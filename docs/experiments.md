# Experiments

Copied on 2026-11-05 from the study notes (decisions of 2026-11-04 and 2026-11-05). These are the approved specifications; the harness implements them. A change needs Ivan's approval and goes into the study notes first.

## Conditions (Ivan)

- Phones: iPhone 11 Pro Max (A13, 60 Hz) and iPhone 15 Pro Max (A17 Pro, 120 Hz), both on the same iOS 27.x build for timed runs.
- Toolchain, frozen for the whole campaign: Xcode 27.1 (27A9275), Swift 6.4.0 (swiftlang-6.4.0.34.1).
- Deployment target iOS 26.0 for the main runs. A separate iOS 18.0 build for experiments 1 and 3, where `Atomic` and `ManagedAtomic` compile to LL/SC loops instead of LSE instructions.
- Energy is not measured.

## Mechanisms

- `Mutex` (Synchronization).
- `OSAllocatedUnfairLock`, plus a variant that locks with `withLock(flags: .adaptiveSpin)` (iOS 18+; the flag is passed per call, no initializer takes it).
- Heap-allocated `os_unfair_lock`.
- `NSLock`, `NSRecursiveLock`.
- `pthread_mutex` (default attributes), `pthread_rwlock`.
- Serial `DispatchQueue.sync`.
- A concurrent queue with `.barrier` writes, in two rows wherever it appears (experiments 1, 3, 4 and 8A). Reads use `sync` in both rows.
  - "sync write": writes and increments use `sync(flags: .barrier)`. This is the contract of a lock: the write is done when the call returns (Swiftfin, bitchat).
  - "async write": writes and increments use `async(flags: .barrier)` (Firefox, Apollo 1.x), timed to completion.
- `DispatchSemaphore`, as the anti-pattern.
- `actor`; `@MainActor`.
- `Atomic`, for counter and flag operations only. swift-atomics `ManagedAtomic`, for counter and flag operations only: the pre-iOS 18 counterpart of `Atomic`. Each has two rows in the base comparison (Ivan, 2026-11-05): one with the orderings a lock gives (`.acquiring` reads, `.releasing` writes, `.acquiringAndReleasing` increments) and one with `.relaxed` everywhere, as a typical counter does.
- `objc_sync_enter` / `objc_sync_exit`.
- No synchronization, as the single-thread floor.

Excluded: `OperationQueue` (not used to protect state) and `OSSpinLock` (deprecated in iOS 10, unsafe).

## The seven experiments

Experiments 5 and 6 were removed; the numbers are kept to match the decision log. Code and data never use the numbers; they use these names:

| Experiment | ID in requests and data | Swift type |
|---|---|---|
| 1. Base comparison | `baseComparison` | `BaseComparison` |
| 2. Request registry | `requestRegistry` | `RequestRegistry` |
| 3. Hot flag | `hotFlag` | `HotFlag` |
| 4. Data store with transactions | `transactionalStore` | `TransactionalStore` |
| 7. Async code | `asyncCode` | `AsyncCode` |
| 8A. Main thread: image cache | `mainThreadCache` | `MainThreadCache` |
| 8B. Main thread: priority inversion | `priorityInversion` | `PriorityInversion` |
| 9. Creation cost, speed and memory | `creationCost` | `CreationCost` |

