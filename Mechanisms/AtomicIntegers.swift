import Atomics
import Synchronization

/// An atomic counter with acquire reads, release writes and acquire-release increments.
final class AtomicInteger: SharedInteger {
    private let value: Atomic<Int>

    init(_ initialValue: Int) {
        value = Atomic(initialValue)
    }

    func read() -> Int {
        value.load(ordering: .acquiring)
    }

    func write(_ value: Int) {
        self.value.store(value, ordering: .releasing)
    }

    func increment() {
        value.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }
}

/// A counter with relaxed ordering on every atomic operation.
final class RelaxedAtomicInteger: SharedInteger {
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
        value.wrappingAdd(1, ordering: .relaxed)
    }
}

/// The swift-atomics counterpart of `AtomicInteger`.
struct ManagedAtomicInteger: SharedInteger {
    private let value: ManagedAtomic<Int>

    init(_ initialValue: Int) {
        value = ManagedAtomic(initialValue)
    }

    func read() -> Int {
        value.load(ordering: .acquiring)
    }

    func write(_ value: Int) {
        self.value.store(value, ordering: .releasing)
    }

    func increment() {
        value.wrappingIncrement(ordering: .acquiringAndReleasing)
    }
}

/// The swift-atomics counterpart of `RelaxedAtomicInteger`.
struct RelaxedManagedAtomicInteger: SharedInteger {
    private let value: ManagedAtomic<Int>

    init(_ initialValue: Int) {
        value = ManagedAtomic(initialValue)
    }

    func read() -> Int {
        value.load(ordering: .relaxed)
    }

    func write(_ value: Int) {
        self.value.store(value, ordering: .relaxed)
    }

    func increment() {
        value.wrappingIncrement(ordering: .relaxed)
    }
}
