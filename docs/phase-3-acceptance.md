# Phase 3 device acceptance

Status: **PENDING at the phone-preparation handoff**. Task 8 Steps 1–2 have a [fresh Release and reader-audit record](build-checks/2026-11-remaining-experiments.md) from clean source `9b6c5f6`. No physical-phone command, signed build, installation, calibration or acceptance session ran for this checkpoint. Task 8 Steps 3–6 remain pending; this document records no measured rates, session IDs or outcomes.

## Resume after phone preparation

Prepare both configured phones, `iphone11` and `iphone15`, using the [repository protocol](../README.md#syncbench): restart and unlock, cable connected, Developer Mode and certificate trust ready, Auto-Lock Never, Do Not Disturb on, fixed brightness, charging/full battery, Low Power Mode off and nominal thermal state. Keep each installed iOS build unchanged and pin it in the acceptance plans' `iosBuilds`. Build signed artifacts from the clean checkpoint with the frozen toolchain; allow the required settle time and keep the debugger detached.

For each phone, run calibration and the plans below. The display interval expectations are about 16.67 ms for `iphone11` and about 8.33 ms for `iphone15`; these are expected values, not observed rates. Verify the calibration's new `display` key before recording the observed intervals.

| Required check | Target | iphone11 | iphone15 |
| --- | --- | --- | --- |
| `calibration` including `display` | iOS 26 | PENDING | PENDING |
| `acceptance-hot-flag` | iOS 26 | PENDING | PENDING |
| `acceptance-hot-flag-ios18` | iOS 18 | PENDING | PENDING |
| `acceptance-request-registry` | iOS 26 | PENDING | PENDING |
| `acceptance-transactional-store` | iOS 26 | PENDING | PENDING |
| `acceptance-creation-cost` | iOS 26 | PENDING | PENDING |
| `acceptance-main-thread-cache` | iOS 26 | PENDING | PENDING |
| Repeat `acceptance-async-code` | iOS 26 | PENDING | PENDING |
| Repeat `acceptance-priority-inversion` | iOS 26 | PENDING | PENDING |

Repeat async-code and priority-inversion acceptance conservatively because the original comparison reports changes in their untimed validator, sample-encoding and TrialLine growth units. The Release record confirms their measured units remain. Calibrate before priority inversion because its holder work uses calibration. The iOS 18 hot-flag plan includes only mutex and the four atomic rows.

Record the clean source/build provenance, private session locations, session IDs, accepted/rejected/incomplete attempt counts and rejection reasons when the sessions exist. Every completed attempt must be accepted; retain failed attempts and their original evidence. Record measured display intervals only after reading the calibration output. Keep device identifiers, signing values, absolute local paths and private traces out of committed text.

## Checks after device acceptance

Task 8 Step 5 is PENDING. Run the full Python suite with the supported Python versions and the Simulator suite after device acceptance. Run CreationCost tests alone with parallel testing disabled; run the other tests with CreationCost excluded. Earlier full and focused results are listed as historical evidence in the Release record.

Task 8 Step 6, the final acceptance commit, is PENDING. The documentation checkpoint before phone preparation does not complete acceptance or the overall plan.
