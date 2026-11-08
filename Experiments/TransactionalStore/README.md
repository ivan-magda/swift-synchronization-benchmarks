# Transactional store (experiment 4)

## Question

What do synchronous reads and transactional writes cost when six workers share 10,000 records, read 98% of the time and write 2% of the time? How does a transaction of twenty records compare with one record?

## Results

**98% reads did not make shared-reader locking faster.** For these short
transactions, `Mutex`, `OSAllocatedUnfairLock` and `pthread_mutex` completed the
most work per second.

Selected [7 November 2026 results](../../docs/results.md), iPhone 15 Pro Max,
ios26 target, six threads and 20 launches. Throughput counts completed read/write
transactions across all threads and includes draining async writes.

| Mechanism | One-record transactions (million/s) | Twenty-record transactions (million/s) |
| --- | ---: | ---: |
| `Mutex` | 34.81 | 9.37 |
| `OSAllocatedUnfairLock` | 34.67 | 9.50 |
| `pthread_mutex` | 35.10 | 9.29 |
| `NSLock` | 22.48 | 8.05 |
| `pthread_rwlock` | 3.88 | 3.07 |
| Concurrent queue, sync barrier writes | 1.69 | 1.60 |
| Concurrent queue, async barrier writes | 2.09 | 1.47 |
| Serial queue | 0.46 | 0.45 |

Compare mechanisms within a column. The two transaction sizes also use different
read-timing frequency and write placement, so the change between columns is not
an isolated measurement of record count.

Throughput is only part of the result. For twenty-record writes, `pthread_mutex`
had a p99 of **14.94 µs**, versus **7.96 µs** for `Mutex`, despite similar throughput.
Adaptive spin lowered write p99 to **6.21 µs**, but reduced throughput to
**5.80 million transactions/s**. Write timing ends inside the protected section,
before unlock and return.

The broad throughput result repeated on iPhone 11, although rwlock came much
closer to Mutex for twenty records. Start with an ordinary lock for this kind of
short work; choose shared-reader protection based on measurements, not the read
percentage alone.

## Rows

Thirteen rows compare `Mutex`, allocated unfair locks (default and adaptive spin), a raw unfair lock, `NSLock`, `NSRecursiveLock`, pthread mutex and read/write lock, serial queue, concurrent queue with synchronous or asynchronous barrier writes, semaphore and Objective-C synchronization. Each store owns one array of 10,000 records, partitioned into fixed groups of one (`singleRecord`) or twenty (`twentyRecords`). Variant `default` uses six workers at the requested QoS. Read/write locks take shared read locks; concurrent queues allow concurrent readers. Every write increments the group's version and stores that version as every record's value.

## One operation

`PthreadReadWriteLockStore.readGroup(_:)` in `LockStores.swift`:

```swift
func readGroup(_ group: Int) -> GroupRead {
    let result = pthread_rwlock_rdlock(lock)
    assert(result == 0)
    defer {
        let result = pthread_rwlock_unlock(lock)
        assert(result == 0)
    }
    return records.readGroup(group, size: groupSize)
}
```

The array scanner sums every value and compares every version with the first record's version while the protection is held.

## How it is timed

Every worker's immutable `OperationList` is generated before the block using `SplitMix64`, the request seed and worker index. Each batch has exactly `operationsPerBatch / 50` writes. Writes occupy seeded boundaries between complete read runs; group indexes come from the same generator. A read run holds 100 reads for `singleRecord` and one read for `twentyRecords`. Mechanisms receive identical lists for the same seed, worker and batch size.

`BatchTimer.timeBatches` times each batch and drains pending asynchronous writes before its end tick. Sub-batch k starts at run `runsPerBatch × k / subBatches`; uneven run counts therefore remain whole. In measured batches, clock reads surround each read run. Every write records its completion tick as the last statement inside its critical section, before unlocking. Its measured duration starts just before the call, so asynchronous write durations include queue wait and execution rather than submission alone. Buffers are allocated before the block and encoded after workers join. Warm-up adds no samples.

Per-worker samples use ticks: `hundredReadsTime` for `singleRecord`, `readTime` for `twentyRecords`, and `writeTime` for both. The acceptance plan uses 50,000 transactions per batch, one warm-up and three measured batches, four sub-batches and `userInitiated` QoS.

## What is checked

Every read contributes its sum to the batch check value and increments a worker's violation counter if it observes different versions in one group. After every worker and queued write finishes, every group's final version must equal its write count across all warm-up and measured lists. Its value sum must equal that version times the group size, and versions must agree. The check also consumes each batch sum and bounds it by the total possible writes. The detail is, for example, `violations 0; groups 10000 with expected versions`.

Requests require a multiple of 5,000 transactions per batch, six workers, supported unique rows and operations, and representable storage and sum bounds.

## Read the code in this order

1. `TransactionalStore.swift`: the question, row dispatch, measured loop and batch setup.
2. `Record.swift`, `LockStores.swift` and `QueueStores.swift`: record scanning, mutations and concrete protection.
3. `OperationList.swift`, `TransactionalStoreRequest.swift` and `TransactionalStoreChecks.swift`: seeded inputs, worker buffers, validation and correctness.

## Compiler notes

`operationLoop` is `@inline(never)` so its concrete specializations remain identifiable in Release disassembly. Each read must retain its lock pair or queue synchronization and load every record's value and version; the returned sums reach the batch check. Every write must retain synchronization and update every record before recording its completion tick. Array mutation and dispatch runtime costs remain ordinary Swift costs. Stores are concrete types owned by this experiment. Release settings and exclusivity checking remain unchanged. The [Release record](../../docs/build-checks/2026-11-remaining-experiments.md) compares experiments 1, 7 and 8B against the retained baseline and inspects all transactional-store rows.
