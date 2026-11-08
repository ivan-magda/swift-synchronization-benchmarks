# Priority inversion (experiment 8B)

## Question

How long does the main thread wait for a low-QoS holder when higher-QoS work keeps every CPU busy? Does each mechanism let the holder finish soon enough, compared with the `os_unfair_lock` and `DispatchSemaphore` references?

## Results

A cheap uncontended lock does not guarantee a short wait when another thread
already holds it. Under this CPU load, most ordinary locks had waits around
13 ms on iPhone 15. Semaphore, rwlock and synchronous barrier writes had much
longer waits.

This is a **partial campaign: three launches per phone**, with 100 measured trials
per mechanism/QoS in each launch. The table shows iPhone 15 Pro Max, ios26 target,
and a `background` holder from the [7 November 2026 campaign](../../docs/results.md).
CPU load lasted 300 ms; holder work was calibrated to about 5 ms without that load.
Wait is measured from main-thread arrival to protected access. The table reports
the median of the three launch medians.

| Mechanism | Median wait (ms) | Waits >250 ms, out of 300 |
| --- | ---: | ---: |
| `Mutex` | 12.95 | 0 |
| `OSAllocatedUnfairLock` | 12.97 | 0 |
| `NSLock` | 12.96 | 0 |
| Concurrent queue, sync barrier writes | 61.94 | 28 |
| `DispatchSemaphore` | 65.63 | 7 |
| `pthread_rwlock` | 68.55 | 57 |

Long waits varied sharply between launches. Background rwlock produced 28, 1 and
28 waits above 250 ms; sync barrier produced 27, 1 and 0. These counts do not
establish a stable probability for an application. On iPhone 11, the same slower
group had medians around 21–22 ms and no waits above 250 ms.

Across both QoS groups, iPhone 15 had 93 censored trials: access occurred only
after the load deadline. Their waits under sustained load are lower bounds near
299 ms, not exact 300 ms observations. All medians in the table remain identifiable
with those bounds included.

The actor row has different semantics. Its timer ends when the actor begins
protected access, before returning to MainActor. The awaiting task suspends; this
is not synchronous main-thread blocking.

Mutex remains a reasonable starting point here, but reducing the work held under
the lock matters too. The timing results alone do not prove a particular runtime
or kernel priority-donation mechanism.

## Rows

Fourteen mechanisms × two holder QoS levels (`utilityHolder` and `backgroundHolder`): `Mutex`, allocated unfair lock, allocated unfair lock with adaptive spin, `os_unfair_lock`, `NSLock`, `NSRecursiveLock`, pthread mutex, pthread read-write lock, Objective-C synchronization, serial queue, synchronous barrier queue, asynchronous barrier queue, semaphore and actor. Each block has one controller pthread, one holder pthread and one load pthread per CPU. The actor and asynchronous barrier submit holder work to their own executor or queue.

## One operation

The `os_unfair_lock` row's holder writes the trial index under the lock (`ContendedUnfairLock` in `ContendedLocks.swift`):

```swift
func hold(trial: Int, work: HolderWork, timestamps: HolderTimestamps) {
    os_unfair_lock_lock(lock)
    timestamps.markAcquired()
    let resultCorrect = work.run()
    value = trial
    timestamps.markReleased(resultCorrect: resultCorrect)
    os_unfair_lock_unlock(lock)
}
```

The main side reads that index after acquiring the same lock:

```swift
@MainActor
func touch(done: @escaping @Sendable (_ acquired: UInt64, _ observedTrial: Int) -> Void) {
    os_unfair_lock_lock(lock)
    let acquired = Clock.now()
    let observedTrial = value
    os_unfair_lock_unlock(lock)
    done(acquired, observedTrial)
}
```

## How it is timed

One trial starts the low-QoS holder while CPUs are free and waits for its acquire mark, then starts a fixed interval of higher-QoS CPU load. The main thread targets holder acquire + 1 ms (configurable), records its actual arrival immediately before `touch`, and records acquire inside the protected access. Holder marks stay inside its critical section, around the fixed reference-loop work and trial-index write. Warm-up trials precede measured trials; all completed trials retain their raw ticks and CPU observations. Allocation, trial-array bookkeeping, pauses, checks and encoding stay outside these intervals. The acquire wait has a two-second deadline; completion waits share load stop + five seconds. A timeout stops the block before another reset or trial.

## What is checked

Every holder must compute the reference result, every main-side observation must equal the trial index, and a main thread arriving during the hold must acquire no earlier than the holder's release. Timeouts fail the block. A trial is valid when arrival occurs during the hold and load, and acquire is no later than load stop; acquire after load stop is censored. Other arrivals are invalid. Censored and invalid trials remain in the output and do not alone fail correctness.

## Read the code in this order

1. `PriorityInversion.swift`: the question, mechanism switch, protocol and five steps of one trial.
2. `ContendedLocks.swift`, `ContendedQueues.swift` and `ContendedActor.swift`: each mechanism's `hold` and `touch`.
3. `PriorityInversionRequest.swift`, `PriorityInversionChecks.swift` and `TrialSupport.swift`: validation, classification and coordination, which you may skip.

The 227-line entry file exceeds the approximate one-screen target so the five trial steps, protocol and fourteen-row switch remain visible together. TrialSupport holds the bookkeeping.

## Compiler notes

Each mechanism keeps its ordinary critical-section statements and timestamp positions; `touch` stays on the main actor. The Release comparison covers `hold`, `touch`, their closures and continuations, as well as the other experiments' measured units. Moving these declarations changes file-name lengths and line numbers embedded in executor-check diagnostics; those metadata-only hash differences retain the same instructions and calls. No new inline or exclusivity attributes are needed. See the [readable-experiment build check](../../docs/build-checks/2026-11-readable-experiments.md#reasons-and-measurement-boundaries) for the three exact diagnostic differences.
