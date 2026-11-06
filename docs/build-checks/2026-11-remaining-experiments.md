# Remaining-experiment Release checks, 2026-11-06

Task 8 Steps 1–2 cover clean source `9b6c5f6`. The later [physical-phone acceptance](../phase-3-acceptance.md) passed on both phones. The initial plan commit `99f20ce` and Task 1 baselines remain intact. This checkpoint changes documentation only.

## Reproduction and retained evidence

Toolchain: Xcode 27.1 (27A9275), Swift swiftlang-6.4.0.34.1, XcodeGen 2.46.0. Archived clean HEAD into `build/private/remaining-experiments/task-eight-code`, a 15-character sibling matching `baseline-source` in path length. Generated its project with XcodeGen. All 117 tracked Swift source files match the archive before and after building.

From the repository root, for `TARGET=26` and `TARGET=18`:

```sh
git archive 9b6c5f6 | tar -x -C build/private/remaining-experiments/task-eight-code
xcodegen generate --spec build/private/remaining-experiments/task-eight-code/project.yml
xcodebuild build \
  -project build/private/remaining-experiments/task-eight-code/SyncBench.xcodeproj \
  -scheme SyncBench -configuration Release -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=${TARGET}.0 \
  -derivedDataPath build/private/remaining-task-8/release-ios${TARGET} -quiet
python3 scripts/codegen_compare.py \
  build/private/remaining-experiments/baseline-ios${TARGET}/Build/Products/Release-iphoneos/SyncBench.app/SyncBench \
  build/private/remaining-task-8/release-ios${TARGET}/Build/Products/Release-iphoneos/SyncBench.app/SyncBench \
  --report build/private/remaining-task-8/codegen-ios${TARGET}.json
python3 scripts/codegen_compare.py --dump \
  build/private/remaining-task-8/release-ios${TARGET}/Build/Products/Release-iphoneos/SyncBench.app/SyncBench
```

Create the empty archive directory before extracting; archive and generate once, then build each target. Both builds exited 0 with empty logs. The commands use no `SWIFT_*` overrides; `-O`, whole-module optimization and default exclusivity remain enabled.

Ignored `build/private/remaining-task-8/` retains both complete comparator reports, full disassemblies, named normalized dumps, five experiment-selected dumps per target, all missing-unit names and closest instruction diffs, and row/caller/consumer evidence. `inspect.py`, `inspect-other-rows.py`, `inspect-creation.py`, `inspect-cache.py` and `preserve-new-units.py` retain the checks and structured indexes. The selected dump includes callbacks, merged aliases, caller paths, checks and async continuations. Private artifacts contain tool-local paths and stay private. Row-table lines refer to `full-disassembly-ios26.txt` and, for the second hot-flag target, `full-disassembly-ios18.txt` in that directory.

| Target | Original baseline kept | Missing | Added | Executable SHA-256 |
| --- | ---: | ---: | ---: | --- |
| iOS 26 | 811/853 | 42 | 1,088 | `e23e7ed950526d3696f672a67e3f92bb9db7e89e3aeae3d938b1c1aecd903ea1` |
| iOS 18 | 937/979 | 42 | 1,083 | `a56f17bebb4b382b99e6a6964b552ccf29de1df7b93806107b907be5766ae8f8` |

## Original missing units

Both original comparisons exit 1. The exact 42 missing hashes match across targets and match the final Task 7 iOS 26 report. Each missing region has an inspected candidate with the same owner. No additional missing unit appears.

| Owner | Units | Observed reason and timing boundary |
| --- | ---: | --- |
| `ExperimentRegistry.makeExperiment` | 7 | Additional experiment dispatch changes branches, layout and registers; construction precedes blocks. |
| `AsyncCodeRequest.blocks` | 29 | Larger request scratch/copy storage changes the validator frame, epilogue and branch offsets; validation precedes timing. |
| `CallerPaths.appendCallTimes` | 3 | The larger embedded request shifts BlockContext field offsets; sample encoding follows worker completion. |
| TrialLine ArrayBuffer/ContiguousArray growth | 3 | Shared metadata-driven growth becomes concrete 128-byte TrialLine allocation/copying. `TrialSetup.runTrials` reserves before trials and appends after completion waits; `PriorityInversionChecks.check` filters after trials. The wrapper calls the array helper. |

