import Dispatch
import Synchronization

/// Experiment 9: the time and live heap space required to create and destroy
/// classes holding one Int. Fifteen rows include the unprotected floor, locks,
/// queues, actors and atomics. Main-actor objects stay on the main thread.
struct CreationCost: Experiment {
    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try CreationCostRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        switch block.description.mechanism {
        case "unsynchronized": return measure(block, make: UnprotectedObject.init)
        case "mutex": return measure(block, make: MutexObject.init)
        case "osAllocatedUnfairLock": return measure(block, make: AllocatedUnfairLockObject.init)
        case "osUnfairLock": return measure(block, make: UnfairLockObject.init)
        case "nsLock": return measure(block, make: NSLockObject.init)
        case "nsRecursiveLock": return measure(block, make: NSRecursiveLockObject.init)
        case "pthreadMutex": return measure(block, make: PthreadMutexObject.init)
        case "pthreadReadWriteLock": return measure(block, make: PthreadReadWriteLockObject.init)
        case "serialQueue": return measure(block, make: SerialQueueObject.init)
        case "barrierQueueSyncWrite": return measure(block, make: BarrierQueueObject.init)
        case "dispatchSemaphore": return measure(block, make: SemaphoreObject.init)
        case "actor": return measure(block, make: ActorObject.init)
        case "mainActor":
            return measure(
                block,
                make: { _ -> MainActorObject in
                    preconditionFailure("Main-thread factory required")
                },
                mainActorMake: { MainActorObject($0) }
            )
        case "atomic": return measure(block, make: AtomicObject.init)
        case "managedAtomic": return measure(block, make: ManagedAtomicObject.init)
        default: preconditionFailure("Validated creationCost mechanism")
        }
    }

    @inline(never)
    static func createLoop<Object: AnyObject>(
        _ objects: inout ContiguousArray<Object>, count: Int,
        counter: CreationDeinitCounter, make: (CreationDeinitCounter) -> Object
    ) {
        for _ in 0..<count {
            objects.append(make(counter))
        }
    }

    @inline(never)
    static func destroyLoop<Object: AnyObject>(_ objects: inout ContiguousArray<Object>, count: Int) {
        objects.removeLast(count)
    }

    private func measure<Object: AnyObject>(
        _ block: BlockContext, make: @escaping @Sendable (CreationDeinitCounter) -> Object,
        mainActorMake: (@MainActor @Sendable (CreationDeinitCounter) -> Object)? = nil
    ) -> [CheckResult] {
        let storage = CreationBatchStorage<Object>(layout: block.layout)
        let counter = CreationDeinitCounter()
        let outcome = CreationBatchOutcome(capacity: block.layout.totalBatches)
        let onMain = block.description.mechanism == "mainActor"
        let gate = CreationBatchGate()
        _ = block.runOnThreads { _, _, log in
            for batch in 0..<block.layout.totalBatches {
                let secondsInTicks = UInt64(10_000_000_000) * UInt64(Clock.timebase.denom) / UInt64(Clock.timebase.numer)
                let (deadline, overflow) = Clock.now().addingReportingOverflow(secondsInTicks)
                if onMain {
                    guard !overflow, waitForMainThreadWork(until: deadline, beforeWait: { gate.ready.signal() }, { done in
                        guard gate.ready.wait(timeout: .now() + .seconds(1)) == .success else {
                            done()
                            return
                        }
                        if let mainActorMake {
                            storage.run(batch: batch, operation: block.description.operation,
                                        layout: block.layout, counter: counter, make: { mainActorMake($0) })
                        }
                        done()
                    }), storage.completedBatch == batch else {
                        outcome.completed = false
                        break
                    }
                } else {
                    let completed = !overflow && waitForMainThreadWork(until: deadline, beforeWait: {
                        guard gate.ready.wait(timeout: .now() + .seconds(1)) == .success else { return }
                        storage.run(batch: batch, operation: block.description.operation,
                                    layout: block.layout, counter: counter, make: make)
                        gate.finished.signal()
                    }) { done in
                        gate.ready.signal()
                        let parked = gate.finished.wait(timeout: .now() + .seconds(1)) == .success
                        gate.mainWaitSucceeded.store(parked, ordering: .relaxed)
                        done()
                    }
                    guard completed, gate.mainWaitSucceeded.load(ordering: .relaxed),
                          storage.completedBatch == batch else {
                        outcome.completed = false
                        break
                    }
                }
                // Only a completed batch grants permission to read executor-owned storage.
                log.recordTimes(batch: batch, start: storage.log.start(ofBatch: batch), end: storage.log.end(ofBatch: batch))
                log.recordCheckValue(batch: batch, value: block.layout.operationsPerBatch)
                for (reading, cpu) in storage.log.cpuReadings(ofBatch: batch).enumerated() {
                    log.recordCPU(batch: batch, reading: reading, cpu: cpu)
                }
                if block.description.operation == "create" {
                    outcome.samples.append(storage.sample)
                }
            }
        }
        if block.description.operation == "create" {
            outcome.appendSamples(to: block)
        }
        return [CreationCostChecks.check(
            operation: block.description.operation, block: block.position,
            objects: block.layout.operationsPerBatch, batches: block.layout.totalBatches,
            destroyed: counter.value, samples: Array(outcome.samples.dropFirst(block.layout.warmupBatches)),
            completed: outcome.completed
        )]
    }
}
