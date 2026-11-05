import Testing

@testable import SyncBench

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
