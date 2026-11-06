import Darwin
import Dispatch
import Synchronization

/// The holder's work: a fixed number of reference-loop iterations and the result they must give.
struct HolderWork: Sendable {
    let iterations: Int
    let expectedResult: UInt64

    /// Runs the work and tells whether the result was right.
    func run() -> Bool {
        referenceLoop(iterations: iterations) == expectedResult
    }
}

/// Times and CPU numbers of the holder side of one trial. Written by the holder, read by the controller.
///
/// The holder publishes each mark with a releasing store and then signals a semaphore; it never takes
/// a lock that the controller could hold, so waiting here donates no priority to the holder.
/// Ticks are 0 and CPU numbers -1 until marked. Call `reset` only while no holder is running.
final class HolderTimestamps: Sendable {
    private let acquireTick = Atomic<UInt64>(0)
    private let releaseTick = Atomic<UInt64>(0)
    private let acquireCPU = Atomic<Int>(-1)
    private let releaseCPU = Atomic<Int>(-1)
    private let holderResultCorrect = Atomic<Bool>(false)
    private let acquired = Atomic<Bool>(false)
    private let released = Atomic<Bool>(false)
    private let acquiredSignal = DispatchSemaphore(value: 0)
    private let releasedSignal = DispatchSemaphore(value: 0)

    func reset() {
        acquired.store(false, ordering: .relaxed)
        released.store(false, ordering: .relaxed)
        acquireTick.store(0, ordering: .relaxed)
        releaseTick.store(0, ordering: .relaxed)
        acquireCPU.store(-1, ordering: .relaxed)
        releaseCPU.store(-1, ordering: .relaxed)
        holderResultCorrect.store(false, ordering: .relaxed)

        // Signals of an earlier trial whose waits ended without consuming them.
        while acquiredSignal.wait(timeout: .now()) == .success {}
        while releasedSignal.wait(timeout: .now()) == .success {}
    }

    func markAcquired() {
        let tick = Clock.now()
        let cpu = CPU.current()
        acquireTick.store(tick, ordering: .relaxed)
        acquireCPU.store(cpu, ordering: .relaxed)
        acquired.store(true, ordering: .releasing)
        acquiredSignal.signal()
    }

    func markReleased(resultCorrect: Bool) {
        let tick = Clock.now()
        let cpu = CPU.current()
        releaseTick.store(tick, ordering: .relaxed)
        releaseCPU.store(cpu, ordering: .relaxed)
        holderResultCorrect.store(resultCorrect, ordering: .relaxed)
        released.store(true, ordering: .releasing)
        releasedSignal.signal()
    }

    /// Returns false when the holder has not acquired by `deadline` (ticks).
    func waitAcquired(until deadline: UInt64) -> Bool {
        Self.wait(for: acquired, signal: acquiredSignal, until: deadline)
    }

    /// Returns false when the holder has not released by `deadline` (ticks).
    func waitReleased(until deadline: UInt64) -> Bool {
        Self.wait(for: released, signal: releasedSignal, until: deadline)
    }

    var acquire: UInt64 {
        acquired.load(ordering: .acquiring) ? acquireTick.load(ordering: .relaxed) : 0
    }

    var release: UInt64 {
        released.load(ordering: .acquiring) ? releaseTick.load(ordering: .relaxed) : 0
    }

    /// At acquire, at release.
    var cpuReadings: [Int] {
        let atAcquire = acquired.load(ordering: .acquiring)
            ? acquireCPU.load(ordering: .relaxed) : -1
        let atRelease = released.load(ordering: .acquiring)
            ? releaseCPU.load(ordering: .relaxed) : -1

        return [atAcquire, atRelease]
    }

    var resultCorrect: Bool {
        released.load(ordering: .acquiring) && holderResultCorrect.load(ordering: .relaxed)
    }

