import Dispatch

/// Every access to state executes synchronously on the serial queue.
final class SerialQueueProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.serial")
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        queue.sync {
            body(&state)
        }
    }
}
