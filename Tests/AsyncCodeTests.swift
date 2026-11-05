import Foundation
import Testing

@testable import SyncBench

@Suite struct AsyncCodeTests {
    // Every allowed pair of the five paths and five mechanisms runs and keeps its count.
    @Test(.timeLimit(.minutes(1)))
    func callerPathsSmokeRunPasses() async throws {
        let attempt = try await runAsyncCodeAttempt(.callerPathsSmoke)

        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 14)

        let checks = attempt.checks
        #expect(checks.count == 14)
        #expect(checks.allSatisfy { ($0["name"] as? String)?.hasPrefix("asyncCode.") == true })
        #expect(checks.allSatisfy { $0["passed"] as? Bool == true })
    }

    // Path "fromManyTasks" times single calls, so it writes samples instead of batches.
    @Test(.timeLimit(.minutes(1)))
    func fromManyTasksWritesOneCallTimeLinePerTask() async throws {
        let attempt = try await runAsyncCodeAttempt(.callerPathsSmoke)
        let blocks = attempt.blocks(operation: "fromManyTasks")

        #expect(blocks.count == 4)
        for block in blocks {
            let position = try #require(block["block"] as? Int)
            #expect(block["threads"] as? Int == 50)
            #expect(attempt.lines(type: "batch", block: position).isEmpty)

            let samples = attempt.lines(type: "samples", block: position)
            #expect(samples.count == 50)
            #expect(samples.allSatisfy { $0["metric"] as? String == "callTime" })
            #expect(samples.allSatisfy { $0["unit"] as? String == "ticks" })
            #expect(samples.allSatisfy { ($0["values"] as? [Int])?.count == 5 })
            #expect(samples.compactMap { $0["thread"] as? Int } == Array(0..<50))
        }
    }

    // Main-thread CPU time is read at both edges of every batch, warm-up included.
    @Test(.timeLimit(.minutes(1)))
    func mainActorPathsWriteMainThreadCPU() async throws {
        let attempt = try await runAsyncCodeAttempt(.callerPathsSmoke)
        let blocks = attempt.blocks(operation: "fromMainActor") + attempt.blocks(operation: "toMainActor")

        #expect(blocks.count == 5)
        for block in blocks {
            let position = try #require(block["block"] as? Int)
            let samples = attempt.lines(type: "samples", block: position)
            let atStart = try #require(samples.first { $0["metric"] as? String == "mainThreadCPUAtBatchStart" })
            let atEnd = try #require(samples.first { $0["metric"] as? String == "mainThreadCPUAtBatchEnd" })

            #expect(samples.count == 2)
            for line in [atStart, atEnd] {
                #expect(line["unit"] as? String == "microseconds")
                #expect(line["thread"] == nil)
            }

            let startValues = try #require(atStart["values"] as? [Int])
            let endValues = try #require(atEnd["values"] as? [Int])
            #expect(startValues.count == 3)
            #expect(endValues.count == 3)
            #expect(zip(startValues, endValues).allSatisfy { $0 <= $1 })
        }
    }

    // No block may be silently dropped: a request must name only pairs the table allows.
    @Test func rejectsRequestWithoutAllowedPairs() {
        var request = RunRequest.callerPathsSmoke
        request.operations = ["fromMainActor"]
        request.mechanisms = ["mainActor"]

        #expect(throws: RequestError.self) { try AsyncCode(request: request) }
    }

    @Test func rejectsUnusedMechanism() {
        var request = RunRequest.callerPathsSmoke
        request.operations = ["onActor"]
        request.mechanisms = ["actor", "mutex"]

        #expect(throws: RequestError.self) { try AsyncCode(request: request) }
    }

    @Test func rejectsManyTasksWithoutTunables() {
        var request = RunRequest.callerPathsSmoke
        request.tunables.asyncCode = nil

        #expect(throws: RequestError.self) { try AsyncCode(request: request) }
    }

    @Test func rejectsMoreThanOneThread() {
        var request = RunRequest.callerPathsSmoke
        request.tunables.threads = 2

        #expect(throws: RequestError.self) { try AsyncCode(request: request) }
    }

    // One actor await, 100 actor awaits and one lock, each covering 100 increments.
    @Test(.timeLimit(.minutes(1)))
    func batchingSmokeRunPasses() async throws {
        let attempt = try await runAsyncCodeAttempt(.batchingSmoke)

        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 3)
        #expect(Set(attempt.checks.compactMap { $0["name"] as? String }) == [
            "asyncCode.oneAwaitPerGroup", "asyncCode.awaitPerOperation", "asyncCode.oneLockPerGroup",
        ])
        #expect(attempt.checks.allSatisfy { $0["passed"] as? Bool == true })
    }

    // A sub-batch must hold whole groups of 100 operations.
    @Test func batchingRejectsGroupsThatDoNotDivide() {
        var request = RunRequest.batchingSmoke
        request.tunables.operationsPerBatch = ["default": 300]

        #expect(throws: RequestError.self) { try AsyncCode(request: request) }
    }
}

