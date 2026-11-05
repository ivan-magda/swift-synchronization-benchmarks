# Result data format

Schema 1 uses UTF-8 JSON Lines: one object per line, with a final newline. Keys are camelCase and sorted at every nesting level. An optional key without a value is omitted, never `null`. Times are integer `mach_absolute_time` ticks; the app computes no averages. Tick and raw sample values are unsigned 64-bit integers. Counts, CPU numbers, byte sizes, and permille values are integers; booleans are JSON booleans.

## Lines

`run`: `type` (`run`), `schema` (1), `request` (the request as decoded), `build`, `phone`, `conditions`.

The request contains `schema`, `runID`, `attemptID`, `attempt`, `experiment`, `variant`, `seed`, `smoke`, optional `simulation`, `mechanisms`, `operations`, `tunables`, optional `traced` (`true` only in requests from a traced plan; omitted otherwise). Tunables contain `threads`, `qos`, `warmupBatches`, `measuredBatches`, `subBatches`, `operationsPerBatch` (mechanism ID to operations count, with a `default` fallback), `referenceLoopIterations`, optional calibration `repeats`, optional `asyncCode`, optional `priorityInversion`. `asyncCode` (experiment 7, path `fromManyTasks`) has `callsPerTask` (timed calls per task) and `warmupCallsPerTask` (untimed calls per task before the timed ones). `priorityInversion` (experiment 8B) has `holderWorkIterations` (`referenceLoop` iterations the holder runs under the lock), `loadQoS`, `loadMilliseconds`, `mainDelayMicroseconds`, `pauseMilliseconds`, `warmupTrials`, `trials`. QoS is `userInteractive`, `userInitiated`, `default`, `utility`, or `background`. Simulation is `crash` or `hang`, only in smoke runs.

`build`: `buildID`, `commit`, `dirty`, `target` (`ios26` or `ios18`), `minimumOS`, `configuration` (`Release` or `Debug`). The build script embeds metadata before signing. An Xcode build without script metadata uses `unknown` for build ID and commit.

`phone`: `machine`, `osVersion`, `osBuild`, `cpuCount`, `activeCPUCount`, `performanceLevels`, `cacheLineBytes`, `memoryBytes`, `timebaseNumerator`, `timebaseDenominator`, `mainThreadQoSClass`, optional `mutexDefaultPolicy`, optional `ulockAdaptiveSpinMicroseconds`. Each performance level has `index`, `name`, `logicalCPUCount`, `physicalCPUCount`, `l1DataCacheBytes`, `l2CacheBytes`, `cpusPerL2`. Memory is unsigned 64-bit; timebase and QoS class are unsigned 32-bit.

`conditions`: `thermalState` (`nominal`, `fair`, `serious`, `critical`), `lowPowerMode`, `batteryState` (`unknown`, `unplugged`, `charging`, `full`), `batteryLevelPermille` (−1 when unknown), `screenBrightnessPermille`, `debuggerAttached`, `applicationState` (`active`, `inactive`, `background`), `environment` (only watched variables that are set), `ticks`, `wallClock` (ISO 8601 UTC, seconds, such as `2026-11-05T00:00:00Z`).

`reference`: `type` (`reference`), `when` (`start` or `end`), `iterations`, `start`, `end`, `cpuReadings` (before and after).

`block`: `type` (`block`), `block` (position in seeded run order, starting at 0), `mechanism`, `operation`, `threads`, `qos`, `operationsPerBatch`, `start`, `end`, `voluntaryContextSwitches`, `involuntaryContextSwitches`, `taskContextSwitches` (changes over the block), `thermalStateAtStart`, `thermalStateAtEnd`.

`batch`: `type` (`batch`), `block`, `batch` (starting at 0, warm-up batches first), `thread`, `warmup`, `operations`, `start`, `end`, `cpuReadings` (`subBatches + 1` values), optional `executorCPUReadings` (same length).

