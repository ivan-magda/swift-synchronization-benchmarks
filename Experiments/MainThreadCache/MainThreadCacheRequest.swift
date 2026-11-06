enum MainThreadCacheRequest {
    static let mechanisms: Set<String> = [
        "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
        "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
        "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
        "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync", "mainActor",
    ]

    static func blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription] {
        try request.validate()
        guard request.variant == "default" else {
            throw RequestError(message: "variant must be default for mainThreadCache")
        }
        guard (2...4).contains(request.tunables.threads) else {
            throw RequestError(message: "threads must be in 2...4 for mainThreadCache")
        }
        guard let cache = request.tunables.mainThreadCache else {
            throw RequestError(message: "mainThreadCache tunables are required")
        }
        try validate(cache)
        try request.requireUniqueSelection(mechanisms: mechanisms, operations: ["scroll"])
        return request.mechanisms.map { mechanism in
            BlockDescription(
                mechanism: mechanism, operation: "scroll",
                threads: request.tunables.threads, qos: request.tunables.qos,
                operationsPerBatch: request.operationsPerBatch(for: mechanism)
            )
        }
    }

    static func validate(_ value: MainThreadCacheTunables) throws(RequestError) {
        guard value.frames >= 1, value.warmupFrames >= 0,
            (1...20_000).contains(value.scrollPointsPerSecond), value.decodeIterations >= 1,
            (0...Int(UInt32.max)).contains(value.writeIntervalMicroseconds) else {
            throw RequestError(message: "mainThreadCache frames, warmupFrames, scrollPointsPerSecond, decodeIterations or writeIntervalMicroseconds outside range")
        }
        let (frames, frameOverflow) = value.frames.addingReportingOverflow(value.warmupFrames)
        let (duration, durationOverflow) = frames.multipliedReportingOverflow(by: 50_000_000)
        let (_, deadlineOverflow) = duration.addingReportingOverflow(5_000_000_000)
        // Conservative geometry bound: at least one point per cell, 60 Hz or faster,
        // four columns and room for two extra rows each frame plus prefetching.
        let (distance, distanceOverflow) = frames.multipliedReportingOverflow(by: value.scrollPointsPerSecond)
        let (reads, readOverflow) = distance.addingReportingOverflow(frames)
        let (_, byteOverflow) = reads.multipliedReportingOverflow(by: 128)
        guard !frameOverflow, !durationOverflow, !deadlineOverflow, !distanceOverflow,
            !readOverflow, !byteOverflow else {
            throw RequestError(message: "mainThreadCache frame duration, read storage or decode work overflow")
        }
    }
}
