import Synchronization

/// The single-thread floor: relaxed atomic storage preserves each memory access.
/// Increment is a separate load and store, so callers must use only one thread.
final class UnsynchronizedInteger: SharedInteger {
    private let value: Atomic<Int>

    init(_ initialValue: Int) {
        value = Atomic(initialValue)
    }

    func read() -> Int {
        value.load(ordering: .relaxed)
    }

    func write(_ value: Int) {
        self.value.store(value, ordering: .relaxed)
    }

    func increment() {
        value.store(value.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
    }
}
