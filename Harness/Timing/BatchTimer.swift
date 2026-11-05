enum BatchTimer {
    @inline(__always)
    static func timeBatches(
        layout: BatchLayout,
        barrier: ThreadBarrier,
        log: ThreadLog,
        recordExecutorCPU: (CPUReadingSlot) -> Void,
        waitForPendingWrites: () -> Void,
        runOperations: (_ batch: Int, _ subBatch: Int, _ count: Int) -> Int
    ) {
        barrier.arriveAndWait()

        for batch in 0..<layout.totalBatches {
            barrier.arriveAndWait()
            var checkValue = 0
            let start = Clock.now()

            for subBatch in 0..<layout.subBatches {
                log.recordCPU(batch: batch, reading: subBatch, cpu: CPU.current())
                recordExecutorCPU(log.executorSlot(batch: batch, reading: subBatch))
                checkValue &+= runOperations(batch, subBatch, layout.operationsPerSubBatch)
            }

            let lastReading = layout.subBatches
            log.recordCPU(batch: batch, reading: lastReading, cpu: CPU.current())
            recordExecutorCPU(log.executorSlot(batch: batch, reading: lastReading))
            waitForPendingWrites()
            let end = Clock.now()
            log.recordTimes(batch: batch, start: start, end: end)
            log.recordCheckValue(batch: batch, value: checkValue)
        }
    }

    @inline(__always)
    static func timeBatches(
        layout: BatchLayout,
        barrier: TaskBarrier,
        log: ThreadLog,
        recordExecutorCPU: (CPUReadingSlot) async -> Void,
        runOperations: (_ batch: Int, _ subBatch: Int, _ count: Int) async -> Int
    ) async {
        await barrier.arriveAndWait()

        for batch in 0..<layout.totalBatches {
            await barrier.arriveAndWait()
            var checkValue = 0
            let start = Clock.now()

            for subBatch in 0..<layout.subBatches {
                log.recordCPU(batch: batch, reading: subBatch, cpu: CPU.current())
                await recordExecutorCPU(log.executorSlot(batch: batch, reading: subBatch))
                checkValue &+= await runOperations(batch, subBatch, layout.operationsPerSubBatch)
            }

            let lastReading = layout.subBatches
            log.recordCPU(batch: batch, reading: lastReading, cpu: CPU.current())
            await recordExecutorCPU(log.executorSlot(batch: batch, reading: lastReading))
            let end = Clock.now()
            log.recordTimes(batch: batch, start: start, end: end)
            log.recordCheckValue(batch: batch, value: checkValue)
        }
    }
}
