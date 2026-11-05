import Dispatch
import Synchronization
import Testing

@testable import SyncBench

@Test(arguments: MechanismID.stateProtections)
func exclusiveAndSharedAccess(_ mechanism: MechanismID) async {
    let values = await onBenchmarkThread {
        let protection = makeIntegerProtection(mechanism, initialValue: 5)
        let incremented = protection.withExclusiveAccess { value in
            value &+= 1
            return value
        }
        return (incremented, protection.withSharedAccess { $0 })
    }

    #expect(values.0 == 6)
    #expect(values.1 == 6)
}

@Test(arguments: MechanismID.stateProtections)
func writeIsVisibleAfterWaiting(_ mechanism: MechanismID) async {
    let value = await onBenchmarkThread {
        let protection = makeIntegerProtection(mechanism, initialValue: 0)
        protection.write(41) { value, newValue in
            value = newValue
        }
        protection.waitForPendingWrites()
        return protection.withSharedAccess { $0 }
    }

    #expect(value == 41)
}

@Test(arguments: MechanismID.stateProtections.filter { $0 != .barrierQueueAsyncWrite })
func synchronousWriteFinishesBeforeReturning(_ mechanism: MechanismID) async {
    let finished = await onBenchmarkThread {
        let protection = makeIntegerProtection(mechanism, initialValue: 0)
        let finished = DispatchSemaphore(value: 0)
        protection.write(finished) { value, finished in
            value = 41
            finished.signal()
        }
        return finished.wait(timeout: .now()) == .success
    }

    #expect(finished)
}

@Test(
    .timeLimit(.minutes(1)),
    arguments: MechanismID.stateProtections.filter { $0 != .unsynchronized }
)
func eightThreadsCountExactly(_ mechanism: MechanismID) async {
    let value = await onBenchmarkThread {
        let protection = makeIntegerProtection(mechanism, initialValue: 0)
        let start = ThreadBarrier(parties: 8)
        let threads = (0..<8).map { _ in
            BenchmarkThread.start(name: "protection-count", qos: .userInitiated) {
                start.arriveAndWait()
                for _ in 0..<10_000 {
                    protection.write(1) { value, increment in
                        value &+= increment
                    }
                }
            }
        }

        for thread in threads {
            thread.join()
        }

        protection.waitForPendingWrites()
        return protection.withSharedAccess { $0 }
    }

    #expect(value == 80_000)
}

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
        let protection = BarrierQueueAsyncWriteProtection<Int>(0)
        let log = ThreadLog(batches: 1, readingsPerBatch: 1)

        for newValue in 0..<1_000 {
            protection.write(newValue) { value, newValue in
                value = newValue
            }
        }

        protection.recordExecutorCPU(into: log.executorSlot(batch: 0, reading: 0))
        protection.waitForPendingWrites()
        // Observe completion before a synchronous read could drain the queue itself.
        let readings = log.executorCPUReadings(ofBatch: 0)
        return (protection.withSharedAccess { $0 }, readings)
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
