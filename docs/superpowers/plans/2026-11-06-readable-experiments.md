# Readable Experiments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reader understands each of experiments 1, 7 and 8B from its own folder, the way one reads a short blog benchmark, while the measured machine code stays the same.

**Architecture:** Each experiment folder gets a one-page `README.md`, its mechanisms as small ordinary classes, and one short main file with the question, the rows and the measured operation. Request validation, check arithmetic and timing plumbing move to clearly named secondary files or to harness helpers. The generic `StateProtection` layer and the visitor are removed. A rename-proof comparison of the Release machine code, before and after, proves that the measured loops did not change; one device acceptance at the end covers this refactor and the three optimizer fixes (`18b65d8`, `1d51346`, `731bdd9`).

**Tech Stack:** Swift 6.4 (Xcode 27.1), Swift Testing on the iOS Simulator; Python 3.9+ standard library; `xcrun nm`, `swift-demangle`, `llvm-objdump`.

**Spec:** `docs/harness-design.md`, `docs/experiments.md`, `docs/data-format.md`. Code facts: `docs/build-checks/2026-11-operation-preservation.md` (the last codegen inspection and its method).

## Why

Ivan, 2026-11-06: "I cannot understand the experiment by looking at the code." The mutex increment of experiment 1 is spread over six files: `BaseComparison.swift` → `SharedIntegers.visit` → `ProtectedInteger` → `StateProtection.write(_:using:)` → `MutexProtection` → `BaseComparisonLoops`, plus `BatchTimer`. Of the 256 lines of `BaseComparison.swift`, about 135 are validation and checks and 75 are plumbing. `CallerPaths.swift` (430 lines) repeats the same timing pattern six times. The generic wrappers exist for a reuse that the project then forbade. The repository becomes public with the article, and readers must be able to see how each number was made.

## Global Constraints

- Everything in the earlier plans' Global Constraints applies: toolchain, Python 3.9, app settings, explicit isolation, timed-code rules, readable names, no personal identifiers, English text, a commit after each task, never rebase.
- **The measured machine code does not change**, except where a task names the change and the build-check note explains it. Symbol names may change; the comparison in Task 1 does not depend on them.
- **Release settings stay as they are.** No new attributes on measured code, no `@exclusivity(unchecked)`. The existing `@inline(never)` on the measured loops and on `CounterActor.incrementAsync()` stays.
- **Any helper that wraps a timed region is `@inline(__always)`** and keeps the caller's isolation (pass `isolation: isolated (any Actor)? = #isolation` through, as `BatchTimer` does).
- **No behavior change:** request format, result lines, check names, plans and the Python checker stay the same. All existing tests keep passing, except the tests of the removed generic layer, which Task 3 replaces.
- **Simplicity rules** (adapted from the `code-simplifier` agent of `claude-plugins-official`):
  - No abstraction without a second user: a protocol, generic type or helper exists only when at least two places use it now. Breaking this rule produced `StateProtection`.
  - Flat code: early returns instead of nesting; no nested ternary operators (use `switch` or `if`).
  - Clear over short: no dense one-liners; a reader understands each line without jumping to another file.
  - Comments say what is measured and why, not what an obvious line does.
  - Do not over-simplify: keep a helper when it gives a step a name the reader needs.

## Simplification pass

Tasks 3–5 end with one simplification pass over the experiment's folder, after the restructure and before the tests and the codegen comparison.
- **Tool.** Use the `code-simplifier` agent if this session has the `code-simplifier` plugin. Otherwise give a fresh subagent the agent's instructions to read directly, from `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/code-simplifier/agents/code-simplifier.md`, together with the request below. Only if that file is missing, use the built-in `/simplify` skill. The agent's JavaScript and React rules (ES modules, `function` keyword, Props types) do not apply here.
- **Request.** Give the tool this request, with the folder filled in:

