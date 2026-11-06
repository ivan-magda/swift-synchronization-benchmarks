# Remaining Experiments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The harness runs all seven approved experiments: this plan adds experiments 2 (`requestRegistry`), 3 (`hotFlag`), 4 (`transactionalStore`), 8A (`mainThreadCache`) and 9 (`creationCost`), plus the display-rate calibration, and ends with one device acceptance on both iPhones.

**Architecture:** Each new experiment is a folder in the readable structure of experiments 1, 7 and 8B: a one-page `README.md`, small ordinary mechanism classes that the experiment owns, a short main file with the question, the rows and the measured operation, and separate request validation and checks. Measured loops call `BatchTimer` or `Clock.now()` directly. The Python checker learns each experiment's expected lines. A row dump of the Release machine code shows that every row keeps its per-operation work, and a comparison against `af0e45e` shows that experiments 1, 7 and 8B keep theirs.

**Tech Stack:** Swift 6.4 (Xcode 27.1), UIKit, Swift Testing on the iOS Simulator; Python 3.9+ standard library; `xcrun nm`, `swift-demangle`, `llvm-objdump`.

**Spec:** `docs/experiments.md` (experiments 2, 3, 4, 8A, 9), `docs/harness-design.md`, `docs/data-format.md`. Patterns to copy: `Experiments/BaseComparison/` (rows, explicit `BatchTimer`), `Experiments/PriorityInversion/` (main thread with deadlines), `Experiments/AsyncCode/CallerPaths.swift` (`samples` lines). Codegen method: `docs/build-checks/2026-11-readable-experiments.md`.

## Global Constraints

- Everything in the earlier plans' Global Constraints applies: frozen toolchain, Python 3.9 standard library, app build settings, explicit isolation, the timed-code rules of `docs/harness-design.md`, readable names (experiment numbers only in docs), no personal identifiers and no absolute local paths in committed files, English text, a commit after each task, never rebase, no `Co-Authored-By` line.
- **Readable structure and simplicity rules:** as in `docs/superpowers/plans/2026-11-06-readable-experiments.md` ("Global Constraints", "Target structure"). The main file has about 120 lines; the README answers the seven template headings.
- **Release settings stay.** No `@exclusivity(unchecked)`. Measured loops get `@inline(never)` (as in experiment 1) so they stay identifiable in the disassembly; no other new attributes on measured code.
- **Each experiment owns its mechanism classes.** Never reuse another experiment's classes, and never share a generic wrapper across state types (`docs/harness-design.md`, "The app").
- **No new harness timing helpers.** Experiments call `BatchTimer.timeBatches(…)` or `Clock.now()` themselves; callback helpers changed measured code before.
- **Every measured result has a consumer.** A read value goes into the batch check value or a check; work outside a lock returns a value that reaches the check value. The compiler must not be able to drop or hoist the work.
- **The main thread never waits without a limit, and the run thread waits for main-thread work only with a deadline** (`waitForMainThreadWork`, Task 2). A missed deadline fails the block's check. A main thread that never recovers ends the attempt through the runner's time limit or a crash report, which the runner keeps; the app adds no separate recovery path.
- **Experiments 1, 7 and 8B keep their machine code:** `scripts/codegen_compare.py` against the Task 1 baseline reports no missing unit, or the task records the reason.
- Spec values: request registry 4 or 8 threads, 50/50 add and remove; hot flag write about every 10 ms, groups of 100 reads; store 10,000 records, 2% writes, transaction sizes 1 and 20, 6 threads; image cache 2–4 writer threads, about 95/5 reads to writes; creation cost 10,000 and 100,000 objects.
- The iOS 18 build adds only hot-flag rows `mutex`, `atomic`, `atomicRelaxed`, `managedAtomic`, `managedAtomicRelaxed`.

## Simplification pass

Tasks 3–7 end with the simplification pass described in the readable-experiments plan (section "Simplification pass": tool choice, request text, check), applied to the new folder. Add one line to the request: "Do not remove a value that a measured loop returns or records."

## Decisions this plan makes (agent's calls, open to correction)

