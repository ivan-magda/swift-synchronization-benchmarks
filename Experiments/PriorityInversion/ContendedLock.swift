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
        let atAcquire = acquired.load(ordering: .acquiring) ? acquireCPU.load(ordering: .relaxed) : -1
        let atRelease = released.load(ordering: .acquiring) ? releaseCPU.load(ordering: .relaxed) : -1

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

            _ = signal.wait(timeout: .now() + .nanoseconds(nanoseconds(ticks: deadline - now)))
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
        return quotient > UInt64(Int.max) ? Int.max : Int(quotient)
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
