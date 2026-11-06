# Async code (experiment 7)

## Question

What does an increment cost when async code calls an actor, the main actor or a lock along five caller paths? How do grouping 100 operations and changing Swift isolation settings affect that cost?

## Rows

7A compares code already on an actor (`onActor`), one background task calling a counter (`fromBackgroundTask`), 50 competing tasks (`fromManyTasks`), a main-actor caller (`fromMainActor`), and a background caller updating main-actor state (`toMainActor`). The middle three paths compare an actor with `Mutex`, `OSAllocatedUnfairLock` and `NSLock`; the first and last use their named actor. 7B compares one actor await per 100 operations, one await per operation, and one mutex acquisition per 100 operations over 128 counters. 7C calls a probe from the main actor with template defaults, Swift 6 settings or `@concurrent`.

## One operation

Path 2, the actor loop in `CallerPaths.fromBackgroundTask`: one background-task call per increment.

```swift
runOperations: { _, _, count in
    for _ in 0..<count {
        await counter.increment()
    }
    return 0
}
```

Path 4, the actor loop in the `@MainActor` `CallerPaths.timeOnMainActor` function: one call to the other actor and return to the main actor per increment.

```swift
runOperations: { _, _, count in
    for _ in 0..<count {
        await counter.increment()
    }
    return 0
}
```

Both call `CounterActor.increment()` in `AsyncCodeCounters.swift`, whose operation is `value &+= 1`. The lock loops call the corresponding counter synchronously.

## How it is timed

Batch rows time the requested number of operations, split into sub-batches with CPU observations; warm-up batches come first. The timer runs inside the actor for `onActor`, inside the main actor for path 4 and 7C, and inside a detached task for paths 2 and 5 and 7B. Path 3 times exactly one call between two clock reads after untimed warm-up and a task barrier; its lock call is synchronous. Counter creation, final-state reads, checks and encoding sit outside timing. Paths 4, 5 and 7C also record main-thread CPU time immediately outside each batch's timestamps.

## What is checked

Each counter must include every warm-up and measured increment from every task. The grouped rows check the sum of all 128 counters. Each isolation probe must count every call; template-default calls must all run on the main thread, while the Swift 6 and `@concurrent` calls must run off it. Request validation rejects unsupported rows, incomplete groups and work counts that overflow.

## Read the code in this order

1. `AsyncCode.swift`: the questions, rows and switch to each path.
2. `CallerPaths.swift`, `Batching.swift`, `IsolationSettings.swift` and `AsyncCodeCounters.swift`: the loops and concrete operations.
3. `AsyncCodeRequest.swift` and `AsyncCodeChecks.swift`: validation and arithmetic, which you may skip; shared timing and recorders live under `Harness/`.

## Compiler notes

The `onActor` row keeps `@inline(never)` on `CounterActor.incrementAsync()`: without it, Release folds the repeated increments into one addition. The attribute belongs to the operation, while `runBatchesOnActor` keeps timing inside the same actor. Lock callers specialize to concrete counters. Caller paths retain explicit timers: the helper probe changed timed continuations even while preserving isolation. See the [operation-preservation build check](../../docs/build-checks/2026-11-operation-preservation.md#experiment-7-onactor) and the [readable-experiment comparison](../../docs/build-checks/2026-11-readable-experiments.md#rejected-preservation-probes-and-folder-deviations).
