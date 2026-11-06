import Darwin
import Dispatch
import Synchronization
import Testing

@testable import SyncBench

@Test(arguments: [QoS.userInitiated, .utility])
func threadRunsWithRequestedQoS(_ qos: QoS) async {
    let observation = await onBenchmarkThread {
        let observedQoS = Mutex<qos_class_t?>(nil)
        let ranOnMainThread = Mutex(true)

        let thread = BenchmarkThread.start(name: "qos-test", qos: qos) {
            observedQoS.withLock { $0 = qos_class_self() }
            ranOnMainThread.withLock { $0 = pthread_main_np() != 0 }
        }
        thread.join()

        return (observedQoS.withLock { $0 }, ranOnMainThread.withLock { $0 })
    }

    #expect(observation.0 == qos.qosClass)
    #expect(observation.1 == false)
}

@Test func threadLogStartsEmptyAndIsAligned() {
    let log = ThreadLog(batches: 3, readingsPerBatch: 5)

    #expect(log.cpuReadings(ofBatch: 0) == [-1, -1, -1, -1, -1])
    #expect(log.executorCPUReadings(ofBatch: 2) == nil)
    #expect(log.baseAddressForTesting % 128 == 0)

    log.recordCPU(batch: 1, reading: 4, cpu: 7)
    log.executorSlot(batch: 1, reading: 0).store(3)

    #expect(log.cpuReadings(ofBatch: 1) == [-1, -1, -1, -1, 7])
    #expect(log.executorCPUReadings(ofBatch: 1) == [3, -1, -1, -1, -1])
    #expect(log.executorCPUReadings(ofBatch: 0) == nil)

    // A failed CPU query is still an executor reading, rather than an unused batch.
    log.executorSlot(batch: 2, reading: 0).store(-1)

    #expect(log.executorCPUReadings(ofBatch: 2) == [-1, -1, -1, -1, -1])
}

// Catches overlapping batch offsets and executor storage that is not visible after join.
@Test func threadLogPreservesIndependentBatchesAfterJoin() async {
    let log = ThreadLog(batches: 3, readingsPerBatch: 2)

    await onBenchmarkThread {
        let writer = BenchmarkThread.start(name: "log-writer", qos: .userInitiated) {
            log.recordTimes(batch: 0, start: 11, end: 17)
            log.recordTimes(batch: 2, start: 31, end: 43)
            log.recordCheckValue(batch: 0, value: 101)
            log.recordCheckValue(batch: 2, value: 303)
            log.recordCPU(batch: 0, reading: 0, cpu: 4)
            log.recordCPU(batch: 2, reading: 1, cpu: 9)

            let executor = BenchmarkThread.start(name: "executor", qos: .utility) {
                log.executorSlot(batch: 0, reading: 1).store(6)
                log.executorSlot(batch: 2, reading: 0).store(8)
            }
            executor.join()
        }
        writer.join()
    }

    #expect(log.start(ofBatch: 0) == 11)
    #expect(log.end(ofBatch: 0) == 17)
    #expect(log.checkValue(ofBatch: 0) == 101)
    #expect(log.start(ofBatch: 2) == 31)
    #expect(log.end(ofBatch: 2) == 43)
    #expect(log.checkValue(ofBatch: 2) == 303)
    #expect(log.cpuReadings(ofBatch: 0) == [4, -1])
    #expect(log.cpuReadings(ofBatch: 2) == [-1, 9])
    #expect(log.executorCPUReadings(ofBatch: 0) == [-1, 6])
    #expect(log.executorCPUReadings(ofBatch: 2) == [8, -1])
    #expect(log.cpuReadings(ofBatch: 1) == [-1, -1])
    #expect(log.executorCPUReadings(ofBatch: 1) == nil)
}

private final class RoundSlot: Sendable {
    let value = Atomic<Int>(0)
}

@Test(.timeLimit(.minutes(1)))
func threadBarrierReleasesNobodyEarly() async {
    let violations = await onBenchmarkThread {
        let barrier = ThreadBarrier(parties: 4)
        let slots = (0..<4).map { _ in RoundSlot() }
        let violations = Atomic<Int>(0)

        let threads = (0..<4).map { index in
            BenchmarkThread.start(name: "barrier-test", qos: .userInitiated) {
                for round in 1...1_000 {
                    slots[index].value.store(round, ordering: .relaxed)
                    barrier.arriveAndWait()

                    for slot in slots where slot.value.load(ordering: .relaxed) < round {
                        violations.wrappingAdd(1, ordering: .relaxed)
                    }
                }
            }
        }

        for thread in threads {
            thread.join()
        }

        return violations.load(ordering: .relaxed)
    }

    #expect(violations == 0)
}

@Test(.timeLimit(.minutes(1)))
func taskBarrierWorksWithMoreTasksThanCores() async {
    let barrier = TaskBarrier(parties: 12)
    let slots = (0..<12).map { _ in RoundSlot() }
    let violations = Atomic<Int>(0)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<12 {
            group.addTask {
                for round in 1...50 {
                    slots[index].value.store(round, ordering: .relaxed)
                    await barrier.arriveAndWait()

                    for slot in slots where slot.value.load(ordering: .relaxed) < round {
                        violations.wrappingAdd(1, ordering: .relaxed)
                    }
                }
            }
        }
    }

    #expect(violations.load(ordering: .relaxed) == 0)
}

private let callerActorLayout = BatchLayout(
    warmupBatches: 1,
    measuredBatches: 2,
    operationsPerBatch: 2,
    subBatches: 2
)

