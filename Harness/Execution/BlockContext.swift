import Darwin
import Foundation

/// Sample-only workers retain the block envelope but allocate no batch storage.
enum BlockRecording: Sendable {
    case batches
    case samplesOnly
}

/// Immutable configuration is shared with workers. Mutable bookkeeping and line encoding
/// belong exclusively to the creating run pthread, after every worker has completed.
final class BlockContext: @unchecked Sendable {
    let position: Int
    let description: BlockDescription
    let layout: BatchLayout
    let request: RunRequest

    private let lines: ResultLineBuffer
    private let owner: pthread_t
    private var hasRun = false
    private(set) var warmupBatchLines = 0

    /// Trial lines follow every samples line and are ordered by trial.
    private var lastAppendedTrial: Int?

    init(
        position: Int,
        description: BlockDescription,
        layout: BatchLayout,
        request: RunRequest,
        lines: ResultLineBuffer
    ) {
        self.position = position
        self.description = description
        self.layout = layout
        self.request = request
        self.lines = lines
        owner = pthread_self()
    }

    func runOnThreads(
        recording: BlockRecording = .batches,
        _ body: @escaping @Sendable (_ thread: Int, _ barrier: ThreadBarrier, _ log: ThreadLog) -> Void
    ) -> [ThreadLog] {
        beginWorkers()
        let logs = makeLogs(recording: recording)
        let barrier = ThreadBarrier(parties: description.threads)
        let start = Clock.now()
        let switches = ContextSwitches.now()
        let thermal = ProcessInfo.processInfo.thermalState.resultName
        let threads = logs.enumerated().map { index, log in
            BenchmarkThread.start(name: "benchmark-\(position)-\(index)", qos: description.qos) {
                body(index, barrier, log)
            }
        }
        for thread in threads {
            thread.join()
        }

        finish(start: start, switches: switches, thermal: thermal, logs: logs, recording: recording)
        return logs
    }

    /// Allocation-sensitive workers wait until the run pthread finishes launching
    /// all workers. The caller supplies one barrier party per worker plus the run
    /// pthread. This untimed lifecycle overload leaves the original paths unchanged.
    func runOnThreads(
        recording: BlockRecording = .batches,
        afterStartup startup: ThreadBarrier,
        _ body: @escaping @Sendable (_ thread: Int, _ barrier: ThreadBarrier, _ log: ThreadLog) -> Void
    ) -> [ThreadLog] {
        beginWorkers()
        let logs = makeLogs(recording: recording)
        let barrier = ThreadBarrier(parties: description.threads)
        let start = Clock.now()
        let switches = ContextSwitches.now()
        let thermal = ProcessInfo.processInfo.thermalState.resultName
        let threads = logs.enumerated().map { index, log in
            BenchmarkThread.start(name: "benchmark-\(position)-\(index)", qos: description.qos) {
                startup.arriveAndWait()
                body(index, barrier, log)
            }
        }
        // Every handle and the thread array now exist; startup temporaries have left scope.
        startup.arriveAndWait()
        for thread in threads {
            thread.join()
        }

        finish(start: start, switches: switches, thermal: thermal, logs: logs, recording: recording)
        return logs
    }

    /// Workers run at `workerQoS` instead of the block's QoS; the block line still reports
    /// the block's QoS. The body deliberately duplicates `runOnThreads(recording:_:)`, which
    /// stays unchanged so experiment 1's machine code does not change. Keep the two in step.
    func runOnThreads(
        recording: BlockRecording = .batches,
        workerQoS: QoS,
        _ body: @escaping @Sendable (_ thread: Int, _ barrier: ThreadBarrier, _ log: ThreadLog) -> Void
    ) -> [ThreadLog] {
        beginWorkers()
        let logs = makeLogs(recording: recording)
        let barrier = ThreadBarrier(parties: description.threads)
        let start = Clock.now()
        let switches = ContextSwitches.now()
        let thermal = ProcessInfo.processInfo.thermalState.resultName
        let threads = logs.enumerated().map { index, log in
            BenchmarkThread.start(name: "benchmark-\(position)-\(index)", qos: workerQoS) {
                body(index, barrier, log)
            }
        }
        for thread in threads {
            thread.join()
        }

        finish(start: start, switches: switches, thermal: thermal, logs: logs, recording: recording)
        return logs
    }

