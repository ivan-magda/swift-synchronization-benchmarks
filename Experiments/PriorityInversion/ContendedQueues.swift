import Dispatch

/// `value` is accessed only on the serial queue.
final class ContendedSerialQueue: ContendedLock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.contended.serial")
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        queue.sync {
            timestamps.markAcquired()
            let resultCorrect = work.run()
            value = trial
            timestamps.markReleased(resultCorrect: resultCorrect)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let (acquired, observedTrial) = queue.sync {
            (Clock.now(), value)
        }
        done(acquired, observedTrial)
    }
}

/// `value` is accessed only on the concurrent queue; the holder writes in a synchronous barrier.
final class ContendedBarrierQueueSyncWrite: ContendedLock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.contended.barrierSyncWrite", attributes: .concurrent)
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        queue.sync(flags: .barrier) {
            timestamps.markAcquired()
            let resultCorrect = work.run()
            value = trial
            timestamps.markReleased(resultCorrect: resultCorrect)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let (acquired, observedTrial) = queue.sync {
            (Clock.now(), value)
        }
        done(acquired, observedTrial)
    }
}

/// `value` is accessed only on the concurrent queue; the holder submits its write as an async barrier
/// and returns. The block retains the owner until its access to `value` has finished.
final class ContendedBarrierQueueAsyncWrite: ContendedLock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.contended.barrierAsyncWrite", attributes: .concurrent)
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        queue.async(flags: .barrier) {
            timestamps.markAcquired()
            let resultCorrect = work.run()
            self.value = trial
            timestamps.markReleased(resultCorrect: resultCorrect)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let (acquired, observedTrial) = queue.sync {
            (Clock.now(), value)
        }
        done(acquired, observedTrial)
    }
}
