/// Actors, the main actor and locks called from async code (experiment 7).
struct AsyncCode: Experiment {
    /// Variant → operation → the mechanisms measured with it. Python mirrors this table (Task 8).
    static let rows: [String: [String: [String]]] = [
        "callerPaths": [
            "onActor": ["actor"],
            "fromBackgroundTask": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
            "fromManyTasks": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
            "fromMainActor": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
            "toMainActor": ["mainActor"],
        ],
        "batching": [
            "oneAwaitPerGroup": ["actor"],
            "awaitPerOperation": ["actor"],
            "oneLockPerGroup": ["mutex"],
        ],
        "isolationSettings": [
            "callFromMainActor": ["templateDefaults", "swift6Language", "concurrentAttribute"],
        ],
    ]

    /// Tasks in path "fromManyTasks".
    static let manyTasks = 50

    /// Operations per await or per lock in experiment 7B.
    static let groupSize = 100

    let blocks: [BlockDescription]

    /// Present whenever path "fromManyTasks" is requested.
    private let asyncCode: AsyncCodeTunables?

    init(request: RunRequest) throws(RequestError) {
        try request.validate()

        guard let operationsTable = Self.rows[request.variant] else {
            throw RequestError(message: "variant is unknown: \(request.variant)")
        }

        guard request.tunables.threads == 1 else {
            throw RequestError(message: "threads must be 1 for asyncCode")
        }

        guard !request.mechanisms.isEmpty, Set(request.mechanisms).count == request.mechanisms.count else {
            throw RequestError(message: "mechanisms must be nonempty and unique")
        }

        guard !request.operations.isEmpty, Set(request.operations).count == request.operations.count else {
            throw RequestError(message: "operations must be nonempty and unique")
        }

        var descriptions: [BlockDescription] = []
        for mechanism in request.mechanisms {
            for operation in request.operations where operationsTable[operation]?.contains(mechanism) == true {
                descriptions.append(BlockDescription(
                    mechanism: mechanism,
                    operation: operation,
                    threads: operation == "fromManyTasks" ? Self.manyTasks : 1,
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
            where !(operations / request.tunables.subBatches).isMultiple(of: Self.groupSize) {
                throw RequestError(
                    message: "operationsPerBatch: \(key) must be a multiple of subBatches × \(Self.groupSize)"
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
            let (_, totalOverflow) = calls.multipliedReportingOverflow(by: Self.manyTasks)
            let (samples, samplesOverflow) = asyncCode.callsPerTask.multipliedReportingOverflow(by: Self.manyTasks)
            let (_, bytesOverflow) = samples.multipliedReportingOverflow(by: MemoryLayout<UInt64>.stride)

            guard !callsOverflow, !totalOverflow, !samplesOverflow, !bytesOverflow else {
                throw RequestError(message: "asyncCode calls per task overflow")
            }
        }

        // Layout validation proves threads × batches × operations fits Int.
        for description in descriptions {
            try BatchLayout(
                warmupBatches: request.tunables.warmupBatches,
                measuredBatches: request.tunables.measuredBatches,
                operationsPerBatch: description.operationsPerBatch,
                subBatches: request.tunables.subBatches
            ).validate(threads: description.threads)
        }

        blocks = descriptions
        asyncCode = request.tunables.asyncCode
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        switch block.description.operation {
        case "oneAwaitPerGroup", "awaitPerOperation", "oneLockPerGroup":
            Batching.run(block)
        case "callFromMainActor":
            IsolationSettings.run(block)
        default:
            CallerPaths.run(block, asyncCode: asyncCode)
        }
    }
}