    /// Detached tasks are intentional: these workers measure the cooperative pool.
    /// Only the dedicated run pthread waits for their completion.
    func runInTasks(
        recording: BlockRecording = .batches,
        _ body: @escaping @Sendable (_ task: Int, _ barrier: TaskBarrier, _ log: ThreadLog) async -> Void
    ) -> [ThreadLog] {
        beginWorkers()
        let logs = makeLogs(recording: recording)
        let barrier = TaskBarrier(parties: description.threads)
        let completion = DispatchGroup()
        let start = Clock.now()
        let switches = ContextSwitches.now()
        let thermal = ProcessInfo.processInfo.thermalState.resultName

        for (index, log) in logs.enumerated() {
            completion.enter()
            Task.detached(priority: description.qos.taskPriority) {
                await body(index, barrier, log)
                completion.leave()
            }
        }

        completion.wait()
        finish(start: start, switches: switches, thermal: thermal, logs: logs, recording: recording)
        return logs
    }

    /// Encode samples after workers finish, never inside measured work.
    func appendSamples(_ line: SamplesLine) {
        precondition(pthread_equal(owner, pthread_self()) != 0)
        precondition(lastAppendedTrial == nil, "Samples lines come before the block's trial lines")
        lines.append(line)
    }

    /// Appends the block's trial lines. Owner thread only; after every samples line of the block.
    func appendTrials(_ trials: [TrialLine]) {
        precondition(pthread_equal(owner, pthread_self()) != 0)

        for trial in trials {
            precondition(trial.block == position, "A trial line belongs to its own block")
            precondition(
                lastAppendedTrial.map { trial.trial > $0 } ?? true,
                "Trial lines are ordered by trial"
            )
            lastAppendedTrial = trial.trial
            lines.append(trial)
        }
    }

    private func beginWorkers() {
        precondition(pthread_main_np() == 0 && pthread_equal(owner, pthread_self()) != 0)
        precondition(!hasRun, "A block has exactly one worker invocation")
        hasRun = true
    }

    private func makeLogs(recording: BlockRecording) -> [ThreadLog] {
        (0..<description.threads).map { _ in
            ThreadLog(
                batches: recording == .batches ? layout.totalBatches : 0,
                readingsPerBatch: recording == .batches ? layout.subBatches + 1 : 0
            )
        }
    }

    private func finish(
        start: UInt64,
        switches: ContextSwitches,
        thermal: String,
        logs: [ThreadLog],
        recording: BlockRecording
    ) {
        let end = Clock.now()
        let delta = ContextSwitches.now() - switches
        let thermalAtEnd = ProcessInfo.processInfo.thermalState.resultName
        lines.append(BlockLine(
            block: position,
            mechanism: description.mechanism,
            operation: description.operation,
            threads: description.threads,
            qos: description.qos,
            operationsPerBatch: description.operationsPerBatch,
            start: start,
            end: end,
            voluntaryContextSwitches: delta.voluntary,
            involuntaryContextSwitches: delta.involuntary,
            taskContextSwitches: delta.task,
            thermalStateAtStart: thermal,
            thermalStateAtEnd: thermalAtEnd
        ))

        guard recording == .batches else {
            return
        }

        for (thread, log) in logs.enumerated() {
            for batch in 0..<layout.totalBatches {
                let warmup = batch < layout.warmupBatches
                if warmup {
                    warmupBatchLines += 1
                }

                lines.append(BatchLine(
                    block: position,
                    batch: batch,
                    thread: thread,
                    warmup: warmup,
                    operations: layout.operationsPerBatch,
                    start: log.start(ofBatch: batch),
                    end: log.end(ofBatch: batch),
                    cpuReadings: log.cpuReadings(ofBatch: batch),
                    executorCPUReadings: log.executorCPUReadings(ofBatch: batch)
                ))
            }
        }
    }
}
