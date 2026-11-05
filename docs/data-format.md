# Result data format

Schema 1 uses UTF-8 JSON Lines: one object per line, with a final newline. Keys are camelCase and sorted at every nesting level. An optional key without a value is omitted, never `null`. Times are integer `mach_absolute_time` ticks; the app computes no averages. Tick and raw sample values are unsigned 64-bit integers. Counts, CPU numbers, byte sizes, and permille values are integers; booleans are JSON booleans.

## Lines

`run`: `type` (`run`), `schema` (1), `request` (the request as decoded), `build`, `phone`, `conditions`.

The request contains `schema`, `runID`, `attemptID`, `attempt`, `experiment`, `variant`, `seed`, `smoke`, optional `simulation`, `mechanisms`, `operations`, `tunables`. Tunables contain `threads`, `qos`, `warmupBatches`, `measuredBatches`, `subBatches`, `operationsPerBatch` (mechanism ID to operations count, with a `default` fallback), `referenceLoopIterations`, optional calibration `repeats`. QoS is `userInteractive`, `userInitiated`, `default`, `utility`, or `background`. Simulation is `crash` or `hang`, only in smoke runs.

`build`: `buildID`, `commit`, `dirty`, `target` (`ios26` or `ios18`), `minimumOS`, `configuration` (`Release` or `Debug`). The build script embeds metadata before signing. An Xcode build without script metadata uses `unknown` for build ID and commit.

`phone`: `machine`, `osVersion`, `osBuild`, `cpuCount`, `activeCPUCount`, `performanceLevels`, `cacheLineBytes`, `memoryBytes`, `timebaseNumerator`, `timebaseDenominator`, `mainThreadQoSClass`, optional `mutexDefaultPolicy`, optional `ulockAdaptiveSpinMicroseconds`. Each performance level has `index`, `name`, `logicalCPUCount`, `physicalCPUCount`, `l1DataCacheBytes`, `l2CacheBytes`, `cpusPerL2`. Memory is unsigned 64-bit; timebase and QoS class are unsigned 32-bit.

`conditions`: `thermalState` (`nominal`, `fair`, `serious`, `critical`), `lowPowerMode`, `batteryState` (`unknown`, `unplugged`, `charging`, `full`), `batteryLevelPermille` (−1 when unknown), `screenBrightnessPermille`, `debuggerAttached`, `applicationState` (`active`, `inactive`, `background`), `environment` (only watched variables that are set), `ticks`, `wallClock` (ISO 8601 UTC, seconds, such as `2026-11-05T00:00:00Z`).

`reference`: `type` (`reference`), `when` (`start` or `end`), `iterations`, `start`, `end`, `cpuReadings` (before and after).

`block`: `type` (`block`), `block` (position in seeded run order, starting at 0), `mechanism`, `operation`, `threads`, `qos`, `operationsPerBatch`, `start`, `end`, `voluntaryContextSwitches`, `involuntaryContextSwitches`, `taskContextSwitches` (changes over the block), `thermalStateAtStart`, `thermalStateAtEnd`.

`batch`: `type` (`batch`), `block`, `batch` (starting at 0, warm-up batches first), `thread`, `warmup`, `operations`, `start`, `end`, `cpuReadings` (`subBatches + 1` values), optional `executorCPUReadings` (same length).

`samples`: `type` (`samples`), optional `block`, optional `thread`, `metric`, `unit`, `values`, optional `cpuAtStart` and `cpuAtEnd` (each as long as `values`). Values are raw unsigned 64-bit samples.

`end`: `type` (`end`), `status` (`completed`, `refused`, `failed`), optional `reasonCode`, optional `reason`, `checks`, `blockLines`, `warmupBatchLines`, `measuredBatchLines`, `conditions` (at the end), `thermalChanges`. Each check has `name`, optional `block`, `passed`, `detail`, optional `violations`. Each thermal change has `ticks`, `thermalState`.

## Order and status

Lines appear in this order: `run`; `reference` at start; for each block its `block` line, then `batch` lines ordered by thread and batch, then `samples` lines; `reference` at end; `end`. Block timestamps enclose batch timestamps, so a block's end tick is written before the enclosed batches. A refused or invalid attempt has only `run` and `end`.

Refusal reason codes are `thermal`, `lowPower`, `battery`, `debugger`, `applicationState`, `environment`, `configuration`. Failure reason codes are `check`, `invalidRequest`.

### Calibration work and checks

Calibration writes four blocks with operation `""`: `clockSingleThread` (one thread),
`clockAllCPUs`, `cpuSpeedUserInteractive`, and `cpuSpeedBackground` (each using
`phone.cpuCount` threads). Clock blocks use metric `clockRead1000`; CPU-speed
blocks use `referenceLoop`. Each block writes one `samples` line per thread,
with unit `ticks` and exactly `tunables.repeats` values. Calibration writes no
batch lines. Each block owns exactly one `calibration.samples` correctness check
with its block position; there is no separate run-level calibration check.

The attempt checker's `ExpectedAttempt.check_per_block` is the experiment prefix
`baseComparison` (followed by `.<operation>`) or the fixed calibration check name
`calibration.samples`. `run_checks` is empty for both experiments.

## Request validation

Every validation error names the field. `schema` is 1. `runID` and `attemptID` match `^[A-Za-z0-9._-]{1,128}$`. `attempt` is at least 1; `seed` is below 2^53. `threads` is 1…64; `warmupBatches` is at least 0; `measuredBatches` and `subBatches` are at least 1. `operationsPerBatch` has a `default` key and every value is a multiple of `subBatches` and at least `subBatches`. `referenceLoopIterations` is at least 1. `simulation` appears only in smoke requests. Decoding does not validate, allowing an invalid decoded request to be included in a failure result.

SplitMix64 and descending Fisher–Yates determine seeded order: for each index from count − 1 to 1, swap with `next() % (index + 1)`.

## Publication

The writer atomically publishes `<attemptID>.jsonl`, then atomically publishes `<attemptID>.done` in the result directory. The marker has `attemptID`, `file`, `bytes`, `sha256` (lowercase hex of the exact JSONL bytes). Both files have sorted keys. A file without its marker is incomplete. Replacing an attempt first removes its old marker. The writer independently rejects an unsafe attempt ID before creating a directory or file, including for invalid decoded requests.

`Tests/Fixtures/golden-base-comparison.jsonl` fixes the writer/checker contract. It uses the one-thread request with seed 7, one mutex increment block, one warm-up and two measured batches of four operations, and the check `expected 12, got 12`. Phone facts and conditions are fixed fictional values. Tests compare bytes against this reviewed fixture and never rewrite it.
