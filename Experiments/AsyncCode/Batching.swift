import Synchronization

/// Experiment 7B: 100 operations in one `await`, against 100 separate awaits and 100
/// operations under one lock. Each row runs in one detached task. `AsyncCode.init` makes
/// every sub-batch a whole number of groups.
enum Batching {
    static func run(_ block: BlockContext) -> [CheckResult] {
        let operation = block.description.operation
        let total = switch operation {
        case "oneAwaitPerGroup":
            oneAwaitPerGroup(block)
        case "awaitPerOperation":
            awaitPerOperation(block)
        case "oneLockPerGroup":
            oneLockPerGroup(block)
        default:
            preconditionFailure("AsyncCode.init accepts only the operations of the rows table")
        }

        return [AsyncCodeChecks.checkCount(
            operation: operation,
            finalValue: total,
            expected: AsyncCodeChecks.expectedCount(threads: block.description.threads, layout: block.layout),
            block: block.position
        )]
    }

    private static func oneAwaitPerGroup(_ block: BlockContext) -> Int {
        let group = CounterGroupActor()
        let total = Mutex(0)

        _ = block.runInTasks { _, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { slot in slot.store(await group.executorCPU()) },
                runOperations: { _, _, count in
                    for operation in stride(from: 0, to: count, by: AsyncCode.groupSize) {
                        await group.incrementGroup(startingAt: operation)
                    }
                    return 0
                }
            )

            let value = await group.total()
            total.withLock { $0 = value }
        }

        return total.withLock { $0 }
    }

    private static func awaitPerOperation(_ block: BlockContext) -> Int {
        let group = CounterGroupActor()
        let total = Mutex(0)

        _ = block.runInTasks { _, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { slot in slot.store(await group.executorCPU()) },
                runOperations: { _, _, count in
                    for operation in 0..<count {
                        await group.incrementOne(at: operation)
                    }
                    return 0
                }
            )

            let value = await group.total()
            total.withLock { $0 = value }
        }

        return total.withLock { $0 }
    }

    private static func oneLockPerGroup(_ block: BlockContext) -> Int {
        let group = MutexCounterGroup()

        _ = block.runInTasks { _, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { _ in },
                runOperations: { _, _, count in
                    for operation in stride(from: 0, to: count, by: AsyncCode.groupSize) {
                        group.incrementGroup(startingAt: operation)
                    }
                    return 0
                }
            )
        }

        return group.total()
    }
}
