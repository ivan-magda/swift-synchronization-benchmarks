import Foundation

/// All observer, generation, and change state is protected by `lock`.
/// Callbacks capture the monitor weakly and reject notifications from an earlier run.
final class ThermalMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (any NSObjectProtocol)?
    private var generation: UInt64 = 0
    private var changes: [ThermalChange] = []

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard observer == nil else {
            return
        }

        changes.removeAll(keepingCapacity: true)
        generation &+= 1
        let currentGeneration = generation

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.record(generation: currentGeneration)
        }
    }

    /// Returns only notifications recorded before this call acquired the lock.
    func stop() -> [ThermalChange] {
        lock.lock()
        let token = observer
        observer = nil
        let recordedChanges = changes
        lock.unlock()

        if let token {
            NotificationCenter.default.removeObserver(token)
        }

        return recordedChanges
    }

    private func record(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        guard observer != nil, self.generation == generation else {
            return
        }

        changes.append(
            ThermalChange(
                ticks: Clock.now(),
                thermalState: ProcessInfo.processInfo.thermalState.resultName
            )
        )
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