- **Hot flag:** both atomic orderings get a row, as in experiment 1. Cost per read comes from `read` blocks with no clock inside the batch; slow groups come from separate `readGroups` blocks that time every group of 100 reads, because a clock read every 100 reads would add about 0.2 ns per read on the iPhone 11 Pro Max.
- **Request registry:** each thread keeps a fixed number of downloads in flight and alternates "remove the oldest" and "add a new one", so adds and removes are exactly 50/50 and the dictionary has `threads × inFlightPerThread` entries. Thread 0 runs cancel-all every `cancelAllEvery` operations. The sampled time is the whole call (waiting plus the short dictionary update); no timestamp goes inside the critical section.
- **Transactional store:** each thread's operation list is made before timing from the seed. Writes sit between read runs, so a timed run of 100 one-record reads contains no write. A write's time ends at the last statement of its critical section, for every mechanism, so `sync` and async `.barrier` writes are measured the same way. `writeTime` also serves as the spec's writer wait: the write itself updates 1 or 20 records, tens of nanoseconds, so the time is almost all waiting.
- **Creation cost:** the malloc readings travel as block-level `samples` lines, not as a new `memory` line type; the design and data-format docs change accordingly. Creation and destruction are separate operations (`create`, `destroy`), each with ordinary batch lines. Rows that create the same object as another row are left out: the adaptive-spin row (same `OSAllocatedUnfairLock`), the async `.barrier` row (same queue) and the relaxed atomic rows. `objc_sync` is out by the spec.
- **Image cache (Ivan, 2026-11-06):** the main thread reads the cache where apps do, in `cellForItemAt`, while a display link scrolls a 4-column grid at a fixed speed in points per second. The number of reads follows the scrolling instead of a fixed count per frame, so collisions with writers are as frequent as in a real list. Keys are URL strings. In the main-actor row the writers are tasks that `await` the store.
- **Display rate:** calibration records 200 display-link callbacks; the runner saves their median interval in `calibration.json` under `display`. Nothing injects it into requests; the analysis reads it.

## Review Focus

1. **The optimizer drops or hoists measured work in a new row:** a flag read moved out of the loop, a transaction read whose result is unused, work outside the lock deleted, an object kept on the stack. Expected: the row dump shows the per-operation calls and loads; experiment 9 also checks at run time that every created object is a heap block. Each experiment task has a codegen step.
2. **New code changes the machine code of experiments 1, 7 or 8B,** for example when the compiler merges a new identical loop with an old one. Expected: the comparison against `af0e45e` reports it; the task reshapes the new code or records the reason.
3. **An async `.barrier` write is still queued when a batch or a check ends** (hot flag, store, image cache). Expected: batches wait for pending writes like experiment 1, and the final check waits too. Each experiment's smoke test includes `barrierQueueAsyncWrite` and checks the final state.
4. **A main-thread step stalls** (display link, main-thread writer, main-actor creation). Expected: the owner's wait has a deadline and the check fails with a timeout detail. Task 2 tests the timeout path.
5. **Tunables whose counts do not divide** (sample interval, groups of 100, the 2% writes) or sample buffers that would grow inside timed code. Expected: request validation rejects them with the field name; all buffers are allocated before the block starts. Each experiment task tests one such request.

## Prerequisites

- Clean working tree at `af0e45e` or later. No phone is needed until Task 8.

---

### Task 1: Row dump and the codegen baseline

**Files:**
- Modify: `scripts/codegen_compare.py`, `scripts/tests/test_codegen_compare.py`, `README.md` (one sentence on `--dump`)

**Interfaces:**
- Produces: `python3 scripts/codegen_compare.py --dump EXECUTABLE` prints, for each selected unit, its function names, then its normalized instructions (the text the hash uses, with `IMPORT:<symbol>` for calls), except that a call to a local function shows its demangled name (`LOCAL:<name>`) instead of `LOCAL`. Hashes stay as they are. `DEFAULT_FILTERS` adds `RequestRegistry`, `Registry`, `HotFlag`, `Flag`, `TransactionalStore`, `Store`, `MainThreadCache`, `ImageCache`, `CreationCost`, `Object`. Later tasks name their classes so these substrings select them.
- Produces: baselines `build/private/remaining-experiments/baseline-ios26` and `-ios18` (ignored), unsigned Release builds of `af0e45e`.

- [ ] **Step 1: Test** `test_dump_lists_imports_of_each_loop`: on the existing fixture, the dump contains the fixture's function name, a line with `IMPORT:` for each imported call in its loop, and `LOCAL:<name>` for a call to a local function. `test_default_filters_select_new_experiments`: each new filter string is in `DEFAULT_FILTERS`. Run; both fail.
- [ ] **Step 2: Implement** `--dump` (mutually exclusive with the two-executable form; exit 2 when no unit is selected) and the filters. Run the Python suite; all pass.
- [ ] **Step 3: Build the baselines** at `af0e45e` with the commands in `docs/build-checks/2026-11-readable-experiments.md` ("Build and comparison commands"), into the paths above. Run the comparison of each baseline against itself: `missing` is empty.
- [ ] **Step 4: Commit:** `git commit -m "Add a per-row machine code dump"`

