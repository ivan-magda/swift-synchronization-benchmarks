enum AsyncCodeRequest {
    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()

        guard let mechanismsByOperation = AsyncCode.rows[request.variant] else {
            throw RequestError(message: "variant is unknown: \(request.variant)")
        }

        guard request.tunables.threads == 1 else {
            throw RequestError(message: "threads must be 1 for asyncCode")
        }

        try request.requireUniqueSelection(mechanisms: nil, operations: nil)

        var descriptions: [BlockDescription] = []
        for mechanism in request.mechanisms {
            for operation in request.operations where mechanismsByOperation[operation]?.contains(mechanism) == true {
                descriptions.append(BlockDescription(
                    mechanism: mechanism,
                    operation: operation,
                    threads: operation == "fromManyTasks" ? AsyncCode.manyTasks : 1,
                    qos: request.tunables.qos,
                    operationsPerBatch: request.operationsPerBatch(for: mechanism)
                ))
            }
        }

        for mechanism in request.mechanisms where !descriptions.contains(where: { $0.mechanism == mechanism }) {
            throw RequestError(
                message: "mechanisms: \(mechanism) has no requested operation in variant \(request.variant)"
            )
        }

        for operation in request.operations where !descriptions.contains(where: { $0.operation == operation }) {
            throw RequestError(
                message: "operations: \(operation) has no requested mechanism in variant \(request.variant)"
            )
        }

        if request.variant == "batching" {
            // Every sub-batch must hold whole groups. `validate()` made each value a multiple of subBatches.
            for (key, operations) in request.tunables.operationsPerBatch.sorted(by: { $0.key < $1.key })
            where !(operations / request.tunables.subBatches).isMultiple(of: AsyncCode.groupSize) {
                throw RequestError(
                    message: "operationsPerBatch: \(key) must be a multiple of subBatches × \(AsyncCode.groupSize)"
                )
            }
        }

        if request.operations.contains("fromManyTasks") {
            guard let asyncCode = request.tunables.asyncCode else {
                throw RequestError(message: "asyncCode is required for fromManyTasks")
            }

            // Each task makes warm-up and timed calls; the timed ones fill a UInt64 buffer.
            let (calls, callsOverflow) = asyncCode.warmupCallsPerTask.addingReportingOverflow(
                asyncCode.callsPerTask
            )
            let (_, totalOverflow) = calls.multipliedReportingOverflow(by: AsyncCode.manyTasks)
            let (samples, samplesOverflow) = asyncCode.callsPerTask.multipliedReportingOverflow(
                by: AsyncCode.manyTasks
            )
            let (_, bytesOverflow) = samples.multipliedReportingOverflow(by: MemoryLayout<UInt64>.stride)

            guard !callsOverflow, !totalOverflow, !samplesOverflow, !bytesOverflow else {
                throw RequestError(message: "asyncCode calls per task overflow")
            }
        }

        // Layout validation proves threads × batches × operations fits Int.
        for description in descriptions {
            _ = try request.validatedLayout(
                operationsPerBatch: description.operationsPerBatch,
                threads: description.threads
            )
        }

        return descriptions
    }
}
