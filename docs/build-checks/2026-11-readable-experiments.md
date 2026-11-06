# Readable experiments: Release code checks (2026-11-06)

Clean source `a1647c675def` contains the readable experiment folders and the three
[operation-preservation fixes](2026-11-operation-preservation.md). Fresh unsigned
arm64 Release builds retain 653 baseline units for iOS 26 and 738 for iOS 18.
Both comparisons report 141 missing and 132 added hashes. The inventories below
explain those differences; the refactor does **not** produce identical measured
machine code. In particular, concrete lock layout and merging change 18 measured
loop/worker regions. Three other hashes change only source-diagnostic constants.
The remaining 120 cover removed interfaces and untimed setup, validation,
checks or coordination.

## Build and comparison commands

Toolchain: Xcode 27.1 (27A9275), Swift `swiftlang-6.4.0.34.1`, XcodeGen 2.46.0,
iPhoneOS 27.1 SDK. Release keeps `-O`, whole-module compilation and default
exclusivity checks. No inline, isolation or compiler settings changed for these
checks; no `SWIFT_*` command-line overrides apply to either probe library.

Run from the repository root. The two candidate derived-data directories were
new for this check. These commands use the original Task 1 baseline artifacts.

```sh
xcodegen generate --spec project.yml
xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench \
  -configuration Release -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  -derivedDataPath build/private/readable-experiments/task6-ios26 \
  -quiet > build/private/readable-experiments/task6-ios26-build.log 2>&1
xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench \
  -configuration Release -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=18.0 \
  -derivedDataPath build/private/readable-experiments/task6-ios18 \
  -quiet > build/private/readable-experiments/task6-ios18-build.log 2>&1
python3 scripts/codegen_compare.py \
  build/private/readable-experiments/baseline-ios26/Build/Products/Release-iphoneos/SyncBench.app/SyncBench \
  build/private/readable-experiments/task6-ios26/Build/Products/Release-iphoneos/SyncBench.app/SyncBench \
  --report build/private/readable-experiments/task6-vs-baseline-ios26.json
python3 scripts/codegen_compare.py \
  build/private/readable-experiments/baseline-ios18/Build/Products/Release-iphoneos/SyncBench.app/SyncBench \
  build/private/readable-experiments/task6-ios18/Build/Products/Release-iphoneos/SyncBench.app/SyncBench \
  --report build/private/readable-experiments/task6-vs-baseline-ios18.json
```

Both builds exit 0 with empty logs. A second comparison of each fresh unsigned
executable to the clean signed artifact used on both phones retains all 785
(iOS 26) / 870 (iOS 18) selected units, with zero missing or added hashes and
exit 0. This ties device acceptance to these candidate instruction regions.
The comparison with the original baseline exits 1 for each target,
as required when any baseline hash is missing. Its full reports equal the
reviewed Task 5 reports, including aliases and added hashes. The original
Task 1 baseline binaries remain unchanged:

| Baseline | Executable SHA-256 | Kept | Missing | Added |
| --- | --- | ---: | ---: | ---: |
| iOS 26 | `2cd3983d5387e36efe627ab371398de085f391c270c80d38f26f373c4f1e752f` | 653 | 141 | 132 |
| iOS 18 | `b35f95cd94b8a4ade6d878c590862041864ae0760ec2ce4ea1f706ac5c054b36` | 738 | 141 | 132 |

Counts refer to distinct normalized instruction regions, not source functions:
several symbols can alias one hash, and a function can contain several regions.
The comparator normalizes symbol names and relocated addresses while retaining
ordinary immediates, field offsets and source-location constants. Its broad
selection also captures validation, metadata and bookkeeping. A missing hash
therefore needs instruction/boundary inspection before a timing conclusion.

## Reasons and measurement boundaries

Task 2 contributes five synchronous CallerPaths setup hashes. Moving
`MainThreadCPURecorder` removes same-file knowledge of its metadata accessor's
unused request argument and initializer's returned-self identity. The caller
adds two register moves and branch relocation, with no extra calls. Construction
precedes `runInTasks`, block timing, the task barrier and batch timestamps. A
colocated `@inline(__always)` factory probe still left five missing hashes
(789 kept / 5 missing / 5 added); the factory was reverted.

Task 3 adds 86 missing hashes: 12 concrete-lock loops, six corresponding lock
workers and 68 untimed generic-layer removals, request/construction changes,
checks and async coordination. Direct concrete `Int` fields replace generic
field addressing: `ldur/stur` become `ldr/str`, with changed register allocation,
prologues and local branches. The loop families are NSRecursiveLock (also
NSLock), ObjcSync (also shared pthread bodies), UnfairLock and DispatchSemaphore,
for read/write/increment. ObjcSync, PthreadMutex and PthreadReadWriteLock workers
use the changed merged read-loop calling conventions instead of an old
discriminator argument. These are permitted measured-code differences from
concrete layout, not a claim of bit identity. Inspection found no added access
check, allocation, clock read or actor hop. Mutex and allocated-lock loops keep
their baseline hashes.

Task 4 adds 37 cumulative missing hashes for untimed request validation, removed
caller dispatch, final checks, batching dispatch, main dispatch and main-actor
counter construction. Its Task-3-relative inventory has 38 hashes: one removed
NSLock `runLock` dispatch hash (`60e9acab3678f3c833fdc2c351bb89a229e052250d901488e2aca15bfb2071a2`)
first appeared after the original baseline, so it is absent from the final
141-entry original-baseline inventory.

Task 5 adds 13 missing hashes: six former `TrialRunner` value-witness/layout
regions, three trial-loop/coordination regions, one concrete-lock factory and
three source-diagnostic differences. The factory and bookkeeping sit outside
mechanism work. Of 40 baseline `hold`/`touch` regions, 39 retain exact hashes;
`ContendedMutex.touch`'s witness changes only its executor-report source line.
The two main-dispatch closures also retain their instruction/call sequence,
clock positions and work, with these changed constants:

| Region | Old → new operands | Consumer |
| --- | --- | --- |
| `ContendedMutex.touch` witness | line 65 → 23 (`w3`: `0x41` → `0x17`) | `_swift_task_reportUnexpectedExecutor` |
| Outer main dispatch closure | filename byte length 27 → 33; line 129 → 176; assumeIsolated line 130 → 177 | executor diagnostic / `MainActor.assumeIsolated` |
| Inner main actor closure | filename byte length 27 → 33; line 130 → 177 | executor diagnostic |

The same three old/new pairs occur in both targets. The controller accepted
these source moves with their diagnostic constants; no artificial
`#sourceLocation` or padding hides them.

All queue, atomic, floor, actor and main-actor measured-loop hashes remain, as do
non-lock timed workers and actor continuations. Supplemental symbol selection
included `timeBatchesOnThreads`, `timeBatchesInTasks` and
`timeBatchesOnIsolation`, without changing normalization. Final binaries emit no
new helper workers under those names, and the supplemental missing inventories
match the default inventories. This supplements source inspection because a
new callback name can fall outside the default selection.

## Rejected preservation probes and folder deviations

The plan's measured-code requirement takes priority over its approximate size
and source-file preferences. The retained deviations are explicit:

- BaseComparison keeps three `QueueIntegers/` source files. Merging them changed
  Dispatch inlining and source-diagnostic operands: 156 hashes were missing in
  the merged-file/order probe; restoring separate files restored all queue loop
  hashes (138 total missing before timer restoration).
- BaseComparison timing keeps direct `BatchTimer` calls and the original
  block/operation capture shape. Callback helpers emitted extra partial-apply
  workers and timed indirect `blr` calls. Direct free-function restoration left
  136 missing; restoring the capture shape reduced the final Task 3 inventory
  to 91. Shared validation/layout/check helpers remain useful outside timing.
- AsyncCode keeps explicit timer calls. The helper/isolation-preserving probe
  built but changed timed continuations (130 Task-3-relative missing). Restoring
  explicit calls left 38 untimed missing hashes, then 37 relative to the original
  baseline. No new helper or measured attribute remains.
- Main files contain 125 BaseComparison lines, 108 AsyncCode lines and 227
  PriorityInversion lines. The first two approximate the 120-line target.
  PriorityInversion exceeds a single screen to expose the required five trial
  steps, protocol and fourteen-row switch. Coordination lives in TrialSupport;
  compressing the visible process would defeat the reader's entry point.
  Pointer-owning lock classes also exceed 35 lines where explicit lifetime and
  assert/defer statements preserve ordinary operation bodies.
- XcodeGen excludes `**/*.md` in Experiments: three identically named README
  resources otherwise collide during regeneration. READMEs are documentation.

