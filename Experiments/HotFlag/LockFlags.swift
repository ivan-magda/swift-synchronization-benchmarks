import Darwin
import Dispatch
import Foundation
import ObjectiveC
import os
import Synchronization

final class MutexFlag: SharedFlag {
    private let value: Mutex<Bool>

    init(_ initialValue: Bool) {
        value = Mutex(initialValue)
    }

    func read() -> Bool {
        value.withLock { value in
            value
        }
    }

    func write(_ newValue: Bool) {
        value.withLock { value in
            value = newValue
        }
    }

}

final class AllocatedUnfairLockFlag: SharedFlag {
    private let value: OSAllocatedUnfairLock<Bool>

    init(_ initialValue: Bool) {
        value = OSAllocatedUnfairLock(initialState: initialValue)
    }

    func read() -> Bool {
        value.withLock { value in
            value
        }
    }

    func write(_ newValue: Bool) {
        value.withLock { value in
            value = newValue
        }
    }

}

final class AdaptiveSpinUnfairLockFlag: SharedFlag {
    private let value: OSAllocatedUnfairLock<Bool>

    init(_ initialValue: Bool) {
        value = OSAllocatedUnfairLock(initialState: initialValue)
    }

    func read() -> Bool {
        value.withLock(flags: .adaptiveSpin) { value in
            value
        }
    }

    func write(_ newValue: Bool) {
        value.withLock(flags: .adaptiveSpin) { value in
            value = newValue
        }
    }

}

/// The heap lock has a stable address and guards every access to value.
final class UnfairLockFlag: SharedFlag, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func read() -> Bool {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        return value
    }

    func write(_ newValue: Bool) {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        value = newValue
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stored lock guards every access to value.
final class NSLockFlag: SharedFlag, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }

    func write(_ newValue: Bool) {
        lock.lock()
        defer {
            lock.unlock()
        }
        value = newValue
    }

}

/// The stored recursive lock guards every access to value.
final class NSRecursiveLockFlag: SharedFlag, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }

    func write(_ newValue: Bool) {
        lock.lock()
        defer {
            lock.unlock()
        }
        value = newValue
    }

}

/// The heap mutex has a stable address and guards every access to value.
final class PthreadMutexFlag: SharedFlag, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func read() -> Bool {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        return value
    }

    func write(_ newValue: Bool) {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        value = newValue
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stable heap lock allows shared readers and excludes writers from all access.
final class PthreadReadWriteLockFlag: SharedFlag, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    func read() -> Bool {
        let result = pthread_rwlock_rdlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        return value
    }

    func write(_ newValue: Bool) {
        let result = pthread_rwlock_wrlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        value = newValue
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// A single semaphore permit excludes all other access to value.
final class DispatchSemaphoreFlag: SharedFlag, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        return value
    }

    func write(_ newValue: Bool) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        value = newValue
    }

}

/// The stored object's Objective-C monitor guards every access to value.
final class ObjcSyncFlag: SharedFlag, @unchecked Sendable {
    private let monitor = NSObject()
    private var value: Bool

    init(_ initialValue: Bool) {
        value = initialValue
    }

    func read() -> Bool {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        return value
    }

    func write(_ newValue: Bool) {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        value = newValue
    }

}
