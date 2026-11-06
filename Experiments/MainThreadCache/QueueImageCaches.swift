import Dispatch

/// Reads and writes run on the serial queue; synchronous calls protect every access.
final class SerialQueueImageCache: ImageCache, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.mainThreadCache.serial")
    private var images = [String: CachedImage]()

    func image(for key: String) -> CachedImage? {
        queue.sync {
            images[key]
        }
    }

    func store(_ entry: CachedImage, for key: String) {
        queue.sync {
            images[key] = entry
        }
    }
}

/// Reads share the concurrent queue; synchronous barriers protect writes.
final class BarrierQueueSyncWriteImageCache: ImageCache, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.mainThreadCache.concurrent", attributes: .concurrent)
    private var images = [String: CachedImage]()

    func image(for key: String) -> CachedImage? {
        queue.sync {
            images[key]
        }
    }

    func store(_ entry: CachedImage, for key: String) {
        queue.sync(flags: .barrier) {
            images[key] = entry
        }
    }
}

/// Reads share the concurrent queue; asynchronous barriers protect writes.
/// Submitted callbacks retain this store; callers drain before observing completion.
final class BarrierQueueAsyncWriteImageCache: ImageCache, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.mainThreadCache.concurrent", attributes: .concurrent)
    private var images = [String: CachedImage]()

    func image(for key: String) -> CachedImage? {
        queue.sync {
            images[key]
        }
    }

    func store(_ entry: CachedImage, for key: String) {
        queue.async(flags: .barrier) {
            self.images[key] = entry
        }
    }

    func waitForPendingWrites() {
        queue.sync(flags: .barrier) {}
    }
}