/// Counts the `runOperations` calls that ran on the main thread.
private func countMainThreadOperations(
    isolation: isolated (any Actor)? = #isolation
) async -> Int {
    let log = ThreadLog(
        batches: callerActorLayout.totalBatches,
        readingsPerBatch: callerActorLayout.subBatches + 1
    )
    var mainThreadCalls = 0

    await BatchTimer.timeBatchesOnCallerIsolation(
        layout: callerActorLayout,
        barrier: TaskBarrier(parties: 1),
        log: log,
        recordExecutorCPU: { _ in },
        runOperations: { _, _, _ in
            if pthread_main_np() != 0 {
                mainThreadCalls += 1
            }
            return 0
        }
    )

    return mainThreadCalls
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func batchTimerRunsOnTheCallersActor() async {
    #expect(await countMainThreadOperations() == 6)

    let detachedCount = await Task.detached {
        await countMainThreadOperations()
    }.value

    #expect(detachedCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func batchEdgesAreReportedAroundEveryBatch() async {
    let log = ThreadLog(
        batches: callerActorLayout.totalBatches,
        readingsPerBatch: callerActorLayout.subBatches + 1
    )
    var edges: [(batch: Int, edge: BatchEdge)] = []

    await BatchTimer.timeBatchesOnCallerIsolation(
        layout: callerActorLayout,
        barrier: TaskBarrier(parties: 1),
        log: log,
        recordExecutorCPU: { _ in },
        recordBatchEdge: { batch, edge in edges.append((batch, edge)) },
        runOperations: { _, _, _ in 0 }
    )

    #expect(edges.map(\.batch) == [0, 0, 1, 1, 2, 2])
    #expect(edges.map(\.edge) == [.start, .end, .start, .end, .start, .end])
}

@Test(arguments: [true, false])
func requireUniqueSelectionRejectsEmptyAndUnknownValues(checkMechanisms: Bool) throws {
    var request = RunRequest.golden
    let mechanisms: Set<String> = ["mutex"]
    let operations: Set<String> = ["increment"]

    if checkMechanisms {
        request.mechanisms = []
    } else {
        request.operations = []
    }
    #expect(throws: RequestError.self) {
        try request.requireUniqueSelection(mechanisms: mechanisms, operations: operations)
    }

    if checkMechanisms {
        request.mechanisms = ["unknown"]
    } else {
        request.operations = ["unknown"]
    }
    #expect(throws: RequestError.self) {
        try request.requireUniqueSelection(mechanisms: mechanisms, operations: operations)
    }

    // A nil allowlist leaves experiment-specific membership validation to the caller.
    try request.requireUniqueSelection(mechanisms: nil, operations: nil)
    try RunRequest.golden.requireUniqueSelection(mechanisms: mechanisms, operations: operations)
}

// Catches validating the request's default count instead of the selected block's count.
@Test func validatedLayoutRejectsInvalidBlockCounts() throws {
    let request = RunRequest.golden

    #expect(throws: RequestError.self) {
        try request.validatedLayout(operationsPerBatch: 3, threads: 2)
    }
    #expect(throws: RequestError.self) {
        try request.validatedLayout(operationsPerBatch: 4, threads: 0)
    }
    #expect(throws: RequestError.self) {
        try request.validatedLayout(operationsPerBatch: Int.max - 1, threads: 2)
    }
    #expect(try request.validatedLayout(operationsPerBatch: 8, threads: 2) == BatchLayout(
        warmupBatches: 1,
        measuredBatches: 2,
        operationsPerBatch: 8,
        subBatches: 2
    ))
}

@Suite struct ThreadStartupTests {
    // Holding the final startup participant must prevent the worker from sampling.
    @Test(.timeLimit(.minutes(1)))
    func threadStartupBlocksSamplingUntilRunSetupFinishes() async {
        let observation = await onBenchmarkThread {
            let startup = ThreadBarrier(parties: 3)
            let sampled = DispatchSemaphore(value: 0)
            let completed = DispatchSemaphore(value: 0)
            let released = DispatchSemaphore(value: 0)
            let owner = BenchmarkThread.start(name: "startup-owner", qos: .userInitiated) {
                let request = RunRequest.golden
                let block = BlockContext(
                    position: 0,
                    description: BlockDescription(
                        mechanism: "test", operation: "sample", threads: 1,
                        qos: .userInitiated, operationsPerBatch: 4
                    ),
                    layout: BatchLayout(
                        warmupBatches: 0, measuredBatches: 1,
                        operationsPerBatch: 4, subBatches: 1
                    ),
                    request: request,
                    lines: ResultLineBuffer()
                )
                _ = block.runOnThreads(recording: .samplesOnly, afterStartup: startup) { _, _, _ in
                    _ = MallocStatistics.read()
                    sampled.signal()
                }
                completed.signal()
            }
            let sampledBeforeRelease = sampled.wait(timeout: .now() + .seconds(1)) == .success
            // Release even when the early-sampling assertion will fail. Waits remain
            // bounded if a broken implementation omitted a barrier participant.
            let releaser = BenchmarkThread.start(name: "startup-release", qos: .userInitiated) {
                startup.arriveAndWait()
                released.signal()
            }
            let ownerCompleted = completed.wait(timeout: .now() + .seconds(1)) == .success
            let gateReleased = released.wait(timeout: .now() + .seconds(1)) == .success
            let sampledAfterRelease = sampledBeforeRelease || sampled.wait(timeout: .now() + .seconds(1)) == .success
            if ownerCompleted { owner.join() }
            if gateReleased { releaser.join() }
            return (sampledBeforeRelease, ownerCompleted, gateReleased, sampledAfterRelease)
        }
        #expect(!observation.0)
        #expect(observation.1)
        #expect(observation.2)
        #expect(observation.3)
    }
}
