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
    func waitForPendingWrites() {}

    func recordExecutorCPU(into slot: CPUReadingSlot) {}

    func finalValue() -> Int {
        waitForPendingWrites()
        return read()
    }
}

/// The shared-integer operations for callers that await an actor.
protocol AsyncSharedInteger: Sendable {
    func read() async -> Int
    func write(_ value: Int) async
    func increment() async

    /// Reads the CPU number on the integer's executor.
    func executorCPU() async -> Int

    func finalValue() async -> Int
}

/// Reads use shared access; mutations follow the protection's write contract.
struct ProtectedInteger<Protection: StateProtection>: SharedInteger where Protection.State == Int {
    private let protection: Protection

    init(_ protection: Protection) {
        self.protection = protection
    }

    func read() -> Int {
        protection.withSharedAccess { $0 }
    }

    func write(_ value: Int) {
        protection.write(value) { state, value in
            state = value
        }
    }

    func increment() {
        protection.write(1) { state, increment in
            state &+= increment
        }
    }

    func waitForPendingWrites() {
        protection.waitForPendingWrites()
    }

    func recordExecutorCPU(into slot: CPUReadingSlot) {
        protection.recordExecutorCPU(into: slot)
    }
}
