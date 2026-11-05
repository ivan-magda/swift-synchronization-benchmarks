import Foundation
import Testing

@testable import SyncBench

@Suite struct CalibrationTests {
    // Missing worker samples, CPU arrays, or any block must fail persisted-run validation.
    @Test(.timeLimit(.minutes(1)))
    func calibrationWritesAllSamples() async throws {
        let request = calibrationRequest()
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

        #expect(outcome.status == "completed")

        let data = try Data(contentsOf: directory.appending(path: outcome.marker.file))
        let lines = try data.split(separator: 0x0A).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }

        let run = try #require(lines.first)
        let phone = try #require(run["phone"] as? [String: Any])
        let cpuCount = try #require(phone["cpuCount"] as? Int)
        let blocks = lines.filter { $0["type"] as? String == "block" }
        let samples = lines.filter { $0["type"] as? String == "samples" }

        #expect(blocks.count == 5)
        #expect(samples.count == 2 + 3 * cpuCount)
        #expect(!lines.contains { $0["type"] as? String == "batch" })
        #expect(Set(blocks.compactMap { $0["mechanism"] as? String }) == [
            "clockSingleThread",
            "clockAllCPUs",
            "cpuSpeedUserInteractive",
            "cpuSpeedBackground",
            "holderWorkSingleThread"
        ])
        for block in blocks {
            let position = try #require(block["block"] as? Int)
            let name = try #require(block["mechanism"] as? String)
            let threads = name.hasSuffix("SingleThread") ? 1 : cpuCount
            let records = samples.filter { $0["block"] as? Int == position }

            #expect(block["operation"] as? String == "")
            #expect(block["threads"] as? Int == threads)
            #expect(
                block["qos"] as? String == (name == "cpuSpeedBackground" ? "background" : "userInteractive")
            )
            #expect(records.count == threads)
            #expect(Set(records.compactMap { $0["thread"] as? Int }) == Set(0..<threads))

            for record in records {
                #expect((record["values"] as? [UInt64])?.count == 5)
                #expect(record["unit"] as? String == "ticks")

                if name.hasPrefix("clock") {
                    #expect(record["metric"] as? String == "clockRead1000")
                    #expect(record["cpuAtStart"] == nil)
                    #expect(record["cpuAtEnd"] == nil)
                } else {
                    // holderWork must not reuse referenceLoop: the core map pools every referenceLoop line.
                    let metric = name.hasPrefix("cpuSpeed") ? "referenceLoop" : "holderWork"
                    #expect(record["metric"] as? String == metric)
                    #expect((record["cpuAtStart"] as? [Int])?.count == 5)
                    #expect((record["cpuAtEnd"] as? [Int])?.count == 5)
                }
            }
        }

        let end = try #require(lines.last)
        let checks = try #require(end["checks"] as? [[String: Any]])
        #expect(checks.count == 5)
        #expect(
            checks.allSatisfy {
                $0["name"] as? String == "calibration.samples" && $0["passed"] as? Bool == true
            }
        )
        #expect(end["warmupBatchLines"] as? Int == 0)
        #expect(end["measuredBatchLines"] as? Int == 0)
    }

    // Invalid selection or repeat counts must be rejected before any worker allocation.
    @Test(arguments: [
        "variant", "mechanisms", "operations", "missingRepeats", "zeroRepeats",
        "negativeRepeats", "overflowRepeats"
    ])
    func rejectsInvalidRequests(_ field: String) {
        var request = calibrationRequest()

        switch field {
        case "variant":
            request.variant = "unknown"
        case "mechanisms":
            request.mechanisms = ["mutex"]
        case "operations":
            request.operations = ["read"]
        case "missingRepeats":
            request.tunables.repeats = nil
        case "zeroRepeats":
            request.tunables.repeats = 0
        case "negativeRepeats":
            request.tunables.repeats = -1
        default:
            request.tunables.repeats = Int.max
        }

        do {
            _ = try Calibration(request: request)
            Issue.record("Accepted invalid \(field)")
        } catch {
            #expect(
                error.message.localizedCaseInsensitiveContains(field.contains("Repeats") ? "repeats" : field)
            )
        }
    }

}

private func calibrationRequest() -> RunRequest {
    var request = RunRequest.golden
    request.experiment = "calibration"
    request.variant = "default"
    request.mechanisms = []
    request.operations = []
    request.tunables.referenceLoopIterations = 1_000
    request.tunables.repeats = 5

    return request
}
