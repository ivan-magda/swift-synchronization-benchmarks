import Dispatch

/// Base-comparison state: every access runs on the serial queue.
/// Keep operations direct so generic inout callbacks cannot add exclusivity checks.
final class SerialQueueInteger: SharedInteger, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.serial")
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
        queue.sync {
            value = newValue
        }
    }

    func increment() {
        queue.sync {
            value &+= 1
        }
    }
}
