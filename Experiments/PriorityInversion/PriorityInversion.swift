import Darwin
import Dispatch
import Synchronization

/// Experiment 8B: priority inversion on the main thread.
///
/// Question: how long does the main thread wait when a low-QoS holder works under
/// a lock while higher-QoS load keeps every CPU busy? Compare fourteen mechanisms
/// with both utility and background holders, using os_unfair_lock and a semaphore
/// as the priority-donating and non-donating references.
///
/// One trial starts the holder, starts CPU load after acquire, and schedules the
/// main thread to arrive 1 ms after acquire. It records both sides' timestamps,
/// CPU observations and the protected trial index; every wait has a deadline.
struct PriorityInversion: Experiment {
    let blocks: [BlockDescription]
    private let tunables: PriorityInversionTunables

    init(request: RunRequest) throws(RequestError) {
        blocks = try PriorityInversionRequest.blocks(for: request)
        tunables = request.tunables.priorityInversion!
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let work = HolderWork(
            iterations: tunables.holderWorkIterations,
            expectedResult: referenceLoop(iterations: tunables.holderWorkIterations)
        )
        let lock = ContendedLocks.make(
            MechanismID(rawValue: block.description.mechanism)!,
            holderQoS: block.description.qos
        )
        let timestamps = HolderTimestamps()
        let mainSide = MainSideRecord()
        let loadThreads = LoadThreads(count: PhoneFacts.read().cpuCount, qos: tunables.loadQoS)
        let holder = HolderThread(
            qos: block.description.qos,
            lock: lock,
            work: work,
            timestamps: timestamps
        )
        let setup = TrialSetup(
            lock: lock,
            holder: holder,
            timestamps: timestamps,
            tunables: tunables,
            loadThreads: loadThreads,
            acquireTimeoutTicks: TrialDeadline.ticks(nanoseconds: 2_000_000_000),
            mainSide: mainSide,
            block: block.position
        )

        let result = Mutex<(trials: [TrialLine], timedOut: Bool)>(([], false))
        _ = block.runOnThreads(
            recording: .samplesOnly,
            workerQoS: block.request.tunables.qos
        ) { _, _, _ in
            let completed = setup.runTrials()
            result.withLock { $0 = completed }
        }

        let completed = result.withLock { $0 }
        block.appendTrials(completed.trials)
        holder.shutDown()
        loadThreads.shutDown()

        return [
            PriorityInversionChecks.check(
                operation: block.description.operation,
                trials: completed.trials,
                timedOut: completed.timedOut,
                block: block.position
            )
        ]
    }
}

enum ContendedLocks {
    /// The fourteen mechanisms of experiment 8B.
    static let mechanisms: [MechanismID] = [
        .mutex,
        .osAllocatedUnfairLock,
        .osAllocatedUnfairLockAdaptiveSpin,
        .osUnfairLock,
        .nsLock,
        .nsRecursiveLock,
        .pthreadMutex,
        .pthreadReadWriteLock,
        .objcSync,
        .serialQueue,
        .barrierQueueSyncWrite,
        .barrierQueueAsyncWrite,
        .dispatchSemaphore,
        .actor,
    ]

    /// One new lock for the mechanism; the actor row needs the holder's QoS for its task priority.
    static func make(_ mechanism: MechanismID, holderQoS: QoS) -> any ContendedLock {
        switch mechanism {
        case .mutex: ContendedMutex()
        case .osAllocatedUnfairLock: ContendedAllocatedUnfairLock()
        case .osAllocatedUnfairLockAdaptiveSpin: ContendedAdaptiveSpinUnfairLock()
        case .osUnfairLock: ContendedUnfairLock()
        case .nsLock: ContendedNSLock()
        case .nsRecursiveLock: ContendedNSRecursiveLock()
        case .pthreadMutex: ContendedPthreadMutex()
        case .pthreadReadWriteLock: ContendedPthreadReadWriteLock()
        case .objcSync: ContendedObjcSync()
        case .serialQueue: ContendedSerialQueue()
        case .barrierQueueSyncWrite: ContendedBarrierQueueSyncWrite()
        case .barrierQueueAsyncWrite: ContendedBarrierQueueAsyncWrite()
        case .dispatchSemaphore: ContendedSemaphore()
        case .actor: ContendedActorLock(holderPriority: holderQoS.taskPriority)
        default:
            preconditionFailure("Experiment 8B has no row for \(mechanism)")
        }
    }
}

/// What the holder and the main thread share in one trial.
protocol ContendedLock: AnyObject, Sendable {
    /// Holder side, called on the holder thread. Takes the lock, calls `markAcquired`,
    /// runs `work`, stores `trial` as the protected value, calls `markReleased`, releases.
    /// The async `.barrier` row and the actor return after submitting; their work runs later.
    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps)

    /// Main side, called on the main thread. Takes the lock (the read side where there is one),
    /// reads the protected value and calls `done` with the acquire tick and that value.
    /// Synchronous mechanisms call `done` before returning; the actor calls it from a main-actor task.
    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void)
}

extension PriorityInversion {
    /// One trial: the holder takes the lock, the load starts, the main thread
    /// arrives 1 ms after the holder's acquire and waits; returns nil on a timeout.
    static func runOneTrial(_ trial: Int, warmup: Bool, setup: TrialSetup) -> TrialLine? {
        let holder = setup.holder
        let timestamps = setup.timestamps
        let loadThreads = setup.loadThreads
        let mainSide = setup.mainSide

        // 1. Start the holder while CPUs are free; never reset an unfinished trial.
        // No holder may still mark these timestamps: either no trial has started, or the
        // preceding holder release and main-side touch completed before we reach this reset.
        timestamps.reset()
        mainSide.reset()
        holder.start(trial: trial)

        let (acquireDeadline, acquireOverflow) = Clock.now().addingReportingOverflow(
            setup.acquireTimeoutTicks
        )
        guard !acquireOverflow, timestamps.waitAcquired(until: acquireDeadline) else {
            return nil
        }

        // 2. Keep the CPUs busy for the fixed load interval.
        let loadStart = Clock.now()
        let (loadStop, loadOverflow) = loadStart.addingReportingOverflow(setup.loadTicks)
        guard !loadOverflow else {
            return nil
        }

        loadThreads.start(until: loadStop)

        // 3. The main thread targets acquire + 1 ms (the request may tune the delay).
        let (arrivalTarget, arrivalOverflow) = timestamps.acquire.addingReportingOverflow(
            setup.mainDelayTicks
        )
        guard !arrivalOverflow else {
            return nil
        }

        let lock = setup.lock

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

        // 4. All completion waits share load stop + five seconds.
        let (deadline, finishOverflow) = loadStop.addingReportingOverflow(setup.finishAllowanceTicks)
        guard !finishOverflow,
            mainSide.waitDone(until: deadline),
            timestamps.waitReleased(until: deadline),
            loadThreads.waitStopped(until: deadline)
        else {
            return nil
        }

        // 5. Keep every completed trial, including censored and invalid arrivals.
        return TrialLine(
            block: setup.block,
            trial: trial,
            warmup: warmup,
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
        )
    }
}
