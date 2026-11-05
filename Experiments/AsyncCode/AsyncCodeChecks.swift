enum AsyncCodeChecks {
    /// The counter must end at the number of increments the block made.
    static func checkCount(operation: String, finalValue: Int, expected: Int, block: Int) -> CheckResult {
        CheckResult(
            name: "asyncCode.\(operation)",
            block: block,
            passed: finalValue == expected,
            detail: "Final value \(finalValue); expected \(expected)",
            violations: nil
        )
    }

    /// Increments of a batch-timed block: threads × batches × operations per batch.
    /// `AsyncCode.init` validated the layout, so the product fits Int.
    static func expectedCount(threads: Int, layout: BatchLayout) -> Int {
        threads * layout.totalBatches * layout.operationsPerBatch
    }

    /// Increments of path "fromManyTasks": warm-up and timed calls of every task.
    /// `AsyncCode.init` checked the product for overflow.
    static func expectedCount(tasks: Int, asyncCode: AsyncCodeTunables) -> Int {
        tasks * (asyncCode.warmupCallsPerTask + asyncCode.callsPerTask)
    }

    /// Experiment 7C: every call reached the probe, and the expected number ran on the main thread.
    static func checkMainThreadCalls(
        operation: String,
        calls: Int,
        onMainThread: Int,
        expectedCalls: Int,
        expectedOnMainThread: Int,
        block: Int
    ) -> CheckResult {
        CheckResult(
            name: "asyncCode.\(operation)",
            block: block,
            passed: calls == expectedCalls && onMainThread == expectedOnMainThread,
            detail: "calls \(calls)/\(expectedCalls); on main thread \(onMainThread), expected \(expectedOnMainThread)",
            violations: nil
        )
    }
}
