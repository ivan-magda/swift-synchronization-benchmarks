import Dispatch

/// Reads and writes run on the serial queue; synchronous calls protect every access.
final class SerialQueueStore: RecordStore, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.transactionalStore.serial")
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        queue.sync {
            records.readGroup(group, size: groupSize)
        }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        queue.sync {
            records.writeGroup(group, size: groupSize)
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }
}

/// Reads share the concurrent queue; synchronous barriers protect writes.
final class BarrierQueueSyncWriteStore: RecordStore, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.transactionalStore.concurrent", attributes: .concurrent)
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        queue.sync {
            records.readGroup(group, size: groupSize)
        }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        queue.sync(flags: .barrier) {
            records.writeGroup(group, size: groupSize)
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }
}

/// Reads share the concurrent queue; asynchronous barriers protect writes.
/// Submitted callbacks retain this store; callers drain before observing completion.
final class BarrierQueueAsyncWriteStore: RecordStore, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.transactionalStore.concurrent", attributes: .concurrent)
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        queue.sync {
            records.readGroup(group, size: groupSize)
        }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        queue.async(flags: .barrier) {
            self.records.writeGroup(group, size: self.groupSize)
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }

    func waitForPendingWrites() {
        queue.sync(flags: .barrier) {}
    }
}
