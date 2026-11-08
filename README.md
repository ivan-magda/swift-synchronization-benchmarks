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

**Start with `Mutex` for short, synchronous access to shared state.** It performed
well in the counter, request registry and transactional store, and added little
creation overhead. Atomic is worth considering for an independent counter or
flag. If an actor already owns the state, look at how often you cross its boundary
and how much work each call does before replacing it with a lock.

- Ordinary locks beat rwlock and barrier queues in the
  [store test](Experiments/TransactionalStore/README.md#results), even with 98% reads.
- Adaptive spin shortened long calls in the
  [request registry](Experiments/RequestRegistry/README.md#results), while making
  the typical call slower. Total throughput rose by about 7% with eight threads
  and no pauses between requests.
- Doing 100 updates per await reduced time per update by about 47× in the
  [async test](Experiments/AsyncCode/README.md#results).
- Queue lookups took about four times as long as Mutex in the
  [image cache](Experiments/MainThreadCache/README.md#results), but neither produced
  display-link callback gaps above the chosen delay threshold.

Each experiment page includes a small results table and its practical limits.
The main examples use iPhone 15 Pro Max; material differences on iPhone 11 are
called out in the text. See [campaign conditions and measurement definitions](docs/results.md)
for the 7 November 2026 data. The raw-data release is still being prepared.

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