The separate non-untimed diagnostic retains 811/811 on iOS 26 and 937/937 on iOS 18, with zero missing. It supplements the complete original reports. Experiments 1, 7 and 8B retain their measured units. Because experiments 7 and 8B have changed untimed units, the phone handoff conservatively includes both acceptance plans again.

## Hot flag: 17 rows, both targets

Each row's read remains inside its loop backedge. The worker consumes the true-read count, accumulates grouped returns where applicable and stores the batch value at ThreadLog +0x10; `HotFlagChecks.check` reads and bounds each value. Queue callbacks load the Bool and store it into the sync return slot. Row-specific callers supply the actual NS object or pthread/monitor function pointers to merged bodies. No loop adds clocks, allocation or logging. The current 28 named operation/callback units per target match the Task 3 inspection.

| Row | Observed per read; consumer | iOS 26 loop / caller line | iOS 18 loop / caller line |
| --- | --- | ---: | ---: |
| mutex | unfair lock, `ldrb` +0x14, unlock; true count → batch check | 67597 / 73936 | 67532 / 73871 |
| osAllocatedUnfairLock | unfair lock, storage `ldrb` +0x10, unlock; true count → batch check | 67569 / 73957 | 67504 / 73892 |
| osAllocatedUnfairLockAdaptiveSpin | adaptive flag translation, lock-with-flags/fallback, `ldrb` +0x10, unlock; true count → batch check | 67474 / 73961 | 67409 / 73896 |
| osUnfairLock | unfair lock, `ldrb` +0x18, unlock; true count → batch check | 67442 / 73965 | 67377 / 73900 |
| nsLock | NSLock caller, merged lock selector, `ldrb` +0x18, unlock selector; true count → batch check | 67410 / 73969 | 67345 / 73904 |
| nsRecursiveLock | recursive-lock caller, same selector/load body; true count → batch check | 67410 / 73977 | 67345 / 73912 |
| pthreadMutex | caller supplies mutex lock/unlock, two indirect calls surround `ldrb` +0x18; true count → batch check | 67374 / 74004 | 67309 / 73939 |
| pthreadReadWriteLock | caller supplies rdlock/unlock, two indirect calls surround `ldrb` +0x18; true count → batch check | 67374 / 74008 | 67309 / 73943 |
| serialQueue | sync invokes concrete byte-load callback; true count → batch check | 67333 / 74012 | 67268 / 73947 |
| barrierQueueSyncWrite | sync invokes concrete byte-load callback; true count → batch check | 67333 / 74025 | 67268 / 73960 |
| barrierQueueAsyncWrite | sync invokes concrete byte-load callback; true count → batch check | 67333 / 74029 | 67268 / 73964 |
| dispatchSemaphore | wait, `ldrb` +0x18, signal; true count → batch check | 67303 / 74035 | 67238 / 73970 |
| objcSync | caller supplies monitor enter/exit around `ldrb` +0x18; true count → batch check | 67374 / 74039 | 67309 / 73974 |
| atomic | one acquire byte load: `ldaprb` / `ldarb`; true count → batch check | 67285 / 74043 | 67220 / 73978 |
| atomicRelaxed | one relaxed `ldrb`; true count → batch check | 67244 / 74051 | 67179 / 73986 |
| managedAtomic | pointer getter then acquire `ldaprb` / `ldarb`; true count → batch check | 67258 / 74047 | 67193 / 73982 |
| managedAtomicRelaxed | pointer getter then relaxed `ldrb`; true count → batch check | 67217 / 74075 | 67152 / 74010 |

The iOS 18 request permits only `mutex`, `atomic`, `atomicRelaxed`, `managedAtomic` and `managedAtomicRelaxed`; the binary also contains the other iOS 26 experiment implementations. Acquire load selection differs by deployment target as shown above.

## Request registry: 10 rows

