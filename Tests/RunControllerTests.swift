import CryptoKit
import Foundation
import Testing

@testable import SyncBench

@Suite struct RunControllerTests {
    // Missing/reordered records or an inaccurate marker makes a completed attempt unusable.
    @Test func completedRunHasLinesInOrder() async throws {
        let run = try await recordRun()

        #expect(run.lines.map { $0["type"] as? String } == [
            "run", "reference", "block", "batch", "batch", "batch",
            "block", "batch", "batch", "batch", "reference", "end",
        ])
        #expect(run.outcome.status == "completed")
        #expect(run.outcome.reasonCode == nil)

        let end = try #require(run.lines.last)
        #expect(end["blockLines"] as? Int == 2)
        #expect(end["warmupBatchLines"] as? Int == 2)
        #expect(end["measuredBatchLines"] as? Int == 4)
        #expect(run.marker == run.outcome.marker)
        #expect(run.marker.bytes == run.data.count)
        #expect(run.marker.sha256 == SHA256.hash(data: run.data)
            .map { String(format: "%02x", $0) }.joined())
        #expect(run.marker.attemptID == RunRequest.golden.attemptID)

        for block in run.lines.filter({ $0["type"] as? String == "block" }) {
            let position = try #require(block["block"] as? Int)
            let start = try #require(block["start"] as? UInt64)
            let end = try #require(block["end"] as? UInt64)

            for batch in run.lines.filter({
                $0["type"] as? String == "batch" && $0["block"] as? Int == position
            }) {
                #expect(try #require(batch["start"] as? UInt64) >= start)
                #expect(try #require(batch["end"] as? UInt64) <= end)
                #expect(batch["operations"] as? Int == 4)
                #expect((batch["cpuReadings"] as? [Int])?.count == 3)
            }
        }
    }

    // These orders are hand-derived from SplitMix64's low bit for the two seeds.
    @Test(arguments: [(UInt64(1), ["first", "second"]), (UInt64(2), ["second", "first"])])
    func blocksFollowTheSeededOrder(_ seed: UInt64, _ expected: [String]) async throws {
        var request = RunRequest.golden
        request.seed = seed

        let run = try await recordRun(request)
        let mechanisms = run.lines.filter { $0["type"] as? String == "block" }
            .compactMap { $0["mechanism"] as? String }
        #expect(mechanisms == expected)
    }

    // A Debug test build must still reach thermal refusal when supplied Release metadata.
    @Test func refusalWritesOnlyRunAndEnd() async throws {
        var request = RunRequest.golden
        request.smoke = false

        let run = try await recordRun(request, conditions: testConditions(thermal: "serious"))
        #expect(run.lines.map { $0["type"] as? String } == ["run", "end"])
        #expect(run.outcome.status == "refused")
        #expect(run.outcome.reasonCode == "thermal")
        #expect(run.lines.last?["blockLines"] as? Int == 0)
        #expect(run.lines.last?["measuredBatchLines"] as? Int == 0)
    }

    @Test func invalidRequestFails() async throws {
        let run = try await recordRun(makeExperiment: { _ throws(RequestError) in
            throw RequestError(message: "unknown experiment")
        })

        #expect(run.lines.map { $0["type"] as? String } == ["run", "end"])
        #expect(run.outcome.status == "failed")
        #expect(run.outcome.reasonCode == "invalidRequest")
        #expect(run.lines.last?["reason"] as? String == "unknown experiment")
    }

    @Test func failedCheckFailsTheRun() async throws {
        var request = RunRequest.golden
        request.variant = "failedCheck"

        let run = try await recordRun(request)
        #expect(run.outcome.status == "failed")
        #expect(run.outcome.reasonCode == "check")

        let reason = try #require(run.lines.last?["reason"] as? String)
        #expect(reason.contains("first.count"))
        #expect(reason.contains("second.count"))
    }

    // An unsafe requested ID must never escape the output directory, even on failure.
    @Test func unsafeAttemptIDUsesSafeDiagnosticFile() async throws {
        var request = RunRequest.golden
        request.attemptID = "../escape"

        let run = try await recordRun(request)
        #expect(run.outcome.reasonCode == "invalidRequest")
        #expect(RunRequest.isValidIdentifier(run.marker.attemptID))
        #expect(run.marker.file == run.marker.attemptID + ".jsonl")
        #expect((run.lines.first?["request"] as? [String: Any])?["attemptID"] as? String == "../escape")
    }

    // Checks govern completion; changed end conditions remain available to the file checker.
    @Test func endConditionsAreRecordedWithoutOverridingPassedChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = await onBenchmarkThread {
            var calls = 0
            return RunController.runToCompletion(
                .golden,
                writingTo: directory,
                makeExperiment: TwoBlockTestExperiment.init,
                captureConditions: {
                    calls += 1
                    return testConditions(thermal: calls == 1 ? "nominal" : "serious")
                },
                build: releaseBuild
            )
        }
        let lines = try readLines(Data(contentsOf: directory.appending(path: outcome.marker.file)))

        #expect(outcome.status == "completed")
        #expect((lines.last?["conditions"] as? [String: Any])?["thermalState"] as? String == "serious")
    }

    // Arithmetic overflow must become invalidRequest before allocation or a timing loop.
    @Test(arguments: ["totalBatches", "readings", "aggregate"])
    func impossibleStorageFailsValidation(_ field: String) async throws {
        var request = RunRequest.golden
        switch field {
        case "totalBatches":
            request.tunables.warmupBatches = Int.max
        case "readings":
            request.tunables.subBatches = Int.max
            request.tunables.operationsPerBatch["default"] = Int.max
        default:
            request.tunables.threads = 64
            request.tunables.measuredBatches = Int.max / 512
        }

        let run = try await recordRun(request)
        #expect(run.outcome.reasonCode == "invalidRequest")
        #expect(run.lines.map { $0["type"] as? String } == ["run", "end"])
    }
}

private let releaseBuild = BuildInfo(
    buildID: "test",
    commit: "test",
    dirty: false,
    target: "ios26",
    minimumOS: "26.0",
    configuration: "Release"
)

private func testConditions(thermal: String = "nominal") -> Conditions {
    Conditions(
        thermalState: thermal,
        lowPowerMode: false,
        batteryState: "charging",
        batteryLevelPermille: 800,
        screenBrightnessPermille: 500,
        debuggerAttached: false,
        applicationState: "active",
        environment: [:],
        ticks: Clock.now(),
        wallClock: "2026-11-05T00:00:00Z"
    )
}

private struct RecordedRun {
    let outcome: RunOutcome
    let marker: DoneMarker
    let data: Data
    let lines: [[String: Any]]
}

private func recordRun(
    _ request: RunRequest = .golden,
    conditions: Conditions = testConditions(),
    makeExperiment: @escaping @Sendable (RunRequest) throws(RequestError) -> any Experiment = TwoBlockTestExperiment.init
) async throws -> RecordedRun {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outcome = await onBenchmarkThread {
        RunController.runToCompletion(
            request,
            writingTo: directory,
            makeExperiment: makeExperiment,
            captureConditions: { conditions },
            build: releaseBuild
        )
    }
    let data = try Data(contentsOf: directory.appending(path: outcome.marker.file))
    let marker = try JSONDecoder().decode(
        DoneMarker.self,
        from: Data(contentsOf: directory.appending(path: outcome.marker.attemptID + ".done"))
    )
    return RecordedRun(outcome: outcome, marker: marker, data: data, lines: try readLines(data))
}

private func readLines(_ data: Data) throws -> [[String: Any]] {
    try data.split(separator: 0x0A).map {
        try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
    }
}
