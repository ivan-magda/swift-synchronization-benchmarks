enum RequestRegistryChecks {
    static func check(
        _ registry: some DownloadRegistry, workers: [RegistryWorker],
        logs: [ThreadLog], block: BlockContext
    ) -> CheckResult {
        let added = workers.reduce(0) { $0 + $1.added }
        let removed = workers.reduce(0) { $0 + $1.removed }
        let cancelled = workers.reduce(0) { $0 + $1.cancelled }
        let left = registry.cancelAll()
        let cancelCalls = workers.reduce(0) { total, worker in
            total + worker.downloads.reduce(0) { $0 + $1.cancelCount.load(ordering: .relaxed) }
        }
        let tunables = block.request.tunables.requestRegistry!
        let expectedAdded = block.description.threads
            * (tunables.inFlightPerThread + block.layout.totalBatches * block.layout.operationsPerBatch / 2)
        let work = Int(truncatingIfNeeded: referenceLoop(iterations: tunables.workIterations))
            &* block.layout.operationsPerBatch
        let validWork = logs.allSatisfy { log in
            (0..<block.layout.totalBatches).allSatisfy { log.checkValue(ofBatch: $0) == work }
        }
        return CheckResult(
            name: "requestRegistry.addAndRemove", block: block.position,
            passed: left == 0 && added == expectedAdded && added == removed + cancelled
                && cancelCalls == cancelled && validWork,
            detail: "added \(added), removed \(removed), cancelled \(cancelled), left \(left)",
            violations: nil
        )
    }
}
