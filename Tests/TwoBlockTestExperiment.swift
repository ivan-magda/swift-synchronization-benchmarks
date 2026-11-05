import Foundation

@testable import SyncBench

/// Exercises real worker paths; variants select failed checks, tasks or sample-only work.
struct TwoBlockTestExperiment: Experiment {
    let request: RunRequest

    init(request: RunRequest) throws(RequestError) {
        self.request = request
    }

    var blocks: [BlockDescription] {
        ["first", "second"].map {
            BlockDescription(
                mechanism: $0, operation: "increment", threads: request.tunables.threads,
                qos: request.tunables.qos, operationsPerBatch: 4)
        }
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        if request.variant == "samples" {
            _ = block.runOnThreads(recording: .samplesOnly) { _, barrier, _ in
                barrier.arriveAndWait()
            }
            block.appendSamples(SamplesLine(
                block: block.position, thread: nil, metric: "clock", unit: "ticks",
                values: [1, 2], cpuAtStart: nil, cpuAtEnd: nil))
            return []
        }

        let logs: [ThreadLog]
        if request.variant == "tasks" {
            logs = block.runInTasks { _, barrier, log in
                await BatchTimer.timeBatches(
                    layout: block.layout, barrier: barrier, log: log,
                    recordExecutorCPU: { $0.store(CPU.current()) },
                    runOperations: { _, _, count in count })
            }
        } else {
            logs = block.runOnThreads { _, barrier, log in
                BatchTimer.timeBatches(
                    layout: block.layout, barrier: barrier, log: log,
                    recordExecutorCPU: { _ in }, waitForPendingWrites: {},
                    runOperations: { _, _, count in count })
            }
        }

        let passed = request.variant != "failedCheck"
            && logs.allSatisfy { log in
                (0..<block.layout.totalBatches).allSatisfy { log.checkValue(ofBatch: $0) == 4 }
            }
        return [CheckResult(
            name: block.description.mechanism + ".count", block: block.position,
            passed: passed, detail: "Each batch must perform four operations", violations: nil)]
    }
}