Each experiment README answers the seven required headings. Its Swift snippets
match the source, allowing indentation, including the two async paths and both
unfair-lock trial sides. Reader order identifies operations before plumbing.
The [device acceptance record](../phase-2-acceptance.md#readable-experiments-and-optimizer-fixes-2026-11-06)
records the four plans on both phones, signed-build provenance and final tests.

## Later dead-helper cleanup

The later `Remove unused block timing wrappers` commit removes only the unused
`BlockContext.timeBatchesOnThreads` / `timeBatchesInTasks` APIs, their two exclusive
tests and their test fixture. The used layout/check helpers remain. Real timer
bodies, experiment timing call sites and compiler settings are unchanged. Device
acceptance still identifies clean source `a1647c675def`; no device acceptance was
rerun for this cleanup.

Fresh unsigned builds use new `final-ios26` and `final-ios18` derived-data
directories under `build/private/readable-experiments/`, with the same commands
and settings above, substituting `final` for `task6` in output paths. Default
comparisons of the accepted `task6` executables against these new executables
exit 0: 785 kept for iOS 26 and 870 for iOS 18, zero missing and zero added.
Supplementing the default filters with `timeBatchesOnThreads`,
`timeBatchesInTasks`, `timeBatchesOnIsolation`, `operationsPerWorker` and
`checkValues` also finds zero missing/added: 791 / 876 kept. Reports are named
`final-vs-task6-ios{26,18}-{default,supplemental}.json`; the supplemental command
is saved as `final-compare-supplemental.py` in the same private directory.
Normalization is unchanged. This is instruction-region inventory evidence,
with the comparator's limits above, rather than whole-program equivalence.

| Final executable | SHA-256 |
| --- | --- |
| iOS 26 | `55dfeebfba1a1312c99c49e0230fc400c6f5ae093a7538467759e8615587c23c` |
| iOS 18 | `ab4cef5e7c11eee0b5c81c0e8b52f9a052168e68679c870ffdebc3054b6ee69d` |

The Task 1 baseline and Task 6 executable hashes were checked before and after
and are unchanged. Their directories were not build destinations. The complete
original-baseline difference inventory below remains unchanged: 653 / 738 kept,
141 missing and 132 added per target, with the same aliases and explanations.

## Complete difference inventory

The following grouped inventories account for all 141 missing hashes and all
132 added hashes per target: 142 missing and 134 added hashes across both
targets. Hashes are full normalized SHA-256 values; symbol
names omit only the module prefixes `SyncBench.` and `Swift.` and private
32-digit discriminator suffixes for readability. All aliases remain listed.
One missing region has target-specific hashes, with the same alias:
`TrialRunner.runTrials` is `28b681ec…` on iOS 26 and `f22ed5a0…` on iOS 18.
Its saved normalized baseline bodies differ only in seven acquire-byte loads,
`ldaprb` versus `ldarb`, in trial coordination. These are existing
deployment-target lowering differences in the removed controller region.
Missing and added target differences are marked below; the rest match.
The category heading supplies each entry's reason.
Two added regions have target-specific hashes: `BaseComparison.run` uses `ldapr`
(iOS 26) versus `ldar` (iOS 18) for a final acquire load; `runOneTrial` uses five
`ldaprb` versus `ldarb` acquire-byte loads in controller coordination. Normalized
diffs contain only these target-dependent acquire instructions. These are the
existing deployment-target lowering differences, separate from refactor changes.

### Missing: Concrete lock loop layout or merging

| Hash | Symbol aliases |
| --- | --- |
| `002d0aa7bb43d6b9619c5f1e2e34ded3843b7728d6f6e1c155462de177c6910e` | `merged generic specialization <ProtectedInteger<NSRecursiveLockProtection<Int>>> of static BaseComparisonLoops.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `185248273bf79c97568973360f4738a05a1665185b2d93cc585a49aa1d0d5c2a` | `merged generic specialization <ProtectedInteger<NSRecursiveLockProtection<Int>>> of static BaseComparisonLoops.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |
| `350f22dab48f673bc49b010e7881b0065294cc317f4dad0800857a5a462362cb` | `generic specialization <ProtectedInteger<SemaphoreProtection<Int>>> of static BaseComparisonLoops.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `490f70c28b1c08f92433081696c6e2fd639d72cc8dfacfd07a995a9f019b2100` | `merged generic specialization <ProtectedInteger<ObjcSyncProtection<Int>>> of static BaseComparisonLoops.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `4f6c50df79f406a0a9b1c3d8968f5d887fb9a44da38d313df89e5789e95d8284` | `merged generic specialization <ProtectedInteger<NSRecursiveLockProtection<Int>>> of static BaseComparisonLoops.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `6033f598503774c49231d2a9a5ddd3d34cb8ae5b7fb81a7b4aba954bf4d7a574` | `merged generic specialization <ProtectedInteger<ObjcSyncProtection<Int>>> of static BaseComparisonLoops.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `622f202225fe8b2b23f820eee1621fb692face098b443772cbfad1fa29dd7fa4` | `generic specialization <ProtectedInteger<SemaphoreProtection<Int>>> of static BaseComparisonLoops.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |
| `86e399a53f22d1a7b500200ef8cd92a2f721d8fceafb7179a1b87365a2068f8a` | `merged generic specialization <ProtectedInteger<ObjcSyncProtection<Int>>> of static BaseComparisonLoops.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |
| `cd166f4f2fa8b6ae9425e518e1794e3017c0cec06a698dadacd1e25e4bb50b06` | `generic specialization <ProtectedInteger<UnfairLockProtection<Int>>> of static BaseComparisonLoops.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `eb36ca0f13692d028087966c7507128f5d1b644fd51b9d27445ca2636a5b753b` | `generic specialization <ProtectedInteger<UnfairLockProtection<Int>>> of static BaseComparisonLoops.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `fd1271b268956aef69d5714ba05384e5fad7a52f9f41b46742432592492da99e` | `generic specialization <ProtectedInteger<SemaphoreProtection<Int>>> of static BaseComparisonLoops.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `ffdd7cf383dc94c02a1132ff71b314cc17cad70251e48b53c1ed65a51e8aee77` | `generic specialization <ProtectedInteger<UnfairLockProtection<Int>>> of static BaseComparisonLoops.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |

### Missing: Concrete lock worker call merging

| Hash | Symbol aliases |
| --- | --- |
| `2fa095f0ac1624b798393ce6d2fb8ceb26bfb80b7d9e03a37580388b9acd20a1` | `generic specialization <ProtectedInteger<ObjcSyncProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]`<br>`generic specialization <ProtectedInteger<PthreadMutexProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]` |
| `37e53a2aaf0c769c6bbfcf005a50382b8ebdb926c18a48fc88bb491907170257` | `generic specialization <ProtectedInteger<PthreadReadWriteLockProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]` |
| `4ef9e249ebfae3cbc2c9996ad0bf135e979d864c5bcd837b9bdd611a14415d01` | `generic specialization <ProtectedInteger<PthreadMutexProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]` |
| `6e2e1d94e33c593e3b8b93d04eff8bf4b205c00b61aea0336655e40c07d7aea3` | `generic specialization <ProtectedInteger<PthreadMutexProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]` |
| `8bb286c9e923e1aa538702f53ffdd3eee85040b6d705cff2b93b1b800982e9b1` | `generic specialization <ProtectedInteger<ObjcSyncProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]`<br>`generic specialization <ProtectedInteger<PthreadMutexProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]` |
| `ca91568ae4efb1c2a29dbdd7a7bcaedd38be3af060ac22c90524a81b1d696070` | `generic specialization <ProtectedInteger<PthreadReadWriteLockProtection<Int>>> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonVisitor).visitSynchronous<A where A: SharedInteger>(A) -> [CheckResult]` |

### Missing: Moved batching dispatch/check assembly

| Hash | Symbol aliases |
| --- | --- |
| `503b661b9d20cbf83542637b94aa599b145b73ac058c7a159fe84b32ecf3b4e6` | `function signature specialization <Arg[1] = Dead> of static Batching.run(BlockContext) -> [CheckResult]` |
| `5059ac4f3a4185c040ffa8d7cec569f68196c30f87628b9d424eb38250d82c45` | `function signature specialization <Arg[1] = Dead> of static Batching.run(BlockContext) -> [CheckResult]` |

### Missing: Moved final check assembly

| Hash | Symbol aliases |
| --- | --- |
| `2baaec37325a6cf31ec9f1abb2e5834ce489476b64debbb8727c96d6cfce836d` | `static CallerPaths.run(_: BlockContext, asyncCode: AsyncCodeTunables?) -> [CheckResult]` |
| `b412eebce7d3a95f958d00b8f5273bf0c0d8273d2ddd6f554b27aae7fe0f5842` | `static CallerPaths.run(_: BlockContext, asyncCode: AsyncCodeTunables?) -> [CheckResult]` |
| `c6be8df8527c548621d692beeed0d85d90ab21bfba6d9b959cf9050b4e76dae3` | `static CallerPaths.run(_: BlockContext, asyncCode: AsyncCodeTunables?) -> [CheckResult]` |
| `cd880242e708d4d37e4c0c3c8c5ac971845524fbd206860ca86305a9bc24ad6f` | `static CallerPaths.run(_: BlockContext, asyncCode: AsyncCodeTunables?) -> [CheckResult]` |

### Missing: Moved request validation

| Hash | Symbol aliases |
| --- | --- |
| `0508a2050b98b6f70e837525ea7c9c2d02bc6a9c3b48b093e9af370e7c0da1b3` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `0dd8e417867fdaf1b3d48fb9dfa91af610ff33b84425dcf3c74ca4799d80fbe0` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `17e1773338209a44ea71e6b820627bc543d129e843e73664c9994c265c862f72` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `25d26256afb1c8919e8bf8cd1b74ae9bcf97fa02058e993431aab5e451f46075` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `2e5433b7bd7dfb18f9d9273177f8e95b2bf1055f2e7dee8ad39de43d2afa0861` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `36e45541aba8913ab2c1c2bf29c5e6e66b11814cc49374a0e53a019d75ca36a2` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `45db1f7b5c496a732d572fd9b3b967dabc2e39b48b830eaf33aad7604b30a510` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `4fcae5d84c8159ff223ef01b9cb27f492a8385c800a925f498e6d5e8b00e1991` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `586428c39e85990bdb0315ce24d287320d3d2d1c0baa780da3a541b0870fb391` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `5a4ed678481192233a1bc34b0de9691e2e13098d5907d8ed17da882e041424fc` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `5e5ef0f094b5d0438755ece9956ffd0e6a379ead3eecac7430547956e04c309a` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `6c8e228f1541b748701e9ec6eb1eb290740528ecbc4bb7777daf7f4d69a55b07` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `6d4ffe652a9e5f31232f450ee61bbbc505ed896d33e877f4ef5f0fca1f41aceb` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `881aaf5dc1f50e09784ba7f555370d99f158cc04581c1b04165241db697cb6fc` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `92d0ec884ea1602c7fec8f6851a52fc0cb7a09e9c1972e15815bdc08b62e8980` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `a9211d95d0d17352a6b8468497f406b1c345d9b6b53d3d11567c796435b44fc8` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `ba6f1ccfdbce8031993094df33d55a628dc5d8d7607da7a7d46afaad28234f84` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `d3d300ee622aa8a4cff3a3b72718f4a7dee000a2be98aa97528b5ea0cea94a38` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `dcc7bd6c66ceec6916ea8d82fe461f818b9ab1589659d3c332cbb3d2d4385310` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `dda5dd7b4dc5c57d39eb0983bbb2dc4af986af708d251716cd8d1967a99bb180` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `e512b95843c38c4cbc54afdbf4b3b5198ae52fbf25b383e51743bbf2de4dc9cf` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `eafbab544063a1e20c6756975d01ac12a7c163155edff9f331d9d32fbc67d8c2` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |
| `ecc0c8f73a739ebf9be1570897d51e09deab7a3006a8700d987ae8e3e3dc7cf8` | `function signature specialization <Arg[1] = Dead> of AsyncCode.init(request: RunRequest) throws(RequestError) -> AsyncCode` |

### Missing: Moved untimed check assembly

| Hash | Symbol aliases |
| --- | --- |
| `0ccb37f620111ff30a0297ad211e1b8ad8a2427d1b62153fbf9bb2469e8f2ada` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `13029be76a53c828ab30985b9dc7eb4d812671bca888c3336591329af2cf6f77` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `18cd6706e0fc80e1619a9d76eea186714eada37c750a99d347bf2fc3f0bde538` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `24043e24ac836a473d1521857bdf678fa2deda2d44d96ae2b0d6a1d228f0981e` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `575305784edb264e5b671ac9ce598de084eb26ef9564d8604266690ae8518a9a` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `5c2872c2c65c6109ed586be35c2d73ce4eca692bd4b48eac09884b85c6b63a3b` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `5d356e41396827470af5b64bd52156551e8cf068da51b864bcb314e84d665714` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `aa1c32d9ccbfa92a3287bb4bf98d1e086564e646763da11974ae694bbbfcd78a` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `b29a8557f638437df26c9caf45e327e380aca02a7c50cfb84d49f531fb082416` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `c3d08fc96c90635bf30f6e67189edf388749bcde755b44cbf0ad324f06d7682a` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |
| `ef4658ddba9ca7e0505fa72e0451ca156395498d54535fedeee5c5e3c7a2ca64` | `(BaseComparisonVisitor).checks(finalValue: Int, logs: [ThreadLog]) -> [CheckResult]` |

### Missing: Moved untimed validation and mechanism creation

| Hash | Symbol aliases |
| --- | --- |
| `0a3524f1f1cf288db035dbdc370bce2ba8d296f347d53a5497022c1e3ceb1008` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `0b02f9d346f766167b7d1e305192fccf8fdce8f2e0a440835c16f3a671d85b51` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `0ee5b6f731b381de1a23e7cdb13b86f53f8c28e96ee980a025309cdf0f53c1c0` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `18626f00f28ea11db8cb207c3dba012b0fc9afccabea3660c0839a74009d1837` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `19952cf88748697eff1a7dd852d453a8a6b6c85d9225d2c62872934b34021c34` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `289537707d2394c50eeccdf44ac6e73a21aa991e5e2af592b7d2aff020a9e026` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `30531b1a257a92da74ce09e266a9a685b855f760ecff4443c256fa7616de6a67` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `37dc34bc1e96232f402a1e5b8fc71658fe9986cd84b3160e37037539b7ea4969` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `3c3c782ef3863668fe727d1485cc3991b9fd928b688e1f6b0f68e71a94b6755b` | `function signature specialization <Arg[1] = Dead> of BaseComparison.run(BlockContext) -> [CheckResult]` |
| `4722d86e1fa43e8776bfbd4fe6add55fe936f2b03123bdcf65dd479383e0ffc0` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `5930f2b114526657f1eeff315f264e98cb9c63e9c8716b5a1f6f421ee727f0e0` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `6a58de17168433465f644e5e66f212dcb8672b5a9356e4fd7b9b2201f3dbea34` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `9f3b32e9fb0851213c0c0de557daf03245d91a1d61a10bc81e6c732790b41967` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `ad44773cdb82b9da7fc4f73830c25d8799f967cd419dc17cc4588b7e38f133c6` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |
| `f6beb34306bf159cc45fdb886975d89181a3fff7d89d41317557ccbbcf87fd4b` | `function signature specialization <Arg[1] = Dead> of BaseComparison.init(request: RunRequest) throws(RequestError) -> BaseComparison` |

### Missing: Removed caller dispatch

| Hash | Symbol aliases |
| --- | --- |
| `1cc34b9ed08e1d6a20547b4cb5cf93cf4c46815fc376a465775c547e5464bf0b` | `static CallerPaths.(runActor)(_: BlockContext, asyncCode: AsyncCodeTunables?) -> Int` |
| `2ccd87ccb071f25b3284c12eae0377369cc8aac37868e77d98ca685b1c99ecb9` | `static CallerPaths.(runActor)(_: BlockContext, asyncCode: AsyncCodeTunables?) -> Int` |
| `2e3c8875033aaa8d0416807bf446804cdcea2ba47219cf34482471e252ed8648` | `static CallerPaths.(runActor)(_: BlockContext, asyncCode: AsyncCodeTunables?) -> Int` |
| `497b22aecee39cb61d00c54cfae30f7830d31dbb41c8a618e86dd0304a4b9f6e` | `generic specialization <MutexCounter> of static CallerPaths.(runLock)<A where A: LockCounter>(_: BlockContext, counter: A, asyncCode: AsyncCodeTunables?) -> Int` |
| `c9db6ce74f3a20d5b1e21fd06f939c3e8de0bbe29bff135768a16635aeef1ab1` | `generic specialization <AllocatedUnfairLockCounter> of static CallerPaths.(runLock)<A where A: LockCounter>(_: BlockContext, counter: A, asyncCode: AsyncCodeTunables?) -> Int` |

### Missing: Removed generic state and visitor layer

| Hash | Symbol aliases |
| --- | --- |
| `066f9da95f6a4be3f62c5e11d895f2f595ad1c925ef32abf077207e31dde8db3` | `PthreadReadWriteLockProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `0a43f97b030020a09b3918714f1dfc157cbc8017f7b2ed2983d18a5538da2fc3` | `NSLockProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1`<br>`NSRecursiveLockProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `0aeb99e1bb51ccf075b356caf9cd81c094120dd369f508ed92c342f5f8d74319` | `BarrierQueueAsyncWriteProtection.write<A where A1: Sendable>(_: A1, using: @Sendable (inout A, A1) -> ()) -> ()` |
| `1b3b9007818d35ca38d09665dd80245be945056af2bc8147f828eade44b52728` | `PthreadReadWriteLockProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1` |
| `1d79e39ba7a6e404c82663746b46ae0b93b0c499f596751250923000fe1cb5b9` | `SemaphoreProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `218149412cb0868d35838c0251cce699e3f8c6150b38a1f7594c5421c0b1c238` | `UnfairLockProtection.__deallocating_deinit` |
| `22a6fead4666d1d1fe9572491e3ee8e7bfa9fe67890e7b32a84e9254d433ec08` | `partial apply forwarder for closure #1 @Sendable (inout A.State) -> () in (extension in SyncBench):StateProtection.write<A where A1: Sendable>(_: A1, using: @Sendable (inout A.State, A1) -> ()) -> ()` |
| `24f00d2e72296e2ea47a0528cb40116cda9c200d25386da736074fb98beffa03` | `PthreadMutexProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `2b21c3acfcc3a50ea4816861dd32c01a97fe7275690072426645f3c42337dc4b` | `MutexProtection.deinit` |
| `3c33c6c98842c8e8c7b6c02cc43f5ed08e84fbd3e1ef27781702867e28dff564` | `BarrierQueueAsyncWriteProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1`<br>`BarrierQueueSyncWriteProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1`<br>`SerialQueueProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `4dd0d2a17f8ee57694c176d45f329e2fdb16b0420ebec4770d4305f583d93662` | `(extension in SyncBench):StateProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A.State) -> A1) -> A1` |
| `5a2632241307880b246aa1f08b7c86c6716fd2469dd69df7f4c5df65133fe646` | `AdaptiveSpinUnfairLockProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `685de0929ab66882015d509df1cd08b8d2ace9ec3c11026cf7a24c3f187e1917` | `generic specialization <(BaseComparisonVisitor)> of static SharedIntegers.visit<A where A: SharedIntegerVisitor>(_: MechanismID, initialValue: Int, with: A) -> A.Output` |
| `6d3fbecc73ca1610173d349a0ad647ed3fddaa558f3223bff723d2b3128077bf` | `type metadata completion function for MutexProtection` |
| `78905fdcf502c4d97833253b3ed86b4a05e580c4dcadc43772fddcc9392912f7` | `partial apply forwarder for closure #1 () -> A1 in BarrierQueueAsyncWriteProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1`<br>`partial apply forwarder for closure #1 () -> A1 in BarrierQueueSyncWriteProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1`<br>`partial apply forwarder for closure #1 () -> A1 in SerialQueueProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `84663b13f08822aa560586e20342ba659c0a18e9a6f7d1c6038da3ac86a78820` | `AllocatedUnfairLockProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `8f8a21532102efbe274487e422cddfd1d0a3d88208e04f4990d189d1540c257d` | `BarrierQueueAsyncWriteProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1`<br>`BarrierQueueSyncWriteProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `941126d7fd7dbaeaa633a4edf0ab9c85569f9245bf0b383b907c5ff615807050` | `partial apply forwarder for closure #1 @Sendable (inout A.State) -> A1 in (extension in SyncBench):StateProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A.State) -> A1) -> A1` |
| `9cc4d7dacccfacd77a8d01693689b89cdcea48e4f42909aaa4aa33919e7e1d7f` | `type metadata accessor for MutexProtection` |
| `a2023c5300c5d82169a2175e344352214768e88f5b0e9d24020495cb1efc2c49` | `BarrierQueueAsyncWriteProtection.__deallocating_deinit`<br>`BarrierQueueSyncWriteProtection.__deallocating_deinit`<br>`NSLockProtection.__deallocating_deinit`<br>`NSRecursiveLockProtection.__deallocating_deinit`<br>`ObjcSyncProtection.__deallocating_deinit`<br>`SemaphoreProtection.__deallocating_deinit`<br>`SerialQueueProtection.__deallocating_deinit` |
| `a6b8843b71a0c00934382f6bde57a4f9c89e16ebb31c170af195784f393cbf76` | `partial apply forwarder for closure #1 @Sendable () -> () in BarrierQueueAsyncWriteProtection.write<A where A1: Sendable>(_: A1, using: @Sendable (inout A, A1) -> ()) -> ()` |
| `ad03905e7b7b7e2886a58e7b835ef3db6317e4bd38b66c23e10c27ddab6acb8b` | `type metadata completion function for AdaptiveSpinUnfairLockProtection`<br>`type metadata completion function for AllocatedUnfairLockProtection` |
| `b2af4e0765e0c0021962c053347895f7a80d69fb46fd24f370c47edd07f434a1` | `closure #1 () -> A1 in BarrierQueueAsyncWriteProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1`<br>`closure #1 () -> A1 in BarrierQueueSyncWriteProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1` |
| `bb9c3f64a11d2edb6bf1e7df7b453b9b9900ae62c9f80e70b259ae93a07c8b9b` | `ObjcSyncProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `c2f21b4c0f98c6c7cf45a3eddb193480256433f715d62b8ba6c6b13bf337c8c4` | `type metadata completion function for BarrierQueueAsyncWriteProtection`<br>`type metadata completion function for BarrierQueueSyncWriteProtection`<br>`type metadata completion function for NSLockProtection`<br>`type metadata completion function for NSRecursiveLockProtection`<br>`type metadata completion function for ObjcSyncProtection`<br>`type metadata completion function for PthreadMutexProtection`<br>`type metadata completion function for PthreadReadWriteLockProtection`<br>`type metadata completion function for SemaphoreProtection`<br>`type metadata completion function for SerialQueueProtection`<br>`type metadata completion function for UnfairLockProtection` |
| `c37e3099ebf347d122f0ee0d61063d37dd78a1a3893eea805475c5457ce9b8c5` | `PthreadMutexProtection.deinit` |
| `ca5c787c77be0672dd39020a6157dd65d5289c9daf2c0f01783aeb40bf28e2f9` | `MutexProtection.__deallocating_deinit`<br>`PthreadMutexProtection.__deallocating_deinit`<br>`PthreadReadWriteLockProtection.__deallocating_deinit` |
| `cb3d3f9e31caebbaf1430b6500c6b42db6c3e2c0b32ebb69b6adddbb3f87876f` | `UnfairLockProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `d0ae16adaee80b3178ac05c1da65b1d60920e9b3e6688658e4b9c0a9952b6782` | `closure #1 @MainActor () -> MainActorInteger in closure #1 @MainActor () -> MainActorInteger in static SharedIntegers.visit<A where A: SharedIntegerVisitor>(_: MechanismID, initialValue: Int, with: A) -> A.Output` |
| `d39b67b4b246cdf30f25bcc37d212e7edc7bf0e86eaca2456577fba86d295225` | `MutexProtection.withExclusiveAccess<A where A1: Sendable>(@Sendable (inout A) -> A1) -> A1` |
| `e04ab45084ec14c9bfb488ceea24c3527ae6a3f6764cbd9fa9cc4fb784b6c8ab` | `PthreadReadWriteLockProtection.deinit` |
| `ecb46cb6b5fcaa3260139714d8e8174e7fdabef514a24ed9588866eae04398b3` | `BarrierQueueAsyncWriteProtection.waitForPendingWrites() -> ()` |
| `edcace4d7894e842170b7ba45fd3617d82ed046d9dd2912f4bb6f4d111cf8cba` | `type metadata instantiation function for AdaptiveSpinUnfairLockProtection`<br>`type metadata instantiation function for AllocatedUnfairLockProtection`<br>`type metadata instantiation function for BarrierQueueAsyncWriteProtection`<br>`type metadata instantiation function for BarrierQueueSyncWriteProtection`<br>`type metadata instantiation function for MutexProtection`<br>`type metadata instantiation function for NSLockProtection`<br>`type metadata instantiation function for NSRecursiveLockProtection`<br>`type metadata instantiation function for ObjcSyncProtection`<br>`type metadata instantiation function for PthreadMutexProtection`<br>`type metadata instantiation function for PthreadReadWriteLockProtection`<br>`type metadata instantiation function for SemaphoreProtection`<br>`type metadata instantiation function for SerialQueueProtection`<br>`type metadata instantiation function for UnfairLockProtection` |
| `ef8ff7b1059bcda5a9741241804b1dff685db10e162ba3ec023c91784cc9b79d` | `(extension in SyncBench):StateProtection.write<A where A1: Sendable>(_: A1, using: @Sendable (inout A.State, A1) -> ()) -> ()` |
| `f07d66fb42099cebc8b33e5fa7951dd53a602fbce12ab47e43f440c153408498` | `closure #1 @MainActor () -> MainActorInteger in static SharedIntegers.visit<A where A: SharedIntegerVisitor>(_: MechanismID, initialValue: Int, with: A) -> A.Output` |
| `f1a0e42dbf49695910f19438074086e40cc957a5a8ba367b3731db096dff4a99` | `partial apply forwarder for closure #1 () -> A1 in BarrierQueueAsyncWriteProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1`<br>`partial apply forwarder for closure #1 () -> A1 in BarrierQueueSyncWriteProtection.withSharedAccess<A where A1: Sendable>(@Sendable (A) -> A1) -> A1` |

### Missing: Replaced top-level dispatch

| Hash | Symbol aliases |
| --- | --- |
| `a8318631611fbbc6e301ab83ac9cc26063535b1dcc57aa1b4e4cfe96adb9e081` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |

### Missing: Task 2 accepted pre-clock setup

| Hash | Symbol aliases |
| --- | --- |
| `042b4aae88059da788f84ff7a5c5d3bf004d85847c060361148eb0435d340399` | `static CallerPaths.(fromMainActor)(_: BlockContext, counter: CounterActor) -> Int` |
| `159e9a7672279a2460ba167f3b97c4bd109f02b79d2961623bed8d57e49563da` | `generic specialization <NSLockCounter> of static CallerPaths.(runLock)<A where A: LockCounter>(_: BlockContext, counter: A, asyncCode: AsyncCodeTunables?) -> Int` |
| `320fd9831c306431abd0ea361416e19e54a5cc749605add6dbcb4c4c27a3e7bf` | `function signature specialization <Arg[1] = Dead> of static CallerPaths.(toMainActor)(BlockContext) -> Int` |
| `6503209db707df67bc41c5586fbd684c3ce51752c1e9836282b79dc2fdd95b56` | `generic specialization <MutexCounter> of static CallerPaths.(fromMainActor)<A where A: LockCounter>(_: BlockContext, counter: A) -> Int` |
| `e313f56dd16a02936f2e1a951fae815baa0be9b4ecc348abc90f59af29052aea` | `generic specialization <AllocatedUnfairLockCounter> of static CallerPaths.(fromMainActor)<A where A: LockCounter>(_: BlockContext, counter: A) -> Int` |

### Missing: Untimed asynchronous coordinator and check assembly

| Hash | Symbol aliases |
| --- | --- |
| `2ee8cdbf41ff78ccb00d681c810ec1754f7278d35df972fa229779328a23ea99` | `merged generic specialization <MainActorInteger> of (BaseComparisonVisitor).visitAsynchronous<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |
| `4bb9bb8ccd88b533853406643a231d7c891bda50de90a339c6d5c72f02eeb405` | `merged generic specialization <MainActorInteger> of (BaseComparisonVisitor).visitAsynchronous<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |
| `4c591a403a3334380ec1d9f4cce0c3a95a943954cc0ec7dca749b127447690d0` | `merged generic specialization <MainActorInteger> of (BaseComparisonVisitor).visitAsynchronous<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |
| `54c49c6b366035c613a84d1cc34e4efad99bd08395058b54dec025dc5fefa40a` | `merged generic specialization <MainActorInteger> of (BaseComparisonVisitor).visitAsynchronous<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |
| `a79842879f8c1230189c80d4ad4a0fce1382722eafb96be02101109fbc4b22e3` | `merged generic specialization <MainActorInteger> of (BaseComparisonVisitor).visitAsynchronous<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |
| `f107154b3ad3354dd175a0078f6bc5f6c2d81f44c372d903c6d42f591717fec8` | `merged generic specialization <MainActorInteger> of (BaseComparisonVisitor).visitAsynchronous<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |

### Missing: Untimed main-actor counter construction

| Hash | Symbol aliases |
| --- | --- |
| `0016f6a58569b6d2195f44f71a7c7a5b8cf21ad06bb64982eb7cb7964d12c3a5` | `closure #1 @MainActor () -> MainActorCounter in closure #1 @MainActor () -> MainActorCounter in static CallerPaths.(toMainActor)(BlockContext) -> Int` |
| `428d86a97e878a33c6d4f5dbf3acf85079a0db6fba3124eeacb21e0cbc8f9fa6` | `closure #1 @MainActor () -> MainActorCounter in static CallerPaths.(toMainActor)(BlockContext) -> Int` |

### Missing: diagnostic source metadata only; same instruction/call sequence

| Hash | Symbol aliases |
| --- | --- |
| `3052f80caca1543d68b5969418dbb2c7f5c077b8ada574d65da94faeab980049` | `closure #1 @MainActor @Sendable () -> () in TrialRunner.runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)` |
| `4b307c605a5cbe83964b24df7636cd407e6d5aa3dad4317d1240eeb26bde5ac8` | `closure #1 @MainActor () -> () in closure #1 @MainActor @Sendable () -> () in TrialRunner.runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)` |
| `fef5b3ad0486031d0f33d4c1b7bfc472414c239a2b4fc1118d58b4bff3fada42` | `protocol witness for ContendedLock.touch(done: @Sendable (UInt64, Int) -> ()) -> () in conformance ContendedMutex : ContendedLock in SyncBench` |

### Missing: untimed TrialRunner to TrialSetup storage layout

| Hash | Symbol aliases |
| --- | --- |
| `20043b72661e25ca4059c482a85ac042babd7f03fc3c409716eea725dc65cf42` | `storeEnumTagSinglePayload value witness for TrialRunner` |
| `21a1e13867e45caf2ee8a4f5c071a56b3450bd238c53f11543ee36e8388ea2ad` | `storeEnumTagSinglePayload value witness for TrialRunner` |
| `21be335c6e8bb50c5822c636ef225b5b1523aebfbcebed2fc1559f1bc9ce4f3f` | `getEnumTagSinglePayload value witness for TrialRunner` |
| `3437f69c7a2d3977fc804d08c4345035049615dfa93deefb538dbadbc7e2c82f` | `initializeWithCopy value witness for TrialRunner` |
| `5d177ce7515da4c6ab013e01639b0a6b818194a82d1771c409889d78764902ae` | `assignWithTake value witness for TrialRunner` |
| `c948dc959bc7c80e602eba25990c08921cb1c9b97c48bc328a4f515233820e05` | `assignWithCopy value witness for TrialRunner` |

### Missing: untimed concrete lock factory

| Hash | Symbol aliases |
| --- | --- |
| `239fd2d490c9a4e75e059171d0e871fc49b394abe950b357f2ecd9853dcf65bf` | `function signature specialization <Arg[2] = Dead> of static ContendedLocks.make(_: MechanismID, holderQoS: QoS) -> ContendedLock` |

### Missing: untimed trial loop bookkeeping and coordination

| Hash | Symbol aliases |
| --- | --- |
| `28b681ec14dfafcb8a5f29f3d893e10409de02f910f38b32c0243de10f70c905` (iOS 26 only) | `TrialRunner.runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)` |
| `852a248a783991d5150ad910da9ab670b36a6f283aa29c06414c6d77b7dd31c3` | `TrialRunner.runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)` |
| `f22ed5a07ae8341d4e8f831143be71329bf87de076305b6961663353e7310dc3` (iOS 18 only) | `TrialRunner.runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)` |
| `f42aac1b0a368ae03ec2632319b863965069a12e4cd3300b900d89acd2d70a61` | `TrialRunner.runTrials(block: Int) -> (trials: [TrialLine], timedOut: Bool)` |

### Added: concrete lock loops (measured layout/merging exceptions)

| Hash | Symbol aliases |
| --- | --- |
| `0faf3742ab333e9f116ecb1cfb7296e0854d1121257560173a2214106c02a7fc` | `generic specialization <UnfairLockInteger> of static BaseComparison.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `1ff7d0845a55fbac415f5aa3a35d1984b22b1c6c1c61d538b617ff6d4b6f29be` | `generic specialization <DispatchSemaphoreInteger> of static BaseComparison.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `3039de3c81c7334cc1135b7841cdd45bb19afd8fe23df7fc310f55949a92c3e1` | `merged generic specialization <ObjcSyncInteger> of static BaseComparison.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `379c492c095339447605bc8415c444101114c686d30e9187bc62a0a7dfbc25a8` | `merged generic specialization <ObjcSyncInteger> of static BaseComparison.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `578c2076b17c7b02159c272185ce4a1a3ea08bf9aebbbaf5c82d52a5d61ae9e3` | `merged generic specialization <ObjcSyncInteger> of static BaseComparison.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |
| `7867e73a67a3fc6bbe5b48382763de91c30ff661f89cb55df90c9e3df096158d` | `merged generic specialization <NSRecursiveLockInteger> of static BaseComparison.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `79081dc24052707de05191e4277a88c2fbdaa96d080d53d483c9ad3dbf03fbce` | `generic specialization <DispatchSemaphoreInteger> of static BaseComparison.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `af8e5d545e28b4f698cb6b497be26d01f1da1e97965916742b19a19e2de43caf` | `merged generic specialization <NSRecursiveLockInteger> of static BaseComparison.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |
| `ce8dc7fbafc24bbb721a7c7a349a8a6e399da8894b7043401127ba47b5e35a0f` | `merged generic specialization <NSRecursiveLockInteger> of static BaseComparison.writeLoop<A where A: SharedInteger>(_: A, count: Int, firstValue: Int) -> ()` |
| `d182597384d175df59eee71dc3a73d2b9f4ef1e9520b553d3e4083e5435dce0c` | `generic specialization <UnfairLockInteger> of static BaseComparison.incrementLoop<A where A: SharedInteger>(_: A, count: Int) -> ()` |
| `dd308c40a9ba07cb9eb0534f65e90a7d8434f8aba42934a6027070b1373fabe3` | `generic specialization <DispatchSemaphoreInteger> of static BaseComparison.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |
| `e65bc4b34c902ef6c556989fffd2b51d67b121303690c5b138fc19c369091e6c` | `generic specialization <UnfairLockInteger> of static BaseComparison.readLoop<A where A: SharedInteger>(_: A, count: Int) -> Int` |

### Added: concrete lock workers (measured merging exceptions)

| Hash | Symbol aliases |
| --- | --- |
| `1ba3efc38e540cb9eec5d80afa4a3f2feb282fcf25e31d8176d5e4c6da42d70c` | `generic specialization <PthreadReadWriteLockInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]` |
| `42fbb972050f0ba28f630c77ccf2533c2818c12bcf675ae340e9da92fc35f5c8` | `generic specialization <ObjcSyncInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]`<br>`generic specialization <PthreadMutexInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]` |
| `506850c162200540ca5236bfd8e067dd1e574b9691e16838ad6b1bb8f7af8326` | `generic specialization <ObjcSyncInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]`<br>`generic specialization <PthreadMutexInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]` |
| `606152b62576ec16bb21abd5913ded1df4cc537623e1881a97543117f8265924` | `generic specialization <PthreadMutexInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]` |
| `91b0a5dd5617fdb49930616be2a5c96d6786506047abbf46819341d91134e540` | `generic specialization <PthreadReadWriteLockInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]` |
| `bea3b8be8a1d4824a47a4f420761d00992921c15ecfdad22dc2f4d72e7dce7c2` | `generic specialization <PthreadMutexInteger> of closure #1 @Sendable (Int, ThreadBarrier, ThreadLog) -> () in (BaseComparisonTiming).measure<A where A: SharedInteger>(A) -> [CheckResult]` |

