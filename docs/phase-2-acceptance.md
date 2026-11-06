# Phase 2 device acceptance

On 2026-11-05, clean source `44400779a6c9` passed calibration, async-code
acceptance and the priority-inversion reference gate on both physical phones.
The iphone15 base regression passed all four attempts. Both prescribed traced
workloads have accepted app results and usable, exportable traces after one
explicitly recorded async trace retry.

These plans use `smoke: true`. This is functional acceptance and a short check
of the experiment's references, not campaign timing data or a mechanism ranking.
The two [signed builds and disassembly checks](build-checks/2026-11-phase-2.md)
record provenance and compiler behavior. No OS update or device setting change
was performed.

## Phones and calibration

| Phone key | Model | Installed iOS | Build | Performance / efficiency CPUs | Holder work iterations | Usable samples |
| --- | --- | --- | --- | --- | ---: | ---: |
| iphone11 | iPhone 11 Pro Max (`iPhone12,5`) | 26.6.0 | 23G71 | `[4, 5]` / `[0, 1, 2, 3]` | 2,218,115 | 200/200 |
| iphone15 | iPhone 15 Pro Max (`iPhone16,2`) | 26.6.2 | 23G90 | `[4, 5]` / `[0, 1, 2, 3]` | 3,149,606 | 200/200 |

The work sizes target 5 ms on an idle performance CPU. The 100,000-iteration
holder calibration medians are 5,410 and 3,810 ticks respectively; both phones
record a 125/3 ns timebase. Core maps match phase 1. Both builds have exact
stripped-executable SHA-256
`0cea7fddd50f2bee7c9030c07e8622d34e48781956caedbc5003673fcc1b6ea7`;
all sessions use clean build `44400779a6c9-clean-ios26-20261105T123656Z`.

## Sessions and correctness

Session folders remain under ignored `results/<phone>/<session ID>/`.

| Phone | Check | Session ID | Outcome |
| --- | --- | --- | --- |
| iphone11 | Calibration | `20261105T123718Z.calibration.16b509da` | 1 accepted |
| iphone15 | Calibration | `20261105T123718Z.calibration.3ed7ddf8` | 1 accepted |
| iphone11 | Async code | `20261105T123836Z.acceptance-async-code.6f8ffba8` | 3 accepted |
| iphone15 | Async code | `20261105T123836Z.acceptance-async-code.40cb9dbe` | 3 accepted |
| iphone11 | Priority inversion | `20261105T124058Z.acceptance-priority-inversion.d75fb8fc` | 1 accepted; reference gate passed |
| iphone15 | Priority inversion | `20261105T124407Z.acceptance-priority-inversion.65ddf3c6` | 1 accepted; reference gate passed |
| iphone15 | Initial traced async | `20261105T124714Z.traced-async-code.43dfde84` | App accepted; disconnected trace, not credited |
| iphone15 | Traced priority inversion | `20261105T124818Z.traced-priority-inversion.0c76e931` | 1 accepted; useful trace, export passed |
| iphone15 | Base regression | `20261105T125250Z.acceptance-base-comparison.54f4b414` | 4 accepted |
| iphone15 | Diagnostic traced async retry | `20261105T125636Z.traced-async-code.80bf9f37` | 1 accepted; useful trace, export passed |

Every session has zero rejected/refused app attempts and no stop reason. All 17
completed JSONL/marker pairs were independently rechecked against their recorded
request, build ID and each phone's known installed OS build: 17 accepted. Every
result records active application state, nominal thermal state and no debugger
at both endpoints. A later device crash-log query found zero SyncBench reports
newer than the respective priority-inversion session starts; both priority runs
published normal completed results, with all 28 block correctness checks passing.

Both async sessions pass `callerPaths`, `batching` and `isolationSettings`.
For each phone, the `callFromMainActor` checks report 1,200 calls in every row:
all 1,200 template calls run on main, and zero Swift 6 or `@concurrent` calls run
on main. These checks establish where the probe body ran; they do not count
every executor handoff in a full call.

## Priority inversion (8B)

Each block has ten measured trials plus one warm-up. The table excludes warm-up
trials. Counts are valid/censored/invalid; medians use only valid
`mainAcquire - mainArrival` values converted from integer ticks on the host.
Censored trials remain in the raw files and are not treated as measured waits.

