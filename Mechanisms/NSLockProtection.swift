import Foundation

/// The stored lock guards every access to state.
final class NSLockProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body(&state)
    }
}
