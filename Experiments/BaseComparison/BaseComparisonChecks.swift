enum BaseComparisonChecks {
    static let threadStride = 1_000_000_000_000

    /// Requests validate the maximum encoded value before entering a loop.
    static func valueWritten(
        byThread thread: Int,
        operation: Int
    ) -> Int {
        thread * threadStride + (operation + 1)
    }

    static func checkIncrements(
        finalValue: Int,
        threads: Int,
        operationsPerThread: Int,
        block: Int
    ) -> CheckResult {
        let (expected, overflow) = threads.multipliedReportingOverflow(by: operationsPerThread)
        return CheckResult(
            name: "baseComparison.increment",
            block: block,
            passed: !overflow && finalValue == expected,
            detail: "Final value \(finalValue); expected \(threads) × \(operationsPerThread)",
            violations: nil
        )
    }

    /// Divide an even factor before multiplying so every representable sum is accepted.
    static func incrementSum(totalOperations: Int) -> Int? {
        guard totalOperations >= 0 else { return nil }
        let (sum, overflow) = totalOperations.isMultiple(of: 2)
            ? (totalOperations / 2).multipliedReportingOverflow(by: totalOperations + 1)
            : totalOperations.multipliedReportingOverflow(by: totalOperations / 2 + 1)
        return overflow ? nil : sum
    }

    static func checkAsyncIncrements(
        finalValue: Int,
        batchSums: [[Int]],
        threads: Int,
        operationsPerThread: Int,
        block: Int
    ) -> CheckResult {
        let (total, totalOverflow) = threads.multipliedReportingOverflow(by: operationsPerThread)
        let expectedSum = totalOverflow ? nil : incrementSum(totalOperations: total)
        var sum = 0
        var sumOverflow = false
        for batchSum in batchSums.joined() {
            let (next, overflow) = sum.addingReportingOverflow(batchSum)
            sum = next
            sumOverflow = sumOverflow || overflow
        }
        return CheckResult(
            name: "baseComparison.increment",
            block: block,
            passed: !totalOverflow && finalValue == total && !sumOverflow && expectedSum == sum,
            detail: "Final value \(finalValue); expected \(threads) × \(operationsPerThread); returned-value sum \(sum); expected \(expectedSum.map(String.init) ?? "unrepresentable")",
            violations: nil
        )
    }

    static func checkWrites(
        finalValue: Int,
        threads: Int,
        operationsPerThread: Int,
        block: Int
    ) -> CheckResult {
        let passed = threads > 0 && operationsPerThread > 0 && (0..<threads).contains { thread in
            let (base, baseOverflow) = thread.multipliedReportingOverflow(by: threadStride)
            let (last, lastOverflow) = base.addingReportingOverflow(operationsPerThread)
            return !baseOverflow && !lastOverflow && finalValue == last
        }
        return CheckResult(
            name: "baseComparison.write",
            block: block,
            passed: passed,
            detail: "Final value \(finalValue) must be a writer's last encoded value",
            violations: nil
        )
    }

    static func checkReads(
        finalValue: Int,
        batchSums: [[Int]],
        operationsPerBatch: Int,
        block: Int
    ) -> CheckResult {
        let (expected, overflow) = BaseComparison.valueForReads.multipliedReportingOverflow(
            by: operationsPerBatch
        )
        var violations = 0
        for sums in batchSums {
            for sum in sums where overflow || sum != expected {
                violations += 1
            }
        }
        return CheckResult(
            name: "baseComparison.read",
            block: block,
            passed: !overflow && finalValue == BaseComparison.valueForReads && violations == 0,
            detail: "Final value \(finalValue); \(violations) batches have an incorrect read sum",
            violations: violations
        )
    }
}
