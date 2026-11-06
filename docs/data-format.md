# Result data format

Schema 1 uses UTF-8 JSON Lines: one object per line, with a final newline. Keys are camelCase and sorted at every nesting level. An optional key without a value is omitted, never `null`. Times are integer `mach_absolute_time` ticks; the app computes no averages. Tick and raw sample values are unsigned 64-bit integers. Counts, CPU numbers, byte sizes, and permille values are integers; booleans are JSON booleans.

## Lines

`run`: `type` (`run`), `schema` (1), `request` (the request as decoded), `build`, `phone`, `conditions`.

The request contains `schema`, `runID`, `attemptID`, `attempt`, `experiment`, `variant`, `seed`, `smoke`, optional `simulation`, `mechanisms`, `operations`, `tunables`, optional `traced` (`true` only in requests from a traced plan; omitted otherwise). Tunables contain `threads`, `qos`, `warmupBatches`, `measuredBatches`, `subBatches`, `operationsPerBatch` (mechanism ID to operations count, with a `default` fallback), `referenceLoopIterations`, optional calibration `repeats`, optional `asyncCode`, optional `priorityInversion`, optional `requestRegistry`, optional `mainThreadCache`. `asyncCode` (experiment 7, path `fromManyTasks`) has `callsPerTask` (timed calls per task) and `warmupCallsPerTask` (untimed calls per task before the timed ones). `priorityInversion` (experiment 8B) has `holderWorkIterations` (`referenceLoop` iterations the holder runs under the lock), `loadQoS`, `loadMilliseconds`, `mainDelayMicroseconds`, `pauseMilliseconds`, `warmupTrials`, `trials`. QoS is `userInteractive`, `userInitiated`, `default`, `utility`, or `background`. Simulation is `crash` or `hang`, only in smoke runs.

`build`: `buildID`, `commit`, `dirty`, `target` (`ios26` or `ios18`), `minimumOS`, `configuration` (`Release` or `Debug`). The build script embeds metadata before signing. An Xcode build without script metadata uses `unknown` for build ID and commit.

`phone`: `machine`, `osVersion`, `osBuild`, `cpuCount`, `activeCPUCount`, `performanceLevels`, `cacheLineBytes`, `memoryBytes`, `timebaseNumerator`, `timebaseDenominator`, `mainThreadQoSClass`, optional `mutexDefaultPolicy`, optional `ulockAdaptiveSpinMicroseconds`. Each performance level has `index`, `name`, `logicalCPUCount`, `physicalCPUCount`, `l1DataCacheBytes`, `l2CacheBytes`, `cpusPerL2`. Memory is unsigned 64-bit; timebase and QoS class are unsigned 32-bit.

`conditions`: `thermalState` (`nominal`, `fair`, `serious`, `critical`), `lowPowerMode`, `batteryState` (`unknown`, `unplugged`, `charging`, `full`), `batteryLevelPermille` (−1 when unknown), `screenBrightnessPermille`, `debuggerAttached`, `applicationState` (`active`, `inactive`, `background`), `environment` (only watched variables that are set), `ticks`, `wallClock` (ISO 8601 UTC, seconds, such as `2026-11-05T00:00:00Z`).

`reference`: `type` (`reference`), `when` (`start` or `end`), `iterations`, `start`, `end`, `cpuReadings` (before and after).

`block`: `type` (`block`), `block` (position in seeded run order, starting at 0), `mechanism`, `operation`, `threads`, `qos`, `operationsPerBatch`, `start`, `end`, `voluntaryContextSwitches`, `involuntaryContextSwitches`, `taskContextSwitches` (changes over the block), `thermalStateAtStart`, `thermalStateAtEnd`.

`batch`: `type` (`batch`), `block`, `batch` (starting at 0, warm-up batches first), `thread`, `warmup`, `operations`, `start`, `end`, `cpuReadings` (`subBatches + 1` values), optional `executorCPUReadings` (same length).

`samples`: `type` (`samples`), optional `block`, optional `thread`, `metric`, `unit`, `values`, optional `cpuAtStart` and `cpuAtEnd` (each as long as `values`). Values are raw unsigned 64-bit samples.