### Added: concrete mechanism interface/metadata replacing generic protections

| Hash | Symbol aliases |
| --- | --- |
| `186a1210c4761b21d31b790efe42e48048a6b33c1def5509446d20a0a3223387` | `type metadata accessor for NSLockInteger` |
| `1dbdff32766916b891920fa05b6a46064955b543a20f1e3b122c28f18819a862` | `protocol witness for SharedInteger.write(Int) -> () in conformance MutexInteger : SharedInteger in SyncBench` |
| `2cec62ed25117a22abed42f3b44b27bace6159f9b248b210d1951c7b197e37c5` | `merged protocol witness for SharedInteger.read() -> Int in conformance NSLockInteger : SharedInteger in SyncBench` |
| `2d3ed73e3114a55f78aff87ec54cc0d7bf9d3e5c068dd8bae13e518f36204319` | `protocol witness for SharedInteger.increment() -> () in conformance MutexInteger : SharedInteger in SyncBench` |
| `2e6112077d8ac1d4aca1862718cfe0171c10c317867d2754e1e0dd40ccbc01ef` | `merged protocol witness for SharedInteger.write(Int) -> () in conformance NSLockInteger : SharedInteger in SyncBench` |
| `366c711060f604a45202d77220d39ea753226ec55213b30a6638970ee19e8517` | `merged protocol witness for SharedInteger.read() -> Int in conformance PthreadMutexInteger : SharedInteger in SyncBench` |
| `3804cbe90c00207696ed76712f6c132dc94a441450679b78923a34b9eba889cd` | `AdaptiveSpinUnfairLockInteger.read() -> Int` |
| `5867249f98cf7fc32607d8f609414386c66861491fafce468ecef0434551a1a7` | `protocol witness for SharedInteger.write(Int) -> () in conformance UnfairLockInteger : SharedInteger in SyncBench` |
| `5ac02aebe70e6334a144e71c2ba9acf3fb6472cb8d9bdfc2d9b24a9fe262fc2a` | `AdaptiveSpinUnfairLockInteger.increment() -> ()` |
| `6227ef76b341790bd4a19261f54a3a74f10a075e760871f7765976b56bf772a2` | `protocol witness for SharedInteger.increment() -> () in conformance AllocatedUnfairLockInteger : SharedInteger in SyncBench` |
| `700a2a26239dc079bb55b264fc6f2d06ab3a4c7794b6096152cf3cea95afe853` | `protocol witness for SharedInteger.read() -> Int in conformance UnfairLockInteger : SharedInteger in SyncBench` |
| `812848283e16a8d5bd1f72096ee4f9abd10e57f4d486ddc329d98b1e4459c651` | `protocol witness for SharedInteger.increment() -> () in conformance ObjcSyncInteger : SharedInteger in SyncBench` |
| `8db51c35053e9f143cc7323c82b3797d8a535158806d44689f1e8c75dddafaf5` | `protocol witness for SharedInteger.increment() -> () in conformance PthreadMutexInteger : SharedInteger in SyncBench`<br>`protocol witness for SharedInteger.increment() -> () in conformance PthreadReadWriteLockInteger : SharedInteger in SyncBench`<br>`protocol witness for SharedInteger.read() -> Int in conformance PthreadMutexInteger : SharedInteger in SyncBench`<br>`protocol witness for SharedInteger.read() -> Int in conformance PthreadReadWriteLockInteger : SharedInteger in SyncBench` |
| `9dfd06027ccfd42c1ee99948d0a18c4c342c3f7191a316b5cb8e9a1fa463c9aa` | `protocol witness for SharedInteger.write(Int) -> () in conformance AllocatedUnfairLockInteger : SharedInteger in SyncBench` |
| `a4280048aadadd125841ea18d015582b9f6df874d1547b0e09bcc5a1cc1cce38` | `protocol witness for SharedInteger.read() -> Int in conformance DispatchSemaphoreInteger : SharedInteger in SyncBench` |
| `a4c04cf16b90fd424845e27a57936b5025a2ea4200bd3eba65726594e7adda98` | `protocol witness for SharedInteger.write(Int) -> () in conformance ObjcSyncInteger : SharedInteger in SyncBench` |
| `be041d4e2680d5ab441e64b69a93c8f10f76d6d6918fb05cec30995cdb619c1d` | `merged protocol witness for SharedInteger.increment() -> () in conformance PthreadMutexInteger : SharedInteger in SyncBench` |
| `c5b6dbc96c85b4fc191ec7a28c4c2fc701555326f593caff63f03f05316dbb2a` | `protocol witness for SharedInteger.increment() -> () in conformance UnfairLockInteger : SharedInteger in SyncBench` |
| `cbb36f056d062323b54fd67f38658fe6b6653fc1bb33911bd689628558046413` | `protocol witness for SharedInteger.read() -> Int in conformance MutexInteger : SharedInteger in SyncBench` |
| `ce404e328ed634072bf12a3b152e66fbc3736cc9b87d4b98ae1e427d4ce70cd8` | `protocol witness for SharedInteger.write(Int) -> () in conformance DispatchSemaphoreInteger : SharedInteger in SyncBench` |
| `d0ad254506b3fd93f45f74888b897c0aa5aef57fcf1450216dc88d28b1050c9b` | `protocol witness for SharedInteger.increment() -> () in conformance DispatchSemaphoreInteger : SharedInteger in SyncBench` |
| `d11757df9369f7b527dfc16f9221da55613b4a30e53d2d58bf0301ddc90cf59c` | `merged protocol witness for SharedInteger.write(Int) -> () in conformance PthreadMutexInteger : SharedInteger in SyncBench` |
| `e573f2b4869ae9596e0a8e513fac6bac8d932ad00189042a28ebdc7870f13fa7` | `protocol witness for SharedInteger.read() -> Int in conformance ObjcSyncInteger : SharedInteger in SyncBench` |
| `eaef4597cb1c461b2bbfbaebbc2e75238f0389a27b1a5e0d2e0bd88b1af80ade` | `protocol witness for SharedInteger.write(Int) -> () in conformance PthreadMutexInteger : SharedInteger in SyncBench`<br>`protocol witness for SharedInteger.write(Int) -> () in conformance PthreadReadWriteLockInteger : SharedInteger in SyncBench` |
| `f26aaa6e3e3c92719bbd2039a6bcea8837f258c901dae116d513b8a1c4cf4406` | `merged protocol witness for SharedInteger.increment() -> () in conformance NSLockInteger : SharedInteger in SyncBench` |
| `fc44e91f441f97c592397ededb5155cb906a68cd58a4155eb7d89e429ad7de08` | `AdaptiveSpinUnfairLockInteger.write(Int) -> ()` |
| `ff26d353d0928016def5cdcfe834191972a94e59c5c6381563b2c1d97c2d010e` | `protocol witness for SharedInteger.read() -> Int in conformance AllocatedUnfairLockInteger : SharedInteger in SyncBench` |

