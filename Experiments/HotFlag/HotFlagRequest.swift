enum HotFlagRequest {
    static let mechanisms: Set<String> = [
        "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
        "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
        "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
        "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync", "atomic",
        "managedAtomic", "atomicRelaxed", "managedAtomicRelaxed",
    ]

    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()
        guard request.variant == "default" else {
            throw RequestError(message: "variant must be default for hotFlag")
        }
        guard request.tunables.threads == 1 else {
            throw RequestError(message: "threads must be 1 for hotFlag")
        }
        try request.requireUniqueSelection(
            mechanisms: mechanisms,
            operations: Set(HotFlag.Operation.allCases.map(\.rawValue))
        )

        var blocks: [BlockDescription] = []
        for mechanism in request.mechanisms {
            let count = request.operationsPerBatch(for: mechanism)
            let layout = try request.validatedLayout(operationsPerBatch: count, threads: 1)
            if request.operations.contains("readGroups") {
                guard layout.operationsPerSubBatch.isMultiple(of: HotFlag.groupSize) else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] must hold whole 100-read groups per sub-batch")
                }
                let (samples, countOverflow) = layout.measuredBatches.multipliedReportingOverflow(by: count / HotFlag.groupSize)
                let (_, byteOverflow) = samples.multipliedReportingOverflow(by: MemoryLayout<UInt64>.stride)
                guard !countOverflow, !byteOverflow else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] group sample storage overflow")
                }
            }
            for operation in request.operations {
                blocks.append(BlockDescription(
                    mechanism: mechanism,
                    operation: operation,
                    threads: 1,
                    qos: request.tunables.qos,
                    operationsPerBatch: count
                ))
            }
        }
        return blocks
    }
}
