import Dispatch
import Synchronization
import Testing

@testable import SyncBench

@Suite struct PriorityInversionTests {
    // Missing registration, trial emission or warm-up indexing must fail the complete attempt.
    @Test(.timeLimit(.minutes(1)))
    func priorityInversionSmokeRunPasses() async throws {
        let attempt = try await runAsyncCodeAttempt(.priorityInversionSmoke)

        #expect(attempt.status == "completed")
        #expect(attempt.blocks.count == 4)
        #expect(attempt.checks.count == 4)
        #expect(attempt.lines.allSatisfy { $0["type"] as? String != "batch" })
        for block in attempt.blocks {
            let position = try #require(block["block"] as? Int)
            let trials = attempt.lines(type: "trial", block: position)
            #expect(trials.count == 4)
            #expect(trials.compactMap { $0["trial"] as? Int } == [0, 1, 2, 3])
            #expect(trials.compactMap { $0["warmup"] as? Bool } == [true, false, false, false])
            #expect(trials.allSatisfy { $0["holderQoS"] as? String == "utility" })
            #expect(block["threads"] as? Int == 1)
            #expect(block["qos"] as? String == "utility")
        }
        #expect(attempt.checks.allSatisfy { $0["name"] as? String == "priorityInversion.utilityHolder" })
    }

    // An absent acquire must stop the controller before any main-side lock attempt is submitted.
    @Test(.timeLimit(.minutes(1)))
    func stuckHolderTimesOutWithoutBlockingMain() async {
        let lock = UnacquiredHolderLock()
        let timestamps = HolderTimestamps()
        let mainSide = MainSideRecord()
        let work = HolderWork(iterations: 1, expectedResult: referenceLoop(iterations: 1))
        let tunables = RunRequest.priorityInversionSmoke.tunables.priorityInversion!
        let observation = await onBenchmarkThread {
            let holder = HolderThread(qos: .utility, lock: lock, work: work, timestamps: timestamps)
            let loadThreads = LoadThreads(count: 1, qos: .userInitiated)
            defer {
                holder.shutDown()
                loadThreads.shutDown()
            }
            let setup = TrialSetup(
                lock: lock,
                holder: holder,
                timestamps: timestamps,
                tunables: tunables,
                loadThreads: loadThreads,
                acquireTimeoutTicks: ticks(milliseconds: 200),
                mainSide: mainSide
            )
            let start = Clock.now()
            let result = setup.runTrials()
            return (result.timedOut, result.trials.count, Clock.now() - start)
        }

        #expect(observation.0)
        #expect(observation.1 == 0)
        #expect(observation.2 >= ticks(milliseconds: 200))
        #expect(observation.2 < ticks(milliseconds: 1_000))
        #expect(mainSide.arrival == 0)
        #expect(lock.touched.load(ordering: .acquiring) == false)
    }

    // Reject every malformed row selection, rather than silently omitting requested blocks.
    @Test func rejectsUnknownMechanismAndHolder() {
        let invalidRows: [([String], [String])] = [
            (["unknown"], ["utilityHolder"]),
            (["atomic"], ["utilityHolder"]),
            (["actor"], ["unknown"]),
            ([], ["utilityHolder"]),
            (["actor", "actor"], ["utilityHolder"]),
            (["actor"], []),
            (["actor"], ["backgroundHolder", "backgroundHolder"]),
        ]
        for (mechanisms, operations) in invalidRows {
            var request = RunRequest.priorityInversionSmoke
            request.mechanisms = mechanisms
            request.operations = operations
            #expect(throws: RequestError.self) { try PriorityInversion(request: request) }
        }
        var request = RunRequest.priorityInversionSmoke
        request.variant = "unknown"
        #expect(throws: RequestError.self) { try PriorityInversion(request: request) }
        request.variant = "default"
        request.tunables.threads = 2
        #expect(throws: RequestError.self) { try PriorityInversion(request: request) }
    }

    @Test func rejectsMissingTunables() {
        var request = RunRequest.priorityInversionSmoke
        request.tunables.priorityInversion = nil
        #expect(throws: RequestError.self) { try PriorityInversion(request: request) }
    }

