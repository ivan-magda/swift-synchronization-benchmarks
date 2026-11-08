# Request registry (experiment 2)

## Question

What does adding and removing shared download requests cost while one thread occasionally cancels every request under the same lock? How much do the other threads wait during cancel-all?

## Results

With pauses between requests, the ten mechanisms delivered nearly the same
throughput on iPhone 15: less than 1% separated their medians. With continuous
traffic, the choice mattered.

The table shows eight threads with no pauses, from the
[7 November 2026 campaign](../../docs/results.md), iPhone 15 Pro Max, ios26 target,
20 launches. Call timings cover one sampled add/remove call. Throughput includes
work outside the lock and periodic cancel-all calls.

| Mechanism | Call p50 (µs) | Call p99 (µs) | Million operations/s |
| --- | ---: | ---: | ---: |
| `Mutex` | 0.292 | 19.056 | 1.056 |
| `OSAllocatedUnfairLock` | 0.292 | 22.539 | 1.076 |
| Allocated unfair lock + adaptive spin | 0.417 | 2.083 | 1.122 |
| `NSLock` | 0.333 | 51.788 | 0.894 |
| Serial queue | 40.062 | 64.104 | 0.182 |

Adaptive spin reduced the slow-call tail but made the median call slower.
Compared within each launch, it improved throughput by about **7%**. Its p99
benefit appeared in all 20 continuous-traffic launches for each phone/thread-count
combination. That is a reason to test it when long waits matter, not to enable it
for every lock.

`Mutex` remains a useful default for this registry. The main campaign used 64
in-flight slots per thread, 2,000 outside-work iterations, cancel-all every 1,024
calls and sampling every 32 calls. Cancellation only updates test objects; no
network operation runs here. The samples do not establish a reliable p99 for
calls delayed specifically by cancellation: there are few overlapping samples,
and the cancel-all timer includes its own wait for the lock.

## Rows

Ten rows compare `Mutex`, allocated unfair locks (default and adaptive spin), raw unfair lock, `NSLock`, `NSRecursiveLock`, pthread mutex, serial queue, semaphore and Objective-C synchronization. Operation `addAndRemove` uses four or eight workers. Variant `normal` pauses after every operation; `burst` has no pauses. Calls alternate evenly between removing the oldest download and adding the next download from a preallocated ring.

## One operation

`MutexRegistry.remove(id:)` in `LockRegistries.swift`:

```swift
func remove(id: Int) -> Download? {
    downloads.withLock { downloads in
        downloads.removeValue(forKey: id)
    }
}
```

## How it is timed

`BatchTimer.timeBatches` times sub-batches, including `referenceLoop` work outside the lock, occasional cancel-all calls on thread 0, and normal-mode pauses. Dictionary capacity is reserved for `threads × inFlightPerThread` before the block. Each worker has `inFlightPerThread + 1` downloads allocated before the block, adds the first `inFlightPerThread` before batch timing, removes before adding to keep occupancy within capacity, and removes remaining entries after all batches finish. Measured batches record per-thread `callStart` and `callTime` in ticks around one registry call per `sampleEvery` operations; window `w` samples offset `w % 2`, alternating removals and additions. Thread 0 records block-level `cancelAllStart` and `cancelAllTime` every `cancelAllEvery` operations. Warm-up uses the same workload without sample clocks. Buffers are allocated before the block; checks and encoding follow the workers. The acceptance plan uses four and eight threads, 16 in-flight downloads per thread, 200 work iterations, 50 µs pauses in normal and zero in burst, 4,096 calls between cancel-all, and 64 between samples.

## What is checked

The dictionary ends empty. Every add is accounted for by a successful remove or cancel-all; per-download relaxed atomic cancel counts also equal the total returned by cancel-all. Every batch's work result equals the expected `referenceLoop` checksum. Each sub-batch has an even number of operations divisible by both sampling intervals. `sampleEvery` must be even and at least two so window offsets alternate call kinds. Requests reject invalid variants, thread counts, pause values and unrepresentable storage or operation counts.

## Read the code in this order

1. `RequestRegistry.swift`: row dispatch and the measured operation loop.
2. `LockRegistries.swift`, `SerialQueueRegistry.swift` and `Download.swift`: concrete registries and atomic cancellation effects.
3. `RequestRegistryTiming.swift`, `RequestRegistryRequest.swift` and `RequestRegistryChecks.swift`: worker storage, timing, validation and checks.

## Compiler notes

`operationLoop` is `@inline(never)` so specialized loops remain identifiable in Release disassembly. Dictionary mutation next to a stored `var` retains its ordinary exclusivity checks with locks and queues; the `Mutex` closure's inout dictionary has none. These costs belong to ordinary application code and are kept. The work iteration count is stored on every preallocated download, initialized from the tunable. Reading it from the current download keeps `referenceLoop` inside the loop: a uniform argument passed in the tunables was hoisted out of the serial-queue loop in Release. Every experiment owns its mechanism classes; no measured attributes or Release settings are changed. Release verification uses the [codegen comparison](../../docs/build-checks/2026-11-remaining-experiments.md) against the retained baseline and inspects each row's dictionary mutation, cancel-all iteration and clear, and work outside the lock.
