import Darwin

/// The heap mutex has a stable address and guards every access to state.
final class PthreadMutexProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var state: State

    init(_ initialState: State) {
        state = initialState
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_mutex_t())
        let result = pthread_mutex_init(lock, nil)
        assert(result == 0)
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        let result = pthread_mutex_lock(lock)
        assert(result == 0)
        defer {
            let result = pthread_mutex_unlock(lock)
            assert(result == 0)
        }
        return body(&state)
    }

    deinit {
        let result = pthread_mutex_destroy(lock)
        assert(result == 0)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}
