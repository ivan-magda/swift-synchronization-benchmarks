import Synchronization

/// Preallocated work item; cancel counts remain observable after registry removal.
final class Download: Sendable {
    let id: Int
    let workIterations: Int
    let cancelCount = Atomic<Int>(0)

    init(id: Int, workIterations: Int) {
        self.id = id
        self.workIterations = workIterations
    }

    func cancel() {
        cancelCount.wrappingAdd(1, ordering: .relaxed)
    }
}

protocol DownloadRegistry: AnyObject, Sendable {
    func add(_ download: Download, id: Int)
    func remove(id: Int) -> Download?
    func cancelAll() -> Int
}
