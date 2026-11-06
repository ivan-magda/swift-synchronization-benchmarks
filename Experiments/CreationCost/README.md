# Creation cost (experiment 9)

## Question

What does creating and destroying a class holding one protected `Int` cost in time and live heap space? How much does each mechanism add over the unprotected class?

## Rows

Fifteen rows cover the unprotected class, `Mutex`, allocated and raw unfair locks, `NSLock`, `NSRecursiveLock`, pthread mutex and read/write lock, serial and concurrent queue, semaphore, actor, main actor, `Atomic` and `ManagedAtomic`. Variant `default` runs one thread, with `create` and `destroy` operations. The raw unfair lock and pthread locks have stable heap addresses. The concurrent queue is the synchronous-barrier row's single queue.

`objc_sync_enter` keeps no lock in the object. The Objective-C runtime attaches a record from a shared list when an object is locked; after unlock that record can serve another object, and the runtime never deletes these records (objc4 `runtime/objc-sync.mm`: “we never free these guys”; read on `main`, the iOS 27 build is unverified). Its memory depends on simultaneous locking, so bytes per existing object does not apply. It stays in other experiments. Adaptive spin and atomic ordering change access behavior, rather than the stored mechanism; asynchronous and synchronous barrier writes use the same concurrent-queue representation. Those duplicate creation rows are omitted. Main-actor objects stay in: UIKit creates and destroys them on the main thread, and zero extra memory per object is itself a result.

## One operation

The creation loop in `CreationCost.swift` appends an ordinary concrete class:

```swift
for _ in 0..<count {
    objects.append(make(counter))
}
```

For example, `MutexObject` stores `Mutex<Int>(0)` and the relaxed deinit counter. Destruction removes the requested number of objects with `objects.removeLast(count)`; every object's `deinit` increments that counter.

## How it is timed

Before the block, a `ContiguousArray` reserves space for one batch, and logs, sample storage and a reusable coordination gate are allocated. `create` times sub-batches of initialization and appends, then destroys the objects outside timing. `destroy` initializes outside timing and times `removeLast` in sub-batches. CPU readings mark sub-batch edges. Each main-actor batch runs through `waitForMainThreadWork` with a ten-second deadline and waits for the caller’s submission cleanup before sampling; a timeout fails the check and leaves executor-owned storage unread. For worker batches, the main thread parks for at most one second while the worker creates, samples and destroys; a missed park deadline fails completion. Malloc statistics and allocated-range enumeration run outside the timed region with the other harness threads idle. Enumeration uses a direct self-reader and allocation-free callbacks, without manually locking zones: Nano may allocate temporary scratch memory internally. Framework activity elsewhere in the process can still change global counts. Warm-up absorbs runtime initialization. Each `create` batch, including warm-up, contributes before-create, after-create and after-destroy blocks and bytes to six block-level samples lines; `destroy` writes none. Acceptance uses 10,000 and 100,000 objects per batch, one warm-up and three measured batches, and four sub-batches.

## What is checked

The relaxed deinit count equals all objects created, including warm-up. After each after-create snapshot, every retained object must have a nonzero `malloc_size`, proving heap allocation outside timing. Aggregate malloc counters cannot prove this: xzone statistics can count cached free slots as in use, so allocating from them need not increase the block count. For return and growth checks, the allocator’s public `MALLOC_PTR_IN_USE_RANGE_TYPE` enumeration counts allocated pointers outside timing, excluding cached free slots. After destruction, these live blocks may exceed their batch’s baseline by at most one percent of its object count; any later increase above an earlier post-destruction count has the same allowance. An enumeration error fails the check. Details report the three raw counts, enumerated live counts and growth. These are allocator-reported blocks and bytes, including allocator cache accounting, not total allocation events. The host can subtract the unprotected row's bytes per object when preparing the memory-versus-speed table.

## Read the code in this order

1. `CreationCost.swift`: dispatch and measured creation/destruction loops.
2. `ProtectedObjects.swift`: the fifteen concrete classes and deinit counter.
3. `CreationBatches.swift`, `MallocStatistics.swift`, `CreationCostRequest.swift` and `CreationCostChecks.swift`: timing, sampling, validation and checks.

## Compiler notes

The measured loops use `@inline(never)` to remain identifiable in Release disassembly. The array keeps every class alive through the after-create snapshot; no stack-promoted substitute satisfies the per-object heap check. Ordinary Release optimization and exclusivity checking stay enabled. Each experiment owns its classes. Release verification compares earlier experiments' machine code with the [retained baseline](../../docs/build-checks/2026-11-readable-experiments.md), then checks object allocation and release in these loops.
