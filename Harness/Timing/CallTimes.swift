/// One task's timed call durations, allocated before the block. Only that task writes;
/// the run thread reads after `runInTasks` returns. The 128-byte alignment keeps two
/// tasks' buffers off one cache line.
final class CallTimes: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<UInt64>
    private let calls: Int

    init(calls: Int) {
        self.calls = calls
        storage = UnsafeMutableRawPointer
            .allocate(byteCount: max(calls * MemoryLayout<UInt64>.stride, 1), alignment: 128)
            .bindMemory(to: UInt64.self, capacity: calls)
        storage.initialize(repeating: 0, count: calls)
    }

    @inline(__always)
    func record(call: Int, ticks: UInt64) {
        precondition(call >= 0 && call < calls)
        storage[call] = ticks
    }

    var values: [UInt64] {
        Array(UnsafeBufferPointer(start: storage, count: calls))
    }

    deinit {
        storage.deinitialize(count: calls)
        UnsafeMutableRawPointer(storage).deallocate()
    }
}
