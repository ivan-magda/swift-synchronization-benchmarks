import Testing

@testable import SyncBench

@Suite struct HotFlagTests {
    // A missing row, skipped writer or warm-up group sample breaks the run contract.
    @Test(.timeLimit(.minutes(1)))
    func hotFlagSmokeRunPasses() async throws {
        let attempt = try await runAttempt(.hotFlagSmoke)

        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 34)
        #expect(attempt.checks.count == 34)
        #expect(attempt.checks.allSatisfy { $0["passed"] as? Bool == true })
        #expect(Set(attempt.checks.compactMap { $0["name"] as? String }) == [
            "hotFlag.read", "hotFlag.readGroups",
        ])

        let grouped = attempt.blocks(operation: "readGroups")
        #expect(grouped.count == 17)
        for block in grouped {
            let position = try #require(block["block"] as? Int)
            #expect(block["threads"] as? Int == 1)
            #expect(block["qos"] as? String == "userInitiated")
            let samples = attempt.lines(type: "samples", block: position)
            #expect(samples.count == 1)
            let line = try #require(samples.first)
            #expect(line["thread"] as? Int == 0)
            #expect(line["metric"] as? String == "readGroupTime")
            #expect(line["unit"] as? String == "ticks")
            #expect((line["values"] as? [Int])?.count == 20)
        }
        for block in attempt.blocks(operation: "read") {
            let position = try #require(block["block"] as? Int)
            #expect(attempt.lines(type: "samples", block: position).isEmpty)
        }
    }

    // 150 reads cannot be split into two sub-batches of whole 100-read groups.
    @Test func hotFlagRejectsGroupsThatDoNotDivide() throws {
        var request = RunRequest.hotFlagSmoke
        request.operations = ["readGroups"]
        request.tunables.operationsPerBatch = ["default": 150]
        do {
            _ = try ExperimentRegistry.makeExperiment(for: request)
            Issue.record("Accepted an incomplete read group")
        } catch {
            #expect(error.message.contains("operationsPerBatch"))
        }
    }
}

extension RunRequest {
    static var hotFlagSmoke: RunRequest {
        var request = RunRequest.golden
        request.experiment = "hotFlag"
        request.variant = "default"
        request.mechanisms = [
            "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
            "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
            "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
            "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync", "atomic",
            "managedAtomic", "atomicRelaxed", "managedAtomicRelaxed",
        ]
        request.operations = ["read", "readGroups"]
        request.tunables.operationsPerBatch = ["default": 1_000]
        return request
    }
}
