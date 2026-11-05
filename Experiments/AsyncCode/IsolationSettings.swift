import IsolationProbeSwift6
import IsolationProbeTemplate

/// Experiment 7C: the main actor calls a nonisolated async function compiled three ways.
/// The probe counts how many calls ran on the main thread, which shows the thread switches.
enum IsolationSettings {
    static func run(_ block: BlockContext) -> [CheckResult] {
        let mechanism = block.description.mechanism
        resetProbe(mechanism: mechanism)

        let mainThreadCPU = MainThreadCPURecorder(batches: block.layout.totalBatches)

        _ = block.runInTasks { _, barrier, log in
            await timeOnMainActor(
                mechanism: mechanism,
                layout: block.layout,
                barrier: barrier,
                log: log,
                mainThreadCPU: mainThreadCPU
            )
        }

        mainThreadCPU.appendLines(to: block)

        let counts = probeCounts(mechanism: mechanism)
        let operations = AsyncCodeChecks.expectedCount(
            threads: block.description.threads,
            layout: block.layout
        )
        return [AsyncCodeChecks.checkMainThreadCalls(
            operation: block.description.operation,
            calls: counts.calls,
            onMainThread: counts.onMainThread,
            expectedCalls: operations,
            expectedOnMainThread: mechanism == "templateDefaults" ? operations : 0,
            block: block.position
        )]
    }

    /// The batch loop inherits the main actor from this function; one operation is one call.
    @MainActor
    private static func timeOnMainActor(
        mechanism: String,
        layout: BatchLayout,
        barrier: TaskBarrier,
        log: ThreadLog,
        mainThreadCPU: MainThreadCPURecorder
    ) async {
        switch mechanism {
        case "templateDefaults":
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { _ in },
                recordBatchEdge: { batch, edge in mainThreadCPU.record(batch: batch, edge: edge) },
                runOperations: { _, _, count in
                    for _ in 0..<count {
                        await IsolationProbeTemplate.IsolationProbe.nonisolatedWork()
                    }
                    return 0
                }
            )
        case "swift6Language":
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { _ in },
                recordBatchEdge: { batch, edge in mainThreadCPU.record(batch: batch, edge: edge) },
                runOperations: { _, _, count in
                    for _ in 0..<count {
                        await IsolationProbeSwift6.IsolationProbe.nonisolatedWork()
                    }
                    return 0
                }
            )
        case "concurrentAttribute":
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { _ in },
                recordBatchEdge: { batch, edge in mainThreadCPU.record(batch: batch, edge: edge) },
                runOperations: { _, _, count in
                    for _ in 0..<count {
                        await IsolationProbeTemplate.IsolationProbe.concurrentWork()
                    }
                    return 0
                }
            )
        default:
            preconditionFailure("AsyncCode.init accepts only the mechanisms of the rows table")
        }
    }

    private static func resetProbe(mechanism: String) {
        switch mechanism {
        case "templateDefaults", "concurrentAttribute":
            IsolationProbeTemplate.IsolationProbe.reset()
        case "swift6Language":
            IsolationProbeSwift6.IsolationProbe.reset()
        default:
            preconditionFailure("AsyncCode.init accepts only the mechanisms of the rows table")
        }
    }

    private static func probeCounts(mechanism: String) -> (calls: Int, onMainThread: Int) {
        switch mechanism {
        case "templateDefaults", "concurrentAttribute":
            IsolationProbeTemplate.IsolationProbe.counts()
        case "swift6Language":
            IsolationProbeSwift6.IsolationProbe.counts()
        default:
            preconditionFailure("AsyncCode.init accepts only the mechanisms of the rows table")
        }
    }
}
