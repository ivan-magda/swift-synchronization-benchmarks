enum TransactionalStoreChecks {
    static func check(
        _ store: some RecordStore, workers: [StoreWorker], logs: [ThreadLog], block: BlockContext
    ) -> CheckResult {
        let groupSize = block.description.operation == TransactionalStore.Operation.singleRecord.rawValue ? 1 : 20
        var expectedVersions = Array(repeating: 0, count: 10_000 / groupSize)
        for worker in workers {
            for run in worker.operations.runs {
                for index in run.writes {
                    expectedVersions[worker.operations.groups[index]] += 1
                }
            }
        }
        let violations = workers.reduce(0) { $0 + $1.violations }
        let validGroups = expectedVersions.enumerated().allSatisfy { group, expected in
            let read = store.readGroup(group)
            return read.versionsMatch && read.version == expected && read.sum == expected * groupSize
        }
        let writes = block.layout.totalBatches * (block.layout.operationsPerBatch / 50) * workers.count
        let maximumSum = writes * groupSize * (block.layout.operationsPerBatch - block.layout.operationsPerBatch / 50)
        let validSums = logs.allSatisfy { log in
            (0..<block.layout.totalBatches).allSatisfy { (0...maximumSum).contains(log.checkValue(ofBatch: $0)) }
        }
        return CheckResult(name: "transactionalStore.\(block.description.operation)", block: block.position,
            passed: violations == 0 && validGroups && validSums,
            detail: "violations \(violations); groups \(expectedVersions.count) with expected versions",
            violations: violations)
    }
}
