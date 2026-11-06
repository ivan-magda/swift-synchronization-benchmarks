# Priority inversion (experiment 8B)

## Question

How long does the main thread wait for a low-QoS holder when higher-QoS work keeps every CPU busy? Does each mechanism let the holder finish soon enough, compared with the `os_unfair_lock` and `DispatchSemaphore` references?

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

## Compiler notes

Each mechanism keeps its ordinary critical-section statements and timestamp positions; `touch` stays on the main actor. The Release comparison covers `hold`, `touch`, their closures and continuations, as well as the other experiments' measured units. Moving these declarations changes file-name lengths and line numbers embedded in executor-check diagnostics; those metadata-only hash differences retain the same instructions and calls. No new inline or exclusivity attributes are needed. See the [operation-preservation build-check method](../../docs/build-checks/2026-11-operation-preservation.md#build-and-inspection-method).