### Task 2: Display-rate calibration

**Files:**
- Create: `Harness/Display/DisplayLinkLoop.swift`, `Harness/Threading/MainThreadWork.swift`
- Modify: `Harness/Timing/Calibration.swift`, `scripts/runner/expected_attempt.py` (`_CALIBRATION_BLOCKS`), `scripts/runner/calibration.py`, `scripts/bench.py` (calibrate writes `display`), `scripts/tests/synthetic_attempts.py`, `docs/data-format.md` ("Calibration work and checks")
- Test: `Tests/CalibrationTests.swift`, `Tests/DisplayLinkLoopTests.swift`, `scripts/tests/test_calibration.py`, `scripts/tests/test_sessions.py`

**Interfaces:**
- Produces: `@MainActor final class DisplayLinkLoop` with `init(frames: Int, onFrame: @escaping @MainActor (_ frame: Int, _ link: CADisplayLink) -> Void)`, `func start(finished: @escaping @Sendable () -> Void)` and `func stop()`. It asks for the screen's maximum frame rate (`preferredFrameRateRange`), calls `onFrame` for frames `0..<frames`, then invalidates the link and calls `finished`. Two users: calibration and Task 7.
- Produces: `func waitForMainThreadWork(until deadline: UInt64, _ start: @escaping @MainActor (_ done: @escaping @Sendable () -> Void) -> Void) -> Bool` in `MainThreadWork.swift`: called on the run thread, it starts the work with `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` and returns `false` when `done` is not called before the tick deadline. Users: calibration and Tasks 3, 6, 7.
- Produces: calibration block `displayFrames`: 1 thread, QoS `userInteractive`, one samples line for thread 0 (like the other calibration blocks), metric `displayFrame`, unit `ticks`, `repeats` values (`Clock.now()` at each callback), no CPU readings, check `calibration.samples`. Deadline: `repeats × 50 ms + 5 s`.
- Produces: `derive_display(calibration_file: Path) -> Dict` returning `medianFrameTicks`, `medianFrameMilliseconds` (rounded to 2 places) and `framesMeasured`; `bench.py calibrate` stores it as `display`. `load_phone_calibration` still accepts files without `display`.

- [ ] **Step 1: Tests.** Swift: `displayLinkLoopCallsEachFrameOnce` (frames 5 → frame indices `[0,1,2,3,4]`, `finished` called once); `waitForMainThreadWorkTimesOut` (work that never calls `done`, deadline 50 ms → returns `false` within 1 s); the calibration smoke run has 6 blocks, and `displayFrames` has one samples line with `repeats` values. Python: `derive_display` on synthetic ticks spaced by 200,000 ticks (8.33 ms at 125/3 ns) returns `medianFrameTicks == 200000` and `medianFrameMilliseconds == 8.33`; the calibrate CLI test expects the `display` key; an old `calibration.json` without `display` still resolves `holderWorkIterations`. Run; they fail.
- [ ] **Step 2: Implement.** Run the Simulator and Python suites; all pass.
- [ ] **Step 3: Commit:** `git commit -m "Calibrate the achieved display rate"`

### Task 3: Hot flag (experiment 3)

**Files:**
- Create in `Experiments/HotFlag/`: `README.md`, `HotFlag.swift`, `LockFlags.swift`, `QueueFlags.swift`, `AtomicFlags.swift`, `HotFlagRequest.swift`, `HotFlagChecks.swift`, `MainThreadWriter.swift`
- Modify: `Harness/Execution/Experiment.swift` (registry), `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`, `docs/data-format.md` (new section), `Tests/TestSupport.swift` (move `runAsyncCodeAttempt` here as `runAttempt`; now five experiments use it)
- Create plans: `plans/acceptance-hot-flag.json`, `plans/acceptance-hot-flag-ios18.json`
- Test: `Tests/HotFlagTests.swift`, `scripts/tests/test_expected_attempt.py`, `scripts/tests/test_attempt_check.py`, `scripts/tests/test_plans.py`