Every row alternates one dictionary removal/insertion under its protection and then calls `referenceLoop` outside protection. The loop loads the current Download's immutable work count at +0x18 inside the backedge, preserving exactly the requested work instead of hoisting a uniform pure call. Returned work reaches the loop sum, worker accumulator and ThreadLog +0x10; `RequestRegistryChecks` checks each checksum and balances adds, removes and atomic cancellations. Cancel-all walks values with relaxed `ldadd`, then clears with capacity-preserving `removeAll` before leaving protection. Current operation/mutation/cancellation units match 114 previously inspected named units.

| Row | Observed per operation; consumer | Loop / caller line |
| --- | --- | ---: |
| mutex | unfair lock/unlock around dictionary mutation; per-download work → batch check, cancellation count → block check | 114977 / 111440 |
| osAllocatedUnfairLock | allocated unfair lock/unlock around dictionary mutation; per-download work → batch check, cancellation count → block check | 114565 / 115410 |
| osAllocatedUnfairLockAdaptiveSpin | adaptive flag translation and lock-with-flags/fallback, unlock around dictionary mutation; per-download work → batch check, cancellation count → block check | 114011 / 115415 |
| osUnfairLock | heap unfair lock/unlock around dictionary mutation; per-download work → batch check, cancellation count → block check | 113578 / 115420 |
| nsLock | NSLock selectors through merged body around dictionary mutation; per-download work → batch check, cancellation count → block check | 113139 / 115425 |
| nsRecursiveLock | recursive-lock selectors through merged body around dictionary mutation; per-download work → batch check, cancellation count → block check | 113139 / 115436 |
| pthreadMutex | pthread mutex lock/unlock around dictionary mutation; per-download work → batch check, cancellation count → block check | 112706 / 115447 |
| serialQueue | synchronous queue callback around dictionary mutation; per-download work → batch check, cancellation count → block check | 112315 / 115465 |
| dispatchSemaphore | semaphore wait/signal around dictionary mutation; per-download work → batch check, cancellation count → block check | 111881 / 115496 |
| objcSync | monitor enter/exit around dictionary mutation; per-download work → batch check, cancellation count → block check | 111445 / 115515 |

`sampleEvery` is even and at least two; window offset `w % 2` samples alternating call kinds. Warm-up performs the same work without sample clocks. Dictionary slow paths and mechanism-owned dispatch runtime costs remain ordinary application costs.

## Transactional store: 13 rows

Under protection, reads load and sum every value and compare every version at 16-byte record stride. Writes update both fields for every record using vector stores plus a scalar tail; completion clocks follow all record stores and precede unlock/callback return. Queue callbacks use the full scanner/writer. Each returned sum reaches the worker's ThreadLog +0x10 slot; the final check consumes batch sums, violation counters and every group's final version/value sum against expected writes. Async workers drain with a synchronous barrier before their final batch clock. Current operations/callbacks match 160 previously inspected named units.

| Row | Observed per transaction; consumer | Loop / caller line |
| --- | --- | ---: |
| mutex | unfair lock/unlock; complete record loads/stores → batch sum, version/violation checks and completion samples | 159481 / 155726 |
| osAllocatedUnfairLock | allocated unfair lock/unlock; complete record loads/stores → batch sum, version/violation checks and completion samples | 159108 / 159860 |
| osAllocatedUnfairLockAdaptiveSpin | adaptive flag translation and lock-with-flags/fallback, unlock; complete record loads/stores → batch sum, version/violation checks and completion samples | 158564 / 159870 |
| osUnfairLock | heap unfair lock/unlock; complete record loads/stores → batch sum, version/violation checks and completion samples | 158176 / 159880 |
| nsLock | NSLock selectors through merged body; complete record loads/stores → batch sum, version/violation checks and completion samples | 157796 / 160014 |
| nsRecursiveLock | recursive-lock selectors through merged body; complete record loads/stores → batch sum, version/violation checks and completion samples | 157796 / 159890 |
| pthreadMutex | pthread mutex lock/unlock; complete record loads/stores → batch sum, version/violation checks and completion samples | 157397 / 159900 |
| pthreadReadWriteLock | pthread rdlock for reads, wrlock for writes, unlock; complete record loads/stores → batch sum, version/violation checks and completion samples | 157397 / 159915 |
| serialQueue | synchronous queue callback; complete record loads/stores → batch sum, version/violation checks and completion samples | 157099 / 159932 |
| barrierQueueSyncWrite | sync read; synchronous barrier write callback; complete record loads/stores → batch sum, version/violation checks and completion samples | 156847 / 159962 |
| barrierQueueAsyncWrite | sync read; asynchronous barrier write callback; complete record loads/stores → batch sum, version/violation checks and completion samples | 156490 / 159972 |
| dispatchSemaphore | semaphore wait/signal; complete record loads/stores → batch sum, version/violation checks and completion samples | 156116 / 159976 |
| objcSync | monitor enter/exit; complete record loads/stores → batch sum, version/violation checks and completion samples | 155736 / 160000 |

