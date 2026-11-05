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
- `onActor` contains no per-operation async call: Release optimization inlines
  `incrementAsync()` and folds the sub-batch into one addition. Same-executor
  handoffs still surround the operations closure. `Mutex.withLock` is inlined
  in the background-task loop. The build notes record both findings.
- Validate trace duration and actual benchmark activity, capture recorder failures,
  include the harness signpost category, and align monotonic timelines rather
  than comparing unsynchronized device and host wall clocks. Keep traces private
  and separate from timed data.

The local Python regression suite passes 140 tests. No implementation or tests
were changed for this acceptance. The earlier Simulator results remain the
implementation's prior evidence; this document adds physical-device checks.
