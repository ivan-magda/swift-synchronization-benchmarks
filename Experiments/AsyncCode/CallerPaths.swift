import Darwin
import Dispatch
import Synchronization

/// Experiment 7A: one counter, called along five paths with one `await` or one lock per
/// operation. Each path function returns the counter's final value.
enum CallerPaths {
    // MARK: - Path "onActor": the batch loop already runs on the actor.

    static func onActor(_ block: BlockContext, counter: CounterActor) -> Int {
        let finalValue = Mutex(0)

        _ = block.runInTasks { _, barrier, log in
            await counter.runBatchesOnActor(layout: block.layout, barrier: barrier, log: log)

            let value = await counter.finalValue()
            finalValue.withLock { $0 = value }
        }

        return finalValue.withLock { $0 }
    }

    // MARK: - Path "fromBackgroundTask": one detached task calls an idle counter.

    static func fromBackgroundTask(_ block: BlockContext, counter: CounterActor) -> Int {
        let finalValue = Mutex(0)

        _ = block.runInTasks { _, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { slot in slot.store(await counter.executorCPU()) },
                runOperations: { _, _, count in
                    for _ in 0..<count {
                        await counter.increment()
                    }
                    return 0
                }
            )

            let value = await counter.finalValue()
            finalValue.withLock { $0 = value }
        }

