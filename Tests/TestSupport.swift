import Foundation

@testable import SyncBench

/// Keeps blocking test work off the main thread and the cooperative task pool.
func onBenchmarkThread<Result: Sendable>(
    _ body: @escaping @Sendable () -> Result
) async -> Result {
    await withCheckedContinuation { continuation in
        _ = BenchmarkThread.start(name: "test-worker", qos: .userInitiated) {
            continuation.resume(returning: body())
        }
    }
}

extension RunRequest {
    static var golden: RunRequest {
        RunRequest(
            schema: 1,
            runID: "golden.one-thread.1",
            attemptID: "golden.one-thread.1.attempt1.20261105T000000Z.0000",
            attempt: 1,
            experiment: "baseComparison",
            variant: "oneThread",
            seed: 7,
            smoke: true,
            simulation: nil,
            mechanisms: ["mutex"],
            operations: ["increment"],
            tunables: Tunables(
                threads: 1,
                qos: .userInitiated,
                warmupBatches: 1,
                measuredBatches: 2,
                subBatches: 2,
                operationsPerBatch: ["default": 4],
                referenceLoopIterations: 10,
                repeats: nil
            )
        )
    }
}

extension AsyncCodeTunables {
    static func valid(callsPerTask: Int = 20, warmupCallsPerTask: Int = 2) -> AsyncCodeTunables {
        AsyncCodeTunables(callsPerTask: callsPerTask, warmupCallsPerTask: warmupCallsPerTask)
    }
}

extension PriorityInversionTunables {
    static func valid(
        holderWorkIterations: Int = 10_000,
        loadMilliseconds: Int = 20,
        mainDelayMicroseconds: Int = 1_000,
        pauseMilliseconds: Int = 5,
        warmupTrials: Int = 1,
        trials: Int = 3
    ) -> PriorityInversionTunables {
        PriorityInversionTunables(
            holderWorkIterations: holderWorkIterations,
            loadQoS: .userInitiated,
            loadMilliseconds: loadMilliseconds,
            mainDelayMicroseconds: mainDelayMicroseconds,
            pauseMilliseconds: pauseMilliseconds,
            warmupTrials: warmupTrials,
            trials: trials
        )
    }
}

func fixtureURL(_ name: String) -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures")
        .appending(path: name)
}

struct InvalidRequestCase: Sendable {
    let request: RunRequest
    let field: String

    static let all: [InvalidRequestCase] = {
        let mutations: [(String, (inout RunRequest) -> Void)] = [
            ("schema", { $0.schema = 0 }),
            ("runID", { $0.runID = "" }),
            ("runID", { $0.runID = String(repeating: "a", count: 129) }),
            ("runID", { $0.runID = "nonASCIIé" }),
            ("attemptID", { $0.attemptID = "../escape" }),
            ("attempt", { $0.attempt = 0 }),
            ("seed", { $0.seed = 1 << 53 }),
            ("threads", { $0.tunables.threads = 0 }),
            ("threads", { $0.tunables.threads = 65 }),
            ("warmupBatches", { $0.tunables.warmupBatches = -1 }),
            ("measuredBatches", { $0.tunables.measuredBatches = 0 }),
            ("subBatches", { $0.tunables.subBatches = 0 }),
            ("operationsPerBatch", { $0.tunables.operationsPerBatch = ["mutex": 4] }),
            ("operationsPerBatch", { $0.tunables.operationsPerBatch["mutex"] = 1 }),
            ("operationsPerBatch", { $0.tunables.operationsPerBatch["mutex"] = 3 }),
            ("referenceLoopIterations", { $0.tunables.referenceLoopIterations = 0 }),
            ("callsPerTask", { $0.tunables.asyncCode = .valid(callsPerTask: 0) }),
            ("warmupCallsPerTask", { $0.tunables.asyncCode = .valid(warmupCallsPerTask: -1) }),
            ("holderWorkIterations", { $0.tunables.priorityInversion = .valid(holderWorkIterations: 0) }),
            ("loadMilliseconds", { $0.tunables.priorityInversion = .valid(loadMilliseconds: 0) }),
            ("mainDelayMicroseconds", { $0.tunables.priorityInversion = .valid(mainDelayMicroseconds: -1) }),
            ("pauseMilliseconds", { $0.tunables.priorityInversion = .valid(pauseMilliseconds: -1) }),
            ("warmupTrials", { $0.tunables.priorityInversion = .valid(warmupTrials: -1) }),
            ("trials", { $0.tunables.priorityInversion = .valid(trials: 0) }),
            ("trials", { $0.tunables.priorityInversion = .valid(warmupTrials: Int.max, trials: 1) }),
            (
                "simulation",
                {
                    $0.smoke = false
                    $0.simulation = .crash
                }
            ),
        ]

        return mutations.map { field, mutate in
            var request = RunRequest.golden
            mutate(&request)
            return InvalidRequestCase(request: request, field: field)
        }
    }()
}