    // The main thread's scheduled sleep must stay below the five-second finish allowance.
    @Test func mainDelayIsBoundedToOneSecond() throws {
        var request = RunRequest.priorityInversionSmoke
        for delay in [0, 1_000_000] {
            request.tunables.priorityInversion!.mainDelayMicroseconds = delay
            _ = try PriorityInversion(request: request)
        }
        for delay in [1_000_001, 60_000_000] {
            request.tunables.priorityInversion!.mainDelayMicroseconds = delay
            do {
                _ = try PriorityInversion(request: request)
                Issue.record("A main delay above one second was accepted: \(delay)")
            } catch {
                #expect(error.message.contains("priorityInversion.mainDelayMicroseconds"))
            }
        }
    }

    // Values accepted by generic validation must still fit the experiment's duration conversions.
    @Test func rejectsUnrepresentableTrialDurations() {
        for field in ["loadMilliseconds", "mainDelayMicroseconds", "pauseMilliseconds"] {
            var request = RunRequest.priorityInversionSmoke
            switch field {
            case "loadMilliseconds": request.tunables.priorityInversion!.loadMilliseconds = Int.max
            case "mainDelayMicroseconds": request.tunables.priorityInversion!.mainDelayMicroseconds = Int.max
            default: request.tunables.priorityInversion!.pauseMilliseconds = Int.max
            }
            #expect(throws: RequestError.self) { try PriorityInversion(request: request) }
        }
    }

    // Each incorrect trial counts once; censorship alone is not a correctness failure.
    @Test func checksWorkObservationExclusionAndTimeout() {
        let incorrectTrials: [(Bool, Int, UInt64)] = [
            (false, 0, 450), (true, -1, 450), (true, 0, 399), (false, -1, 399),
        ]
        for (correct, observed, acquire) in incorrectTrials {
            let check = PriorityInversionChecks.check(
                operation: "utilityHolder",
                trials: [trialLine(correct: correct, observed: observed, acquire: acquire)],
                timedOut: false,
                block: 3
            )
            #expect(!check.passed)
            #expect(check.violations == 1)
            #expect(check.block == 3)
        }
        let completed = PriorityInversionChecks.check(
            operation: "backgroundHolder",
            trials: [
                trialLine(outcome: .valid),
                trialLine(acquire: 601, outcome: .censored),
                trialLine(arrival: 401, outcome: .invalid),
            ],
            timedOut: false,
            block: 2
        )
        #expect(completed.passed)
        #expect(completed.violations == 0)
        #expect(completed.name == "priorityInversion.backgroundHolder")
        #expect(completed.detail.contains("valid 1, censored 1, invalid 1"))

        let timedOut = PriorityInversionChecks.check(operation: "utilityHolder", trials: [], timedOut: true, block: 0)
        #expect(!timedOut.passed)
        #expect(timedOut.violations == 0)
    }

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

extension RunRequest {
    fileprivate static var priorityInversionSmoke: RunRequest {
        var request = RunRequest.golden
        request.experiment = "priorityInversion"
        request.variant = "default"
        request.mechanisms = ["osUnfairLock", "dispatchSemaphore", "barrierQueueAsyncWrite", "actor"]
        request.operations = ["utilityHolder"]
        request.tunables.priorityInversion = PriorityInversionTunables(
            holderWorkIterations: 10_000,
            loadQoS: .userInitiated,
            loadMilliseconds: 20,
            mainDelayMicroseconds: 1_000,
            pauseMilliseconds: 5,
            warmupTrials: 1,
            trials: 3
        )
        return request
    }
}

/// Controls the one failure not offered by real locks: hold returns without publishing an acquire.
private final class UnacquiredHolderLock: ContendedLock {
    let touched = Atomic<Bool>(false)

    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {}

    @MainActor
    func touch(done: @escaping @Sendable (UInt64, Int) -> Void) {
        touched.store(true, ordering: .releasing)
        done(Clock.now(), -1)
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

private func trialLine(
    correct: Bool = true,
    observed: Int = 0,
    arrival: UInt64 = 300,
    acquire: UInt64 = 450,
    outcome: TrialOutcome = .valid
) -> TrialLine {
    TrialLine(
        block: 3,
        trial: 0,
        warmup: false,
        holderQoS: .utility,
        loadStart: 100,
        loadStop: 600,
        holderAcquire: 200,
        holderRelease: 400,
        mainArrival: arrival,
        mainAcquire: acquire,
        holderCPUReadings: [0, 0],
        mainCPU: 1,
        holderResultCorrect: correct,
        mainObservedTrial: observed,
        outcome: outcome
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
