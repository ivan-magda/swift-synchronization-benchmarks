# Base comparison (experiment 1)

## Question

What does reading, writing or incrementing a shared `Int` cost with each synchronization mechanism? How does that cost change with 2, 6 or 12 threads of artificial contention?

## Results

With one thread, `Mutex`, `OSAllocatedUnfairLock` and `os_unfair_lock` took almost
the same time. Using the raw lock did not buy a meaningful improvement.

Selected results from the [7 November 2026 campaign](../../docs/results.md),
iPhone 15 Pro Max, ios26 target, 20 launches. Each value is the median of batch mean times
per operation across launches; it is not an individually timed call. The actor
row uses one background Task and one `await` per increment.

| Mechanism | Time per increment (ns) |
| --- | ---: |
| `Mutex` | 1.855 |
| `OSAllocatedUnfairLock` | 1.856 |
| `os_unfair_lock` | 1.855 |
| `NSLock` | 6.359 |
| `Atomic`, acquire/release | 1.879 |
| `actor` | 62.773 |
| Serial `DispatchQueue` | 88.233 |

With two threads, the acquire/release atomic counter completed about **310 million
increments/s**, versus **102 million** with `Mutex`. That makes Atomic worth
considering for this operation; it does not make it a replacement for protecting
several related fields.

The ranking changes with contention. On iPhone 11, for example, `NSLock` beat
`Mutex` with two threads despite being slower without contention. Twelve workers
also oversubscribe the phones' six CPUs, and their batch windows do not always
overlap. Treat those rows as the achieved workload throughput, not a fixed level
of simultaneous contention.

`Mutex` is a good starting point for short synchronous state access. The actor
and queue results describe the calls made here, not the cost of an entire async
subsystem.

## Rows

Each of the 20 mechanisms runs `read`, `write` and `increment`: ten locks, semaphore or monitor rows; three queue rows; an actor and the main actor; four atomic rows; and a single-thread floor. The variants use 1, 2, 6 or 12 background workers. The floor runs only with one thread. Actor rows use background tasks with one `await` per operation. Atomic rows compare acquire/release ordering with relaxed ordering.

## One operation

`MutexInteger.increment()` from `LockIntegers.swift`:

```swift
func increment() {
    value.withLock { value in
        value &+= 1
    }
}
```

## How it is timed

The clock covers batches of the requested number of operations, divided into sub-batches for CPU observations. Warm-up batches precede measured batches. Workers start together; actor rows use detached tasks. Async queue mutation batches include the wait for their queued writes to finish. Synchronous reads omit executor probes and drains so instrumentation does not add queue barriers. Counter creation, worker startup, final-state checks and result encoding sit outside the timed batches.

## What is checked

Reads must return the initial value and leave it unchanged. A write must leave one writer's last encoded value. Increments must produce the exact total, including warm-up work; actor rows also check the sum of the new values returned by every increment. Validation rejects work counts whose sums or encoded values cannot fit in `Int`.

## Read the code in this order

1. `BaseComparison.swift`: mechanism selection and the measured loops.
2. `LockIntegers.swift`, the `QueueIntegers/` files, `AtomicIntegers.swift`, `ActorIntegers.swift` and `UnsynchronizedInteger.swift`: concrete operations.
3. The rest: `SharedInteger.swift`, request validation, checks and timing plumbing, which you may skip.

The entry file has 125 lines. Queue types keep three separate source files and timing keeps explicit `BatchTimer` calls because merging files or adopting callback helpers changed measured code.

## Compiler notes

The single-thread floor uses separate relaxed atomic loads and stores so the compiler cannot fold the loop away; this does not make its increment safe for concurrent callers. Measured loops keep `@inline(never)` so their Release disassembly remains identifiable. Concrete queue storage avoids the extra exclusivity checks introduced by generic inout callbacks. See the [operation-preservation build check](../../docs/build-checks/2026-11-operation-preservation.md) and the [readable-experiment comparison](../../docs/build-checks/2026-11-readable-experiments.md), which records the permitted concrete-lock layout and merging differences.
