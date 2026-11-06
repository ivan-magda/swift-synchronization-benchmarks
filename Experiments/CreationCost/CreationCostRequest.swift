enum CreationCostRequest {
    static let mechanisms: Set<String> = [
        "unsynchronized", "mutex", "osAllocatedUnfairLock", "osUnfairLock",
        "nsLock", "nsRecursiveLock", "pthreadMutex", "pthreadReadWriteLock",
        "serialQueue", "barrierQueueSyncWrite", "dispatchSemaphore", "actor",
        "mainActor", "atomic", "managedAtomic",
    ]

    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()
        guard request.variant == "default" else {
            throw RequestError(message: "variant must be default for creationCost")
        }
        guard request.tunables.threads == 1 else {
            throw RequestError(message: "threads must be 1 for creationCost")
        }
        try request.requireUniqueSelection(mechanisms: mechanisms, operations: ["create", "destroy"])
        var blocks: [BlockDescription] = []
        for mechanism in request.mechanisms {
            let count = request.operationsPerBatch(for: mechanism)
            let layout = try request.validatedLayout(operationsPerBatch: count, threads: 1)
            let (objectBytes, objectOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<AnyObject>.stride)
            let (_, totalOverflow) = objectBytes.multipliedReportingOverflow(by: layout.totalBatches)
            guard !objectOverflow, !totalOverflow else {
                throw RequestError(message: "operationsPerBatch[\(mechanism)] object storage overflow")
            }
            for operation in request.operations {
                blocks.append(BlockDescription(mechanism: mechanism, operation: operation, threads: 1,
                                               qos: request.tunables.qos, operationsPerBatch: count))
            }
        }
        return blocks
    }
}
