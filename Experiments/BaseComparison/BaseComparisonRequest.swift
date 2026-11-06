enum BaseComparisonRequest {
    private static let threadsByVariant = [
        "oneThread": 1,
        "twoThreads": 2,
        "sixThreads": 6,
        "twelveThreads": 12,
    ]

    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()

        guard let threads = threadsByVariant[request.variant] else {
            throw RequestError(message: "variant is unknown: \(request.variant)")
        }

        guard request.tunables.threads == threads else {
            throw RequestError(message: "threads must match variant \(request.variant)")
        }

        try request.requireUniqueSelection(
            mechanisms: Set(MechanismID.allCases.map(\.rawValue)),
            operations: Set(BaseComparison.Operation.allCases.map(\.rawValue))
        )

        guard threads == 1 || !request.mechanisms.contains(MechanismID.unsynchronized.rawValue) else {
            throw RequestError(message: "unsynchronized requires one thread in mechanisms")
        }

        var descriptions: [BlockDescription] = []
        for mechanism in request.mechanisms {
            let operationsPerBatch = request.operationsPerBatch(for: mechanism)
            let layout = try request.validatedLayout(
                operationsPerBatch: operationsPerBatch,
                threads: threads
            )

            // Layout validation proves cumulative per-thread and aggregate work fit Int.
            let operationsPerThread = layout.operationsPerWorker

            if request.operations.contains(BaseComparison.Operation.increment.rawValue),
                mechanism == MechanismID.actor.rawValue || mechanism == MechanismID.mainActor.rawValue
            {
                guard BaseComparisonChecks.incrementSum(totalOperations: threads * operationsPerThread) != nil else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] increment sum overflow")
                }
            }

            if request.operations.contains(BaseComparison.Operation.read.rawValue) {
                let (_, overflow) = BaseComparison.valueForReads.multipliedReportingOverflow(
                    by: operationsPerBatch
                )
                guard !overflow else {
                    throw RequestError(message: "operationsPerBatch[\(mechanism)] read sum overflow")
                }
            }

            if request.operations.contains(BaseComparison.Operation.write.rawValue) {
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
                        operationsPerBatch: operationsPerBatch
                    )
                )
            }
        }

        return descriptions
    }
}
