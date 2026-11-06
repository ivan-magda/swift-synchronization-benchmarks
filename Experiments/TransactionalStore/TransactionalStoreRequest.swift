enum TransactionalStoreRequest {
    static let mechanisms: Set<String> = [
        "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
        "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
        "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
        "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync",
    ]

    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()
        guard request.variant == "default" else {
            throw RequestError(message: "variant must be default for transactionalStore")
        }
        guard request.tunables.threads == 6 else {
            throw RequestError(message: "threads must be 6 for transactionalStore")
        }
        try request.requireUniqueSelection(mechanisms: mechanisms,
            operations: Set(TransactionalStore.Operation.allCases.map(\.rawValue)))
        var blocks: [BlockDescription] = []
        for mechanism in request.mechanisms {
            let count = request.operationsPerBatch(for: mechanism)
            let layout = try request.validatedLayout(operationsPerBatch: count, threads: 6)
            guard count.isMultiple(of: 5_000) else {
                throw RequestError(message: "operationsPerBatch[\(mechanism)] must be a multiple of 5000")
            }
            // The largest representation has one run per read. This conservative
            // bound covers the flat indexes, ranges, completion ticks and samples.
            let (transactions, transactionOverflow) = count.multipliedReportingOverflow(by: layout.totalBatches)
            let (bytes, byteOverflow) = transactions.multipliedReportingOverflow(by: 128)
            let (_, aggregateOverflow) = bytes.multipliedReportingOverflow(by: 6)
            let (writes, writeOverflow) = (transactions / 50).multipliedReportingOverflow(by: 6)
            let (readValue, valueOverflow) = writes.multipliedReportingOverflow(by: 20)
            let (_, sumOverflow) = readValue.multipliedReportingOverflow(by: count - count / 50)
            guard !transactionOverflow, !byteOverflow, !aggregateOverflow,
                !writeOverflow, !valueOverflow, !sumOverflow else {
                throw RequestError(message: "operationsPerBatch[\(mechanism)] transactional storage or sum overflow")
            }
            for operation in request.operations {
                blocks.append(BlockDescription(mechanism: mechanism, operation: operation,
                    threads: 6, qos: request.tunables.qos, operationsPerBatch: count))
            }
        }
        return blocks
    }
}