enum GoldenAttempt {
    static func conditions(ticks: UInt64, wallClock: String) -> Conditions {
        Conditions(
            thermalState: "nominal",
            lowPowerMode: false,
            batteryState: "charging",
            batteryLevelPermille: 800,
            screenBrightnessPermille: 500,
            debuggerAttached: false,
            applicationState: "active",
            environment: [:],
            ticks: ticks,
            wallClock: wallClock
        )
    }

    static func lines() -> ResultLineBuffer {
        let lines = ResultLineBuffer()
        let phone = PhoneFacts(
            machine: "iPhone99,1",
            osVersion: "27.0",
            osBuild: "24A000",
            cpuCount: 6,
            activeCPUCount: 6,
            performanceLevels: [
                PerformanceLevel(
                    index: 0,
                    name: "Performance",
                    logicalCPUCount: 2,
                    physicalCPUCount: 2,
                    l1DataCacheBytes: 131072,
                    l2CacheBytes: 8_388_608,
                    cpusPerL2: 2
                ),
                PerformanceLevel(
                    index: 1,
                    name: "Efficiency",
                    logicalCPUCount: 4,
                    physicalCPUCount: 4,
                    l1DataCacheBytes: 65536,
                    l2CacheBytes: 4_194_304,
                    cpusPerL2: 4
                ),
            ],
            cacheLineBytes: 128,
            memoryBytes: 8_589_934_592,
            timebaseNumerator: 125,
            timebaseDenominator: 3,
            mainThreadQoSClass: 33,
            mutexDefaultPolicy: "firstfit",
            ulockAdaptiveSpinMicroseconds: nil
        )
        let build = BuildInfo(
            buildID: "0123456789ab-clean-ios26-20261105T000000Z",
            commit: "0123456789ab",
            dirty: false,
            target: "ios26",
            minimumOS: "26.0",
            configuration: "Release"
        )

        lines.append(
            RunLine(
                schema: 1,
                request: .golden,
                build: build,
                phone: phone,
                conditions: conditions(ticks: 100, wallClock: "2026-11-05T00:00:00Z")
            )
        )
        lines.append(
            ReferenceLine(
                when: "start",
                iterations: 10,
                start: 110,
                end: 120,
                cpuReadings: [0, 0]
            )
        )
        lines.append(
            BlockLine(
                block: 0,
                mechanism: "mutex",
                operation: "increment",
                threads: 1,
                qos: .userInitiated,
                operationsPerBatch: 4,
                start: 130,
                end: 200,
                voluntaryContextSwitches: 1,
                involuntaryContextSwitches: 0,
                taskContextSwitches: 1,
                thermalStateAtStart: "nominal",
                thermalStateAtEnd: "nominal"
            )
        )
        lines.append(
            BatchLine(
                block: 0,
                batch: 0,
                thread: 0,
                warmup: true,
                operations: 4,
                start: 140,
                end: 150,
                cpuReadings: [0, 0, 0],
                executorCPUReadings: nil
            )
        )
        lines.append(
            BatchLine(
                block: 0,
                batch: 1,
                thread: 0,
                warmup: false,
                operations: 4,
                start: 160,
                end: 170,
                cpuReadings: [0, 0, 0],
                executorCPUReadings: nil
            )
        )
        lines.append(
            BatchLine(
                block: 0,
                batch: 2,
                thread: 0,
                warmup: false,
                operations: 4,
                start: 180,
                end: 190,
                cpuReadings: [0, 0, 0],
                executorCPUReadings: nil
            )
        )
        lines.append(
            ReferenceLine(
                when: "end",
                iterations: 10,
                start: 210,
                end: 220,
                cpuReadings: [0, 0]
            )
        )
        lines.append(
            EndLine(
                status: "completed",
                reasonCode: nil,
                reason: nil,
                checks: [
                    CheckResult(
                        name: "baseComparison.increment",
                        block: 0,
                        passed: true,
                        detail: "expected 12, got 12",
                        violations: nil
                    )
                ],
                blockLines: 1,
                warmupBatchLines: 1,
                measuredBatchLines: 2,
                conditions: conditions(ticks: 230, wallClock: "2026-11-05T00:00:01Z"),
                thermalChanges: []
            )
        )

        return lines
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

func runAttempt(_ request: RunRequest) async throws -> FinishedAttempt {
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