`samples`: `type` (`samples`), optional `block`, optional `thread`, `metric`, `unit`, `values`, optional `cpuAtStart` and `cpuAtEnd` (each as long as `values`). Values are raw unsigned 64-bit samples.

`trial` (experiment 8B): `type` (`trial`), `block`, `trial` (starting at 0, warm-up trials first), `warmup`, `holderQoS`, the ticks `loadStart`, `loadStop`, `holderAcquire`, `holderRelease`, `mainArrival`, `mainAcquire`, `holderCPUReadings` (CPU numbers on the holder side at acquire and at release), `mainCPU` (CPU number of the main thread after it got the lock), `holderResultCorrect`, `mainObservedTrial` (the value the main thread read under the lock; the holder writes the trial index), `outcome` (`valid`, `censored`, `invalid`).

A trial is `valid` when the main thread arrived while the holder held the lock (`holderAcquire < mainArrival < holderRelease`) and before the load stopped (`mainArrival < loadStop`), and got the lock no later than the load stop (`mainAcquire <= loadStop`). It is `censored` when the main thread arrived the same way but got the lock only after the load stopped (`mainAcquire > loadStop`): the wait is kept and reported apart, never as a measured wait. Every other trial is `invalid`: it is kept and counted, but its wait is never used.

`end`: `type` (`end`), `status` (`completed`, `refused`, `failed`), optional `reasonCode`, optional `reason`, `checks`, `blockLines`, `warmupBatchLines`, `measuredBatchLines`, `conditions` (at the end), `thermalChanges`. Each check has `name`, optional `block`, `passed`, `detail`, optional `violations`. Each thermal change has `ticks`, `thermalState`.

## Order and status

Lines appear in this order: `run`; `reference` at start; for each block its `block` line, then `batch` lines ordered by thread and batch, then `samples` lines, then `trial` lines ordered by `trial`; `reference` at end; `end`. Block timestamps enclose batch timestamps, so a block's end tick is written before the enclosed batches. A refused or invalid attempt has only `run` and `end`.

Refusal reason codes are `thermal`, `lowPower`, `battery`, `debugger`, `applicationState`, `environment`, `configuration`. Failure reason codes are `check`, `invalidRequest`.

### Calibration work and checks

Calibration writes five blocks with operation `""`: `clockSingleThread` (one thread),
`clockAllCPUs`, `cpuSpeedUserInteractive`, and `cpuSpeedBackground` (each using
`phone.cpuCount` threads), and `holderWorkSingleThread` (one thread). Every block
uses QoS `userInteractive` except `cpuSpeedBackground` (`background`). Clock blocks
use metric `clockRead1000`; CPU-speed blocks use `referenceLoop`;
`holderWorkSingleThread` uses `holderWork`. Each block writes one `samples` line
per thread, with unit `ticks` and exactly `tunables.repeats` values, so an attempt
has `2 + 3 × cpuCount` samples lines. `referenceLoop` and `holderWork` samples time
`referenceLoop(iterations: tunables.referenceLoopIterations)` and carry
`cpuAtStart` and `cpuAtEnd`; clock samples carry neither. The core map pools every
`referenceLoop` line, so the holder work keeps its own metric. Calibration writes no
batch lines. Each block owns exactly one `calibration.samples` correctness check
with its block position; there is no separate run-level calibration check.

