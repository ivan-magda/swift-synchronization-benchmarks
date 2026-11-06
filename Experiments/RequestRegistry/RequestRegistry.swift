import Darwin

/// Experiment 2: what does shared download bookkeeping cost with occasional
/// cancel-all calls? Ten concrete registries compare lock and queue protection,
/// with four or eight workers and pauses (normal) or continuous calls (burst).
struct RequestRegistry: Experiment {
    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try RequestRegistryRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let capacity =
            block.description.threads * block.request.tunables.requestRegistry!.inFlightPerThread
        switch block.description.mechanism {
        case "mutex":
            return measure(MutexRegistry(capacity: capacity), block)
        case "osAllocatedUnfairLock":
            return measure(AllocatedUnfairLockRegistry(capacity: capacity), block)
        case "osAllocatedUnfairLockAdaptiveSpin":
            return measure(AdaptiveSpinUnfairLockRegistry(capacity: capacity), block)
        case "osUnfairLock":
            return measure(UnfairLockRegistry(capacity: capacity), block)
        case "nsLock":
            return measure(NSLockRegistry(capacity: capacity), block)
        case "nsRecursiveLock":
            return measure(NSRecursiveLockRegistry(capacity: capacity), block)
        case "pthreadMutex":
            return measure(PthreadMutexRegistry(capacity: capacity), block)
        case "serialQueue":
            return measure(SerialQueueRegistry(capacity: capacity), block)
        case "dispatchSemaphore":
            return measure(DispatchSemaphoreRegistry(capacity: capacity), block)
        case "objcSync":
            return measure(ObjcSyncRegistry(capacity: capacity), block)
        default:
            preconditionFailure("Validated requestRegistry mechanism")
        }
    }

    @inline(never)
    static func operationLoop(
        _ registry: some DownloadRegistry, worker: RegistryWorker,
        tunables: RequestRegistryTunables, firstOperation: Int, count: Int,
        measuredOperation: Int?, cancelAll: Bool
    ) -> Int {
        var value = 0
        for operation in 0..<count {
            let ordinal = firstOperation + operation
            let pair = ordinal / 2
            let index =
                ordinal.isMultiple(of: 2)
                ? pair % worker.downloads.count
                : (pair % worker.downloads.count + tunables.inFlightPerThread)
                    % worker.downloads.count
            let download = worker.downloads[index]
            let measured = measuredOperation.map { $0 + operation }
            let sample =
                measured.map { $0 % tunables.sampleEvery == ($0 / tunables.sampleEvery) % 2 }
                ?? false
            let removing = ordinal.isMultiple(of: 2)
            let removed: Download?
            let start = sample ? Clock.now() : 0
            if removing {
                removed = registry.remove(id: download.id)
            } else {
                registry.add(download, id: download.id)
                removed = nil
            }
            if sample, let measured {
                let end = Clock.now()
                let index = measured / tunables.sampleEvery
                worker.callStart.record(call: index, ticks: start)
                worker.callTime.record(call: index, ticks: end - start)
            }
            if removed != nil { worker.removed += 1 }
            if !removing { worker.added += 1 }
            value &+= Int(truncatingIfNeeded: referenceLoop(iterations: download.workIterations))
            if cancelAll && (ordinal + 1).isMultiple(of: tunables.cancelAllEvery) {
                let start = measured != nil ? Clock.now() : 0
                let cancelled = registry.cancelAll()
                if let measured {
                    let end = Clock.now()
                    let index = measured / tunables.cancelAllEvery
                    worker.cancelAllStart.record(call: index, ticks: start)
                    worker.cancelAllTime.record(call: index, ticks: end - start)
                }
                worker.cancelled += cancelled
            }
            if tunables.pauseMicroseconds > 0 { usleep(UInt32(tunables.pauseMicroseconds)) }
        }
        return value
    }
}
