# Per-operation work in experiments 1 and 7

Checked on 2026-11-06 by comparing baseline `409b16a646c19aaa6544c6699606aae65ca99ceb`
with implementation `731bdd96d41fa3f08cfc9399a1f5c651af215c0c`. Both source revisions
were extracted with `git archive` into separate ignored directories before building.
This unsigned audit did not run devices. The subsequent [iphone15 repeat
acceptance](../phase-2-acceptance.md#operation-preservation-repeat-2026-11-06)
checks both deployment targets and the corrected async workload on hardware.

## Build and inspection method

Both revisions were built as unsigned arm64 Release apps for deployment targets
iOS 26.0 and iOS 18.0 with Xcode 27.1 (27A9275), Swift 6.4
(`swiftlang-6.4.0.34.1`), XcodeGen 2.46.0 and the iPhoneOS27.1 SDK.
All four builds succeeded. For each source directory and target:

```sh
xcodegen generate --spec <source>/project.yml
xcodebuild build -project <source>/SyncBench.xcodeproj -scheme SyncBench \
  -configuration Release -destination generic/platform=iOS \
  -derivedDataPath <derived-data> CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=<26.0-or-18.0>
```

No `SWIFT_*` command-line overrides were supplied. Settings snapshots confirm
Swift 6, `-O`, whole-module optimization, nonisolated default actor isolation,
Approachable Concurrency NO, both isolation inference flags NO, and default
exclusivity enforcement (`SWIFT_ENFORCE_EXCLUSIVE_ACCESS` unset).
The two isolation-probe libraries retain their project settings.

Inspection used the actual linked executables:

```sh
xcrun nm <executable> | xcrun swift-demangle
xcrun llvm-objdump --macho --mattr=+lse,+rcpc \
  --no-show-raw-insn --disassemble <executable>
xcrun llvm-objdump --macho --indirect-symbols <executable>
```

Imported branches were resolved through Mach-O indirect symbols. Function aliases
at a shared address were retained. Comparisons check instruction counts, complete
mnemonic sequences, imported-branch sequences, named direct callees, indirect
branches and dynamic access-check counts, including async continuations. This
establishes operation structure; it does not assert byte-identical executables,
identical address/register allocation or equal runtime distributions.

Exact executable SHA-256 values:

| Revision | iOS 26 | iOS 18 |
| --- | --- | --- |
| Baseline | `2522e787d8a0598fe5e83111330ea0856ea629e57b58c53bd870daac92aa6aad` | `8b0c83931b401973233e53c69cc4e6a60d0ebb626bd383a5aaf3aa4ae27b2063` |
| Corrected | `8db47afaaf4c55ea92275b91e0a4cc09fad699e2c95ff26d8cc8592f6b30e164` | `d8dbedef67c12151f007c74ed5cd48b4583a4a936805cbe01747fdf9498364ca` |

## Experiment 7 `onActor`

The baseline folded all sub-batch increments into one load/add-count/store
(iOS 26 `0x10001d468`–`0x10001d474`). The earlier phase-2 check documented that
folding; this correction supersedes that behavior.

`CounterActor.incrementAsync()` now has a deliberate `@inline(never)` so the row
retains its stated operation: one await of the same actor's async method per
increment. In both corrected targets, `runBatchesOnActor` branches to the method
at `0x100007fa0` for the first operation and `0x1000080ec` for each repeat.
The repeat continuation increments its operation index, compares it with the
sub-batch count, and calls again until complete. The method's resume body at
`0x1000077c8` contains one state load, add-one and store.

The method remains isolated to the same actor. Its async entry passes that actor
to `swift_task_switch`; this is not a round trip to another executor per operation.
The noninlined async call includes ordinary Swift async-frame costs:
`swift_task_alloc` before each invocation and `swift_task_dealloc` on resumption.
Those costs belong to this explicit call-preservation choice and are included in
the row. The former inlined `CallerPaths.onActor` batch envelope is now emitted
under `CounterActor.runBatchesOnActor`, so its continuation inventory changes too.

## Experiment 1 actor increments

Actor and MainActor increment return the incremented value. The caller accumulates
those values and records the checksum, giving each awaited result a consumer.
No noinline attribute or optimizer/exclusivity setting was added to these rows.

For `ActorInteger`, the baseline repeat path stayed on the actor. The corrected
mutation continuation returns to the generic executor after every increment:
`mov x1, #0; mov x2, #0; b swift_task_switch` at iOS 26
`0x1000137f0`–`0x1000137f8` (iOS 18 `0x100013840`–`0x100013848`).
The generic continuation consumes the result, updates the checksum and loop index,
then switches back to the actor for the next operation.

`MainActorInteger` already had a per-operation generic-executor return in the
baseline. The corrected loop preserves it, now with the consumed result:
iOS 26 `0x1000136cc`–`0x1000136e0`, iOS 18 `0x10001371c`–`0x100013730`.
Its generic continuation consumes the result before reacquiring MainActor.
The new checksum arithmetic and its overflow checks are part of these increment
workloads; this is not a claim that the new loops have the old instruction cost.

## Experiment 1 single-thread floor

The old `NoProtection<Int>` state load was hoisted outside the read loop, writes
collapsed to one final store, and increments collapsed to one add-count/store.
`UnsynchronizedInteger` now uses relaxed `Atomic<Int>` loads and stores. Increment
is a separate relaxed load and store, with no atomic read-modify-write operation;
the row remains restricted to one thread.

| Corrected operation | iOS 26 loop | iOS 18 loop | Per-operation state work |
| --- | --- | --- | --- |
| Read | `0x10000f354` | `0x10000f364` | Plain `ldr` inside the checksum loop |
| Write | `0x10000fcd8` | `0x10000fce8` | Plain `str` inside the value-generation loop |
| Increment | `0x1000104f8` | `0x100010548` | Plain `ldr`/add-one/`str` inside the counted loop |

None of these loops contains an atomic RMW, fence, lock, dynamic Swift access
check or allocation. Read and write share emitted bodies with the existing
`RelaxedAtomicInteger` specializations; the floor's worker calls those shared
bodies directly. This preserves each access without a per-operation function call.

## Other experiment 1 and 7 paths

Both deployment targets give the same comparison result:

| Coverage outside the corrected rows | Result |
| --- | --- |
| 56 experiment-1 loop aliases | Same instruction counts, mnemonic sequences, imported/direct callees, indirect branches and access counts |
| 54 concrete queue aliases, including closures and thunks | Same structure; zero dynamic access checks |
| 12 ManagedAtomic operation/accessor aliases | Same structure; six operation loops retain no access checks, separate storage accessors retain theirs |
| 285 experiment-7 caller, batching and counter aliases outside `onActor` | Same comparison metrics |
| 71 isolation-setting/probe aliases | Same comparison metrics |

Two retained experiment-1 relaxed atomic read/write function names acquire a
`merged` prefix because the new floor reuses their bodies; their instruction
structures are unchanged. The old floor's three loops and the actor/MainActor
increment continuations are replaced as described above. The `onActor` envelope,
method and continuation changes are intentional. No additional measured-row
instruction-structure change was found in the recorded inventories.

The raw binaries, full disassembly, demangled symbols, indirect imports, settings,
logs, per-function normalized records and comparison JSON remain under ignored
`build/private/operation-preservation/`. The capture script is `inspect_binary.py`;
`compare_binaries.py` records the retained, renamed, changed and missing aliases
for both targets. Local reports are under `.superpowers/operation-preservation/`.