| Mechanism | Holder | iphone11 counts | Median ms | iphone15 counts | Median ms |
| --- | --- | --- | ---: | --- | ---: |
| actor | backgroundHolder | 10/0/0 | 15.170 | 10/0/0 | 16.694 |
| actor | utilityHolder | 10/0/0 | 10.903 | 10/0/0 | 14.229 |
| barrierQueueAsyncWrite | backgroundHolder | 10/0/0 | 6.245 | 10/0/0 | 6.099 |
| barrierQueueAsyncWrite | utilityHolder | 10/0/0 | 5.911 | 10/0/0 | 6.101 |
| barrierQueueSyncWrite | backgroundHolder | 10/0/0 | 9.927 | 3/7/0 | 121.542 |
| barrierQueueSyncWrite | utilityHolder | 10/0/0 | 9.996 | 9/1/0 | 18.072 |
| dispatchSemaphore | backgroundHolder | 10/0/0 | 11.116 | 4/6/0 | 45.974 |
| dispatchSemaphore | utilityHolder | 10/0/0 | 9.154 | 10/0/0 | 30.976 |
| mutex | backgroundHolder | 10/0/0 | 5.757 | 10/0/0 | 6.083 |
| mutex | utilityHolder | 10/0/0 | 5.839 | 10/0/0 | 6.078 |
| nsLock | backgroundHolder | 10/0/0 | 6.071 | 10/0/0 | 6.126 |
| nsLock | utilityHolder | 10/0/0 | 5.897 | 10/0/0 | 6.081 |
| nsRecursiveLock | backgroundHolder | 10/0/0 | 5.942 | 10/0/0 | 6.096 |
| nsRecursiveLock | utilityHolder | 10/0/0 | 5.807 | 10/0/0 | 6.098 |
| objcSync | backgroundHolder | 10/0/0 | 5.780 | 10/0/0 | 6.098 |
| objcSync | utilityHolder | 10/0/0 | 5.817 | 10/0/0 | 6.112 |
| osAllocatedUnfairLock | backgroundHolder | 10/0/0 | 6.095 | 10/0/0 | 6.107 |
| osAllocatedUnfairLock | utilityHolder | 10/0/0 | 5.760 | 10/0/0 | 6.084 |
| osAllocatedUnfairLockAdaptiveSpin | backgroundHolder | 10/0/0 | 5.959 | 10/0/0 | 6.094 |
| osAllocatedUnfairLockAdaptiveSpin | utilityHolder | 10/0/0 | 5.715 | 10/0/0 | 6.120 |
| osUnfairLock | backgroundHolder | 10/0/0 | 6.104 | 10/0/0 | 6.086 |
| osUnfairLock | utilityHolder | 10/0/0 | 5.781 | 10/0/0 | 6.084 |
| pthreadMutex | backgroundHolder | 10/0/0 | 5.753 | 10/0/0 | 6.132 |
| pthreadMutex | utilityHolder | 10/0/0 | 5.814 | 10/0/0 | 6.085 |
| pthreadReadWriteLock | backgroundHolder | 10/0/0 | 9.992 | 8/2/0 | 49.281 |
| pthreadReadWriteLock | utilityHolder | 10/0/0 | 8.952 | 10/0/0 | 21.577 |
| serialQueue | backgroundHolder | 10/0/0 | 5.711 | 10/0/0 | 6.101 |
| serialQueue | utilityHolder | 10/0/0 | 5.916 | 10/0/0 | 6.087 |

iphone11's 28 warm-ups are all valid; iphone15 has 27 valid and one censored
warm-up. No measured trial is invalid. All iphone11 measured trials are valid;
iphone15 has 264 valid and 16 censored measured trials.

Both phones pass the explicit reference gate. Their utility-holder
`osUnfairLock` blocks have 10/10 valid trials. On iphone11 its valid waits span
5.618–6.389 ms, versus 8.531–10.657 ms for `DispatchSemaphore`; on iphone15 the
ranges are 6.044–6.114 ms and 12.733–51.277 ms. Background-holder valid reference
ranges are also disjoint. No tunable was changed to obtain this result. The
iphone15 background semaphore median is conditional on only four valid trials;
six are censored, so that median alone understates the full wait experience.

## What the traces establish

