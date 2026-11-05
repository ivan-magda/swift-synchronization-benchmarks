import Dispatch

/// Base-comparison state: reads share the queue; synchronous barriers protect mutations.
/// This concrete Int storage is never exposed through a generic state callback.
final class BarrierQueueSyncWriteInteger: SharedInteger, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.concurrent", attributes: .concurrent)
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        queue.sync {
            value
        }
    }

    func write(_ newValue: Int) {
        queue.sync(flags: .barrier) {
            value = newValue
        }
    }

    func increment() {
        queue.sync(flags: .barrier) {
            value &+= 1
        }
    }
}
