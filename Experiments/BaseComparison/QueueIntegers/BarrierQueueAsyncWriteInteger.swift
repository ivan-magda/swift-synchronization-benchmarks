import Dispatch

/// Base-comparison state: reads share the queue; asynchronous barriers protect mutations.
/// Submitted closures retain their owner. Callers drain queued work before observing completion.
final class BarrierQueueAsyncWriteInteger: SharedInteger, @unchecked Sendable {
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
        queue.async(flags: .barrier) {
            self.value = newValue
        }
    }

    func increment() {
        queue.async(flags: .barrier) {
            self.value &+= 1
        }
    }

    func waitForPendingWrites() {
        queue.sync(flags: .barrier) {}
    }

    func recordExecutorCPU(into slot: CPUReadingSlot) {
        queue.async(flags: .barrier) {
            slot.store(CPU.current())
        }
    }
}
