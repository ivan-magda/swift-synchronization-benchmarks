/// A way to protect state for synchronous callers: a lock, a queue or a semaphore.
protocol StateProtection<State>: AnyObject, Sendable {
    associatedtype State: Sendable

    init(_ initialState: State)

    /// Runs `body` with exclusive access and returns its result.
    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result

    /// Runs `body` with read access. Reader-writer locks and concurrent queues allow
    /// overlapping readers. The default implementation uses exclusive access.
    func withSharedAccess<Result: Sendable>(
        _ body: @Sendable (State) -> Result
    ) -> Result

    /// Changes the state before returning, except for async barrier writes, which
    /// return after submission. Pass data as `argument` to avoid closure captures.
    func write<Argument: Sendable>(
        _ argument: Argument,
        using body: @escaping @Sendable (inout State, Argument) -> Void
    )

    /// Returns when every submitted write has run. The default does nothing.
    func waitForPendingWrites()

    /// Fills the slot with the CPU where queued writes run. The default does nothing.
    func recordExecutorCPU(into slot: CPUReadingSlot)
}

extension StateProtection {
    func withSharedAccess<Result: Sendable>(
        _ body: @Sendable (State) -> Result
    ) -> Result {
        withExclusiveAccess { state in
            body(state)
        }
    }

    func write<Argument: Sendable>(
        _ argument: Argument,
        using body: @escaping @Sendable (inout State, Argument) -> Void
    ) {
        withExclusiveAccess { state in
            body(&state, argument)
        }
    }

    func waitForPendingWrites() {}

    func recordExecutorCPU(into slot: CPUReadingSlot) {}
}
