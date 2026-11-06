import Testing

@testable import SyncBench

// Catches a read/modify/write increment that loses updates under contention.
@Test(
    .timeLimit(.minutes(1)),
    arguments: MechanismID.allCases.filter { $0 != .unsynchronized }
)
func concurrentIncrementsAreExact(_ mechanism: MechanismID) async {
    let task = await onBenchmarkThread {
        concurrentIncrements(of: mechanism)
    }
    let values = await task.value

    #expect(values.actual == values.expected)
    if let sum = values.returnedValueSum {
        // The 8,000 returned new values must sum to 1 + ... + 8,000.
        #expect(sum == 32_004_000)
    }
}

private struct IncrementResult: Sendable {
    let actual: Int
    let expected: Int
    let returnedValueSum: Int?
}

private func concurrentIncrements<Integer: SharedInteger>(
    _ integer: Integer
) -> Task<IncrementResult, Never> {
    let start = ThreadBarrier(parties: 4)
    let threads = (0..<4).map { _ in
        BenchmarkThread.start(name: "integer-count", qos: .userInitiated) {
            start.arriveAndWait()
            for _ in 0..<5_000 {
                integer.increment()
            }
        }
    }

    for thread in threads {
        thread.join()
    }

    let finalValue = integer.finalValue()
    return Task.detached {
        IncrementResult(actual: finalValue, expected: 20_000, returnedValueSum: nil)
    }
}

private func concurrentIncrements<Integer: AsyncSharedInteger>(
    _ integer: Integer
) -> Task<IncrementResult, Never> {
    Task.detached {
        let start = TaskBarrier(parties: 8)
        // Detached tasks give every async row the specified background caller path.
        let tasks = (0..<8).map { _ in
            Task.detached {
                await start.arriveAndWait()
                return await BaseComparison.incrementLoopAsync(integer, count: 1_000)
            }
        }

        var sum = 0
        for task in tasks {
            sum += await task.value
        }

        return IncrementResult(
            actual: await integer.finalValue(), expected: 8_000, returnedValueSum: sum
        )
    }
}

private func concurrentIncrements(of mechanism: MechanismID) -> Task<IncrementResult, Never> {
    switch mechanism {
    case .unsynchronized:
        preconditionFailure("The floor requires one thread")
    case .mutex:
        return concurrentIncrements(MutexInteger(0))
    case .osAllocatedUnfairLock:
        return concurrentIncrements(AllocatedUnfairLockInteger(0))
    case .osAllocatedUnfairLockAdaptiveSpin:
        return concurrentIncrements(AdaptiveSpinUnfairLockInteger(0))
    case .osUnfairLock:
        return concurrentIncrements(UnfairLockInteger(0))
    case .nsLock:
        return concurrentIncrements(NSLockInteger(0))
    case .nsRecursiveLock:
        return concurrentIncrements(NSRecursiveLockInteger(0))
    case .pthreadMutex:
        return concurrentIncrements(PthreadMutexInteger(0))
    case .pthreadReadWriteLock:
        return concurrentIncrements(PthreadReadWriteLockInteger(0))
    case .serialQueue:
        return concurrentIncrements(SerialQueueInteger(0))
    case .barrierQueueSyncWrite:
        return concurrentIncrements(BarrierQueueSyncWriteInteger(0))
    case .barrierQueueAsyncWrite:
        return concurrentIncrements(BarrierQueueAsyncWriteInteger(0))
    case .dispatchSemaphore:
        return concurrentIncrements(DispatchSemaphoreInteger(0))
    case .objcSync:
        return concurrentIncrements(ObjcSyncInteger(0))
    case .actor:
        return concurrentIncrements(ActorInteger(0))
    case .mainActor:
        return concurrentIncrements(MainActorInteger.makeOnMainThread(0))
    case .atomic:
        return concurrentIncrements(AtomicInteger(0))
    case .atomicRelaxed:
        return concurrentIncrements(RelaxedAtomicInteger(0))
    case .managedAtomic:
        return concurrentIncrements(ManagedAtomicInteger(0))
    case .managedAtomicRelaxed:
        return concurrentIncrements(RelaxedManagedAtomicInteger(0))
    }
}
