# Hot flag (experiment 3)

## Question

What does one synchronous read of a shared `Bool` cost while the main thread toggles it about every 10 ms? How often do groups of 100 reads wait behind a write?

## Results

Atomic was the cheapest way to read this flag while another thread changed it.
The saving over `Mutex` was about **1.54 ns per read** on iPhone 15, so the number
of reads matters when deciding whether a change is worthwhile.

Selected [7 November 2026 results](../../docs/results.md), iPhone 15 Pro Max,
ios26 target, 12 launches. These are batch mean times, summarized across launches.

| Mechanism | Mean time per read (ns) |
| --- | ---: |
| `Atomic`, acquire/release | 0.320 |
| `Atomic`, relaxed | 0.322 |
| `ManagedAtomic`, acquire/release | 0.796 |
| `Mutex` | 1.859 |
| `OSAllocatedUnfairLock` | 1.858 |
| Allocated unfair lock + adaptive spin | 8.893 |
| Serial queue | 202.780 |

Use Atomic when the flag and its memory-ordering requirements fit the operation.
If the flag is part of a larger protected state, this result alone is not a reason
to split it out of a `Mutex`.

Relaxed reads offered no material advantage on iPhone 15. On iPhone 11 they did:
about 0.455 ns versus 0.612 ns for acquire. The ios18/ios26 build-target comparison
made little difference to flag reads on either phone.

The separate `readGroups` measurements time **100 reads**, not one. Some atomic
groups recorded zero ticks; their p99 was one tick on iPhone 15. Use the batch
means above for the fast rows. There are no per-write timestamps, so slow groups
cannot be attributed specifically to waiting behind a write.

## Rows

Seventeen rows compare `Mutex`, allocated unfair locks (default and adaptive spin), a raw unfair lock, `NSLock`, `NSRecursiveLock`, pthread mutex and read/write lock, serial queue, concurrent queue with synchronous or asynchronous barrier writes, semaphore, Objective-C synchronization, and acquiring or relaxed `Atomic` and `ManagedAtomic`. The pthread read/write lock takes a read lock for reads. Variant `default` runs one reader at the requested QoS. Operations are `read` and `readGroups`; there is no pause between reads.

## One operation

`MutexFlag.read()` in `LockFlags.swift`:

```swift
func read() -> Bool {
    value.withLock { value in
        value
    }
}
```

## How it is timed

`BatchTimer.timeBatches` times reads split into sub-batches, with warm-up batches first. `read` has no clock read inside its operation loop. In measured batches, `readGroups` also places clock reads around every 100 reads and stores each duration in a preallocated buffer; warm-up uses plain reads. One `readGroupTime` samples line on thread 0 holds the measured durations in ticks. The main-thread timer writes immediately at start, then every 10 ms with zero leeway. Flag creation, timer start and stop, the final read, checks and encoding are outside batch timing. The acceptance plans start with one million reads per batch, one warm-up and three measured batches, four sub-batches and `userInitiated` QoS.

## What is checked

After batches finish, the reader stops the writer through main-thread work with a one-second deadline, drains pending asynchronous writes, then reads once more. At least one write must have happened, and that read must equal the last written value. A missed start or stop deadline fails the block. Returned true-read counts reach the batch check values and must lie within the batch's read count. Requests reject incomplete 100-read groups within a sub-batch and unrepresentable storage sizes.

## Read the code in this order

1. `HotFlag.swift`: the question, row dispatch, read loop and batch timing.
2. `LockFlags.swift`, `QueueFlags.swift` and `AtomicFlags.swift`: each flag's concrete operations.
3. `MainThreadWriter.swift`, `HotFlagRequest.swift` and `HotFlagChecks.swift`: writer coordination, validation and checks.

## Compiler notes

`readLoop` is `@inline(never)` so each specialized loop remains identifiable in Release disassembly. Each iteration still calls its lock or performs an atomic load, keeping the flag read inside the loop. Acquiring atomic rows use acquire loads and release stores; relaxed rows use relaxed operations. Each experiment owns its concrete state classes; sharing another experiment's wrappers could change its machine code. Release verification uses the [codegen comparison](../../docs/build-checks/2026-11-remaining-experiments.md) against the retained baseline and inspects the HotFlag loops.