### Added: extracted final checks (untimed)

| Hash | Symbol aliases |
| --- | --- |
| `18c93d21aeb87a9021d896a05b3c1126da0b456359d3d9bebb34b40be89c6e56` | `function signature specialization <Arg[4] = Dead> of static BaseComparisonChecks.checks(operation: BaseComparison.Operation, finalValue: Int, logs: [ThreadLog], block: BlockContext) -> [CheckResult]` |
| `2a9b3fddbd51477e3104e6e252c529ee8566b82d8a3fb24ee243fd4caf3ff64c` | `function signature specialization <Arg[4] = Dead> of static BaseComparisonChecks.checks(operation: BaseComparison.Operation, finalValue: Int, logs: [ThreadLog], block: BlockContext) -> [CheckResult]` |
| `2d02c77b8c4e8ad038482c55a12ee182fcc866919dd2d9b03cbfe4d3846f9d44` | `function signature specialization <Arg[4] = Dead> of static BaseComparisonChecks.checks(operation: BaseComparison.Operation, finalValue: Int, logs: [ThreadLog], block: BlockContext) -> [CheckResult]` |
| `3a217965e3efc1349edf01ddc440ffc0a5359bbf2faa0bb31a3ac3bcdf1da398` | `function signature specialization <Arg[4] = Dead> of static BaseComparisonChecks.checks(operation: BaseComparison.Operation, finalValue: Int, logs: [ThreadLog], block: BlockContext) -> [CheckResult]` |
| `57ecf6d7d5517023722b3b89614148dcfb5a43b1c9d839606b44237e127778d0` | `function signature specialization <Arg[3] = Dead> of static AsyncCodeChecks.checkCount(finalValue: Int, asyncCode: AsyncCodeTunables?, block: BlockContext) -> CheckResult` |
| `e4f5e1bd46e5ceac798844ad2e83975e6f38172d30abb1a0d38611c0a1fe9975` | `function signature specialization <Arg[4] = Dead> of static BaseComparisonChecks.checks(operation: BaseComparison.Operation, finalValue: Int, logs: [ThreadLog], block: BlockContext) -> [CheckResult]` |

