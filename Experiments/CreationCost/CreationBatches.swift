import Dispatch
import Synchronization

/// A single executor owns this storage while a batch runs. The worker reads it only
/// after completion; a timed-out main-thread closure keeps ownership and its lifetime.
final class CreationBatchStorage<Object: AnyObject>: @unchecked Sendable {
    private var objects: ContiguousArray<Object> = []
    let log: ThreadLog
    private(set) var completedBatch: Int?
    private(set) var sample = CreationCostChecks.MemorySample(
        before: (0, 0), afterCreate: (0, 0), afterDestroy: (0, 0), heapBlocks: 0, liveBefore: nil, liveAfterDestroy: nil
    )

    init(layout: BatchLayout) {
        objects.reserveCapacity(layout.operationsPerBatch)
        log = ThreadLog(batches: layout.totalBatches, readingsPerBatch: layout.subBatches + 1)
    }

    func run(
        batch: Int, operation: String, layout: BatchLayout,
        counter: CreationDeinitCounter, make: (CreationDeinitCounter) -> Object
    ) {
        if operation == "destroy" {
            CreationCost.createLoop(&objects, count: layout.operationsPerBatch, counter: counter, make: make)
        }
        let before = operation == "create" ? MallocStatistics.read() : (blocks: 0, bytes: 0)
        let liveBefore = operation == "create" ? MallocStatistics.liveBlocks() : nil
        let start = Clock.now()
        for subBatch in 0..<layout.subBatches {
            log.recordCPU(batch: batch, reading: subBatch, cpu: CPU.current())
            if operation == "create" {
                CreationCost.createLoop(&objects, count: layout.operationsPerSubBatch, counter: counter, make: make)
            } else {
                CreationCost.destroyLoop(&objects, count: layout.operationsPerSubBatch)
            }
        }
        log.recordCPU(batch: batch, reading: layout.subBatches, cpu: CPU.current())
        let end = Clock.now()
        if operation == "create" {
            let afterCreate = MallocStatistics.read()
            let heapBlocks = CreationCostChecks.heapBlockCount(objects)
            objects.removeAll(keepingCapacity: true)
            let afterDestroy = MallocStatistics.read()
            let liveAfterDestroy = MallocStatistics.liveBlocks()
            sample = CreationCostChecks.MemorySample(before: before, afterCreate: afterCreate,
                                                     afterDestroy: afterDestroy, heapBlocks: heapBlocks,
                                                     liveBefore: liveBefore, liveAfterDestroy: liveAfterDestroy)
        }
        log.recordTimes(batch: batch, start: start, end: end)
        completedBatch = batch
    }
}

/// Worker-owned results are read by the run thread only after the worker joins.
final class CreationBatchOutcome: @unchecked Sendable {
    var completed = true
    var samples: [CreationCostChecks.MemorySample] = []

    init(capacity: Int) {
        samples.reserveCapacity(capacity)
    }

    func appendSamples(to block: BlockContext) {
        let metrics: [(String, String, (CreationCostChecks.MemorySample) -> UInt64)] = [
            ("mallocBlocksBeforeCreate", "blocks", { $0.before.blocks }),
            ("mallocBlocksAfterCreate", "blocks", { $0.afterCreate.blocks }),
            ("mallocBlocksAfterDestroy", "blocks", { $0.afterDestroy.blocks }),
            ("mallocBytesBeforeCreate", "bytes", { $0.before.bytes }),
            ("mallocBytesAfterCreate", "bytes", { $0.afterCreate.bytes }),
            ("mallocBytesAfterDestroy", "bytes", { $0.afterDestroy.bytes }),
        ]
        for (metric, unit, value) in metrics {
            block.appendSamples(SamplesLine(block: block.position, thread: nil, metric: metric, unit: unit,
                                            values: samples.map(value), cpuAtStart: nil, cpuAtEnd: nil))
        }
    }
}

/// Both semaphores are allocated before the block. Main parks for at most one
/// second; its success flag is read only after the helper publishes completion.
final class CreationBatchGate: Sendable {
    let ready = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let mainWaitSucceeded = Atomic<Bool>(false)
}
