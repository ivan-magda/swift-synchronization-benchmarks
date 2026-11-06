enum PriorityInversionChecks {
    /// Invalid and censored trials still pass correctness when their values and exclusion are right.
    static func check(
        operation: String,
        trials: [TrialLine],
        timedOut: Bool,
        block: Int
    ) -> CheckResult {
        let violations = trials.filter { trial in
            !trial.holderResultCorrect
                || trial.mainObservedTrial != trial.trial
                || (trial.mainArrival < trial.holderRelease && trial.mainAcquire < trial.holderRelease)
        }.count

        let valid = trials.filter { $0.outcome == .valid }.count
        let censored = trials.filter { $0.outcome == .censored }.count
        let invalid = trials.filter { $0.outcome == .invalid }.count

        return CheckResult(
            name: "priorityInversion.\(operation)",
            block: block,
            passed: !timedOut && violations == 0,
            detail: "valid \(valid), censored \(censored), invalid \(invalid); timed out \(timedOut)",
            violations: violations
        )
    }
}

enum TrialOutcome: String, Codable, Sendable {
    case valid
    case censored
    case invalid

    /// Valid: the main thread arrived while the holder held the lock and the load ran.
    /// Censored: such an arrival, but the main thread got the lock after the load stopped.
    /// Invalid: everything else. Invalid trials are kept and counted, never used as waits.
    static func classify(
        holderAcquire: UInt64,
        holderRelease: UInt64,
        mainArrival: UInt64,
        mainAcquire: UInt64,
        loadStop: UInt64
    ) -> TrialOutcome {
        let arrivedDuringHold = holderAcquire < mainArrival
            && mainArrival < holderRelease
        guard arrivedDuringHold, mainArrival < loadStop else {
            return .invalid
        }

        return mainAcquire > loadStop ? .censored : .valid
    }
}
