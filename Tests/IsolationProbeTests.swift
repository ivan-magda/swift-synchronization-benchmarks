import IsolationProbeSwift6
import IsolationProbeTemplate
import Testing

@testable import SyncBench

/// Serialized: the probe's counters are shared by every test that calls it.
@Suite(.serialized)
struct IsolationProbeTests {
    @MainActor
    @Test func templateSettingsKeepNonisolatedAsyncOnTheMainThread() async {
        IsolationProbeTemplate.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeTemplate.IsolationProbe.nonisolatedWork()
        }
        #expect(IsolationProbeTemplate.IsolationProbe.counts() == (calls: 10, onMainThread: 10))
    }

    @MainActor
    @Test func swift6SettingsMoveNonisolatedAsyncOffTheMainThread() async {
        IsolationProbeSwift6.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeSwift6.IsolationProbe.nonisolatedWork()
        }
        #expect(IsolationProbeSwift6.IsolationProbe.counts() == (calls: 10, onMainThread: 0))
    }

    @MainActor
    @Test func concurrentAttributeMovesTheCallOffTheMainThread() async {
        IsolationProbeTemplate.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeTemplate.IsolationProbe.concurrentWork()
        }
        #expect(IsolationProbeTemplate.IsolationProbe.counts() == (calls: 10, onMainThread: 0))
    }

    // Experiment 7C in the app: the checks compare the probe's main-thread calls with
    // 0 thread switches (template defaults) and 2 switches (Swift 6, `@concurrent`).
    @Test(.timeLimit(.minutes(1)))
    func isolationSettingsSmokeRunPasses() async throws {
        let request = RunRequest.asyncCodeSmoke(
            variant: "isolationSettings",
            operations: ["callFromMainActor"],
            mechanisms: ["templateDefaults", "swift6Language", "concurrentAttribute"],
            operationsPerBatch: 20
        )
        let attempt = try await runAttempt(request)

        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 3)
        #expect(attempt.checks.count == 3)
        #expect(attempt.checks.allSatisfy { $0["name"] as? String == "asyncCode.callFromMainActor" })
        #expect(attempt.checks.allSatisfy { $0["passed"] as? Bool == true })

        for block in attempt.blocks {
            let position = try #require(block["block"] as? Int)
            let metrics = attempt.lines(type: "samples", block: position).compactMap { $0["metric"] as? String }
            #expect(metrics == ["mainThreadCPUAtBatchStart", "mainThreadCPUAtBatchEnd"])
        }
    }
}
