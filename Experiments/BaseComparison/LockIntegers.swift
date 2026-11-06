import Darwin
import Dispatch
import Foundation
import ObjectiveC
import os
import Synchronization

final class MutexInteger: SharedInteger {
    private let value: Mutex<Int>

    init(_ initialValue: Int) {
        value = Mutex(initialValue)
    }

    func read() -> Int {
        value.withLock { value in
            value
        }
    }

    func write(_ newValue: Int) {
        value.withLock { value in
            value = newValue
        }
    }

    func increment() {
        value.withLock { value in
            value &+= 1
        }
    }
}

final class AllocatedUnfairLockInteger: SharedInteger {
    private let value: OSAllocatedUnfairLock<Int>

    init(_ initialValue: Int) {
        value = OSAllocatedUnfairLock(initialState: initialValue)
    }

    func read() -> Int {
        value.withLock { value in
            value
        }
    }

    func write(_ newValue: Int) {
        value.withLock { value in
            value = newValue
        }
    }

    func increment() {
        value.withLock { value in
            value &+= 1
        }
    }
}

final class AdaptiveSpinUnfairLockInteger: SharedInteger {
    private let value: OSAllocatedUnfairLock<Int>

    init(_ initialValue: Int) {
        value = OSAllocatedUnfairLock(initialState: initialValue)
    }

    func read() -> Int {
        value.withLock(flags: .adaptiveSpin) { value in
            value
        }
    }

    func write(_ newValue: Int) {
        value.withLock(flags: .adaptiveSpin) { value in
            value = newValue
        }
    }

    func increment() {
        value.withLock(flags: .adaptiveSpin) { value in
            value &+= 1
        }
    }
}

/// The heap lock has a stable address and guards every access to value.
final class UnfairLockInteger: SharedInteger, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func read() -> Int {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        return value
    }

    func write(_ newValue: Int) {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        value = newValue
    }

    func increment() {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        value &+= 1
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stored lock guards every access to value.
final class NSLockInteger: SharedInteger, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }

    func write(_ newValue: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        value = newValue
    }

    func increment() {
        lock.lock()
        defer {
            lock.unlock()
        }
        value &+= 1
    }
}

/// The stored recursive lock guards every access to value.
final class NSRecursiveLockInteger: SharedInteger, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }

    func write(_ newValue: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        value = newValue
    }

    func increment() {
        lock.lock()
        defer {
            lock.unlock()
        }
        value &+= 1
    }
}

/// The heap mutex has a stable address and guards every access to value.
final class PthreadMutexInteger: SharedInteger, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func read() -> Int {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        return value
    }

    func write(_ newValue: Int) {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        value = newValue
    }

    func increment() {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        value &+= 1
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stable heap lock allows shared readers and excludes writers from all access.
final class PthreadReadWriteLockInteger: SharedInteger, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    func read() -> Int {
        let result = pthread_rwlock_rdlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        return value
    }

    func write(_ newValue: Int) {
        let result = pthread_rwlock_wrlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        value = newValue
    }

    func increment() {
        let result = pthread_rwlock_wrlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        value &+= 1
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// A single semaphore permit excludes all other access to value.
final class DispatchSemaphoreInteger: SharedInteger, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        return value
    }

    func write(_ newValue: Int) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        value = newValue
    }

    func increment() {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        value &+= 1
    }
}

/// The stored object's Objective-C monitor guards every access to value.
final class ObjcSyncInteger: SharedInteger, @unchecked Sendable {
    private let monitor = NSObject()
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        return value
    }

    func write(_ newValue: Int) {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        value = newValue
    }

    func increment() {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        value &+= 1
    }
}
