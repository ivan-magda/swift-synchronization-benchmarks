enum PriorityInversionChecks {
    /// Invalid and censored trials still pass correctness when their values and exclusion are right.
    static func check(operation: String, trials: [TrialLine], timedOut: Bool, block: Int) -> CheckResult {
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
