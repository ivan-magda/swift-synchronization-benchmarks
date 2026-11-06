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

/// Returns a deliberately torn entry to drive the real cell's correctness check.
private final class HalfWrittenImageCache: ImageCache {
    let image: UIImage
    init(image: UIImage) { self.image = image }
    func image(for key: String) -> CachedImage? { CachedImage(image: image, imageIndex: 1) }
    func store(_ entry: CachedImage, for key: String) {}
}

extension MainThreadCacheTunables {
    static var smoke: Self {
        Self(warmupFrames: 10, frames: 60, scrollPointsPerSecond: 3_000,
             decodeIterations: 10, writeIntervalMicroseconds: 20_000)
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
