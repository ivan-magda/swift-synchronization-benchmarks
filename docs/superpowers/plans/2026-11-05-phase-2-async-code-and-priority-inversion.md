# Harness Phase 2 Implementation Plan: async code and priority inversion

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The harness runs experiment 7 (`asyncCode`, parts A, B and C) and experiment 8B (`priorityInversion`) on both iPhones from the Mac script, calibrates the 8B work size, pins each phone's iOS build in the plans, records System Trace runs, and accepts or rejects every attempt by the checks in the design.

**Architecture:** Both experiments plug into the existing `Experiment` / `BlockContext` / `RunController` path of the app and into the per-experiment branches of the Mac script's attempt checker. Experiment 7C compiles one probe file into two static libraries with different Swift settings. Experiment 8B runs one trial at a time: a low-QoS holder thread, load threads on every CPU and a job on the main thread, all coordinated by one controller thread, and writes one `trial` line per trial.

**Tech Stack:** Swift 6.4 (Xcode 27.1), UIKit, Synchronization, os, Dispatch, Swift Testing on the iOS Simulator; XcodeGen 2.46.0; Python 3.9+ standard library with `unittest`; `xcrun devicectl`, `xcrun xctrace`.

**Spec:** `docs/harness-design.md` and `docs/experiments.md` (experiments 7 and 8B). Read both before any task. The phase 1 plan (`docs/superpowers/plans/2026-11-05-phase-1-core-and-base-comparison.md`), `docs/phase-1-acceptance.md` and `docs/phase-1-decisions.md` describe the code this plan extends.

## Phases

This is plan 2 of 3 for milestone 7:
1. Done: harness core, calibration, base comparison, Mac script, checks.
2. This plan: async code (7), priority inversion (8B), the 8B work-size calibration, per-phone iOS builds, System Trace runs.
3. Next: request registry (2), hot flag (3), transactional store (4), main-thread cache (8A) with the display-rate calibration, creation cost (9).

## Names

Code and data use these names. Experiment numbers appear only in docs.

| Thing | Name |
|---|---|
| Experiment 7, ID and type | `asyncCode`, `AsyncCode` |
| Experiment 8B, ID and type | `priorityInversion`, `PriorityInversion` |
| 7 part A, B, C (request `variant`) | `callerPaths`, `batching`, `isolationSettings` |
| 7A caller paths (request `operations`) | `onActor`, `fromBackgroundTask`, `fromManyTasks`, `fromMainActor`, `toMainActor` |
| 7B rows (operations) | `oneAwaitPerGroup`, `awaitPerOperation`, `oneLockPerGroup` |
| 7C operation, and its rows (request `mechanisms`) | `callFromMainActor`; `templateDefaults`, `swift6Language`, `concurrentAttribute` |
| 7C libraries and probe type | `IsolationProbeTemplate`, `IsolationProbeSwift6`; `IsolationProbe` |
| 8B variant | `default` |
| 8B holder QoS (operations) | `utilityHolder`, `backgroundHolder` |
| New line type | `trial` |
| New metrics | `callTime` (ticks), `mainThreadCPUAtBatchStart` and `mainThreadCPUAtBatchEnd` (microseconds), `holderWork` (ticks) |
| New calibration block | `holderWorkSingleThread` |
| New tunables | `tunables.asyncCode`, `tunables.priorityInversion` |
| New plan fields | `iosBuilds` (replaces `iosBuild`), `traced` |

## Global Constraints

Everything in the phase 1 plan's Global Constraints still applies: toolchain, Python 3.9, app settings, explicit isolation, timed-code rules, data rules, readable code, no personal identifiers, English text, a commit after each task. In addition:

- **Wrappers must not add costs that ordinary app code would not have** (Ivan, 2026-11-05). Release defaults stay on, including dynamic exclusivity checks. Experiments 7 and 8B write each mechanism as ordinary app code in their own types. They never use `StateProtection`, `ProtectedInteger`, `SharedIntegers` or the experiment 1 queue integers: one generic class used with another state type shares one property declaration, and that changes experiment 1's machine code.
- **iOS is not updated** (Ivan, 2026-11-05). Each phone stays on its installed iOS 26.6.x build. Non-smoke plans pin each phone's build in `iosBuilds`.
- **The main thread never waits without a limit.** In 8B the main thread waits on a lock at most until the load stops plus the holder's remaining work. Every controller wait has a deadline.
- **Never pass `SWIFT_*` settings on the `xcodebuild` command line.** Command-line settings apply to every target and would erase the difference between the two 7C libraries.
- **Traces stay private.** `.trace` files contain device names and identifiers. They live under ignored `results/` and are never committed or published.

## Decisions this plan makes (agent's calls, open to correction)

- **8B trial order:** the holder takes the lock while the CPUs are free, then the load starts, then the main thread arrives 1 ms after the holder's acquire. The design said "load first"; under full load a `.background` holder may not get a core even to take the lock, and such trials measure nothing. Explained to Ivan on 2026-11-05. `docs/harness-design.md` changes in Task 13.
- **8B mechanisms:** every lock and queue plus the actor: `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `objcSync`, `serialQueue`, `barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore`, `actor`. Both `.barrier` rows, as in the other experiments. With `pthreadReadWriteLock` and both `.barrier` rows the holder writes and the main thread reads, as in an image cache.
- **8B load:** one load thread per CPU (`phone.cpuCount`) at `tunables.priorityInversion.loadQoS` (`userInitiated` in all plans: above both holder QoS values, below the main thread). The load stops at a fixed tick. The acceptance plans use 300 ms, so a mechanism that does not donate priority shows a censored wait of at least 300 ms, above the 250 ms hang threshold. The pilot sets the final length.
- **8B work:** the holder runs `referenceLoop(iterations:)` for `holderWorkIterations`, the same for every mechanism. Calibration derives the count for 5 ms on an idle performance core; plans write `"holderWorkIterations": "fromCalibration"` and the script fills in the phone's number.
- **8B controller QoS:** `tunables.qos` (`userInteractive` in the plans), so it wakes at once when the holder has the lock.
- **8B trial count:** the spec's "at least 1,000 trials per mechanism" is for the main runs: their plans reach it with `trials` × `repeats` (milestone 10). The acceptance plan runs 10 trials per block.
- **7A blocks:** the table in Task 6. The lock rows appear in the paths where a lock is a real alternative; `onActor` and `toMainActor` have only their actor row.
- **7B state:** an array of 128 counters; operation `k` increments counter `k % 128`. With a single `Int` the compiler folds 100 increments into one addition, and "100 operations" would measure nothing.
- **7C rows** are the three ways a nonisolated async function can be compiled. Thread switches are observed in the app: the probe counts how many of its calls ran on the main thread. Instruments only illustrates.
- **7C libraries** are named `IsolationProbeTemplate` and `IsolationProbeSwift6`. The design's `Exp7Template` and `Exp7Swift6` break the naming rule.
- **Main-thread CPU time** comes from `thread_info(THREAD_BASIC_INFO)` on the main thread's Mach port, in microseconds, read just outside each batch.
- **System Trace runs** record all processes on the phone, started by the script before the launch. A plan with `"traced": true` produces only traced attempts; analysis ignores them.
- **Per-phone iOS builds:** `iosBuilds` maps phone keys to builds. The doctor compares the phone's build, and the attempt check compares the `run` line's `phone.osBuild`.

## Review Focus

1. **An 8B trial does not finish.** If the holder never takes the lock, the controller stops the block after its deadline, never schedules the main side, and the block check fails; Task 10 tests this. If a holder takes the lock and never releases it (only a code error can do that, because the load always stops at its tick), the main thread stays blocked and the runner ends the attempt as `timeout` at the run's time limit. That outcome is bounded; the plan adds no other recovery path.
2. **The 7C settings are not applied** (a project-level setting leaks into a library, or a build passes `SWIFT_*` on the command line). Expected: the 7C check fails in the app, and `build-info.json` shows each library's settings. Tasks 5 and 7 test where the probe's body runs.
3. **8B runs without a calibrated work size.** Expected: `run` refuses before installing, naming the phone and the missing file. Task 4 tests it.
4. **The checker accepts a file of the wrong shape**: 49 call-time lines instead of 50, a missing main-thread CPU line, a missing trial, a trial whose outcome label disagrees with its timestamps. Tasks 8 and 11 test these malformed files.
5. **`xctrace` does not start, or does not stop.** Expected: the session stops with a reason before launching the app, and no `xctrace` process outlives the session. Task 12 tests it with a fake recorder.

## Prerequisites from Ivan

- The experiment 1 queue fix and the repeated phase 1 acceptance are committed before Task 1.
- Before Task 14: both iPhones connected, unlocked, Auto-Lock Never, Developer Mode on, automatic iOS updates off; `local.json` present.

---

### Task 1: Per-block expectations in the attempt checker

Today `ExpectedAttempt` has one thread count, one QoS rule and one batch size per mechanism for the whole attempt. Experiments 7 and 8B need them per block. This task changes the structure only; `baseComparison` and `calibration` behave exactly as before.

**Files:**
- Modify: `scripts/runner/expected_attempt.py`, `scripts/runner/attempt_check.py`
- Test: `scripts/tests/test_expected_attempt.py` (create), `scripts/tests/test_attempt_check.py`

**Interfaces:**
- Produces:

```python
@dataclass(frozen=True)
class ExpectedSamples:
    metric: str
    unit: str
    per_thread: bool           # one line per thread (with "thread"), or one line for the block (no "thread")
    lines: int
    values_per_line: int
    cpu_readings: bool         # cpuAtStart and cpuAtEnd present


