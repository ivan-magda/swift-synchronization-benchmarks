# Phase 3 device acceptance

Both phones passed the required remaining-experiment acceptance plans and the conservative async-code and priority-inversion repeats on 2026-11-06. All completed attempts were accepted, with zero rejected or refused attempts and no session stop reasons. The user confirmed phone preparation before these runs.

## Build and run provenance

The signed Release builds came from clean documentation checkpoint `e7384aa6a185d21f05896007deee10d24b65cb94`. Its Swift source matches the clean `9b6c5f6` compiler-check source in the [Release record](build-checks/2026-11-remaining-experiments.md). The toolchain remained Xcode 27.1 (27A9275), Swift swiftlang-6.4.0.34.1 and XcodeGen 2.46.0. Release settings and the installed phone operating systems stayed unchanged.

| Target | Signed build ID |
| --- | --- |
| ios26 | `e7384aa6a185-clean-ios26-20261106T113714Z` |
| ios18 | `e7384aa6a185-clean-ios18-20261106T114856Z` |

Both signing profiles cover both configured phones, so each target used one immutable signed artifact. Parallel pipelines ran on separate phones; each phone ran one plan at a time and switched to iOS 18 only after its iOS 26 pipeline finished. Target-specific artifacts and state remained separate. The runner keyed progress by plan hash, phone, current code hash and clean eligibility; older accepted runs did not satisfy this checkpoint.

Private acceptance-plan copies under `build/private/remaining-task-8/device/plans/` pin `iphone11` to installed iOS build `23G71` and `iphone15` to `23G90`. Workloads, settle times and pauses match the committed plans. Calibration preflight checked the pinned build before the normal calibration command. Both phones passed doctor checks for availability, Developer Mode, unlock state, toolchain and profile lifetime. The runner installed clean artifacts and applied each plan's settle time.

## Calibration display observations

| Phone | Measured frames | Median interval | Expected interval |
| --- | ---: | ---: | ---: |
| iphone11 | 200 | 16.61 ms | about 16.67 ms |
| iphone15 | 200 | 8.33 ms | about 8.33 ms |

Both saved calibrations contain the new `display` key. The medians use consecutive callback ticks and each phone's recorded timebase. Holder-work calibration preceded priority inversion.

## Session outcomes

Accepted counts below count whole attempts, each containing all configured rows and operations. The iOS 18 plan covers mutex and the four atomic hot-flag rows. Creation cost covers both 10,000 and 100,000 objects; the cache plan covers two and four writers. Session IDs identify the retained evidence under ignored `results/<phone>/<session>/`.

| Plan | Target | iphone11: accepted, session | iphone15: accepted, session |
| --- | --- | --- | --- |
| calibration | iOS 26 | 1; `20261106T113759Z.calibration.6d03475d` | 1; `20261106T113939Z.calibration.91a7fb1e` |
| acceptance-hot-flag | iOS 26 | 1; `20261106T113905Z.acceptance-hot-flag.3e1cbb5f` | 1; `20261106T114038Z.acceptance-hot-flag.a64d6765` |
| acceptance-hot-flag-ios18 | iOS 18 | 1; `20261106T115607Z.acceptance-hot-flag-ios18.756c4b3a` | 1; `20261106T115537Z.acceptance-hot-flag-ios18.44bb9a33` |
| acceptance-request-registry | iOS 26 | 4; `20261106T113956Z.acceptance-request-registry.e3880cfc` | 4; `20261106T114129Z.acceptance-request-registry.42401028` |
| acceptance-transactional-store | iOS 26 | 1; `20261106T114334Z.acceptance-transactional-store.60ab0e75` | 1; `20261106T114509Z.acceptance-transactional-store.12cec50f` |
| acceptance-creation-cost | iOS 26 | 2; `20261106T114433Z.acceptance-creation-cost.65eca1d1` | 2; `20261106T114605Z.acceptance-creation-cost.52c60e21` |
| acceptance-main-thread-cache | iOS 26 | 2; `20261106T115027Z.acceptance-main-thread-cache.4e80d895` | 2; `20261106T115206Z.acceptance-main-thread-cache.8911ff0c` |
| acceptance-async-code | iOS 26 | 3; `20261106T114558Z.acceptance-async-code.3034edd2` | 3; `20261106T114732Z.acceptance-async-code.f64214f7` |
| acceptance-priority-inversion | iOS 26 | 1; `20261106T114801Z.acceptance-priority-inversion.4183548c` | 1; `20261106T114931Z.acceptance-priority-inversion.6b1d92ac` |

Totals: **16 accepted attempts on iphone11; 16 on iphone15**. Rejected: 0. Refused: 0. Incomplete: 0. No retries, source fixes, allocator overrides or correctness-threshold changes were needed.

The async-code and priority-inversion repeats cover the conservative handoff requirement: their measured baseline units remained, while their untimed validation, sample encoding or TrialLine growth units changed. These smoke acceptance runs establish functionality; the pilot still sets performance tunables and the cache read/write ratio.

## Verification after the phone runs

The Xcode Python 3.9 full suite passed: **172 tests**. The user asked to avoid redundant checks, so this follow-up did not rerun the full Simulator suite or the second Python interpreter. The unchanged Swift source already had a full pass of 90 test functions / 225 configuration runs, followed by the cache-drain fix's focused 4-function / 11-run pass. Those remain historical results, not fresh Step 5 runs. CreationCost ran in isolation for its historical full suite and must remain isolated in future runs.

The completed scope includes phone acceptance, one fresh full Python run and the documentation record. The repeated full Simulator run was waived at the user's request. Final documentation checks found no whitespace errors or private device/signing identifiers. Original tool output, signed profiles and per-attempt files remain in ignored private storage.
