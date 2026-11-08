# Results from 7 November 2026

The experiment READMEs summarize the accepted main-campaign measurements.
Their primary examples use iPhone 15 Pro Max with the ios26 build. Each page
states its workload and number of launches; important differences on the second
phone appear alongside the findings.

## Devices and build

| Device | Installed iOS | OS build |
| --- | --- | --- |
| iPhone 15 Pro Max | 26.6.2 | 23G90 |
| iPhone 11 Pro Max | 26.6 | 23G71 |

Measurements used Xcode 27.1 (27A9275), Swift 6.4.0
(`swiftlang-6.4.0.34.1`), Release optimization and the existing dynamic exclusivity
checks. The measured apps came from commit `e2ebb821f0abcf76d2da89228cae89bb03ba85be`.

Both phones stayed on their installed OS. **ios18 and ios26 name deployment
targets, not the OS running on the phone.** The older-target build covers base
comparison and hot flag. Device comparisons also include an OS-patch difference;
they do not isolate the processor.

Runs used physical phones without a debugger, fixed 0% screen brightness,
Low Power Mode off, nominal thermal-state checks, and a five-second host pause
between launches. Each run started a fresh app process. These checks do not
hold CPU frequency, core placement or scheduler state constant.

## Accepted coverage

| Experiment | iPhone 11 launches | iPhone 15 launches |
| --- | ---: | ---: |
| [Base comparison](../Experiments/BaseComparison/README.md#results), both targets | 416 | 456 |
| [Request registry](../Experiments/RequestRegistry/README.md#results) | 80 | 80 |
| [Hot flag](../Experiments/HotFlag/README.md#results), both targets | 24 | 24 |
| [Transactional store](../Experiments/TransactionalStore/README.md#results) | 20 | 20 |
| [Async code](../Experiments/AsyncCode/README.md#results) | 68 | 76 |
| [Main-thread cache](../Experiments/MainThreadCache/README.md#results) | 24 | 24 |
| [Priority inversion](../Experiments/PriorityInversion/README.md#results) | 3 | 3 |
| [Creation cost](../Experiments/CreationCost/README.md#results) | 24 | 24 |

Total: **1,366 accepted launches**. The required campaign completed all 1,312
launches; the optional cache campaign completed 48. Priority inversion was stopped
after three of ten planned launches per phone, adding six. Six unsuccessful
required attempts remain recorded and are excluded from these performance
summaries. Pilot, preparation, traced runs and warm-up are also excluded.

## How to read the numbers

- **Mean time per operation:** divide a measured batch's elapsed time by its
  operation count, take the median within each launch, then the median across
  launches. Fractions of a nanosecond come from timing many operations together;
  they are not individual calls measured at that resolution.
- **Throughput:** sum the threads' operation counts and divide by the interval
  from the earliest batch start to the latest finish. Take the median across
  measured batches, then launches. This counts completed work, including async
  write drains where specified. Work outside the lock and pauses remain in the
  request-registry denominator.
- **p50 and p99:** compute the percentile of sampled durations inside each launch,
  then take the median of those launch percentiles. p99 is the time within which
  about 99% of the sampled operations completed in that launch; it is not a
  maximum or a guarantee. Percentiles use linear interpolation.
- **Relative comparisons:** pair mechanisms within a launch where possible.
  Ratios between separate configurations, such as grouped versus individual
  awaits, are descriptive and unpaired. A ratio of medians need not equal the
  median of paired ratios.
- **Extra memory:** subtract the ordinary class's allocator-reported bytes per
  object from the mechanism's result in the same launch, then summarize those
  differences. This is not an exact type size or physical memory footprint.

One clock tick is about 41.7 ns on both phones. A zero-tick call is unresolved,
not free. Warm-up counts and work sizes come from each recorded request; the
smaller acceptance-plan examples in the READMEs are not campaign settings.

Priority-inversion waits that outlast the load deadline are censored. They remain
lower bounds rather than exact sustained-load durations. The reported medians
can still be identified with those bounds included. Three launches per phone
are too few for a precise claim about the rate of long waits in an application.

## Scope and data

These experiments compare concrete implementations in controlled workloads.
The registry does no network cancellation; the cache uses prepared images and
simulated preparation work. Neither energy consumption nor whole-app speedup
was measured. The cache's callback gaps also do not count every rendered-frame
hitch. Read the limits next to each result before applying it elsewhere.

The raw-data release is currently a draft. Published downloads will appear on
the repository's [Releases page](https://github.com/ivan-magda/swift-synchronization-benchmarks/releases).
The result records are described in [data format](data-format.md), and
[running SyncBench](running.md) explains how to collect and check your own runs.