### Added: extracted request validation (untimed)

| Hash | Symbol aliases |
| --- | --- |
| `01e4426826045e4ef64445be174af77af7d3123732450ed741999dffeb6d19bc` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `04761c4757c1c219ab8d4dd4a5bb2727798d071e7d467ca13d0974da0831a363` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `0ae9e0651ddc023c115b283e9a75a4708de0f5cdd128d6ce7b53a298da35abc3` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `11a2954ad2359af6fd6d1b18489d031bc1664a0d05bb1b6e6ba4be32aa379684` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `2047b18ff4d221c44960811182c4a2e2005e79f84338cc699d8af73ff2a52927` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `212a68bd90549e1da302059d5afde05678031c5cdde4e68cc1edded6b660f3bd` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `236210571332032fd3faaaa3e0dfa5476c1489d68220f9a48c672c4a7625b7ed` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `262d5914d3db25f9777d7cd49bec96a3c6f70f19f05a85379a4c34a4158d48ae` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `2d163e0220916fc43fcc5df41b44b2285c670fcc141a321905b5cbd275b9e89d` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `3b284888de78ca9c0c5af3fad8663d8ea06354243e6d7c74f050c5eb690c4e0c` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `3e43f24b03efada23e048f3a3f61cc2e24cbc39b3e60e910b9c3009bb50bef4d` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `4019ac3983b56ee52bb2b2819876efa23e62b1a211c901b7d5403d1e5725077b` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `41ad865bfb58390b6b5435a8db258fd772ec5cbd9bf430c24941bf89b454fde4` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `4528eae345fdf08c06329f5d2513ff2654d30bd3a5d6637a6ce8ac2c063c21ff` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `49277e73e117191a1c97f2b79592718743dc8396573f7eefb99ad875e3cf459c` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `5a2a544077c5fe209120b7a2382087257f9994335bb07b6ba86a30c1897050e2` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `5a70de132fb9e39c6243387c9df7bdc7abe48f97d6cf7649a49cb92ee2d53126` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `5ea7197dd82889d4e18f93ff4654ddf8d2acb7847219a6353d8c06347664fb37` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `5fdf8b26bd0b95b85c6779147fea72587626389795bca02cfc0125c41a862807` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `632a1b4c765cc336fab12400271fce9b75bca4cfc773e20a9677a189de0ce3c2` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `634f911342e947bf5f680d6bed99a653c774add35d14e29dca283e6445763012` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `64a42a4f45618ac90d1860387f49f4e30f162e80cf8474d1e5df95dc7ee7985e` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `67efb98789c3a924abe23342e7e13eaa990af0c8adfe70faf82803a29b525e7e` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `7f65748c24197691f12203d593ff3d69e2f06959e4768f95e446106621477b8c` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `7ff212a10f6e4cdca45d0c5dd8b64cb8f6329d4e528cb8e7feb061e07793f110` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `8616e3a5930cf4cf75d56c47478df885e8fc5a1b1e480a567181c0a582b15339` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `8bb96c812e8d3f54352de9bc505218085e085c007c49b1d8b60aacb6bbcbf26d` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `920f57ce8a9049e1a5d2e9d2522dc4813f072e6944f3ce28b4b27dfcc013749a` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `a5cfdd1b5dc9405db6be293af92c5dd09b3a65a98beb1af0440712f64b4dd5b2` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `ac0a78a52f50dfddd647d0b0d8312fa613cbfabc5fcdf2bbf392528599b5028b` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `b235a01c9c30671aafa8e13b80c5c16527581385e7136c1ff77f600887bd5ae1` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `b9943a177a840e27f0de08a3b8f2b2c40209410796d294dc11a2ecc88e2757fd` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `be69db9e238dad97bec88341c31718efe10770fe163aeaea23f70a9a9444f369` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `c387f0d9818aaf2db1e23686f9c35a3794800c3355fc108885a2721724b76f2e` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `ca8904d23ef765acb3e8a238cb68587942d5ca42e6f3665f6f1b787d764471ef` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `cac91dd7738a2ceaa58603b23f01a372dc3ca0fb10dd1a0606cc44542cdc69dd` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `cd83c1c56d94571123a7bdff7b77229c2d09e7cad3e670ad71342cf815e3844a` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `d019a6e8a8b43b95c17d994ec2e36bb1a958f67af5266a82c9eb1abecc903b54` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `d86db8731f41dd566e589ce413c0f87bf4e8609563d21f322566f07165745368` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `d958bdc5a3756935991790ccbd8adb4e8abd3404205bd0903b3e4ae03dd7a708` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `d99e8dbdd48e226ffbea821ae1062e6f76b3ff9c74705f1ff8ab6076be545d78` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `da981255ed7d8a132f27fe20ee370ffad042545fb4abdf43d26b619737801502` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `dc2ed3bc7657e3ee6ccdfe0b7e8bd35e1f1873d9be51db451e2456e4516f6fd3` | `function signature specialization <Arg[1] = Dead> of static AsyncCodeRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `de3f54cbc76858be43d1c3a71f01e333001aef58f13a984486134fe681e2ea35` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |
| `e20a4646cfa7d76f2030bac8d9ffd29673b63c688e0e07434d2f9474844662a0` | `function signature specialization <Arg[1] = Dead> of static BaseComparisonRequest.blocks(for: RunRequest) throws(RequestError) -> [BlockDescription]` |

### Added: extracted routing/check assembly or pre-clock setup (untimed)

| Hash | Symbol aliases |
| --- | --- |
| `03664e7aa69a53f2761df49420a1a3df92045fb5afdc3455597aeab7a5a5e7d6` | `function signature specialization <Arg[1] = Dead> of static Batching.awaitPerOperation(BlockContext) -> Int`<br>`function signature specialization <Arg[1] = Dead> of static Batching.oneAwaitPerGroup(BlockContext) -> Int` |
| `1691e7952d244b31e025389980467f2f0d80480e5505f68f3698fca600a8054b` | `closure #1 @MainActor () -> MainActorCounter in static CallerPaths.toMainActor(BlockContext) -> Int` |
| `19edf3d86ec622dee49e4d4ea0026c8f9fd448d6e4840fd2172fe1dd87ba5edd` (iOS 26 only) | `function signature specialization <Arg[1] = Dead> of BaseComparison.run(BlockContext) -> [CheckResult]` |
| `49df4ce03d5e8d3747c34ec4c465a1659c0ec04f2878c0f4aabaf6893bff9325` (iOS 18 only) | `function signature specialization <Arg[1] = Dead> of BaseComparison.run(BlockContext) -> [CheckResult]` |
| `5de7a463309bb645a4b7bdb75ee316ec545a9c2c5ea0cfa7bceee2d023a5637d` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `6ba3046cab0b70fed2061d8fde5139ed23cd5db153860f4d14b912012d72677a` | `generic specialization <AllocatedUnfairLockCounter> of static CallerPaths.fromMainActor<A where A: LockCounter>(_: BlockContext, counter: A) -> Int` |
| `70c0af092362e16066c0eac1ac2b87c1d0200c8cb5ec9e57bb2b154f8c4ec53c` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `74d9e3f26db31be6817415fe47dc158506abdc654fd8d5b6990b369b9759c546` | `function signature specialization <Arg[1] = Dead> of static CallerPaths.toMainActor(BlockContext) -> Int` |
| `8b23b3629d7e7b664697736a1a5614b17dd253b863dfd9e8ca900ffc83939cdc` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `98bfb9f42d99d7fd97bbbc22c4810e05354b09940d443581ca4a6c205818f2be` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `9ad72c22660d284b77655c3623e87da52d1455028d4ed3992024d10fcf2ecef9` | `generic specialization <MutexCounter> of static CallerPaths.fromMainActor<A where A: LockCounter>(_: BlockContext, counter: A) -> Int` |
| `9ff82bd5cb0bdbfd6576d03ad977b2230ddc0a41c91b7a83228403cabe327c7b` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `b7d361f921fe9e2d9ba5e45bdd34bc0b811353a8f5b9ebb8e0c5ba25e48bfe2f` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `cd411b91d3209c2a5d4c48bc24cd73a95635eadb992980d525738178f8548be4` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `dbb415a9db38b39a7ab2ef9210fc581ed274eb775e86e4afa47063f6d65da513` | `static CallerPaths.fromMainActor(_: BlockContext, counter: CounterActor) -> Int` |
| `dd6f5a368229ff60c68172d36c557c8c4a8772e90fd0182d334a131223dbe3d8` | `closure #1 @MainActor () -> MainActorCounter in closure #1 @MainActor () -> MainActorCounter in static CallerPaths.toMainActor(BlockContext) -> Int` |
| `e29ccac84593c02fab27e743c12912384c6d231ad6337d74a962fcf78503b3f5` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `f3c20326441bd2139c1bd8865453db05836dac3dd38c2373257e492b05a5cd88` | `function signature specialization <Arg[1] = Exploded> of AsyncCode.run(BlockContext) -> [CheckResult]` |
| `f65efd3de809a52f466c50fa076bb4457028ad72e59d714f2373443abf9c7ca6` | `generic specialization <NSLockCounter> of static CallerPaths.fromMainActor<A where A: LockCounter>(_: BlockContext, counter: A) -> Int` |

