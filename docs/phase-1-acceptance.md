# Phase 1 device acceptance

## Direct queue correction acceptance (2026-11-05)

This is the latest full acceptance. Concrete queue counters were implemented in
`3579043`; the clean source revision used for both signed builds is
`b2c9f9dae09cae8c14007c11221894bb0fe67bc7`. Standard Release `-O`/WMO and default
exclusivity remain enabled; no `@exclusivity(unchecked)` is used. All recorded
sessions have `dev: false`.

| Deployment target | Build ID | Exact stripped-executable SHA-256 |
| --- | --- | --- |
| ios26 | `b2c9f9dae09c-clean-ios26-20261105T094500Z` | `f1d9307b6c54396a8c7da340c1247bf2a60ded6b16c18f4cc0caaf8d04bdcf98` |
| ios18 | `b2c9f9dae09c-clean-ios18-20261105T094756Z` | `b193eb9fb025b20a381117ffed75307f36492548ad7703a65f2646e17103506c` |

Both profiles cover both configured phones, so each target's same signed app was
used on both devices. iPhone 11 Pro Max remains on iOS 26.6 (23G71), and iPhone 15
Pro Max remains on iOS 26.6.2 (23G90). Automatic updates remain disabled per Ivan's
preparation decision. No OS update or setting change was performed. The initial
live doctor calls and the strict plans verified the expected OS builds.

| Phone | Check | Session ID | Outcome |
| --- | --- | --- | --- |
| iphone11 | iOS 26, 1/2/6/12 threads | `20261105T094801Z.acceptance-base-comparison.01176119` | 4 accepted, 0 rejected/refused |
| iphone11 | Calibration | `20261105T095039Z.calibration.adbc88f2` | 1 accepted, 0 rejected/refused |
| iphone11 | Crash/hang | `20261105T095130Z.crash-and-hang.3edc3663` | crashed + timeout; original .ips copied; hang terminated |
| iphone11 | Strict non-smoke | `20261105T095325Z.queue-correction-strict-iphone11.2c3dfb06` | 1 accepted, 0 rejected/refused |
| iphone11 | iOS 18, 1/2/6/12 threads | `20261105T095523Z.acceptance-base-comparison-ios18.0bd7feb3` | 4 accepted, 0 rejected/refused |
| iphone15 | iOS 26, 1/2/6/12 threads | `20261105T094801Z.acceptance-base-comparison.2a81adbe` | 4 accepted, 0 rejected/refused |
| iphone15 | Calibration | `20261105T095036Z.calibration.7f70a01a` | 1 accepted, 0 rejected/refused |
| iphone15 | Crash/hang | `20261105T095126Z.crash-and-hang.def58cf8` | crashed + timeout; original .ips copied; hang terminated |
| iphone15 | Strict non-smoke | `20261105T095321Z.queue-correction-strict-iphone15.19f4c81a` | 1 accepted, 0 rejected/refused |
| iphone15 | iOS 18, 1/2/6/12 threads | `20261105T095523Z.acceptance-base-comparison-ios18.82e69ddb` | 4 accepted, 0 rejected/refused |

All 20 completed attempts (16 base comparison, two calibration, two strict) were
independently rechecked with `bench.py check`, reconstructing each launch request
from its plan and checking the known build ID. All passed. Every iOS 18 result
records `minimumOS: 18.0`. Every session ended without a stop reason. The two
crash/hang commands intentionally returned exit 1: their statuses are `crashed`
and `timeout`, not accepted measurements. Each crash has one nonempty original
`.ips` in its attempt folder; no redaction or provenance sidecar is generated.
The timeout path completed process termination successfully on each phone.

Strict plans pin each phone's OS build and run Mutex plus all three corrected
queue counters, read/write/increment, with one warm-up and two measured batches,
four sub-batches, 10,000 operations per batch (2,000 for the async-barrier row),
and 100,000 reference iterations. They use `smoke: false`. Both results have
12 passing block checks, 12 warm-up and 24 measured batch records; preflight and
end conditions pass, including `applicationState: active` at both endpoints.
These short checks verify normal launch/conditions, not performance rankings.

- iphone11 calibration: performance CPUs `[4, 5]`, efficiency CPUs `[0, 1, 2, 3]`.
- iphone11 strict plan SHA-256: `b61c44356a10aac849aabe101a15ece5c1953a878578031168163e1910bf5bf4`.
- iphone15 calibration: performance CPUs `[4, 5]`, efficiency CPUs `[0, 1, 2, 3]`.
- iphone15 strict plan SHA-256: `827e7d7e457c102f4c9292c3ed6dd8b9ca4846989fc07e4527bbdb2d3c1ea0e1`.

