import os

final class AllocatedUnfairLockProtection<State: Sendable>: StateProtection {
    private let state: OSAllocatedUnfairLock<State>

    init(_ initialState: State) {
        state = OSAllocatedUnfairLock(initialState: initialState)
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        state.withLock(body)
    }
}