**Interfaces:**
- Produces: `protocol SharedFlag: AnyObject, Sendable { func read() -> Bool; func write(_ value: Bool); func waitForPendingWrites() }` (the last is empty except for the async `.barrier` row).
- Rows (17): `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock` (read lock for reads), `serialQueue`, `barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore`, `objcSync`, `atomic` and `managedAtomic` (`.acquiring` reads, `.releasing` writes), `atomicRelaxed` and `managedAtomicRelaxed` (`.relaxed`). Classes: `MutexFlag`, `AllocatedUnfairLockFlag`, …, `RelaxedManagedAtomicFlag`.
- Operations: `read` (batches, no clock inside) and `readGroups` (each group of 100 reads timed with `Clock.now()`; measured batches only; one samples line on thread 0, metric `readGroupTime`, unit `ticks`, `measuredBatches × operationsPerBatch / 100` values). Variant `default`, 1 reader thread at `tunables.qos`.
- `@inline(never) static func readLoop(_ flag: some SharedFlag, count: Int) -> Int` returns the number of `true` reads; the batch check value gets it.
- Writer: `MainThreadWriter` toggles the flag on the main thread with a `DispatchSourceTimer` (first write at once, then every 10 ms, leeway 0) while the block runs; it counts writes and keeps the last value.
- Check `hotFlag.<operation>` per block: after the reader's batches, stop the writer through `waitForMainThreadWork` (deadline 1 s), wait for pending writes, then one more read on the reader thread must equal the last written value; at least one write happened. Detail: `writes 12; last true, read true`.
- Validation: `operationsPerBatch / subBatches` is a multiple of 100 for `readGroups`.

- [ ] **Step 1: Tests.** `hotFlagSmokeRunPasses`: all 17 rows × both operations at `operationsPerBatch` 1,000, `subBatches` 2 → status `completed`, 34 blocks, every check passed, each `readGroups` block has one samples line with `measuredBatches × 10` values. `hotFlagRejectsGroupsThatDoNotDivide` (`operationsPerBatch` 150 with `readGroups` → error names `operationsPerBatch`). Python: expected blocks and a synthetic attempt accepted; the same attempt without its samples line rejected; both plans load. Run; they fail.
- [ ] **Step 2: Implement** the folder, the registry case, the Python expectation and the two plans (guess tunables: `operationsPerBatch` 1,000,000, 1 warm-up and 3 measured batches, `subBatches` 4, `qos` `userInitiated`). README "One operation": `MutexFlag.read()`. Compiler notes: the flag read stays inside the loop because each iteration calls the lock or is an atomic load.
- [ ] **Step 3: Simplification pass** over `Experiments/HotFlag/`.
- [ ] **Step 4: Run all tests; all pass.** Build unsigned Release for iOS 26 and iOS 18. Compare each with its Task 1 baseline: no missing unit. Dump the `HotFlag` units: every lock row's read loop calls its lock and unlock (or `dispatch_sync`, `objc_sync_enter`/`exit`, semaphore wait/signal) once per iteration with the flag load between them; acquiring atomic rows have one `ldar`/`ldapr`, relaxed rows one plain load, inside the loop. Keep the dump in `build/private/remaining-experiments/`.
- [ ] **Step 5: Commit:** `git commit -m "Add the hot flag experiment"`

### Task 4: Request registry (experiment 2)

**Files:**
- Create in `Experiments/RequestRegistry/`: `README.md`, `RequestRegistry.swift`, `LockRegistries.swift`, `SerialQueueRegistry.swift`, `Download.swift`, `RequestRegistryRequest.swift`, `RequestRegistryChecks.swift`
- Modify: `Harness/Execution/RunRequest.swift` (`RequestRegistryTunables`), `Harness/Execution/Experiment.swift`, `scripts/runner/plans.py` and `scripts/runner/attempt_check.py` (the new tunables group), `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`, `docs/data-format.md`
- Create plan: `plans/acceptance-request-registry.json`
- Test: `Tests/RequestRegistryTests.swift`, `Tests/RunRequestTests.swift`, Python tests as in Task 3

