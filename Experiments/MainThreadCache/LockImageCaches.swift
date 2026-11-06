import Darwin
import Dispatch
import Foundation
import ObjectiveC
import os
import Synchronization

final class MutexImageCache: ImageCache {
    private let images: Mutex<[String: CachedImage]>

    init() {
        images = Mutex([:])
    }

    func image(for key: String) -> CachedImage? {
        images.withLock { images in
            images[key]
        }
    }

    func store(_ entry: CachedImage, for key: String) {
        images.withLock { images in
            images[key] = entry
        }
    }
}

final class AllocatedUnfairLockImageCache: ImageCache {
    private let images: OSAllocatedUnfairLock<[String: CachedImage]>

    init() {
        images = OSAllocatedUnfairLock(initialState: [:])
    }

    func image(for key: String) -> CachedImage? {
        images.withLock { images in
            images[key]
        }
    }

    func store(_ entry: CachedImage, for key: String) {
        images.withLock { images in
            images[key] = entry
        }
    }
}

final class AdaptiveSpinUnfairLockImageCache: ImageCache {
    private let images: OSAllocatedUnfairLock<[String: CachedImage]>

    init() {
        images = OSAllocatedUnfairLock(initialState: [:])
    }

    func image(for key: String) -> CachedImage? {
        images.withLock(flags: .adaptiveSpin) { images in
            images[key]
        }
    }

    func store(_ entry: CachedImage, for key: String) {
        images.withLock(flags: .adaptiveSpin) { images in
            images[key] = entry
        }
    }
}

/// The stable heap unfair lock guards every image access.
final class UnfairLockImageCache: ImageCache, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var images: [String: CachedImage] = [:]

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func image(for key: String) -> CachedImage? {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        images[key] = entry
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The stored lock guards every image access.
final class NSLockImageCache: ImageCache, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CachedImage] = [:]

    func image(for key: String) -> CachedImage? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        lock.lock()
        defer {
            lock.unlock()
        }
        images[key] = entry
    }
}

/// The stored recursive lock guards every image access.
final class NSRecursiveLockImageCache: ImageCache, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var images: [String: CachedImage] = [:]

    func image(for key: String) -> CachedImage? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        lock.lock()
        defer {
            lock.unlock()
        }
        images[key] = entry
    }
}

/// The stable heap mutex guards every image access.
final class PthreadMutexImageCache: ImageCache, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var images: [String: CachedImage] = [:]

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func image(for key: String) -> CachedImage? {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        images[key] = entry
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// Shared read locks protect reads; the exclusive write lock protects every mutation.
final class PthreadReadWriteLockImageCache: ImageCache, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var images: [String: CachedImage] = [:]

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    func image(for key: String) -> CachedImage? {
        let result = pthread_rwlock_rdlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        let result = pthread_rwlock_wrlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        images[key] = entry
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// The single semaphore permit guards every image access.
final class DispatchSemaphoreImageCache: ImageCache, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var images: [String: CachedImage] = [:]

    func image(for key: String) -> CachedImage? {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        images[key] = entry
    }
}

/// The stored object monitor guards every image access.
final class ObjcSyncImageCache: ImageCache, @unchecked Sendable {
    private let monitor = NSObject()
    private var images: [String: CachedImage] = [:]

    func image(for key: String) -> CachedImage? {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        return images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        images[key] = entry
    }
}
