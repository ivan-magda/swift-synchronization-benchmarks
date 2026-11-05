import Dispatch
import Synchronization

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
                guard !ending.load(ordering: .acquiring) else { return }
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
                guard !worker.ending.load(ordering: .acquiring) else { return }
                lock.hold(trial: worker.trial.load(ordering: .acquiring), work: work, timestamps: timestamps)
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
    static func validateDuration(_ value: Int, nanosecondsPerUnit: UInt64, field: String) throws(RequestError) {
        let (nanoseconds, overflow) = UInt64(value).multipliedReportingOverflow(by: nanosecondsPerUnit)
        guard !overflow, ticks(nanoseconds: nanoseconds) != UInt64.max else {
            throw RequestError(message: "priorityInversion.\(field) must fit UInt64 nanoseconds and ticks")
        }
    }

    static func ticks(nanoseconds: UInt64) -> UInt64 {
        let timebase = Clock.timebase
        let product = nanoseconds.multipliedFullWidth(by: UInt64(timebase.denom))
        guard product.high < UInt64(timebase.numer) else { return UInt64.max }
        return UInt64(timebase.numer).dividingFullWidth(product).quotient
    }

    static func dispatchTime(until deadline: UInt64) -> DispatchTime {
        let now = Clock.now()
        guard now < deadline else { return .now() }
        let timebase = Clock.timebase
        let product = (deadline - now).multipliedFullWidth(by: UInt64(timebase.numer))
        guard product.high < UInt64(timebase.denom) else { return .distantFuture }
        let nanoseconds = UInt64(timebase.denom).dividingFullWidth(product).quotient
        return .now() + .nanoseconds(Int(clamping: nanoseconds))
    }
}
