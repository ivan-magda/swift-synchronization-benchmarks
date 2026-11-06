import Synchronization

/// Threads read, write and increment one shared integer (experiment 1).
struct BaseComparison: Experiment {
    enum Operation: String, CaseIterable, Sendable {
        case read
        case write
        case increment
    }

    static let threadsByVariant = [
        "oneThread": 1,
        "twoThreads": 2,
        "sixThreads": 6,
        "twelveThreads": 12,
    ]

    static let valueForReads = 42

    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        try request.validate()

        guard let threads = Self.threadsByVariant[request.variant] else {
            throw RequestError(message: "variant is unknown: \(request.variant)")
        }

        guard request.tunables.threads == threads else {
            throw RequestError(message: "threads must match variant \(request.variant)")
        }

        guard !request.mechanisms.isEmpty,
            Set(request.mechanisms).count == request.mechanisms.count,
            request.mechanisms.allSatisfy({ MechanismID(rawValue: $0) != nil })
        else {
            throw RequestError(message: "mechanisms must be nonempty, unique MechanismID values")
        }

        guard threads == 1 || !request.mechanisms.contains(MechanismID.unsynchronized.rawValue) else {
            throw RequestError(message: "unsynchronized requires one thread in mechanisms")
        }

        guard !request.operations.isEmpty,
            Set(request.operations).count == request.operations.count,
            request.operations.allSatisfy({ Operation(rawValue: $0) != nil })
        else {
            throw RequestError(message: "operations must be nonempty, unique Operation values")
        }

        var descriptions: [BlockDescription] = []
        for mechanism in request.mechanisms {
            let operations = request.operationsPerBatch(for: mechanism)
            let layout = BatchLayout(
                warmupBatches: request.tunables.warmupBatches,
                measuredBatches: request.tunables.measuredBatches,
                operationsPerBatch: operations,
                subBatches: request.tunables.subBatches
            )
            try layout.validate(threads: threads)

            // Layout validation proves cumulative per-thread and aggregate work fit Int.
            let operationsPerThread = layout.totalBatches * operations

            if request.operations.contains(Operation.increment.rawValue),
                mechanism == MechanismID.actor.rawValue || mechanism == MechanismID.mainActor.rawValue
            {
                guard BaseComparisonChecks.incrementSum(totalOperations: threads * operationsPerThread) != nil else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] increment sum overflow")
                }
            }

            if request.operations.contains(Operation.read.rawValue) {
                let (_, overflow) = Self.valueForReads.multipliedReportingOverflow(by: operations)
                guard !overflow else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] read sum overflow")
                }
            }

            if request.operations.contains(Operation.write.rawValue) {
                let (base, baseOverflow) = (threads - 1).multipliedReportingOverflow(
                    by: BaseComparisonChecks.threadStride
                )
                let (_, lastOverflow) = base.addingReportingOverflow(operationsPerThread)
                guard !baseOverflow, !lastOverflow else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] write value overflow")
                }
            }

            for operation in request.operations {
                descriptions.append(
                    BlockDescription(
                        mechanism: mechanism,
                        operation: operation,
                        threads: threads,
                        qos: request.tunables.qos,
                        operationsPerBatch: operations
                    )
                )
            }
        }

        blocks = descriptions
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let operation = Operation(rawValue: block.description.operation)!

        return SharedIntegers.visit(
            MechanismID(rawValue: block.description.mechanism)!,
            initialValue: operation == .read ? Self.valueForReads : 0,
            with: BaseComparisonVisitor(block: block, operation: operation)
        )
    }
}

private struct BaseComparisonVisitor: SharedIntegerVisitor {
    let block: BlockContext
    let operation: BaseComparison.Operation

    func visitSynchronous<Integer: SharedInteger>(_ integer: Integer) -> [CheckResult] {
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
                        return BaseComparisonLoops.readLoop(integer, count: count)
                    case .write:
                        BaseComparisonLoops.writeLoop(
                            integer,
                            count: count,
                            firstValue: firstValue(
                                thread: thread,
                                batch: batch,
                                subBatch: subBatch,
                                count: count
                            )
                        )
                    case .increment:
                        BaseComparisonLoops.incrementLoop(integer, count: count)
                    }
                    return 0
                }
            )
        }

        return checks(finalValue: integer.finalValue(), logs: logs)
    }

    func visitAsynchronous<Integer: AsyncSharedInteger>(_ integer: Integer) -> [CheckResult] {
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
                        return await BaseComparisonLoops.readLoopAsync(integer, count: count)
                    case .write:
                        await BaseComparisonLoops.writeLoopAsync(
                            integer,
                            count: count,
                            firstValue: firstValue(
                                thread: thread,
                                batch: batch,
                                subBatch: subBatch,
                                count: count
                            )
                        )
                    case .increment:
                        return await BaseComparisonLoops.incrementLoopAsync(integer, count: count)
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
                    batchSums: logs.map { log in
                        (0..<block.layout.totalBatches).map { log.checkValue(ofBatch: $0) }
                    },
                    threads: block.description.threads,
                    operationsPerThread: block.layout.totalBatches * block.layout.operationsPerBatch,
                    block: block.position
                )
            ]
        }
        return checks(finalValue: value, logs: logs)
    }

    private func firstValue(thread: Int, batch: Int, subBatch: Int, count: Int) -> Int {
        BaseComparisonChecks.valueWritten(
            byThread: thread,
            operation: batch * block.layout.operationsPerBatch + subBatch * count
        )
    }

    private func checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult] {
        let operationsPerThread = block.layout.totalBatches * block.layout.operationsPerBatch

        switch operation {
        case .read:
            return [
                BaseComparisonChecks.checkReads(
                    finalValue: finalValue,
                    batchSums: logs.map { log in
                        (0..<block.layout.totalBatches).map { log.checkValue(ofBatch: $0) }
                    },
                    operationsPerBatch: block.layout.operationsPerBatch,
                    block: block.position
                )
            ]
        case .write:
            return [
                BaseComparisonChecks.checkWrites(
                    finalValue: finalValue,
                    threads: block.description.threads,
                    operationsPerThread: operationsPerThread,
                    block: block.position
                )
            ]
        case .increment:
            return [
                BaseComparisonChecks.checkIncrements(
                    finalValue: finalValue,
                    threads: block.description.threads,
                    operationsPerThread: operationsPerThread,
                    block: block.position
                )
            ]
        }
    }
}
