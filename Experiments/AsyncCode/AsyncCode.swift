/// Experiment 7: actors, the main actor and locks called from async code.
///
/// 7A: what does one increment cost along five caller paths: already on the actor,
/// a background task, 50 competing tasks, the main actor, and a call to the main actor?
/// 7B: how do 100 operations in one await compare with separate awaits or one lock?
/// 7C: how do template defaults, Swift 6 settings and @concurrent change calls from
/// the main actor to nonisolated async work?
///
/// The rows below select a concrete path. Each path shows its measured loop;
/// README.md explains timing, correctness checks and compiler constraints.
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
        blocks = try AsyncCodeRequest.blocks(for: request)
        asyncCode = request.tunables.asyncCode
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let finalValue: Int
        switch (block.description.operation, block.description.mechanism) {
        case ("onActor", "actor"):
            finalValue = CallerPaths.onActor(block, counter: CounterActor())
        case ("fromBackgroundTask", "actor"):
            finalValue = CallerPaths.fromBackgroundTask(block, counter: CounterActor())
        case ("fromBackgroundTask", "mutex"):
            finalValue = CallerPaths.fromBackgroundTask(block, counter: MutexCounter())
        case ("fromBackgroundTask", "osAllocatedUnfairLock"):
            finalValue = CallerPaths.fromBackgroundTask(block, counter: AllocatedUnfairLockCounter())
        case ("fromBackgroundTask", "nsLock"):
            finalValue = CallerPaths.fromBackgroundTask(block, counter: NSLockCounter())
        case ("fromManyTasks", "actor"):
            finalValue = CallerPaths.fromManyTasks(
                block,
                counter: CounterActor(),
                asyncCode: asyncCode!
            )
        case ("fromManyTasks", "mutex"):
            finalValue = CallerPaths.fromManyTasks(
                block,
                counter: MutexCounter(),
                asyncCode: asyncCode!
            )
        case ("fromManyTasks", "osAllocatedUnfairLock"):
            finalValue = CallerPaths.fromManyTasks(
                block,
                counter: AllocatedUnfairLockCounter(),
                asyncCode: asyncCode!
            )
        case ("fromManyTasks", "nsLock"):
            finalValue = CallerPaths.fromManyTasks(
                block,
                counter: NSLockCounter(),
                asyncCode: asyncCode!
            )
        case ("fromMainActor", "actor"):
            finalValue = CallerPaths.fromMainActor(block, counter: CounterActor())
        case ("fromMainActor", "mutex"):
            finalValue = CallerPaths.fromMainActor(block, counter: MutexCounter())
        case ("fromMainActor", "osAllocatedUnfairLock"):
            finalValue = CallerPaths.fromMainActor(block, counter: AllocatedUnfairLockCounter())
        case ("fromMainActor", "nsLock"):
            finalValue = CallerPaths.fromMainActor(block, counter: NSLockCounter())
        case ("toMainActor", "mainActor"):
            finalValue = CallerPaths.toMainActor(block)
        case ("oneAwaitPerGroup", "actor"):
            finalValue = Batching.oneAwaitPerGroup(block)
        case ("awaitPerOperation", "actor"):
            finalValue = Batching.awaitPerOperation(block)
        case ("oneLockPerGroup", "mutex"):
            finalValue = Batching.oneLockPerGroup(block)
        case ("callFromMainActor", _):
            return IsolationSettings.run(block)
        default:
            preconditionFailure("AsyncCode.init accepts only the pairs of the rows table")
        }

        return [AsyncCodeChecks.checkCount(finalValue: finalValue, asyncCode: asyncCode, block: block)]
    }
}
