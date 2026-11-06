import Dispatch


/// Hot-flag state: every access runs on the serial queue.
/// Keep operations direct so generic inout callbacks cannot add exclusivity checks.
final class SerialQueueFlag: SharedFlag, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.hotFlag.serial")
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        queue.sync {
            value
        }
    }

    func write(_ newValue: Bool) {
        queue.sync {
            value = newValue
        }
    }

}


/// Hot-flag state: reads share the queue; synchronous barriers protect mutations.
/// This concrete Bool storage is never exposed through a generic state callback.
final class BarrierQueueSyncWriteFlag: SharedFlag, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.hotFlag.concurrent", attributes: .concurrent)
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        queue.sync {
            value
        }
    }

    func write(_ newValue: Bool) {
        queue.sync(flags: .barrier) {
            value = newValue
        }
    }

}


/// Hot-flag state: reads share the queue; asynchronous barriers protect mutations.
/// Submitted closures retain their owner. Callers drain queued work before observing completion.
final class BarrierQueueAsyncWriteFlag: SharedFlag, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.hotFlag.concurrent", attributes: .concurrent)
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        queue.sync {
            value
        }
    }

    func write(_ newValue: Bool) {
        queue.async(flags: .barrier) {
            self.value = newValue
        }
    }

    func waitForPendingWrites() {
        queue.sync(flags: .barrier) {}
    }

}
