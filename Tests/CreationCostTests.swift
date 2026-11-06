import Dispatch
import Synchronization
import Testing

@testable import SyncBench

// Malloc statistics cover this process, so these allocation-heavy tests run in order.
@Suite(.serialized) struct CreationCostTests {
    // Skipped destruction or a missing row must reject the full run.
    @Test(.timeLimit(.minutes(1)))
    func creationCostSmokeRunPasses() async throws {
        let attempt = try await runAttempt(.creationCostSmoke)
        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 30)
        #expect(attempt.checks.count == 30)
        for check in attempt.checks {
            let row = attempt.blocks.first { $0["block"] as? Int == check["block"] as? Int }
            #expect(check["passed"] as? Bool == true, "\(String(describing: row)); \(check)")
        }
        for block in attempt.blocks {
            let position = try #require(block["block"] as? Int)
            let samples = attempt.lines(type: "samples", block: position)
            #expect(samples.count == (block["operation"] as? String == "create" ? 6 : 0))
            for sample in samples {
                #expect(sample["thread"] == nil)
                #expect((sample["values"] as? [UInt64])?.count == 3)
            }
        }
    }

    // With no warm-up, the first snapshot still waits for the run pthread's setup.
    @Test(.timeLimit(.minutes(1)))
    func creationCostWithoutWarmupWaitsForStartup() async throws {
        var request = RunRequest.creationCostSmoke
        request.tunables.warmupBatches = 0
        request.mechanisms = ["unsynchronized", "mainActor"]
        let attempt = try await runAttempt(request)
        #expect(attempt.status == "completed")
        #expect(attempt.checks.count == 4)
        for check in attempt.checks {
            #expect(check["passed"] as? Bool == true, "\(check)")
        }
    }

    // A stack-promoted or prematurely released class fails the per-object heap proof.
    @Test func unprotectedObjectsAreHeapBlocks() {
        let counter = CreationDeinitCounter()
        var objects: ContiguousArray<UnprotectedObject> = []
        objects.reserveCapacity(1_000)
        CreationCost.createLoop(&objects, count: 1_000, counter: counter, make: UnprotectedObject.init)
        #expect(CreationCostChecks.heapBlockCount(objects) == 1_000)
        #expect(counter.value == 0)
        objects.removeAll()
        #expect(counter.value == 1_000)
    }

    // Starting before submission cleanup can corrupt process-wide malloc deltas.
    @Test func mainThreadBatchWaitsForCallerPreparation() async {
        let published = await onBenchmarkThread {
            let ready = DispatchSemaphore(value: 0)
            let observed = Atomic<Bool>(false)
            let ticks = UInt64(1_000_000_000) * UInt64(Clock.timebase.denom) / UInt64(Clock.timebase.numer)
            let completed = waitForMainThreadWork(
                until: Clock.now() + ticks,
                beforeWait: { ready.signal() }
            ) { done in
                observed.store(ready.wait(timeout: .now() + .seconds(1)) == .success, ordering: .relaxed)
                done()
            }
            return completed && observed.load(ordering: .relaxed)
        }
        #expect(published)
    }

    // Falling counts are not growth; a later rise still uses the lowest prior count.
    @Test func postDestroyGrowthUsesOrderedCounts() {
        func check(_ counts: [UInt64]) -> CheckResult {
            let samples = counts.map { count in
                CreationCostChecks.MemorySample(
                    before: (1_000, 0), afterCreate: (2_000, 0),
                    afterDestroy: (count, 0), heapBlocks: 1_000,
                    liveBefore: 1_000, liveAfterDestroy: count
                )
            }
            return CreationCostChecks.check(
                operation: "create", block: 0, objects: 1_000,
                batches: counts.count, destroyed: counts.count * 1_000,
                samples: samples, completed: true
            )
        }
        #expect(check([1_000, 980]).passed)
        #expect(check([1_000, 980, 990]).passed)
        #expect(!check([1_000, 980, 991]).passed)
    }

    // A failed zone enumeration must never silently substitute aggregate statistics.
    @Test func failedLiveEnumerationFailsTheCheck() {
        let sample = CreationCostChecks.MemorySample(
            before: (1_000, 0), afterCreate: (2_000, 0), afterDestroy: (1_000, 0),
            heapBlocks: 1_000, liveBefore: nil, liveAfterDestroy: 1_000
        )
        let check = CreationCostChecks.check(
            operation: "create", block: 0, objects: 1_000,
            batches: 1, destroyed: 1_000, samples: [sample], completed: true
        )
        #expect(!check.passed)
        #expect(check.detail.contains("enumeration failed"))
    }

    // Retaining created objects must fail with the observed post-destroy growth.
    @Test func aLeakFailsTheCheck() {
        let counter = CreationDeinitCounter()
        var objects: [LeakingCreationObject] = []
        var references: [WeakCreationObject] = []
        references.reserveCapacity(1_000)
        let before = MallocStatistics.read()
        let liveBefore = MallocStatistics.liveBlocks()
        for _ in 0..<1_000 {
            let object = LeakingCreationObject(counter)
            objects.append(object)
            references.append(WeakCreationObject(value: object))
        }
        let afterCreate = MallocStatistics.read()
        let heapBlocks = CreationCostChecks.heapBlockCount(ContiguousArray(objects))
        objects.removeAll()
        let afterDestroy = MallocStatistics.read()
        let liveAfterDestroy = MallocStatistics.liveBlocks()
        let sample = CreationCostChecks.MemorySample(
            before: before, afterCreate: afterCreate, afterDestroy: afterDestroy, heapBlocks: heapBlocks,
            liveBefore: liveBefore, liveAfterDestroy: liveAfterDestroy
        )
        let check = CreationCostChecks.check(
            operation: "create", block: 0, objects: 1_000,
            batches: 1, destroyed: counter.value, samples: [sample], completed: true
        )
        #expect(!check.passed)
        #expect(check.detail.contains("growth"))
        #expect(liveAfterDestroy != nil && liveBefore != nil)
        if let liveAfterDestroy, let liveBefore {
            #expect(liveAfterDestroy > liveBefore + 10)
        }
        for reference in references { reference.value?.release() }
    }
}

/// A controlled retain cycle exercises the real malloc and deinit checks.
private final class LeakingCreationObject {
    private let counter: CreationDeinitCounter
    private var retainedSelf: LeakingCreationObject?

    init(_ counter: CreationDeinitCounter) {
        self.counter = counter
        retainedSelf = self
    }

    func release() {
        retainedSelf = nil
    }

    deinit { counter.increment() }
}

private struct WeakCreationObject {
    weak var value: LeakingCreationObject?
}

extension RunRequest {
    static var creationCostSmoke: RunRequest {
        var request = RunRequest.golden
        request.experiment = "creationCost"
        request.variant = "default"
        request.mechanisms = [
            "unsynchronized", "mutex", "osAllocatedUnfairLock", "osUnfairLock",
            "nsLock", "nsRecursiveLock", "pthreadMutex", "pthreadReadWriteLock",
            "serialQueue", "barrierQueueSyncWrite", "dispatchSemaphore", "actor",
            "mainActor", "atomic", "managedAtomic"
        ]
        request.operations = ["create", "destroy"]
        request.tunables.operationsPerBatch = ["default": 1_000]
        return request
    }
}
