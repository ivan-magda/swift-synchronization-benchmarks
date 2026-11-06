enum RequestRegistryRequest {
    static let mechanisms: Set<String> = [
        "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
        "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
        "serialQueue", "dispatchSemaphore", "objcSync",
    ]

    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()
        guard let registry = request.tunables.requestRegistry else {
            throw RequestError(message: "requestRegistry tunables are required")
        }
        guard request.variant == "normal" || request.variant == "burst" else {
            throw RequestError(message: "variant must be normal or burst for requestRegistry")
        }
        guard request.variant == "normal" ? registry.pauseMicroseconds >= 1 : registry.pauseMicroseconds == 0 else {
            throw RequestError(message: "requestRegistry.pauseMicroseconds must be positive for normal and zero for burst")
        }
        guard [4, 8].contains(request.tunables.threads) else {
            throw RequestError(message: "threads must be 4 or 8 for requestRegistry")
        }
        try request.requireUniqueSelection(mechanisms: mechanisms, operations: ["addAndRemove"])
        let (perThread, perThreadOverflow) = registry.inFlightPerThread.addingReportingOverflow(1)
        let (downloads, countOverflow) = request.tunables.threads.multipliedReportingOverflow(by: perThread)
        let (_, storageOverflow) = downloads.multipliedReportingOverflow(by: MemoryLayout<Download>.stride)
        guard !perThreadOverflow, !countOverflow, !storageOverflow else {
            throw RequestError(message: "requestRegistry.inFlightPerThread storage overflow")
        }
        var blocks: [BlockDescription] = []
        for mechanism in request.mechanisms {
            let count = request.operationsPerBatch(for: mechanism)
            let layout = try request.validatedLayout(operationsPerBatch: count, threads: request.tunables.threads)
            guard layout.operationsPerSubBatch.isMultiple(of: 2) else {
                throw RequestError(message: "operationsPerBatch[\(mechanism)] must be even per sub-batch")
            }
            for (field, interval) in [("sampleEvery", registry.sampleEvery), ("cancelAllEvery", registry.cancelAllEvery)] {
                guard layout.operationsPerSubBatch.isMultiple(of: interval) else {
                    throw RequestError(message: "requestRegistry.\(field) must divide operationsPerBatch per sub-batch")
                }
                let (samples, countOverflow) = layout.measuredBatches.multipliedReportingOverflow(by: count / interval)
                let (_, sampleOverflow) = samples.multipliedReportingOverflow(by: MemoryLayout<UInt64>.stride)
                guard !countOverflow, !sampleOverflow else {
                    throw RequestError(message: "requestRegistry.\(field) sample storage overflow")
                }
            }
            let (operations, operationOverflow) = layout.totalBatches.multipliedReportingOverflow(by: count)
            let (added, addedOverflow) = (operations / 2).addingReportingOverflow(registry.inFlightPerThread)
            let (_, totalOverflow) = added.multipliedReportingOverflow(by: request.tunables.threads)
            guard !operationOverflow, !addedOverflow, !totalOverflow else {
                throw RequestError(message: "requestRegistry added count overflow")
            }
            blocks.append(BlockDescription(mechanism: mechanism, operation: "addAndRemove",
                threads: request.tunables.threads, qos: request.tunables.qos, operationsPerBatch: count))
        }
        return blocks
    }
}