**Interfaces:**
- Produces: `struct RequestRegistryTunables: Codable, Equatable, Sendable { var inFlightPerThread: Int; var workIterations: Int; var pauseMicroseconds: Int; var cancelAllEvery: Int; var sampleEvery: Int }` as `Tunables.requestRegistry`.
- Produces: `protocol DownloadRegistry: AnyObject, Sendable { func add(_ download: Download, id: Int); func remove(id: Int) -> Download?; func cancelAll() -> Int }`. `cancelAll` calls `cancel()` on every download under the lock, then `removeAll(keepingCapacity: true)`, and returns the count. The dictionary is created with `minimumCapacity: threads × inFlightPerThread` before timing. `Download` is a `final class` with `let id: Int` and a relaxed `Atomic<Int>` cancel count; each thread allocates its downloads before the block.
- Rows (10): `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `serialQueue`, `dispatchSemaphore`, `objcSync`. Classes `MutexRegistry`, … `ObjcSyncRegistry`. Operation `addAndRemove`; variants `normal` (requires `pauseMicroseconds ≥ 1`, `usleep` after each operation) and `burst` (requires `pauseMicroseconds == 0`). `tunables.threads` is 4 or 8.
- One operation: an add or a remove (alternating), then `referenceLoop(iterations: workIterations)` outside the lock, its result added to the batch value. Untimed: each thread adds `inFlightPerThread` downloads before the first batch and removes the rest after the last. In `normal`, batch times include the pauses.
- Samples, measured batches only: per thread `callStart` and `callTime` (one operation per window of `sampleEvery` operations: operation `k` when `k % sampleEvery == (k / sampleEvery) % 2`, so samples alternate between adds and removes; `Clock.now()` before and after the call); block-level `cancelAllStart` and `cancelAllTime` (thread 0 runs cancel-all). Counts: `measuredBatches × operationsPerBatch / sampleEvery` and `/ cancelAllEvery`.
- Check `requestRegistry.addAndRemove`: the dictionary ends empty, and added = removed by `remove` + cleared by `cancelAll`. Detail: `added 8000, removed 7936, cancelled 64, left 0`.
- Validation: `operationsPerBatch / subBatches` is even and a multiple of `sampleEvery` and `cancelAllEvery`.

- [ ] **Step 1: Tests.** `requestRegistrySmokeRunPasses` for both variants with 4 threads, all 10 rows, `operationsPerBatch` 1,024, `sampleEvery` 64, `cancelAllEvery` 256 → completed, checks pass, the expected samples counts. `requestRegistryRejectsUndividedSamples` (`sampleEvery` 100 → names `requestRegistry.sampleEvery`). `RunRequestTests`: the group's minimum values. Python as in Task 3, plus a plan with a bad `requestRegistry` group rejected. Run; they fail.
- [ ] **Step 2: Implement.** Acceptance plan: both variants at 4 and 8 threads (guess: `inFlightPerThread` 16, `workIterations` 200, `pauseMicroseconds` 50, `cancelAllEvery` 4,096, `sampleEvery` 64). README compiler notes: dictionary code next to a `var` keeps its exclusivity check with locks and queues and has none with `Mutex`; that is ordinary code, kept.
- [ ] **Step 3: Simplification pass.**
- [ ] **Step 4: Tests, comparison, dump** as in Task 3 Step 4 (iOS 26 only). Expected in each row's loop: the lock pair (or `dispatch_sync`) with the dictionary insert or remove between them (a call, or inlined hashing and probing), and the `referenceLoop` call outside them; in `cancelAll`, the iteration and the `removeAll` call.
- [ ] **Step 5: Commit:** `git commit -m "Add the request registry experiment"`

### Task 5: Transactional store (experiment 4)

**Files:**
- Create in `Experiments/TransactionalStore/`: `README.md`, `TransactionalStore.swift`, `LockStores.swift`, `QueueStores.swift`, `Record.swift`, `OperationList.swift`, `TransactionalStoreRequest.swift`, `TransactionalStoreChecks.swift`
- Modify: `Harness/Execution/Experiment.swift`, `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`, `docs/data-format.md`
- Create plan: `plans/acceptance-transactional-store.json`
- Test: `Tests/TransactionalStoreTests.swift`, Python tests as in Task 3

**Interfaces:**
- Produces: `struct Record { var version: Int; var value: Int }`; 10,000 records in one array per store, split into fixed groups of the transaction size. `protocol RecordStore: AnyObject, Sendable { func readGroup(_ group: Int) -> GroupRead; func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int); func waitForPendingWrites() }`. `GroupRead` holds the sum of values and whether all versions matched. A write sets `version + 1` and a value derived from it on every record of the group; its last statement inside the critical section records `Clock.now()` into `endTimes`.
- Rows (13): the hot-flag lock and queue rows without atomics: `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`, `barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore`, `objcSync`. Classes `MutexStore`, …. Readers share the read lock (`pthread_rwlock_rdlock`) or the concurrent queue (`sync`).
- Operations `singleRecord` (groups of 1; reads timed in runs of 100) and `twentyRecords` (groups of 20; each read timed). Variant `default`; plans use 6 threads.
- `OperationList.make(seed: UInt64, thread: Int, batches: Int, transactionsPerBatch: Int, readsPerRun: Int, groups: Int) -> OperationList`: per batch exactly `transactionsPerBatch / 50` writes (2%), placed between read runs at seeded positions; group indexes from `SplitMix64`. Made before timing; every mechanism gets the same lists.
- Samples, measured batches only, per thread: `readTime` (`twentyRecords`) or `hundredReadsTime` (`singleRecord`), and `writeTime` (submission tick to the recorded end tick). The batch waits for pending writes before its end tick, as in experiment 1.
- Check `transactionalStore.<operation>`: violation counter (reads that saw two versions in one group) is 0, and every group's final version equals its number of writes in the lists. Detail: `violations 0; groups 10000 with expected versions`.
- Sub-batches: each batch's list is cut into `subBatches` slices at run boundaries (run `runs × k / subBatches` starts slice `k`); `runOperations` processes the slice of its `subBatch` and ignores `count`.
- Validation: `operationsPerBatch` is a multiple of 5,000.

- [ ] **Step 1: Tests.** `transactionalStoreSmokeRunPasses` (13 rows × 2 operations, 6 threads, `operationsPerBatch` 5,000) → completed, checks pass, `writeTime` has `measuredBatches × 100` values per thread. `operationListHasTwoPercentWrites` (5,000 transactions → 100 writes, 4,900 reads, runs of 100 never contain a write; the same seed gives the same list). `aTornReadIsCounted`: a test store that writes half a group makes the check fail with `violations > 0`. Validation test for 4,999. Python as in Task 3. Run; they fail.
- [ ] **Step 2: Implement.** README "One operation": `PthreadReadWriteLockStore.readGroup(_:)`.
- [ ] **Step 3: Simplification pass.**
- [ ] **Step 4: Tests, comparison, dump** (iOS 26). Expected per read transaction: the lock pair (read lock for `pthreadReadWriteLock`, `dispatch_sync` for queues) and loads of every record of the group, possibly as vector loads that cover the whole group; the sum reaches the check value. Per write: the lock pair or barrier submission and stores to every record.
- [ ] **Step 5: Commit:** `git commit -m "Add the transactional store experiment"`

### Task 6: Creation cost (experiment 9)

**Files:**
- Create in `Experiments/CreationCost/`: `README.md`, `CreationCost.swift`, `ProtectedObjects.swift`, `MallocStatistics.swift`, `CreationCostRequest.swift`, `CreationCostChecks.swift`
- Modify: `Harness/Execution/Experiment.swift`, `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`, `docs/data-format.md`, `docs/harness-design.md` (the `memory` line becomes `samples` lines)
- Create plan: `plans/acceptance-creation-cost.json` (two entries: 10,000 and 100,000 objects as `operationsPerBatch`)
- Test: `Tests/CreationCostTests.swift`, Python tests as in Task 3

**Interfaces:**
- Rows (15): `unsynchronized`, `mutex`, `osAllocatedUnfairLock`, `osUnfairLock` (heap-allocated lock), `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`, `barrierQueueSyncWrite` (one concurrent queue), `dispatchSemaphore`, `actor`, `mainActor`, `atomic`, `managedAtomic`. Classes `UnprotectedObject`, `MutexObject`, …, `ManagedAtomicObject`: each holds one `Int` and its mechanism, as app code writes it, and a `deinit` that adds 1 to a relaxed `Atomic<Int>` deinit counter.
- Operations: `create` (timed creation of `operationsPerBatch` objects, appended to a `ContiguousArray` reserved before the block; untimed destruction after) and `destroy` (untimed creation; timed `removeLast(operationsPerSubBatch)` per sub-batch). One thread; the batch loop is written out with `Clock.now()` and `ThreadLog`, with CPU readings at sub-batch edges, because malloc readings must run between batches. `mainActor` runs each batch on the main thread through `waitForMainThreadWork` (deadline 10 s).
- `MallocStatistics.read() -> (blocks: UInt64, bytes: UInt64)` from `malloc_zone_statistics(nil, …)`.
- Samples (`create` blocks only), block-level, one value per batch: `mallocBlocksBeforeCreate`, `mallocBlocksAfterCreate`, `mallocBlocksAfterDestroy` (unit `blocks`) and the three `mallocBytes…` (unit `bytes`).
- Check `creationCost.<operation>`: the deinit count equals the objects created; for `create` also, in every measured batch, blocks after create − blocks before ≥ objects (each object is a heap block, none kept on the stack) and blocks after destroy − blocks before ≤ objects / 100; across measured batches, blocks after destroy grow by at most objects / 100. Warm-up batches absorb one-time runtime allocations. Detail names the three numbers. All other harness threads are idle while the statistics are read.

- [ ] **Step 1: Tests.** `creationCostSmokeRunPasses` (15 rows × 2 operations, `operationsPerBatch` 1,000, 1 warm-up and 2 measured batches) → completed, checks pass, 6 samples lines per `create` block. `unprotectedObjectsAreHeapBlocks` (the check's heap-block rule holds for `unsynchronized`). `aLeakFailsTheCheck`: a test object that keeps itself alive fails with a growth detail. Python as in Task 3. Run; they fail.
- [ ] **Step 2: Implement.** README states why `objc_sync` and the left-out rows are not here (copy the note from `docs/experiments.md`).
- [ ] **Step 3: Simplification pass.**
- [ ] **Step 4: Tests, comparison, dump** (iOS 26). Expected: the create loop calls `swift_allocObject` once per object, plus the mechanism's own allocation or init (for example `pthread_mutex_init`, `dispatch_queue_create`, `objc_alloc`); the destroy path releases every object.
- [ ] **Step 5: Commit:** `git commit -m "Add the creation cost experiment"`

### Task 7: Main-thread image cache (experiment 8A)

**Files:**
- Create in `Experiments/MainThreadCache/`: `README.md`, `MainThreadCache.swift`, `LockImageCaches.swift`, `QueueImageCaches.swift`, `MainActorImageCache.swift`, `ScrollingScreen.swift`, `CacheImages.swift`, `MainThreadCacheRequest.swift`, `MainThreadCacheChecks.swift`
- Modify: `Harness/Execution/RunRequest.swift` (`MainThreadCacheTunables`), `Harness/Execution/Experiment.swift`, `scripts/runner/plans.py`, `scripts/runner/attempt_check.py`, `scripts/runner/expected_attempt.py`, `scripts/tests/synthetic_attempts.py`, `docs/data-format.md`
- Create plan: `plans/acceptance-main-thread-cache.json` (2 and 4 writers)
- Test: `Tests/MainThreadCacheTests.swift`, Python tests as in Task 4

**Interfaces:**
- Produces: `struct MainThreadCacheTunables: Codable, Equatable, Sendable { var warmupFrames: Int; var frames: Int; var scrollPointsPerSecond: Int; var decodeIterations: Int; var writeIntervalMicroseconds: Int }` as `Tunables.mainThreadCache`.
- Produces: `struct CachedImage: Sendable { let image: UIImage; let imageIndex: Int }` and `protocol ImageCache: AnyObject, Sendable { func image(for key: String) -> CachedImage?; func store(_ entry: CachedImage, for key: String) }`. `CacheImages` draws 64 images at block setup (`UIGraphicsImageRenderer`, outside timing) and makes 1,000 keys like `https://images.example.com/photos/0042.jpg`; the cache is filled with all keys before the block.
- Rows (14): the 13 store rows of Task 5 (`ImageCache` classes, read lock and `sync` for reads) plus `mainActor` (`@MainActor final class MainActorImageCache`; reads are direct; writers are `Task.detached` loops that `await` `store`). Operation `scroll`; variant `default`; `tunables.threads` (2…4) is the number of writers at `tunables.qos`.
- `ScrollingScreen` (`@MainActor`) adds a full-screen `UICollectionView` to the root view controller's view and removes it after the block: a grid of 4 columns of square cells with one `UIImageView` each, 10,000 items, item `i` shows key `i % 1000`, UIKit defaults (prefetching on). A `DisplayLinkLoop` (Task 2) runs `warmupFrames + frames` frames; each frame moves `contentOffset` by `scrollPointsPerSecond / maximumFramesPerSecond` points, so both phones scroll at the same speed and every mechanism shows the same cells.
- The measured operation is the app's own read: `collectionView(_:cellForItemAt:)` dequeues the cell, reads `cache.image(for: key)` between two `Clock.now()` calls, records the time, and sets `cell.imageView.image`. UIKit calls it whenever a cell appears, so the number of reads per frame follows the scrolling (about 1–3 at fast scroll, none in some frames). Reads count only after the warm-up frames.
- Writers: until the frames end, `referenceLoop(iterations: decodeIterations)` (its result goes to a check value), then `store` a seeded random image for a seeded random key, then pause `writeIntervalMicroseconds`. The owner stops them with a relaxed `Atomic<Bool>` and waits for pending writes. The pilot tunes `writeIntervalMicroseconds` toward about 95/5 reads to writes; the check detail reports both counts.
- The owner installs the screen, runs the frames and removes the screen through `waitForMainThreadWork`.
- Samples, measured frames only, block-level: `readTime` (one value per read, ticks; the count is not fixed), `frameStart` (`frames` values, ticks), `frameInterval` (`frames` values, nanoseconds, `targetTimestamp − timestamp`). Block line only; no batch lines (`recording: .samplesOnly`). The read buffer is allocated before the block with a capacity computed from the scroll distance and the cell size, plus room for prefetching; an overflow fails the check and never grows the buffer.
- Python: `ExpectedSamples` gets a way to say "at least one value" (for example `values_per_line=None`), used only for `readTime`; every other group keeps its exact count.
- Check `mainThreadCache.scroll`: all frames completed before the deadline (`(warmupFrames + frames) × 50 ms + 5 s`); at least one measured read; every read found an entry whose image is `images[imageIndex]` (violations counted); every writer stored at least once. Detail: `frames 600/600; reads 950, writes 50, violations 0`.
- Validation: `frames ≥ 1`, `warmupFrames ≥ 0`, `scrollPointsPerSecond` 1…20,000.

