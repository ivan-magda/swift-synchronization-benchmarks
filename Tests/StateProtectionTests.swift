import Dispatch
import Synchronization
import Testing

@testable import SyncBench

@Test(arguments: [
    MechanismID.pthreadReadWriteLock,
    .barrierQueueSyncWrite,
    .barrierQueueAsyncWrite
])
func readersOverlap(_ mechanism: MechanismID) async {
    let overlapped = await onBenchmarkThread {
        let protection = makeIntegerProtection(mechanism, initialValue: 0)
        let firstEntered = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let overlapped = Mutex(false)

        let first = BenchmarkThread.start(name: "first-reader", qos: .userInitiated) {
            protection.withSharedAccess { _ in
                firstEntered.signal()
                let result = secondEntered.wait(timeout: .now() + 2)
                overlapped.withLock { $0 = result == .success }
            }
        }
        let firstResult = firstEntered.wait(timeout: .now() + 2)
        let second = BenchmarkThread.start(name: "second-reader", qos: .userInitiated) {
            protection.withSharedAccess { _ -> Void in
                secondEntered.signal()
            }
        }
        first.join()
        second.join()
        return firstResult == .success && overlapped.withLock { $0 }
    }

    #expect(overlapped)
}

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
        let protection = BarrierQueueAsyncWriteProtection<Int>(0)
        let readerEntered = DispatchSemaphore(value: 0)
        let writerReturned = DispatchSemaphore(value: 0)
        let returnedBeforeReaderFinished = Mutex(false)

        let reader = BenchmarkThread.start(name: "held-reader", qos: .userInitiated) {
            protection.withSharedAccess { _ in
                readerEntered.signal()
                let result = writerReturned.wait(timeout: .now() + 2)
                returnedBeforeReaderFinished.withLock { $0 = result == .success }
            }
        }
        let enteredResult = readerEntered.wait(timeout: .now() + 2)
        protection.write(41) { value, newValue in
            value = newValue
        }
        writerReturned.signal()
        reader.join()
        protection.waitForPendingWrites()
        return (
            enteredResult == .success && returnedBeforeReaderFinished.withLock { $0 },
            protection.withSharedAccess { $0 }
        )
    }

    #expect(observation.0)
    #expect(observation.1 == 41)
}