`bench.py calibrate` writes `results/<phone>/calibration.json` from the accepted
attempt: `attemptID`, `phone` (the run line's phone facts), `coreMap`
(`performance`, `efficiency`, `medianTicksByCPU`) and `priorityInversion`. The
holder work size uses integers only: it keeps the `holderWork` samples whose
`cpuAtStart` equals `cpuAtEnd` and is a performance CPU of the core map (at least
half of all samples, or calibration fails), takes their median ticks, and scales
the measured iterations to 5 ms
(`5_000_000 × timebaseDenominator // timebaseNumerator` ticks).
`priorityInversion` holds `holderWorkIterations`, `targetMilliseconds` (5),
`iterationsMeasured`, `medianTicks` and `samplesUsed`. A plan's
`"holderWorkIterations": "fromCalibration"` is replaced with this integer before
launch; the session records `calibrationAttemptID` in `session.json`, and stops
before installation when the file or its `priorityInversion` is missing.

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
operation is in no allowed pair, or when `fromManyTasks` is requested without `asyncCode`.
Every block uses QoS `tunables.qos` and `operationsPerBatch` for its mechanism. The app
runs `callerPaths` now; `batching` and `isolationSettings` are added with experiments 7B
and 7C.

`callerPaths` blocks:
- `onActor`, `fromBackgroundTask`, `fromMainActor`, `toMainActor`: one task (`threads` 1)
  and the usual `batch` lines. The `actor` and `mainActor` rows carry
  `executorCPUReadings`, except `onActor`, whose loop already runs on the actor.
- `fromManyTasks`: 50 tasks (`threads` 50) and no `batch` lines. Each task makes
  `asyncCode.warmupCallsPerTask` untimed calls, waits once for the others, then times
  `asyncCode.callsPerTask` single calls. The block writes one `samples` line per task:
  `thread` (the task index, 0…49), metric `callTime`, unit `ticks`, `callsPerTask` values,
  no CPU readings.
- `fromMainActor` and `toMainActor` also write two `samples` lines without `thread`:
  metrics `mainThreadCPUAtBatchStart` and `mainThreadCPUAtBatchEnd`, unit `microseconds`,
  one value per batch, warm-up batches first (`warmupBatches + measuredBatches` values).
  A value is the main thread's user plus system CPU time, read just before the batch's start
  tick or just after its end tick.

Each block has one check, `asyncCode.<operation>`, with its block position: the counter's
final value equals `threads × (warmupBatches + measuredBatches) × operationsPerBatch`, or
`50 × (warmupCallsPerTask + callsPerTask)` for `fromManyTasks`.

The attempt checker's `ExpectedAttempt.check_per_block` is the experiment prefix
`baseComparison` (followed by `.<operation>`) or the fixed calibration check name
`calibration.samples`. `run_checks` is empty for both experiments.

## Request validation

Every validation error names the field. `schema` is 1. `runID` and `attemptID` match `^[A-Za-z0-9._-]{1,128}$`. `attempt` is at least 1; `seed` is below 2^53. `threads` is 1…64; `warmupBatches` is at least 0; `measuredBatches` and `subBatches` are at least 1. `operationsPerBatch` has a `default` key and every value is a multiple of `subBatches` and at least `subBatches`. `referenceLoopIterations` is at least 1. When `asyncCode` is present, `callsPerTask` is at least 1 and `warmupCallsPerTask` at least 0. When `priorityInversion` is present, `holderWorkIterations`, `loadMilliseconds` and `trials` are at least 1, `mainDelayMicroseconds`, `pauseMilliseconds` and `warmupTrials` at least 0, and `warmupTrials + trials` fits a signed 64-bit integer. Experiments add their own rules. `simulation` appears only in smoke requests. Decoding does not validate, allowing an invalid decoded request to be included in a failure result.

SplitMix64 and descending Fisher–Yates determine seeded order: for each index from count − 1 to 1, swap with `next() % (index + 1)`.

## Publication

The writer atomically publishes `<attemptID>.jsonl`, then atomically publishes `<attemptID>.done` in the result directory. The marker has `attemptID`, `file`, `bytes`, `sha256` (lowercase hex of the exact JSONL bytes). Both files have sorted keys. A file without its marker is incomplete. Replacing an attempt first removes its old marker. The writer independently rejects an unsafe attempt ID before creating a directory or file, including for invalid decoded requests.

`Tests/Fixtures/golden-base-comparison.jsonl` fixes the writer/checker contract. It uses the one-thread request with seed 7, one mutex increment block, one warm-up and two measured batches of four operations, and the check `expected 12, got 12`. Phone facts and conditions are fixed fictional values. Tests compare bytes against this reviewed fixture and never rewrite it.
