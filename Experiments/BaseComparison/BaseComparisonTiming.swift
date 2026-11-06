import Synchronization

@inline(__always)
func measure(
    _ integer: some SharedInteger,
    _ operation: BaseComparison.Operation,
    _ block: BlockContext
) -> [CheckResult] {
    BaseComparisonTiming(block: block, operation: operation).measure(integer)
}

@inline(__always)
func measureAsync(
    _ integer: some AsyncSharedInteger,
    _ operation: BaseComparison.Operation,
    _ block: BlockContext
) -> [CheckResult] {
    BaseComparisonTiming(block: block, operation: operation).measureAsync(integer)
}

/// Keep the timer in the worker closure and retain its block/operation capture
/// layout. Escaping operation callbacks add indirect calls inside timed batches.
private struct BaseComparisonTiming {
    let block: BlockContext
    let operation: BaseComparison.Operation

    func measure<Integer: SharedInteger>(_ integer: Integer) -> [CheckResult] {
        let logs = block.runOnThreads { thread, barrier, log in
            BatchTimer.timeBatches(
                layout: block.layout,
                barrier: barrier,
                log: log,
                // Reads execute synchronously on the caller; queue probes/drains would
                // inject synthetic barriers into their timing. Final correctness still
                // uses finalValue() after every worker's timed work has finished.
                recordExecutorCPU: operation == .read ? { _ in } : { integer.recordExecutorCPU(into: $0) },
                waitForPendingWrites: operation == .read ? {} : { integer.waitForPendingWrites() },
                runOperations: { batch, subBatch, count in
                    switch operation {
                    case .read:
                        return BaseComparison.readLoop(integer, count: count)
                    case .write:
                        BaseComparison.writeLoop(
                            integer,
                            count: count,
                            firstValue: BaseComparisonChecks.firstValue(
                                thread: thread,
                                batch: batch,
                                subBatch: subBatch,
                                count: count,
                                block: block
                            )
                        )
                    case .increment:
                        BaseComparison.incrementLoop(integer, count: count)
                    }
                    return 0
                }
            )
        }

        return BaseComparisonChecks.checks(
            operation: operation,
            finalValue: integer.finalValue(),
            logs: logs,
            block: block
        )
    }

    /// Actor rows use detached background callers, awaiting one operation at a time.
    func measureAsync<Integer: AsyncSharedInteger>(_ integer: Integer) -> [CheckResult] {
        let finalValue = Mutex(0)
        let logs = block.runInTasks { thread, barrier, log in
            await BatchTimer.timeBatches(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { slot in slot.store(await integer.executorCPU()) },
                runOperations: { batch, subBatch, count in
                    switch operation {
                    case .read:
                        return await BaseComparison.readLoopAsync(integer, count: count)
                    case .write:
                        await BaseComparison.writeLoopAsync(
                            integer,
                            count: count,
                            firstValue: BaseComparisonChecks.firstValue(
                                thread: thread,
                                batch: batch,
                                subBatch: subBatch,
                                count: count,
                                block: block
                            )
                        )
                    case .increment:
                        return await BaseComparison.incrementLoopAsync(integer, count: count)
                    }
                    return 0
                }
            )

            // Every worker's timed operations have ended before the final read.
            await barrier.arriveAndWait()

            if thread == 0 {
                let value = await integer.finalValue()
                finalValue.withLock { $0 = value }
            }
        }

        let value = finalValue.withLock { $0 }
        if operation == .increment {
            return [
                BaseComparisonChecks.checkAsyncIncrements(
                    finalValue: value,
                    batchSums: logs.checkValues(batches: block.layout.totalBatches),
                    threads: block.description.threads,
                    operationsPerThread: block.layout.operationsPerWorker,
                    block: block.position
                )
            ]
        }
        return BaseComparisonChecks.checks(
            operation: operation,
            finalValue: value,
            logs: logs,
            block: block
        )
    }
}
