import Darwin
import Synchronization

/// A low-priority holder, CPU load, and a main-thread lock attempt (experiment 8B).
struct PriorityInversion: Experiment {
    let blocks: [BlockDescription]
    private let tunables: PriorityInversionTunables

    init(request: RunRequest) throws(RequestError) {
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
            throw RequestError(message: "priorityInversion.mainDelayMicroseconds must be at most 1000000")
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
            throw RequestError(message: "priorityInversion.pauseMilliseconds must fit useconds_t microseconds")
        }
        let mechanisms = Set(ContendedLocks.mechanisms.map(\.rawValue))
        guard !request.mechanisms.isEmpty,
            Set(request.mechanisms).count == request.mechanisms.count,
            request.mechanisms.allSatisfy({ mechanisms.contains($0) })
        else {
            throw RequestError(message: "mechanisms must be nonempty, unique priorityInversion mechanisms")
        }
        let holderQoS: [String: QoS] = [
            "utilityHolder": .utility,
            "backgroundHolder": .background
        ]
        guard !request.operations.isEmpty,
            Set(request.operations).count == request.operations.count,
            request.operations.allSatisfy({ holderQoS[$0] != nil })
        else {
            throw RequestError(message: "operations must be nonempty, unique utilityHolder or backgroundHolder")
        }
        blocks = request.mechanisms.flatMap { mechanism in
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
        self.tunables = tunables
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let work = HolderWork(
            iterations: tunables.holderWorkIterations,
            expectedResult: referenceLoop(iterations: tunables.holderWorkIterations)
        )
        let lock = ContendedLocks.make(
            MechanismID(rawValue: block.description.mechanism)!,
            holderQoS: block.description.qos
        )
        let timestamps = HolderTimestamps()
        let mainSide = MainSideRecord()
        let loadThreads = LoadThreads(count: PhoneFacts.read().cpuCount, qos: tunables.loadQoS)
        let holder = HolderThread(
            qos: block.description.qos,
            lock: lock,
            work: work,
            timestamps: timestamps
        )
        let runner = TrialRunner(
            lock: lock,
            holder: holder,
            timestamps: timestamps,
            tunables: tunables,
            loadThreads: loadThreads,
            acquireTimeoutTicks: TrialDeadline.ticks(nanoseconds: 2_000_000_000),
            mainSide: mainSide
        )
        let result = Mutex<(trials: [TrialLine], timedOut: Bool)>(([], false))
        _ = block.runOnThreads(recording: .samplesOnly, workerQoS: block.request.tunables.qos) { _, _, _ in
            let completed = runner.runTrials(block: block.position)
            result.withLock { $0 = completed }
        }
        let completed = result.withLock { $0 }
        block.appendTrials(completed.trials)
        holder.shutDown()
        loadThreads.shutDown()
        return [
            PriorityInversionChecks.check(
                operation: block.description.operation,
                trials: completed.trials,
                timedOut: completed.timedOut,
                block: block.position
            )
        ]
    }
}
