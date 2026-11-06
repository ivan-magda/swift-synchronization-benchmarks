enum MechanismID: String, CaseIterable, Codable, Sendable {
    case unsynchronized
    case mutex
    case osAllocatedUnfairLock
    case osAllocatedUnfairLockAdaptiveSpin
    case osUnfairLock
    case nsLock
    case nsRecursiveLock
    case pthreadMutex
    case pthreadReadWriteLock
    case serialQueue
    case barrierQueueSyncWrite
    case barrierQueueAsyncWrite
    case dispatchSemaphore
    case objcSync
    case actor
    case mainActor
    case atomic
    case atomicRelaxed
    case managedAtomic
    case managedAtomicRelaxed

    /// The 13 mechanisms that implement `StateProtection`.
    static var stateProtections: [MechanismID] {
        [
            .mutex,
            .osAllocatedUnfairLock,
            .osAllocatedUnfairLockAdaptiveSpin,
            .osUnfairLock,
            .nsLock,
            .nsRecursiveLock,
            .pthreadMutex,
            .pthreadReadWriteLock,
            .serialQueue,
            .barrierQueueSyncWrite,
            .barrierQueueAsyncWrite,
            .dispatchSemaphore,
            .objcSync,
        ]
    }
}
