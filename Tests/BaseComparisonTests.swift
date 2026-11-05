import Foundation
import Testing

@testable import SyncBench

@Suite struct BaseComparisonTests {
    // A lost update must fail even though every worker completes its timing loop.
    @Test func incrementCheck() {
        let correct = BaseComparisonChecks.checkIncrements(
            finalValue: 20,
            threads: 2,
            operationsPerThread: 10,
            block: 3
        )
        let lostIncrement = BaseComparisonChecks.checkIncrements(
            finalValue: 19,
            threads: 2,
            operationsPerThread: 10,
            block: 3
        )

        #expect(correct.passed)
        #expect(correct.name == "baseComparison.increment")
        #expect(correct.block == 3)
        #expect(!lostIncrement.passed)
    }

    // An earlier value from any writer cannot stand in for its final write.
    @Test(arguments: [
        (10, true),
        (1_000_000_000_010, true),
        (1_000_000_000_009, false),
        (0, false)
    ])
    func writeCheckAcceptsOnlyALastValue(_ finalValue: Int, _ passed: Bool) {
        let result = BaseComparisonChecks.checkWrites(
            finalValue: finalValue,
            threads: 2,
            operationsPerThread: 10,
            block: 4
        )

        #expect(result.passed == passed)
        #expect(result.name == "baseComparison.write")
        #expect(result.block == 4)
        #expect(BaseComparisonChecks.valueWritten(byThread: 1, operation: 9) == 1_000_000_000_010)
    }

    // Reader corruption and an unexpected final state are independent failures.
    @Test(arguments: [
        (42, [[168, 168], [168, 167]], false, 1),
        (41, [[168, 168]], false, 0),
        (42, [[168, 168]], true, 0)
    ])
    func readCheckCountsBadBatches(
        _ finalValue: Int, _ sums: [[Int]], _ passed: Bool, _ violations: Int
    ) {
        let result = BaseComparisonChecks.checkReads(
            finalValue: finalValue,
            batchSums: sums,
            operationsPerBatch: 4,
            block: 5
        )

        #expect(result.passed == passed)
        #expect(result.violations == violations)
        #expect(result.name == "baseComparison.read")
        #expect(result.block == 5)
    }

    // Every rejected request must explain which selection is invalid.
    @Test(arguments: InvalidBaseRequest.all)
    fileprivate func invalidRequests(_ invalid: InvalidBaseRequest) {
        do {
            _ = try BaseComparison(request: invalid.request)
            Issue.record("Accepted invalid \(invalid.field)")
        } catch {
            #expect(error.message.contains(invalid.field))
        }
    }

    // Counts can fit one batch and still overflow cumulative work, read sums or write encoding.
    @Test(arguments: ["increment", "read", "write"])
    func rejectsUnrepresentableWork(_ operation: String) {
        var request = RunRequest.golden
        request.operations = [operation]
        request.tunables.subBatches = 1
        request.tunables.warmupBatches = 0
        request.tunables.measuredBatches = operation == "increment" ? 3 : 1
        request.tunables.operationsPerBatch = ["default": operation == "increment" ? Int.max / 2 : Int.max]

        if operation == "write" {
            request.variant = "twoThreads"
            request.tunables.threads = 2
            request.tunables.operationsPerBatch = ["default": Int.max / 2]
            request.tunables.measuredBatches = 2
        }

        #expect(throws: RequestError.self) { try BaseComparison(request: request) }
    }

    // Validation must reject overflow, without imposing a fixed operation-count ceiling.
    @Test func acceptsRepresentableLargeWork() throws {
        var request = RunRequest.golden
        request.operations = ["write"]
        request.tunables.warmupBatches = 0
        request.tunables.measuredBatches = 1
        request.tunables.subBatches = 1
        request.tunables.operationsPerBatch = ["default": Int.max]

        let experiment = try BaseComparison(request: request)
        #expect(experiment.blocks.first?.operationsPerBatch == Int.max)
    }