1. **Base comparison** (with part B). One background thread reads, writes and increments an `Int` for every mechanism, timed in batches of about a million operations. The actor is called from a background task with one `await` per operation. No-synchronization floor. Part B: the same on 2, 6 and 12 threads, labelled artificial load. Part B results go to this repository; the article may leave them out.
2. **Request registry.** A shared dictionary (download id → object). 4 or 8 threads add and remove entries 50/50, with some work outside the lock. Occasionally one thread cancels all: it iterates and clears under the lock. Two modes: normal (pauses between operations) and burst (no pauses). Locks and queues plus `OSAllocatedUnfairLock` with `.adaptiveSpin`; no atomics, no `pthread_rwlock` or `.barrier` (every operation writes; they go to experiment 4), no actor (experiment 7). Metrics: total time and operations per second; wait time for a sample of operations (median and slowest 1%); cancel-all duration and the waits it causes; context switches. The dictionary must end empty. Thread counts are our choice, not production data. Real code: SDWebImage `runningOperations`, Alamofire `RequestTaskMap`.
3. **Hot flag.** All mechanisms that can protect a `Bool`, including `Atomic` and `ManagedAtomic`; no actor, because the loop is synchronous. A high-priority background thread reads the flag in a loop without pauses; the main thread writes it about every 10 ms. Metrics: cost per read (batches of a million); slow groups of 100 reads (rare waits behind a write); a time estimate for 100, 1,000 and 10,000 reads per second (cost per read × rate; an estimate, not measured CPU share). The reader must see the last written value. Real code: Pocket Casts PR #5186 (per-instance serial queue with `sync` replaced by `OSAllocatedUnfairLock`, "much cheaper", no numbers published); SDWebImage `isCancelled` via `@synchronized` (issue #3631).
4. **Data store with transactions** (two transaction sizes). 10,000 records. A read transaction reads several records and a write transaction updates several records, each under one lock. 6 threads, 98% reads and 2% writes (our choice). Transaction sizes 1 and 20 records (parallel reading can only pay off when reads are long enough). All locks and queues; `pthread_rwlock` and the `.barrier` queue let readers run together. No atomics, no actor (experiment 7). Metrics: transactions per second; read time (each 20-record transaction, groups of 100 for 1-record ones; median and slowest 1%); write time to completion (async `.barrier` writes are timed until they run); writer wait under many readers. Check: the store is split into fixed groups (1 or 20 records, matching the transaction size); each transaction reads or writes one whole group; a write stamps one version on all records of its group, and a reader must see one version within the group. Fixed groups are needed because overlapping record sets show mixed versions even when the code is correct. Real code: Apollo iOS 1.x `ApolloStore` (`.barrier` writes plus a separate `ReadWriteLock`); Apollo iOS 2.0 moved to an async reader-writer lock.
7. **Async code, actor or `Mutex`** (all three parts).
   - A: five caller paths with one `await` per operation: (1) code already on the actor (no hop); (2) a background task calls an idle actor; (3) 50 tasks call one actor at once (queueing); (4) MainActor calls another actor and returns; (5) a background task updates MainActor state. Compared with `Mutex`, `OSAllocatedUnfairLock` and `NSLock` used directly inside the async function.
   - B: 100 operations in one `await`, against 100 separate awaits and 100 operations under one lock.
   - C: the same code with the Xcode 27.1 template defaults (MainActor default isolation, Approachable Concurrency), in Swift 6 mode without them, and with `@concurrent`. Expected: 0, 2 and 2 thread switches for MainActor → nonisolated async.
   - Metrics: time per operation in batches; per-call time for path 3 (median, slowest 1%); main-thread time spent on hops for paths 4 and 5; a separate Instruments run only to show where threads switch; final state check. Real code: Nuke 13 (a global actor instead of queues), Apollo iOS 2.0.
8. **Main thread** (both parts).
   - A: programmatic scrolling (60 Hz on iPhone 11 Pro Max, 120 Hz on 15 Pro Max). The main thread reads an image cache (URL → image) several times per frame while 2–4 background threads write decoded images, about 95/5. All locks and queues including `pthread_rwlock` and `.barrier`, plus a variant with the cache on the main actor (background writes `await` to main). Metrics: every main-thread read wait (median, slowest 1%); display-link callback gaps against 8.33 / 16.67 ms (they show main-thread delays per frame, not render-server hitches, so on their own they are not reported as dropped frames). Main never sees a half-written entry. The achieved frame interval is recorded in each run.
   - B: a low-QoS holder (`.utility` and `.background`) does a fixed amount of CPU work under the lock (about 5 ms on an idle core); the main thread tries 1 ms later; load threads with a QoS above the holder's keep all cores busy, so the holder cannot get a core without a boost. All locks and queues plus an actor busy with low-priority work. Record the holder's core type. Reference tools: `os_unfair_lock` (donates priority) and `DispatchSemaphore` (does not); a separate Instruments run shows the holder's priority. Metrics: main-thread arrival-to-acquire time, at least 1,000 trials per mechanism, compared with the two references, the frame budgets and the 250 ms hang threshold. It answers the `NSLock` priority question only if the two references differ.
   - Real code: SDWebImage memory cache (`weakCacheLock`), Mile-A-Day PR #439, Firebase Sessions #15394.
9. **Creation cost, speed and memory.** All mechanisms (including the actor, `Atomic` and `ManagedAtomic`) except `objc_sync_enter`. A simple class with one `Int` field protected by each mechanism, plus the same class without protection. Create and destroy 10,000 and 100,000 objects. Metrics: creation and destruction time per object (batches); live memory blocks and extra bytes per object from malloc statistics before and after (these counters show live blocks, not every allocation event), minus the unprotected class. Memory must return to the starting level after destruction. Output: a memory-versus-speed table that pairs these numbers with the per-operation cost from experiment 1. Real code: Firebase (one lock per property), Pocket Casts (one queue per flag before PR #5186).
   - Why `objc_sync_enter` is not in this experiment (Ivan asked to keep this note): it keeps no lock in the object. On `objc_sync_enter(obj)` the Objective-C runtime attaches a record from a shared list to the object; after `objc_sync_exit` the record becomes free and can be given to another object, and the runtime never deletes these records (objc4 `runtime/objc-sync.mm`: "we never free these guys"; read on the `main` branch, the iOS 27 build is unverified). Its memory depends on how many objects are locked at the same time, not on how many objects exist, so "bytes per object" does not apply. It stays in the other experiments.
   - `@MainActor` stays in, with objects created and destroyed on the main thread, as UIKit code does. Zero extra memory per object is expected; that is itself a result.

## Settings of a new Xcode 27.1 app (experiment 7C)

Read from the Xcode 27.1 project templates on 2026-10-20:
- `SWIFT_VERSION = 5.0`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, `SWIFT_COMPILATION_MODE = wholemodule` (Release), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT` and `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES` default to the value of `SWIFT_APPROACHABLE_CONCURRENCY`, so the template turns them on.
