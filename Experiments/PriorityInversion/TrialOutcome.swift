extension TrialOutcome {
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
        let arrivedDuringHold = holderAcquire < mainArrival && mainArrival < holderRelease
        guard arrivedDuringHold, mainArrival < loadStop else {
            return .invalid
        }

        return mainAcquire > loadStop ? .censored : .valid
    }
}