    // Wrong expansion order or ignoring a per-mechanism override changes the benchmark.
    @Test func blocksUseRequestOrderAndMechanismBatchSizes() throws {
        var request = RunRequest.golden
        request.mechanisms = ["actor", "mutex"]
        request.operations = ["write", "read"]
        request.tunables.operationsPerBatch["actor"] = 2

        let blocks = try BaseComparison(request: request).blocks
        #expect(blocks.map(\.mechanism) == ["actor", "actor", "mutex", "mutex"])
        #expect(blocks.map(\.operation) == ["write", "read", "write", "read"])
        #expect(blocks.map(\.operationsPerBatch) == [2, 2, 4, 4])
    }

    // All concrete rows must execute every operation, warm-up and measured work through the registry.
    @Test(.timeLimit(.minutes(1)), arguments: [1, 2])
    func smokeAllMechanisms(_ threads: Int) async throws {
        var request = RunRequest.golden
        request.variant = threads == 1 ? "oneThread" : "twoThreads"
        request.tunables.threads = threads
        request.mechanisms = MechanismID.allCases
            .filter { threads == 1 || $0 != .unsynchronized }
            .map(\.rawValue)
        request.operations = ["read", "write", "increment"]
        request.tunables.subBatches = 4
        request.tunables.operationsPerBatch = ["default": 4_000, "actor": 400, "mainActor": 80]

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = request
        let outcome = await onBenchmarkThread {
            RunController.runToCompletion(
                input,
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
        let blocks = lines.filter { $0["type"] as? String == "block" }
        let batches = lines.filter { $0["type"] as? String == "batch" }

        #expect(blocks.count == (threads == 1 ? 60 : 57))
        #expect(batches.count == (threads == 1 ? 180 : 342))

        let end = try #require(lines.last)
        let checks = try #require(end["checks"] as? [[String: Any]])
        #expect(checks.count == blocks.count)
        #expect(checks.allSatisfy { $0["passed"] as? Bool == true })
        #expect(end["warmupBatchLines"] as? Int == (threads == 1 ? 60 : 114))
        #expect(end["measuredBatchLines"] as? Int == (threads == 1 ? 120 : 228))

        for block in blocks {
            let position = try #require(block["block"] as? Int)
            let mechanism = try #require(block["mechanism"] as? String)
            let operations = mechanism == "actor" ? 400 : mechanism == "mainActor" ? 80 : 4_000
            let records = batches.filter { $0["block"] as? Int == position }

            #expect(records.count == 3 * threads)
            #expect(records.allSatisfy { $0["operations"] as? Int == operations })

            if mechanism == "actor" || mechanism == "mainActor" || mechanism == "barrierQueueAsyncWrite" {
                #expect(records.allSatisfy { ($0["executorCPUReadings"] as? [Int])?.count == 5 })
            }
        }
    }
}

private struct InvalidBaseRequest: Sendable {
    let request: RunRequest
    let field: String

    static let all: [Self] = {
        let mutations: [(String, (inout RunRequest) -> Void)] = [
            ("variant", { $0.variant = "unknown" }),
            ("threads", { $0.tunables.threads = 2 }),
            ("mechanisms", { $0.mechanisms = [] }),
            ("mechanisms", { $0.mechanisms = ["mutex", "mutex"] }),
            ("mechanisms", { $0.mechanisms = ["spinlock"] }),
            ("unsynchronized", {
                $0.variant = "twoThreads"
                $0.tunables.threads = 2
                $0.mechanisms = ["unsynchronized"]
            }),
            ("operations", { $0.operations = [] }),
            ("operations", { $0.operations = ["read", "read"] }),
            ("operations", { $0.operations = ["unknown"] }),
        ]
        return mutations.map { field, mutate in
            var request = RunRequest.golden
            mutate(&request)
            return Self(request: request, field: field)
        }
    }()
}
