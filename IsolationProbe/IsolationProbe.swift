import Darwin
import Synchronization

/// The probe of experiment 7C. This file is compiled twice: into `IsolationProbeTemplate`
/// with the settings of a new Xcode 27.1 app, and into `IsolationProbeSwift6` in Swift 6
/// mode without Approachable Concurrency. The settings decide where the body of
/// `nonisolatedWork()` runs when the main actor calls it.
public enum IsolationProbe {
    nonisolated private static let calls = Atomic<Int>(0)
    nonisolated private static let callsOnMainThread = Atomic<Int>(0)

    /// A plain `nonisolated async` function. With the template settings it runs on the
    /// caller's actor; in Swift 6 mode without them it runs on the global executor.
    nonisolated public static func nonisolatedWork() async {
        recordCall()
    }

    /// Runs on the global executor with any settings.
    @concurrent
    public static func concurrentWork() async {
        recordCall()
    }

    /// Calls since the last reset, and how many of them ran on the main thread.
    nonisolated public static func counts() -> (calls: Int, onMainThread: Int) {
        (calls.load(ordering: .relaxed), callsOnMainThread.load(ordering: .relaxed))
    }

    nonisolated public static func reset() {
        calls.store(0, ordering: .relaxed)
        callsOnMainThread.store(0, ordering: .relaxed)
    }

    /// The same two atomic updates in every row, so the three rows do the same work.
    nonisolated private static func recordCall() {
        let onMainThread = pthread_main_np() != 0 ? 1 : 0
        _ = calls.wrappingAdd(1, ordering: .relaxed)
        _ = callsOnMainThread.wrappingAdd(onMainThread, ordering: .relaxed)
    }
}
