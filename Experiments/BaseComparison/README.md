# Base comparison (experiment 1)

## Question

What does reading, writing or incrementing a shared `Int` cost with each synchronization mechanism? How does that cost change with 2, 6 or 12 threads of artificial contention?

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
