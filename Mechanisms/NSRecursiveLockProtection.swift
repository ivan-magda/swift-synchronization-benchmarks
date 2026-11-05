import Foundation

/// The stored recursive lock guards every access to state.
final class NSRecursiveLockProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
