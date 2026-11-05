import Darwin
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

@Test func clockNeverGoesBack() {
    var previous = Clock.now()

    for _ in 0..<1_000 {
        let current = Clock.now()
        #expect(current >= previous)
        previous = current
    }

    #expect(Clock.timebase.numer > 0)
    #expect(Clock.timebase.denom > 0)
}

@Test func contextSwitchCountersOnlyGrow() async {
    let readings = await onBenchmarkThread {
        let earlier = ContextSwitches.now()
        let thread = BenchmarkThread.start(name: "switch-test", qos: .utility) {}
        thread.join()
        return (earlier, ContextSwitches.now())
    }

    #expect(readings.1.voluntary >= readings.0.voluntary)
    #expect(readings.1.involuntary >= readings.0.involuntary)
    #expect(readings.1.task >= readings.0.task)
    #expect(
        ContextSwitches(voluntary: 17, involuntary: 11, task: 29)
            - ContextSwitches(voluntary: 3, involuntary: 5, task: 7)
            == ContextSwitches(voluntary: 14, involuntary: 6, task: 22)
    )
}