Both credited traces were recorded with System Trace for all processes and
passed `xcrun xctrace export --input <trace> --toc` with exit 0. Actual traces,
exports, CLI diagnostics and device identifiers remain private and ignored.

The initial async trace also exports, but lasts only 1.064 seconds and ends with
`Device disconnected`. It contains no SyncBench priority, QoS or CPU-profile
rows and only one app thread-state entry. It is retained and not credited as
useful experiment evidence. An initial comparison of phone JSON wall-clock times
with host trace times suggested no overlap; those clocks differ, so that
comparison alone cannot establish overlap. The disconnected end and missing
benchmark activity are the reasons this trace is insufficient.

The diagnostic retry preserves that first artifact and its accepted-state
history. An ignored copy of `traced-async-code.json` adds only one trailing
newline: decoded plan, name, run ID, seed, tunables and workload are identical,
but the raw plan hash selects a fresh state namespace. A temporary ignored driver
injects recorder process/wait hooks solely to retain private stdout, stderr and
lifecycle evidence; repository runner code is unchanged. Its 32.455-second trace
ends with `User pressed Stop`, and `xctrace` exits 0. It contains 199 app priority
rows, 313 app QoS rows and 125 app CPU samples, including `IsolationSettings.run`,
main-queue callbacks and global-executor enqueue functions. Main and worker
activity confirms the actual experiment was recorded. These short probe bodies
are not individually sampled often enough for an exact per-call switch census.

The 32.308-second priority-inversion trace also ends with `User pressed Stop`.
Its two named holder pthread lifetimes match the recorded block order,
`osUnfairLock` then `DispatchSemaphore` (the source creates one holder per block).
The unfair-lock holder requests Utility QoS but reaches effective User Interactive
in three intervals totalling 20.944 ms; its scheduled/base priority reaches 47
in three intervals. The semaphore holder has no such interval and stays Utility
apart from a roughly 0.011 ms User Initiated wake interval. This is direct
scheduler-table evidence of the reference priority contrast, separate from the
short untraced wait distributions.

The stock System Trace template collects PointsOfInterest signposts; the harness
uses the `SyncBench` subsystem with category `block`. Those block intervals are
absent from these exports. The tables support the observations above, but a
custom trace configuration must include that category for precise signpost-based
block alignment. The recorder also does not reject an early recording-process
exit after its start notification: the initial disconnected trace exposes this
runner gap. A successful TOC export alone must not qualify future traces.

## Consequences for plan 3 and the pilot

- Preserve clean-build, request, marker, OS-build and calibration provenance.
  Calibration targets idle performance-core work, not a fixed loaded hold time;
  verify reference separation and overlap again with the pilot's conditions.
- Use the specified larger trial counts (at least 1,000 per mechanism), multiple
  runs and a chosen estimator before performance conclusions. Report censorship
  per block, especially the iphone15 background semaphore and sync-barrier rows;
  conditional medians must not hide waits beyond the 300 ms load interval.
- Relate measured waits to each phone's frame budget and the 250 ms hang threshold
  only after the pilot. Do not infer dropped frames from these trials.
- The actor row records `mainAcquire` on the actor before returning to main; its
  timestamp excludes that final return hop. Keep this distinction visible.
