# Main-thread image cache (experiment 8A)

## Question

How much does a cache read delay a scrolling UIKit screen while two to four background writers simulate image preparation and replace cached images?

## Results

Queue lookups took about four times as long as Mutex lookups, but that difference
did not produce an advantage in the measured callback-delay metric.

Selected [7 November 2026 results](../../docs/results.md), iPhone 15 Pro Max,
ios26 target, four background writers and 12 launches. Timings cover the cache
lookup in `cellForItemAt`, not the rest of cell configuration. Each value is the
median of the corresponding per-launch percentile. Each block recorded 1,800
display-link callbacks after 60 warm-up callbacks.

| Mechanism | Lookup p50 (µs) | Lookup p99 (µs) |
| --- | ---: | ---: |
| `Mutex` | 2.02 | 8.16 |
| Direct `MainActor` access | 2.10 | 8.29 |
| `NSLock` | 2.42 | 10.02 |
| Serial queue | 7.94 | 19.25 |
| Concurrent queue, sync barrier writes | 8.21 | 20.21 |
| Concurrent queue, async barrier writes | 8.27 | 19.89 |

Across both writer configurations, neither phone had a callback gap greater than
1.5 times the scheduled display interval: **0 of 604,464 gaps per phone**. This
measures CADisplayLink callback spacing, not render-server hitches or all dropped
frames. A cheaper lookup did not establish smoother scrolling in this workload.

The MainActor cache was read directly by UIKit, without an actor hop. There is no
speed reason here to move an already MainActor-owned cache behind a Mutex.

The cache was prefilled, all reads were hits, and writers updated it infrequently.
Their preparation work simulated decoding; it did not decode image files. Two
writers paused 350 ms each; four paused 700 ms, keeping similar aggregate pacing.
The MainActor variant completed slightly fewer writes, so this is not an exact
equal-write-count comparison.

## Rows

Fourteen rows compare Mutex, allocated unfair locks (default and adaptive spin), a raw unfair lock, NSLock, NSRecursiveLock, pthread mutex and read/write lock, serial queue, concurrent queue with synchronous or asynchronous barrier writes, semaphore, Objective-C synchronization and a main-actor cache. Each row owns its dictionary and protection. Read/write locks take a read lock for lookups; queue readers use sync. Main-actor reads are direct and detached writers await each main-actor store. Variant `default` uses operation `scroll`; `threads` is the number of writers at the requested QoS.

At block setup, CacheImages draws 64 images and builds 1,000 URL keys. Every key is filled before scrolling begins. Writers replace entries for existing keys, so dictionary capacity does not grow. Each seeded writer chooses a key and an image, runs exactly `decodeIterations` of referenceLoop outside the cache, stores the complete image/index pair, then pauses `writeIntervalMicroseconds`. The decode result reaches the correctness detail. An immutable per-image work-count array, selected by the runtime image index, keeps the configured work associated with each write. The pilot adjusted the pause toward a 95/5 read/write ratio. The reported reads cover measured frames only; writes include writer startup and warm-up through frame completion. Those different windows prevent interpreting the raw counts as an exact read/write ratio.

## One operation

`NSLockImageCache.image(for:)`, called by `ScrollingScreen.collectionView(_:cellForItemAt:)`:

```swift
func image(for key: String) -> CachedImage? {
    lock.lock()
    defer {
        lock.unlock()
    }
    return images[key]
}
```

The cell dequeues normally, times this lookup and assigns the returned UIImage to its UIImageView. UIKit decides when cells are needed; there is no synthetic read loop.

## How it is timed

A full-screen UICollectionView has four columns of square cells, 10,000 items and UIKit's default prefetching. Item i uses key i modulo 1,000. DisplayLinkLoop advances the content offset by `scrollPointsPerSecond / maximumFramesPerSecond` points per callback. The step is fixed per callback: delayed callbacks reduce the actual scrolling speed over elapsed time. At the bottom it wraps to the top. Each row uses the same geometry, step, frame count and seed.

After `warmupFrames`, Clock.now brackets only the application's cache lookup inside the real cell callback. A fixed read buffer is allocated before the block using scroll distance, cell size, visible rows and a prefetch margin. It never grows; overflow fails correctness. Measured frames also record their start tick and `targetTimestamp - timestamp` in nanoseconds. Frame gaps show main-thread delays per frame, not render-server hitches, and include the real UIKit work of configuring cells. The frame-interval value is the display link's scheduled interval; gaps between frameStart values reveal missed or delayed callbacks.

Blocks emit no batch lines. Their three block-level samples lines are `readTime` (ticks, one value per measured read, any positive count), `frameStart` (ticks, exactly `frames` values) and `frameInterval` (nanoseconds, exactly `frames` values). Warm-up contributes none of these values. Buffers are copied and encoded after measurement.

A coordinator starts the display loop only after the writers are ready. Installation, display completion and removal use deadline-bounded main-thread coordination. The deadline is `(warmupFrames + frames) × 50 ms + 5 s`. A relaxed atomic stops writers at frame completion. Paused pthread writers wake immediately; detached writers are cancelled to wake their pauses and still finish any awaited store. Writer completion is bounded; counters are read only after completion. The asynchronous barrier cache drains every submitted write before the block ends.

## What is checked

`mainThreadCache.scroll` requires all measured frames before the deadline, at least one measured read, no read-buffer overflow, at least one store by every writer and no missing or inconsistent entry. Every measured read checks that its UIImage is identical to `images[imageIndex]`, with index bounds checked first. Detail includes `frames 600/600; reads 950, writes 50, violations 0`, overflow and the decode checksum.

Requests require `frames >= 1`, `warmupFrames >= 0`, nominal scroll speed 1…20,000 points per second (used to derive the fixed step per callback), positive decode work and a pause fitting UInt32 microseconds. Frame duration and storage arithmetic must fit before allocation. The acceptance plan includes two and four writers, 60 warm-up and 600 measured frames. These acceptance inputs passed on the Simulator and on both phones with pinned iOS builds; the main-campaign settings are described in Results above.

## Read the code in this order

1. MainThreadCache.swift: row selection and the two writer loops.
2. ScrollingScreen.swift: actual cells, frame movement and timing buffers.
3. CacheImages.swift, LockImageCaches.swift, QueueImageCaches.swift and MainActorImageCache.swift: immutable image fixtures and concrete mechanisms.
4. MainThreadCacheChecks.swift and MainThreadCacheRequest.swift: lifecycle, publication, checks and validation.

## Compiler notes

The cell callback and writer loops are `@inline(never)`. Release inspection must show a lock/unlock pair or dispatch_sync around each protected lookup, with a direct dictionary lookup for mainActor. Decode work must remain inside each writer iteration and reach the checksum. Dynamic exclusivity and all Release settings stay unchanged. The experiment owns its concrete mechanism types; it does not share another experiment's state wrappers. The [Release record](../../docs/build-checks/2026-11-remaining-experiments.md) records the current reader, writer and consumer inspection.
