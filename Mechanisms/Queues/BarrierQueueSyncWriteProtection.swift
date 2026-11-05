import Dispatch

/// Reads run on the concurrent queue; barrier access excludes all other access.
final class BarrierQueueSyncWriteProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "SyncBench.concurrent",
        attributes: .concurrent
    )
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        queue.sync(flags: .barrier) {
            body(&state)
        }
    }

    func withSharedAccess<Result: Sendable>(
        _ body: @Sendable (State) -> Result
    ) -> Result {
        queue.sync {
            body(state)
        }
    }
}