## Creation cost: 15 rows

The shared create loop calls the selected typed constructor on each iteration and appends its owned result to reserved storage. The destroy loop reaches typed `replaceSubrange` and `swift_arrayDestroy`. Every row's destructor increments the relaxed deinit counter with `ldadd` and releases its class allocation; mechanism-owned storage also releases or frees. Retained objects reach untimed `malloc_size` checks, raw samples and live-range return checks. Deinit totals consume destruction. Constructor/destructor lines below include aliases and merged bodies resolved to their implementations.

| Row | Observed allocation/destruction; consumer | Constructor / destructor line |
| --- | --- | ---: |
| unsynchronized | `swift_allocObject`, inline Int; heap proof and deinit total consume objects | 47716 / 102384 |
| mutex | `swift_allocObject`, inline lock/state; heap proof and deinit total consume objects | 47720 / 102004 |
| osAllocatedUnfairLock | class allocation plus lock/state Swift allocation; heap proof and deinit total consume objects | 47738 / 102386 |
| osUnfairLock | class allocation plus `swift_slowAlloc` lock storage; free on deinit; heap proof and deinit total consume objects | 47765 / 102048 |
| nsLock | class allocation plus `objc_allocWithZone` / init; field release; heap proof and deinit total consume objects | 47788 / 102075 |
| nsRecursiveLock | class allocation plus recursive NS class metadata into allocator; field release; heap proof and deinit total consume objects | 47794 / 102381 |
| pthreadMutex | class and lock storage allocations, pthread init/destroy and free; heap proof and deinit total consume objects | 47824 / 102095 |
| pthreadReadWriteLock | class and rwlock storage allocations, pthread init/destroy and free; heap proof and deinit total consume objects | 47851 / 102108 |
| serialQueue | class allocation and Dispatch queue initializer; queue release; heap proof and deinit total consume objects | 47883 / 102378 |
| barrierQueueSyncWrite | class allocation and concurrent Dispatch queue initializer; queue release; heap proof and deinit total consume objects | 47900 / 102379 |
| dispatchSemaphore | class allocation and `dispatch_semaphore_create`; semaphore release; heap proof and deinit total consume objects | 47993 / 102380 |
| actor | class allocation and `swift_defaultActor_initialize`; actor destroy/deallocate; heap proof and deinit total consume objects | 48013 / 102294 |
| mainActor | class allocation, inline Int, distinct metadata; heap proof and deinit total consume objects | 48033 / 102383 |
| atomic | class allocation, inline atomic Int; heap proof and deinit total consume objects | 48037 / 102326 |
| managedAtomic | class plus atomic-storage allocation; owned-storage release; heap proof and deinit total consume objects | 48058 / 102351 |

The six raw malloc-statistics sample lines remain unchanged and include warm-up, first. Aggregate malloc counters can include allocator-cached free slots, so the correctness check uses direct nonzero `malloc_size` for every retained object and separate `MALLOC_PTR_IN_USE_RANGE_TYPE` live-pointer enumeration for return/growth. The original one-percent allowance remains for post-destruction excess and positive later-minus-earlier growth; enumeration failures fail the check. Exact deinit totals include warm-up. These untimed checks do not alter allocator settings or the six exported raw samples. CreationCost tests must run in isolation because other process activity affects global allocator observations.

## Main-thread image cache: 14 rows

