import Foundation
import Synchronization
import Testing

@testable import SyncBench

@Suite struct DisplayLinkLoopTests {
    // An off-by-one frame boundary or a repeated finish would corrupt frame samples.
    @Test(.timeLimit(.minutes(1)))
    @MainActor func displayLinkLoopCallsEachFrameOnce() async {
        var indices: [Int] = []
        let completions = Atomic<Int>(0)
        let loop = DisplayLinkLoop(frames: 5) { frame, _ in
            indices.append(frame)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loop.start {
                if completions.wrappingAdd(1, ordering: .relaxed).oldValue == 0 {
                    continuation.resume()
                }
            }
        }
        loop.stop()
        #expect(indices == [0, 1, 2, 3, 4])
        #expect(completions.load(ordering: .relaxed) == 1)
    }

    // Missing completion must not strand the run thread indefinitely.
    @Test(.timeLimit(.minutes(1)))
    func waitForMainThreadWorkTimesOut() async {
        let observation = await onBenchmarkThread {
            let started = ContinuousClock.now
            let timebase = Clock.timebase
            let duration = 50_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
            let completed = waitForMainThreadWork(until: Clock.now() + duration) { _ in }
            return (completed, started.duration(to: .now))
        }
        #expect(!observation.0)
        #expect(observation.1 < .seconds(1))
    }
}