```text
Simplify the Swift files in Experiments/<Folder>/ for a human reader, without
changing behavior. Follow the simplicity rules in the Global Constraints of
docs/superpowers/plans/2026-11-06-readable-experiments.md. Do not change:
- any @inline(never) or @inline(__always) attribute;
- the statements inside a mechanism's critical section, including the
  lock(); defer { unlock() } shape (do not switch between it and withLock);
- the bodies of the measured loops;
- where timestamps are read and where markAcquired / markReleased are called;
- isolation (@MainActor, isolated parameters, nonisolated, Task.detached);
- doc comments that explain the experiment or a compiler note;
- check names, request fields and result lines.
Report every change in one line.
```

- **Check.** After the pass, run the Simulator tests and the codegen comparison. Revert any change that moves a measured unit into `missing`, and give its reason in the task's report.

## Target structure

Every experiment folder has:

| File | Content | Size |
|---|---|---|
| `README.md` | The page a reader opens first (template below) | one page |
| `<Experiment>.swift` | Doc comment with the question and the rows; the switch from mechanism to concrete class; the measured operations as plain code | at most about 120 lines |
| Mechanism files | One small final class (or actor) per mechanism, written as an app writes it | 10–35 lines per class |
| `<Experiment>Request.swift` | Validation of the request (moved from `init`) | as needed |
| `<Experiment>Checks.swift` | Correctness checks and their arithmetic | as needed |
| Plumbing files | Timing calls, trial coordination, recorders; a reader may skip them | as needed |

`README.md` template, in this order and with these headings:

```markdown
# <Experiment name> (experiment <N>)

## Question
One or two sentences from docs/experiments.md.

## Rows
Which mechanisms and operations, how many threads or tasks, which variants.

## One operation
The real code of one row's operation, copied from the mechanism file, 5–10 lines.

## How it is timed
One paragraph: what the clock covers (batches of N operations, warm-up, per-call
or per-trial timing), what runs outside the timed part.

## What is checked
The correctness checks, in words.

## Read the code in this order
1. `<Experiment>.swift`
2. the mechanism files
3. the rest (validation, checks, plumbing), which you may skip.

## Compiler notes
What the Release build does that a reader would not expect (for example: the
single-thread floor uses relaxed atomics so the loop is not folded; `onActor`
uses `@inline(never)`), with a link to the build-check note.
```

The main file of experiment 1, as a reader should see it. It is a shape, not a transcript: the implementer writes the bodies.

```swift
/// Experiment 1: base comparison.
///
/// Question: what does one read, one write and one increment of a shared `Int`
/// cost with each synchronization mechanism, on one thread and with 2, 6 and 12
/// threads at once?
///
/// Each row protects one `Int` with one mechanism; the classes are in
/// LockIntegers.swift, QueueIntegers.swift, AtomicIntegers.swift and
/// ActorIntegers.swift. One operation is one call of `read()`, `write(_:)` or
/// `increment()`. The harness times the loops below in batches (README.md).
struct BaseComparison: Experiment {
    let blocks: [BlockDescription]

    init(request: RunRequest) throws(RequestError) {
        blocks = try BaseComparisonRequest.blocks(for: request)
    }

    func run(_ block: BlockContext) -> [CheckResult] {
        let operation = Operation(block)
        let initialValue = operation == .read ? Self.valueForReads : 0

        switch MechanismID(block) {
        case .unsynchronized:
            return measure(UnsynchronizedInteger(initialValue), operation, block)
        case .mutex:
            return measure(MutexInteger(initialValue), operation, block)
        // ... one line per mechanism ...
        case .actor:
            return measureAsync(ActorInteger(initialValue), operation, block)
        case .mainActor:
            return measureAsync(MainActorInteger.makeOnMainThread(initialValue), operation, block)
        }
    }
}

// The measured code: one call of the mechanism per loop iteration.
extension BaseComparison {
    @inline(never)
    static func incrementLoop(_ integer: some SharedInteger, count: Int) {
        for _ in 0..<count {
            integer.increment()
        }
    }

    // readLoop, writeLoop and the three async loops, written the same way.
}
```

## Decisions this plan makes (agent's calls, open to correction)

