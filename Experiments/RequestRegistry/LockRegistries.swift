import Darwin
import Dispatch
import Foundation
import ObjectiveC
import os
import Synchronization

final class MutexRegistry: DownloadRegistry {
    private let downloads: Mutex<[Int: Download]>

    init(capacity: Int) {
        downloads = Mutex(Dictionary(minimumCapacity: capacity))
    }

    func add(_ download: Download, id: Int) {
        downloads.withLock { downloads in
            downloads[id] = download
        }
    }

    func remove(id: Int) -> Download? {
        downloads.withLock { downloads in
            downloads.removeValue(forKey: id)
        }
    }

    func cancelAll() -> Int {
        downloads.withLock { downloads in
            let count = downloads.count
            for download in downloads.values { download.cancel() }
            downloads.removeAll(keepingCapacity: true)
            return count
        }
    }
}

final class AllocatedUnfairLockRegistry: DownloadRegistry {
    private let downloads: OSAllocatedUnfairLock<[Int: Download]>

    init(capacity: Int) {
        downloads = OSAllocatedUnfairLock(initialState: Dictionary(minimumCapacity: capacity))
    }

    func add(_ download: Download, id: Int) {
        downloads.withLock { downloads in
            downloads[id] = download
        }
    }

    func remove(id: Int) -> Download? {
        downloads.withLock { downloads in
            downloads.removeValue(forKey: id)
        }
    }

    func cancelAll() -> Int {
        downloads.withLock { downloads in
            let count = downloads.count
            for download in downloads.values { download.cancel() }
            downloads.removeAll(keepingCapacity: true)
            return count
        }
    }
}

final class AdaptiveSpinUnfairLockRegistry: DownloadRegistry {
    private let downloads: OSAllocatedUnfairLock<[Int: Download]>

    init(capacity: Int) {
        downloads = OSAllocatedUnfairLock(initialState: Dictionary(minimumCapacity: capacity))
    }

    func add(_ download: Download, id: Int) {
        downloads.withLock(flags: .adaptiveSpin) { downloads in
            downloads[id] = download
        }
    }

    func remove(id: Int) -> Download? {
        downloads.withLock(flags: .adaptiveSpin) { downloads in
            downloads.removeValue(forKey: id)
        }
    }

    func cancelAll() -> Int {
        downloads.withLock(flags: .adaptiveSpin) { downloads in
            let count = downloads.count
            for download in downloads.values { download.cancel() }
            downloads.removeAll(keepingCapacity: true)
            return count
        }
    }
}

/// The stable heap unfair lock guards every dictionary access.
final class UnfairLockRegistry: DownloadRegistry, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func add(_ download: Download, id: Int) {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        downloads[id] = download
    }

    func remove(id: Int) -> Download? {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        return downloads.removeValue(forKey: id)
    }

    func cancelAll() -> Int {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        let count = downloads.count
        for download in downloads.values { download.cancel() }
        downloads.removeAll(keepingCapacity: true)
        return count
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stored lock guards every dictionary access.
final class NSLockRegistry: DownloadRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
    }

    func add(_ download: Download, id: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        downloads[id] = download
    }

    func remove(id: Int) -> Download? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return downloads.removeValue(forKey: id)
    }

    func cancelAll() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        let count = downloads.count
        for download in downloads.values { download.cancel() }
        downloads.removeAll(keepingCapacity: true)
        return count
    }

}

/// The stored recursive lock guards every dictionary access.
final class NSRecursiveLockRegistry: DownloadRegistry, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
    }

    func add(_ download: Download, id: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        downloads[id] = download
    }

    func remove(id: Int) -> Download? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return downloads.removeValue(forKey: id)
    }

    func cancelAll() -> Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        let count = downloads.count
        for download in downloads.values { download.cancel() }
        downloads.removeAll(keepingCapacity: true)
        return count
    }

}

/// The stable heap mutex guards every dictionary access.
final class PthreadMutexRegistry: DownloadRegistry, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func add(_ download: Download, id: Int) {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        downloads[id] = download
    }

    func remove(id: Int) -> Download? {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        return downloads.removeValue(forKey: id)
    }

    func cancelAll() -> Int {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        let count = downloads.count
        for download in downloads.values { download.cancel() }
        downloads.removeAll(keepingCapacity: true)
        return count
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// One semaphore permit guards every dictionary access.
final class DispatchSemaphoreRegistry: DownloadRegistry, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
    }

    func add(_ download: Download, id: Int) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        downloads[id] = download
    }

    func remove(id: Int) -> Download? {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        return downloads.removeValue(forKey: id)
    }

    func cancelAll() -> Int {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        let count = downloads.count
        for download in downloads.values { download.cancel() }
        downloads.removeAll(keepingCapacity: true)
        return count
    }

}

/// The stored monitor guards every dictionary access.
final class ObjcSyncRegistry: DownloadRegistry, @unchecked Sendable {
    private let monitor = NSObject()
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
    }

    func add(_ download: Download, id: Int) {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        downloads[id] = download
    }

    func remove(id: Int) -> Download? {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        return downloads.removeValue(forKey: id)
    }

    func cancelAll() -> Int {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        let count = downloads.count
        for download in downloads.values { download.cancel() }
        downloads.removeAll(keepingCapacity: true)
        return count
    }

}
