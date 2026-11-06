import Synchronization

/// Experiment 3: how much does a synchronous Bool read cost while the main
/// thread toggles it every 10 ms? Seventeen concrete flags compare locks,
/// queues and acquiring or relaxed atomics; groups expose rare reader waits.
struct HotFlag: Experiment {
    enum Operation: String, CaseIterable, Sendable {
        case read
        case readGroups
    }

    static let groupSize = 100
    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try HotFlagRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        switch block.description.mechanism {
        case "mutex": return measure(MutexFlag(false), block)
        case "osAllocatedUnfairLock": return measure(AllocatedUnfairLockFlag(false), block)
        case "osAllocatedUnfairLockAdaptiveSpin": return measure(AdaptiveSpinUnfairLockFlag(false), block)
        case "osUnfairLock": return measure(UnfairLockFlag(false), block)
        case "nsLock": return measure(NSLockFlag(false), block)
        case "nsRecursiveLock": return measure(NSRecursiveLockFlag(false), block)
        case "pthreadMutex": return measure(PthreadMutexFlag(false), block)
        case "pthreadReadWriteLock": return measure(PthreadReadWriteLockFlag(false), block)
        case "serialQueue": return measure(SerialQueueFlag(false), block)
        case "barrierQueueSyncWrite": return measure(BarrierQueueSyncWriteFlag(false), block)
        case "barrierQueueAsyncWrite": return measure(BarrierQueueAsyncWriteFlag(false), block)
        case "dispatchSemaphore": return measure(DispatchSemaphoreFlag(false), block)
        case "objcSync": return measure(ObjcSyncFlag(false), block)
        case "atomic": return measure(AtomicFlag(false), block)
        case "managedAtomic": return measure(ManagedAtomicFlag(false), block)
        case "atomicRelaxed": return measure(RelaxedAtomicFlag(false), block)
        case "managedAtomicRelaxed": return measure(RelaxedManagedAtomicFlag(false), block)
        default: preconditionFailure("Validated hotFlag mechanism")
        }
    }

    @inline(never)
    static func readLoop(_ flag: some SharedFlag, count: Int) -> Int {
        var trueReads = 0
        for _ in 0..<count {
            if flag.read() { trueReads += 1 }
        }
        return trueReads
    }

    private func measure(_ flag: some SharedFlag, _ block: BlockContext) -> [CheckResult] {
        let grouped = block.description.operation == Operation.readGroups.rawValue
        let groupsPerBatch = block.layout.operationsPerBatch / Self.groupSize
        let samples = CallTimes(calls: grouped ? block.layout.measuredBatches * groupsPerBatch : 0)
        let writer = MainThreadWriter(flag)
        let state = Mutex<MainThreadWriter.State?>(nil)
        let observation = Mutex<HotFlagChecks.Observation?>(nil)
        let logs = block.runOnThreads { _, barrier, log in
            let started = waitForMainThreadWork(until: MainThreadWriter.deadline()) { done in
                writer.start()
                done()
            }
            BatchTimer.timeBatches(
                layout: block.layout, barrier: barrier, log: log,
                recordExecutorCPU: { _ in }, waitForPendingWrites: {},
                runOperations: { batch, subBatch, count in
                    guard grouped, batch >= block.layout.warmupBatches else {
                        return Self.readLoop(flag, count: count)
                    }
                    var trueReads = 0
                    let groups = count / Self.groupSize
                    for group in 0..<groups {
                        let start = Clock.now()
                        trueReads += Self.readLoop(flag, count: Self.groupSize)
                        let end = Clock.now()
                        let index = (batch - block.layout.warmupBatches) * groupsPerBatch + subBatch * groups + group
                        samples.record(call: index, ticks: end - start)
                    }
                    return trueReads
                }
            )
            let stopped = waitForMainThreadWork(until: MainThreadWriter.deadline()) { done in
                let final = writer.stop()
                state.withLock { $0 = final }
                done()
            }
            if stopped, let final = state.withLock({ $0 }) {
                flag.waitForPendingWrites()
                let read = flag.read()
                observation.withLock { $0 = HotFlagChecks.Observation(started: started, writer: final, read: read) }
            }
        }
        if grouped {
            block.appendSamples(
                SamplesLine(
                    block: block.position, thread: 0, metric: "readGroupTime", unit: "ticks",
                    values: samples.values, cpuAtStart: nil, cpuAtEnd: nil
                ))
        }
        return [HotFlagChecks.check(observation.withLock { $0 }, logs: logs, block: block)]
    }
}

/// A hot-flag mechanism owns its Bool; only asynchronous barriers need a drain.
protocol SharedFlag: AnyObject, Sendable {
    func read() -> Bool
    func write(_ value: Bool)
    func waitForPendingWrites()
}

extension SharedFlag {
    func waitForPendingWrites() {}
}
