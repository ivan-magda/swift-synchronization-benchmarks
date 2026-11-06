import Dispatch
import Synchronization
import Testing

@testable import SyncBench

@Test func asyncBarrierKeepsOrder() async {
    let observation = await onBenchmarkThread {
        let protection = BarrierQueueAsyncWriteInteger(0)
        let log = ThreadLog(batches: 1, readingsPerBatch: 1)

        for newValue in 0..<1_000 {
            protection.write(newValue)
        }

        protection.recordExecutorCPU(into: log.executorSlot(batch: 0, reading: 0))
        protection.waitForPendingWrites()
        // Observe completion before a synchronous read could drain the queue itself.
        let readings = log.executorCPUReadings(ofBatch: 0)
        return (protection.read(), readings)
    }

    #expect(observation.0 == 999)
    #expect(observation.1?.count == 1)
    #expect((observation.1?.first ?? -1) >= 0)
}

// Catches changing async submission into a synchronous barrier that waits for readers.
@Test func asyncBarrierWriteReturnsWhileReaderHoldsAccess() async {
    let observation = await onBenchmarkThread {
        let protection = BarrierQueueAsyncWriteInteger(0)
        let readerEntered = DispatchSemaphore(value: 0)
        let writerReturned = DispatchSemaphore(value: 0)
        let returnedBeforeReaderFinished = Mutex(false)

        let reader = BenchmarkThread.start(name: "held-reader", qos: .userInitiated) {
            protection.withQueueAccess {
                readerEntered.signal()
                let result = writerReturned.wait(timeout: .now() + 2)
                returnedBeforeReaderFinished.withLock { $0 = result == .success }
            }
        }
        let enteredResult = readerEntered.wait(timeout: .now() + 2)
        protection.increment()
        writerReturned.signal()
        reader.join()
        protection.waitForPendingWrites()
        return (
            enteredResult == .success && returnedBeforeReaderFinished.withLock { $0 },
            protection.read()
        )
    }

    #expect(observation.0)
    #expect(observation.1 == 1)
}