    /// The flag decides; the semaphore only wakes the waiter, so a stale or early signal is harmless.
    private static func wait(
        for flag: borrowing Atomic<Bool>,
        signal: DispatchSemaphore,
        until deadline: UInt64
    ) -> Bool {
        while !flag.load(ordering: .acquiring) {
            let now = Clock.now()
            guard now < deadline else {
                return false
            }

            _ = signal.wait(
                timeout: .now() + .nanoseconds(nanoseconds(ticks: deadline - now))
            )
        }

        return true
    }

    /// Saturates instead of overflowing for very distant deadlines.
    private static func nanoseconds(ticks: UInt64) -> Int {
        let timebase = Clock.timebase
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        guard product.high < UInt64(timebase.denom) else {
            return Int.max
        }

        let quotient = UInt64(timebase.denom).dividingFullWidth(product).quotient
        return Int(clamping: quotient)
    }
}

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

    var arrival: UInt64 {
        arrivalTick.load(ordering: .relaxed)
    }

    var acquire: UInt64 {
        acquireTick.load(ordering: .relaxed)
    }

    var cpu: Int {
        cpuNumber.load(ordering: .relaxed)
    }

    var observed: Int {
        observedTrial.load(ordering: .relaxed)
    }
}

struct TrialSetup: Sendable {
    let lock: any ContendedLock
    let holder: HolderThread
    let timestamps: HolderTimestamps
    let tunables: PriorityInversionTunables
    let loadThreads: LoadThreads
    let acquireTimeoutTicks: UInt64
    let mainSide: MainSideRecord
    let block: Int
    let loadTicks: UInt64
    let mainDelayTicks: UInt64
    let finishAllowanceTicks: UInt64

    init(
        lock: any ContendedLock,
        holder: HolderThread,
        timestamps: HolderTimestamps,
        tunables: PriorityInversionTunables,
        loadThreads: LoadThreads,
        acquireTimeoutTicks: UInt64,
        mainSide: MainSideRecord = MainSideRecord(),
        block: Int = 0
    ) {
        self.lock = lock
        self.holder = holder
        self.timestamps = timestamps
        self.tunables = tunables
        self.loadThreads = loadThreads
        self.acquireTimeoutTicks = acquireTimeoutTicks
        self.mainSide = mainSide
        self.block = block
        loadTicks = TrialDeadline.ticks(
            nanoseconds: UInt64(tunables.loadMilliseconds) * 1_000_000
        )
        mainDelayTicks = TrialDeadline.ticks(
            nanoseconds: UInt64(tunables.mainDelayMicroseconds) * 1_000
        )
        finishAllowanceTicks = TrialDeadline.ticks(nanoseconds: 5_000_000_000)
    }

    /// Runs on the controller pthread. After a timeout no next trial is started or record reset.
    func runTrials() -> (trials: [TrialLine], timedOut: Bool) {
        precondition(pthread_main_np() == 0)

        let totalTrials = tunables.warmupTrials + tunables.trials
        var trials: [TrialLine] = []
        trials.reserveCapacity(totalTrials)

        for trial in 0..<totalTrials {
            guard let line = PriorityInversion.runOneTrial(
                trial,
                warmup: trial < tunables.warmupTrials,
                setup: self
            ) else {
                return (trials, true)
            }
            trials.append(line)
            usleep(useconds_t(tunables.pauseMilliseconds * 1_000))
        }

        return (trials, false)
    }
}

/// Reusable load pthreads. The controller starts and waits for one trial at a time;
/// each worker's command and shutdown flag are published atomically before its wake signal.
final class LoadThreads: Sendable {
    private final class Worker: Sendable {
        let wake = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let stopTick = Atomic<UInt64>(0)
        let ending = Atomic<Bool>(false)

        func run() {
            while true {
                wake.wait()
                guard !ending.load(ordering: .acquiring) else {
                    return
                }

                let deadline = stopTick.load(ordering: .acquiring)
                while Clock.now() < deadline && !ending.load(ordering: .relaxed) {
                    blackHole(referenceLoop(iterations: 1_000))
                }

                stopped.signal()
            }
        }
    }

    private let workers: [Worker]
    private let threads: [BenchmarkThread]

