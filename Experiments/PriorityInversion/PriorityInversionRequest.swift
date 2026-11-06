import Darwin

enum PriorityInversionRequest {
    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()

        guard request.variant == "default" else {
            throw RequestError(message: "variant must be default for priorityInversion")
        }

        guard request.tunables.threads == 1 else {
            throw RequestError(message: "threads must be 1 for priorityInversion")
        }

        guard let tunables = request.tunables.priorityInversion else {
            throw RequestError(message: "priorityInversion tunables are required")
        }

        guard tunables.mainDelayMicroseconds <= 1_000_000 else {
            throw RequestError(
                message: "priorityInversion.mainDelayMicroseconds must be at most 1000000"
            )
        }

        try TrialDeadline.validateDuration(
            tunables.loadMilliseconds,
            nanosecondsPerUnit: 1_000_000,
            field: "loadMilliseconds"
        )
        try TrialDeadline.validateDuration(
            tunables.mainDelayMicroseconds,
            nanosecondsPerUnit: 1_000,
            field: "mainDelayMicroseconds"
        )

        guard UInt64(tunables.pauseMilliseconds) <= UInt64(useconds_t.max) / 1_000 else {
            throw RequestError(
                message: "priorityInversion.pauseMilliseconds must fit useconds_t microseconds"
            )
        }

        let mechanisms = Set(ContendedLocks.mechanisms.map(\.rawValue))
        guard !request.mechanisms.isEmpty,
            Set(request.mechanisms).count == request.mechanisms.count,
            request.mechanisms.allSatisfy({ mechanisms.contains($0) })
        else {
            throw RequestError(
                message: "mechanisms must be nonempty, unique priorityInversion mechanisms"
            )
        }

        let holderQoS: [String: QoS] = [
            "utilityHolder": .utility,
            "backgroundHolder": .background
        ]

        guard !request.operations.isEmpty,
            Set(request.operations).count == request.operations.count,
            request.operations.allSatisfy({ holderQoS[$0] != nil })
        else {
            throw RequestError(
                message: "operations must be nonempty, unique utilityHolder or backgroundHolder"
            )
        }

        return request.mechanisms.flatMap { mechanism in
            request.operations.map { operation in
                BlockDescription(
                    mechanism: mechanism,
                    operation: operation,
                    threads: 1,
                    qos: holderQoS[operation]!,
                    operationsPerBatch: request.operationsPerBatch(for: mechanism)
                )
            }
        }
    }
}