        return finalValue.withLock { $0 }
    }

    static func fromBackgroundTask<Counter: LockCounter>(
        _ block: BlockContext,
        counter: Counter
    ) -> Int {
        _ = block.runInTasks { _, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { _ in },
                runOperations: { _, _, count in
                    for _ in 0..<count {
                        counter.increment()
                    }
                    return 0
                }
            )
        }

        return counter.finalValue()
    }

    // MARK: - Path "fromManyTasks": 50 tasks call one counter at once; each call is timed.

    static func fromManyTasks(
        _ block: BlockContext,
        counter: CounterActor,
        asyncCode: AsyncCodeTunables
    ) -> Int {
        let callTimes = (0..<block.description.threads).map { _ in
            CallTimes(calls: asyncCode.callsPerTask)
        }
        let finalValue = Mutex(0)
        _ = block.runInTasks(recording: .samplesOnly) { task, barrier, _ in
            let times = callTimes[task]
            for _ in 0..<asyncCode.warmupCallsPerTask {
                await counter.increment()
            }

            await barrier.arriveAndWait()

            for call in 0..<asyncCode.callsPerTask {
                let start = Clock.now()
                await counter.increment()
                let end = Clock.now()
                times.record(call: call, ticks: end - start)
            }

            // Every task's calls have ended before the final read.
            await barrier.arriveAndWait()

            if task == 0 {
                let value = await counter.finalValue()
                finalValue.withLock { $0 = value }
            }
        }

        appendCallTimes(callTimes, to: block)
        return finalValue.withLock { $0 }
    }

    static func fromManyTasks<Counter: LockCounter>(
        _ block: BlockContext,
        counter: Counter,
        asyncCode: AsyncCodeTunables
    ) -> Int {
        let callTimes = (0..<block.description.threads).map { _ in
            CallTimes(calls: asyncCode.callsPerTask)
        }
        _ = block.runInTasks(recording: .samplesOnly) { task, barrier, _ in
            let times = callTimes[task]
            for _ in 0..<asyncCode.warmupCallsPerTask {
                counter.increment()
            }

            await barrier.arriveAndWait()

            for call in 0..<asyncCode.callsPerTask {
                let start = Clock.now()
                counter.increment()
                let end = Clock.now()
                times.record(call: call, ticks: end - start)
            }
        }

        appendCallTimes(callTimes, to: block)
        return counter.finalValue()
    }

    private static func appendCallTimes(_ callTimes: [CallTimes], to block: BlockContext) {
        for (task, times) in callTimes.enumerated() {
            block.appendSamples(SamplesLine(
                block: block.position,
                thread: task,
                metric: "callTime",
                unit: "ticks",
                values: times.values,
                cpuAtStart: nil,
                cpuAtEnd: nil
            ))
        }
    }

    // MARK: - Path "fromMainActor": a main-actor function calls the counter and returns.

    static func fromMainActor(_ block: BlockContext, counter: CounterActor) -> Int {
        let mainThreadCPU = MainThreadCPURecorder(batches: block.layout.totalBatches)
        let finalValue = Mutex(0)
        _ = block.runInTasks { _, barrier, log in
            await timeOnMainActor(
                layout: block.layout,
                barrier: barrier,
                log: log,
                counter: counter,
                mainThreadCPU: mainThreadCPU
            )

            let value = await counter.finalValue()
            finalValue.withLock { $0 = value }
        }

        mainThreadCPU.appendLines(to: block)
        return finalValue.withLock { $0 }
    }

    static func fromMainActor<Counter: LockCounter>(
        _ block: BlockContext,
        counter: Counter
    ) -> Int {
        let mainThreadCPU = MainThreadCPURecorder(batches: block.layout.totalBatches)
        _ = block.runInTasks { _, barrier, log in
            await timeOnMainActor(
                layout: block.layout,
                barrier: barrier,
                log: log,
                counter: counter,
                mainThreadCPU: mainThreadCPU
            )
        }

        mainThreadCPU.appendLines(to: block)
        return counter.finalValue()
    }

    /// The batch loop inherits the main actor from this function.
    @MainActor
    private static func timeOnMainActor(
        layout: BatchLayout,
        barrier: TaskBarrier,
        log: ThreadLog,
        counter: CounterActor,
        mainThreadCPU: MainThreadCPURecorder
    ) async {
        await BatchTimer.timeBatchesOnCallerIsolation(
            layout: layout,
            barrier: barrier,
            log: log,
            recordExecutorCPU: { slot in slot.store(await counter.executorCPU()) },
            recordBatchEdge: { batch, edge in mainThreadCPU.record(batch: batch, edge: edge) },
            runOperations: { _, _, count in
                for _ in 0..<count {
                    await counter.increment()
                }
                return 0
            }
        )
    }

    /// The batch loop inherits the main actor from this function.
    @MainActor
    private static func timeOnMainActor<Counter: LockCounter>(
        layout: BatchLayout,
        barrier: TaskBarrier,
        log: ThreadLog,
        counter: Counter,
        mainThreadCPU: MainThreadCPURecorder
    ) async {
        await BatchTimer.timeBatchesOnCallerIsolation(
            layout: layout,
            barrier: barrier,
            log: log,
            recordExecutorCPU: { _ in },
            recordBatchEdge: { batch, edge in mainThreadCPU.record(batch: batch, edge: edge) },
            runOperations: { _, _, count in
                for _ in 0..<count {
                    counter.increment()
                }
                return 0
            }
        )
    }

    // MARK: - Path "toMainActor": a background task updates main-actor state.

    static func toMainActor(_ block: BlockContext) -> Int {
        let counter = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                MainActorCounter()
            }
        }
        let mainThreadCPU = MainThreadCPURecorder(batches: block.layout.totalBatches)
        let finalValue = Mutex(0)
        _ = block.runInTasks { _, barrier, log in
            await BatchTimer.timeBatchesOnCallerIsolation(
                layout: block.layout,
                barrier: barrier,
                log: log,
                recordExecutorCPU: { slot in slot.store(await counter.executorCPU()) },
                recordBatchEdge: { batch, edge in mainThreadCPU.record(batch: batch, edge: edge) },
                runOperations: { _, _, count in
                    for _ in 0..<count {
                        await counter.increment()
                    }
                    return 0
                }
            )

            let value = await counter.finalValue()
            finalValue.withLock { $0 = value }
        }

        mainThreadCPU.appendLines(to: block)
        return finalValue.withLock { $0 }
    }
}