Local verification: all 38 Swift test functions pass, including real queue drain
and executor-slot completion; Python suites pass 82 tests on both Python 3.15
and 3.9.6. The bounded code/assembly review found no blocker. New queue bodies
have no dynamic access checks; the [build checks](build-checks/2026-11-phase-1.md#direct-queue-counters-2026-11-05-correction)
record the independent arm64/iOS 26 reference, corrected ManagedAtomic attribution,
and the lock optimizer differences rather than claiming byte-identical lock code.

Session files remain under `results/<phone>/<session>/`. Local commands,
reconstructed requests, independent checker verdicts and the consolidated summary
remain under ignored `build/queue-revision/`. Older acceptance below is historical
and does not replace these clean-build results.

## Earlier acceptance and lifecycle work

On 2026-11-05 I ran the implemented CLI on both cable-connected physical phones.
All 16 base-comparison attempts passed, covering both deployment targets and
1, 2, 6, and 12 threads on each phone. Both calibrations passed. After fixing
delayed crash-report collection, both phones retained a simulated crash report
and terminated the simulated hang at its 60-second limit.

These are functional smoke checks. The plans mark their samples `smoke: true`;
the iOS 26 base and calibration sessions also carry `dev: true` because the user
was formatting repository files during acceptance. They do not establish
performance rankings or replace the pilot. The original async-write queue read
batches also included synthetic instrumentation barriers; those historical files
are functional smoke evidence, not unbiased read timing. The correction removes
executor probes and pending-write drains from synchronous read timing, retains
them for mutations, and keeps actor executor sampling. Its behavior is verified
locally in Simulator and an unsigned Release build; no new device timing
validation is claimed.

A final read-only recount found all 18 original completed smoke attempts started with
`applicationState: "inactive"`; 12 also ended inactive and six ended active.
Smoke bypasses the hard preflight conditions, so these accepted files establish
smoke correctness and runner integration only. They do not establish a working
non-smoke launch lifecycle. The corrected app waits for actual application and
foreground-scene activation plus two active display callbacks before consuming
the request, and resets that delay on interrupted activation. Simulator lifecycle
ordering tests cover this correction. Supplemental physical non-smoke runs
verified startup on both phones, as recorded below.

## Corrected lifecycle supplement

After the user unlocked iphone11, I built the corrected app from clean HEAD
`a0bdaff3066fd0df0b0650114e07a27f1784a449`, which includes the activation-gate
fix `3429bbe`. The installed build was
`a0bdaff3066f-clean-ios26-20261105T064732Z`.
The provisioning profile covers both configured phones, so I reused that same
signed app after the user unlocked iphone15. Each session accepted its one
non-smoke attempt with no rejection, refusal, or stop reason:

| Phone | Pinned iOS build | Session ID |
| --- | --- | --- |
| iphone11 | `23G71` | `20261105T064745Z.final-lifecycle-iphone11.9a69a53f` |
| iphone15 | `23G90` | `20261105T065156Z.final-lifecycle-iphone15.617534d3` |

Each private plan pins its observed iOS build, sets `smoke: false`,
and runs Mutex read/write/increment on one thread, with one warm-up and two
measured batches of 10,000 operations per block. It keeps the normal strict
preflight and a 60-second launch/run limit. The plan SHA-256 values are:

- iphone11: `22fdaf97913a40e8f200dca948a23d0dd567e2a9e4a7669e3d83aac93cc285bf`.
- iphone15: `8bf0629cf69ae033762de983d0ff5ae2351064250b0461be221f668303f71677`.

Both results record `applicationState: "active"` at start and end,
nominal thermal state, Low Power Mode off, no debugger, and an empty watched
environment. The battery was full on iphone11 and charging on iphone15.
Each result has three passing block checks, three warm-up batch lines, and six
measured batch lines. Both sessions have `dev: false`. Independent
`bench.py check` invocations, using requests reconstructed from the plans and
the expected build ID, accepted both file/marker pairs with exit status 0.
No preflight condition or phone setting changed for these checks.

The first iphone15 invocation stopped in doctor because its live unlock check
failed, before installation or launch. After the user unlocked it again and
kept the screen on, the immediate retry produced the accepted session above.

Two builds from the same clean source have the same exact stripped-executable
hash; the [build-check supplement](build-checks/2026-11-phase-1.md#corrected-app-build-supplement)
records that evidence. These short runs verify startup and strict preflight on
both phones. The earlier smoke files remain intact; the full final-binary matrix
and performance measurements remain outside this supplement.

## Environment and provenance

| Phone key | Model | Installed iOS | Build | CPUs | Tick timebase |
| --- | --- | --- | --- | --- | --- |
| iphone11 | iPhone 11 Pro Max, iPhone12,5 | 26.6.0 | 23G71 | 2 performance + 4 efficiency | 125/3 ns |
| iphone15 | iPhone 15 Pro Max, iPhone16,2 | 26.6.2 | 23G90 | 2 performance + 4 efficiency | 125/3 ns |

Both phones answered live unlocked and Developer Mode queries, installed the
signed app, launched without a debugger, and produced checked result files.
The installed versions above are now frozen by Ivan's decision; automatic OS
updates are disabled and neither phone is to be upgraded. A shared iOS 27.x build
is not required. Smoke plans record the observed versions; strict plans pin each
phone's own `iosBuild`. Earlier results below remain historical evidence.

Xcode 27.1 (27A9275), swiftlang-6.4.0.34.1, and XcodeGen 2.46.0 match the frozen
toolchain. Builds use Release `-O`, whole-module optimization, Swift 6, explicit
isolation, and default Release exclusivity. The signed apps and profiles remain
in ignored `build/artifacts/`; public metadata stays in `results/builds/` with
repository-relative app paths.

| Installed use | Build ID | Embedded source commit | Dirty |
| --- | --- | --- | --- |
| iphone11 iOS 26 base | `08bf62e3e4c8-dirty-ios26-20261105T054019Z` | `08bf62e3e4c8` | yes |
| iphone15 iOS 26 base; both calibrations | `08bf62e3e4c8-dirty-ios26-20261105T054041Z` | `08bf62e3e4c8` | yes |
| Both iOS 18 base sessions | `2099dbb8911f-clean-ios18-20261105T054328Z` | `2099dbb8911f` | no |
| First iphone15 crash/hang | `2099dbb8911f-dirty-ios26-20261105T054439Z` | `2099dbb8911f` | yes |
| First iphone11 crash/hang; both recovery retries | `2099dbb8911f-dirty-ios26-20261105T054535Z` | `2099dbb8911f` | yes |

I built for each phone, and checked that the later provisioning profile covers
both configured destinations before reusing it. Each target's installed apps
have the exact executable hash recorded in the
[build checks](build-checks/2026-11-phase-1.md). A same-HEAD, same-file-content
pair proves iOS 26 hash stability for that prior source snapshot without binary
normalization. The later lifecycle correction changes the app; that earlier
hash evidence applies to the earlier binary. The supplement records a new signed
build pair and physical checks of the corrected binary on both phones. Concurrent
formatting changed earlier snapshots; I did not use those pairs as proof.

The base and calibration sessions used the then-current runner. The crash
retries use runner commit `19ab4ad` (`Wait for delayed crash report publication`).
That Python-only change required no new app build.

## Sessions and results

Session folders live at `results/<phone>/<session ID>/`. No raw samples or
signed apps are committed with this report.

| Phone | Session ID | Result |
| --- | --- | --- |
| iphone11 | `20261105T054043Z.acceptance-base-comparison.79ab3f18` | iOS 26: 4 accepted, 0 rejected/refused |
| iphone15 | `20261105T054108Z.acceptance-base-comparison.48cf30e0` | iOS 26: 4 accepted, 0 rejected/refused |
| iphone11 | `20261105T054440Z.acceptance-base-comparison-ios18.ea71b714` | iOS 18: 4 accepted, 0 rejected/refused |
| iphone15 | `20261105T054440Z.acceptance-base-comparison-ios18.0ca5b04d` | iOS 18: 4 accepted, 0 rejected/refused |
| iphone11 | `20261105T054330Z.calibration.6cbeba60` | 1 accepted; core map written |
| iphone15 | `20261105T054330Z.calibration.cffd5010` | 1 accepted; core map written |
| iphone11 | `20261105T054608Z.crash-and-hang.2a01e36b` | crash + timeout; initial collector missed delayed crash report |
| iphone15 | `20261105T054531Z.crash-and-hang.56dae200` | crash + timeout; initial collector missed delayed crash report |
| iphone11 | `20261105T055225Z.crash-and-hang.c002eb93` | retry: crash report retained; hang timed out and terminated |
| iphone15 | `20261105T055225Z.crash-and-hang.eddefefd` | retry: crash report retained; hang timed out and terminated |

I invoked `bench.py check` on all 18 completed JSONL files using their request
and expected embedded build ID: 18 accepted. Their `.done` hashes, expected
block/batch counts, and correctness checks passed. They record
`debuggerAttached: false` and nominal thermal state at both ends.
The eight iOS 18 run lines report `minimumOS: "18.0"`.

Per phone, the iOS 26 plan records 60 blocks/120 measured batches for one thread,
then 57/228, 57/684, and 57/1368 for 2, 6, and 12 threads. The contention variants
exclude the unsynchronized floor. The iOS 18 plan records 15 blocks per variant
and 30, 60, 180, and 360 measured batches. Calibration records four checked
sample blocks and no batches.

The original two-variant smoke plans remain available; I used their four-variant
acceptance counterparts to cover the requested contention cases. `status`
reports four accepted and zero pending for each phone and target, and one
accepted calibration per phone. The diagnostic plan keeps simulated failures
rejected, returns exit status 1, and can remain pending until its attempt budget
is exhausted. A zero accepted count is expected for that plan.

## Crash and timeout evidence

The first collector queried before iOS published a report. On iphone15 it
recorded `crashed` at 05:45:46 UTC; the report's modification time was 05:45:53.
On iphone11 it recorded `crashed` at 05:46:23; the report appeared with a
05:46:36 modification time. Later read-only queries found the expected
SyncBench report on each phone. I reported this discrepancy before changing
the runner. Commit `19ab4ad` adds a shared 30-second discovery deadline and an
explicit reason when no report becomes available.

The retries retained these public copies, each with `1.provenance.json`:

- iphone11: session `20261105T055225Z.crash-and-hang.c002eb93`, under
  `crash/crash-and-hang.crash.1.attempt2.20261105T055239Z.a3e9d52d/1.ips`.
- iphone15: session `20261105T055225Z.crash-and-hang.eddefefd`, under
  `crash/crash-and-hang.crash.1.attempt2.20261105T055240Z.fc120735/1.ips`.

The provenance hashes match both sanitized copies and private originals.
Original crash reports and raw devicectl stdout/arguments remain under
`build/private/`. The initial attempts retain their session metadata and logs;
they have no completed JSONL publication. Both retry hangs reached `timeout`,
and their devicectl process-termination commands returned success. Their
sessions ended with no stop reason.

A scan of result files found no configured signing, bundle, device identifiers,
repository absolute path, or absolute host/device path. Crash sanitization
redacts report identity fields and learned identity values before publication.

## Calibration and follow-up work

Both core maps classify CPUs `[4, 5]` as performance and `[0, 1, 2, 3]` as
efficiency. The performance count is two, matching each phone's recorded
`hw.perflevel0.logicalcpu`. Both CPU-speed QoS blocks contribute stable samples;
the derivation excludes samples with differing CPU readings at their ends.

| Phone | Median clock-read block, 1 thread | Median clock-read block, all 6 CPUs |
| --- | --- | --- |
| iphone11 | 454 ticks per 1000 reads | 464.5 ticks per 1000 reads |
| iphone15 | 119 ticks per 1000 reads | 111 ticks per 1000 reads |

These host-derived medians summarize the smoke calibration, including its loop
and timing envelope. The raw files retain 200 single-thread observations and
1200 all-CPU observations per phone. At 125/3 ns per tick, a single tick is about
41.67 ns; future analysis must report values near that resolution with care.
The all-CPU samples include scheduling outliers, so the pilot must choose its
estimator before performance conclusions.

Plans 2 and 3 must preserve the request/marker/build checks and complete failed
attempt history. They must budget crash publication as well as process lifetime,
use the PID returned in `process.processIdentifier`, and copy result files one
at a time. Deployment target selects LSE versus LL/SC code even when both apps
run on the same installed iOS. The unsynchronized floor permits compiler
reductions; queue captures and ManagedAtomic accessors keep dynamic exclusivity,
and async barrier writes include their mechanism's allocation cost. Keep those
facts visible when extending comparisons or choosing pilot batch sizes.

Achieved display rate, the experiment-8B work size, System Trace validation,
long-duration stability, and performance measurements remain outside
this phase-1 smoke acceptance.
