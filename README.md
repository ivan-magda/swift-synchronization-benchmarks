# Swift Synchronization Benchmarks

This project compares Swift synchronization mechanisms on real iPhones. It runs small, focused experiments and records raw measurements, device conditions, and correctness checks for each run.

The experiments cover locks, queues, actors, and atomics in workloads such as counters, a request registry, a transactional store, and an image cache. Each experiment page explains what it measures and how to read the code:

- [Base comparison](Experiments/BaseComparison/README.md)
- [Request registry](Experiments/RequestRegistry/README.md)
- [Hot flag](Experiments/HotFlag/README.md)
- [Transactional store](Experiments/TransactionalStore/README.md)
- [Async code](Experiments/AsyncCode/README.md)
- [Main-thread image cache](Experiments/MainThreadCache/README.md)
- [Priority inversion](Experiments/PriorityInversion/README.md)
- [Creation cost](Experiments/CreationCost/README.md)

## Results

The [Milestone 10 release](https://github.com/ivan-magda/swift-synchronization-benchmarks/releases/tag/milestone-10) contains raw measurements from iPhone 11 Pro Max and iPhone 15 Pro Max, along with run plans, checks, and build metadata. The optional priority-inversion campaign was paused; its included results are incomplete. Use the recorded acceptance checks when analysing attempts.

The `ios18` and `ios26` labels refer to build targets. Each result records the operating system build actually installed on the phone. Results depend on the device, operating system, workload, and run conditions; they are not a universal ranking of synchronization mechanisms. See the [data format](docs/data-format.md) for the JSON Lines records.

## Run the benchmarks

The iOS app and Xcode scheme are named `SyncBench`.

You need macOS, Xcode 27.1, XcodeGen 2.46.0, Python 3.9 or later, and a physical iPhone with Developer Mode enabled. Copy `local.example.json` to `local.json` and enter your signing and device details. This file stays local.

From the repository root, replacing `iphone11` with a configured phone key:

```bash
python3 scripts/bench.py build --target ios26 --phone iphone11
python3 scripts/bench.py doctor --phone iphone11 --plan plans/acceptance-base-comparison.json
python3 scripts/bench.py calibrate --phone iphone11
python3 scripts/bench.py run --phone iphone11 --plan plans/acceptance-base-comparison.json
```

This acceptance plan checks that the harness works; it is not a full measurement campaign. See [running SyncBench](docs/running.md) for device preparation, other plans, tests, and compiler checks.

## License

The source code is available under the [MIT License](LICENSE).
