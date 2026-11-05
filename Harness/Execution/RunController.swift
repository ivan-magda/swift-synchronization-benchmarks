import Darwin
import Foundation
import os

struct RunOutcome: Equatable, Sendable {
    let status: String
    let reasonCode: String?
    let marker: DoneMarker
}

typealias ExperimentFactory = @Sendable (RunRequest) throws(RequestError) -> any Experiment

enum RunController {
    /// Complete an attempt synchronously on a dedicated pthread, never on main.
    static func runToCompletion(
        _ request: RunRequest,
        writingTo directory: URL,
        makeExperiment: ExperimentFactory = ExperimentRegistry.makeExperiment,
        captureConditions: () -> Conditions = Conditions.captureFromRunThread,
        build: BuildInfo = .current()
    ) -> RunOutcome {
        precondition(pthread_main_np() == 0)
        let phone = PhoneFacts.read()
        let initialConditions = captureConditions()
        let lines = ResultLineBuffer()
        lines.append(RunLine(
            schema: 1,
            request: request,
            build: build,
            phone: phone,
            conditions: initialConditions
        ))

        // Retain the invalid request verbatim in its run line, but never use an unsafe
        // supplied identifier as a path. Such a diagnostic cannot be accepted as a run.
        let fileAttemptID = RunRequest.isValidIdentifier(request.attemptID)
            ? request.attemptID
            : "invalid." + UUID().uuidString

        func finish(
            status: String,
            reasonCode: String? = nil,
            reason: String? = nil,
            checks: [CheckResult] = [],
            warmupBatchLines: Int = 0,
            conditions: Conditions,
            thermalChanges: [ThermalChange] = []
        ) -> RunOutcome {
            lines.append(EndLine(
                status: status,
                reasonCode: reasonCode,
                reason: reason,
                checks: checks,
                blockLines: lines.lineCounts["block", default: 0],
                warmupBatchLines: warmupBatchLines,
                measuredBatchLines: lines.lineCounts["batch", default: 0] - warmupBatchLines,
                conditions: conditions,
                thermalChanges: thermalChanges
            ))

            do {
                let marker = try ResultWriter.write(lines, attemptID: fileAttemptID, to: directory)
                return RunOutcome(status: status, reasonCode: reasonCode, marker: marker)
            } catch {
                fatalError("Cannot publish attempt results: \(error)")
            }
        }

        let experiment: any Experiment
        let descriptions: [BlockDescription]
        do throws(RequestError) {
            try request.validate()
            experiment = try makeExperiment(request)
            descriptions = experiment.blocks
            var batchLines = 0

            for description in descriptions {
                let layout = layout(for: description, request: request)
                try layout.validate(threads: description.threads)
                let count = layout.totalBatches * description.threads
                let (total, overflow) = batchLines.addingReportingOverflow(count)
                guard !overflow else {
                    throw RequestError(message: "run batch line count overflow")
                }
                batchLines = total
            }
        } catch {
            return finish(
                status: "failed",
                reasonCode: "invalidRequest",
                reason: error.message,
                conditions: initialConditions
            )
        }

        if case let .refuse(reason, detail) = Preflight.decide(
            initialConditions,
            build: build,
            request: request
        ) {
            return finish(
                status: "refused",
                reasonCode: reason.rawValue,
                reason: detail,
                conditions: initialConditions
            )
        }

        let monitor = ThermalMonitor()
        monitor.start()
        appendReference(when: "start", request: request, lines: lines)
        let signposter = OSSignposter(subsystem: "SyncBench", category: "block")
        var checks: [CheckResult] = []
        var warmupBatchLines = 0

        for (position, description) in seededShuffle(descriptions, seed: request.seed).enumerated() {
            let block = BlockContext(
                position: position,
                description: description,
                layout: layout(for: description, request: request),
                request: request,
                lines: lines
            )
            let interval = signposter.beginInterval(
                "block",
                "\(description.mechanism, privacy: .public) \(description.operation, privacy: .public)"
            )
            checks.append(contentsOf: experiment.run(block))
            signposter.endInterval("block", interval)
            warmupBatchLines += block.warmupBatchLines

            if position == 0 {
                switch request.simulation {
                case .crash:
                    fatalError("simulated crash")
                case .hang:
                    while true {
                        sleep(3_600)
                    }
                case nil:
                    break
                }
            }
        }

        appendReference(when: "end", request: request, lines: lines)
        let finalConditions = captureConditions()
        let thermalChanges = monitor.stop()
        let failedChecks = checks.filter { !$0.passed }
        return finish(
            status: failedChecks.isEmpty ? "completed" : "failed",
            reasonCode: failedChecks.isEmpty ? nil : "check",
            reason: failedChecks.isEmpty ? nil : failedChecks.map(\.name).joined(separator: ", "),
            checks: checks,
            warmupBatchLines: warmupBatchLines,
            conditions: finalConditions,
            thermalChanges: thermalChanges
        )
    }

    /// The UI callback executes once on main before any measured block starts.
    static func launch(_ request: RunRequest, showStatus: @escaping @Sendable (String) -> Void) {
        _ = BenchmarkThread.start(name: "benchmark-run", qos: .userInitiated) {
            DispatchQueue.main.sync {
                showStatus("running \(request.runID)")
            }

            let directory = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appending(path: "runs")
            _ = runToCompletion(request, writingTo: directory)

            exit(0)
        }
    }

    private static func layout(for block: BlockDescription, request: RunRequest) -> BatchLayout {
        BatchLayout(
            warmupBatches: request.tunables.warmupBatches,
            measuredBatches: request.tunables.measuredBatches,
            operationsPerBatch: block.operationsPerBatch,
            subBatches: request.tunables.subBatches
        )
    }

    private static func appendReference(when: String, request: RunRequest, lines: ResultLineBuffer) {
        let cpuBefore = CPU.current()
        let start = Clock.now()
        let value = referenceLoop(iterations: request.tunables.referenceLoopIterations)
        let end = Clock.now()
        let cpuAfter = CPU.current()
        blackHole(value)
        lines.append(ReferenceLine(
            when: when,
            iterations: request.tunables.referenceLoopIterations,
            start: start,
            end: end,
            cpuReadings: [cpuBefore, cpuAfter]
        ))
    }
}
