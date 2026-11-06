import Synchronization
import Testing
import UIKit

@testable import SyncBench

@Suite struct MainThreadCacheTests {
    // Missing rows, warm-up reads or frame loss corrupt the exported scrolling data.
    @Test(.timeLimit(.minutes(1)))
    func mainThreadCacheSmokeRunPasses() async throws {
        let attempt = try await runAttempt(.mainThreadCacheSmoke)
        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 14)
        #expect(attempt.checks.count == 14)
        #expect(attempt.checks.allSatisfy { $0["passed"] as? Bool == true })
        #expect(attempt.lines.allSatisfy { $0["type"] as? String != "batch" })
        for block in attempt.blocks {
            let position = try #require(block["block"] as? Int)
            let samples = attempt.lines(type: "samples", block: position)
            #expect(samples.count == 3)
            for metric in ["frameStart", "frameInterval"] {
                let line = try #require(samples.first { $0["metric"] as? String == metric })
                #expect((line["values"] as? [Int])?.count == 60)
                #expect(line["thread"] == nil)
                #expect(line["unit"] as? String == (metric == "frameStart" ? "ticks" : "nanoseconds"))
            }
            let reads = try #require(samples.first { $0["metric"] as? String == "readTime" })
            #expect((reads["values"] as? [Int])?.isEmpty == false)
            #expect(reads["unit"] as? String == "ticks")
        }
    }

    // Moving the final drain after runOnThreads exports an end tick before queued work ends.
    @Test(.timeLimit(.minutes(1)))
    func asynchronousWritesDrainInsideTheExportedBlock() async throws {
        var request = RunRequest.mainThreadCacheSmoke
        request.mechanisms = ["barrierQueueAsyncWrite"]
        request.tunables.mainThreadCache!.warmupFrames = 1
        request.tunables.mainThreadCache!.frames = 4
        let experiment = try MainThreadCache(request: request)
        let cache = DrainRecordingImageCache()
        let observation = await onBenchmarkThread { [request] in
            let lines = ResultLineBuffer()
            let description = experiment.blocks[0]
            let block = BlockContext(
                position: 0, description: description,
                layout: BatchLayout(
                    warmupBatches: 1, measuredBatches: 2,
                    operationsPerBatch: 4, subBatches: 2
                ), request: request, lines: lines
            )
            let checks = experiment.measure(cache, block)
            return (lines.data, cache.drain, checks.allSatisfy(\.passed))
        }
        let first = try #require(observation.0.split(separator: 0x0A).first)
        let block = try #require(JSONSerialization.jsonObject(with: Data(first)) as? [String: Any])
        let start = try #require(block["start"] as? UInt64)
        let end = try #require(block["end"] as? UInt64)
        #expect(observation.2)
        #expect(observation.1.count == 2) // Prefill drain, then the final writer drain.
        #expect(start < observation.1.tick)
        #expect(observation.1.tick <= end)
    }

    // A torn image/index pair must fail the check even though the lookup found an entry.
    @Test(arguments: [(100, false), (0, true)])
    @MainActor func aHalfWrittenEntryIsCounted(_ capacity: Int, _ overflow: Bool) {
        let images = CacheImages()
        let cache = HalfWrittenImageCache(image: images.images[0])
        let screen = ScrollingScreen(images: images, tunables: .smoke, readCapacity: capacity) { key in
            cache.image(for: key)
        }
        screen.recordingReads = true
        let collection = screen.collectionView
        _ = screen.collectionView(collection, cellForItemAt: IndexPath(item: 0, section: 0))
        #expect(screen.observation.violations == 1)
        #expect(screen.observation.reads == 1)
        #expect(screen.observation.overflow == overflow)
    }

    @Test(arguments: ["frames", "warmupFrames", "speed", "decode", "interval", "overflow", "threads"])
    func rejectsInvalidWorkload(_ field: String) {
        var request = RunRequest.mainThreadCacheSmoke
        switch field {
        case "frames": request.tunables.mainThreadCache!.frames = 0
        case "warmupFrames": request.tunables.mainThreadCache!.warmupFrames = -1
        case "speed": request.tunables.mainThreadCache!.scrollPointsPerSecond = 20_001
        case "decode": request.tunables.mainThreadCache!.decodeIterations = 0
        case "interval": request.tunables.mainThreadCache!.writeIntervalMicroseconds = Int.max
        case "overflow": request.tunables.mainThreadCache!.frames = Int.max
        case "threads": request.tunables.threads = 1
        default: preconditionFailure("Test case")
        }
        #expect(throws: RequestError.self) { try ExperimentRegistry.makeExperiment(for: request) }
    }
}

/// Wraps the real asynchronous cache and records when each actual drain returns.
private final class DrainRecordingImageCache: ImageCache {
    struct Drain: Sendable {
        var count = 0
        var tick: UInt64 = 0
    }

    private let cache = BarrierQueueAsyncWriteImageCache()
    private let state = Mutex(Drain())

    var drain: Drain { state.withLock { $0 } }

    func image(for key: String) -> CachedImage? { cache.image(for: key) }
    func store(_ entry: CachedImage, for key: String) { cache.store(entry, for: key) }

    func waitForPendingWrites() {
        cache.waitForPendingWrites()
        state.withLock { drain in
            drain.count += 1
            drain.tick = Clock.now()
        }
    }
}

/// Returns a deliberately torn entry to drive the real cell's correctness check.
private final class HalfWrittenImageCache: ImageCache {
    let image: UIImage
    init(image: UIImage) { self.image = image }
    func image(for key: String) -> CachedImage? { CachedImage(image: image, imageIndex: 1) }
    func store(_ entry: CachedImage, for key: String) {}
}

extension MainThreadCacheTunables {
    static var smoke: Self {
        Self(
            warmupFrames: 10, frames: 60, scrollPointsPerSecond: 3_000,
            decodeIterations: 10, writeIntervalMicroseconds: 20_000
        )
    }
}

extension RunRequest {
    static var mainThreadCacheSmoke: Self {
        var request = RunRequest.golden
        request.experiment = "mainThreadCache"
        request.variant = "default"
        request.mechanisms = [
            "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
            "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
            "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
            "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync", "mainActor",
        ]
        request.operations = ["scroll"]
        request.tunables.threads = 2
        request.tunables.mainThreadCache = .smoke
        return request
    }
}
