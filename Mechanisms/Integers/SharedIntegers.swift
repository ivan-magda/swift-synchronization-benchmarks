import Dispatch

/// Receives a concrete integer type so measured loops can specialize for it.
protocol SharedIntegerVisitor {
    associatedtype Output

    func visitSynchronous<Integer: SharedInteger>(_ integer: Integer) -> Output
    func visitAsynchronous<Integer: AsyncSharedInteger>(_ integer: Integer) -> Output
}

enum SharedIntegers {
    /// Creates the main-actor row on the main thread. Call from a background
    /// benchmark pthread, keeping the main thread free to serve this request.
    static func visit<Visitor: SharedIntegerVisitor>(
        _ mechanism: MechanismID,
        initialValue: Int,
        with visitor: Visitor
    ) -> Visitor.Output {
        switch mechanism {
        case .unsynchronized:
            return visitor.visitSynchronous(ProtectedInteger(NoProtection(initialValue)))
        case .mutex:
            return visitor.visitSynchronous(ProtectedInteger(MutexProtection(initialValue)))
        case .osAllocatedUnfairLock:
            return visitor.visitSynchronous(
                ProtectedInteger(AllocatedUnfairLockProtection(initialValue))
            )
        case .osAllocatedUnfairLockAdaptiveSpin:
            return visitor.visitSynchronous(
                ProtectedInteger(AdaptiveSpinUnfairLockProtection(initialValue))
            )
        case .osUnfairLock:
            return visitor.visitSynchronous(ProtectedInteger(UnfairLockProtection(initialValue)))
        case .nsLock:
            return visitor.visitSynchronous(ProtectedInteger(NSLockProtection(initialValue)))
        case .nsRecursiveLock:
            return visitor.visitSynchronous(ProtectedInteger(NSRecursiveLockProtection(initialValue)))
        case .pthreadMutex:
            return visitor.visitSynchronous(ProtectedInteger(PthreadMutexProtection(initialValue)))
        case .pthreadReadWriteLock:
            return visitor.visitSynchronous(
                ProtectedInteger(PthreadReadWriteLockProtection(initialValue))
            )
        case .serialQueue:
            return visitor.visitSynchronous(ProtectedInteger(SerialQueueProtection(initialValue)))
        case .barrierQueueSyncWrite:
            return visitor.visitSynchronous(
                ProtectedInteger(BarrierQueueSyncWriteProtection(initialValue))
            )
        case .barrierQueueAsyncWrite:
            return visitor.visitSynchronous(
                ProtectedInteger(BarrierQueueAsyncWriteProtection(initialValue))
            )
        case .dispatchSemaphore:
            return visitor.visitSynchronous(ProtectedInteger(SemaphoreProtection(initialValue)))
        case .objcSync:
            return visitor.visitSynchronous(ProtectedInteger(ObjcSyncProtection(initialValue)))
        case .actor:
            return visitor.visitAsynchronous(ActorInteger(initialValue))
        case .mainActor:
            let integer = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    MainActorInteger(initialValue)
                }
            }
            return visitor.visitAsynchronous(integer)
        case .atomic:
            return visitor.visitSynchronous(AtomicInteger(initialValue))
        case .atomicRelaxed:
            return visitor.visitSynchronous(RelaxedAtomicInteger(initialValue))
        case .managedAtomic:
            return visitor.visitSynchronous(ManagedAtomicInteger(initialValue))
        case .managedAtomicRelaxed:
            return visitor.visitSynchronous(RelaxedManagedAtomicInteger(initialValue))
        }
    }
}