extension RunRequest {
    /// An `asyncCode` smoke request: one warm-up batch, two measured batches, two sub-batches.
    static func asyncCodeSmoke(
        variant: String,
        operations: [String],
        mechanisms: [String],
        operationsPerBatch: Int
    ) -> RunRequest {
        var request = RunRequest.golden
        request.runID = "smoke.async-code.1"
        request.attemptID = "smoke.async-code.1.attempt1.20261105T000000Z.0000"
        request.experiment = "asyncCode"
        request.variant = variant
        request.operations = operations
        request.mechanisms = mechanisms
        request.tunables.warmupBatches = 1
        request.tunables.measuredBatches = 2
        request.tunables.subBatches = 2
        request.tunables.operationsPerBatch = ["default": operationsPerBatch]
        return request
    }

    fileprivate static var callerPathsSmoke: RunRequest {
        var request = asyncCodeSmoke(
            variant: "callerPaths",
            operations: ["onActor", "fromBackgroundTask", "fromManyTasks", "fromMainActor", "toMainActor"],
            mechanisms: ["actor", "mainActor", "mutex", "osAllocatedUnfairLock", "nsLock"],
            operationsPerBatch: 40
        )
        request.tunables.asyncCode = AsyncCodeTunables(callsPerTask: 5, warmupCallsPerTask: 1)
        return request
    }

    fileprivate static var batchingSmoke: RunRequest {
        asyncCodeSmoke(
            variant: "batching",
            operations: ["oneAwaitPerGroup", "awaitPerOperation", "oneLockPerGroup"],
            mechanisms: ["actor", "mutex"],
            operationsPerBatch: 400
        )
    }
}

/// The decoded lines of one finished attempt.
struct FinishedAttempt {
    let status: String
    let lines: [[String: Any]]

    var blocks: [[String: Any]] {
        lines.filter { $0["type"] as? String == "block" }
    }

    var checks: [[String: Any]] {
        lines.last?["checks"] as? [[String: Any]] ?? []
    }

    func blocks(operation: String) -> [[String: Any]] {
        blocks.filter { $0["operation"] as? String == operation }
    }

    func lines(type: String, block: Int) -> [[String: Any]] {
        lines.filter { $0["type"] as? String == type && $0["block"] as? Int == block }
    }
}

func runAsyncCodeAttempt(_ request: RunRequest) async throws -> FinishedAttempt {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let outcome = await onBenchmarkThread {
        RunController.runToCompletion(
            request,
            writingTo: directory,
            captureConditions: {
                GoldenAttempt.conditions(ticks: Clock.now(), wallClock: "2026-11-05T00:00:00Z")
            },
            build: BuildInfo(
                buildID: "test",
                commit: "test",
                dirty: false,
                target: "ios26",
                minimumOS: "26.0",
                configuration: "Release"
            )
        )
    }

    let data = try Data(contentsOf: directory.appending(path: outcome.marker.file))
    let lines = try data.split(separator: 0x0A).map {
        try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
    }
    return FinishedAttempt(status: outcome.status, lines: lines)
}
