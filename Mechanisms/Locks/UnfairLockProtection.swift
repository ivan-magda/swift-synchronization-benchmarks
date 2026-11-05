import os

/// The heap lock has a stable address and guards every access to state.
final class UnfairLockProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var state: State

    init(_ initialState: State) {
        state = initialState
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
        }
        return body(&state)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}