- In the 2026-11-05 build, `onActor` contained no per-operation async call:
  Release optimization inlined `incrementAsync()` and folded the sub-batch into
  one addition. The [2026-11-06 correction](#operation-preservation-repeat-2026-11-06)
  supersedes that row. `Mutex.withLock` was inlined in the background-task loop.
- Validate trace duration and actual benchmark activity, capture recorder failures,
  include the harness signpost category, and align monotonic timelines rather
  than comparing unsynchronized device and host wall clocks. Keep traces private
  and separate from timed data.

The local Python regression suite passes 140 tests. No implementation or tests
were changed for this acceptance. The earlier Simulator results remain the
implementation's prior evidence; this document adds physical-device checks.

## Operation-preservation repeat (2026-11-06)

Clean source `cfcddf82df269940cb0ccbcdba2ec13541c18cc5` was rebuilt as signed
arm64 Release apps with fresh derived-data directories for both deployment
targets. Prior build artifacts, results and state were preserved. The user
reduced the repeat acceptance to **iphone15 only**; iphone11 was not run.
Both initial base commands stopped at the locked-device doctor gate before
creating any session or attempt. After iphone15 was unlocked, the campaigns
below ran with fresh codeHash state namespaces, rather than reusing completed
campaign state. No OS update, calibration, priority-inversion or trace run was
performed.

| Target | Build ID | Stripped-executable SHA-256 / codeHash |
| --- | --- | --- |
| iOS 26.0 | `cfcddf82df26-clean-ios26-20261106T004427Z` | `5f53b01f4dee99fa82c40d406033c2492053c0cc27462600bdb10dc895bd514a` |
| iOS 18.0 | `cfcddf82df26-clean-ios18-20261106T004524Z` | `22b03a690af8a1e40734e0069120a31b6462a08b7768d0db6a528c941ab3933a` |

Both signed builds passed `codesign --verify --deep --strict`, and their
provisioning profiles cover the run phone. Build metadata records Xcode 27.1
(27A9275), Swift `swiftlang-6.4.0.34.1`, iPhoneOS27.1 SDK, Swift 6, `-O`,
whole-module optimization, nonisolated default isolation, Approachable
Concurrency NO and both isolation inference flags NO. Exclusivity enforcement
remains the default (unset); no `SWIFT_*` command-line settings were supplied.
The two probe libraries retain their distinct template and Swift 6 settings.
The same signed target artifact was used throughout each target's sessions.

| Phone | Plan / deployment target | Session ID | Outcome |
| --- | --- | --- | --- |
| iphone15 | Base comparison / iOS 26 | `20261106T004633Z.acceptance-base-comparison.6ca701ed` | 4 accepted |
| iphone15 | Async code / iOS 26 | `20261106T004911Z.acceptance-async-code.15e24e0b` | 3 accepted |
| iphone15 | Base comparison / iOS 18 | `20261106T005116Z.acceptance-base-comparison-ios18.e5f09443` | 4 accepted |

The iOS 18 label is the app deployment target; the phone still runs iOS 26.6.2
(build `23G90`). All three sessions have zero rejected/refused attempts and no
stop reason. All 11 fresh JSONL/marker pairs were independently checked against
the reconstructed plan request, signed build ID and installed OS build,
including marker byte count and SHA-256: 11 accepted. All endpoints report active
application state, nominal thermal state and no debugger. All 311 block
correctness checks pass: 231 base iOS 26, 20 async and 60 base iOS 18.

The eight actor/MainActor increment blocks in the iOS 26 base campaign pass both
final-count and returned-value checksum checks. Independent arithmetic verifies
`N = threads × 3 batches × operationsPerBatch`, final value `N`, and checksum
`N × (N + 1) / 2` for every block. The single-thread `unsynchronized` floor passes
read, write and increment checks. The iOS 18 plan retains its prescribed subset
of `Atomic`, `ManagedAtomic` and `Mutex` rows; it does not exercise those
actor/floor corrections.

Async acceptance passes `callerPaths`, `batching` and `isolationSettings`.
`onActor` finishes at 6,000/6,000 increments. Each isolation row reports
1,200/1,200 calls: all template calls execute on main, and zero Swift 6 or
`@concurrent` calls execute on main.

The [optimized-code audit](build-checks/2026-11-operation-preservation.md)
establishes why this repeat has a different interpretation from the old row:
`onActor` now preserves one noninlined async call per increment on the same
actor, including async-frame allocation/deallocation costs; it is not a switch
to a different executor per operation. The floor now performs one relaxed load
or store per operation (increment is separate load/add/store), with no atomic
read-modify-write, lock or added access check in its audited loops. Actor and
MainActor increment results are consumed in their checksum, preserving the
intended return to the caller per increment. These smoke results establish
functional correctness with that audited operation structure, not a performance
ranking or equivalence to the earlier optimized-away workload.

Raw tool logs and independent validation records remain private under ignored
`build/private/operation-preservation-acceptance/`; signed apps and provisioning
profiles remain under ignored `build/artifacts/`, and session results under
ignored `results/iphone15/<session ID>/`.

## Readable experiments and optimizer fixes (2026-11-06)

Clean source `a1647c675def` passed the four requested acceptance plans on both
physical phones. The [readable-experiment build check](build-checks/2026-11-readable-experiments.md)
records the original-baseline comparison, permitted concrete-lock differences,
source-diagnostic constants and rejected helper/file-merge probes. It also ties
the fresh unsigned candidates to the signed artifacts: all 785 / 870 selected
units match for iOS 26 / iOS 18 respectively. This adds acceptance for the
[three optimizer fixes](build-checks/2026-11-operation-preservation.md) on both
phones; it does not establish a performance ranking.

All unsigned builds, signed builds and device runs preceded Task 6's tracked
documentation/comment edits. Both signed build records have `dirty: false`.
The existing runner built them with these commands; the profile in each app
covers both configured phones, so each target uses one artifact on both phones:

```sh
python3 scripts/bench.py build --target ios26 --phone iphone11
python3 scripts/bench.py build --target ios18 --phone iphone15
```

Both signed apps pass `codesign --verify --strict`. Build metadata retains
arm64, Swift 6, `-O`, whole-module compilation, nonisolated default isolation,
Approachable Concurrency NO, both isolation-inference flags NO and default
exclusivity enforcement. No `SWIFT_*` command-line overrides were supplied;
the two 7C libraries retain their distinct template/Swift 6 settings.

| Target | Build ID | Stripped-executable SHA-256 / codeHash |
| --- | --- | --- |
| 26.0 | `a1647c675def-clean-ios26-20261106T070633Z` | `ecdcc9ed2fae1a48fa92d79e53e835b3c2f40207beffd025b73f7840e4f75c10` |
| 18.0 | `a1647c675def-clean-ios18-20261106T070654Z` | `c9054914c87117529b4c0624d39103fada9837f0e590645bf07be45bc3ca655c` |

Phones retain iOS 26.6.0 (`23G71`, iphone11) and iOS 26.6.2 (`23G90`, iphone15).
The iOS 18 label describes the app deployment target. No phone reboot or OS
update took place. The initial iphone11 calibration installed the app but iOS
denied launch at the developer-certificate Trust gate. The user trusted the
certificate and opened SyncBench once; the unchanged artifact then passed.

The failed pre-app attempt remains in session
`20261106T070659Z.calibration.81cdba37`, attempt
`calibration.calibration.1.attempt1.20261106T070717Z.4c93f92b`, with
`launchFailed` and no completed JSONL result. The runner retains that rejection;
it is separate from the completed app results below. No result/state history
was removed or rewritten.

### Fresh calibration and sessions

`bench.py calibrate --phone PHONE` ran before that phone's acceptance plans.
The runner retained the accepted attempt ID in each priority-inversion session.
Both calibrations identify performance CPUs `[4, 5]`, efficiency CPUs
`[0, 1, 2, 3]` and a 125/3 ns timebase. They target 5 ms of idle performance-core
holder work; loaded trials need not hold for exactly 5 ms.

| Phone | Accepted calibration attempt | 100,000-iteration median ticks | Usable samples | Holder work iterations |
| --- | --- | ---: | ---: | ---: |
| iphone11 | `calibration.calibration.1.attempt2.20261106T071638Z.c96f553c` | 5,454 | 199/200 | 2,200,220 |
| iphone15 | `calibration.calibration.1.attempt1.20261106T070721Z.1e4b828f` | 3,810 | 200/200 | 3,149,606 |

The accepted calibration and acceptance sessions follow. For each acceptance
plan, the runner used
`python3 scripts/bench.py run --phone PHONE --plan plans/PLAN.json`:

| Phone | Plan | Session ID | Outcome |
| --- | --- | --- | --- |
| iphone11 | `calibration` | `20261106T071624Z.calibration.4fabf97b` | 1 accepted |
| iphone11 | `acceptance-base-comparison` | `20261106T071716Z.acceptance-base-comparison.c65349f9` | 4 accepted |
| iphone11 | `acceptance-base-comparison-ios18` | `20261106T072227Z.acceptance-base-comparison-ios18.d2ba98f9` | 4 accepted |
| iphone11 | `acceptance-async-code` | `20261106T072504Z.acceptance-async-code.80a8b633` | 3 accepted |
| iphone11 | `acceptance-priority-inversion` | `20261106T072706Z.acceptance-priority-inversion.beedbec2` | 1 accepted |
| iphone15 | `calibration` | `20261106T070659Z.calibration.4a2482c2` | 1 accepted |
| iphone15 | `acceptance-base-comparison` | `20261106T070812Z.acceptance-base-comparison.0b92c355` | 4 accepted |
| iphone15 | `acceptance-base-comparison-ios18` | `20261106T071046Z.acceptance-base-comparison-ios18.9318e99e` | 4 accepted |
| iphone15 | `acceptance-async-code` | `20261106T071319Z.acceptance-async-code.44005f4c` | 3 accepted |
| iphone15 | `acceptance-priority-inversion` | `20261106T071518Z.acceptance-priority-inversion.e212a27e` | 1 accepted |

The eight acceptance sessions have 24 accepted attempts, zero rejected/refused
attempts and no stop reason. Including the two successful calibrations gives
26 completed JSONL/marker pairs. Independent reconstruction of each request,
including the calibrated holder work, passed the checker with the recorded
clean build ID and installed OS build; marker byte counts and SHA-256 checks
also pass. The 688 correctness checks include 339 acceptance checks and five
calibration checks per phone. Both endpoints report active application state,
nominal thermal state and no debugger.

Both iOS 26 base campaigns pass the floor's three checks and all eight
actor/MainActor increment blocks. Independent arithmetic confirms final
`N = threads × 3 batches × operationsPerBatch` and returned-value checksum
`N × (N + 1) / 2` for those blocks. The iOS 18 campaigns cover the prescribed
Mutex / Atomic / ManagedAtomic subset at 1, 2, 6 and 12 threads.

Both async campaigns pass caller paths, batching and isolation settings.
`onActor` finishes at 6,000 increments; each isolation row counts 1,200 calls,
all on main for template defaults and none on main for Swift 6 or
`@concurrent`. The build check preserves the noninlined operation on the same
actor; these results do not count executor handoffs per operation. Each 8B
attempt passes 28 block checks and retains 308 trials (28 warm-ups and 280
measured). Censored and invalid outcomes follow the existing correctness rule
and remain in the raw output. No trace campaign ran for this repeat.

### Final local verification

```sh
python3 -m unittest discover -s scripts/tests -t scripts
/usr/bin/python3 -m unittest discover -s scripts/tests -t scripts
xcodebuild test -project SyncBench.xcodeproj -scheme SyncBench \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -resultBundlePath build/private/readable-experiments/task6-simulator.xcresult \
  -quiet
```

Python passes 151 tests on the default interpreter and Xcode's Python 3.9.6.
The Simulator passes 68 tests / 182 executions, with zero failures, skips or
runtime warnings. Its log retains the three pre-existing SDK telemetry
`invalidDigitCount(94232)` messages; no Swift diagnostics occur. The three
experiment READMEs have the required seven headings and source-matching Swift
snippets. The build note documents the entry-file sizes and preservation
exceptions.

Session JSONL, markers and state remain under ignored `results/`. Signed apps
and profiles remain under ignored `build/artifacts/`. Comparison reports, test
bundles, CLI logs and independent rechecks remain under ignored
`build/private/readable-experiments/`; the runner's private device/build
diagnostics remain in their existing `build/private/` locations.

### Later dead-helper cleanup verification

The later `Remove unused block timing wrappers` commit deletes the unused
`BlockContext` timing wrappers and their two exclusive tests. Device acceptance
above remains for clean revision `a1647c675def`; it was not rerun, and its signed
artifacts, session history and original inventory remain unchanged. Fresh unsigned
`final-ios26` / `final-ios18` builds preserve every selected instruction region
of the accepted Task 6 executables: default 785 / 870 kept, supplemental 791 / 876
kept, zero missing or added for either target. The [build check](build-checks/2026-11-readable-experiments.md#later-dead-helper-cleanup)
records the comparison scope and limits.

The final Simulator command uses the same destination as above, with
`-enableCodeCoverage YES`, result bundle
`build/private/readable-experiments/final-simulator.xcresult` and unfiltered log
`final-simulator.log` in that directory. It exits 0: 66 tests / 180 executions,
zero failures, skips and runtime warnings. The two-count reduction removes only
the deleted wrapper tests. Coverage reports all retained layout/check-value,
request-validation and real `BatchTimer` helper lines executed. The same three
SDK telemetry `invalidDigitCount(94232)` messages remain visible. They originate
in Xcode's `IDESchemeActionSDKRecord`; this repository cleanup does not repair
that external telemetry subsystem, suppress messages or filter errors. The
151-test Python results above remain the Task 6 results; no Python source changed
in this cleanup.