`trial` (experiment 8B): `type` (`trial`), `block`, `trial` (starting at 0, warm-up trials first), `warmup`, `holderQoS` (`utility` for `utilityHolder`, `background` for `backgroundHolder`, matching the block's `qos`), the ticks `loadStart`, `loadStop`, `holderAcquire`, `holderRelease`, `mainArrival`, `mainAcquire`, `holderCPUReadings` (CPU numbers on the holder side at acquire and at release), `mainCPU` (CPU number of the main thread after it got the lock), `holderResultCorrect`, `mainObservedTrial` (the value the main thread read under the lock; the holder writes the trial index), `outcome` (`valid`, `censored`, `invalid`).

A trial is `valid` when the main thread arrived while the holder held the lock (`holderAcquire < mainArrival < holderRelease`) and before the load stopped (`mainArrival < loadStop`), and got the lock no later than the load stop (`mainAcquire <= loadStop`). It is `censored` when the main thread arrived the same way but got the lock only after the load stopped (`mainAcquire > loadStop`): the wait is kept and reported apart, never as a measured wait. Every other trial is `invalid`: it is kept and counted, but its wait is never used.

`end`: `type` (`end`), `status` (`completed`, `refused`, `failed`), optional `reasonCode`, optional `reason`, `checks`, `blockLines`, `warmupBatchLines`, `measuredBatchLines`, `conditions` (at the end), `thermalChanges`. Each check has `name`, optional `block`, `passed`, `detail`, optional `violations`. Each thermal change has `ticks`, `thermalState`.

## Order and status

Lines appear in this order: `run`; `reference` at start; for each block its `block` line, then `batch` lines ordered by thread and batch, then `samples` lines, then `trial` lines ordered by `trial`; `reference` at end; `end`. Block timestamps enclose batch timestamps, so a block's end tick is written before the enclosed batches. A refused or invalid attempt has only `run` and `end`.

Refusal reason codes are `thermal`, `lowPower`, `battery`, `debugger`, `applicationState`, `environment`, `configuration`. Failure reason codes are `check`, `invalidRequest`.

### Calibration work and checks

Calibration writes six blocks with operation `""`: `clockSingleThread` (one thread),
`clockAllCPUs`, `cpuSpeedUserInteractive`, and `cpuSpeedBackground` (each using
`phone.cpuCount` threads), `holderWorkSingleThread` and `displayFrames` (one thread
each). Every block
uses QoS `userInteractive` except `cpuSpeedBackground` (`background`). Clock blocks
use metric `clockRead1000`; CPU-speed blocks use `referenceLoop`;
`holderWorkSingleThread` uses `holderWork`; `displayFrames` uses `displayFrame`.
Each block writes one `samples` line
per thread, with unit `ticks` and exactly `tunables.repeats` values, so an attempt
has `3 + 3 × cpuCount` samples lines. `referenceLoop` and `holderWork` samples time
`referenceLoop(iterations: tunables.referenceLoopIterations)` and carry
`cpuAtStart` and `cpuAtEnd`; clock and display samples carry neither. The core map
pools every
`referenceLoop` line, so the holder work keeps its own metric. Calibration writes no
batch lines. Each block owns exactly one `calibration.samples` correctness check
with its block position; there is no separate run-level calibration check.

`displayFrames` requests the screen's maximum frame rate and records `Clock.now()`
at each of `repeats` display-link callbacks (absolute ticks, not durations). The run
thread waits at most `repeats × 50 ms + 5 s`; a missed deadline fails the block check.
These callback gaps measure achieved main-thread cadence, not render-server hitches.

`bench.py calibrate` writes `results/<phone>/calibration.json` from the accepted
attempt: `attemptID`, `phone` (the run line's phone facts), `coreMap`
(`performance`, `efficiency`, `medianTicksByCPU`), `display` and `priorityInversion`.
`display` holds `medianFrameTicks` (the median of consecutive callback gaps),
`medianFrameMilliseconds` (ticks converted using the phone timebase, rounded to two
places) and `framesMeasured` (the callback count). Derivation requires at least two
callbacks, positive gaps and a positive timebase. Existing `calibration.json` files
without `display` still resolve holder work. The holder work calculation keeps the `holderWork` samples whose
`cpuAtStart` equals `cpuAtEnd` and is a performance CPU of the core map (at least
half of all samples, or calibration fails), and takes `int(median(usableTicks))`.
It computes the 5 ms target as
`targetTicks = 5_000_000 × timebaseDenominator // timebaseNumerator`, then sets
`holderWorkIterations = round(targetTicks × iterationsMeasured / medianTicks)`.
The final division uses Python floating-point arithmetic and `round` returns an integer.
`priorityInversion` holds `holderWorkIterations`, `targetMilliseconds` (5),
`iterationsMeasured`, `medianTicks` and `samplesUsed`. A plan's
`"holderWorkIterations": "fromCalibration"` is replaced with this integer before
launch; the session records `calibrationAttemptID` in `session.json`, and stops
before installation when the file or its `priorityInversion` is missing.

### Request registry (experiment 2)

`requestRegistry` requests use operation `addAndRemove`, variant `normal` or `burst`, four or eight threads, and a required `tunables.requestRegistry` group: `inFlightPerThread`, `workIterations`, `pauseMicroseconds`, `cancelAllEvery`, `sampleEvery`. The first two values and `cancelAllEvery` are at least one; pauses are 0…4,294,967,295 microseconds and must be positive in normal and zero in burst. `sampleEvery` is even and at least two. Each sub-batch contains an even number of calls divisible by `sampleEvery` and `cancelAllEvery`. Storage sizes and total add counts must fit a signed integer.

The ten mechanisms are `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `serialQueue`, `dispatchSemaphore`, `objcSync`. Every worker alternates removal of its oldest download and addition of its next preallocated download. The dictionary reserves `threads × inFlightPerThread` capacity before the block. Each worker allocates one extra ring item before the block, fills its initial in-flight entries before batches, then removes all its remaining entries after batches. An operation includes one registry call and `referenceLoop(workIterations)` outside the lock. Normal batch times include the pause after each operation. Thread 0 also cancels every registered download and clears the dictionary under the lock every `cancelAllEvery` operations.

Blocks emit ordinary warm-up and measured batch lines. Measured batches additionally emit `callStart` and `callTime` samples on every thread, each containing `measuredBatches × operationsPerBatch / sampleEvery` values. For measured operation `k`, the sampled call satisfies `k % sampleEvery == (k / sampleEvery) % 2`; samples alternate between removals and additions. Calls are bracketed by `Clock.now()` without outside work or pauses. Thread 0's cancel-all calls produce two block-level samples lines (no `thread`): `cancelAllStart` and `cancelAllTime`, each with `measuredBatches × operationsPerBatch / cancelAllEvery` values. Starts are absolute ticks; times are elapsed ticks. All four metrics use unit `ticks`, have no CPU arrays, and exclude warm-up.

Each block has one `requestRegistry.addAndRemove` check. It requires an empty dictionary, `added == removed + cancelled`, matching per-download atomic cancellation counts, and the expected outside-work checksum in every batch. Detail follows `added 8000, removed 7936, cancelled 64, left 0`.

### Hot flag (experiment 3)

`hotFlag`, variant `default`, runs one reader thread at `tunables.qos` against a main-thread writer that toggles a `Bool` immediately, then every 10 ms with zero timer leeway. The 17 mechanisms are `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`, `barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore`, `objcSync`, `atomic`, `managedAtomic`, `atomicRelaxed` and `managedAtomicRelaxed`. Acquiring atomic rows use acquiring reads and releasing writes; the relaxed rows use relaxed ordering. Every selected mechanism runs each selected operation.

Both `read` and `readGroups` write the normal warm-up and measured batch lines. `readGroups` additionally writes exactly one `samples` line on thread 0, with metric `readGroupTime`, unit `ticks` and `measuredBatches × operationsPerBatch / 100` values in batch, sub-batch and group order. Each value times 100 reads in a measured batch. Warm-up contributes no group samples. There are no executor CPU arrays or extra sample lines for `read`. For `readGroups`, `operationsPerBatch / subBatches` must be a multiple of 100.

Each block has one `hotFlag.<operation>` check. After its reader batches, the reader stops the main-thread writer with a one-second deadline, waits for pending asynchronous writes, and reads the final value on the reader thread. A passing check requires at least one write, a final read equal to the last written value, valid batch true-read counts and completed main-thread start and stop work. Its detail is, for example, `writes 12; last true, read true`. The iOS 18 acceptance plan adds only `mutex`, `atomic`, `atomicRelaxed`, `managedAtomic` and `managedAtomicRelaxed` rows.

### Transactional store (experiment 4)

`transactionalStore`, variant `default`, runs six workers at `tunables.qos`. Its 13 mechanisms are `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`, `barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore` and `objcSync`. Every selected row runs each selected operation: `singleRecord` or `twentyRecords`. A store owns 10,000 records partitioned into groups of one or twenty. Each read sums all values and compares all versions under protection; each write increments the group's version and assigns that version to every value.

`operationsPerBatch` must be a multiple of 5,000. Before timing, seeded per-worker lists place exactly `operationsPerBatch / 50` writes between read runs and select record groups through `SplitMix64`. A read run contains 100 transactions for `singleRecord`, or one for `twentyRecords`. Sub-batch k starts at run `runsPerBatch × k / subBatches`, so run boundaries survive uneven splits; the ordinary batch line still reports `operationsPerBatch` transactions. Each batch drains pending writes before its end tick.

Every block writes ordinary warm-up and measured batch lines plus two measured-only samples lines per thread, with unit `ticks` and no CPU arrays. `singleRecord` uses `hundredReadsTime` with `measuredBatches × (operationsPerBatch - operationsPerBatch / 50) / 100` values; `twentyRecords` uses `readTime` with `measuredBatches × (operationsPerBatch - operationsPerBatch / 50)` values. Both use `writeTime` with `measuredBatches × operationsPerBatch / 50` values. Read samples bracket each complete read run. Write samples span submission through the completion tick recorded inside the write critical section, before unlocking. Arrays follow batch and run order, and write samples follow write order.

Each block has one `transactionalStore.<operation>` check with integer `violations`, counting reads that saw different versions within a group. A passing check requires zero violations, every group's final version equal to its write count across all lists, a matching final value sum and valid batch sums. Detail follows `violations 0; groups 10000 with expected versions` (500 groups for `twentyRecords`). Checks and sample encoding happen after all workers and asynchronous writes finish.

### Main-thread image cache (experiment 8A)

`mainThreadCache` requests use variant `default`, operation `scroll`, and 2…4 writer threads. The required `tunables.mainThreadCache` group contains `warmupFrames` (at least 0), `frames` (at least 1), `scrollPointsPerSecond` (1…20,000), `decodeIterations` (at least 1) and `writeIntervalMicroseconds` (0…4,294,967,295). Frame duration and sample storage arithmetic must fit a signed integer before allocation. The fourteen mechanisms are the thirteen transactional-store rows plus `mainActor`.

Blocks use sample-only recording, with no `batch` lines and no CPU arrays. Exactly three `samples` lines carry `block` and omit `thread`: `readTime` uses unit `ticks` and any positive number of values; `frameStart` uses unit `ticks` and exactly `frames` values; `frameInterval` uses unit `nanoseconds` and exactly `frames` values. All values exclude warm-up. The variable read count applies only to this experiment's `readTime`; transactional-store read samples and every other sample group retain exact counts. Frame starts are Clock.now readings; intervals are `targetTimestamp - timestamp` from CADisplayLink. Read durations bracket the actual cache lookup inside the UIKit cell callback.

Every block has one `mainThreadCache.scroll` check: frames completed before `(warmupFrames + frames) × 50 ms + 5 s`, at least one measured read, no missing entry or mismatched image/index pair, no fixed-buffer overflow and at least one completed store by every writer. Writers stop and pending writes drain before their counters are inspected. The detail reports measured frames, measured reads, all writes (including warm-up), violations, overflow and the consumed decode checksum.

## Creation cost (experiment 9)

Variant `default` runs the requested mechanisms × operations on one thread. Mechanisms are
`unsynchronized`, `mutex`, `osAllocatedUnfairLock`, `osUnfairLock`, `nsLock`,
`nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`,
`barrierQueueSyncWrite`, `dispatchSemaphore`, `actor`, `mainActor`, `atomic`, and
`managedAtomic`. Operations are `create` and `destroy`. Selections are nonempty and unique;
requests require `threads` 1 and representable object storage. Both operations emit the usual
warm-up and measured `batch` lines, using the requested QoS and object count. The main-actor
row creates and destroys on the main thread, with a ten-second deadline per batch.
An untimed readiness signal ensures caller submission buffers have been released before
the main thread reads malloc statistics. For worker batches, main parks for at most one
second, and a missed park deadline fails completion even if the worker later finishes.

Only `create` emits samples: six lines per block, with no `thread`, `cpuAtStart` or
`cpuAtEnd`. Metrics `mallocBlocksBeforeCreate`, `mallocBlocksAfterCreate` and
`mallocBlocksAfterDestroy` use unit `blocks`; `mallocBytesBeforeCreate`,
`mallocBytesAfterCreate` and `mallocBytesAfterDestroy` use unit `bytes`. Each line has
`warmupBatches + measuredBatches` values in batch order, warm-up first. These are allocator-reported blocks
and bytes (including allocator cache accounting), read outside creation/destruction timing while other harness threads are idle.

Each block has one `creationCost.<operation>` check. The deinit counter must equal all
created objects, including warm-up. Every object retained in a measured create batch must have nonzero `malloc_size`,
checked outside timing after the after-create snapshot. Aggregate xzone statistics can
include cached free slots, so creation need not add one reported block per object. Return and growth checks use a separate untimed enumeration of
`MALLOC_PTR_IN_USE_RANGE_TYPE`, counting allocated pointers while excluding cached free
slots. After destruction, these live blocks above that batch’s baseline must be at most
`operationsPerBatch / 100`; any later increase above an earlier post-destruction count has
the same allowance. Enumeration errors fail the check. Enumeration uses the supported
self-reader with allocation-free callbacks and no manual zone locking; Nano may allocate
transient scratch memory internally. Unrelated framework activity can still change
process-wide counts. Detail gives deinit counts, completion, the three raw block counts,
enumerated live before/after-destruction counts and post-destruction growth. A missed
main-thread deadline fails completion; executor-owned storage is read only after successful
completion. `destroy` checks deinit accounting and completion without malloc samples.

### Async code (experiment 7)

The variant picks a table of operations; each operation lists the mechanisms measured with it
(`AsyncCode.rows` in Swift):

| Variant | Operation | Mechanisms |
|---|---|---|
| `callerPaths` | `onActor` | `actor` |
| `callerPaths` | `fromBackgroundTask` | `actor`, `mutex`, `osAllocatedUnfairLock`, `nsLock` |
| `callerPaths` | `fromManyTasks` | `actor`, `mutex`, `osAllocatedUnfairLock`, `nsLock` |
| `callerPaths` | `fromMainActor` | `actor`, `mutex`, `osAllocatedUnfairLock`, `nsLock` |
| `callerPaths` | `toMainActor` | `mainActor` |
| `batching` | `oneAwaitPerGroup`, `awaitPerOperation` | `actor` |
| `batching` | `oneLockPerGroup` | `mutex` |
| `isolationSettings` | `callFromMainActor` | `templateDefaults`, `swift6Language`, `concurrentAttribute` |

The blocks are the requested (operation, mechanism) pairs that the table allows. A request
is rejected when the variant is not in the table, when `tunables.threads` is not 1, when
`mechanisms` or `operations` is empty or repeats a value, when a requested mechanism or
operation is in no allowed pair, when `fromManyTasks` is requested without `asyncCode`, or,
for `batching`, when an `operationsPerBatch` value is not a multiple of `subBatches × 100`.
Every block uses QoS `tunables.qos` and `operationsPerBatch` for its mechanism.

`callerPaths` blocks:
- `onActor`, `fromBackgroundTask`, `fromMainActor`, `toMainActor`: one task (`threads` 1)
  and the usual `batch` lines. The `actor` and `mainActor` rows carry
  `executorCPUReadings`, except `onActor`, whose loop already runs on the actor.
- `fromManyTasks`: 50 tasks (`threads` 50) and no `batch` lines. Each task makes
  `asyncCode.warmupCallsPerTask` untimed calls, waits once for the others, then times
  `asyncCode.callsPerTask` single calls. In the actor row, tasks wait a second time
  after timing so task 0 reads the final counter only after all timed calls finish.
  Lock rows read the final counter after all tasks have joined. The block writes
  one `samples` line per task:
  `thread` (the task index, 0…49), metric `callTime`, unit `ticks`, `callsPerTask` values,
  no CPU readings.
- `fromMainActor` and `toMainActor` also write two `samples` lines without `thread`:
  metrics `mainThreadCPUAtBatchStart` and `mainThreadCPUAtBatchEnd`, unit `microseconds`,
  one value per batch, warm-up batches first (`warmupBatches + measuredBatches` values).
  A value is the main thread's user plus system CPU time, read just before the batch's start
  tick or just after its end tick.

`batching` blocks: one task (`threads` 1) and the usual `batch` lines. The state is 128
counters; operation `k` of a sub-batch increments counter `k % 128`. `oneAwaitPerGroup`
awaits one actor call per 100 operations, `awaitPerOperation` one actor call per operation,
and `oneLockPerGroup` takes a `Mutex` once per 100 operations. The two `actor` rows carry
`executorCPUReadings`; `oneLockPerGroup` does not.

`isolationSettings` blocks: one task (`threads` 1) whose batch loop runs on the main actor;
one operation is one call of the probe from the main actor. `templateDefaults` calls
`nonisolatedWork()` of `IsolationProbeTemplate`, `swift6Language` the same function of
`IsolationProbeSwift6`, and `concurrentAttribute` `concurrentWork()` of
`IsolationProbeTemplate`. The block writes the usual `batch` lines without
`executorCPUReadings` and the two main-thread CPU `samples` lines described for `callerPaths`.

Each block has one check, `asyncCode.<operation>`, with its block position. For `callerPaths`
and `batching`, the counter's final value (the sum of the 128 counters for `batching`) equals
`threads × (warmupBatches + measuredBatches) × operationsPerBatch`, or
`50 × (warmupCallsPerTask + callsPerTask)` for `fromManyTasks`. For `isolationSettings`, the
probe is reset before the block; after it, the probe's call count equals
`(warmupBatches + measuredBatches) × operationsPerBatch`, and its count of calls that ran on
the main thread equals that number for `templateDefaults` and 0 for the other two rows
(0 and 2 thread switches per call). The detail names both numbers, for example
`calls 1200/1200; on main thread 1200, expected 1200`.

The attempt checker stores the required name in each `ExpectedBlock.check`:
`baseComparison.<operation>`, `requestRegistry.addAndRemove`, `hotFlag.<operation>`, `transactionalStore.<operation>`, `creationCost.<operation>`, `mainThreadCache.scroll`, `asyncCode.<operation>`,
`priorityInversion.<operation>`, or the fixed calibration name `calibration.samples`.
`ExpectedAttempt.blocks` maps each (mechanism, operation) pair to its expected work,
including batch, samples and trial line counts. `ExpectedAttempt.run_checks` is
empty for all implemented experiments.

### Priority inversion (experiment 8B)

Variant `default` runs every requested mechanism × operation pair. The fourteen mechanisms
are `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`,
`nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`,
`barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore`, `actor`, and `objcSync`.
Operations are `utilityHolder` and `backgroundHolder`. A block has one thread and reports the
holder's QoS (`utility` or `background`); the controller pthread runs at `tunables.qos`.
Requests require nonempty, unique mechanism and operation lists, `tunables.threads` 1,
and `tunables.priorityInversion`. `mainDelayMicroseconds` is 0…1,000,000 inclusive
(at most one second), keeping the scheduled main-thread sleep below the five-second
finish allowance.
Duration conversion must fit unsigned 64-bit nanoseconds and ticks: `loadMilliseconds`
is at most 18,446,744,073,709, with a smaller limit when required by the recorded clock
timebase. `pauseMilliseconds` is at most 4,294,967 so its microseconds fit `useconds_t`.
A deadline addition that overflows the tick clock is reported as a timeout.

Blocks emit no `batch` or `samples` lines. Each emits `warmupTrials + trials` `trial` lines,
indexed from 0; only the first `warmupTrials` have `warmup` true. The controller waits for
the holder to acquire while the CPUs are free, then releases one load pthread per CPU.
`loadStart` and `loadStop` are the intended fixed load interval; the main side targets
the holder acquire plus `mainDelayMicroseconds` for arrival. Outcome classification follows the tick
rules above. All trials, including invalid and censored ones, remain in the file.

Each block has one `priorityInversion.<operation>` check with its block position. It passes
when no wait timed out, every holder result is correct, every main-side observation equals
the trial index, and `mainAcquire >= holderRelease` whenever `mainArrival < holderRelease`.
`violations` counts trials breaking any of those correctness rules once per trial. The detail
reports the outcome counts and timeout flag, for example
`valid 8, censored 2, invalid 1; timed out false`. Invalid or censored outcomes alone do not
fail correctness. An acquire wait times out after 2 seconds; subsequent waits share a deadline
5 seconds after `loadStop`. A timeout stops that block's trials early, retains the completed
trial lines, and fails the check even if their `violations` count is zero.

## Request validation

Every validation error names the field. `schema` is 1. `runID` and `attemptID` match `^[A-Za-z0-9._-]{1,128}$`. `attempt` is at least 1; `seed` is below 2^53. `threads` is 1…64; `warmupBatches` is at least 0; `measuredBatches` and `subBatches` are at least 1. `operationsPerBatch` has a `default` key and every value is a multiple of `subBatches` and at least `subBatches`. `referenceLoopIterations` is at least 1. When `asyncCode` is present, `callsPerTask` is at least 1 and `warmupCallsPerTask` at least 0. When `priorityInversion` is present, `holderWorkIterations`, `loadMilliseconds` and `trials` are at least 1, `mainDelayMicroseconds`, `pauseMilliseconds` and `warmupTrials` at least 0, and `warmupTrials + trials` fits a signed 64-bit integer. When `requestRegistry` is present, its minima and even sampling interval follow the experiment 2 rules above. Experiments add their own rules. `simulation` appears only in smoke requests. Decoding does not validate, allowing an invalid decoded request to be included in a failure result.

SplitMix64 and descending Fisher–Yates determine seeded order: for each index from count − 1 to 1, swap with `next() % (index + 1)`.

## Publication

The writer atomically publishes `<attemptID>.jsonl`, then atomically publishes `<attemptID>.done` in the result directory. The marker has `attemptID`, `file`, `bytes`, `sha256` (lowercase hex of the exact JSONL bytes). Both files have sorted keys. A file without its marker is incomplete. Replacing an attempt first removes its old marker. The writer independently rejects an unsafe attempt ID before creating a directory or file, including for invalid decoded requests.

`Tests/Fixtures/golden-base-comparison.jsonl` fixes the writer/checker contract. It uses the one-thread request with seed 7, one mutex increment block, one warm-up and two measured batches of four operations, and the check `expected 12, got 12`. Phone facts and conditions are fixed fictional values. Tests compare bytes against this reviewed fixture and never rewrite it.

## Host trace attempt records

The host's schema-1 run state and `session.log` retain `traced: true` and the
session-relative `traceFile` for traced attempts. New records also have
`traceStatus`: `completed` when recorder finalization succeeds, or `failed`.
`completed` describes the recorder lifecycle; it does not certify trace contents
or override a rejected app verdict.

On recorder failure, the host record has `status: traceFailed`, `accepted: false`,
`traceReason` and `reasons` describing the recorder failure, and `appVerdict`
containing the unchanged app checker verdict (`status`, `accepted`, `reason_code`,
`reasons`). The copied JSONL, marker and `.check.json` remain unchanged, and the
trace path remains available for diagnostics. The session reports a rejection
and stops with the trace reason. Failed traces do not count toward `maxAttempts`,
so the same CLI command can retry with a new attempt ID without editing state.
Older records without these optional fields keep their existing meaning and are
not rewritten or retroactively validated.
