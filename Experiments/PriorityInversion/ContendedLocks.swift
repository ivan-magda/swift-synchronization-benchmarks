import Dispatch
import Foundation
import ObjectiveC
import Synchronization
import os

enum ContendedLocks {
    /// The fourteen mechanisms of experiment 8B.
    static let mechanisms: [MechanismID] = [
        .mutex,
        .osAllocatedUnfairLock,
        .osAllocatedUnfairLockAdaptiveSpin,
        .osUnfairLock,
        .nsLock,
        .nsRecursiveLock,
        .pthreadMutex,
        .pthreadReadWriteLock,
        .objcSync,
        .serialQueue,
        .barrierQueueSyncWrite,
        .barrierQueueAsyncWrite,
        .dispatchSemaphore,
        .actor,
    ]

    /// One new lock for the mechanism; the actor row needs the holder's QoS for its task priority.
    static func make(_ mechanism: MechanismID, holderQoS: QoS) -> any ContendedLock {
        switch mechanism {
        case .mutex: ContendedMutex()
        case .osAllocatedUnfairLock: ContendedAllocatedUnfairLock()
        case .osAllocatedUnfairLockAdaptiveSpin: ContendedAdaptiveSpinUnfairLock()
        case .osUnfairLock: ContendedUnfairLock()
        case .nsLock: ContendedNSLock()
        case .nsRecursiveLock: ContendedNSRecursiveLock()
        case .pthreadMutex: ContendedPthreadMutex()
        case .pthreadReadWriteLock: ContendedPthreadReadWriteLock()
        case .objcSync: ContendedObjcSync()
        case .serialQueue: ContendedSerialQueue()
        case .barrierQueueSyncWrite: ContendedBarrierQueueSyncWrite()
        case .barrierQueueAsyncWrite: ContendedBarrierQueueAsyncWrite()
        case .dispatchSemaphore: ContendedSemaphore()
        case .actor: ContendedActorLock(holderPriority: holderQoS.taskPriority)
        default:
            preconditionFailure("Experiment 8B has no row for \(mechanism)")
        }
    }
}

// Each row protects the trial index the holder last wrote; -1 means no holder has written yet.

final class ContendedMutex: ContendedLock {
    private let value = Mutex(-1)

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        value.withLock { value in
            timestamps.markAcquired()
            let resultCorrect = work.run()
            value = trial
            timestamps.markReleased(resultCorrect: resultCorrect)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let (acquired, observedTrial) = value.withLock { value in
            (Clock.now(), value)
        }
        done(acquired, observedTrial)
    }
}

final class ContendedAllocatedUnfairLock: ContendedLock {
    private let value = OSAllocatedUnfairLock(initialState: -1)

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        value.withLock { value in
            timestamps.markAcquired()
            let resultCorrect = work.run()
            value = trial
            timestamps.markReleased(resultCorrect: resultCorrect)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let (acquired, observedTrial) = value.withLock { value in
            (Clock.now(), value)
        }
        done(acquired, observedTrial)
    }
}

final class ContendedAdaptiveSpinUnfairLock: ContendedLock {
    private let value = OSAllocatedUnfairLock(initialState: -1)

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        value.withLock(flags: .adaptiveSpin) { value in
            timestamps.markAcquired()
            let resultCorrect = work.run()
            value = trial
            timestamps.markReleased(resultCorrect: resultCorrect)
        }
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let (acquired, observedTrial) = value.withLock(flags: .adaptiveSpin) { value in
            (Clock.now(), value)
        }
        done(acquired, observedTrial)
    }
}

/// The heap lock has a stable address and guards every access to `value`.
final class ContendedUnfairLock: ContendedLock, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value = -1

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        os_unfair_lock_lock(lock)
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        os_unfair_lock_unlock(lock)
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        os_unfair_lock_lock(lock)
        let acquired = Clock.now()
        let observedTrial = value
        os_unfair_lock_unlock(lock)
        done(acquired, observedTrial)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The lock guards every access to `value`.
final class ContendedNSLock: ContendedLock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        lock.lock()
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        lock.unlock()
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        lock.lock()
        let acquired = Clock.now()
        let observedTrial = value
        lock.unlock()
        done(acquired, observedTrial)
    }
}

/// The lock guards every access to `value`.
final class ContendedNSRecursiveLock: ContendedLock, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        lock.lock()
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        lock.unlock()
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        lock.lock()
        let acquired = Clock.now()
        let observedTrial = value
        lock.unlock()
        done(acquired, observedTrial)
    }
}

/// The heap mutex, with default attributes, has a stable address and guards every access to `value`.
final class ContendedPthreadMutex: ContendedLock, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var value = -1

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        let lockResult = pthread_mutex_lock(lock)
        assert(lockResult == 0)
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        let unlockResult = pthread_mutex_unlock(lock)
        assert(unlockResult == 0)
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let lockResult = pthread_mutex_lock(lock)
        assert(lockResult == 0)
        let acquired = Clock.now()
        let observedTrial = value
        let unlockResult = pthread_mutex_unlock(lock)
        assert(unlockResult == 0)
        done(acquired, observedTrial)
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The holder writes under the write lock; the main thread reads under the read lock.
final class ContendedPthreadReadWriteLock: ContendedLock, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var value = -1

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        let lockResult = pthread_rwlock_wrlock(lock)
        assert(lockResult == 0)
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        let unlockResult = pthread_rwlock_unlock(lock)
        assert(unlockResult == 0)
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let lockResult = pthread_rwlock_rdlock(lock)
        assert(lockResult == 0)
        let acquired = Clock.now()
        let observedTrial = value
        let unlockResult = pthread_rwlock_unlock(lock)
        assert(unlockResult == 0)
        done(acquired, observedTrial)
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// This object's Objective-C monitor guards every access to `value`.
final class ContendedObjcSync: ContendedLock, @unchecked Sendable {
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        let enterResult = objc_sync_enter(self)
        assert(enterResult == OBJC_SYNC_SUCCESS)
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        let exitResult = objc_sync_exit(self)
        assert(exitResult == OBJC_SYNC_SUCCESS)
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        let enterResult = objc_sync_enter(self)
        assert(enterResult == OBJC_SYNC_SUCCESS)
        let acquired = Clock.now()
        let observedTrial = value
        let exitResult = objc_sync_exit(self)
        assert(exitResult == OBJC_SYNC_SUCCESS)
        done(acquired, observedTrial)
    }
}

/// A single semaphore permit guards every access to `value`.
final class ContendedSemaphore: ContendedLock, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var value = -1

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
        semaphore.wait()
        timestamps.markAcquired()
        let resultCorrect = work.run()
        value = trial
        timestamps.markReleased(resultCorrect: resultCorrect)
        semaphore.signal()
    }

    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
        semaphore.wait()
        let acquired = Clock.now()
        let observedTrial = value
        semaphore.signal()
        done(acquired, observedTrial)
    }
}
