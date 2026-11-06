# Harness design

Date: 2026-11-05. Status: approved by Ivan on 2026-11-05 (milestone 6 done). Before approval it was read by a fresh agent as a builder on 2026-11-05, and its five questions are answered in the text; cross-checked by Codex on 2026-11-05, and its seven findings are applied with Ivan's approval (the cross-check notes stay with the study notes). Copied into this repository on 2026-11-05 (milestone 7); this copy is the one to keep current. References to reports A–M and to local checks point to the study notes, which are not part of this repository.

The experiments themselves are specified in `docs/experiments.md`. This document describes only the tool that runs them.

## Why

We need raw, checkable data for the seven approved experiments (1, 2, 3, 4, 7, 8, 9) from two real iPhones. Readers must be able to see how each number was made and to run the code themselves.

Goals:
- Measure on a real iPhone, in a Release build, with no debugger.
- Give every mechanism the same work, and check the result after every run.
- Record the conditions of every run.
- Run for hours without a person, for example overnight.
- Keep every raw sample, so others can redo the analysis.

Non-goals: energy measurement (Ivan's decision); a general benchmark framework; timed results from the Simulator or a Mac (smoke tests only); statistics and charts (milestone 11).

The harness fails, even if it works, when:
- a difference between mechanisms comes from the harness and not from the mechanism (thread start-up inside the timed part, an allocation in one wrapper only, a different call path);
- runs from different iOS builds, toolchains or code versions get mixed;
- a failed or refused run disappears without a trace;
- a reader cannot follow how a number was made.

## Constraints

- Toolchain frozen: Xcode 27.1 (27A9275), swiftlang-6.4.0.34.1.
- Phones stay on their installed OS: iPhone 11 Pro Max (A13, 60 Hz), iOS 26.6 (23G71); iPhone 15 Pro Max (A17 Pro, 120 Hz), iOS 26.6.2 (23G90). Automatic OS updates are disabled. Do not update either phone; a shared iOS 27.x build is not required.
- Free Personal Team (Apple, "About your developer account", read 2026-11-05): provisioning profiles expire 7 days after issue, so we rebuild weekly; up to 3 apps per phone; up to 10 App IDs and up to 3 devices, each expiring after 7 days. One manual Trust per certificate on each phone (2026-10-29).
- No debugger: launch with `xcrun devicectl device process launch` without `--console` (`P_TRACED` false, checked 2026-10-29).
- Copy result files one at a time; directory copies have timed out (report E).
- Without a debugger the watchdog is active: the main thread must never block for long (the scene-update kill comes at 10 s, report L).
- The public repository must not contain the team ID, Apple IDs or phone UDIDs.

## Approaches

1. **One app plus a Mac run script. Chosen by Ivan on 2026-11-05.** One iOS app holds all seven experiments. The script builds and installs it and starts one run at a time with `devicectl`; a launch argument selects the experiment. The whole pipeline was proven on 2026-10-29. Cost: we write the timing and thread code ourselves.
2. **XCTest `measure` on the device.** A standard tool, but raw samples stay inside `.xcresult`, the tests run inside the test-runner process, and experiment 8 (main thread with scrolling) cannot run there. It may return later only as an optional "reproduce in Xcode" check for one or two headline numbers.
3. **Manual runs started from a button on the phone.** No script, but each of hundreds of runs needs a person, and nothing checks the conditions between runs.

Also rejected: one app per experiment. It duplicates the shared code and multiplies builds and signing. It gives no extra isolation, because every run already gets a fresh process.

## Repository

`swift-synchronization-benchmarks`, in Ivan's local `Developer` folder (name and place: Ivan). A new git repository; it becomes public on GitHub with the Habr article (milestone 12).

```
project.yml        XcodeGen spec; the .xcodeproj is generated and not committed
local.example.json template for local.json (team ID, bundle ID prefix, phone names
                   and UDIDs); local.json itself is not committed
App/               app shell: launch arguments, run controller, minimal UI
Harness/           timing, threads, conditions, result writer, calibration
Mechanisms/        one wrapper per mechanism with the operations the experiments need
Experiments/       one folder per experiment, named after it (BaseComparison/, HotFlag/, ...)
IsolationProbe/    one source file compiled into IsolationProbeTemplate and
                   IsolationProbeSwift6 static libraries (experiment 7C)
scripts/bench.py   the Mac script
plans/             run plans
results/           raw data and run state; not in git (see "Open")
docs/              method notes, this design, notes from the build checks
```

`App/`, `Harness/`, `Mechanisms/` and `Experiments/` are one module, the app target. So the measured loop and the lock wrapper compile together, as in a typical app. Only the two experiment-7C libraries have different settings, on purpose.

## The app

Build:
- One app target, UIKit life cycle, iPhone only. Release, `-O`, whole-module. Exclusivity checking stays at its Release default; never `-Ounchecked`.
- Measure ordinary Swift application code with standard Release exclusivity enforcement. Do not use `@exclusivity(unchecked)`. Harness wrappers must not add costs absent from ordinary code using the same mechanism. Base comparison uses concrete queue counters with direct `read`, `write`, and `increment` bodies inside queue closures, never a generic `body(&state)` for their integer storage.
- Each experiment owns its wrapper declarations. The existing `Mechanisms/` wrappers are base-comparison-owned; future experiments must declare their state wrappers in their own experiment directories. Do not instantiate a base-comparison generic wrapper with dictionaries or other state types for another experiment: its stored property declaration is shared across specializations, which can change exclusivity optimization even for the existing Int row. Common clocks, thread infrastructure, and result types remain shared.
- App module: Swift 6 language mode, default isolation `nonisolated`, Approachable Concurrency off. Isolation is written in the code (`nonisolated`, `@MainActor`, `@concurrent`, `Task.detached`), so hop counts do not depend on inference.
- UIKit types (`UIViewController`, `UIView`, the app and scene delegates) are `@MainActor`. Code inside them runs on the main thread, and a `Task {}` written there inherits the main actor. So experiment code lives in the harness's own nonisolated types, and a run leaves the main thread explicitly: on its own pthread or in `Task.detached`.
- Experiment 7C: the same source file in `IsolationProbe/` compiles into the static libraries `IsolationProbeTemplate` (Swift 5 mode, Approachable Concurrency, default isolation `MainActor`, the other template settings listed in `docs/experiments.md`) and `IsolationProbeSwift6` (the app module's Swift 6 settings). The `@concurrent` variant lives in `IsolationProbeTemplate`. Never pass `SWIFT_*` settings on the `xcodebuild` command line: they would override both libraries. The build script records each library's settings in `build-info.json`. For the template library, `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT` and `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES` remain unset and appear as `""` in that file because `-showBuildSettings` omits their derived defaults. They follow `SWIFT_APPROACHABLE_CONCURRENCY`; the compiler enables both features.
- Two builds from the same code, one bundle ID: deployment target iOS 26.0 (main) and iOS 18.0. The iOS 18 build runs only the rows whose code changes with the target: `Atomic` and `ManagedAtomic`, plus `Mutex` as an unchanged reference. It runs them in experiment 1, including part B (under contention LL/SC and LSE are expected to differ most; a hypothesis), and in experiment 3. Code that needs iOS 26 stays out of this build. The script installs the build that the next block of runs needs.
- Info.plist: `CADisableMinimumFrameDurationOnPhone = YES`, so the 15 Pro Max can run at 120 Hz; file sharing on, as a manual fallback.

One run inside the app:
1. Read the launch arguments: experiment, variant, run ID, attempt ID (new for every launch), seed, and the tunables (batch size, warm-up and measured batch counts, durations). The plan holds the tunables, so the pilot can change them without a rebuild. With no arguments the app shows an idle screen and does nothing.
2. Wait until the first frame is on screen. Never do work during launch.
3. Preflight: record the conditions. If a hard condition fails, refuse the run (see "Checks").
4. Reference loop: time a fixed CPU loop at the start and at the end of the run, to see frequency drift.
5. The experiment: blocks (mechanism × operation) in a random order from the seed. Each block has warm-up batches, then measured batches. One `os_signpost` interval per block, so Instruments traces line up with the data.
6. Correctness. Checks of the final state run outside the timed code. Checks of what a reader saw (experiments 4 and 8A) run inside the loop: each read checks its own observation and adds to a per-thread violation counter. The same check code runs for every mechanism. The counters are evaluated here.
7. Write `runs/<attempt-id>.jsonl` with a final `end` line, then the marker `runs/<attempt-id>.done`, then exit. The app writes the `end` line and the marker in every case it controls: a completed run, a refused run, a failed check.

Rules for timed code:
- Clock: `mach_absolute_time()` ticks; the timebase goes into the file. One tick is about 41.67 ns on A13.
- The cost of an operation comes from batches. Where a spec asks for a distribution, single operations or small groups are timed with the same clock: 2 (sampled waits), 3 (groups of 100 reads), 4 (each 20-record transaction, groups of 100 one-record reads, each write until it is done, writer waits), 7A path 3 (each call), 8A (each main-thread read), 8B (each trial). For an async `.barrier` write, the caller records the submission time and the write block records its own end time. A value of one or two ticks is below the timer's resolution; the analysis reports it as such, not as nanoseconds. Calibration measures the clock-read cost that goes with these numbers.
- The harness adds no I/O, logging or allocation inside the timed part. Allocations that belong to a mechanism, such as a block per `async` call, are part of its cost. Samples go to preallocated buffers; the file is written at the end.
- An opaque sink: `@_optimize(none)` `blackHole` (an underscored attribute; the method text says so).
- Create locks and state before the timed part. Experiment 9 times creation on purpose.
- Threads: pthreads with a declared QoS, started together from one barrier. Each thread reads its CPU number (`pthread_cpu_number_np`) at the start and end of each batch and at a few fixed points inside it, between sub-batches. The call returns the CPU at that moment only. A batch is labelled P or E only when all its readings agree; otherwise it is "mixed". This is an observation, not measured residency; traces check it. Where the work runs on another thread (async `.barrier` writes, actors, `@MainActor`), the executing side also records CPU readings. Synchronous read batches omit executor probes and pending-write drains: their reads already finish on the caller, and instrumentation barriers would alter read concurrency. Final correctness reads remain outside timing and wait for pending writes. The Swift concurrency pool is used only where tasks and actors are the subject: the actor row of experiment 1, experiment 7, the main-actor variant of 8A, the actor in 8B.
- The UI does not change during timed parts, except the scrolling in 8A.
- The main thread never waits without a limit. In 8B the load threads stop after a fixed time, so no wait can come near the watchdog limit.

Notes on single experiments:
- The `.barrier` queue has two rows wherever it appears: experiments 1, 3, 4 and 8A (Ivan, 2026-11-05). Reads use `sync` in both rows.
  - "sync write": writes and increments use `sync(flags: .barrier)`. This is the contract of a lock: the write is done when the call returns (Swiftfin, bitchat).
  - "async write": writes and increments use `async(flags: .barrier)` (Firefox, Apollo 1.x). Timing runs to completion: a batch ends after a `sync` that waits for all queued writes, and the correctness check waits the same way.
  - In the local corpus of 25 open-source iOS apps, only 3 use `.barrier` at all (checked 2026-11-05).
- 1: `@MainActor` is a row, called like the actor: a background task, one `await` per operation (the same path as 7A path 5). The batch size is a tunable per row, because the actor and main-actor rows are much slower than locks.
- 8A: a `UICollectionView` that a `CADisplayLink` scrolls by a fixed step per frame. The app draws the images at start; no network.
- 8B: the holder acquires the lock and starts its work first; then the controller starts the load threads, and the main thread targets arrival 1 ms after the holder acquired. Acquiring before starting the load gives the low-QoS holder a chance to take the lock while the CPUs are free. The work size (iterations for about 5 ms on an idle performance core) comes from calibration. Each trial records timestamps: load start and stop, holder acquire and release, main arrival and acquire. A trial is valid only when main arrives while the holder holds the lock and the load is still running, and acquires no later than the load stop. A wait that runs past the load stop is censored: it is kept and reported apart, not as a measured wait. Other trials are invalid and kept for counting.
- 9: all other threads are idle while the app reads the malloc statistics. `@MainActor` stays in, as approved. Its objects are created and destroyed on the main thread, as UIKit code does. Its extra memory per object is expected to be zero; that is itself a result for the memory-versus-speed table (no memory, but each access from another thread needs a hop, experiment 1).

Calibration mode (once per phone, milestone 8): timebase; clock-read cost, alone and while all cores read the clock; `hw.*` values and the cache line size; the mapping of CPU numbers to P and E cores; the achieved display rate; the 8B work size from block `holderWorkSingleThread`; `qos_class_main()`; the default `pthread_mutex` policy.

Smoke mode: tiny tunables, for checking all experiments end to end during development. Smoke runs are marked `smoke` and never analysed.

## The Mac script

`scripts/bench.py`: Python 3, standard library only, so readers install nothing extra. Commands:
- `doctor`: the Xcode build and `swiftc` version match the frozen ones; XcodeGen is installed; the phone is connected, unlocked and in Developer Mode. It compares the phone's installed iOS build with the plan's `iosBuilds` entry for that phone key; a smoke plan may omit the pin.
- `build --target ios26|ios18`: `xcodegen generate`, then `xcodebuild` Release with `-allowProvisioningUpdates`. Before compiling, it puts a build ID into the app as a generated source file: git commit, clean or dirty tree, target. After the build, it writes `build-info.json` next to the results, never into the signed app: the build ID, Xcode and Swift versions, deployment target, key build settings, a hash of the executable code with the signature removed, the profile expiry date.
- `calibrate --phone <name>`: runs the calibration mode and saves the phone facts.
- `run --phone <name> --plan <file>`: runs a plan (below).
- `status --plan <file>`: what is done, what failed, what is left.

How `run` works:
1. Refuse to start if `doctor` fails or if the profile expires before the planned end of the session.
2. Install the build the block needs, then wait a settle time.
3. For each pending run, in the plan's seeded random order:
   - give the launch a new attempt ID;
   - check with `devicectl device info lockState` that the phone is unlocked;
   - launch with `devicectl device process launch` (no `--console`) and the run arguments; read the PID from its JSON output (`--json-output`);
   - wait for the app to exit with `devicectl device process awaitTermination --pid <pid>` and a time limit. If that does not work, check the process list rarely, starting after the expected run time;
   - copy the result file and the `.done` marker, one file at a time;
   - check the file; write one line to the session log; pause; next run.
4. The status comes from the `end` line: `completed`, `refused` or `failed`. If the app is still alive after the time limit, terminate it and mark the attempt `timeout`. If it exited without `.done`, mark it `crashed` and copy the crash report (`devicectl device copy from --domain-type systemCrashLogs`). Copy the original `.ips` bytes and filename directly into the session's `crash/<attempt ID>/` folder, without redaction, a separate private copy, or provenance sidecars.
5. After a thermal refusal, wait and start a new attempt of the same run. Each run gets an initial attempt plus at most `maxThermalRetries` thermal retries per session; exhaustion stops that session. A fresh session gets a fresh thermal allowance, and doctor budgets it for every pending run. Thermal refusals do not count toward ordinary `maxAttempts`. Any other refusal stops the session. Every attempt and its files are kept, with attempt numbers increasing across sessions.

The run state is saved after every run under `results/`, so a stopped session continues from the next run, and a running session does not make the git tree dirty. State identity includes plan, phone, code hash, and build eligibility: dirty builds use a `--dev.json` suffix and clean builds use `--clean.json`. Run, doctor, status, and calibration lookup use this same namespace. Accepted dev work never completes a clean campaign. Legacy files without an eligibility suffix are retained unchanged but not credited, because their eligibility is unknown; a fresh run is required. New attempt records include `buildID` and `dev` provenance. The script runs under `caffeinate`, so the Mac does not sleep. After a weekly rebuild, the same code hash keeps runs comparable; a different hash means a new build ID. For a plan with `"traced": true`, the script records System Trace of all processes around each attempt, starting before app launch and stopping after app exit or termination. It writes `<session>/traces/<attemptID>.trace` under ignored `results/`. These files contain device names and identifiers and are never shared, committed or published. Traced runs stay separate from timed measurement data.

A traced attempt completes only when the app is accepted and the recorder remains alive until the requested stop, then exits with status zero after SIGINT within the 300-second flush allowance. An early exit (including status zero), nonzero finalization, or forced kill is a trace failure. The runner still copies and checks the app result, saves the original app verdict and artifacts, records `traceFailed`, and stops the session. Trace failures do not consume `maxAttempts`; repeating the ordinary `run` command retries with a new attempt ID and trace path, even with `maxAttempts: 1`. This validates recorder completion, not trace contents. Existing attempt history is retained unchanged.

## Data format

One JSON Lines file per attempt (one launch), raw values only; the app computes no averages. On the Mac: `results/<phone>/<session-id>/<attempt-id>.jsonl`, plus `session.json` per session (phone, iOS build, build info, plan, start and end times, notes such as the restart time).

- First line, `run`: schema version, run ID, attempt ID, build ID, experiment, variant, seed, tunables, phone (model, iOS build, cores, cache line size, timebase), conditions at start.
- `block`, one per mechanism × operation: start and end ticks, context-switch counts (`getrusage` and `task_info`; check them once against System Trace), thermal state.
- `batch`: block reference, threads, QoS, warm-up or measured, operation count, ticks, CPU readings (start, inside, end; executor side where it differs).
- `samples`: block reference, metric (for example `wait`, `frame_gap`), unit, an array of raw values.
- `trial` (8B): one line per trial: holder QoS; timestamps of load start and stop, holder acquire and release, main arrival and acquire; holder CPU readings; valid or censored.
- `memory` (9): malloc statistics before and after, per mechanism and object count.
- Last line, `end`: status (`completed`; `refused` with a reason; `failed` with a reason), correctness results including the violation counters, the numbers of blocks and batches written, conditions at end, thermal changes during the run.

A file without an `end` line is an incomplete attempt. Times are integer ticks; the analysis converts them to nanoseconds.

## Checks

1. Session (script, before the first run): frozen toolchain; the phone on the planned iOS build; the installed build came from a clean git tree (a dirty tree marks runs `dev`, and the analysis drops them); the profile is valid until the planned end.
2. Run preflight (app): Release build; no debugger (`P_TRACED`, checked at the start and again at the end of the run, so a tool that attaches later is caught too); thermal state `.nominal`; Low Power Mode off; battery charging or full; app active; the `PTHREAD_MUTEX_*` environment variables unset. On failure the app writes the `run` line, an `end` line with status `refused` and the reason, and the `.done` marker, then exits.
3. Correctness (app), from the approved specs. Reader-side checks count violations inside the loop; the others run after the timed part:
   - 1 and 7: the final value equals the expected value;
   - 2: the dictionary ends empty;
   - 3: the reader sees the last written value;
   - 4: every read transaction saw one version inside its group (violation counter at zero);
   - 8A: no main-thread read saw a half-written entry (violation counter at zero);
   - 8B: the holder finished its work in every trial, no trial is missing, and the share of valid trials is reported;
   - 9: every object is freed (deinit count), and repeated create-and-free cycles show no growth.
4. File (script, after the copy): valid JSON Lines; an `end` line; the `run` line matches the launch request (run ID, attempt ID, build ID, experiment, variant, seed, tunables); the numbers of blocks and measured batches match what the tunables imply; all checks passed; good conditions at start and end; the `.done` marker names the same attempt and the file's hash. The attempt is accepted, or rejected with a reason. Rejected attempts stay on disk and are counted in the report.
5. Build (by hand, once per build; notes in `docs/`): inspect Release disassembly for every measured row and verify that its intended per-operation work survives optimization. `withLock` is inlined, atomics are LSE or LL/SC as the deployment target predicts, and the harness adds no allocation to the measured loops. If the compiler hoists or folds away required work, change the workload to give each operation an observable consumer or use an explicit, narrowly scoped noinline boundary; document the choice and its measured costs. Check caller paths and async continuations as well as operation bodies. The [operation-preservation check](build-checks/2026-11-operation-preservation.md) records the current experiment-1 and experiment-7 evidence, including ordinary async-frame costs for the deliberately noninlined `onActor` method.

Code that does no timing (plan expansion, the file check, the result writer) gets unit tests. The file check is tested with broken files: an inconsistent read, a missing batch, another build ID, a refused run, a missing `end` line; each must be rejected or classified correctly. The timing code is checked by calibration and by the correctness checks.

## Run protocol

- A session is a block of runs on one phone, for example one night. Before it: restart and unlock the phone; it is on the cable, Auto-Lock is "Never", Do Not Disturb is on, the brightness is fixed. Phone preparation (milestone 8) gives the full list. `devicectl device reboot` exists; phone preparation also checks whether a session can start after it without a person at the lock screen.
- A settle time after the restart and after each install; the pilot sets its length.
- Inside a session, runs of different experiments are mixed in a seeded random order. Runs that need the other build form their own block.
- Order of work: harness core and calibration; then experiment 1 end to end (app, script, file, checks); then 7 and 8B; then 2, 3, 4, 8A and 9.
- The pilot (milestone 9) sets batch sizes, warm-up, pauses, runs per experiment and the estimator. Values in the first plans are guesses and are marked so.
- The pilot also checks that 8B trials overlap (holder, main thread, load). If the gap between the `os_unfair_lock` and `DispatchSemaphore` references disappears once invalid trials are removed, 8B cannot answer the `NSLock` question.

## Who decided what

Ivan: one app plus a Mac script; the repository name and place; public with the Habr article; the frozen toolchain; the two phones; deployment targets iOS 26 (main) and iOS 18 (experiments 1 and 3); no energy measurement; the experiment specs; two `.barrier` rows (sync and async writes).

Agent's calls, open to correction: Python with the standard library for the script; XcodeGen; UIKit; Swift 6 mode with explicit isolation for the app module; one bundle ID for both builds; one run per app launch; JSON Lines with integer ticks; tunables as launch arguments; a local, uncommitted config for personal identifiers; the session protocol; `results/` outside git for now. After the builder check: only `Atomic`, `ManagedAtomic` and a `Mutex` reference in the iOS 18 build; `@MainActor` as a row in experiment 1, called like the actor; single-operation timing where a spec asks for a distribution, with the resolution limit stated. Cross-check fixes (all seven approved by Ivan on 2026-11-05): per-transaction and per-write timing for experiment 4; in-loop reader checks; a status in the `end` line and attempt IDs; the file check against the launch request; CPU readings inside batches; valid and censored 8B trials; the build ID embedded before signing.

## Left to the builder

Type and field names; batch sizes and time limits until the pilot; the idle screen; the plan file format; the exact `devicectl` flags. Checked in its help on 2026-11-05: `process launch` passes the arguments that follow the bundle ID and has `--environment-variables`; `process awaitTermination` needs `--pid` and takes the global `--timeout`; `copy from` accepts `--domain-type systemCrashLogs`; `process terminate`, `info processes`, `info lockState` and `reboot` exist.

## Open (does not block milestone 7)

- Where raw data lives at publication: git, Git LFS or a release archive. Until then `results/` is outside git and needs a backup.
- Whether to push to a private GitHub repository before publication, as a backup.
