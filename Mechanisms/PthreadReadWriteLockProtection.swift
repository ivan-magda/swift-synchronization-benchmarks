import Darwin

/// The stable heap lock allows shared readers and excludes writers from all access.
final class PthreadReadWriteLockProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var state: State

    init(_ initialState: State) {
        state = initialState
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        let result = pthread_rwlock_init(lock, nil)
        assert(result == 0)
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        let result = pthread_rwlock_wrlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        return body(&state)
    }

    func withSharedAccess<Result: Sendable>(
        _ body: @Sendable (State) -> Result
    ) -> Result {
        let result = pthread_rwlock_rdlock(lock)
        assert(result == 0)
        defer {
            let result = pthread_rwlock_unlock(lock)
            assert(result == 0)
        }
        return body(state)
    }

    deinit {
        let result = pthread_rwlock_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}
