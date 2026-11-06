import Darwin
import Dispatch
import Foundation
import ObjectiveC
import os
import Synchronization

final class MutexStore: RecordStore {
    private let records: Mutex<[Record]>
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
        records = Mutex(Array(repeating: Record(version: 0, value: 0), count: 10_000))
    }

    func readGroup(_ group: Int) -> GroupRead {
        records.withLock { records in
            records.readGroup(group, size: groupSize)
        }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        records.withLock { records in
            records.writeGroup(group, size: groupSize)
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }
}

final class AllocatedUnfairLockStore: RecordStore {
    private let records: OSAllocatedUnfairLock<[Record]>
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
        records = OSAllocatedUnfairLock(initialState: Array(repeating: Record(version: 0, value: 0), count: 10_000))
    }

    func readGroup(_ group: Int) -> GroupRead {
        records.withLock { records in
            records.readGroup(group, size: groupSize)
        }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        records.withLock { records in
            records.writeGroup(group, size: groupSize)
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }
}

final class AdaptiveSpinUnfairLockStore: RecordStore {
    private let records: OSAllocatedUnfairLock<[Record]>
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
        records = OSAllocatedUnfairLock(initialState: Array(repeating: Record(version: 0, value: 0), count: 10_000))
    }

    func readGroup(_ group: Int) -> GroupRead {
        records.withLock(flags: .adaptiveSpin) { records in
            records.readGroup(group, size: groupSize)
        }
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        records.withLock(flags: .adaptiveSpin) { records in
            records.writeGroup(group, size: groupSize)
            endTimes.record(call: slot, ticks: Clock.now())
        }
    }
}

/// The stable heap unfair lock guards every record access.
final class UnfairLockStore: RecordStore, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func readGroup(_ group: Int) -> GroupRead {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stored lock guards every record access.
final class NSLockStore: RecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        lock.lock()
        defer {
            lock.unlock()
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }
}

/// The stored recursive lock guards every record access.
final class NSRecursiveLockStore: RecordStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        lock.lock()
        defer {
            lock.unlock()
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }
}

/// The stable heap mutex guards every record access.
final class PthreadMutexStore: RecordStore, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func readGroup(_ group: Int) -> GroupRead {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// Shared read locks protect reads; the exclusive write lock protects every mutation.
final class PthreadReadWriteLockStore: RecordStore, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    func readGroup(_ group: Int) -> GroupRead {
        let result = pthread_rwlock_rdlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        let result = pthread_rwlock_wrlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The single semaphore permit guards every record access.
final class DispatchSemaphoreStore: RecordStore, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }
}

/// The stored object monitor guards every record access.
final class ObjcSyncStore: RecordStore, @unchecked Sendable {
    private let monitor = NSObject()
    private var records = Array(repeating: Record(version: 0, value: 0), count: 10_000)
    private let groupSize: Int

    init(groupSize: Int) {
        self.groupSize = groupSize
    }

    func readGroup(_ group: Int) -> GroupRead {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        return records.readGroup(group, size: groupSize)
    }

    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int) {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        records.writeGroup(group, size: groupSize)
        endTimes.record(call: slot, ticks: Clock.now())
    }
}
