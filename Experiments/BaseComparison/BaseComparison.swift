/// Experiment 1: base comparison.
///
/// What does one read, write or increment of a shared `Int` cost with each
/// synchronization mechanism, on one thread and with 2, 6 and 12 threads at once?
/// Each row protects one `Int`; LockIntegers.swift, QueueIntegers/,
/// AtomicIntegers.swift and ActorIntegers.swift contain the concrete operations.
/// One operation is one method call. The harness times the loops below in batches
/// (README.md), with the unsynchronized floor restricted to one thread.
struct BaseComparison: Experiment {
    enum Operation: String, CaseIterable, Sendable {
        case read
        case write
        case increment
    }

    static let valueForReads = 42
    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try BaseComparisonRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let operation = Operation(rawValue: block.description.operation)!
        let initialValue = operation == .read ? Self.valueForReads : 0

        switch MechanismID(rawValue: block.description.mechanism)! {
        case .unsynchronized:
            return measure(UnsynchronizedInteger(initialValue), operation, block)
        case .mutex:
            return measure(MutexInteger(initialValue), operation, block)
        case .osAllocatedUnfairLock:
            return measure(AllocatedUnfairLockInteger(initialValue), operation, block)
        case .osAllocatedUnfairLockAdaptiveSpin:
            return measure(AdaptiveSpinUnfairLockInteger(initialValue), operation, block)
        case .osUnfairLock:
            return measure(UnfairLockInteger(initialValue), operation, block)
        case .nsLock:
            return measure(NSLockInteger(initialValue), operation, block)
        case .nsRecursiveLock:
            return measure(NSRecursiveLockInteger(initialValue), operation, block)
        case .pthreadMutex:
            return measure(PthreadMutexInteger(initialValue), operation, block)
        case .pthreadReadWriteLock:
            return measure(PthreadReadWriteLockInteger(initialValue), operation, block)
        case .serialQueue:
            return measure(SerialQueueInteger(initialValue), operation, block)
        case .barrierQueueSyncWrite:
            return measure(BarrierQueueSyncWriteInteger(initialValue), operation, block)
        case .barrierQueueAsyncWrite:
            return measure(BarrierQueueAsyncWriteInteger(initialValue), operation, block)
        case .dispatchSemaphore:
            return measure(DispatchSemaphoreInteger(initialValue), operation, block)
        case .objcSync:
            return measure(ObjcSyncInteger(initialValue), operation, block)
        case .actor:
            return measureAsync(ActorInteger(initialValue), operation, block)
        case .mainActor:
            return measureAsync(MainActorInteger.makeOnMainThread(initialValue), operation, block)
        case .atomic:
            return measure(AtomicInteger(initialValue), operation, block)
        case .atomicRelaxed:
            return measure(RelaxedAtomicInteger(initialValue), operation, block)
        case .managedAtomic:
            return measure(ManagedAtomicInteger(initialValue), operation, block)
        case .managedAtomicRelaxed:
            return measure(RelaxedManagedAtomicInteger(initialValue), operation, block)
        }
    }
}

// The measured code: one call of the mechanism per loop iteration.
extension BaseComparison {
    @inline(never)
    static func readLoop<Integer: SharedInteger>(_ integer: Integer, count: Int) -> Int {
        var sum = 0
        for _ in 0..<count {
            sum += integer.read()
        }
        return sum
    }

    @inline(never)
    static func writeLoop<Integer: SharedInteger>(
        _ integer: Integer, count: Int, firstValue: Int
    ) {
        for operation in 0..<count {
            integer.write(firstValue + operation)
        }
    }

    @inline(never)
    static func incrementLoop<Integer: SharedInteger>(_ integer: Integer, count: Int) {
        for _ in 0..<count {
            integer.increment()
        }
    }

    @inline(never)
    static func readLoopAsync<Integer: AsyncSharedInteger>(_ integer: Integer, count: Int) async -> Int {
        var sum = 0
        for _ in 0..<count {
            sum += await integer.read()
        }
        return sum
    }

    @inline(never)
    static func writeLoopAsync<Integer: AsyncSharedInteger>(
        _ integer: Integer, count: Int, firstValue: Int
    ) async {
        for operation in 0..<count {
            await integer.write(firstValue + operation)
        }
    }

    @inline(never)
    static func incrementLoopAsync<Integer: AsyncSharedInteger>(_ integer: Integer, count: Int) async -> Int {
        var sum = 0
        for _ in 0..<count {
            sum += await integer.increment()
        }
        return sum
    }
}