- Each mechanism of experiment 1 becomes a concrete class with `State == Int` (`MutexInteger`, `NSLockInteger`, …). Its statements keep today's shape (`lock()`; `defer { unlock() }`; the access), so the compiler produces the same loops. The concrete queue classes in `QueueIntegers/` already follow this rule.
- The visitor (`SharedIntegerVisitor`, `SharedIntegers.visit`) becomes the `switch` in `BaseComparison.run`; a generic call with a concrete type specializes the same way.
- `MechanismID.swift` moves to `Harness/Execution/` without the test-only `stateProtections` list; the `Mechanisms/` folder is removed.
- In 8B the steps of one trial (holder takes the lock, load starts, main thread arrives 1 ms later, waits, record) are visible in `PriorityInversion.swift`; the coordination types live in `TrialSupport.swift`.
- The codegen comparison becomes a committed script, so readers and plan 3 can repeat it.

## Review Focus

1. **A helper adds a call or a hop inside a timed region**, because it is not inlined or it drops the caller's isolation. Expected: the comparison reports the changed loop. Every task runs it.
2. **Concrete lock classes change the generated code.** The change can be an access check that appears or disappears, or a different merging of identical bodies. Expected: the comparison reports it, and the task records the change, or reshapes the class until the loop matches.
3. **The main-actor counter is created off the main thread** after the visitor goes away. Expected: it is still created with `DispatchQueue.main.sync { MainActor.assumeIsolated { … } }` from the run thread; the experiment 1 smoke test covers the `mainActor` rows.
4. **Tests disappear with the generic layer.** Expected: Task 3 names each removed test and what replaces it. The exact concurrent-increment test for every mechanism stays.
5. **8B instrumentation leaves the critical section.** Expected: `markAcquired`, `markReleased` and the acquire tick stay inside each class's critical section, and `touch` stays `@MainActor`; the 8B smoke test and the comparison cover it.

## Prerequisites

- The working tree is clean at the commit after `cfcddf8` (the optimizer fixes and their build check). If a device re-acceptance of those fixes is still running, let it finish; Task 6 repeats it anyway.

---

### Task 1: Rename-proof codegen comparison

**Files:**
- Create: `scripts/codegen_compare.py`, `scripts/tests/test_codegen_compare.py`, `scripts/tests/fixtures/codegen/` (small text fixtures)
- Modify: `README.md` (one paragraph: how to run it)

**Interfaces:**
- Produces:

```python
def measured_units(disassembly: str, indirect_symbols: str, demangled: Dict[str, str],
                   name_filters: Sequence[str]) -> Dict[str, List[str]]
# normalized unit hash -> names of the functions that contain it

def compare(baseline: Dict[str, List[str]], candidate: Dict[str, List[str]]) -> CodegenReport
# CodegenReport(missing: Dict[hash, names], added: Dict[hash, names], kept: int)
```

Command line: `python3 scripts/codegen_compare.py BASELINE_EXECUTABLE CANDIDATE_EXECUTABLE --report OUT.json`. It runs `xcrun nm`, `xcrun swift-demangle`, `xcrun llvm-objdump --macho --mattr=+lse,+rcpc --no-show-raw-insn --disassemble` and `--indirect-symbols` on each executable, as `docs/build-checks/2026-11-operation-preservation.md` describes. It exits 1 when `missing` is not empty.

How units are built, so that renames do not matter:
1. Split the disassembly into functions by symbol, and keep the functions whose demangled name contains one of the filters. The default filters are `BaseComparison`, `SharedInteger`, `Integer`, `Protection`, `AsyncCode`, `CallerPaths`, `Batching`, `IsolationSettings`, `Counter`, `IsolationProbe`, `Contended`, `Holder`, `Trial`, `LoadThreads`, `referenceLoop`, `BatchTimer`.
2. Normalize each instruction:
   - drop addresses;
   - write branch targets as offsets from the function start;
   - write a call into a stub as `IMPORT:<symbol>`, resolved through the indirect symbols;
   - write a call into another local function as `LOCAL`;
   - write literal-pool and page addresses as `ADDR`.