@dataclass(frozen=True)
class ExpectedBlock:
    mechanism: str
    operation: str
    threads: int
    qos: str
    operations_per_batch: int
    batch_lines: int           # 0 when the block writes no batch lines
    samples: Tuple[ExpectedSamples, ...]
    trial_lines: int           # 0 for every experiment except priorityInversion
    check: str                 # the one check this block must carry


@dataclass(frozen=True)
class ExpectedAttempt:
    blocks: Dict[Tuple[str, str], ExpectedBlock]
    warmup_batches: int
    measured_batches: int
    sub_batches: int
    run_checks: FrozenSet[str]


def expected_attempt(request: Dict[str, Any], cpu_count: int) -> ExpectedAttempt
```

- [ ] **Step 1: Write the failing tests** in `scripts/tests/test_expected_attempt.py`:

```python
def test_base_comparison_blocks_carry_threads_qos_and_check(self):
    request = golden_request()   # baseComparison, oneThread, mutex × increment, {"default": 4}
    expected = expected_attempt(request, cpu_count=6)
    block = expected.blocks[("mutex", "increment")]
    self.assertEqual(block.threads, 1)
    self.assertEqual(block.qos, "userInitiated")
    self.assertEqual(block.operations_per_batch, 4)
    self.assertEqual(block.batch_lines, 1 * (1 + 2))
    self.assertEqual(block.samples, ())
    self.assertEqual(block.trial_lines, 0)
    self.assertEqual(block.check, "baseComparison.increment")

def test_calibration_blocks_keep_their_thread_and_sample_rules(self):
    expected = expected_attempt(calibration_request(repeats=200), cpu_count=6)
    single = expected.blocks[("clockSingleThread", "")]
    self.assertEqual((single.threads, single.qos, single.batch_lines), (1, "userInteractive", 0))
    self.assertEqual(single.samples, (ExpectedSamples("clockRead1000", "ticks", True, 1, 200, False),))
    background = expected.blocks[("cpuSpeedBackground", "")]
    self.assertEqual((background.threads, background.qos), (6, "background"))
    self.assertEqual(background.samples, (ExpectedSamples("referenceLoop", "ticks", True, 6, 200, True),))
    self.assertEqual(single.check, "calibration.samples")
```

- [ ] **Step 2: Run them; expect failure** (`ExpectedSamples` does not exist).

Run: `python3 -m unittest discover -s scripts/tests -t scripts -p 'test_expected_attempt.py' -v`
Expected: FAIL with an import error.

- [ ] **Step 3: Implement** the three dataclasses and both existing branches in `expected_attempt.py`. Then change `attempt_check._check_work` to read threads, QoS, batch count, samples and the check name from `expected.blocks[(mechanism, operation)]` instead of the attempt-wide fields and the calibration special cases. The rules stay the same; only where they read their numbers changes.

- [ ] **Step 4: Run the whole Python suite.** Every existing test passes unchanged.

Run: `python3 -m unittest discover -s scripts/tests -t scripts`
Expected: `OK`.

- [ ] **Step 5: Commit:** `git commit -m "Give the attempt checker per-block expectations"`

---

### Task 2: Request and result-line contract for the new experiments (Swift)

**Files:**
- Modify: `Harness/Execution/RunRequest.swift`, `Harness/Results/ResultLines.swift`, `Harness/Execution/BlockContext.swift`, `Harness/Timing/BatchTimer.swift`, `Tests/TestSupport.swift`, `docs/data-format.md`
- Test: `Tests/RunRequestTests.swift`, `Tests/ThreadTests.swift`

**Interfaces:**
- Produces:

```swift
/// Tunables of experiment 7, path "fromManyTasks".
struct AsyncCodeTunables: Codable, Equatable, Sendable {
    /// Timed calls per task.
    var callsPerTask: Int
    /// Untimed calls per task before the timed ones.
    var warmupCallsPerTask: Int
}

/// Tunables of experiment 8B.
struct PriorityInversionTunables: Codable, Equatable, Sendable {
    /// `referenceLoop` iterations the holder runs under the lock.
    var holderWorkIterations: Int
    var loadQoS: QoS
    var loadMilliseconds: Int
    var mainDelayMicroseconds: Int
    var pauseMilliseconds: Int
    var warmupTrials: Int
    var trials: Int
}

// New optional members:
// Tunables.asyncCode: AsyncCodeTunables?
// Tunables.priorityInversion: PriorityInversionTunables?
// RunRequest.traced: Bool?        // true only in traced plans; omitted otherwise

enum TrialOutcome: String, Codable, Sendable {
    case valid
    case censored
    case invalid
}

/// One trial of experiment 8B.
struct TrialLine: Encodable, Sendable {
    let type = "trial"
    let block: Int
    let trial: Int
    let warmup: Bool
    let holderQoS: QoS
    let loadStart: UInt64
    let loadStop: UInt64
    let holderAcquire: UInt64
    let holderRelease: UInt64
    let mainArrival: UInt64
    let mainAcquire: UInt64
    /// CPU numbers on the holder side at acquire and at release.
    let holderCPUReadings: [Int]
    /// CPU number of the main thread after it got the lock.
    let mainCPU: Int
    let holderResultCorrect: Bool
    /// The value the main thread read under the lock: the holder writes the trial index.
    let mainObservedTrial: Int
    let outcome: TrialOutcome
}

enum BatchEdge: Sendable {
    case start
    case end
}

// BlockContext additions:
func runOnThreads(
    recording: BlockRecording = .batches,
    workerQoS: QoS? = nil,          // nil: description.qos, as today
    _ body: @escaping @Sendable (_ thread: Int, _ barrier: ThreadBarrier, _ log: ThreadLog) -> Void
) -> [ThreadLog]

/// Appends the block's trial lines. Owner thread only; after every samples line of the block.
func appendTrials(_ trials: [TrialLine])

// BatchTimer, async overload, new parameters (existing callers compile unchanged):
static func timeBatches(
    layout: BatchLayout,
    barrier: TaskBarrier,
    log: ThreadLog,
    isolation: isolated (any Actor)? = #isolation,
    recordExecutorCPU: (CPUReadingSlot) async -> Void,
    recordBatchEdge: (_ batch: Int, _ edge: BatchEdge) -> Void = { _, _ in },
    runOperations: (_ batch: Int, _ subBatch: Int, _ count: Int) async -> Int
) async
```

`recordBatchEdge(batch, .start)` runs just before the batch's start tick; `recordBatchEdge(batch, .end)` just after its end tick. With `isolation` the whole loop, including `runOperations`, runs on the caller's actor, so a main-actor or actor caller adds no hops of its own.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func requestWithNewTunablesRoundTrips() throws {
    var request = RunRequest.golden
    request.traced = true
    request.tunables.asyncCode = AsyncCodeTunables(callsPerTask: 20, warmupCallsPerTask: 2)
    request.tunables.priorityInversion = PriorityInversionTunables(
        holderWorkIterations: 10_000,
        loadQoS: .userInitiated,
        loadMilliseconds: 20,
        mainDelayMicroseconds: 1_000,
        pauseMilliseconds: 5,
        warmupTrials: 1,
        trials: 3
    )
    let encoded = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(RunRequest.self, from: encoded) == request)
}

```

