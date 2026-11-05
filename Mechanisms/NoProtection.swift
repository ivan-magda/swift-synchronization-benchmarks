/// The single-thread floor. The caller must confine all access to one thread;
/// unchecked Sendable permits transfer to the benchmark's owning thread only.
final class NoProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        body(&state)
    }
}