- [ ] **Step 1: Tests.** `mainThreadCacheSmokeRunPasses` in the Simulator (14 rows, 2 writers, 10 warm-up and 60 measured frames, `scrollPointsPerSecond` 3,000) → completed, checks pass, `frameStart` and `frameInterval` have 60 values and `readTime` at least one. `aHalfWrittenEntryIsCounted` with a test cache that returns a mismatched index. Python: a `readTime` line with any positive count is accepted and an empty one rejected; the rest as in Task 4. Run; they fail.
- [ ] **Step 2: Implement.** README "One operation": `NSLockImageCache.image(for:)` as called from `cellForItemAt`; "How it is timed" says that frame gaps show main-thread delays per frame, not render-server hitches, and that they include the real UIKit work of configuring cells.
- [ ] **Step 3: Simplification pass.**
- [ ] **Step 4: Tests, comparison, dump** (iOS 26). Expected per read: the lock pair (read lock, `dispatch_sync`) around the dictionary lookup; the `mainActor` read is a direct lookup.
- [ ] **Step 5: Commit:** `git commit -m "Add the main-thread image cache experiment"`

### Task 8: Docs, codegen record and acceptance on both iPhones

**Files:**
- Create: `docs/build-checks/2026-11-remaining-experiments.md`, `docs/phase-3-acceptance.md`
- Modify: `README.md` (the experiment list), `docs/harness-design.md` (only where this plan changed it)