The actual cell callback dequeues before its first clock, calls the cache between two clocks, validates image/index identity and assigns UIImageView.image afterward. Those identity and UI consumers retain the dictionary result. Each synchronous writer retains runtime image selection → exact configured decode work → checksum store inside its backedge; the main-actor async continuations retain the same sequence before the awaited mutation. `CacheWriter.next` loads the immutable per-image work count from its runtime index. `CacheSession.check` consumes every writer checksum in exported detail. Async-barrier drain follows the writers' final barrier inside the block envelope.

| Row | Observed lookup and writer work; consumer | Reader entry line |
| --- | --- | ---: |
| mutex | unfair lock/unlock around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78496 |
| osAllocatedUnfairLock | allocated unfair lock/unlock around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78564 |
| osAllocatedUnfairLockAdaptiveSpin | adaptive flag translation and lock-with-flags/fallback, unlock around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78605 |
| osUnfairLock | heap unfair lock/unlock around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78709 |
| nsLock | NSLock selectors through merged body around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78774 |
| nsRecursiveLock | recursive-lock selectors through merged body around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 79041 |
| pthreadMutex | pthread mutex lock/unlock around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78835 |
| pthreadReadWriteLock | pthread rdlock for reads, wrlock for writes, unlock around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78854 |
| serialQueue | synchronous queue callback around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 91794 |
| barrierQueueSyncWrite | synchronous read callback; synchronous barrier store; image → identity/UI, per-write decode → exported checksum | 91794 |
| barrierQueueAsyncWrite | synchronous read callback; asynchronous barrier store; image → identity/UI, per-write decode → exported checksum | 91794 |
| dispatchSemaphore | semaphore wait/signal around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78890 |
| objcSync | monitor enter/exit around dictionary lookup and protected store; image → identity/UI, per-write decode → exported checksum | 78943 |
| mainActor | direct dictionary lookup; awaited writer store; image → identity/UI, per-write decode → exported checksum | 88644 |

Read counts cover measured frames; write counts include startup and warm-up. A later pilot must account for those windows before interpreting a 95/5 ratio. Frame intervals are scheduled display-link intervals, while frameStart gaps expose delayed callbacks. No phone display rate or performance result has been measured at this checkpoint.

## Reader audit and verification scope

Each new README has these seven headings: Question, Rows, One operation, How it is timed, What is checked, Read the code in this order, Compiler notes. Each operation excerpt matches actual Swift statements after indentation normalization. Main files: HotFlag 112 lines, RequestRegistry 89, TransactionalStore 111, CreationCost 125, MainThreadCache 113. All are about the requested 120-line screen. This audit corrected compiler-record links and clarified that cache acceptance inputs await phone verification.

No Swift, Python, plans or build settings changed in this checkpoint. Task 7 records the last complete verification: 90 Swift test functions / 225 configuration runs and 172 Python tests on both default Python and Xcode Python 3.9. The subsequent cache-drain fix passed its focused 4-function / 11-run suite. These are prior test results, not reruns for Task 8. At the pre-device checkpoint, Task 8 Step 5 remained pending after device acceptance, with CreationCost isolated. The later acceptance record distinguishes its fresh Python result from the full Simulator rerun waived by the user. Fresh verification here comprises both Release builds, original-baseline comparisons, missing-unit classification, dumps, per-row work/consumer inspection and documentation checks.

## Missing-hash appendix

These exact hashes apply to both targets. Complete original names and normalized before/after diffs remain in the private classification artifacts.

### ExperimentRegistry.makeExperiment

```text
020f2bb37d5cf3236a293d53a39c0a69048d2cc30f4bf0a9d40d31b9ee3affb8
356f405607f06ddc22b4d36f8247b23a238c84bbeeb8a17dc3a7c40192870707
4c4a54bb4f936f80bb1bfb71f9d6f11b4372997f98052c3cb6bad1739735fe0c
5020747ef44685b9c3ab616cda39e4207371f19a3f8eec9a216531a879538dd5
5fcd50d2572410d61fdcda7eb27b4274ee38cc015a6aaa45f9435ecddd10238b
7ccaaf39692e775366d3df6297468fa46d9d56347277a9a304e477b91368469b
95625947b437a457c2aa54546c86a0e1496d1ef17a45c3ff0487743c12477d66
```

