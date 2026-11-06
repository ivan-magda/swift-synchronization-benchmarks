import Darwin
import Dispatch
import Synchronization
import UIKit

/// Real collection-view cache reads compete with two to four image writers.
struct MainThreadCache: Experiment {
    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try MainThreadCacheRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        switch block.description.mechanism {
        case "mutex": return measure(MutexImageCache(), block)
        case "osAllocatedUnfairLock": return measure(AllocatedUnfairLockImageCache(), block)
        case "osAllocatedUnfairLockAdaptiveSpin": return measure(AdaptiveSpinUnfairLockImageCache(), block)
        case "osUnfairLock": return measure(UnfairLockImageCache(), block)
        case "nsLock": return measure(NSLockImageCache(), block)
        case "nsRecursiveLock": return measure(NSRecursiveLockImageCache(), block)
        case "pthreadMutex": return measure(PthreadMutexImageCache(), block)
        case "pthreadReadWriteLock": return measure(PthreadReadWriteLockImageCache(), block)
        case "serialQueue": return measure(SerialQueueImageCache(), block)
        case "barrierQueueSyncWrite": return measure(BarrierQueueSyncWriteImageCache(), block)
        case "barrierQueueAsyncWrite": return measure(BarrierQueueAsyncWriteImageCache(), block)
        case "dispatchSemaphore": return measure(DispatchSemaphoreImageCache(), block)
        case "objcSync": return measure(ObjcSyncImageCache(), block)
        case "mainActor": return measureMainActor(block)
        default: preconditionFailure("Validated mainThreadCache mechanism")
        }
    }

    func measure(_ cache: some ImageCache, _ block: BlockContext) -> [CheckResult] {
        let session = CacheSession(block: block)
        guard let images = session.prepare(read: { key in cache.image(for: key) }, fill: { images in
            for (index, key) in images.keys.enumerated() {
                cache.store(images.entry(index % images.images.count), for: key)
            }
            cache.waitForPendingWrites()
        }) else { return [session.check(writers: [])] }
        let writers = session.makeWriters(images: images)
        let coordinator = session.startCoordinator(writers: writers)
        _ = block.runOnThreads(recording: .samplesOnly) { index, barrier, _ in
            barrier.arriveAndWait()
            if index == 0 { session.ready.store(true, ordering: .relaxed) }
            writeLoop(cache, writer: writers[index], session: session)
            barrier.arriveAndWait()
            if index == 0 { cache.waitForPendingWrites() }
            writers[index].finished.store(true, ordering: .releasing)
        }
        coordinator.join()
        session.appendSamples(to: block)
        return [session.check(writers: writers)]
    }

    private func measureMainActor(_ block: BlockContext) -> [CheckResult] {
        let session = CacheSession(block: block)
        let cache = MainActorImageCache()
        guard let images = session.prepare(read: { key in cache.image(for: key) }, fill: { images in
            for (index, key) in images.keys.enumerated() {
                cache.store(images.entry(index % images.images.count), for: key)
            }
        }) else { return [session.check(writers: [])] }
        let writers = session.makeWriters(images: images)
        let coordinator = session.startCoordinator(writers: writers)
        // Detached writers keep decode work outside main. Pthread participants wait
        // only to the deadline, including when a writer is awaiting a main-actor store.
        _ = block.runOnThreads(recording: .samplesOnly) { index, barrier, _ in
            let completion = DispatchSemaphore(value: 0)
            let task = Task.detached(priority: block.description.qos.taskPriority) {
                await writeLoop(cache, writer: writers[index], session: session)
                writers[index].finished.store(true, ordering: .releasing)
                completion.signal()
            }
            session.register(task)
            barrier.arriveAndWait()
            if index == 0 { session.ready.store(true, ordering: .relaxed) }
            if completion.wait(timeout: session.waitDeadline) == .timedOut { task.cancel() }
        }
        coordinator.join()
        let drained = writers.allSatisfy { $0.finished.load(ordering: .acquiring) }
        if drained { session.appendSamples(to: block) }
        return [session.check(writers: drained ? writers : [])]
    }

    @inline(never)
    private func writeLoop(_ cache: some ImageCache, writer: CacheWriter, session: CacheSession) {
        while !session.stop.load(ordering: .relaxed) && Clock.now() < session.deadline {
            let (key, entry, iterations) = writer.next()
            writer.checkValue &+= referenceLoop(iterations: iterations)
            cache.store(entry, for: key)
            writer.writes += 1
            if session.tunables.writeIntervalMicroseconds > 0 {
                let pause = DispatchTime.now() + .microseconds(session.tunables.writeIntervalMicroseconds)
                _ = writer.pause.wait(timeout: min(pause, session.waitDeadline))
            }
        }
    }

    @inline(never)
    private func writeLoop(_ cache: MainActorImageCache, writer: CacheWriter, session: CacheSession) async {
        while !Task.isCancelled && !session.stop.load(ordering: .relaxed) && Clock.now() < session.deadline {
            let (key, entry, iterations) = writer.next()
            writer.checkValue &+= referenceLoop(iterations: iterations)
            await cache.store(entry, for: key)
            writer.writes += 1
            if session.tunables.writeIntervalMicroseconds > 0 {
                try? await Task.sleep(for: .microseconds(session.tunables.writeIntervalMicroseconds))
            }
        }
    }
}
