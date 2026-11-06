import Synchronization

extension BlockContext {
    /// Runs the block on its threads and times `operations` in batches.
    @inline(__always)
    func timeBatchesOnThreads(
        recordExecutorCPU: @escaping @Sendable (CPUReadingSlot) -> Void = { _ in },
        waitForPendingWrites: @escaping @Sendable () -> Void = {},
        _ operations: @escaping @Sendable (_ thread: Int, _ batch: Int, _ subBatch: Int, _ count: Int) -> Int
    ) -> [ThreadLog] {
        runOnThreads { thread, barrier, log in
            BatchTimer.timeBatches(
                layout: self.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: recordExecutorCPU,
                waitForPendingWrites: waitForPendingWrites,
                runOperations: { batch, subBatch, count in
                    operations(thread, batch, subBatch, count)
                }
            )
        }
    }

    /// Runs one detached task per worker and times `operations` in batches.
    /// Task 0 reads `finalValue` after every worker has finished.
    @inline(__always)
    func timeBatchesInTasks(
        recordExecutorCPU: @escaping @Sendable (CPUReadingSlot) async -> Void,
        recordBatchEdge: @escaping @Sendable (_ batch: Int, _ edge: BatchEdge) -> Void = { _, _ in },
        operations: @escaping @Sendable (_ thread: Int, _ batch: Int, _ subBatch: Int, _ count: Int) async -> Int,
        finalValue: @escaping @Sendable () async -> Int
    ) -> (logs: [ThreadLog], finalValue: Int) {
        let recordedFinalValue = Mutex(0)
        let logs = runInTasks { thread, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: self.layout,
                barrier: barrier,
                log: log,
                isolation: #isolation,
                recordExecutorCPU: recordExecutorCPU,
                recordBatchEdge: recordBatchEdge,
                runOperations: { batch, subBatch, count in
                    await operations(thread, batch, subBatch, count)
                }
            )

            await barrier.arriveAndWait()

            if thread == 0 {
                let value = await finalValue()
                recordedFinalValue.withLock { $0 = value }
            }
        }

        return (logs, recordedFinalValue.withLock { $0 })
    }
}

extension BatchLayout {
    var operationsPerWorker: Int { totalBatches * operationsPerBatch }
}

extension Array where Element == ThreadLog {
    func checkValues(batches: Int) -> [[Int]] {
        map { log in
            (0..<batches).map { log.checkValue(ofBatch: $0) }
        }
    }
}
