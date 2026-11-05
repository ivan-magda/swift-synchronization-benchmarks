import Dispatch

/// A single semaphore permit excludes all other access to state.
final class SemaphoreProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        return body(&state)
    }
}