- [ ] **Step 1: Codegen record.** From a clean HEAD, build unsigned Release for iOS 26 and iOS 18, compare with the Task 1 baselines and dump the new units. For every new row, write one line: the per-operation calls and loads found, and that the result has a consumer. Expected: no missing old unit without a recorded reason, and no row whose work is gone.
- [ ] **Step 2: Read each new README as a reader:** seven headings, the real code under "One operation", a main file of about one screen.
- [ ] **Step 3: Stop and ask Ivan to prepare both phones.**
- [ ] **Step 4: Device acceptance on `iphone11` and `iphone15`** from clean signed builds: `calibration` (new `display` key present: about 16.67 ms on `iphone11`, about 8.33 ms on `iphone15`), `acceptance-hot-flag`, `acceptance-hot-flag-ios18` (iOS 18 build), `acceptance-request-registry`, `acceptance-transactional-store`, `acceptance-creation-cost`, `acceptance-main-thread-cache`. Expected: every completed attempt is accepted. If Step 1 recorded a changed unit in experiments 1, 7 or 8B, also repeat that experiment's acceptance plan. Record session IDs, outcomes and the display rates in `docs/phase-3-acceptance.md`.
- [ ] **Step 5: Run the Python suite and the Simulator tests; all pass.**
- [ ] **Step 6: Commit:** `git commit -m "Record remaining-experiment checks and acceptance"`
