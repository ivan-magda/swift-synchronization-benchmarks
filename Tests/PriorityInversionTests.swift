import Dispatch
import Synchronization
import Testing

@testable import SyncBench

@Suite struct PriorityInversionTests {
    // The same ticks as scripts/tests/test_trials.py: the holder holds the lock from 200 to 400.
    @Test func classifiesTrials() {
        #expect(classify() == .valid)
        #expect(classify(mainAcquire: 600) == .valid)
        #expect(classify(mainAcquire: 601) == .censored)
        #expect(classify(mainArrival: 150) == .invalid)
        #expect(classify(mainArrival: 401) == .invalid)
        #expect(classify(holderRelease: 800, mainArrival: 650, mainAcquire: 850) == .invalid)
    }

    // The main side arrives while the holder works and must see the holder's value after its release.
    // Serialized: every case blocks the shared main thread while it waits.
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ContendedLocks.mechanisms)
    func everyMechanismKeepsTheMainSideOut(_ mechanism: MechanismID) async throws {
        let work = holderWork(milliseconds: 5)
        let trial = 7
        let lock = ContendedLocks.make(mechanism, holderQoS: .utility)
        let timestamps = HolderTimestamps()
        let mainSide = Mutex<(acquired: UInt64, observedTrial: Int)?>(nil)
        let mainSideDone = DispatchSemaphore(value: 0)

        let finished = await onBenchmarkThread {
            _ = BenchmarkThread.start(name: "holder", qos: .utility) {
                lock.hold(trial: trial, work: work, timestamps: timestamps)
            }

            guard timestamps.waitAcquired(until: deadline(milliseconds: 2_000)) else {
                return false
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    lock.touch { acquired, observedTrial in
                        mainSide.withLock { $0 = (acquired, observedTrial) }
                        mainSideDone.signal()
                    }
                }
            }

            return mainSideDone.wait(timeout: .now() + .seconds(2)) == .success
                && timestamps.waitReleased(until: deadline(milliseconds: 2_000))
        }

        #expect(finished)
        let observation = try #require(mainSide.withLock { $0 })
        #expect(observation.acquired >= timestamps.release)
        #expect(observation.observedTrial == trial)
        #expect(timestamps.resultCorrect)
        #expect(timestamps.cpuReadings.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func asyncBarrierHoldReturnsBeforeTheWorkEnds() async {
        let work = holderWork(milliseconds: 5)
        let lock = ContendedLocks.make(.barrierQueueAsyncWrite, holderQoS: .utility)
        let timestamps = HolderTimestamps()

        let (releaseWhenHoldReturned, released) = await onBenchmarkThread {
            lock.hold(trial: 3, work: work, timestamps: timestamps)
            let releaseWhenHoldReturned = timestamps.release

            return (releaseWhenHoldReturned, timestamps.waitReleased(until: deadline(milliseconds: 2_000)))
        }

        #expect(releaseWhenHoldReturned == 0)
        #expect(released)
        #expect(timestamps.release > 0)
    }

    // A wait without a mark returns at its deadline; reset forgets an earlier mark.
    @Test(.timeLimit(.minutes(1)))
    func holderTimestampWaitsEndAtTheirDeadline() async {
        let timestamps = HolderTimestamps()

        let observation = await onBenchmarkThread {
            let start = Clock.now()
            let acquiredBeforeMark = timestamps.waitAcquired(until: start + ticks(milliseconds: 20))
            let waited = Clock.now() - start

            timestamps.markAcquired()
            let acquiredAfterMark = timestamps.waitAcquired(until: deadline(milliseconds: 2_000))
            let releasedWithoutMark = timestamps.waitReleased(until: deadline(milliseconds: 20))

            timestamps.reset()
            let acquiredAfterReset = timestamps.waitAcquired(until: deadline(milliseconds: 20))

            return (acquiredBeforeMark, waited, acquiredAfterMark, releasedWithoutMark, acquiredAfterReset)
        }

        #expect(observation.0 == false)
        #expect(observation.1 >= ticks(milliseconds: 20))
        #expect(observation.2 == true)
        #expect(observation.3 == false)
        #expect(observation.4 == false)
        #expect(timestamps.acquire == 0)
    }
}

private func classify(
    holderRelease: UInt64 = 400,
    mainArrival: UInt64 = 300,
    mainAcquire: UInt64 = 450
) -> TrialOutcome {
    TrialOutcome.classify(
        holderAcquire: 200,
        holderRelease: holderRelease,
        mainArrival: mainArrival,
        mainAcquire: mainAcquire,
        loadStop: 600
    )
}

private func ticks(milliseconds: UInt64) -> UInt64 {
    milliseconds * 1_000_000 * UInt64(Clock.timebase.denom) / UInt64(Clock.timebase.numer)
}

private func deadline(milliseconds: UInt64) -> UInt64 {
    Clock.now() + ticks(milliseconds: milliseconds)
}

/// Holder work that takes about the given time on this machine.
private func holderWork(milliseconds: UInt64) -> HolderWork {
    let probeIterations = 100_000
    let start = Clock.now()
    _ = referenceLoop(iterations: probeIterations)
    let probeTicks = max(Clock.now() - start, 1)
    let iterations = Int(ticks(milliseconds: milliseconds) * UInt64(probeIterations) / probeTicks)

    return HolderWork(iterations: iterations, expectedResult: referenceLoop(iterations: iterations))
}
