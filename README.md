# SyncBench

This repository contains an iOS harness for comparing Swift synchronization mechanisms on real iPhones.
It records raw samples and run conditions so the measurements can be checked and reproduced.

Start with the experiment pages. Each explains its question, operations, timing
and checks before pointing to the source:

- [Base comparison](Experiments/BaseComparison/README.md) (experiment 1)
- [Request registry](Experiments/RequestRegistry/README.md) (experiment 2)
- [Hot flag](Experiments/HotFlag/README.md) (experiment 3)
- [Transactional store](Experiments/TransactionalStore/README.md) (experiment 4)
- [Async code](Experiments/AsyncCode/README.md) (experiment 7)
- [Main-thread image cache](Experiments/MainThreadCache/README.md) (experiment 8A)
- [Priority inversion](Experiments/PriorityInversion/README.md) (experiment 8B)
- [Creation cost](Experiments/CreationCost/README.md) (experiment 9)

The harness also implements calibration. The
[remaining-experiment Release checks](docs/build-checks/2026-11-remaining-experiments.md)
record the new rows' compiler work and consumers. Their
[device acceptance is pending](docs/phase-3-acceptance.md) at the phone-preparation
handoff. Earlier physical-phone results remain in
[phase 1 acceptance](docs/phase-1-acceptance.md) and
[phase 2 acceptance](docs/phase-2-acceptance.md); the
[readable-experiment checks](docs/build-checks/2026-11-readable-experiments.md)
record the earlier compiler evidence.

Use Xcode 27.1 (27A9275), Swift swiftlang-6.4.0.34.1, and XcodeGen 2.46.0.
The Python runner uses the standard library and supports Python 3.9.
Copy `local.example.json` to ignored `local.json` and fill in your signing and
phone configuration. Keep its values private.

Before a device session:

- Restart and unlock the phone, connect its cable, and enable Developer Mode.
- Complete the developer-certificate Trust step and verify an app can launch.
- Set Auto-Lock to Never, enable Do Not Disturb, and fix the brightness.
- Keep the phone charging or full, disable Low Power Mode, and let it cool to
  nominal thermal state. Allow the plan's settle time after installation.
- Close the debugger and leave the benchmark app active. Unset
  `PTHREAD_MUTEX_*` environment overrides.
- For comparable measurements, pin each phone's installed iOS build in the
  plan's `iosBuilds` (phone key to iOS build). The supplied smoke plans leave
  it empty.

Run from the repository root, substituting your configured phone key:

```bash
python3 scripts/bench.py build --target ios26 --phone iphone11
python3 scripts/bench.py doctor --phone iphone11 --plan plans/acceptance-base-comparison.json
python3 scripts/bench.py calibrate --phone iphone11
python3 scripts/bench.py run --phone iphone11 --plan plans/acceptance-base-comparison.json
python3 scripts/bench.py status --plan plans/acceptance-base-comparison.json

python3 scripts/bench.py build --target ios18 --phone iphone11
python3 scripts/bench.py run --phone iphone11 --plan plans/acceptance-base-comparison-ios18.json
python3 scripts/bench.py status --plan plans/acceptance-base-comparison-ios18.json
```

Repeat for `iphone15`. Build for the destination phone when its provisioning
profile needs registration. `run` installs the latest artifact for the plan's
target; `doctor` requires that artifact to exist. The acceptance plans cover
1, 2, 6, and 12 threads. The smaller `smoke-base-comparison*.json` plans cover
1 and 2 threads. All these plans have `smoke: true`; their samples are for
functional checks.

For async code and priority inversion, build `ios26`, then run the new plans:

```bash
python3 scripts/bench.py run --phone iphone11 --plan plans/acceptance-async-code.json
python3 scripts/bench.py calibrate --phone iphone11
python3 scripts/bench.py run --phone iphone11 --plan plans/acceptance-priority-inversion.json
python3 scripts/bench.py run --phone iphone11 --plan plans/traced-async-code.json
python3 scripts/bench.py run --phone iphone11 --plan plans/traced-priority-inversion.json
```

Run `calibrate` for the configured phone before any plan that uses
`"holderWorkIterations": "fromCalibration"`, including both priority-inversion
plans. The runner reads the holder work size from `results/<phone>/calibration.json`
and stops before installation if it is missing. The four async/priority-inversion
plans have `smoke: true`; their tunables are acceptance guesses until the pilot sets the
measurement values.

Plans with `"traced": true` record System Trace of all processes around each
attempt. They write `.trace` files under
`results/<phone>/<session>/traces/`. These files contain device names and
identifiers: keep them private and never share or commit them. Use traced runs
to inspect thread switches and priorities; keep their samples apart from timed
measurement data.

The runner saves each launch, resumes pending runs by plan, phone, code hash,
and build eligibility (`clean` or `dev`), and uses `caffeinate` during the session.
Dirty-build progress never satisfies clean runs. State filenames now end in
`--clean.json` or `--dev.json`. Older state files without this marker are retained
unchanged as history, but their unknown eligibility is not credited; run the plan
again to create eligible progress. `run`, `doctor`, and `status` use the same
namespace. `status` reports both configured phones.
`calibrate` writes `results/<phone>/calibration.json` after checking stable CPU
samples and performance-level counts. Check a copied attempt against its saved
launch request and expected build ID:

```bash
python3 scripts/bench.py check results/<phone>/<session>/<attempt>.jsonl \
  --request <request.json> --build-id <build-id>
```

To exercise recovery, build `ios26`, then run
`python3 scripts/bench.py run --phone iphone11 --plan plans/crash-and-hang.json`.
Expect `crashed` with the original crash report, then `timeout` with process
termination after 60 seconds. This diagnostic plan returns exit status 1 because
both simulated failures remain rejected attempts. Crash publication can take
several seconds; the runner waits up to 30 seconds for a matching report and
records a reason if none arrives.

Public result metadata lives under ignored `results/`. Signed apps and profiles
live under `build/artifacts/`; build metadata contains repository-relative app
paths. Raw tool output stays under `build/private/`. Original `.ips` reports are
copied unchanged, with their original filenames, into
`results/<phone>/<session>/crash/<attempt>/`. No redaction or extra crash metadata
is generated. Keep failed attempts when reviewing
a session. Provisioning profiles expire, so rebuild before the runner's planned
session window exceeds the profile lifetime.

Run the runner tests:

```bash
python3 -m unittest discover -s scripts/tests -t scripts
```

Compare measured code in two unsigned Release executables with
`python3 scripts/codegen_compare.py BASELINE_EXECUTABLE CANDIDATE_EXECUTABLE --report OUT.json`.
The comparator uses Xcode's inspection tools to hash normalized loops and async
continuations, ignoring function renames and relocated addresses. The JSON report
lists missing and added units with their function names and the number kept; a
missing baseline unit returns exit status 1. Added units are informational.
Use `python3 scripts/codegen_compare.py --dump EXECUTABLE` to print each selected
unit’s function names and normalized instructions, including imported symbols and
demangled local call targets.

Generate the Xcode project and run the tests on the Simulator:

```bash
xcodegen generate
xcodebuild test -project SyncBench.xcodeproj -scheme SyncBench \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Compile an unsigned Release build for iOS:

```bash
xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench \
  -configuration Release -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO -quiet
```
