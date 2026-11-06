enum HotFlagChecks {
    struct Observation: Sendable {
        let started: Bool
        let writer: MainThreadWriter.State
        let read: Bool
    }

    static func check(
        _ observation: Observation?, logs: [ThreadLog], block: BlockContext
    ) -> CheckResult {
        let validCounts = logs.allSatisfy { log in
            (0..<block.layout.totalBatches).allSatisfy { batch in
                (0...block.layout.operationsPerBatch).contains(log.checkValue(ofBatch: batch))
            }
        }
        guard let observation else {
            return CheckResult(
                name: "hotFlag.\(block.description.operation)", block: block.position,
                passed: false, detail: "Main-thread writer missed its 1 s deadline", violations: nil
            )
        }
        let state = observation.writer
        return CheckResult(
            name: "hotFlag.\(block.description.operation)", block: block.position,
            passed: observation.started && state.writes > 0 && state.last == observation.read && validCounts,
            detail: "writes \(state.writes); last \(state.last), read \(observation.read)",
            violations: nil
        )
    }
}
