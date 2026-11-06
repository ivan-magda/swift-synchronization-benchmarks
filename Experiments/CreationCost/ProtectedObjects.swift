import Atomics
import Darwin
import Dispatch
import Foundation
import os
import Synchronization

/// Shared only for relaxed deinit accounting; object storage has one owner.
final class CreationDeinitCounter: Sendable {
    private let count = Atomic<Int>(0)

    var value: Int { count.load(ordering: .relaxed) }

    func increment() {
        count.wrappingAdd(1, ordering: .relaxed)
    }
}

final class UnprotectedObject {
    private var value = 0
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class MutexObject {
    private let value = Mutex<Int>(0)
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class AllocatedUnfairLockObject {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class UnfairLockObject {
    private var value = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) {
        self.counter = counter
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        counter.increment()
    }
}

final class NSLockObject {
    private var value = 0
    private let lock = NSLock()
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class NSRecursiveLockObject {
    private var value = 0
    private let lock = NSRecursiveLock()
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class PthreadMutexObject {
    private var value = 0
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) {
        self.counter = counter
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
        counter.increment()
    }
}

final class PthreadReadWriteLockObject {
    private var value = 0
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) {
        self.counter = counter
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
        counter.increment()
    }
}

final class SerialQueueObject {
    private var value = 0
    private let queue = DispatchQueue(label: "creation.serial")
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class BarrierQueueObject {
    private var value = 0
    private let queue = DispatchQueue(label: "creation.concurrent", attributes: .concurrent)
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class SemaphoreObject {
    private var value = 0
    private let semaphore = DispatchSemaphore(value: 1)
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

actor ActorObject {
    private var value = 0
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

@MainActor final class MainActorObject {
    private var value = 0
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class AtomicObject {
    private let value = Atomic<Int>(0)
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}

final class ManagedAtomicObject {
    private let value = ManagedAtomic<Int>(0)
    private let counter: CreationDeinitCounter

    init(_ counter: CreationDeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
}