Three more tests, described by their assertions:
- `batchTimerRunsOnTheCallersActor` (a `@MainActor` test): one `TaskBarrier(parties: 1)`, layout 1 warm-up / 2 measured / 2 sub-batches. Inside `runOperations`, count the calls where `pthread_main_np() != 0`. Expect 6 of 6. The same call from `Task.detached` counts 0 of 6.
- `batchEdgesAreReportedAroundEveryBatch`: record every `(batch, edge)` pair. Expect `(0, .start), (0, .end), (1, .start), (1, .end), (2, .start), (2, .end)`.
- The existing golden-fixture test still passes byte for byte, because nil members are omitted.

- [ ] **Step 2: Run them; expect compile errors** for the missing members.

Run: `xcodegen generate && xcodebuild test -project SyncBench.xcodeproj -scheme SyncBench -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: build failure naming `AsyncCodeTunables`.

- [ ] **Step 3: Implement** the members above. `RunRequest.validate()` adds only generic rules: when present, every count in the new tunables is at least 0, `callsPerTask`, `loadMilliseconds`, `trials` and `holderWorkIterations` are at least 1, and `warmupTrials + trials` fits the overflow checks. Experiment-specific rules live in the experiments' `init`. `appendTrials` preconditions the owner thread, and `appendSamples` preconditions that no trial line of the block was appended yet.

- [ ] **Step 4: Update `docs/data-format.md`:** the new tunables and `traced`; the `trial` line with every field above; the order inside a block group (`block`, then `batch` lines, then `samples` lines, then `trial` lines ordered by `trial`); the outcome rule from Task 9, written in words. The end line gets no new counter.

- [ ] **Step 5: Run the Simulator tests; all pass**, including the golden fixture byte comparison.

- [ ] **Step 6: Commit:** `git commit -m "Add tunables, trial lines and isolation-aware batch timing"`

---

### Task 3: Plans and the file check for the new contract (Python)

**Files:**
- Modify: `scripts/runner/plans.py`, `scripts/runner/doctor.py`, `scripts/runner/attempt_check.py`, `scripts/runner/sessions.py`, every file in `plans/` (`"iosBuild": null` becomes `"iosBuilds": {}`)
- Create: `scripts/runner/trials.py`
- Test: `scripts/tests/test_plans.py`, `scripts/tests/test_doctor.py`, `scripts/tests/test_attempt_check.py`, `scripts/tests/test_trials.py` (create)

**Interfaces:**
- Consumes: `ExpectedBlock.trial_lines` (Task 1); the contract of Task 2.
- Produces:

```python
# plans.py
# Plan gains:   ios_builds: Dict[str, str]   (from "iosBuilds"; default {})
#               traced: bool                 (from "traced"; default False)
# PlannedRun gains: traced: bool
# make_request(run, attempt_id, attempt) adds "traced": True only when run.traced.

# trials.py
def classify_trial(line: Dict[str, Any]) -> str      # "valid" | "censored" | "invalid"

# attempt_check.py
def check_attempt(
    result_file: Path,
    done_file: Optional[Path],
    request: Dict[str, Any],
    build_id: str,
    expected_os_build: Optional[str] = None,
) -> AttemptVerdict
```

Plan rules:
- `iosBuild` is rejected with the message `"iosBuild was replaced by iosBuilds (phone key → iOS build)"`.
- A non-smoke plan needs a non-empty `iosBuilds`; keys are phone-key identifiers, values are build identifiers.
- `tunables.asyncCode`: `callsPerTask` ≥ 1, `warmupCallsPerTask` ≥ 0.
- `tunables.priorityInversion`: `holderWorkIterations` is an integer ≥ 1 or the string `"fromCalibration"`; `loadQoS` is a QoS name; `loadMilliseconds` ≥ 1; `mainDelayMicroseconds`, `pauseMilliseconds`, `warmupTrials` ≥ 0; `trials` ≥ 1.
- In a launch request (`_completed_request`), `holderWorkIterations` must be an integer: the session resolves the string first (Task 4).

Doctor: for a non-smoke plan, finding `ios-build` fails when the phone key is missing from `iosBuilds`; otherwise it compares as today. `run_session` passes `plan.ios_builds.get(phone.key)` to `check_attempt`, which rejects a `run` line whose `phone.osBuild` differs (`"phone iOS build differs from the plan"`).

Trial lines in `attempt_check`:
- `_validate_line` knows `trial` with the fields and types of Task 2.
- Inside a block group, trial lines come after the samples lines, carry the block's position, have `trial` = 0, 1, 2… without gaps, `warmup` true for exactly the first `warmupTrials`, and every timestamp inside the block's start and end.
- `holderQoS` equals the block's `qos`.
- `outcome` equals `classify_trial(line)`.
- `holderResultCorrect` is true and `mainObservedTrial == trial` in every trial; when `mainArrival < holderRelease`, also `mainAcquire >= holderRelease` (the main thread cannot have the lock while the holder has it).
- The number of trial lines equals `ExpectedBlock.trial_lines`; any trial line in a block that expects none is invalid.

`classify_trial` is the rule of Task 9, in Python:

```python
def classify_trial(line: Dict[str, Any]) -> str:
    """Valid: the main thread arrived while the holder held the lock and the load ran.
    Censored: such an arrival, but the main thread got the lock after the load stopped.
    Invalid: everything else."""
    arrived_during_hold = line["holderAcquire"] < line["mainArrival"] < line["holderRelease"]
    if not arrived_during_hold or line["mainArrival"] >= line["loadStop"]:
        return "invalid"
    if line["mainAcquire"] > line["loadStop"]:
        return "censored"
    return "valid"
```

- [ ] **Step 1: Write the failing tests:**
  - `test_trials.py`: one case per outcome (valid; censored; arrival before acquire; arrival after release; arrival after load stop), with literal tick values.
  - `test_plans.py`: `iosBuild` rejected; non-smoke plan without `iosBuilds` rejected; `"fromCalibration"` accepted in a plan; a nested tunable below its minimum rejected with the field named; `traced` copied into requests only when true.
  - `test_doctor.py`: non-smoke plan, phone key missing from `iosBuilds` → `ios-build` fails.
  - `test_attempt_check.py`: a base-comparison attempt with one extra `trial` line is invalid; an attempt whose `phone.osBuild` differs from `expected_os_build` is invalid.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement**, and change every plan in `plans/` to `"iosBuilds": {}`.
- [ ] **Step 4: Run the whole Python suite; `OK`.**
- [ ] **Step 5: Commit:** `git commit -m "Pin iOS builds per phone and check trial lines"`

---

### Task 4: Calibration of the holder work size

**Files:**
- Modify: `Harness/Timing/Calibration.swift`, `scripts/runner/expected_attempt.py`, `scripts/runner/attempt_check.py` (only if a calibration rule still names four blocks), `scripts/runner/calibration.py`, `scripts/bench.py`, `scripts/runner/sessions.py`, `scripts/runner/doctor.py`, `scripts/tests/synthetic_attempts.py`, `docs/data-format.md`
- Test: `Tests/CalibrationTests.swift`, `scripts/tests/test_calibration.py`, `scripts/tests/test_sessions.py`

**Interfaces:**
- Consumes: `referenceLoop(iterations:)`, the calibration block machinery, `derive_core_map`.
- Produces:

```python
def derive_holder_work(calibration_file: Path, core_map: Dict[str, Any]) -> Dict[str, Any]
# {"holderWorkIterations": int, "targetMilliseconds": 5, "iterationsMeasured": int,
#  "medianTicks": int, "samplesUsed": int}

def load_phone_calibration(results: Path, phone_key: str) -> Optional[Dict[str, Any]]

def resolve_tunables(tunables: Dict[str, Any], calibration: Optional[Dict[str, Any]]) -> Dict[str, Any]
# Returns a copy with "fromCalibration" replaced; raises CalibrationError naming the phone file when it cannot.
```

`results/<phone>/calibration.json` gains `"priorityInversion": <derive_holder_work result>`.

The fifth calibration block, `holderWorkSingleThread`, runs on one thread at `.userInteractive` while nothing else runs. Each of its `repeats` samples is the tick count of `referenceLoop(iterations: tunables.referenceLoopIterations)`, with `cpuAtStart` and `cpuAtEnd`. Metric `holderWork`, unit `ticks`. It must not use the metric `referenceLoop`: `derive_core_map` pools every line with that metric. The calibration attempt now has five blocks and `2 + 3 × cpuCount` samples lines.

The derivation uses integers only:

```python
TARGET_MILLISECONDS = 5

