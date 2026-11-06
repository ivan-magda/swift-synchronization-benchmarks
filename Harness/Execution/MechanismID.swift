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

}