### Added: main-actor construction/async coordination (untimed)

| Hash | Symbol aliases |
| --- | --- |
| `1fe96f0c56b73e307b59e8cc330ea800acfd8ac924e3992d0db4d20805badb88` | `closure #1 @MainActor () -> MainActorInteger in closure #1 @MainActor () -> MainActorInteger in static MainActorInteger.makeOnMainThread(Int) -> MainActorInteger` |
| `97ac56b17ef211e0ecd00f33f95fc5a2e76ec1f52b004bed3f4a385711accc01` | `closure #1 @MainActor () -> MainActorInteger in static MainActorInteger.makeOnMainThread(Int) -> MainActorInteger` |
| `f8caa790b1c8a588b58d007a186f28f27046b1eb5a341ebfdeed85586818aade` | `merged generic specialization <MainActorInteger> of (BaseComparisonTiming).measureAsync<A where A: AsyncSharedInteger>(A) -> [CheckResult]` |

### Added: moved concrete-lock construction (untimed)

| Hash | Symbol aliases |
| --- | --- |
| `d38d19c5a7864b707ade8a4273587674b3ae4aee7e6ad80895174e1ec8dad8b0` | `function signature specialization <Arg[2] = Dead> of static ContendedLocks.make(_: MechanismID, holderQoS: QoS) -> ContendedLock` |