def derive_holder_work(calibration_file, core_map):
    lines = read_accepted_calibration(calibration_file)        # same check as derive_core_map
    phone = run_line(lines)["phone"]
    samples = holder_work_samples(lines)                       # (ticks, cpuAtStart, cpuAtEnd)
    performance = set(core_map["performance"])
    usable = [ticks for ticks, start, end in samples if start == end and start in performance]
    if len(usable) * 2 < len(samples):
        raise CalibrationError("fewer than half of the holderWork samples ran on one performance CPU")
    median_ticks = int(statistics.median(usable))
    target_ticks = (TARGET_MILLISECONDS * 1_000_000 * phone["timebaseDenominator"]) // phone["timebaseNumerator"]
    iterations_measured = run_line(lines)["request"]["tunables"]["referenceLoopIterations"]
    return {
        "holderWorkIterations": round(target_ticks * iterations_measured / median_ticks),
        "targetMilliseconds": TARGET_MILLISECONDS,
        "iterationsMeasured": iterations_measured,
        "medianTicks": median_ticks,
        "samplesUsed": len(usable),
    }
```

`run_session` loads the phone's calibration once when any pending run has `"fromCalibration"`, resolves the tunables before building each request, and records `calibrationAttemptID` in `session.json`. A missing file or a missing `priorityInversion` key stops the session before installation. The doctor reports it as finding `calibration`.

- [ ] **Step 1: Write the failing tests.**
  - `CalibrationTests`: five blocks; `holderWorkSingleThread` has one thread, `.userInteractive`, one `holderWork` samples line with `repeats` values and both CPU arrays.
  - `test_calibration.py`: timebase 125/3, 100,000 iterations measured, usable median 2,400 ticks on performance CPUs → `holderWorkIterations == 5_000_000` (5 ms = 120,000 ticks; 120,000 × 100,000 / 2,400). Samples on efficiency CPUs and samples with different start and end CPUs are ignored. Fewer than half usable → `CalibrationError`.
  - `test_sessions.py`: a plan with `"fromCalibration"` and no calibration file for the phone stops before `install` with a message naming `results/<phone>/calibration.json`; with the file, the launched request carries the integer.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.** Update `expected_attempt`, the calibration branch of `synthetic_attempts.py`, `bench.py calibrate` and `docs/data-format.md` ("Calibration work and checks").
- [ ] **Step 4: Run the Simulator tests and the Python suite; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Calibrate the priority-inversion holder work"`

---

### Task 5: Isolation probe libraries (experiment 7C)

**Files:**
- Create: `IsolationProbe/IsolationProbe.swift`
- Modify: `project.yml`, `scripts/runner/builds.py`
- Test: `Tests/IsolationProbeTests.swift` (create), `scripts/tests/test_builds.py`

**Interfaces:**
- Produces: modules `IsolationProbeTemplate` and `IsolationProbeSwift6`, each with `public enum IsolationProbe` (members below). The app refers to them as `IsolationProbeTemplate.IsolationProbe` and `IsolationProbeSwift6.IsolationProbe`.

The same file compiles into both libraries. Copy it exactly; its behavior is the experiment:

```swift
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
```