    init(count: Int, qos: QoS) {
        precondition(count > 0)
        let workers = (0..<count).map { _ in Worker() }
        self.workers = workers
        threads = workers.enumerated().map { index, worker in
            BenchmarkThread.start(name: "inversion-load-\(index)", qos: qos) { worker.run() }
        }
    }

    /// Release every worker. Call only before the first trial or after `waitStopped` succeeds.
    func start(until stopTick: UInt64) {
        for worker in workers {
            worker.stopTick.store(stopTick, ordering: .releasing)
            worker.wake.signal()
        }
    }

    /// Returns false when some worker has not stopped at the controller's deadline.
    func waitStopped(until deadline: UInt64) -> Bool {
        for worker in workers {
            guard worker.stopped.wait(timeout: TrialDeadline.dispatchTime(until: deadline)) == .success else {
                return false
            }
        }

        return true
    }

    /// Controller only. Interrupts active load and joins all pthreads, including after a timeout.
    func shutDown() {
        for worker in workers {
            worker.ending.store(true, ordering: .releasing)
            worker.wake.signal()
        }

        for thread in threads {
            thread.join()
        }
    }
}

/// One pthread at the holder's QoS. Only the controller writes commands; the worker reads
/// each trial before calling `hold`. The semaphore and atomic command publish that handoff.
final class HolderThread: Sendable {
    private final class Worker: Sendable {
        let wake = DispatchSemaphore(value: 0)
        let trial = Atomic<Int>(0)
        let ending = Atomic<Bool>(false)
    }

    let qos: QoS
    private let worker = Worker()
    private let thread: BenchmarkThread

    init(qos: QoS, lock: any ContendedLock, work: HolderWork, timestamps: HolderTimestamps) {
        self.qos = qos
        let worker = worker
        thread = BenchmarkThread.start(name: "inversion-holder", qos: qos) {
            while true {
                worker.wake.wait()
                guard !worker.ending.load(ordering: .acquiring) else {
                    return
                }

                lock.hold(
                    trial: worker.trial.load(ordering: .acquiring),
                    work: work,
                    timestamps: timestamps
                )
            }
        }
    }

    /// Controller only; the previous trial's holder and main-side work must have completed.
    func start(trial: Int) {
        worker.trial.store(trial, ordering: .releasing)
        worker.wake.signal()
    }

    /// Controller only. The lock's finite holder work finishes before the pthread is joined.
    func shutDown() {
        worker.ending.store(true, ordering: .releasing)
        worker.wake.signal()
        thread.join()
    }
}

/// Integer timebase conversion shared by the trial's deadline waits.
enum TrialDeadline {
    static func validateDuration(
        _ value: Int,
        nanosecondsPerUnit: UInt64,
        field: String
    ) throws(RequestError) {
        let (nanoseconds, overflow) = UInt64(value).multipliedReportingOverflow(by: nanosecondsPerUnit)
        guard !overflow, ticks(nanoseconds: nanoseconds) != UInt64.max else {
            throw RequestError(message: "priorityInversion.\(field) must fit UInt64 nanoseconds and ticks")
        }
    }

    static func ticks(nanoseconds: UInt64) -> UInt64 {
        let timebase = Clock.timebase
        let product = nanoseconds.multipliedFullWidth(by: UInt64(timebase.denom))
        guard product.high < UInt64(timebase.numer) else {
            return UInt64.max
        }

        return UInt64(timebase.numer).dividingFullWidth(product).quotient
    }

    static func dispatchTime(until deadline: UInt64) -> DispatchTime {
        let now = Clock.now()
        guard now < deadline else {
            return .now()
        }

        let timebase = Clock.timebase
        let product = (deadline - now).multipliedFullWidth(by: UInt64(timebase.numer))
        guard product.high < UInt64(timebase.denom) else {
            return .distantFuture
        }

        let nanoseconds = UInt64(timebase.denom).dividingFullWidth(product).quotient
        return .now() + .nanoseconds(Int(clamping: nanoseconds))
    }
}
