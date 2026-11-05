import Darwin
import Dispatch
import Synchronization

/// The main side publishes its fields before signaling completion. The controller resets
/// only before the first trial or after completion, and reads only after `waitDone` succeeds.
final class MainSideRecord: Sendable {
    private let arrivalTick = Atomic<UInt64>(0)
    private let acquireTick = Atomic<UInt64>(0)
    private let cpuNumber = Atomic<Int>(-1)
    private let observedTrial = Atomic<Int>(-1)
    private let done = DispatchSemaphore(value: 0)

    func reset() {
        arrivalTick.store(0, ordering: .relaxed)
        acquireTick.store(0, ordering: .relaxed)
        cpuNumber.store(-1, ordering: .relaxed)
        observedTrial.store(-1, ordering: .relaxed)
        while done.wait(timeout: .now()) == .success {}
    }

    func store(arrival: UInt64, acquire: UInt64, cpu: Int, observed: Int) {
        arrivalTick.store(arrival, ordering: .relaxed)
        acquireTick.store(acquire, ordering: .relaxed)
        cpuNumber.store(cpu, ordering: .relaxed)
        observedTrial.store(observed, ordering: .relaxed)
    }

    func signalDone() {
        done.signal()
    }

    func waitDone(until deadline: UInt64) -> Bool {
        done.wait(timeout: TrialDeadline.dispatchTime(until: deadline)) == .success
    }

    var arrival: UInt64 { arrivalTick.load(ordering: .relaxed) }
    var acquire: UInt64 { acquireTick.load(ordering: .relaxed) }
    var cpu: Int { cpuNumber.load(ordering: .relaxed) }
    var observed: Int { observedTrial.load(ordering: .relaxed) }
}

struct TrialRunner: Sendable {
    let lock: any ContendedLock
    let holder: HolderThread
    let timestamps: HolderTimestamps
    let tunables: PriorityInversionTunables
    let loadThreads: LoadThreads
    let acquireTimeoutTicks: UInt64
    let mainSide: MainSideRecord

    init(
        lock: any ContendedLock,
        holder: HolderThread,
        timestamps: HolderTimestamps,
        tunables: PriorityInversionTunables,
        loadThreads: LoadThreads,
        acquireTimeoutTicks: UInt64,
        mainSide: MainSideRecord = MainSideRecord()
    ) {
        self.lock = lock
        self.holder = holder
        self.timestamps = timestamps
        self.tunables = tunables
        self.loadThreads = loadThreads
        self.acquireTimeoutTicks = acquireTimeoutTicks
        self.mainSide = mainSide
    }

    /// Runs on the controller pthread. After a timeout no next trial is started or record reset.
    func runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool) {
        precondition(pthread_main_np() == 0)
        let loadTicks = TrialDeadline.ticks(
            nanoseconds: UInt64(tunables.loadMilliseconds) * 1_000_000
        )
        let mainDelayTicks = TrialDeadline.ticks(
            nanoseconds: UInt64(tunables.mainDelayMicroseconds) * 1_000
        )
        let finishAllowanceTicks = TrialDeadline.ticks(nanoseconds: 5_000_000_000)
        let totalTrials = tunables.warmupTrials + tunables.trials
        var trials: [TrialLine] = []
        trials.reserveCapacity(totalTrials)

        for trial in 0..<totalTrials {
            // No holder may still mark these timestamps: either no trial has started, or the
            // preceding holder release and main-side touch completed before we reach this reset.
            timestamps.reset()
            mainSide.reset()
            holder.start(trial: trial)
            let (acquireDeadline, acquireOverflow) = Clock.now().addingReportingOverflow(
                acquireTimeoutTicks
            )
            guard !acquireOverflow, timestamps.waitAcquired(until: acquireDeadline) else {
                return (trials, true)
            }

            let loadStart = Clock.now()
            let (loadStop, loadOverflow) = loadStart.addingReportingOverflow(loadTicks)
            guard !loadOverflow else { return (trials, true) }
            loadThreads.start(until: loadStop)

            let (arrivalTarget, arrivalOverflow) = timestamps.acquire.addingReportingOverflow(
                mainDelayTicks
            )
            guard !arrivalOverflow else { return (trials, true) }
            let lock = lock
            let mainSide = mainSide
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    mach_wait_until(arrivalTarget)
                    let mainArrival = Clock.now()
                    lock.touch { mainAcquire, observedTrial in
                        mainSide.store(
                            arrival: mainArrival,
                            acquire: mainAcquire,
                            cpu: CPU.current(),
                            observed: observedTrial
                        )
                        mainSide.signalDone()
                    }
                }
            }

            let (deadline, finishOverflow) = loadStop.addingReportingOverflow(finishAllowanceTicks)
            guard !finishOverflow,
                mainSide.waitDone(until: deadline),
                timestamps.waitReleased(until: deadline),
                loadThreads.waitStopped(until: deadline)
            else {
                return (trials, true)
            }

            trials.append(TrialLine(
                block: block,
                trial: trial,
                warmup: trial < tunables.warmupTrials,
                holderQoS: holder.qos,
                loadStart: loadStart,
                loadStop: loadStop,
                holderAcquire: timestamps.acquire,
                holderRelease: timestamps.release,
                mainArrival: mainSide.arrival,
                mainAcquire: mainSide.acquire,
                holderCPUReadings: timestamps.cpuReadings,
                mainCPU: mainSide.cpu,
                holderResultCorrect: timestamps.resultCorrect,
                mainObservedTrial: mainSide.observed,
                outcome: .classify(
                    holderAcquire: timestamps.acquire,
                    holderRelease: timestamps.release,
                    mainArrival: mainSide.arrival,
                    mainAcquire: mainSide.acquire,
                    loadStop: loadStop
                )
            ))
            usleep(useconds_t(tunables.pauseMilliseconds * 1_000))
        }
        return (trials, false)
    }
}