The two targets in `project.yml` (the folder is outside the app's source globs, so nothing compiles twice into the app):

```yaml
  IsolationProbeTemplate:
    type: library.static
    platform: iOS
    sources:
      - IsolationProbe
    settings:
      base:
        # The settings of a new Xcode 27.1 app (docs/experiments.md).
        SWIFT_VERSION: "5.0"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY: YES
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
        # NONISOLATED_NONSENDING_BY_DEFAULT and INFER_ISOLATED_CONFORMANCES stay unset:
        # they follow SWIFT_APPROACHABLE_CONCURRENCY, as in the template.
      configs:
        Release:
          SWIFT_OPTIMIZATION_LEVEL: -O
          SWIFT_COMPILATION_MODE: wholemodule

  IsolationProbeSwift6:
    type: library.static
    platform: iOS
    sources:
      - IsolationProbe
    settings:
      groups: [swiftSettings]
      configs:
        Release:
          SWIFT_OPTIMIZATION_LEVEL: -O
          SWIFT_COMPILATION_MODE: wholemodule
```

The `SyncBench` target adds both as dependencies. `builds.py` records, for each of the two library targets, `SWIFT_VERSION`, `SWIFT_APPROACHABLE_CONCURRENCY`, `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT`, `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, `SWIFT_OPTIMIZATION_LEVEL` and `SWIFT_COMPILATION_MODE` from `-showBuildSettings -json` into `build-info.json` under `librarySettings.<target>`.

- [ ] **Step 1: Write the failing tests** in one serialized suite. The probe's counters are shared, and Swift Testing runs tests in parallel by default. Task 7's 7C smoke test goes into the same suite.

```swift
@Suite(.serialized)
struct IsolationProbeTests {
    @MainActor
    @Test func templateSettingsKeepNonisolatedAsyncOnTheMainThread() async {
        IsolationProbeTemplate.IsolationProbe.reset()
        for _ in 0..<10 {
            await IsolationProbeTemplate.IsolationProbe.nonisolatedWork()
        }
        #expect(IsolationProbeTemplate.IsolationProbe.counts() == (calls: 10, onMainThread: 10))
    }

    @MainActor
    @Test func swift6SettingsMoveNonisolatedAsyncOffTheMainThread() async {
        // The same loop with IsolationProbeSwift6: expect (calls: 10, onMainThread: 0).
    }

    @MainActor
    @Test func concurrentAttributeMovesTheCallOffTheMainThread() async {
        // The same loop with IsolationProbeTemplate.IsolationProbe.concurrentWork(): expect (10, 0).
    }
}
```

`test_builds.py`: a fake `-showBuildSettings -json` with three targets → `build-info.json` has `settings` for `SyncBench` and `librarySettings` for both libraries with the values above.

- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.** If the compiler rejects `@concurrent` in Swift 5 mode, or the iOS 18 build (`IPHONEOS_DEPLOYMENT_TARGET=18.0`) does not compile, stop and report; do not change the settings to make it compile.
- [ ] **Step 4: Run the Simulator tests, an unsigned Release build for `generic/platform=iOS` with both deployment targets, and the Python suite; all pass.**

Run: `xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=18.0 -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit:** `git commit -m "Add the isolation probe libraries"`

---

### Task 6: Async code, caller paths (experiment 7A)

**Files:**
- Create: `Experiments/AsyncCode/AsyncCode.swift`, `Experiments/AsyncCode/AsyncCodeCounters.swift`, `Experiments/AsyncCode/CallerPaths.swift`, `Experiments/AsyncCode/AsyncCodeChecks.swift`, `Harness/Timing/MainThreadCPUClock.swift`
- Modify: `Harness/Execution/Experiment.swift` (registry), `docs/data-format.md`
- Test: `Tests/AsyncCodeTests.swift` (create)

**Interfaces:**
- Consumes: Task 2 (`isolation`, `recordBatchEdge`, `AsyncCodeTunables`), `BlockContext.runInTasks`, `TaskBarrier`, `ThreadLog`.
- Produces:

```swift
struct AsyncCode: Experiment {
    /// Variant → operation → the mechanisms measured with it. Python mirrors this table (Task 8).
    static let rows: [String: [String: [String]]]
    /// Tasks in path "fromManyTasks".
    static let manyTasks = 50
    /// Operations per await or per lock in experiment 7B.
    static let groupSize = 100
}

/// CPU time of the main thread, readable from any thread.
struct MainThreadCPUClock: Sendable {
    /// Keeps the main thread's Mach port. Must run on the main thread.
    @MainActor
    init()
    /// User plus system time of the main thread, in microseconds.
    func microseconds() -> UInt64
}
```

The rows of all three parts:

```swift
static let rows: [String: [String: [String]]] = [
    "callerPaths": [
        "onActor": ["actor"],
        "fromBackgroundTask": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
        "fromManyTasks": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
        "fromMainActor": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
        "toMainActor": ["mainActor"],
    ],
    "batching": [
        "oneAwaitPerGroup": ["actor"],
        "awaitPerOperation": ["actor"],
        "oneLockPerGroup": ["mutex"],
    ],
    "isolationSettings": [
        "callFromMainActor": ["templateDefaults", "swift6Language", "concurrentAttribute"],
    ],
]
```

`init` rules: the variant is a key of `rows`; `mechanisms` and `operations` are non-empty and unique; the blocks are every (operation, mechanism) pair of the request that the table allows, and every requested mechanism and operation appears in at least one block; `tunables.threads == 1`; `tunables.asyncCode` is present when `fromManyTasks` is requested. A block has 50 threads for `fromManyTasks` and 1 otherwise, QoS `tunables.qos`, and `request.operationsPerBatch(for: mechanism)` operations per batch.

The counters are ordinary app code. Each has `increment()` and `finalValue() -> Int`:

```swift
actor CounterActor {
    private var value = 0
    func increment()
    /// For path "onActor": an async method of the same actor, awaited from inside it.
    func incrementAsync() async
    /// Path "onActor": runs `BatchTimer.timeBatches` on this actor; one operation is `await incrementAsync()`.
    func runBatchesOnActor(layout: BatchLayout, barrier: TaskBarrier, log: ThreadLog) async
    func executorCPU() -> Int
    func finalValue() -> Int
}

@MainActor
final class MainActorCounter { /* private var value; increment(); executorCPU(); finalValue() */ }

final class MutexCounter: Sendable { /* private let value = Mutex(0) */ }
final class AllocatedUnfairLockCounter: Sendable { /* private let value = OSAllocatedUnfairLock(initialState: 0) */ }
final class NSLockCounter: @unchecked Sendable { /* private let lock = NSLock(); private var value = 0 */ }
```

What each caller path does:

| Path | Where the batch loop runs | One operation | Extra lines |
|---|---|---|---|
| `onActor` | inside `CounterActor`: `BatchTimer.timeBatches(..., isolation: self, ...)` | `await incrementAsync()` | — |
| `fromBackgroundTask` | one detached task (`runInTasks`) | actor: `await counter.increment()`; locks: `counter.increment()` | — |
| `fromManyTasks` | 50 detached tasks, `recording: .samplesOnly` | the same, one clock read before and after each call | one `callTime` line per task |
| `fromMainActor` | a `@MainActor` function called from the detached task; `BatchTimer` inherits the main actor | the same as `fromBackgroundTask` | main-thread CPU lines |
| `toMainActor` | one detached task | `await mainCounter.increment()` | main-thread CPU lines |

- Actor and main-actor rows record executor CPU readings through `executorCPU()`, as in experiment 1. Lock rows and `onActor` pass `{ _ in }`.
- `fromManyTasks`: each task makes `warmupCallsPerTask` untimed calls, waits once on the shared `TaskBarrier`, then makes `callsPerTask` timed calls into a buffer allocated before the block. Each value is `end - start` of one call. After `runInTasks` returns, the run thread appends one `samples` line per task: `thread` = task index, metric `callTime`, unit `ticks`.
- Main-thread CPU lines: `recordBatchEdge` stores `clock.microseconds()` into two buffers of `layout.totalBatches` values allocated before the block. After the block: two `samples` lines without `thread`, metrics `mainThreadCPUAtBatchStart` and `mainThreadCPUAtBatchEnd`, unit `microseconds`.
- `MainThreadCPUClock.init` takes `pthread_mach_thread_np(pthread_self())` on the main thread; the iOS SDK has no `pthread_main_thread_np`. `microseconds()` reads `thread_info(_:THREAD_BASIC_INFO)` for that port and adds user and system time. Create the clock on the run thread before the block with `DispatchQueue.main.sync { MainActor.assumeIsolated { MainThreadCPUClock() } }`.
- Create `MainActorCounter` on the run thread with `DispatchQueue.main.sync { MainActor.assumeIsolated { MainActorCounter() } }`, as experiment 1 does.

Checks: one per block, named `asyncCode.<operation>`. The final value must equal `threads × totalBatches × operationsPerBatch`, or `50 × (warmupCallsPerTask + callsPerTask)` for `fromManyTasks`.

- [ ] **Step 1: Write the failing tests** in `Tests/AsyncCodeTests.swift`:
  - `callerPathsSmokeRunPasses`: a smoke request with variant `callerPaths`, all five paths, mechanisms `actor`, `mainActor`, `mutex`, `osAllocatedUnfairLock`, `nsLock`, layout 1 warm-up / 2 measured / 2 sub-batches / `{"default": 40}`, `asyncCode` 5 timed and 1 warm-up call. Run it with `RunController.runToCompletion` on a benchmark thread. Expect 14 `block` lines, status `completed`, 14 passing `asyncCode.*` checks.
  - `fromManyTasksWritesOneCallTimeLinePerTask`: the `fromManyTasks` blocks have no `batch` lines and 50 `callTime` lines with 5 values each, threads 0…49.
  - `mainActorPathsWriteMainThreadCPU`: each `fromMainActor` and `toMainActor` block has both main-thread CPU lines with 3 values, and every start value is ≤ the end value of the same batch.
  - `rejectsRequestWithoutAllowedPairs` (only `fromMainActor` and only `mainActor`), `rejectsUnusedMechanism`, `rejectsManyTasksWithoutTunables`, `rejectsMoreThanOneThread`: `init` throws.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.** Register `"asyncCode"` in `ExperimentRegistry`. Add the `asyncCode` section to `docs/data-format.md`: the table, thread counts, extra lines, check names.
- [ ] **Step 4: Run the Simulator tests; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Add the async code caller paths"`

---

### Task 7: Async code, batching and isolation settings (experiments 7B and 7C)

**Files:**
- Modify: `Experiments/AsyncCode/AsyncCode.swift`, `Experiments/AsyncCode/AsyncCodeCounters.swift`, `Experiments/AsyncCode/AsyncCodeChecks.swift`, `docs/data-format.md`
- Create: `Experiments/AsyncCode/Batching.swift`, `Experiments/AsyncCode/IsolationSettings.swift`
- Test: `Tests/AsyncCodeTests.swift`, `Tests/IsolationProbeTests.swift`

**Interfaces:**
- Consumes: Task 5 (`IsolationProbe` in both modules), Task 6 (`AsyncCode.rows`, `groupSize`, main-thread CPU lines).
- Produces:

```swift
actor CounterGroupActor {
    /// 128 counters; operation k increments counter k % 128.
    private var counters = [Int](repeating: 0, count: 128)
    func incrementGroup(startingAt operation: Int)     // AsyncCode.groupSize operations
    func incrementOne(at operation: Int)
    func executorCPU() -> Int
    func total() -> Int
}

final class MutexCounterGroup: Sendable {
    private let counters = Mutex([Int](repeating: 0, count: 128))
    func incrementGroup(startingAt operation: Int)     // AsyncCode.groupSize operations under one withLock
    func total() -> Int
}
```

7B rows, each in one detached task with `BatchTimer`; `runOperations(batch, subBatch, count)` covers `count` single increments:

| Operation | Mechanism | Calls per `count` operations |
|---|---|---|
| `oneAwaitPerGroup` | `actor` | `count / 100` × `await group.incrementGroup(startingAt:)` |
| `awaitPerOperation` | `actor` | `count` × `await group.incrementOne(at:)` |
| `oneLockPerGroup` | `mutex` | `count / 100` × `group.incrementGroup(startingAt:)` |

`init` requires every `operationsPerBatch` value of a batching request to be a multiple of `subBatches × 100`. Check `asyncCode.<operation>`: `total()` equals the operations done.

7C rows: the batch loop runs in a `@MainActor` function (as `fromMainActor`), one operation is one call, and both main-thread CPU lines are written:

| Mechanism | One operation | Expected calls on the main thread |
|---|---|---|
| `templateDefaults` | `await IsolationProbeTemplate.IsolationProbe.nonisolatedWork()` | all |
| `swift6Language` | `await IsolationProbeSwift6.IsolationProbe.nonisolatedWork()` | none |
| `concurrentAttribute` | `await IsolationProbeTemplate.IsolationProbe.concurrentWork()` | none |

Reset the probe before the block. Check `asyncCode.callFromMainActor` passes when `calls` equals the operations done and `onMainThread` equals the expected number. Its detail names both numbers, for example `calls 1200/1200; on main thread 1200, expected 1200`.

- [ ] **Step 1: Write the failing tests:**
  - `batchingSmokeRunPasses`: three blocks, layout 1/2/2, `{"default": 400}`; status `completed`.
  - `batchingRejectsGroupsThatDoNotDivide`: `{"default": 300}` with 2 sub-batches → `init` throws.
  - `isolationSettingsSmokeRunPasses`, in the serialized `IsolationProbeTests` suite of Task 5 (it resets the shared probe): three blocks, `{"default": 20}`; all three checks pass, which proves 0 and 2 thread switches on the Simulator.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement**, and extend the `asyncCode` section of `docs/data-format.md`.
- [ ] **Step 4: Run the Simulator tests; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Add async batching and isolation settings"`

---

### Task 8: Async code in the attempt checker

**Files:**
- Modify: `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`
- Test: `scripts/tests/test_expected_attempt.py`, `scripts/tests/test_attempt_check.py`

**Interfaces:**
- Consumes: `ExpectedBlock` (Task 1); the table and line rules of Tasks 6 and 7.
- Produces: an `asyncCode` branch of `expected_attempt` and of `make_attempt_lines`; `ASYNC_CODE_ROWS` (the same table as `AsyncCode.rows`), `MANY_TASKS = 50`, `GROUP_SIZE = 100`.

Per block: `threads` 50 for `fromManyTasks`, else 1; QoS `tunables.qos`; `batch_lines` 0 for `fromManyTasks`, else `threads × (warmup + measured)`; samples: `fromManyTasks` → `ExpectedSamples("callTime", "ticks", True, 50, callsPerTask, False)`; `fromMainActor`, `toMainActor` and `callFromMainActor` → `ExpectedSamples("mainThreadCPUAtBatchStart", "microseconds", False, 1, warmup + measured, False)` and the same for `...End`; check `asyncCode.<operation>`. The expected blocks are the requested (operation, mechanism) pairs that the table allows, the same filter as in Swift (Task 6). A requested mechanism or operation that no allowed pair uses raises `ValueError` (the attempt becomes `invalid`). A block in the file that is not expected makes the attempt `invalid` through the existing pair-set rule.

- [ ] **Step 1: Write the failing tests.** A synthetic `callerPaths` attempt for the acceptance request (five mechanisms × five paths, 25 combinations) expects exactly the 14 allowed blocks and is accepted. Each mutation is rejected as `invalid`: one `callTime` line removed (49 tasks); one `callTime` line with one value too few; one `mainThreadCPUAtBatchEnd` line removed; a `batch` line added to a `fromManyTasks` block; a request whose only operation is `fromMainActor` and only mechanism is `mainActor` (no allowed pair). Synthetic `batching` and `isolationSettings` attempts are accepted.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole Python suite; `OK`.**
- [ ] **Step 5: Commit:** `git commit -m "Check async code attempts"`

---

### Task 9: Priority inversion, contended locks and trial outcome

**Files:**
- Create: `Experiments/PriorityInversion/ContendedLock.swift`, `Experiments/PriorityInversion/ContendedLocks.swift`, `Experiments/PriorityInversion/ContendedQueues.swift`, `Experiments/PriorityInversion/ContendedActor.swift`, `Experiments/PriorityInversion/TrialOutcome.swift`
- Test: `Tests/PriorityInversionTests.swift` (create)

**Interfaces:**
- Consumes: `TrialOutcome` (Task 2), `referenceLoop(iterations:)`, `Clock`, `CPU`.
- Produces:

```swift
/// The holder's work: a fixed number of reference-loop iterations and the result they must give.
struct HolderWork: Sendable {
    let iterations: Int
    let expectedResult: UInt64
    /// Runs the work and tells whether the result was right.
    func run() -> Bool
}

/// Times and CPU numbers of the holder side of one trial. Written by the holder, read by the controller.
final class HolderTimestamps: @unchecked Sendable {
    func reset()
    func markAcquired()                          // stores Clock.now() and CPU.current(), then signals
    func markReleased(resultCorrect: Bool)       // stores Clock.now() and CPU.current(), then signals
    func waitAcquired(until deadline: UInt64) -> Bool
    func waitReleased(until deadline: UInt64) -> Bool
    var acquire: UInt64 { get }
    var release: UInt64 { get }
    var cpuReadings: [Int] { get }               // at acquire, at release
    var resultCorrect: Bool { get }
}

/// What the holder and the main thread share in one trial.
protocol ContendedLock: AnyObject, Sendable {
    /// Holder side, called on the holder thread. Takes the lock, calls `markAcquired`,
    /// runs `work`, stores `trial` as the protected value, calls `markReleased`, releases.
    /// The async `.barrier` row and the actor return after submitting; their work runs later.
    func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps)

    /// Main side, called on the main thread. Takes the lock (the read side where there is one),
    /// reads the protected value and calls `done` with the acquire tick and that value.
    /// Synchronous mechanisms call `done` before returning; the actor calls it from a main-actor task.
    @MainActor
    func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void)
}

enum ContendedLocks {
    /// One new lock for the mechanism; the actor row needs the holder's QoS for its task priority.
    static func make(_ mechanism: MechanismID, holderQoS: QoS) -> any ContendedLock
}

extension TrialOutcome {
    static func classify(
        holderAcquire: UInt64,
        holderRelease: UInt64,
        mainArrival: UInt64,
        mainAcquire: UInt64,
        loadStop: UInt64
    ) -> TrialOutcome
}
```

The fourteen rows. Every row stores the protected value inside its own lock, as ordinary code does; none reuses an experiment 1 type:

| Mechanism | Holder side | Main side |
|---|---|---|
| `mutex` | `Mutex<Int>.withLock` | `withLock` |
| `osAllocatedUnfairLock` | `OSAllocatedUnfairLock<Int>.withLock` | `withLock` |
| `osAllocatedUnfairLockAdaptiveSpin` | `withLock(flags: .adaptiveSpin)` (as in `AdaptiveSpinUnfairLockProtection`) | the same |
| `osUnfairLock` | heap `os_unfair_lock`, lock and unlock | the same |
| `nsLock`, `nsRecursiveLock` | `lock()` / `unlock()` | the same |
| `pthreadMutex` | heap `pthread_mutex_t`, default attributes | the same |
| `pthreadReadWriteLock` | `pthread_rwlock_wrlock` | `pthread_rwlock_rdlock` |
| `objcSync` | `objc_sync_enter(self)` / `objc_sync_exit(self)` | the same |
| `serialQueue` | `queue.sync` | `queue.sync` |
| `barrierQueueSyncWrite` | `queue.sync(flags: .barrier)` | `queue.sync` |
| `barrierQueueAsyncWrite` | `queue.async(flags: .barrier)`; the block does the holder steps | `queue.sync` |
| `dispatchSemaphore` | `wait()` / `signal()`, initial value 1 | the same |
| `actor` | `Task.detached(priority: holderQoS.taskPriority) { await actor.hold(...) }` | `Task { @MainActor in done(await actor.touch()) }` |

The outcome rule, the same as `classify_trial` in Task 3:

```swift
extension TrialOutcome {
    /// Valid: the main thread arrived while the holder held the lock and the load ran.
    /// Censored: such an arrival, but the main thread got the lock after the load stopped.
    /// Invalid: everything else. Invalid trials are kept and counted, never used as waits.
    static func classify(
        holderAcquire: UInt64,
        holderRelease: UInt64,
        mainArrival: UInt64,
        mainAcquire: UInt64,
        loadStop: UInt64
    ) -> TrialOutcome {
        let arrivedDuringHold = holderAcquire < mainArrival && mainArrival < holderRelease
        guard arrivedDuringHold, mainArrival < loadStop else {
            return .invalid
        }
        return mainAcquire > loadStop ? .censored : .valid
    }
}
```

- [ ] **Step 1: Write the failing tests:**
  - `classifiesTrials`: the five cases of `test_trials.py`, with the same tick values.
  - `everyMechanismKeepsTheMainSideOut` (parameterized over the 14 mechanisms): a holder `BenchmarkThread` calls `hold` with work that takes about 5 ms. As soon as the acquire is marked, a second thread performs the main side through `DispatchQueue.main.async`. Expect the main side's acquire tick ≥ `timestamps.release`, the observed value equal to the trial index, and `resultCorrect`.
  - `asyncBarrierHoldReturnsBeforeTheWorkEnds`: `hold` returns before `timestamps.release` is set.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the Simulator tests; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Add the contended locks of the priority-inversion experiment"`

---

### Task 10: Priority inversion, trial runner and experiment

**Files:**
- Create: `Experiments/PriorityInversion/LoadThreads.swift`, `Experiments/PriorityInversion/TrialRunner.swift`, `Experiments/PriorityInversion/PriorityInversion.swift`, `Experiments/PriorityInversion/PriorityInversionChecks.swift`
- Modify: `Harness/Execution/Experiment.swift` (registry), `docs/data-format.md`
- Test: `Tests/PriorityInversionTests.swift`

**Interfaces:**
- Consumes: Task 2 (`runOnThreads(workerQoS:)`, `appendTrials`, `TrialLine`, `PriorityInversionTunables`), Task 9.
- Produces:

```swift
/// Threads that keep every CPU busy until a stop tick, once per trial.
final class LoadThreads: @unchecked Sendable {
    init(count: Int, qos: QoS)
    /// Releases every thread; each spins on `referenceLoop(iterations: 1_000)` until `stopTick`.
    func start(until stopTick: UInt64)
    /// Returns false when some thread is still spinning at `deadline`.
    func waitStopped(until deadline: UInt64) -> Bool
    /// Ends and joins the threads.
    func shutDown()
}

/// The holder: one thread at the block's QoS that calls `lock.hold` once per trial.
final class HolderThread: @unchecked Sendable {
    init(qos: QoS, lock: any ContendedLock, work: HolderWork, timestamps: HolderTimestamps)
    /// Wakes the thread; it calls `lock.hold(trial:work:timestamps:)` and waits again.
    func start(trial: Int)
    /// Ends and joins the thread.
    func shutDown()
}

/// What the main thread saw in one trial. Written on the main thread, read by the controller.
final class MainSideRecord: @unchecked Sendable {
    func reset()
    func store(arrival: UInt64, acquire: UInt64, cpu: Int, observed: Int)
    func signalDone()
    func waitDone(until deadline: UInt64) -> Bool
    var arrival: UInt64 { get }
    var acquire: UInt64 { get }
    var cpu: Int { get }
    var observed: Int { get }
}

struct TrialRunner {
    init(
        lock: any ContendedLock,
        holder: HolderThread,
        timestamps: HolderTimestamps,
        tunables: PriorityInversionTunables,
        loadThreads: LoadThreads,
        acquireTimeoutTicks: UInt64      // 2 s in the experiment; tests pass less
    )
    /// Runs warm-up and measured trials on the calling (controller) thread.
    /// Stops early and reports a timeout when any wait passes its deadline.
    func runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)
}

struct PriorityInversion: Experiment { }
```

One trial, as the controller runs it. This is the algorithm the design and the decisions above fix; write it in this order:

```swift
// 1. The holder takes the lock while the CPUs are free.
timestamps.reset()
mainSide.reset()
holder.start(trial: trial)                       // the holder thread calls lock.hold(...)
guard timestamps.waitAcquired(until: Clock.now() + acquireTimeoutTicks) else {
    return timedOut
}

// 2. The load starts at once and stops at a fixed tick.
let loadStart = Clock.now()
let loadStop = loadStart + loadTicks
loadThreads.start(until: loadStop)

// 3. The main thread arrives 1 ms after the holder's acquire.
let arrivalTarget = timestamps.acquire + mainDelayTicks
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        mach_wait_until(arrivalTarget)
        let mainArrival = Clock.now()
        lock.touch { mainAcquire, observedTrial in
            mainSide.store(arrival: mainArrival, acquire: mainAcquire, cpu: CPU.current(), observed: observedTrial)
            mainSide.signalDone()
        }
    }
}

// 4. Every wait has a deadline after the load stop.
let deadline = loadStop + finishAllowanceTicks       // 5 s
guard mainSide.waitDone(until: deadline),
      timestamps.waitReleased(until: deadline),
      loadThreads.waitStopped(until: deadline) else {
    return timedOut
}

// 5. Record the trial and pause.
trials.append(TrialLine(... outcome: TrialOutcome.classify(...)))
usleep(useconds_t(tunables.pauseMilliseconds * 1_000))
```

`loadTicks`, `mainDelayTicks` and `finishAllowanceTicks` are the tunables converted from milliseconds and microseconds to ticks with `Clock.timebase`, once before the first trial.

`PriorityInversion`:
- `init` rules: variant `default`; mechanisms non-empty, unique, from the fourteen of Task 9; operations non-empty, unique, from `utilityHolder` and `backgroundHolder`; `tunables.threads == 1`; `tunables.priorityInversion` present.
- Blocks: every mechanism × operation, one thread, QoS `.utility` or `.background` from the operation.
- `run(block)`, in this order:
  1. Before the block: compute `HolderWork.expectedResult` once.
  2. Create the lock (`ContendedLocks.make`), a `HolderTimestamps`, a `MainSideRecord`, `LoadThreads(count: PhoneFacts.read().cpuCount, qos: loadQoS)` and a `HolderThread` at the block's QoS.
  3. Call `block.runOnThreads(recording: .samplesOnly, workerQoS: request.tunables.qos)`. Its one worker is the controller and calls `runTrials`.
  4. Append the trial lines, then shut the threads down.
- Check `priorityInversion.<operation>`, one per block, passes when:
  - no wait timed out;
  - every trial has `holderResultCorrect`;
  - every trial has `mainObservedTrial == trial`;
  - `mainAcquire >= holderRelease` in every trial where `mainArrival < holderRelease`.
- `violations` counts the trials that break any of these. The detail gives the counts, for example `valid 8, censored 2, invalid 1`.

- [ ] **Step 1: Write the failing tests:**
  - `priorityInversionSmokeRunPasses`: mechanisms `osUnfairLock`, `dispatchSemaphore`, `barrierQueueAsyncWrite`, `actor`; operation `utilityHolder`; tunables `holderWorkIterations` 10,000, load 20 ms, delay 1,000 µs, pause 5 ms, 1 warm-up and 3 trials. Expect four blocks with four `trial` lines each, `trial` 0…3, warm-up only on trial 0, `holderQoS` `utility`, status `completed`. The test does not assert outcomes: priorities on the Simulator differ from a phone.
  - `stuckHolderTimesOutWithoutBlockingMain`: a test `ContendedLock` whose `hold` never calls `markAcquired`, `acquireTimeoutTicks` for 200 ms. `runTrials` returns `timedOut` within 1 s, and the main side was never scheduled.
  - `rejectsUnknownMechanismAndHolder`, `rejectsMissingTunables`: `init` throws.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.** Register `"priorityInversion"`. Add its section to `docs/data-format.md`: block shape, trial lines, check rules.
- [ ] **Step 4: Run the Simulator tests; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Add the priority-inversion experiment"`

---

### Task 11: Priority inversion in the attempt checker

**Files:**
- Modify: `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`
- Test: `scripts/tests/test_attempt_check.py`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: a `priorityInversion` branch: `PRIORITY_INVERSION_MECHANISMS` (the fourteen), `HOLDER_QOS = {"utilityHolder": "utility", "backgroundHolder": "background"}`. Per block: threads 1, QoS from `HOLDER_QOS`, `batch_lines` 0, no samples, `trial_lines = warmupTrials + trials`, check `priorityInversion.<operation>`.

- [ ] **Step 1: Write the failing tests.** A synthetic attempt with two mechanisms × two holders is accepted. Each mutation is rejected as `invalid`: one trial line removed; an `outcome` label that disagrees with the timestamps; `mainAcquire` before `holderRelease` with the arrival during the hold; `holderResultCorrect` false; `holderQoS` different from the block; a trial outside its block's ticks; `warmup` on the wrong trial; an unknown mechanism.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole Python suite; `OK`.**
- [ ] **Step 5: Commit:** `git commit -m "Check priority-inversion attempts"`

---

### Task 12: System Trace runs

**Files:**
- Create: `scripts/runner/trace_recorder.py`
- Modify: `scripts/runner/sessions.py`, `scripts/tests/fake_device.py`
- Test: `scripts/tests/test_sessions.py`

**Interfaces:**
- Consumes: `Plan.traced` and `PlannedRun.traced` (Task 3).
- Produces:

```python
class TraceRecorder:
    """Records a System Trace of every process on one phone around one attempt."""

    def start(self, udid: str, output: Path, time_limit_seconds: int) -> None: ...
    def stop(self) -> None: ...


def run_session(..., recorder_factory: Callable[[], TraceRecorder] = TraceRecorder) -> SessionSummary
```

`start` and `stop` in this order:

```python
def start(self, udid, output, time_limit_seconds):
    name = "dev.syncbench.trace." + secrets.token_hex(4)
    # Listen first, so the notification cannot be missed.
    self.listener = self.popen(["notifyutil", "-1", name])
    self.process = self.popen([
        "xcrun", "xctrace", "record",
        "--template", "System Trace",
        "--device", udid,
        "--all-processes",
        "--time-limit", f"{time_limit_seconds}s",
        "--output", str(output),
        "--notify-tracing-started", name,
        "--no-prompt",
    ])
    if not self.wait(self.listener, timeout_seconds=60):
        self.stop()
        raise SessionError("System Trace did not start within 60 seconds")


def stop(self):
    # SIGINT lets xctrace finish the file; kill only if it does not exit.
    send_interrupt(self.process)
    if not self.wait(self.process, timeout_seconds=300):
        self.process.kill()
    terminate_if_running(self.listener)
```

In `run_session`, only for a traced run:
1. After the request is built and before `devices.launch`, start a recorder with `output = <session>/traces/<attemptID>.trace` and `time_limit_seconds = run.time_limit_seconds + 60`. The run's own deadline starts after the recorder has started.
2. Stop it in a `finally` after the wait or the termination, before the files are copied.
3. The attempt record gets `"traced": true` and `"traceFile"`, a path relative to the session folder.

A recorder that fails to start stops the session before the app launches. Untraced runs never create a recorder.

- [ ] **Step 1: Write the failing tests** with a `FakeRecorder` in `fake_device.py`:
  - in a traced plan, the recorder starts before `launch` and stops after the exit, also when the attempt times out;
  - a recorder that raises from `start` stops the session, `launch` is never called, and `stop` was called;
  - an untraced plan creates no recorder;
  - the record carries `traced` and `traceFile`.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole Python suite; `OK`.**
- [ ] **Step 5: Commit:** `git commit -m "Record System Trace runs"`

---

### Task 13: Plans, README and design updates

**Files:**
- Create: `plans/acceptance-async-code.json`, `plans/acceptance-priority-inversion.json`, `plans/traced-async-code.json`, `plans/traced-priority-inversion.json`
- Modify: `README.md`, `docs/harness-design.md`, `docs/data-format.md`
- Test: `scripts/tests/test_plans.py`

All four plans: `"schema": 1`, `"buildTarget": "ios26"`, `"smoke": true`, `"iosBuilds": {}`, `"seed": 20261106`, `"settleSeconds": 10`, `"pauseSeconds": 2`. Every value below is a guess for acceptance; the pilot sets the real ones.

- `acceptance-async-code`: three entries, one per variant, each `repeats: 1`, `timeLimitSeconds: 300`, threads 1, QoS `userInitiated`, 1 warm-up and 2 measured batches, 4 sub-batches, `referenceLoopIterations: 1000000`.
  - `callerPaths`: all five paths; mechanisms `actor`, `mainActor`, `mutex`, `osAllocatedUnfairLock`, `nsLock`; `operationsPerBatch` `{"default": 10000, "actor": 2000, "mainActor": 400}`; `asyncCode` `{"callsPerTask": 200, "warmupCallsPerTask": 20}`.
  - `batching`: all three operations; mechanisms `actor`, `mutex`; `{"default": 10000, "actor": 2000}` (multiples of 400).
  - `isolationSettings`: `callFromMainActor`; the three mechanisms; `{"default": 400}`.
- `acceptance-priority-inversion`:
  - one entry, `variant: "default"`, `timeLimitSeconds: 900`;
  - the fourteen mechanisms × `utilityHolder`, `backgroundHolder`;
  - threads 1, QoS `userInteractive` (the controller), 0 warm-up and 1 measured batch, 1 sub-batch, `{"default": 1}`, `referenceLoopIterations: 1000000`;
  - `priorityInversion`: `holderWorkIterations: "fromCalibration"`, `loadQoS: "userInitiated"`, `loadMilliseconds: 300`, `mainDelayMicroseconds: 1000`, `pauseMilliseconds: 50`, `warmupTrials: 1`, `trials: 10`.
- `traced-async-code`: `"traced": true`; the `isolationSettings` entry only, `{"default": 200}`, 1 measured batch.
- `traced-priority-inversion`: `"traced": true`; mechanisms `osUnfairLock`, `dispatchSemaphore`; operation `utilityHolder`; 0 warm-up and 3 trials; the other values as in the acceptance plan.

`README.md`: run `calibrate` before any plan with `"fromCalibration"`; how to run the new plans; traced plans write `.trace` files under the session folder; those files hold device identifiers and are never shared.

`docs/harness-design.md`:
- In the repository tree, replace `Exp7Template/` and `Exp7Swift6/` with `IsolationProbe/`: one file compiled into the static libraries `IsolationProbeTemplate` and `IsolationProbeSwift6`. Apply the same rename in the build section.
- The 8B note: the holder takes the lock first, then the load starts, then the main thread arrives 1 ms later. Add the reason in one sentence.
- Calibration mode: the 8B work size comes from block `holderWorkSingleThread`.
- `doctor` compares the phone's build with `iosBuilds`.
- Traced runs: the script records System Trace of all processes around each attempt of a plan with `"traced": true`.

`docs/data-format.md`: read it once end to end; the sections from Tasks 2–11 must agree with the code.

- [ ] **Step 1: Write the failing test** `test_every_plan_in_plans_loads`: `load_plan` accepts every file in `plans/`.
- [ ] **Step 2: Run it; expect failure** (the new plans do not exist).
- [ ] **Step 3: Write the plans and the text changes.**
- [ ] **Step 4: Run the whole Python suite and the Simulator tests; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Add phase 2 plans and update the docs"`

---

### Task 14: Acceptance on both iPhones

**Files:**
- Create: `docs/phase-2-acceptance.md`
- Modify: `docs/build-checks/2026-11-phase-1.md` (a phase 2 section) or create `docs/build-checks/2026-11-phase-2.md`

Ivan prepares both phones (see Prerequisites). Never print the values from `local.json`. Run every step on `iphone11` and on `iphone15` unless a step says otherwise.

- [ ] **Step 1: Build.** Run `python3 scripts/bench.py build --target ios26 --phone <key>` from a clean tree. Expected: `build-info.json` shows `librarySettings` with the template settings for `IsolationProbeTemplate` and the app's settings for `IsolationProbeSwift6`.
- [ ] **Step 2: Calibrate.** Run `python3 scripts/bench.py calibrate --phone <key>`. Expected: the core map as in phase 1, and `priorityInversion.holderWorkIterations` with at least half of the samples used. Write down both numbers.
- [ ] **Step 3: Async code.** Run `python3 scripts/bench.py run --phone <key> --plan plans/acceptance-async-code.json`. Expected: three accepted attempts; the three `callFromMainActor` checks pass on the phone (template: every call on the main thread; the other two: none).
- [ ] **Step 4: Priority inversion.** Run `python3 scripts/bench.py run --phone <key> --plan plans/acceptance-priority-inversion.json`. Expected: one accepted attempt; no crash and no watchdog report.
  - Summarize each block: valid, censored and invalid counts, and the median of `mainAcquire - mainArrival` over the valid trials, in milliseconds. Use a few lines of Python in the shell; do not add a tool.
  - Stop and report when a `utilityHolder` block of `osUnfairLock` has fewer than half valid trials, or when `osUnfairLock` and `dispatchSemaphore` show no difference. Then 8B cannot answer its question, and the decision is Ivan's.
- [ ] **Step 5: Traced runs, `iphone15` only.** Run both traced plans. Expected: each attempt is accepted, and `xcrun xctrace export --input <trace> --toc` succeeds for each trace file.
- [ ] **Step 6: Regression, `iphone15` only.** Run `plans/acceptance-base-comparison.json`. Expected: four accepted attempts. Repeat the per-function `swift_beginAccess` scan recorded in the build checks; experiment 1's rows are unchanged.
- [ ] **Step 7: Build notes.** Write down, from the Release disassembly:
  - whether `Mutex.withLock` is inlined in the `fromBackgroundTask` loop;
  - whether the compiler inlined `incrementAsync()` into the `onActor` loop. If it did, that path measures no call, and the acceptance document says so.
- [ ] **Step 8: Write `docs/phase-2-acceptance.md`.** Include:
  - each phone's model and iOS build;
  - the session IDs and their results;
  - the calibrated work sizes;
  - the 8B summary table;
  - what the trace files show;
  - what plan 3 and the pilot must take into account.
- [ ] **Step 9: Commit:** `git commit -m "Record phase 2 acceptance on device"`
