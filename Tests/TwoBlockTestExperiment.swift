import Foundation

@testable import SyncBench

/// Small real-thread experiment for controller status and result-publication tests.
struct TwoBlockTestExperiment: Experiment {
    let request: RunRequest

    init(request: RunRequest) throws(RequestError) {
        self.request = request
    }

    var blocks: [BlockDescription] {
        ["first", "second"].map {
            BlockDescription(
                mechanism: $0,
                operation: "increment",
                threads: request.tunables.threads,
                qos: request.tunables.qos,
                operationsPerBatch: 4
            )
        }
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let logs = block.runOnThreads { _, barrier, log in
            BatchTimer.timeBatches(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { _ in },
                waitForPendingWrites: {},
                runOperations: { _, _, count in count }
            )
        }

        let passed = request.variant != "failedCheck"
            && logs.allSatisfy { log in
                (0..<block.layout.totalBatches).allSatisfy { log.checkValue(ofBatch: $0) == 4 }
            }
        return [CheckResult(
            name: block.description.mechanism + ".count",
            block: block.position,
            passed: passed,
            detail: "Each batch must perform four operations",
            violations: nil
        )]
    }
}