### Added: moved trial closures/witness (source-diagnostic constants only)

| Hash | Symbol aliases |
| --- | --- |
| `60d10b968e93082a714c91080a5089e5a6ccbbc404d543484136d1d7a9ad5b43` | `closure #1 @MainActor @Sendable () -> () in static PriorityInversion.runOneTrial(_: Int, warmup: Bool, setup: TrialSetup) -> TrialLine?` |
| `7291fed93d51f19cfdf184e82244645493e79c28f88e064fe419e20c8b70c31f` | `protocol witness for ContendedLock.touch(done: @Sendable (UInt64, Int) -> ()) -> () in conformance ContendedMutex : ContendedLock in SyncBench` |
| `c67ec4ed5dd9d49cd5f714d4fa0015da959060a34679ad60656419f05e79d089` | `closure #1 @MainActor () -> () in closure #1 @MainActor @Sendable () -> () in static PriorityInversion.runOneTrial(_: Int, warmup: Bool, setup: TrialSetup) -> TrialLine?` |

### Added: trial storage/controller coordination replacing TrialRunner (outside mechanism bodies)

| Hash | Symbol aliases |
| --- | --- |
| `1aa996840b86892077a8e30fc7c34c53f074b2628a6974e8688107571ff6d442` | `outlined enum get tag of TrialLine?` |
| `1c715412ad24176bc7e2af7ba3833487ffb215e688ec5564bc8c859f36ac3ae3` | `assignWithTake value witness for TrialSetup` |
| `3ba98966bf24c0dc7d87238b5602d76a7cefa89842af6ca93f0527c25757e8f7` | `initializeWithCopy value witness for TrialSetup` |
| `3e09d52a1ee13afee9c956ab3ef858291999141ec8995fb4ce42a7290325236a` | `outlined enum tag store of TrialLine?` |
| `66233d3f421d60a5e58b75ba255b3093c7ccdd36ef18e0ddde96719e71171a59` | `TrialSetup.runTrials() -> (trials: [TrialLine], timedOut: Bool)` |
| `8215e98100494891f5f9a7034597f921beb57fd2f29481651216bf31bd22cfc5` | `assignWithCopy value witness for TrialSetup` |
| `99e47bc0d72649bd15df605a8ce65a1a96a386a2d5a62fddcb453a27c5613215` | `TrialSetup.runTrials() -> (trials: [TrialLine], timedOut: Bool)` |
| `ab357bfc313fba6876921afff6c54371fe6b99bf19aeec7b04bc88664af2885b` (iOS 18 only) | `function signature specialization <Arg[3] = Dead> of static PriorityInversion.runOneTrial(_: Int, warmup: Bool, setup: TrialSetup) -> TrialLine?` |
| `bd9f7bdb6b2835e5a6e84c691acd05427c72f56aca2eac4dfb20df5b1c1a5aae` | `storeEnumTagSinglePayload value witness for TrialSetup` |
| `c52e7445b8360103c89b7624a3cf0d8bf2e62bd5bfd53de653ca357bf9b5a509` | `getEnumTagSinglePayload value witness for TrialSetup` |
| `d8db57de988a91bd69693896b43985226f9ba2976e49f1731fb020358cc54c6f` (iOS 26 only) | `function signature specialization <Arg[3] = Dead> of static PriorityInversion.runOneTrial(_: Int, warmup: Bool, setup: TrialSetup) -> TrialLine?` |
| `fabf970f5bb1e0d841f61b5d261e3f474c01c4f927b853eb5345f10c3678050f` | `storeEnumTagSinglePayload value witness for TrialSetup` |
