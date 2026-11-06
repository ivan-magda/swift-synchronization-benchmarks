/// Each worker exclusively owns its counters and sample buffers until all workers
/// join. Downloads are immutable apart from their independent atomic cancel counts.
final class RegistryWorker: @unchecked Sendable {
    let downloads: [Download]
    let callStart: CallTimes
    let callTime: CallTimes
    let cancelAllStart: CallTimes
    let cancelAllTime: CallTimes
    var added = 0
    var removed = 0
    var cancelled = 0

    init(thread: Int, tunables: RequestRegistryTunables, layout: BatchLayout) {
        downloads = (0...tunables.inFlightPerThread).map {
            Download(id: thread * (tunables.inFlightPerThread + 1) + $0, workIterations: tunables.workIterations)
        }
        let operations = layout.measuredBatches * layout.operationsPerBatch
        callStart = CallTimes(calls: operations / tunables.sampleEvery)
        callTime = CallTimes(calls: operations / tunables.sampleEvery)
        cancelAllStart = CallTimes(calls: thread == 0 ? operations / tunables.cancelAllEvery : 0)
        cancelAllTime = CallTimes(calls: thread == 0 ? operations / tunables.cancelAllEvery : 0)
    }
}

extension RequestRegistry {
    func measure(_ registry: some DownloadRegistry, _ block: BlockContext) -> [CheckResult] {
        let tunables = block.request.tunables.requestRegistry!
        let workers = (0..<block.description.threads).map {
            RegistryWorker(thread: $0, tunables: tunables, layout: block.layout)
        }
        let logs = block.runOnThreads { thread, barrier, log in
            let worker = workers[thread]
            for download in worker.downloads.prefix(tunables.inFlightPerThread) {
                registry.add(download, id: download.id)
                worker.added += 1
            }
            BatchTimer.timeBatches(
                layout: block.layout, barrier: barrier, log: log,
                recordExecutorCPU: { _ in }, waitForPendingWrites: {},
                runOperations: { batch, subBatch, count in
                    let firstOperation = batch * block.layout.operationsPerBatch + subBatch * count
                    let measuredOperation = batch >= block.layout.warmupBatches
                        ? firstOperation - block.layout.warmupBatches * block.layout.operationsPerBatch : nil
                    return Self.operationLoop(registry, worker: worker, tunables: tunables,
                        firstOperation: firstOperation, count: count, measuredOperation: measuredOperation, cancelAll: thread == 0)
                }
            )
            barrier.arriveAndWait()
            for download in worker.downloads {
                if registry.remove(id: download.id) != nil {
                    worker.removed += 1
                }
            }
        }
        for (thread, worker) in workers.enumerated() {
            for (metric, times) in [("callStart", worker.callStart), ("callTime", worker.callTime)] {
                block.appendSamples(SamplesLine(block: block.position, thread: thread,
                    metric: metric, unit: "ticks", values: times.values, cpuAtStart: nil, cpuAtEnd: nil))
            }
        }
        for (metric, times) in [("cancelAllStart", workers[0].cancelAllStart), ("cancelAllTime", workers[0].cancelAllTime)] {
            block.appendSamples(SamplesLine(block: block.position, thread: nil,
                metric: metric, unit: "ticks", values: times.values, cpuAtStart: nil, cpuAtEnd: nil))
        }
        return [RequestRegistryChecks.check(registry, workers: workers, logs: logs, block: block)]
    }
}
