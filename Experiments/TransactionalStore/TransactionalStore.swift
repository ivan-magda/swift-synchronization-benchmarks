/// Experiment 4: what do synchronous transactions cost with six workers, 98%
/// reads and 2% writes? Thirteen stores protect groups of one or twenty records.
struct TransactionalStore: Experiment {
    enum Operation: String, CaseIterable, Sendable {
        case singleRecord
        case twentyRecords
    }

    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try TransactionalStoreRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let groupSize = block.description.operation == Operation.singleRecord.rawValue ? 1 : 20
        switch block.description.mechanism {
        case "mutex":
            return measure(MutexStore(groupSize: groupSize), block)
        case "osAllocatedUnfairLock":
            return measure(AllocatedUnfairLockStore(groupSize: groupSize), block)
        case "osAllocatedUnfairLockAdaptiveSpin":
            return measure(AdaptiveSpinUnfairLockStore(groupSize: groupSize), block)
        case "osUnfairLock":
            return measure(UnfairLockStore(groupSize: groupSize), block)
        case "nsLock":
            return measure(NSLockStore(groupSize: groupSize), block)
        case "nsRecursiveLock":
            return measure(NSRecursiveLockStore(groupSize: groupSize), block)
        case "pthreadMutex":
            return measure(PthreadMutexStore(groupSize: groupSize), block)
        case "pthreadReadWriteLock":
            return measure(PthreadReadWriteLockStore(groupSize: groupSize), block)
        case "serialQueue":
            return measure(SerialQueueStore(groupSize: groupSize), block)
        case "barrierQueueSyncWrite":
            return measure(BarrierQueueSyncWriteStore(groupSize: groupSize), block)
        case "barrierQueueAsyncWrite":
            return measure(BarrierQueueAsyncWriteStore(groupSize: groupSize), block)
        case "dispatchSemaphore":
            return measure(DispatchSemaphoreStore(groupSize: groupSize), block)
        case "objcSync":
            return measure(ObjcSyncStore(groupSize: groupSize), block)
        default:
            preconditionFailure("Validated transactionalStore mechanism")
        }
    }

    @inline(never)
    static func operationLoop(
        _ store: some RecordStore, worker: StoreWorker, batch: Int,
        subBatch: Int, layout: BatchLayout
    ) -> Int {
        let operations = worker.operations
        let first = batch * operations.runsPerBatch
        let lower = first + operations.runsPerBatch * subBatch / layout.subBatches
        let upper = first + operations.runsPerBatch * (subBatch + 1) / layout.subBatches
        let measured = batch >= layout.warmupBatches
        var sum = 0
        for runIndex in lower..<upper {
            let run = operations.runs[runIndex]
            let start = measured ? Clock.now() : 0
            for index in run.reads {
                let read = store.readGroup(operations.groups[index])
                sum += read.sum
                if !read.versionsMatch { worker.violations += 1 }
            }
            if measured {
                let end = Clock.now()
                worker.readTimes.record(
                    call: runIndex - layout.warmupBatches * operations.runsPerBatch,
                    ticks: end - start)
            }
            for index in run.writes {
                let slot = run.firstWrite + index - run.writes.lowerBound
                if measured { worker.writeStarts.record(call: slot, ticks: Clock.now()) }
                store.writeGroup(operations.groups[index], endTimes: worker.writeEnds, slot: slot)
            }
        }
        return sum
    }

    func measure(_ store: some RecordStore, _ block: BlockContext) -> [CheckResult] {
        let isSingleRecord = block.description.operation == Operation.singleRecord.rawValue
        let workers = (0..<block.description.threads).map {
            StoreWorker(seed: block.request.seed, thread: $0, layout: block.layout, groupSize: isSingleRecord ? 1 : 20)
        }
        let logs = block.runOnThreads { thread, barrier, log in
            let worker = workers[thread]
            BatchTimer.timeBatches(
                layout: block.layout, barrier: barrier, log: log,
                recordExecutorCPU: { _ in }, waitForPendingWrites: { store.waitForPendingWrites() },
                runOperations: { batch, subBatch, _ in
                    Self.operationLoop(
                        store, worker: worker, batch: batch,
                        subBatch: subBatch, layout: block.layout)
                }
            )
        }
        for (thread, worker) in workers.enumerated() {
            let starts = worker.writeStarts.values
            let ends = worker.writeEnds.values
            let first = block.layout.warmupBatches * worker.operations.writesPerBatch
            let writeTimes = (first..<ends.count).map { ends[$0] - starts[$0] }
            for (metric, values) in [
                (isSingleRecord ? "hundredReadsTime" : "readTime", worker.readTimes.values),
                ("writeTime", writeTimes)
            ] {
                block.appendSamples(
                    SamplesLine(
                        block: block.position, thread: thread,
                        metric: metric, unit: "ticks", values: values, cpuAtStart: nil, cpuAtEnd: nil))
            }
        }
        return [TransactionalStoreChecks.check(store, workers: workers, logs: logs, block: block)]
    }
}
