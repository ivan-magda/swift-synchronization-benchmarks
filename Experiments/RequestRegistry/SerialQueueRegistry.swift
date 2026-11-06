import Dispatch

/// Synchronous work on the private serial queue guards every dictionary access.
final class SerialQueueRegistry: DownloadRegistry, @unchecked Sendable {
    private let queue = DispatchQueue(label: "request-registry.serial")
    private var downloads: [Int: Download]

    init(capacity: Int) {
        downloads = Dictionary(minimumCapacity: capacity)
    }

    func add(_ download: Download, id: Int) {
        queue.sync {
            downloads[id] = download
        }
    }

    func remove(id: Int) -> Download? {
        queue.sync {
            downloads.removeValue(forKey: id)
        }
    }

    func cancelAll() -> Int {
        queue.sync {
            let count = downloads.count
            for download in downloads.values { download.cancel() }
            downloads.removeAll(keepingCapacity: true)
            return count
        }
    }
}