3. A unit is every loop region (from the target of a backward branch to that branch) and, for a function without a backward branch, its whole body. Async loops have no backward branch: their resume functions continue through `swift_task_switch`. Hash each unit's normalized instruction lines.
4. `missing` lists the baseline units that do not occur in the candidate. `added` lists the candidate units that do not occur in the baseline; it is for information only.

- [ ] **Step 1: Write the failing tests** with fixtures of a few functions each:
  - `test_renamed_function_with_same_loop_is_kept`: the same loop body under another symbol name → `missing` is empty.
  - `test_extra_call_in_loop_is_missing`: the candidate loop has one more `bl` to the `_swift_beginAccess` stub → the baseline unit is in `missing`, with the baseline function's name.
  - `test_stub_calls_resolve_through_indirect_symbols`: a `bl` to a stub address normalizes to `IMPORT:_os_unfair_lock_lock`.
  - `test_resume_function_without_loop_is_one_unit`: a function that ends in `b <swift_task_switch stub>` and has no backward branch produces one unit.
- [ ] **Step 2: Run them; expect failures.** `python3 -m unittest discover -s scripts/tests -t scripts -p 'test_codegen_compare.py' -v`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Check it on real binaries.** Build unsigned Release for iOS 26 and iOS 18 at the current HEAD twice, into two derived-data folders, and compare each pair. Expected: `missing` is empty and exit 0. Keep both HEAD builds as the baselines for later tasks under ignored `build/private/readable-experiments/baseline-ios26` and `…-ios18`.

```bash
xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench -configuration Release \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=26.0 -derivedDataPath build/private/readable-experiments/baseline-ios26 -quiet
```

- [ ] **Step 5: Run the whole Python suite; `OK`.** Commit: `git commit -m "Add a rename-proof codegen comparison"`

---

### Task 2: Harness helpers for repeated plumbing

**Files:**
- Create: `Harness/Timing/BlockTiming.swift`, `Harness/Execution/RequestValidation.swift`
- Move without change: `MainThreadCPURecorder` and `CallTimes` from `Experiments/AsyncCode/CallerPaths.swift` to `Harness/Timing/MainThreadCPURecorder.swift` and `Harness/Timing/CallTimes.swift`; `Mechanisms/MechanismID.swift` to `Harness/Execution/MechanismID.swift` (delete `stateProtections` and the one test that uses it, which Task 3 replaces)
- Modify: `project.yml` only if a source folder disappears

