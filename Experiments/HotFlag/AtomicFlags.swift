import Atomics
import Synchronization

/// An atomic flag with acquire reads and release writes.
final class AtomicFlag: SharedFlag {
    private let value: Atomic<Bool>

    init(_ initialValue: Bool) {
        value = Atomic(initialValue)
    }

    func read() -> Bool {
        value.load(ordering: .acquiring)
    }

    func write(_ value: Bool) {
        self.value.store(
            value,
            ordering: .releasing
        )
    }

}

/// A flag with relaxed ordering on both atomic operations.
final class RelaxedAtomicFlag: SharedFlag {
    private let value: Atomic<Bool>

    init(_ initialValue: Bool) {
        value = Atomic(initialValue)
    }

    func read() -> Bool {
        value.load(ordering: .relaxed)
    }

    func write(_ value: Bool) {
        self.value.store(
            value,
            ordering: .relaxed
        )
    }

}

/// The swift-atomics counterpart of `AtomicFlag`.
final class ManagedAtomicFlag: SharedFlag {
    private let value: ManagedAtomic<Bool>

    init(_ initialValue: Bool) {
        value = ManagedAtomic(initialValue)
    }

    func read() -> Bool {
        value.load(ordering: .acquiring)
    }

    func write(_ value: Bool) {
        self.value.store(
            value,
            ordering: .releasing
        )
    }

}

/// The swift-atomics counterpart of `RelaxedAtomicFlag`.
final class RelaxedManagedAtomicFlag: SharedFlag {
    private let value: ManagedAtomic<Bool>

    init(_ initialValue: Bool) {
        value = ManagedAtomic(initialValue)
    }

    func read() -> Bool {
        value.load(ordering: .relaxed)
    }

    func write(_ value: Bool) {
        self.value.store(
            value,
            ordering: .relaxed
        )
    }

}
