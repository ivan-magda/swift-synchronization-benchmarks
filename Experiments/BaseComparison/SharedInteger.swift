/// One shared integer for synchronous callers in the base comparison.
protocol SharedInteger: Sendable {
    func read() -> Int
    func write(_ value: Int)
    func increment()
    func waitForPendingWrites()
    func recordExecutorCPU(into slot: CPUReadingSlot)

    /// Waits for pending writes before reading the final state.
    func finalValue() -> Int
}

extension SharedInteger {
    func waitForPendingWrites() {
    }

    func recordExecutorCPU(into slot: CPUReadingSlot) {
    }

    func finalValue() -> Int {
        waitForPendingWrites()
        return read()
    }
}

/// The shared-integer operations for callers that await an actor.
protocol AsyncSharedInteger: Sendable {
    func read() async -> Int
    func write(_ value: Int) async
    /// Increments the value and returns its new value on the same executor.
    func increment() async -> Int

    /// Reads the CPU number on the integer's executor.
    func executorCPU() async -> Int

    func finalValue() async -> Int
}