**Interfaces:**
- Produces (names are the plan's choice; signatures may adapt to the code, but every helper that contains a timed region must be `@inline(__always)`):

```swift
extension BlockContext {
    /// Runs the block on its threads and times `operations` in batches.
    @inline(__always)
    func timeBatchesOnThreads(
        recordExecutorCPU: (CPUReadingSlot) -> Void = { _ in },
        waitForPendingWrites: () -> Void = {},
        _ operations: (_ thread: Int, _ batch: Int, _ subBatch: Int, _ count: Int) -> Int
    ) -> [ThreadLog]

    /// Runs one detached task per worker and times `operations` in batches.
    /// Task 0 reads `finalValue` after every worker has finished.
    @inline(__always)
    func timeBatchesInTasks(
        recordExecutorCPU: @escaping @Sendable (CPUReadingSlot) async -> Void,
        recordBatchEdge: @escaping @Sendable (_ batch: Int, _ edge: BatchEdge) -> Void = { _, _ in },
        operations: @escaping @Sendable (_ thread: Int, _ batch: Int, _ subBatch: Int, _ count: Int) async -> Int,
        finalValue: @escaping @Sendable () async -> Int
    ) -> (logs: [ThreadLog], finalValue: Int)
}

extension BatchLayout {
    var operationsPerWorker: Int { get }          // totalBatches × operationsPerBatch
}

extension Array where Element == ThreadLog {
    func checkValues(batches: Int) -> [[Int]]
}

extension RunRequest {
    /// Throws when the list is empty, has duplicates, or has a value outside `allowed`.
    func requireUniqueSelection(mechanisms allowed: Set<String>?, operations allowedOperations: Set<String>?) throws(RequestError)
    func validatedLayout(operationsPerBatch: Int, threads: Int) throws(RequestError) -> BatchLayout
}
```

The async helper must keep today's order: barrier, timed batches, a final barrier, then task 0 reads the final value. Experiment 7's paths that run on an actor or on the main actor keep calling `BatchTimer` from inside that isolation. Task 4 adds the helper they need there.

- [ ] **Step 1: Write the failing tests** in `Tests/ThreadTests.swift`: `timeBatchesOnThreadsRecordsEveryBatch` (2 threads, 1 warm-up and 2 measured batches → 6 logs entries with start < end), `timeBatchesInTasksReturnsTheFinalValue` (2 tasks increment a `Mutex<Int>` 3 × 4 times → final value 24), and `requireUniqueSelectionRejectsDuplicates`.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement the helpers and the moves. Do not use them in experiments yet.**
- [ ] **Step 4: Run the Simulator tests (all pass) and the comparison against the Task 1 baselines (`missing` empty for iOS 26 and iOS 18).**
- [ ] **Step 5: Commit:** `git commit -m "Add harness helpers for experiment plumbing"`

---

### Task 3: Experiment 1, readable

**Files:**
- Create in `Experiments/BaseComparison/`: `README.md`, `BaseComparisonRequest.swift`, `BaseComparisonTiming.swift` (`measure` and `measureAsync`), `SharedInteger.swift` (the two protocols, harness hooks with default empty implementations), `LockIntegers.swift`, `QueueIntegers.swift` (the three files of `QueueIntegers/` in one), `AtomicIntegers.swift`, `ActorIntegers.swift`, `UnsynchronizedInteger.swift`
- Modify: `BaseComparison.swift` (the shape above), `BaseComparisonChecks.swift` (gets the check assembly)
- Delete: `Experiments/BaseComparison/BaseComparisonLoops.swift` (its loops move into `BaseComparison.swift`), `Experiments/BaseComparison/QueueIntegers/`, `Mechanisms/` (StateProtection, Locks, Queues, Integers)
- Test: `Tests/BaseComparisonTests.swift`, `Tests/SharedIntegerTests.swift`, `Tests/StateProtectionTests.swift`, `Tests/TestSupport.swift`

**Interfaces:**
- Consumes: Task 2 helpers.
- Produces:
  - `BaseComparisonRequest.blocks(for request: RunRequest) throws(RequestError) -> [BlockDescription]`
  - in `BaseComparisonTiming.swift`: `func measure(_ integer: some SharedInteger, _ operation: BaseComparison.Operation, _ block: BlockContext) -> [CheckResult]` and `func measureAsync(_ integer: some AsyncSharedInteger, _ operation: BaseComparison.Operation, _ block: BlockContext) -> [CheckResult]`
  - `MainActorInteger.makeOnMainThread(_ initialValue: Int) -> MainActorInteger`: called on the run thread; creates the counter with `DispatchQueue.main.sync { MainActor.assumeIsolated { … } }`
  - the concrete classes `MutexInteger`, `AllocatedUnfairLockInteger`, `AdaptiveSpinUnfairLockInteger`, `UnfairLockInteger`, `NSLockInteger`, `NSRecursiveLockInteger`, `PthreadMutexInteger`, `PthreadReadWriteLockInteger`, `DispatchSemaphoreInteger`, `ObjcSyncInteger` (all `final class …: SharedInteger`), plus the queue, atomic, actor and floor types under their current names. `PthreadReadWriteLockInteger.read()` uses the read lock.

The lock classes keep the statements of today's protections specialized to `Int`. For example:

```swift
/// `NSLock` next to the protected value, as app code writes it.
final class NSLockInteger: SharedInteger, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ initialValue: Int) {
        value = initialValue
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
```

Tests:
- `SharedIntegerTests`: the exact concurrent-increment test for every synchronized mechanism stays, rewritten against the new switch (a test-only factory from `MechanismID` to the class is fine).
- `StateProtectionTests`:
  - `asyncBarrierKeepsOrder` stays.
  - `synchronousWriteFinishesBeforeReturning` and `readersOverlap` tested the removed generic contract; delete them.
  - `asyncBarrierWriteReturnsWhileReaderHoldsAccess` becomes a test of `BarrierQueueAsyncWriteInteger`: `increment()` returns while a test block occupies the queue. Use a test hook in the class if needed.
- `TestSupport.makeIntegerProtection` goes away.

- [ ] **Step 1: Update the tests first** as listed. Run them; they fail to compile against the old layout.
- [ ] **Step 2: Restructure.** `BaseComparison.swift` stays within about 120 lines and contains no validation, check arithmetic or `BatchTimer` call. Write `README.md` from the template; under "One operation" show `MutexInteger.increment()`.
- [ ] **Step 3: Simplification pass** over `Experiments/BaseComparison/` (see "Simplification pass").
- [ ] **Step 4: Run the Simulator tests; all pass**, including the golden fixture and the smoke run of all 20 mechanisms.
- [ ] **Step 5: Compare against the Task 1 baselines for iOS 26 and iOS 18.** Expected: `missing` is empty. If a lock loop differs (an access check, a different merge of identical bodies), first try to restore the old statement shape. If the difference stays, record it in Task 6's build-check note with the reason.
- [ ] **Step 6: Commit:** `git commit -m "Make the base comparison readable"`

---

### Task 4: Experiment 7, readable

**Files:**
- Create in `Experiments/AsyncCode/`: `README.md`, `AsyncCodeRequest.swift`
- Modify: `AsyncCode.swift` (doc comment with the 7A, 7B and 7C questions, the rows table, one switch from operation and mechanism to a path function; at most about 120 lines), `CallerPaths.swift` (one short function per path and mechanism group), `Batching.swift`, `IsolationSettings.swift`, `AsyncCodeChecks.swift`
**Interfaces:**
- Consumes: Task 2 (`timeBatchesInTasks`, `MainThreadCPURecorder`, `CallTimes`, the request helpers).
- Produces: no new public names; `AsyncCode.rows`, `manyTasks` and `groupSize` keep their names.

The paths that run in a detached task (`fromBackgroundTask`, `toMainActor` and the 7B rows) use `timeBatchesInTasks` from Task 2. Each path function shows its loop as plain code. For example:

```swift
/// Path 2: a background task calls an idle actor, one await per operation.
static func fromBackgroundTask(_ counter: CounterActor, in block: BlockContext) -> Int {
    block.timeBatchesInTasks(
        recordExecutorCPU: { slot in
            slot.store(await counter.executorCPU())
        },
        operations: { _, _, _, count in
            for _ in 0..<count {
                await counter.increment()
            }
            return 0
        },
        finalValue: {
            await counter.finalValue()
        }
    ).finalValue
}
```

The paths that run on an actor or on the main actor (`onActor`, `fromMainActor` and the 7C rows) keep calling `BatchTimer` from inside that isolation. If the same lines still repeat there, add one `@inline(__always)` helper next to them in `CallerPaths.swift` that takes `isolation: isolated (any Actor)? = #isolation`.

The two `fromManyTasks` variants keep their two `Clock.now()` reads around exactly one call; the lock variant stays synchronous between them. The `@MainActor` functions and `CounterActor.runBatchesOnActor` keep calling the timing code from inside their isolation.

- [ ] **Step 1: Restructure.** `CallerPaths.swift` should shrink well below its 430 lines. Write `README.md`; under "One operation" show path 2 and path 4, and under "Compiler notes" the `@inline(never)` of `onActor` and why.
- [ ] **Step 2: Simplification pass** over `Experiments/AsyncCode/` (see "Simplification pass").
- [ ] **Step 3: Run the Simulator tests; all pass** (they reach the code through `AsyncCode(request:)` and `RunController`).
- [ ] **Step 4: Compare against the baselines.** Expected: `missing` is empty. A path whose timed region changed goes back to the explicit form; readability does not beat measurement.
- [ ] **Step 5: Commit:** `git commit -m "Make the async code experiment readable"`

---

### Task 5: Experiment 8B, readable

**Files:**
- Create in `Experiments/PriorityInversion/`: `README.md`, `PriorityInversionRequest.swift`, `TrialSupport.swift` (`HolderWork`, `HolderTimestamps`, `MainSideRecord`, `HolderThread`, `LoadThreads`, `TrialDeadline`, and the trial loop with its bookkeeping, moved from `ContendedLock.swift`, `LoadThreads.swift` and `TrialRunner.swift`)
- Modify: `PriorityInversion.swift` (doc comment with the question, the 14 mechanisms × 2 holder QoS and what one trial does; the `ContendedLock` protocol; the switch from mechanism to class; `runOneTrial` with the five steps as plain code), `PriorityInversionChecks.swift` (also holds `TrialOutcome`)
- Delete: `ContendedLock.swift`, `LoadThreads.swift`, `TrialRunner.swift`, `TrialOutcome.swift` after the moves
- Test: `Tests/PriorityInversionTests.swift` (type locations only)

**Interfaces:**
- Produces:

```swift
extension PriorityInversion {
    /// One trial: the holder takes the lock, the load starts, the main thread
    /// arrives 1 ms after the holder's acquire and waits; returns nil on a timeout.
    static func runOneTrial(_ trial: Int, warmup: Bool, setup: TrialSetup) -> TrialLine?
}
```

`TrialSetup` (in `TrialSupport.swift`) holds what the steps use: the lock, the holder thread, the timestamps, the main-side record, the load threads, and the tunables converted to ticks. The trial loop in `TrialSupport.swift` calls `runOneTrial` for warm-up and measured trials, as `TrialRunner.runTrials` does today.

- [ ] **Step 1: Restructure.** The five steps in `runOneTrial` read like the listing in the phase 2 plan, Task 10. Write `README.md`; under "One operation" show the `os_unfair_lock` row's `hold` and `touch`, and under "How it is timed" one trial.
- [ ] **Step 2: Simplification pass** over `Experiments/PriorityInversion/` (see "Simplification pass").
- [ ] **Step 3: Run the Simulator tests; all pass**, including the stuck-holder test.
- [ ] **Step 4: Compare against the baselines.** Expected: `missing` is empty for every `hold` and `touch`.
- [ ] **Step 5: Commit:** `git commit -m "Make the priority-inversion experiment readable"`

---

### Task 6: Docs, codegen record and acceptance on both iPhones

**Files:**
- Create: `docs/build-checks/2026-11-readable-experiments.md`
- Modify: `docs/harness-design.md` (the repository tree and one rule: every experiment folder follows the target structure of this plan), `README.md` (point readers to the experiment READMEs), `scripts/runner/expected_attempt.py` (comments that name moved Swift types), `docs/phase-2-acceptance.md` (a new section)

- [ ] **Step 1: Final comparison.** Run `scripts/codegen_compare.py` on the Task 1 baselines against a clean HEAD, for iOS 26 and iOS 18. Write `docs/build-checks/2026-11-readable-experiments.md`: the command, kept and missing unit counts, and every recorded difference with its reason. Expected: no missing unit without a recorded reason.
- [ ] **Step 2: Read each README as a reader.** Each answers its seven headings. Each "One operation" snippet is the real code. Each main file fits on one screen.
- [ ] **Step 3: Device acceptance on both phones** from a clean build. This also covers the three optimizer fixes.
  - `iphone11` and `iphone15`: `acceptance-base-comparison` (iOS 26 build), `acceptance-base-comparison-ios18` (iOS 18 build), `acceptance-async-code`, `acceptance-priority-inversion`.
  - Expected: every completed attempt is accepted.
  - Record the session IDs and results in `docs/phase-2-acceptance.md` under "Readable experiments and optimizer fixes (2026-11-06)".
- [ ] **Step 4: Run the whole Python suite and the Simulator tests; all pass.**
- [ ] **Step 5: Commit:** `git commit -m "Record readable-experiment checks and acceptance"`
