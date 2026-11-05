import Dispatch

/// State is accessed only on the concurrent queue, with every mutation in a barrier.
/// Submitted writes retain the owner until their access to state has finished.
final class BarrierQueueAsyncWriteProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncBench.concurrent", attributes: .concurrent)
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

    func write<Argument: Sendable>(
        _ argument: Argument,
        using body: @escaping @Sendable (inout State, Argument) -> Void
    ) {
        queue.async(flags: .barrier) {
            body(&self.state, argument)
        }
    }

    func waitForPendingWrites() {
        queue.sync(flags: .barrier) {}
    }

    func recordExecutorCPU(into slot: CPUReadingSlot) {
        queue.async(flags: .barrier) {
            slot.store(CPU.current())
        }
    }
}
