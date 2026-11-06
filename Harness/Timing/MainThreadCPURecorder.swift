import Darwin
import Dispatch

/// Main-thread CPU time at both edges of every batch, allocated before the block.
/// The batch loop writes one batch at a time; the run thread reads after `runInTasks` returns.
/// Experiments 7A and 7C write its two lines.
final class MainThreadCPURecorder: @unchecked Sendable {
    private let clock: MainThreadCPUClock
    private let batches: Int
    private let atBatchStart: UnsafeMutablePointer<UInt64>
    private let atBatchEnd: UnsafeMutablePointer<UInt64>

    /// Call on the run thread: the clock is created on the main thread.
    init(batches: Int) {
        precondition(pthread_main_np() == 0)
        clock = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                MainThreadCPUClock()
            }
        }
        self.batches = batches
        atBatchStart = .allocate(capacity: batches)
        atBatchStart.initialize(repeating: 0, count: batches)
        atBatchEnd = .allocate(capacity: batches)
        atBatchEnd.initialize(repeating: 0, count: batches)
    }

    /// Runs outside the timed region: before a batch's start tick or after its end tick.
    @inline(__always)
    func record(batch: Int, edge: BatchEdge) {
        precondition(batch >= 0 && batch < batches)
        let microseconds = clock.microseconds()

        switch edge {
        case .start:
            atBatchStart[batch] = microseconds
        case .end:
            atBatchEnd[batch] = microseconds
        }
    }

    func appendLines(to block: BlockContext) {
        for (metric, values) in [
            ("mainThreadCPUAtBatchStart", atBatchStart),
            ("mainThreadCPUAtBatchEnd", atBatchEnd),
        ] {
            block.appendSamples(SamplesLine(
                block: block.position,
                thread: nil,
                metric: metric,
                unit: "microseconds",
                values: Array(UnsafeBufferPointer(start: values, count: batches)),
                cpuAtStart: nil,
                cpuAtEnd: nil
            ))
        }
    }

    deinit {
        atBatchStart.deinitialize(count: batches)
        atBatchStart.deallocate()
        atBatchEnd.deinitialize(count: batches)
        atBatchEnd.deallocate()
    }
}
