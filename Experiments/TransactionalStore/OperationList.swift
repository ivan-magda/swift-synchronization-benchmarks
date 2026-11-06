/// Immutable input generated before timing. Each run contains only reads, followed
/// by zero or more writes; a sub-batch boundary always lies between complete runs.
struct OperationList: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        let reads: Range<Int>
        let writes: Range<Int>
        let firstWrite: Int
    }

    let groups: [Int]
    let runs: [Run]
    let runsPerBatch: Int
    let writesPerBatch: Int

    static func make(
        seed: UInt64, thread: Int, batches: Int, transactionsPerBatch: Int,
        readsPerRun: Int, groups: Int
    ) -> OperationList {
        let writesPerBatch = transactionsPerBatch / 50
        let runsPerBatch = (transactionsPerBatch - writesPerBatch) / readsPerRun
        var generator = SplitMix64(seed: seed &+ UInt64(thread) &* 0x9E37_79B9_7F4A_7C15)
        var groupIndexes: [Int] = []
        var runs: [Run] = []
        groupIndexes.reserveCapacity(batches * transactionsPerBatch)
        runs.reserveCapacity(batches * runsPerBatch)
        var writeSlot = 0
        for _ in 0..<batches {
            var writesAtBoundary = Array(repeating: 0, count: runsPerBatch)
            for _ in 0..<writesPerBatch {
                writesAtBoundary[Int(generator.next() % UInt64(runsPerBatch - 1))] += 1
            }
            for run in 0..<runsPerBatch {
                let first = groupIndexes.count
                for _ in 0..<(readsPerRun + writesAtBoundary[run]) {
                    groupIndexes.append(Int(generator.next() % UInt64(groups)))
                }
                let firstWrite = first + readsPerRun
                runs.append(
                    Run(
                        reads: first..<firstWrite,
                        writes: firstWrite..<groupIndexes.count, firstWrite: writeSlot))
                writeSlot += writesAtBoundary[run]
            }
        }
        return OperationList(
            groups: groupIndexes, runs: runs,
            runsPerBatch: runsPerBatch, writesPerBatch: writesPerBatch)
    }
}

/// One worker owns counters and start/read buffers. Queue callbacks write unique
/// completion slots; draining the queue and joining workers publish them to the run thread.
final class StoreWorker: @unchecked Sendable {
    let operations: OperationList
    let readTimes: CallTimes
    let writeStarts: CallTimes
    let writeEnds: CallTimes
    var violations = 0

    init(seed: UInt64, thread: Int, layout: BatchLayout, groupSize: Int) {
        operations = OperationList.make(
            seed: seed, thread: thread, batches: layout.totalBatches,
            transactionsPerBatch: layout.operationsPerBatch,
            readsPerRun: groupSize == 1 ? 100 : 1, groups: 10_000 / groupSize)
        readTimes = CallTimes(calls: layout.measuredBatches * operations.runsPerBatch)
        writeStarts = CallTimes(calls: layout.totalBatches * operations.writesPerBatch)
        writeEnds = CallTimes(calls: layout.totalBatches * operations.writesPerBatch)
    }
}
