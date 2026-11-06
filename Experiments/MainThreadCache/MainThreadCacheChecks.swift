import Darwin
import Dispatch
import Synchronization
import UIKit

/// Each writer owns its generator and counters; the owner reads only after joining.
final class CacheWriter: @unchecked Sendable {
    private let images: CacheImages
    private let workIterations: [Int]
    private var random: SplitMix64
    let pause = DispatchSemaphore(value: 0)
    let finished = Atomic<Bool>(false)
    var writes = 0
    var checkValue: UInt64 = 0

    init(images: CacheImages, iterations: Int, seed: UInt64) {
        self.images = images
        workIterations = Array(repeating: iterations, count: images.images.count)
        random = SplitMix64(seed: seed)
    }

    func next() -> (String, CachedImage, Int) {
        let key = Int(random.next() % UInt64(images.keys.count))
        let image = Int(random.next() % UInt64(images.images.count))
        // Runtime selection keeps the configured decode work attached to every write.
        return (images.keys[key], images.entry(image), workIterations[image])
    }
}

/// Main owns screen state; mutexes publish only complete snapshots. Each writer owns
/// its counters, and relaxed atomics carry only stop/readiness signals, not data.
final class CacheSession: @unchecked Sendable {
    struct Result: Sendable {
        let observation: ScrollingScreen.Observation
        let samples: [(String, String, [UInt64])]
    }

    let tunables: MainThreadCacheTunables
    let deadline: UInt64
    let waitDeadline: DispatchTime
    private let tasks: Mutex<[Task<Void, Never>]>
    let ready = Atomic<Bool>(false)
    let stop = Atomic<Bool>(false)
    private let screen = Mutex<ScrollingScreen?>(nil)
    private let result = Mutex<Result?>(nil)
    private let completed = Mutex<Bool>(false)
    private let block: BlockContext

    init(block: BlockContext) {
        self.block = block
        tunables = block.request.tunables.mainThreadCache!
        let nanoseconds = UInt64(tunables.warmupFrames + tunables.frames) * 50_000_000 + 5_000_000_000
        waitDeadline = .now() + .nanoseconds(Int(nanoseconds))
        var storage: [Task<Void, Never>] = []
        storage.reserveCapacity(block.description.threads)
        tasks = Mutex(storage)
        let timebase = Clock.timebase
        let ticks = UInt64(Double(nanoseconds) * Double(timebase.denom) / Double(timebase.numer))
        let (end, overflow) = Clock.now().addingReportingOverflow(ticks)
        deadline = overflow ? UInt64.max : end
    }

    func prepare(
        read: @escaping @MainActor @Sendable (String) -> CachedImage?,
        fill: @escaping @MainActor @Sendable (CacheImages) -> Void
    ) -> CacheImages? {
        let prepared = Mutex<CacheImages?>(nil)
        let installed = waitForMainThreadWork(until: deadline) { [self] done in
            defer { done() }
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                let view = scene.windows.first(where: \.isKeyWindow)?.rootViewController?.view else { return }
            let images = CacheImages()
            fill(images)
            let capacity = ScrollingScreen.readCapacity(tunables: tunables, size: view.bounds.size)
            let scrolling = ScrollingScreen(images: images, tunables: tunables, readCapacity: capacity, read: read)
            scrolling.install(in: view, maximumFramesPerSecond: scene.screen.maximumFramesPerSecond)
            screen.withLock { $0 = scrolling }
            prepared.withLock { $0 = images }
        }
        guard installed else {
            queueCleanup()
            return nil
        }
        return prepared.withLock { $0 }
    }

    func makeWriters(images: CacheImages) -> [CacheWriter] {
        (0..<block.description.threads).map { index in
            CacheWriter(
                images: images, iterations: tunables.decodeIterations,
                seed: block.request.seed &+ UInt64(index)
            )
        }
    }

    func register(_ task: Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    private func stopWriters(_ writers: [CacheWriter]) {
        stop.store(true, ordering: .relaxed)
        for writer in writers {
            writer.pause.signal()
        }
        tasks.withLock { tasks in
            for task in tasks { task.cancel() }
        }
    }

    /// A dedicated coordinator waits for frames while every requested writer works.
    /// Every main-thread wait uses the block deadline.
    func startCoordinator(writers: [CacheWriter]) -> BenchmarkThread {
        BenchmarkThread.start(name: "cache-frames", qos: block.description.qos) { [self] in
            while !ready.load(ordering: .relaxed) && Clock.now() < deadline { usleep(100) }
            let finished = waitForMainThreadWork(until: deadline) { [self] done in
                guard let scrolling = screen.withLock({ $0 }) else {
                    done()
                    return
                }
                scrolling.start { [self] in
                    stopWriters(writers)
                    MainActor.assumeIsolated {
                        scrolling.stopAndRemove()
                        let snapshot = Result(observation: scrolling.observation, samples: scrolling.samples)
                        result.withLock { $0 = snapshot }
                    }
                    done()
                }
            }
            stopWriters(writers)
            completed.withLock { $0 = finished }
            if !finished {
                // Cleanup is queued even when main is late; no state is read on timeout.
                queueCleanup()
            }
        }
    }

    private func queueCleanup() {
        _ = waitForMainThreadWork(until: deadline) { [self] done in
            screen.withLock { $0 }?.stopAndRemove()
            done()
        }
    }

    func appendSamples(to block: BlockContext) {
        guard completed.withLock({ $0 }), let result = result.withLock({ $0 }) else { return }
        for (metric, unit, values) in result.samples {
            block.appendSamples(SamplesLine(
                block: block.position, thread: nil,
                metric: metric, unit: unit, values: values, cpuAtStart: nil, cpuAtEnd: nil
            ))
        }
    }

    func check(writers: [CacheWriter]) -> CheckResult {
        let snapshot = completed.withLock { $0 } ? result.withLock { $0 } : nil
        let observation = snapshot?.observation
        let writes = writers.reduce(0) { $0 + $1.writes }
        let checksum = writers.reduce(UInt64(0)) { $0 &+ $1.checkValue }
        return CheckResult(
            name: "mainThreadCache.scroll", block: block.position,
            passed: observation?.frames == tunables.frames && (observation?.reads ?? 0) > 0
                && observation?.violations == 0 && observation?.overflow == false
                && writers.count == block.description.threads && writers.allSatisfy { $0.writes > 0 },
            detail: "frames \(observation?.frames ?? 0)/\(tunables.frames); reads \(observation?.reads ?? 0), writes \(writes), violations \(observation?.violations ?? 0); overflow \(observation?.overflow ?? false); decode check \(checksum)",
            violations: observation?.violations
        )
    }
}
