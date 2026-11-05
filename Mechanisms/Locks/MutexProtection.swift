import Synchronization

final class MutexProtection<State: Sendable>: StateProtection {
    private let state: Mutex<State>

    init(_ initialState: State) {
        state = Mutex(initialState)
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        state.withLock { state in
            body(&state)
        }
    }
}