### AsyncCodeRequest.blocks

```text
04761c4757c1c219ab8d4dd4a5bb2727798d071e7d467ca13d0974da0831a363
11a2954ad2359af6fd6d1b18489d031bc1664a0d05bb1b6e6ba4be32aa379684
2047b18ff4d221c44960811182c4a2e2005e79f84338cc699d8af73ff2a52927
236210571332032fd3faaaa3e0dfa5476c1489d68220f9a48c672c4a7625b7ed
262d5914d3db25f9777d7cd49bec96a3c6f70f19f05a85379a4c34a4158d48ae
3b284888de78ca9c0c5af3fad8663d8ea06354243e6d7c74f050c5eb690c4e0c
3e43f24b03efada23e048f3a3f61cc2e24cbc39b3e60e910b9c3009bb50bef4d
4019ac3983b56ee52bb2b2819876efa23e62b1a211c901b7d5403d1e5725077b
41ad865bfb58390b6b5435a8db258fd772ec5cbd9bf430c24941bf89b454fde4
4528eae345fdf08c06329f5d2513ff2654d30bd3a5d6637a6ce8ac2c063c21ff
5a2a544077c5fe209120b7a2382087257f9994335bb07b6ba86a30c1897050e2
5a70de132fb9e39c6243387c9df7bdc7abe48f97d6cf7649a49cb92ee2d53126
5ea7197dd82889d4e18f93ff4654ddf8d2acb7847219a6353d8c06347664fb37
5fdf8b26bd0b95b85c6779147fea72587626389795bca02cfc0125c41a862807
632a1b4c765cc336fab12400271fce9b75bca4cfc773e20a9677a189de0ce3c2
634f911342e947bf5f680d6bed99a653c774add35d14e29dca283e6445763012
64a42a4f45618ac90d1860387f49f4e30f162e80cf8474d1e5df95dc7ee7985e
7f65748c24197691f12203d593ff3d69e2f06959e4768f95e446106621477b8c
7ff212a10f6e4cdca45d0c5dd8b64cb8f6329d4e528cb8e7feb061e07793f110
8616e3a5930cf4cf75d56c47478df885e8fc5a1b1e480a567181c0a582b15339
8bb96c812e8d3f54352de9bc505218085e085c007c49b1d8b60aacb6bbcbf26d
a5cfdd1b5dc9405db6be293af92c5dd09b3a65a98beb1af0440712f64b4dd5b2
ac0a78a52f50dfddd647d0b0d8312fa613cbfabc5fcdf2bbf392528599b5028b
be69db9e238dad97bec88341c31718efe10770fe163aeaea23f70a9a9444f369
c387f0d9818aaf2db1e23686f9c35a3794800c3355fc108885a2721724b76f2e
cac91dd7738a2ceaa58603b23f01a372dc3ca0fb10dd1a0606cc44542cdc69dd
d86db8731f41dd566e589ce413c0f87bf4e8609563d21f322566f07165745368
d958bdc5a3756935991790ccbd8adb4e8abd3404205bd0903b3e4ae03dd7a708
dc2ed3bc7657e3ee6ccdfe0b7e8bd35e1f1873d9be51db451e2456e4516f6fd3
```

### CallerPaths.appendCallTimes

```text
3cb9a6841cae7f5d549ff19dd1e4edbd9931d90074a4063f07c61ba084259c04
89d7c00935b53397f52ed5c8dc3aea9fe7a23f412b566518e30d1f07c807e4e5
c20326975dcfddca6a72b940022928b9b1646c202a93fe7435e5a76adc0ee2d9
```

### TrialLine array growth

```text
2ddac8738266d91bb1afce1a1e86b9c97abd1fa2b24e91ce6301bf97d65ac279
62f48a7140b6a3ba11293c82093cfb4774902785e7a6425b5f85a6a504a9fe27
9f830f4fe83b27117adef851b0a3eca2defa6078d8e29ca627bfda47336f2c95
```
