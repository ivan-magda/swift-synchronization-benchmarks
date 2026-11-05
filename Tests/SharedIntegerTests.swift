import Testing

@testable import SyncBench

// Catches a dropped write or an increment that replaces rather than adds to state.
@Test(arguments: MechanismID.allCases)
func writeReadIncrement(_ mechanism: MechanismID) async {
    let task = await onBenchmarkThread {
        SharedIntegers.visit(mechanism, initialValue: 0, with: WriteReadIncrementVisitor())
    }
    let values = await task.value

    #expect(values.0 == 7)
    #expect(values.1 == 10)
}

// Catches a read/modify/write increment that loses updates under contention.
@Test(
    .timeLimit(.minutes(1)),
    arguments: MechanismID.allCases.filter { $0 != .unsynchronized }
)
func concurrentIncrementsAreExact(_ mechanism: MechanismID) async {
    let task = await onBenchmarkThread {
        SharedIntegers.visit(mechanism, initialValue: 0, with: ConcurrentIncrementsVisitor())
    }
    let values = await task.value

    #expect(values.actual == values.expected)
}

// Catches missing CPU capture on the executor that owns the integer.
@Test(arguments: [MechanismID.actor, .mainActor])
func executorCPUIsRead(_ mechanism: MechanismID) async {
    let task = await onBenchmarkThread {
        SharedIntegers.visit(mechanism, initialValue: 0, with: ExecutorCPUVisitor())
    }

    #expect(await task.value >= 0)
}

private struct WriteReadIncrementVisitor: SharedIntegerVisitor {
    func visitSynchronous<Integer: SharedInteger>(_ integer: Integer) -> Task<(Int, Int), Never> {
        integer.write(7)
        integer.waitForPendingWrites()
        let readValue = integer.read()

        for _ in 0..<3 {
            integer.increment()
        }
        let finalValue = integer.finalValue()
        return Task.detached { (readValue, finalValue) }
    }

    func visitAsynchronous<Integer: AsyncSharedInteger>(_ integer: Integer) -> Task<(Int, Int), Never> {
        Task.detached {
            await integer.write(7)
            let readValue = await integer.read()

            for _ in 0..<3 {
                await integer.increment()
            }
            return (readValue, await integer.finalValue())
        }
    }
}

private struct IncrementResult: Sendable {
    let actual: Int
    let expected: Int
}

private struct ConcurrentIncrementsVisitor: SharedIntegerVisitor {
    func visitSynchronous<Integer: SharedInteger>(_ integer: Integer) -> Task<IncrementResult, Never> {
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
        return Task.detached { IncrementResult(actual: finalValue, expected: 20_000) }
    }

    func visitAsynchronous<Integer: AsyncSharedInteger>(_ integer: Integer) -> Task<IncrementResult, Never> {
        Task.detached {
            let start = TaskBarrier(parties: 8)
            // Detached tasks give every async row the specified background caller path.
            let tasks = (0..<8).map { _ in
                Task.detached {
                    await start.arriveAndWait()
                    for _ in 0..<1_000 {
                        await integer.increment()
                    }
                }
            }

            for task in tasks {
                await task.value
            }

            return IncrementResult(actual: await integer.finalValue(), expected: 8_000)
        }
    }
}

private struct ExecutorCPUVisitor: SharedIntegerVisitor {
    func visitSynchronous<Integer: SharedInteger>(_ integer: Integer) -> Task<Int, Never> {
        preconditionFailure("Executor CPU tests require an asynchronous integer")
    }

    func visitAsynchronous<Integer: AsyncSharedInteger>(_ integer: Integer) -> Task<Int, Never> {
        Task.detached {
            await integer.executorCPU()
        }
    }
}
