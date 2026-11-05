# Harness Phase 1 Implementation Plan: core, calibration, base comparison, Mac script

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working harness that runs the base comparison (experiment 1: one thread, and 2, 6 and 12 threads; iOS 26 and iOS 18 builds) and the calibration mode on one iPhone from the Mac script, and accepts or rejects every attempt by the checks in the design.

**Architecture:** One UIKit iOS app (module `SyncBench`) holds the harness core, the mechanism wrappers and the experiments. Each launch runs one attempt off the main thread and writes one JSON Lines file plus a `.done` marker into `Documents/runs/`. A Python script (`scripts/bench.py`, standard library only) builds, installs, launches with `xcrun devicectl`, copies the files one at a time and checks them.

**Tech Stack:** Swift 6.4 (Xcode 27.1), UIKit, Synchronization, os, Dispatch, swift-atomics 1.3.1, XcodeGen 2.46.0, Swift Testing on the iOS Simulator; Python 3.9+ standard library with `unittest`.

**Spec:** `docs/harness-design.md` (approved 2026-11-05) and `docs/experiments.md` (the experiment specs). Read both before any task.

## Phases

Milestone 7 is built in three plans, one per stage of the design's order of work:
1. This plan: harness core, calibration, the base comparison with both builds, the Mac script, the checks.
2. Async code (experiment 7) and priority inversion (experiment 8B), with the calibration of the 8B work size (iterations for about 5 ms on an idle core).
3. Request registry (2), hot flag (3), transactional store (4), main-thread cache (8A) with the calibration of the achieved display rate, creation cost (9).

Plans 2 and 3 are written after this plan runs on a phone, because they depend on what we learn there. Milestone 7 is done when all three run once on one iPhone with every check passing.

## Names

Code and data use readable names, never experiment numbers. The numbers stay only in the docs, to match the decision log.

| Experiment | ID in requests and data | Swift type and folder |
|---|---|---|
| 1 | `baseComparison` | `BaseComparison`, `Experiments/BaseComparison/` |
| 2 | `requestRegistry` | `RequestRegistry` |
| 3 | `hotFlag` | `HotFlag` |
| 4 | `transactionalStore` | `TransactionalStore` |
| 7 | `asyncCode` | `AsyncCode` |
| 8A | `mainThreadCache` | `MainThreadCache` |
| 8B | `priorityInversion` | `PriorityInversion` |
| 9 | `creationCost` | `CreationCost` |
| — | `calibration` | `Calibration`, `Harness/` |

Base comparison variants: `oneThread` (part A of the spec), `twoThreads`, `sixThreads`, `twelveThreads` (part B).

Mechanism IDs: `unsynchronized`, `mutex`, `osAllocatedUnfairLock`, `osAllocatedUnfairLockAdaptiveSpin`, `osUnfairLock`, `nsLock`, `nsRecursiveLock`, `pthreadMutex`, `pthreadReadWriteLock`, `serialQueue`, `barrierQueueSyncWrite`, `barrierQueueAsyncWrite`, `dispatchSemaphore`, `objcSync`, `actor`, `mainActor`, `atomic`, `atomicRelaxed`, `managedAtomic`, `managedAtomicRelaxed`.

## Global Constraints

- Toolchain: Xcode 27.1 (27A9275), swiftlang-6.4.0.34.1; XcodeGen 2.46.0. The `.xcodeproj` is generated and never committed.
- Python: everything in `scripts/` runs on Python 3.9 (Xcode's `python3` is 3.9.6) with the standard library only. Use `from __future__ import annotations` and `typing.Optional`; no `match`; no third-party packages. Run the tests with `python3 -m unittest discover -s scripts/tests -t scripts`.
- App target `SyncBench`: iPhone only, UIKit life cycle with a scene delegate, deployment target iOS 26.0; the script sets 18.0 for the second build.
- App module settings: `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, `SWIFT_APPROACHABLE_CONCURRENCY = NO`, `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = NO`, `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES = NO`. Release: `-O`, whole module. Never `-Ounchecked`; exclusivity checking stays at its default.
- Isolation is explicit. Harness, mechanism and experiment types are nonisolated; only UIKit types and the main-actor row are `@MainActor`. A run leaves the main thread on its own pthread. Code on that thread that must touch UIKit uses `DispatchQueue.main.sync { MainActor.assumeIsolated { … } }`.
- Timed code: the harness adds no I/O, logging, allocation or UI change. Samples go to storage allocated before the block; lines are encoded between blocks and written once at the end of the run. The main thread never waits without a limit.
- Data: JSON Lines, schema 1, integer ticks, sorted keys; the app computes no averages. Field names are fixed in `docs/data-format.md` (Task 2).
- Readable code: descriptive names without abbreviations (`operations`, not `ops`), one declaration per line, `///` comments where a name does not say everything, the Swift API Design Guidelines and PEP 8. Simple code first; no structure that the task does not need.
- No team ID, Apple ID, UDID, device name or absolute local path in any committed file or in `results/` (raw data becomes public at milestone 12). Personal values live only in `local.json`, which git ignores.
- Repository text in English. Commit after each task with a short imperative message; no "Co-Authored-By" lines; never rebase.

## Decisions this plan makes (agent's calls, open to correction)

- The base comparison runs every mechanism, including `osAllocatedUnfairLockAdaptiveSpin`. `unsynchronized` runs only with one thread: with more threads it is a data race.
- Worker QoS is a tunable; the smoke plans use `userInitiated`. All threads of one block use the same QoS.
- Atomic orderings (Ivan, 2026-11-05): `Atomic` and `ManagedAtomic` get two rows each. `atomic` and `managedAtomic` read with `.acquiring`, write with `.releasing` and increment with `.acquiringAndReleasing`, the guarantees a lock gives. `atomicRelaxed` and `managedAtomicRelaxed` use `.relaxed` everywhere, as a typical counter does.
- Locks use explicit `lock()` / `unlock()` with `defer`. `Mutex` and `OSAllocatedUnfairLock` use `withLock`. Each wrapper keeps the state as app code does: a `private var` in a final class guarded by the primitive; `Mutex` and `OSAllocatedUnfairLock` keep it inside the lock.
- Every batch of a block starts from a shared barrier. Each thread does the same number of operations and records its own start and end ticks.
- The build ID goes into `Info.plist` keys through build settings on the `xcodebuild` command line. It is embedded before signing, without a generated source file. A build made in Xcode without the script reports `unknown`. Each build gets a new build ID; the code hash in `build-info.json` tells whether two builds are comparable.
- The launch request is one argument: `--bench-request <base64 of the request JSON>`, after `--` on the `devicectl` command line.
- One plan file uses one build target; runs for the iOS 18 build live in their own plan file.
- Smoke runs record the conditions but never refuse, so development needs no thermal or charging setup.
- A smoke request may ask the app to crash or hang on purpose, to check the script's `crashed` and `timeout` handling with the real `devicectl`. Unit tests cover the other paths.
- The disassembly check (design, Checks §5) is done by hand with two commands; there is no script for it.

## Review Focus

1. Release-only optimizer effects. The `unsynchronized` floor or a read loop can collapse under `-O`, because nothing in the loop calls out; `withLock` may fail to inline; one wrapper may keep a dynamic exclusivity check that another loses. Task 15 looks at every measured loop in the Release binary and writes down what the compiler did. Nobody adds calls to defeat the optimizer.
2. Comparable builds across weekly re-signing. Two builds of one commit must give the same code hash. Task 15 builds twice and compares.
3. The phone locks or loses the connection mid-session, or the free profile expires. The script stops with a clear reason, and the next session continues with the next pending run. Task 14 tests a fake device that reports "locked" and one whose launch fails.
4. `devicectl` output that changes or does not parse. The parsers raise an error that names the command and keeps the raw output next to the session log. Task 13 tests a malformed file.

## Prerequisites from Ivan

- Before Task 1: network access for the swift-atomics package.
- Before Task 12: one phone on the cable, unlocked, with Developer Mode on. It is off on the iPhone 15 Pro Max; the iPhone 11 Pro Max has it on but was not connected on 2026-11-05. `local.json` holds the free team that signed the probe on 2026-10-29, a bundle ID under Ivan's own prefix and the phone UDIDs; it stays local. After the first install, trust the developer certificate on the phone (Settings → General → VPN & Device Management).
- Both phones run iOS 26.6.x. That is fine here: timed runs on iOS 27.x belong to milestone 8.

---

### Task 1: Repository scaffold and app shell

**Files:**
- Create: `.gitignore`, `README.md`, `project.yml`, `local.example.json`, `App/AppDelegate.swift`, `App/SceneDelegate.swift`, `App/RunViewController.swift`, `App/Info.plist`, `Tests/AppShellTests.swift`
- Already present: `docs/harness-design.md`, `docs/experiments.md`, this plan

**Interfaces:**

```swift
/// The only screen. Shows the run status, which never changes during timed work.
@MainActor
final class RunViewController: UIViewController {
    /// The text the status label shows now.
    var currentStatus: String { get }

    func showStatus(_ text: String)
}
```

- [ ] **Step 1: Write `.gitignore`**

```gitignore
*.xcodeproj/
build/
results/
local.json
.DS_Store
__pycache__/
*.pyc
```

- [ ] **Step 2: Write `project.yml`**

```yaml
name: SyncBench

options:
  deploymentTarget:
    iOS: "26.0"

packages:
  swift-atomics:
    url: https://github.com/apple/swift-atomics.git
    exactVersion: 1.3.1

settingGroups:
  swiftSettings:
    SWIFT_VERSION: "6.0"
    SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated
    SWIFT_APPROACHABLE_CONCURRENCY: NO
    SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT: NO
    SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES: NO

targets:
  SyncBench:
    type: application
    platform: iOS
    sources:
      - App
      - path: Harness
        optional: true
      - path: Mechanisms
        optional: true
      - path: Experiments
        optional: true
    dependencies:
      - package: swift-atomics
        product: Atomics
    settings:
      groups: [swiftSettings]
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.example.syncbench
        INFOPLIST_FILE: App/Info.plist
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        TARGETED_DEVICE_FAMILY: "1"
        CODE_SIGN_STYLE: Automatic
        BENCH_BUILD_ID: ""
        BENCH_GIT_COMMIT: ""
        BENCH_GIT_DIRTY: ""
        BENCH_BUILD_TARGET: ""
      configs:
        Release:
          SWIFT_OPTIMIZATION_LEVEL: -O
          SWIFT_COMPILATION_MODE: wholemodule
    scheme:
      testTargets:
        - SyncBenchTests

  SyncBenchTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - Tests
    dependencies:
      - target: SyncBench
    settings:
      groups: [swiftSettings]
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.example.syncbench.tests
        GENERATE_INFOPLIST_FILE: YES
```

  No team ID here: the script passes it on the command line (Task 12).

- [ ] **Step 3: Write `App/Info.plist`** (Xcode merges it with the generated keys)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <true/>
    <key>UIFileSharingEnabled</key>
    <true/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
        <key>UISceneConfigurations</key>
        <dict>
            <key>UIWindowSceneSessionRoleApplication</key>
            <array>
                <dict>
                    <key>UISceneConfigurationName</key>
                    <string>Default</string>
                    <key>UISceneDelegateClassName</key>
                    <string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
                </dict>
            </array>
        </dict>
    </dict>
    <key>BenchBuildID</key>
    <string>$(BENCH_BUILD_ID)</string>
    <key>BenchGitCommit</key>
    <string>$(BENCH_GIT_COMMIT)</string>
    <key>BenchGitDirty</key>
    <string>$(BENCH_GIT_DIRTY)</string>
    <key>BenchBuildTarget</key>
    <string>$(BENCH_BUILD_TARGET)</string>
</dict>
</plist>
```

- [ ] **Step 4: Write the failing test** `Tests/AppShellTests.swift`

```swift
import Testing
import UIKit
@testable import SyncBench

@MainActor
@Test func idleScreenShowsIdleStatus() {
    let controller = RunViewController()

    controller.loadViewIfNeeded()

    #expect(controller.currentStatus == "SyncBench idle")
}
```

- [ ] **Step 5: Run it**

```bash
xcodegen generate
xcodebuild test -project SyncBench.xcodeproj -scheme SyncBench \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

  Expected: the build fails because `RunViewController` does not exist.

- [ ] **Step 6: Implement the shell.** `AppDelegate` does nothing at launch. `SceneDelegate` creates the window with `RunViewController`. `RunViewController` shows one centered label with "SyncBench idle".

- [ ] **Step 7: Run the tests again.** Expected: `** TEST SUCCEEDED **`, one test passed.

- [ ] **Step 8: Check that the device build compiles without signing**

```bash
xcodebuild build -project SyncBench.xcodeproj -scheme SyncBench \
  -configuration Release -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO -quiet
```

  Expected: exit status 0.

- [ ] **Step 9: Write `local.example.json`** (placeholders only) and `README.md` (two sentences on what the repository is, "Status: under construction (milestone 7)", and the commands from Steps 5 and 8)

```json
{
  "teamID": "ABCDE12345",
  "bundleID": "com.example.syncbench",
  "phones": {
    "iphone11": {
      "udid": "00000000-0000000000000000",
      "model": "iPhone12,5"
    },
    "iphone15": {
      "udid": "00000000-0000000000000000",
      "model": "iPhone16,2"
    }
  }
}
```

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add app shell, project spec and design docs"
```

---

### Task 2: Run request, seeded order, result lines and writer

**Files:**
- Create: `Harness/Random.swift`, `Harness/RunRequest.swift`, `Harness/BuildInfo.swift`, `Harness/ResultLines.swift`, `Harness/ResultWriter.swift`, `docs/data-format.md`, `Tests/TestSupport.swift`, `Tests/RunRequestTests.swift`, `Tests/ResultWriterTests.swift`, `Tests/Fixtures/golden-base-comparison.jsonl`

**Interfaces:**

```swift
/// SplitMix64: a small seeded generator, so one seed always gives one block order.
struct SplitMix64: RandomNumberGenerator {
    init(seed: UInt64)

    mutating func next() -> UInt64
}

/// Fisher–Yates from the last element down: for each i from count - 1 to 1,
/// swap element i with element Int(generator.next() % UInt64(i + 1)).
func seededShuffle<Element>(_ items: [Element], seed: UInt64) -> [Element]
```

```swift
enum QoS: String, Codable, Sendable, CaseIterable {
    case userInteractive
    case userInitiated
    case `default`
    case utility
    case background
}

/// Smoke runs only: makes the app fail on purpose, to check the Mac script.
enum Simulation: String, Codable, Sendable {
    /// `fatalError` after the first block.
    case crash
    /// The run thread sleeps forever after the first block; the main thread stays free.
    case hang
}

struct Tunables: Codable, Equatable, Sendable {
    var threads: Int
    var qos: QoS
    var warmupBatches: Int
    var measuredBatches: Int
    /// A batch is split into sub-batches; the CPU number is read between them.
    var subBatches: Int
    /// Operations per batch by mechanism ID. The key "default" covers the others.
    var operationsPerBatch: [String: Int]
    var referenceLoopIterations: Int
    /// Calibration only: samples per measurement.
    var repeats: Int?
}

struct RunRequest: Codable, Equatable, Sendable {
    var schema: Int
    var runID: String
    var attemptID: String
    var attempt: Int
    var experiment: String
    var variant: String
    var seed: UInt64
    var smoke: Bool
    var simulation: Simulation?
    var mechanisms: [String]
    var operations: [String]
    var tunables: Tunables

    /// Returns nil when the arguments contain no `--bench-request`.
    static func decode(launchArguments: [String]) throws(RequestError) -> RunRequest?

    func validate() throws(RequestError)

    func operationsPerBatch(for mechanism: String) -> Int
}

struct RequestError: Error, Equatable, Sendable {
    let message: String
}
```

```swift
/// What the build script put into Info.plist before signing.
struct BuildInfo: Codable, Equatable, Sendable {
    /// "unknown" for a build made in Xcode without the script.
    var buildID: String
    var commit: String
    var dirty: Bool
    /// "ios26" or "ios18".
    var target: String
    /// `MinimumOSVersion` from the bundle.
    var minimumOS: String
    /// "Release" or "Debug".
    var configuration: String

    static func current(bundle: Bundle = .main) -> BuildInfo
}
```

```swift
/// Encoded result lines, kept in memory until the run ends.
/// Only the run thread appends to it.
final class ResultLineBuffer: @unchecked Sendable {
    private(set) var data: Data
    /// Lines written so far, by line type.
    private(set) var lineCounts: [String: Int]

    func append<Line: Encodable>(_ line: Line)
}

struct DoneMarker: Codable, Equatable, Sendable {
    let attemptID: String
    let file: String
    let bytes: Int
    let sha256: String
}

enum ResultWriter {
    /// Writes `<attemptID>.jsonl` atomically, then `<attemptID>.done`.
    static func write(
        _ lines: ResultLineBuffer,
        attemptID: String,
        to directory: URL
    ) throws -> DoneMarker
}
```

`ResultLines.swift` holds one `Encodable` struct per line type (`RunLine`, `ReferenceLine`, `BlockLine`, `BatchLine`, `SamplesLine`, `EndLine`) and the nested types (`PhoneFacts`, `PerformanceLevel`, `Conditions`, `CheckResult`, `ThermalChange`). The keys are the ones in `docs/data-format.md`. For example:

```swift
struct BatchLine: Encodable {
    let type = "batch"
    let block: Int
    let batch: Int
    let thread: Int
    let warmup: Bool
    let operations: Int
    let start: UInt64
    let end: UInt64
    let cpuReadings: [Int]
    let executorCPUReadings: [Int]?
}
```

**`docs/data-format.md`** fixes these lines. Keys are camelCase and sorted on output; an optional key is left out when it has no value, never written as `null`.

- `run`: `type`, `schema`, `request` (the request as decoded), `build`, `phone`, `conditions`.
- `phone`: `machine`, `osVersion`, `osBuild`, `cpuCount`, `activeCPUCount`, `performanceLevels` (each: `index`, `name`, `logicalCPUCount`, `physicalCPUCount`, `l1DataCacheBytes`, `l2CacheBytes`, `cpusPerL2`), `cacheLineBytes`, `memoryBytes`, `timebaseNumerator`, `timebaseDenominator`, `mainThreadQoSClass`, optional `mutexDefaultPolicy`, optional `ulockAdaptiveSpinMicroseconds`.
- `conditions`: `thermalState` (`nominal`, `fair`, `serious`, `critical`), `lowPowerMode`, `batteryState` (`unknown`, `unplugged`, `charging`, `full`), `batteryLevelPermille` (−1 when unknown), `screenBrightnessPermille`, `debuggerAttached`, `applicationState` (`active`, `inactive`, `background`), `environment` (only the watched variables that are set), `ticks`, `wallClock` (ISO 8601, UTC, seconds).
- `reference`: `type`, `when` (`start` or `end`), `iterations`, `start`, `end`, `cpuReadings` (before and after).
- `block`: `type`, `block` (position in the run order, from 0), `mechanism`, `operation`, `threads`, `qos`, `operationsPerBatch`, `start`, `end`, `voluntaryContextSwitches`, `involuntaryContextSwitches`, `taskContextSwitches` (changes over the block), `thermalStateAtStart`, `thermalStateAtEnd`.
- `batch`: `type`, `block`, `batch` (from 0; warm-up batches first), `thread`, `warmup`, `operations`, `start`, `end`, `cpuReadings` (`subBatches + 1` values), optional `executorCPUReadings` (same length).
- `samples`: `type`, optional `block`, optional `thread`, `metric`, `unit`, `values`, optional `cpuAtStart` and `cpuAtEnd` (as long as `values`).
- `end`: `type`, `status` (`completed`, `refused`, `failed`), optional `reasonCode`, optional `reason`, `checks` (each: `name`, optional `block`, `passed`, `detail`, optional `violations`), `blockLines`, `warmupBatchLines`, `measuredBatchLines`, `conditions` (at the end), `thermalChanges` (each: `ticks`, `thermalState`).
- Order: `run`; `reference` (start); for each block its `block` line, then its `batch` lines by thread and batch, then its `samples` lines; `reference` (end); `end`. A refused or invalid attempt has only `run` and `end`.
- Reason codes. Refused: `thermal`, `lowPower`, `battery`, `debugger`, `applicationState`, `environment`, `configuration`. Failed: `check`, `invalidRequest`.
- The `.done` file: `attemptID`, `file`, `bytes`, `sha256` (lowercase hex).

**Validation rules.** Each failure names its field in `message`:
- `schema` is 1;
- `runID` and `attemptID` match `^[A-Za-z0-9._-]{1,128}$`;
- `attempt` is at least 1; `seed` is below 2^53;
- `threads` is 1…64; `warmupBatches` is at least 0; `measuredBatches` and `subBatches` are at least 1;
- `operationsPerBatch` has a `"default"` key, and every value is a multiple of `subBatches` and at least `subBatches`;
- `referenceLoopIterations` is at least 1;
- `simulation` appears only in smoke requests.

**The golden attempt** is the contract between the Swift writer and the Python checker (Task 11):
- request:

```json
{
  "schema": 1,
  "runID": "golden.one-thread.1",
  "attemptID": "golden.one-thread.1.attempt1.20261105T000000Z.0000",
  "attempt": 1,
  "experiment": "baseComparison",
  "variant": "oneThread",
  "seed": 7,
  "smoke": true,
  "mechanisms": ["mutex"],
  "operations": ["increment"],
  "tunables": {
    "threads": 1,
    "qos": "userInitiated",
    "warmupBatches": 1,
    "measuredBatches": 2,
    "subBatches": 2,
    "operationsPerBatch": { "default": 4 },
    "referenceLoopIterations": 10
  }
}
```

- build ID `0123456789ab-clean-ios26-20261105T000000Z`;
- lines: `run`, `reference` (start), one `block` (`mutex`, `increment`), three `batch` lines (4 operations, 3 CPU readings each), `reference` (end), `end` (`completed`; one passed check `baseComparison.increment` with detail `expected 12, got 12`; 1 block line, 1 warm-up and 2 measured batch lines);
- ticks increase through the file; phone facts and conditions are fixed made-up values.

`Tests/TestSupport.swift` holds the helpers that later tasks extend: `RunRequest.golden`, `GoldenAttempt.lines()` (builds the golden lines), `fixtureURL(_:)` (a file in `Tests/Fixtures`, found from `#filePath`) and `InvalidRequestCase` (`request`, `field`; one case per validation rule).

- [ ] **Step 1: Write the failing tests**

```swift
import CryptoKit
import Foundation
import Testing
@testable import SyncBench

@Test func splitMix64GivesKnownValues() {
    var generator = SplitMix64(seed: 0)

    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
    #expect(generator.next() == 0x06C4_5D18_8009_454F)
}

@Test func seededShuffleGivesFixedOrder() {
    #expect(seededShuffle(Array(0..<10), seed: 42) == [0, 9, 5, 8, 6, 4, 7, 2, 1, 3])
    #expect(seededShuffle(["a", "b", "c", "d", "e"], seed: 7) == ["e", "b", "d", "a", "c"])
}

@Test func requestRoundTripsThroughLaunchArguments() throws {
    let request = RunRequest.golden
    let argument = try JSONEncoder().encode(request).base64EncodedString()

    let decoded = try RunRequest.decode(
        launchArguments: ["SyncBench", "--bench-request", argument]
    )

    #expect(decoded == request)
}

@Test(arguments: InvalidRequestCase.all)
func invalidRequestNamesTheField(_ invalidCase: InvalidRequestCase) {
    let error = #expect(throws: RequestError.self) {
        try invalidCase.request.validate()
    }

    #expect(error?.message.contains(invalidCase.field) == true)
}

@Test func writerOutputMatchesGoldenFile() throws {
    let lines = GoldenAttempt.lines()
    let goldenURL = fixtureURL("golden-base-comparison.jsonl")

    if ProcessInfo.processInfo.environment["RECORD_GOLDEN"] == "1" {
        try lines.data.write(to: goldenURL)
    }

    #expect(lines.data == (try Data(contentsOf: goldenURL)))
}

@Test func doneMarkerDescribesTheFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)

    let marker = try ResultWriter.write(
        GoldenAttempt.lines(),
        attemptID: RunRequest.golden.attemptID,
        to: directory
    )

    let file = try Data(contentsOf: directory.appending(path: marker.file))
    let fileHash = SHA256.hash(data: file)
        .map { String(format: "%02x", $0) }
        .joined()

    #expect(marker.attemptID == RunRequest.golden.attemptID)
    #expect(marker.bytes == file.count)
    #expect(marker.sha256 == fileHash)
}
```

  Also: no `--bench-request` argument gives `nil`; `operationsPerBatch(for:)` with `["default": 8, "actor": 4]` gives 4 for `actor` and 8 for `mutex`.

- [ ] **Step 2: Run the tests.** Expected: the build fails; the types do not exist.
- [ ] **Step 3: Implement** the types, then write `docs/data-format.md` from the list above.
- [ ] **Step 4: Record the golden file once.** Run `writerOutputMatchesGoldenFile` with `RECORD_GOLDEN=1` in the test environment. Read the new file against `docs/data-format.md`, then run the tests without the variable.
- [ ] **Step 5: Run the tests.** Expected: all pass.
- [ ] **Step 6: Commit**: `git commit -m "Add run request, result lines and writer"`

---

### Task 3: Clock, threads, barriers, thread logs

**Files:**
- Create: `Harness/Clock.swift`, `Harness/BlackHole.swift`, `Harness/BenchmarkThread.swift`, `Harness/Barriers.swift`, `Harness/ThreadLog.swift`, `Harness/ContextSwitches.swift`, `Tests/ThreadTests.swift`
- Modify: `Tests/TestSupport.swift`: add `onBenchmarkThread(_:)`, which runs a closure on a `BenchmarkThread` and returns its result through a continuation. Tests that block use it, so they never hold a pool thread or the main thread.

**Interfaces:**

```swift
enum Clock {
    /// `mach_absolute_time()`: ticks, not nanoseconds.
    @inline(__always)
    static func now() -> UInt64

    static let timebase: mach_timebase_info_data_t
}

enum CPU {
    /// `pthread_cpu_number_np`: the CPU this thread runs on at the moment of the call.
    /// Returns -1 if the call fails.
    @inline(__always)
    static func current() -> Int
}

/// Keeps the optimizer from deleting a value that nothing else uses.
/// `@_optimize(none)` is an underscored attribute (see package-benchmark PR #179);
/// the method text says so.
@_optimize(none) @inline(never)
func blackHole<T>(_ value: T)

/// Hides a value from the optimizer, so it cannot treat it as a constant.
@_optimize(none) @inline(never)
func opaque<T>(_ value: T) -> T
```

```swift
extension QoS {
    var qosClass: qos_class_t { get }

    /// `TaskPriority(rawValue: UInt8(qosClass.rawValue))`.
    var taskPriority: TaskPriority { get }
}

/// A pthread with a declared QoS.
final class BenchmarkThread: @unchecked Sendable {
    static func start(
        name: String,
        qos: QoS,
        body: @escaping @Sendable () -> Void
    ) -> BenchmarkThread

    func join()
}

/// Releases all parties at once. Uses `pthread_mutex` and `pthread_cond`; reusable.
final class ThreadBarrier: @unchecked Sendable {
    init(parties: Int)

    func arriveAndWait()
}

/// The same for tasks. It suspends the task and never blocks a thread.
final class TaskBarrier: Sendable {
    init(parties: Int)

    func arriveAndWait() async
}
```

```swift
/// One CPU reading that another thread fills in: the queue that runs async writes,
/// an actor, or the main actor.
struct CPUReadingSlot: @unchecked Sendable {
    func store(_ cpu: Int)
}

/// Timing storage for one thread in one block. Allocated before the block in one
/// piece, aligned to 128 bytes; readings start at -1. Only its own thread writes it;
/// the run thread reads it after `join`.
final class ThreadLog: @unchecked Sendable {
    init(batches: Int, readingsPerBatch: Int)

    func recordTimes(batch: Int, start: UInt64, end: UInt64)
    func recordCPU(batch: Int, reading: Int, cpu: Int)
    func executorSlot(batch: Int, reading: Int) -> CPUReadingSlot
    func recordCheckValue(batch: Int, value: Int)

    func start(ofBatch batch: Int) -> UInt64
    func end(ofBatch batch: Int) -> UInt64
    func cpuReadings(ofBatch batch: Int) -> [Int]
    /// nil when nothing filled the executor slots of this batch.
    func executorCPUReadings(ofBatch batch: Int) -> [Int]?
    func checkValue(ofBatch batch: Int) -> Int
}

struct ContextSwitches: Equatable, Sendable {
    /// `getrusage`: `ru_nvcsw`.
    var voluntary: Int
    /// `getrusage`: `ru_nivcsw`.
    var involuntary: Int
    /// `task_info(TASK_EVENTS_INFO)`: `csw`.
    var task: Int

    static func now() -> ContextSwitches
    static func - (later: ContextSwitches, earlier: ContextSwitches) -> ContextSwitches
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [QoS.userInitiated, .utility])
func threadRunsWithRequestedQoS(_ qos: QoS) {
    let observedQoS = Mutex<qos_class_t?>(nil)
    let ranOnMainThread = Mutex(true)

    let thread = BenchmarkThread.start(name: "qos-test", qos: qos) {
        observedQoS.withLock { $0 = qos_class_self() }
        ranOnMainThread.withLock { $0 = pthread_main_np() != 0 }
    }
    thread.join()

    #expect(observedQoS.withLock { $0 } == qos.qosClass)
    #expect(ranOnMainThread.withLock { $0 } == false)
}

@Test func threadLogStartsEmptyAndIsAligned() {
    let log = ThreadLog(batches: 3, readingsPerBatch: 5)

    #expect(log.cpuReadings(ofBatch: 0) == [-1, -1, -1, -1, -1])
    #expect(log.executorCPUReadings(ofBatch: 2) == nil)
    #expect(log.baseAddressForTesting % 128 == 0)

    log.recordCPU(batch: 1, reading: 4, cpu: 7)
    log.executorSlot(batch: 1, reading: 0).store(3)

    #expect(log.cpuReadings(ofBatch: 1)[4] == 7)
    #expect(log.executorCPUReadings(ofBatch: 1)?[0] == 3)
}
```

  Also:
  - `threadBarrierReleasesNobodyEarly`: 4 threads, 1,000 rounds. Each thread has its own `Atomic<Int>` slot. Before arriving, a thread stores the round number in its slot; after `arriveAndWait()` it checks that every slot holds at least this round. (A fast thread may already have stored the next round, so the check is "at least", not "equal".) Expect zero violations.
  - `taskBarrierWorksWithMoreTasksThanCores`: 12 tasks, 50 rounds, the same check, time limit one minute. Finishing proves there is no deadlock on the cooperative pool.
  - `clockNeverGoesBack`: 1,000 reads in a row never decrease; the timebase numerator and denominator are above 0.
  - `contextSwitchCountersOnlyGrow`: a later reading is at least the earlier one in every field.

- [ ] **Step 2: Run the tests.** Expected: the build fails.
- [ ] **Step 3: Implement** the types.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add clock, threads, barriers and thread logs"`

---

### Task 4: Conditions, phone facts, preflight

**Files:**
- Create: `Harness/Conditions.swift`, `Harness/PhoneFacts.swift`, `Harness/Preflight.swift`, `Harness/ThermalMonitor.swift`, `Tests/PreflightTests.swift`

**Interfaces:**

```swift
extension Conditions {
    /// Reads battery, screen brightness and application state from UIKit.
    @MainActor
    static func capture() -> Conditions

    /// Calls `capture()` on the main thread and waits. Never call it on the main thread.
    static func captureFromRunThread() -> Conditions

    static let watchedEnvironment = [
        "PTHREAD_MUTEX_DEFAULT_POLICY",
        "PTHREAD_MUTEX_USE_ULOCK",
        "PTHREAD_MUTEX_ADAPTIVE_SPIN",
        "LIBDISPATCH_COOPERATIVE_POOL_STRICT",
        "SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL",
    ]
}

/// `sysctl` with `KERN_PROC_PID`: is `P_TRACED` set?
func isDebuggerAttached() -> Bool

extension PhoneFacts {
    static func read() -> PhoneFacts
}

enum RefusalReason: String, Codable, Sendable {
    case configuration
    case debugger
    case thermal
    case lowPower
    case battery
    case applicationState
    case environment
}

enum PreflightDecision: Equatable, Sendable {
    case proceed
    case refuse(RefusalReason, detail: String)
}

enum Preflight {
    static func decide(
        _ conditions: Conditions,
        build: BuildInfo,
        request: RunRequest
    ) -> PreflightDecision
}

/// Records thermal state changes during a run.
final class ThermalMonitor: @unchecked Sendable {
    func start()
    func stop() -> [ThermalChange]
}
```

`PhoneFacts.read()` uses these `sysctl` names: `hw.machine`, `kern.osversion`, `hw.ncpu`, `hw.activecpu`, `hw.nperflevels`, `hw.perflevel<N>.name`, `.logicalcpu`, `.physicalcpu`, `.l1dcachesize`, `.l2cachesize`, `.cpusperl2`, `hw.cachelinesize`, `hw.memsize`, and, when readable, `kern.pthread_mutex_default_policy` and `kern.ulock_adaptive_spin_usecs`; plus `qos_class_main()` and `Clock.timebase`.

**Preflight rules.** In a smoke run the conditions never refuse. In other runs the checks go in this order; the first failure decides the reason, and the detail lists every failed condition:

| Condition | Reason |
|---|---|
| The build configuration is not Release | `configuration` |
| A debugger is attached | `debugger` |
| The thermal state is not nominal | `thermal` |
| Low Power Mode is on | `lowPower` |
| The battery is neither charging nor full | `battery` |
| The app is not active | `applicationState` |
| A watched environment variable is set | `environment` |

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: PreflightCase.all)
func preflightDecision(_ preflightCase: PreflightCase) {
    let decision = Preflight.decide(
        preflightCase.conditions,
        build: preflightCase.build,
        request: preflightCase.request
    )

    #expect(decision == preflightCase.expected)
}
```

  `PreflightCase.all`: each condition of the table alone, in a non-smoke run, gives its reason; all good gives `proceed`; a smoke run with every condition bad gives `proceed`; thermal `fair` with Low Power Mode on gives `thermal`, and the detail names both. Also `phoneFactsAreConsistent`: `cpuCount` is at least 1, the timebase is not zero, and the performance level indexes go 0, 1, ….

- [ ] **Step 2: Run the tests.** Expected: the build fails.
- [ ] **Step 3: Implement** the types.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add conditions, phone facts and preflight"`

---

### Task 5: State protections (the lock and queue wrappers)

**Files:**
- Create: `Mechanisms/MechanismID.swift`, `Mechanisms/StateProtection.swift`, one file per wrapper in the table below, `Tests/StateProtectionTests.swift`
- Modify: `Tests/TestSupport.swift`: add `makeIntegerProtection(_ mechanism: MechanismID, initialValue: Int) -> any StateProtection<Int>`

**Interfaces:**

```swift
enum MechanismID: String, CaseIterable, Codable, Sendable {
    case unsynchronized
    case mutex
    case osAllocatedUnfairLock
    case osAllocatedUnfairLockAdaptiveSpin
    case osUnfairLock
    case nsLock
    case nsRecursiveLock
    case pthreadMutex
    case pthreadReadWriteLock
    case serialQueue
    case barrierQueueSyncWrite
    case barrierQueueAsyncWrite
    case dispatchSemaphore
    case objcSync
    case actor
    case mainActor
    case atomic
    case atomicRelaxed
    case managedAtomic
    case managedAtomicRelaxed

    /// The 14 mechanisms that implement `StateProtection`.
    static var stateProtections: [MechanismID] { get }
}
```

```swift
/// A way to protect state for synchronous callers: a lock, a queue or a semaphore.
protocol StateProtection<State>: AnyObject, Sendable {
    associatedtype State: Sendable

    init(_ initialState: State)

    /// Runs `body` with exclusive access and returns its result.
    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result

    /// Runs `body` with read access. Readers share access in `pthread_rwlock` and the
    /// concurrent queue. The default implementation uses exclusive access.
    func withSharedAccess<Result: Sendable>(
        _ body: @Sendable (State) -> Result
    ) -> Result

    /// Changes the state. The change is done when the call returns, except in the
    /// async `.barrier` queue, which only submits it.
    func write<Argument: Sendable>(
        _ argument: Argument,
        using body: @escaping @Sendable (inout State, Argument) -> Void
    )

    /// Returns when every submitted write has run. The default does nothing.
    func waitForPendingWrites()

    /// Fills the slot with the CPU where queued writes run. The default does nothing.
    func recordExecutorCPU(into slot: CPUReadingSlot)
}
```

Callers pass the new value as `argument` and a closure that captures nothing. A closure without captures needs no allocated context, so `@escaping` costs nothing for the synchronous wrappers:

```swift
let protection = MutexProtection<Int>(0)

protection.write(1) { value, increment in
    value &+= increment
}

let current = protection.withSharedAccess { value in
    value
}
```

| Type | Mechanism ID | Exclusive access | Shared access | Writes |
|---|---|---|---|---|
| `NoProtection` | `unsynchronized` | calls `body` directly | default | default |
| `MutexProtection` | `mutex` | `Mutex.withLock` | default | default |
| `AllocatedUnfairLockProtection` | `osAllocatedUnfairLock` | `OSAllocatedUnfairLock.withLock` | default | default |
| `AdaptiveSpinUnfairLockProtection` | `osAllocatedUnfairLockAdaptiveSpin` | `withLock(flags: .adaptiveSpin)` | default | default |
| `UnfairLockProtection` | `osUnfairLock` | heap-allocated `os_unfair_lock` | default | default |
| `NSLockProtection` | `nsLock` | `lock()` / `unlock()` | default | default |
| `NSRecursiveLockProtection` | `nsRecursiveLock` | `lock()` / `unlock()` | default | default |
| `PthreadMutexProtection` | `pthreadMutex` | heap `pthread_mutex_t`, default attributes | default | default |
| `PthreadReadWriteLockProtection` | `pthreadReadWriteLock` | `pthread_rwlock_wrlock` | `pthread_rwlock_rdlock` | default |
| `SerialQueueProtection` | `serialQueue` | `queue.sync` | default | default |
| `BarrierQueueSyncWriteProtection` | `barrierQueueSyncWrite` | `queue.sync(flags: .barrier)` | `queue.sync` | default |
| `BarrierQueueAsyncWriteProtection` | `barrierQueueAsyncWrite` | `queue.sync(flags: .barrier)` | `queue.sync` | `queue.async(flags: .barrier)` |
| `SemaphoreProtection` | `dispatchSemaphore` | `wait()` / `signal()`, value 1 | default | default |
| `ObjcSyncProtection` | `objcSync` | `objc_sync_enter` / `objc_sync_exit` on a stored `NSObject` | default | default |

`BarrierQueueAsyncWriteProtection` also overrides `waitForPendingWrites()` with `queue.sync(flags: .barrier) {}` and `recordExecutorCPU(into:)` with an async barrier block that stores `CPU.current()` in the slot. All types are `final`; heap primitives are freed in `deinit`; return codes are checked with `assert` only, so Release code matches app code. Queue labels: `"SyncBench.serial"` and `"SyncBench.concurrent"`, with no QoS.

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: MechanismID.stateProtections)
func exclusiveAndSharedAccess(_ mechanism: MechanismID) {
    let protection = makeIntegerProtection(mechanism, initialValue: 5)

    let valueAfterIncrement = protection.withExclusiveAccess { value in
        value &+= 1
        return value
    }

    #expect(valueAfterIncrement == 6)
    #expect(protection.withSharedAccess { $0 } == 6)
}

@Test(arguments: MechanismID.stateProtections)
func writeIsVisibleAfterWaiting(_ mechanism: MechanismID) {
    let protection = makeIntegerProtection(mechanism, initialValue: 0)

    protection.write(41) { value, newValue in
        value = newValue
    }
    protection.waitForPendingWrites()

    #expect(protection.withSharedAccess { $0 } == 41)
}
```

  Also:
  - `eightThreadsCountExactly` (every mechanism except `unsynchronized`): 8 threads each add 1 ten thousand times through `write`; after `waitForPendingWrites()` the value is 80,000.
  - `readersOverlap` (`pthreadReadWriteLock` and both barrier queues): thread A, inside shared access, waits up to 2 s for a semaphore that thread B signals from inside its own shared access. Both get in.
  - `asyncBarrierKeepsOrder`: 1,000 writes of 0…999, then `recordExecutorCPU`, then `waitForPendingWrites()`: the value is 999 and the slot holds a CPU number of at least 0.

- [ ] **Step 2: Run the tests.** Expected: the build fails.
- [ ] **Step 3: Implement** the protocol, its default implementations and the 14 wrappers.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add lock and queue wrappers"`

---

### Task 6: Shared integers: locks, atomics, actor, main actor

**Files:**
- Create: `Mechanisms/SharedInteger.swift`, `Mechanisms/AtomicIntegers.swift`, `Mechanisms/ActorIntegers.swift`, `Mechanisms/SharedIntegers.swift`, `Tests/SharedIntegerTests.swift`

**Interfaces:**

```swift
/// One shared `Int`, as the base comparison uses it, for synchronous callers.
protocol SharedInteger: Sendable {
    func read() -> Int
    func write(_ value: Int)
    func increment()
    func waitForPendingWrites()
    func recordExecutorCPU(into slot: CPUReadingSlot)

    /// Waits for pending writes, then reads.
    func finalValue() -> Int
}

/// The same for callers that `await`: the actor and the main actor.
protocol AsyncSharedInteger: Sendable {
    func read() async -> Int
    func write(_ value: Int) async
    func increment() async

    /// The CPU number, read on the actor's executor.
    func executorCPU() async -> Int

    func finalValue() async -> Int
}

/// A shared integer behind any `StateProtection`: reads use shared access,
/// writes and increments use `write(_:using:)`.
struct ProtectedInteger<Protection: StateProtection>: SharedInteger
where Protection.State == Int {
    init(_ protection: Protection)
}

/// `Synchronization.Atomic<Int>` with the orderings a lock gives.
final class AtomicInteger: SharedInteger {
    init(_ initialValue: Int)
}

/// `Synchronization.Atomic<Int>` with `.relaxed` everywhere.
final class RelaxedAtomicInteger: SharedInteger {
    init(_ initialValue: Int)
}

/// `ManagedAtomic<Int>` from swift-atomics, with the orderings a lock gives.
struct ManagedAtomicInteger: SharedInteger {
    init(_ initialValue: Int)
}

/// `ManagedAtomic<Int>` from swift-atomics, with `.relaxed` everywhere.
struct RelaxedManagedAtomicInteger: SharedInteger {
    init(_ initialValue: Int)
}

actor ActorInteger: AsyncSharedInteger {
    init(_ initialValue: Int)
}

@MainActor
final class MainActorInteger: AsyncSharedInteger {
    init(_ initialValue: Int)
}
```

```swift
/// Receives the shared integer for a mechanism with its concrete type,
/// so every measured loop is specialized for that type.
protocol SharedIntegerVisitor {
    associatedtype Output

    func visitSynchronous<Integer: SharedInteger>(_ integer: Integer) -> Output
    func visitAsynchronous<Integer: AsyncSharedInteger>(_ integer: Integer) -> Output
}

enum SharedIntegers {
    /// One `switch` over all 20 mechanism IDs. For `mainActor` it creates the object
    /// on the main thread, as UIKit code does, so it must not run on the main thread.
    static func visit<Visitor: SharedIntegerVisitor>(
        _ mechanism: MechanismID,
        initialValue: Int,
        with visitor: Visitor
    ) -> Visitor.Output
}
```

Atomic orderings (Ivan, 2026-11-05):

| Operation | `AtomicInteger`, `ManagedAtomicInteger` | `RelaxedAtomicInteger`, `RelaxedManagedAtomicInteger` |
|---|---|---|
| read | `load(ordering: .acquiring)` | `load(ordering: .relaxed)` |
| write | `store(value, ordering: .releasing)` | `store(value, ordering: .relaxed)` |
| increment | `.acquiringAndReleasing` | `.relaxed` |

The increment is `wrappingAdd(1, ordering:)` on `Atomic` and `wrappingIncrement(ordering:)` on `ManagedAtomic`.

- [ ] **Step 1: Write the failing tests.** Each test visits every mechanism with a test visitor:
  - `writeReadIncrement`: start at 0; `write(7)`; `read()` returns 7; three `increment()` calls; `finalValue()` returns 10.
  - `concurrentIncrementsAreExact` (every mechanism except `unsynchronized`): synchronous integers get 4 threads × 5,000 increments and end at 20,000; async ones get 8 detached tasks × 1,000 and end at 8,000.
  - `executorCPUIsRead`: `ActorInteger` and `MainActorInteger` return a CPU number of at least 0.

  Run the main-actor cases through `onBenchmarkThread`, so the main thread stays free.

- [ ] **Step 2: Run the tests.** Expected: the build fails.
- [ ] **Step 3: Implement** the integers and `SharedIntegers.visit`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add shared integers for locks, atomics and actors"`

---

### Task 7: Block runner and run controller

**Files:**
- Create: `Harness/Experiment.swift`, `Harness/BlockContext.swift`, `Harness/BatchTimer.swift`, `Harness/ReferenceLoop.swift`, `Harness/RunController.swift`, `Tests/RunControllerTests.swift`, `Tests/TwoBlockTestExperiment.swift`
- Modify: `App/RunViewController.swift` (start a run)

**Interfaces:**

```swift
/// One block: one mechanism with one operation.
struct BlockDescription: Equatable, Sendable {
    let mechanism: String
    let operation: String
    let threads: Int
    let qos: QoS
    let operationsPerBatch: Int
}

/// How a block splits into batches.
struct BatchLayout: Equatable, Sendable {
    let warmupBatches: Int
    let measuredBatches: Int
    let operationsPerBatch: Int
    let subBatches: Int

    var totalBatches: Int { warmupBatches + measuredBatches }
    var operationsPerSubBatch: Int { operationsPerBatch / subBatches }
}

protocol Experiment: Sendable {
    init(request: RunRequest) throws(RequestError)

    /// In a fixed order; the run controller shuffles them with the seed.
    var blocks: [BlockDescription] { get }

    func run(_ block: BlockContext) -> [CheckResult]
}

enum ExperimentRegistry {
    /// Empty in this task: every ID throws. Task 8 adds `baseComparison`,
    /// Task 9 adds `calibration`.
    static func makeExperiment(for request: RunRequest) throws(RequestError) -> any Experiment
}
```

```swift
final class BlockContext: @unchecked Sendable {
    /// Position of the block in the run order.
    let position: Int
    let description: BlockDescription
    let layout: BatchLayout
    let request: RunRequest

    /// Runs `body` on `description.threads` pthreads with the block's QoS,
    /// then writes the `block` and `batch` lines.
    func runOnThreads(
        _ body: @escaping @Sendable (_ thread: Int, _ barrier: ThreadBarrier, _ log: ThreadLog) -> Void
    ) -> [ThreadLog]

    /// The same with detached tasks; this pthread waits until they finish.
    func runInTasks(
        _ body: @escaping @Sendable (_ task: Int, _ barrier: TaskBarrier, _ log: ThreadLog) async -> Void
    ) -> [ThreadLog]

    func appendSamples(_ line: SamplesLine)
}
```

`runOnThreads` and `runInTasks` do the bookkeeping around a block:
1. create one `ThreadLog` per thread (`totalBatches` batches, `subBatches + 1` readings) and one barrier;
2. read the clock, the context switches and the thermal state;
3. start the threads with the block's QoS (or detached tasks with its task priority) and wait for all of them;
4. read the clock, the context switches and the thermal state again;
5. append the `block` line, then the `batch` lines (a batch is warm-up when its index is below `warmupBatches`).

**The timing loop.** This is the only place where batches are timed. The async version has the same shape with `await`; it reads the executor CPU with `await integer.executorCPU()` and has nothing to wait for at the end.

```swift
enum BatchTimer {
    @inline(__always)
    static func timeBatches(
        layout: BatchLayout,
        barrier: ThreadBarrier,
        log: ThreadLog,
        recordExecutorCPU: (CPUReadingSlot) -> Void,
        waitForPendingWrites: () -> Void,
        runOperations: (_ batch: Int, _ subBatch: Int, _ count: Int) -> Int
    ) {
        // Every thread exists before the first batch starts.
        barrier.arriveAndWait()

        for batch in 0..<layout.totalBatches {
            // All threads start the batch together. Not timed.
            barrier.arriveAndWait()

            var checkValue = 0
            let start = Clock.now()

            for subBatch in 0..<layout.subBatches {
                log.recordCPU(batch: batch, reading: subBatch, cpu: CPU.current())
                recordExecutorCPU(log.executorSlot(batch: batch, reading: subBatch))
                checkValue &+= runOperations(batch, subBatch, layout.operationsPerSubBatch)
            }

            let lastReading = layout.subBatches
            log.recordCPU(batch: batch, reading: lastReading, cpu: CPU.current())
            recordExecutorCPU(log.executorSlot(batch: batch, reading: lastReading))

            // Async `.barrier` writes finish inside the timed part.
            waitForPendingWrites()

            let end = Clock.now()
            log.recordTimes(batch: batch, start: start, end: end)
            log.recordCheckValue(batch: batch, value: checkValue)
        }
    }
}
```

```swift
/// A fixed CPU loop for the start and end of every run: xorshift64
/// (x ^= x << 13; x ^= x >> 7; x ^= x << 17), starting from 0x9E3779B97F4A7C15.
@inline(never)
func referenceLoop(iterations: Int) -> UInt64

struct RunOutcome: Equatable, Sendable {
    let status: String
    let reasonCode: String?
    let marker: DoneMarker
}

/// Builds the experiment for a request. Tests pass their own.
typealias ExperimentFactory = (RunRequest) throws(RequestError) -> any Experiment

enum RunController {
    /// Runs one attempt to the end on the calling thread (never the main thread)
    /// and writes its files. Does not exit.
    static func runToCompletion(
        _ request: RunRequest,
        writingTo directory: URL,
        makeExperiment: ExperimentFactory = ExperimentRegistry.makeExperiment,
        captureConditions: () -> Conditions = Conditions.captureFromRunThread
    ) -> RunOutcome

    /// The app's entry: runs on a `userInitiated` thread, writes into
    /// `Documents/runs`, then calls `exit(0)`.
    static func launch(_ request: RunRequest, showStatus: @escaping @Sendable (String) -> Void)
}
```

`runToCompletion`, in order:
1. Read `BuildInfo.current()`, `PhoneFacts.read()` and the conditions; append the `run` line.
2. `request.validate()` and `makeExperiment`. On `RequestError`, append `end` (`failed`, `invalidRequest`, the message) and write the files.
3. `Preflight.decide`. On a refusal, append `end` (`refused`, the reason and detail, zero counts) and write the files.
4. Start the `ThermalMonitor`. Append the `reference` line for the start: run `referenceLoop(iterations:)` on this thread, read the CPU before and after, and pass the result to `blackHole`.
5. Run the blocks in the order `seededShuffle(experiment.blocks, seed: request.seed)`. Each block gets one `OSSignposter` interval (subsystem `"SyncBench"`, category `"block"`, name `block`, message `"<mechanism> <operation>"`). Collect the checks. After the first block: `simulation == .crash` calls `fatalError("simulated crash")`; `simulation == .hang` sleeps on this thread forever.
6. Append the `reference` line for the end. Read the conditions; stop the monitor.
7. Append `end`: `completed` when every check passed, otherwise `failed` with reason code `check` and the names of the failed checks; the line counts come from `lineCounts`.
8. Write the files with `ResultWriter` and return the outcome.

`launch` shows `"running <runID>"` once, before the first block. `RunViewController.viewDidAppear` decodes the request from `ProcessInfo.processInfo.arguments`. Without a request the app stays idle. If decoding fails, it shows the message and calls `exit(2)`. Otherwise it starts a `CADisplayLink`; on the second callback it stops the link and calls `RunController.launch`. Nothing runs during app launch.

- [ ] **Step 1: Write the failing tests** with `TwoBlockTestExperiment` (blocks `first` and `second`, one thread, `runOperations` returns its count):
  - `completedRunHasLinesInOrder`: line types in the order `run`, `reference`, `block`, 3 × `batch`, `block`, 3 × `batch`, `reference`, `end`; `end.status` is `completed`; `blockLines` is 2; the `.done` marker matches the file.
  - `blocksFollowTheSeededOrder`: with seeds 1 and 2, the `block` lines come in the order `seededShuffle(["first", "second"], seed:)` gives.
  - `refusalWritesOnlyRunAndEnd`: a non-smoke request with thermal state `serious`: two lines, status `refused`, reason code `thermal`.
  - `invalidRequestFails`: `makeExperiment` throws: status `failed`, reason code `invalidRequest`.
  - `failedCheckFailsTheRun`: the test experiment returns one failed check: status `failed`, reason code `check`.
  - `tasksWriteOneLogEach`: `runInTasks` with 3 tasks writes 3 × 3 `batch` lines for threads 0, 1 and 2.

  Run every case through `onBenchmarkThread` into a temporary directory.

- [ ] **Step 2: Run the tests.** Expected: the build fails.
- [ ] **Step 3: Implement** the types and the controller; wire up `RunViewController`.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add block runner and run controller"`

---

### Task 8: Base comparison

**Files:**
- Create: `Experiments/BaseComparison/BaseComparison.swift`, `Experiments/BaseComparison/BaseComparisonLoops.swift`, `Experiments/BaseComparison/BaseComparisonChecks.swift`, `Tests/BaseComparisonTests.swift`
- Modify: `Harness/Experiment.swift` (registry entry `baseComparison`)

**Interfaces:**

```swift
/// Experiment 1 in docs/experiments.md: threads read, write and increment one shared Int.
struct BaseComparison: Experiment {
    enum Operation: String, CaseIterable, Sendable {
        case read
        case write
        case increment
    }

    /// Number of threads for each variant. `oneThread` is part A of the spec,
    /// the others are part B.
    static let threadsByVariant = [
        "oneThread": 1,
        "twoThreads": 2,
        "sixThreads": 6,
        "twelveThreads": 12,
    ]

    /// Every read block starts with this value, and every read must return it.
    static let valueForReads = 42
}
```

```swift
/// The measured loops. Each one is a separate function, specialized for each
/// mechanism, so it can be found in the disassembly.
enum BaseComparisonLoops {
    /// Returns the sum of the values it read, for the read check.
    @inline(never)
    static func readLoop<Integer: SharedInteger>(
        _ integer: Integer,
        count: Int
    ) -> Int

    /// Writes firstValue, firstValue + 1, and so on.
    @inline(never)
    static func writeLoop<Integer: SharedInteger>(
        _ integer: Integer,
        count: Int,
        firstValue: Int
    )

    @inline(never)
    static func incrementLoop<Integer: SharedInteger>(
        _ integer: Integer,
        count: Int
    )

    // The same three for `AsyncSharedInteger`, as `async` functions:
    // readLoopAsync, writeLoopAsync, incrementLoopAsync.
}
```

```swift
enum BaseComparisonChecks {
    /// thread × 1_000_000_000_000 + operation + 1: every thread writes its own values.
    static func valueWritten(byThread thread: Int, operation: Int) -> Int

    /// "baseComparison.increment". Passes when finalValue == threads × operationsPerThread.
    static func checkIncrements(
        finalValue: Int,
        threads: Int,
        operationsPerThread: Int,
        block: Int
    ) -> CheckResult

    /// "baseComparison.write". Passes when finalValue is the last value of some thread:
    /// valueWritten(byThread: t, operation: operationsPerThread - 1).
    static func checkWrites(
        finalValue: Int,
        threads: Int,
        operationsPerThread: Int,
        block: Int
    ) -> CheckResult

    /// "baseComparison.read". Passes when finalValue == 42 and every batch sum equals
    /// 42 × operationsPerBatch. `violations` counts the batches with a wrong sum.
    static func checkReads(
        finalValue: Int,
        batchSums: [[Int]],
        operationsPerBatch: Int,
        block: Int
    ) -> CheckResult
}
```

**Validation in `init`** (each failure names its field): the variant is a key of `threadsByVariant`; `tunables.threads` matches it; `mechanisms` is not empty, has no duplicates and holds only `MechanismID` values; `unsynchronized` appears only with one thread; `operations` is not empty, has no duplicates and holds only `Operation` values. The blocks are every mechanism with every operation, mechanism by mechanism, each with `operationsPerBatch(for:)` of its mechanism.

**One block:**
1. Build the integer with `SharedIntegers.visit`: initial value 42 for reads, 0 otherwise.
2. A synchronous integer runs through `runOnThreads` and `BatchTimer.timeBatches`; an async one through `runInTasks` and `timeBatchesAsync`.
3. `runOperations` calls one loop. For writes, `firstValue` is `valueWritten(byThread: thread, operation: batch × operationsPerBatch + subBatch × count)`.
4. After the threads end, read `finalValue()` and return the check for the operation, with `operationsPerThread = totalBatches × operationsPerBatch`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func incrementCheck() {
    let correct = BaseComparisonChecks.checkIncrements(
        finalValue: 20,
        threads: 2,
        operationsPerThread: 10,
        block: 0
    )
    let lostIncrement = BaseComparisonChecks.checkIncrements(
        finalValue: 19,
        threads: 2,
        operationsPerThread: 10,
        block: 0
    )

    #expect(correct.passed)
    #expect(!lostIncrement.passed)
}

@Test func readCheckCountsBadBatches() {
    let result = BaseComparisonChecks.checkReads(
        finalValue: 42,
        batchSums: [[168, 168], [168, 167]],
        operationsPerBatch: 4,
        block: 0
    )

    #expect(!result.passed)
    #expect(result.violations == 1)
}
```

  Also:
  - `writeCheckAcceptsOnlyALastValue`: with 2 threads and 10 operations each, `valueWritten(byThread: 1, operation: 9)` passes and `valueWritten(byThread: 1, operation: 8)` fails.
  - `invalidRequests`: an unknown variant; `oneThread` with 2 threads; a duplicate mechanism; mechanism `spinlock`; `unsynchronized` in `twoThreads`; an empty or unknown operation. Each throws.
  - `smokeOneThread`: variant `oneThread`, all 20 mechanisms, all three operations; 1 warm-up and 2 measured batches, 4 sub-batches; operations per batch: default 4,000, `actor` 400, `mainActor` 80. Expect status `completed`, 60 block lines, 180 batch lines and every check passed.
  - `smokeTwoThreads`: the 19 mechanisms without `unsynchronized`, 2 threads. Expect `completed`, 57 block lines and 342 batch lines.

- [ ] **Step 2: Run the tests.** Expected: the build fails.
- [ ] **Step 3: Implement** the experiment, the loops, the checks and the registry entry.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add the base comparison experiment"`

---

### Task 9: Calibration

**Files:**
- Create: `Harness/Calibration.swift`, `Tests/CalibrationTests.swift`
- Modify: `Harness/Experiment.swift` (registry entry `calibration`)

`Calibration` is an `Experiment`. Request: experiment `calibration`, variant `default`, no mechanisms or operations, `tunables.repeats` of at least 1. It has four blocks; the block name goes into the `mechanism` field, `operation` is empty, and the blocks write only `samples` lines:

| Block | Threads and QoS | Samples |
|---|---|---|
| `clockSingleThread` | 1, `userInteractive` | `repeats` values: ticks for 1,000 `Clock.now()` calls in a row; metric `clockRead1000`, unit `ticks` |
| `clockAllCPUs` | `cpuCount`, `userInteractive`, released together | the same metric, one line per thread |
| `cpuSpeedUserInteractive` | `cpuCount`, `userInteractive` | `repeats` runs of `referenceLoop(iterations:)` per thread; metric `referenceLoop`, with `cpuAtStart` and `cpuAtEnd` |
| `cpuSpeedBackground` | `cpuCount`, `background` | the same |

The only check, `calibration.samples`, passes when every line has `repeats` values.

The design's calibration also measures the achieved display rate and the 8B work size. They come with the experiments that need them: the work size in plan 2, the display rate in plan 3.

- [ ] **Step 1: Write the failing test** `calibrationWritesAllSamples`: repeats 5, 1,000 iterations, smoke. Expect status `completed`, 4 block lines, `1 + 3 × cpuCount` samples lines, 5 values in each, and `cpuAtStart` and `cpuAtEnd` as long as `values` in the `referenceLoop` lines.
- [ ] **Step 2: Run it.** Expected: the build fails.
- [ ] **Step 3: Implement** `Calibration` and the registry entry.
- [ ] **Step 4: Run it.** Expected: pass.
- [ ] **Step 5: Commit**: `git commit -m "Add calibration"`

---

### Task 10: Mac script: config, plans, run state

**Files:**
- Create: `scripts/bench.py`, `scripts/runner/__init__.py`, `scripts/runner/config.py`, `scripts/runner/plans.py`, `scripts/runner/run_state.py`, `scripts/tests/__init__.py`, `scripts/tests/test_plans.py`, `scripts/tests/test_run_state.py`, `plans/smoke-base-comparison.json`, `plans/smoke-base-comparison-ios18.json`, `plans/crash-and-hang.json`, `plans/calibration.json`

**Interfaces:**

```python
# runner/config.py

REPOSITORY: Path  # the folder that holds scripts/


@dataclass(frozen=True)
class Phone:
    key: str
    udid: str
    model: str


@dataclass(frozen=True)
class LocalConfig:
    team_id: str
    bundle_id: str
    phones: Dict[str, Phone]


def load_local_config(path: Path) -> LocalConfig:
    """Read local.json. ConfigError names a missing key."""
```

```python
# runner/plans.py

@dataclass(frozen=True)
class PlannedRun:
    run_id: str
    experiment: str
    variant: str
    seed: int
    smoke: bool
    simulation: Optional[str]
    mechanisms: Tuple[str, ...]
    operations: Tuple[str, ...]
    tunables: Dict[str, Any]
    time_limit_seconds: int


@dataclass(frozen=True)
class Plan:
    name: str
    build_target: str            # "ios26" or "ios18"
    smoke: bool
    ios_build: Optional[str]     # None: any iOS build
    seed: int
    shuffle: bool
    settle_seconds: int
    pause_seconds: int
    thermal_wait_seconds: int
    max_thermal_retries: int
    max_attempts: int
    runs: Tuple[PlannedRun, ...]  # in the order they run
    sha256: str                  # of the plan file


def load_plan(path: Path) -> Plan:
    """Read and check a plan file. PlanError names the bad key."""


def make_run_id(plan_name: str, entry_name: str, repeat: int) -> str:
    """For example "smoke-base-comparison.one-thread.1"."""


def make_run_seed(plan_seed: int, run_id: str) -> int:
    """The first 13 hex digits of sha256(f"{plan_seed}:{run_id}"), so it stays below 2**53."""


def make_attempt_id(run_id: str, attempt: int, now: datetime, suffix: str) -> str:
    """For example "smoke-base-comparison.one-thread.1.attempt1.20261105T120000Z.3f9c"."""


def make_request(run: PlannedRun, attempt_id: str, attempt: int) -> Dict[str, Any]:
    """The request for the app (schema 1). Keys whose value is None are left out."""


def encode_request(request: Dict[str, Any]) -> str:
    """Base64 of the compact JSON with sorted keys."""
```

```python
# runner/run_state.py

def state_path(results: Path, plan: Plan, phone_key: str, code_hash: str) -> Path:
    """results/state/<plan name>--<phone key>--<plan hash>--<code hash>.json, with the
    first 8 hex digits of each hash. A build with other code starts a new state,
    so results of two builds never count toward one plan."""


class RunState:
    """Which runs of a plan are done on one phone. Saved after every attempt."""

    @classmethod
    def load_or_create(cls, path: Path, plan: Plan) -> RunState: ...

    def pending_runs(self) -> List[PlannedRun]:
        """Runs in plan order with no accepted attempt and fewer than
        max_attempts counted attempts. Thermal refusals are not counted."""

    def record_attempt(self, run_id: str, attempt: Dict[str, Any]) -> None: ...

    def attempts(self, run_id: str) -> List[Dict[str, Any]]: ...

    def save(self) -> None:
        """Writes a temporary file, then replaces the old one."""
```

**Plan files.** Keys: `schema` (1), `name`, `buildTarget`, `smoke`, `iosBuild` (null for any; required outside smoke plans, so one plan never mixes iOS builds), `seed`, `shuffle` (default true), `settleSeconds`, `pauseSeconds`, `thermalWaitSeconds` (default 300), `maxThermalRetries` (default 3), `maxAttempts` (default 3), and `runs`. Each run entry has `name` (unique in the plan), `experiment`, `variant`, `repeats`, `timeLimitSeconds`, `mechanisms`, `operations`, `tunables`, and in smoke plans an optional `simulation`. With `shuffle`, the runs are ordered by `random.Random(seed).shuffle`. For example, `plans/smoke-base-comparison.json`:

```json
{
  "schema": 1,
  "name": "smoke-base-comparison",
  "buildTarget": "ios26",
  "smoke": true,
  "iosBuild": null,
  "seed": 20261105,
  "settleSeconds": 10,
  "pauseSeconds": 2,
  "runs": [
    {
      "name": "one-thread",
      "experiment": "baseComparison",
      "variant": "oneThread",
      "repeats": 1,
      "timeLimitSeconds": 300,
      "mechanisms": [
        "unsynchronized",
        "mutex",
        "osAllocatedUnfairLock",
        "osAllocatedUnfairLockAdaptiveSpin",
        "osUnfairLock",
        "nsLock",
        "nsRecursiveLock",
        "pthreadMutex",
        "pthreadReadWriteLock",
        "serialQueue",
        "barrierQueueSyncWrite",
        "barrierQueueAsyncWrite",
        "dispatchSemaphore",
        "objcSync",
        "actor",
        "mainActor",
        "atomic",
        "atomicRelaxed",
        "managedAtomic",
        "managedAtomicRelaxed"
      ],
      "operations": ["read", "write", "increment"],
      "tunables": {
        "threads": 1,
        "qos": "userInitiated",
        "warmupBatches": 1,
        "measuredBatches": 2,
        "subBatches": 4,
        "operationsPerBatch": {
          "default": 10000,
          "actor": 2000,
          "mainActor": 400,
          "barrierQueueAsyncWrite": 2000
        },
        "referenceLoopIterations": 1000000
      }
    }
  ]
}
```

The other plans:
- `smoke-base-comparison.json` also has a second entry, `two-threads`: variant `twoThreads`, the same mechanisms without `unsynchronized`, `threads` 2.
- `smoke-base-comparison-ios18.json`: build target `ios18`, the same two entries with mechanisms `atomic`, `atomicRelaxed`, `managedAtomic`, `managedAtomicRelaxed` and `mutex`.
- `crash-and-hang.json`: `shuffle` false; two entries, `crash` and `hang`, each with variant `oneThread`, mechanism `mutex`, operation `increment`, `timeLimitSeconds` 60 and the matching `simulation`.
- `calibration.json`: one entry `calibration`, experiment `calibration`, variant `default`, no mechanisms or operations, `threads` 1, `qos` `userInteractive`, 0 warm-up and 1 measured batch, 1 sub-batch, `operationsPerBatch` `{"default": 1}`, 100,000 reference loop iterations, `repeats` 200, `timeLimitSeconds` 600.

- [ ] **Step 1: Write the failing tests**

```python
class PlanTests(unittest.TestCase):
    def test_run_id_and_seed(self):
        run_id = make_run_id("smoke-base-comparison", "one-thread", 1)

        self.assertEqual(run_id, "smoke-base-comparison.one-thread.1")
        self.assertEqual(make_run_seed(20261105, run_id), 184828474630059)

    def test_request_keys(self):
        plan = load_plan(SMOKE_PLAN)
        attempt_id = "smoke-base-comparison.one-thread.1.attempt1.20261105T000000Z.abcd"

        request = make_request(plan.runs[0], attempt_id, attempt=1)

        self.assertEqual(
            set(request),
            {
                "schema", "runID", "attemptID", "attempt", "experiment", "variant",
                "seed", "smoke", "mechanisms", "operations", "tunables",
            },
        )
```

  Also:
  - `test_smoke_plan_order_is_stable`: two loads of the smoke plan give the same run order, with 2 runs.
  - `test_unshuffled_plan_keeps_file_order`: `crash-and-hang.json` gives `crash`, then `hang`.
  - `test_invalid_plans_name_the_key`: a missing `buildTarget`, build target `ios17`, `repeats` 0, a duplicate entry name, `simulation` in a non-smoke plan, `iosBuild` null in a non-smoke plan.
  - `test_encode_request_round_trips`.
  - `test_pending_runs`: an accepted attempt makes a run done; three crashed attempts use up its attempts; three thermal refusals do not.
  - `test_state_survives_reload`.

- [ ] **Step 2: Run** `python3 -m unittest discover -s scripts/tests -t scripts`. Expected: import errors.
- [ ] **Step 3: Implement** the modules and the four plan files. `bench.py` gets `argparse` subcommands `doctor`, `build`, `calibrate`, `run`, `status` and `check`; until their task, each prints "not implemented" and exits with 2.
- [ ] **Step 4: Run the tests**, also with `/usr/bin/python3` (3.9.6). Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add plans and run state to the Mac script"`

---

### Task 11: Attempt check

**Files:**
- Create: `scripts/runner/expected_attempt.py`, `scripts/runner/attempt_check.py`, `scripts/tests/synthetic_attempts.py`, `scripts/tests/test_attempt_check.py`
- Modify: `scripts/bench.py` (`check <result file> --request <file> --build-id <id>`)

**Interfaces:**

```python
# runner/expected_attempt.py

@dataclass(frozen=True)
class ExpectedAttempt:
    """What a completed attempt must contain, derived from its request."""

    blocks: FrozenSet[Tuple[str, str]]     # (mechanism, operation); each appears exactly once
    threads: int
    warmup_batches: int
    measured_batches: int
    samples_lines: Optional[int]           # None: not checked
    operations_per_batch: Dict[str, int]   # by mechanism
    check_per_block: Optional[str]         # name prefix of the check each block must have
    run_checks: FrozenSet[str]             # checks that belong to the whole run


def expected_attempt(request: Dict[str, Any], cpu_count: int) -> ExpectedAttempt:
    """baseComparison: every requested mechanism with every requested operation;
    `threads` × (warmupBatches + measuredBatches) batch lines per block; each block
    has the check "baseComparison.<operation>"; no run checks.
    calibration: its four block names with operation ""; no batch lines;
    1 + 3 × cpu_count samples lines; one run check, "calibration.samples"."""
```

```python
# runner/attempt_check.py

@dataclass
class AttemptVerdict:
    status: str                  # completed, refused, failed, incomplete or invalid
    accepted: bool               # only a completed attempt can be accepted
    reason_code: Optional[str]
    reasons: List[str]


def check_attempt(
    result_file: Path,
    done_file: Optional[Path],
    request: Dict[str, Any],
    build_id: str,
) -> AttemptVerdict: ...
```

```python
# tests/synthetic_attempts.py (tests only)

def make_attempt_lines(
    request: Dict[str, Any],
    build_id: str,
    status: str = "completed",
    reason_code: Optional[str] = None,
    cpu_count: int = 6,
) -> List[Dict[str, Any]]: ...


def write_attempt(directory: Path, lines: List[Dict[str, Any]]) -> Tuple[Path, Path]:
    """Writes the result file and a matching .done file."""
```

**Rules, in order:**
1. No `.done` file: `incomplete`. A `.done` whose attempt ID, size or hash does not match the result file: `invalid`.
2. Every line is a JSON object of a known type; the first line is `run` and the last is `end`. Otherwise `invalid`.
3. The `run` line's `request` equals the launch request, and its build ID equals `build_id`. Otherwise `invalid`, and the reason names `request` or `build`.
4. An `end` status of `refused` gives `refused` with the reason code; `failed` gives `failed`.
5. The work matches `expected_attempt`. The `block` lines hold exactly the expected (mechanism, operation) pairs, each once. Every block has batch indices 0 … totalBatches − 1 for every thread 0 … threads − 1, each once, with the warm-up flag on the first `warmupBatches`. Each batch has its block's operation count. The samples lines and the counts in `end` match, and there are exactly two `reference` lines. Otherwise `invalid`.
6. The checks match `expected_attempt`: every block has one check with the expected name and its block position, the run checks are there, all of them passed, and every `violations` value is 0. A missing or failed check: `invalid`.
7. Non-smoke runs only: at start and at end, the thermal state is `nominal`, no debugger is attached, Low Power Mode is off, the battery is charging or full, the application is `active`, and `environment` is empty. Otherwise `invalid` (reason `conditions`).
8. Every block starts before it ends, and every batch lies inside its block.

- [ ] **Step 1: Write the failing tests.** Each broken file starts from the golden file or from `make_attempt_lines` with one change, and gets a fresh matching `.done` unless the test is about `.done`:
  - `test_golden_file_is_accepted`: `Tests/Fixtures/golden-base-comparison.jsonl` with the golden request and build ID from Task 2;
  - `test_missing_done_is_incomplete`;
  - `test_done_hash_mismatch_is_invalid`; `test_done_for_another_attempt_is_invalid`;
  - `test_other_build_id_is_invalid`; `test_changed_seed_is_invalid`;
  - `test_missing_measured_batch_is_invalid`; `test_duplicate_batch_is_invalid`; `test_wrong_operation_count_is_invalid`;
  - `test_substituted_block_is_invalid`: one requested block is replaced by a second copy of another block, with every count unchanged;
  - `test_missing_checks_are_invalid`: `end.checks` is empty;
  - `test_inconsistent_read_is_invalid` (a check with `violations` 1);
  - `test_thermal_refusal_is_classified` (status `refused`, reason code `thermal`, not accepted); `test_failed_run_is_classified`;
  - `test_missing_end_line_is_invalid` (`.done` present);
  - `test_bad_end_conditions_rejected_outside_smoke`: thermal state `fair` at the end, and, as a second case, application state `background` at the end;
  - `test_calibration_counts`.
- [ ] **Step 2: Run the tests.** Expected: import errors.
- [ ] **Step 3: Implement** the two modules, the test helpers and the `check` command.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add the attempt check"`

---

### Task 12: Build and doctor

**Files:**
- Create: `scripts/runner/processes.py`, `scripts/runner/device_control.py` (only `list_devices` and `is_unlocked` in this task), `scripts/runner/builds.py`, `scripts/runner/doctor.py`, `scripts/tests/test_builds.py`, `scripts/tests/test_doctor.py`, `scripts/tests/test_fixtures.py`, `scripts/tests/fixtures/devicectl/list-devices.json`, `lock-state-locked.json`, `lock-state-unlocked.json`, `scripts/tests/fixtures/profile.plist` (made up)
- Modify: `scripts/bench.py` (`build --target ios26|ios18 --phone <key>`, `doctor --phone <key> [--plan <file>]`)

**Interfaces:**

```python
# runner/processes.py

@dataclass
class ProcessResult:
    arguments: List[str]
    return_code: int
    stdout: str
    stderr: str


# A function that runs a command: (arguments, timeout in seconds) -> ProcessResult.
CommandRunner = Callable[[Sequence[str], Optional[float]], ProcessResult]


def run_command(arguments: Sequence[str], timeout_seconds: Optional[float] = None) -> ProcessResult: ...
```

```python
# runner/device_control.py

@dataclass(frozen=True)
class DeviceInfo:
    udid: str
    model: str
    os_version: str
    os_build: str
    developer_mode: bool
    available: bool


class DeviceControlError(Exception):
    """Names the devicectl command and the file that keeps its raw output."""


class DeviceControl:
    """Runs `xcrun devicectl` with --json-output and reads the result."""

    def __init__(self, run_command: CommandRunner, scratch_folder: Path): ...

    def list_devices(self) -> List[DeviceInfo]: ...

    def is_unlocked(self, udid: str) -> bool: ...
```

```python
# runner/builds.py

FROZEN_XCODE = ("27.1", "27A9275")
FROZEN_SWIFT = "swiftlang-6.4.0.34.1"
DEPLOYMENT_TARGETS = {"ios26": "26.0", "ios18": "18.0"}


def make_build_id(commit: str, dirty: bool, target: str, now: datetime) -> str:
    """For example "0123456789ab-clean-ios26-20261105T000000Z"."""


def xcodebuild_arguments(
    target: str,
    config: LocalConfig,
    phone: Phone,
    build_id: str,
    commit: str,
    dirty: bool,
    derived_data: Path,
) -> List[str]: ...


def code_hash(executable: Path, run_command: CommandRunner) -> str:
    """SHA-256 of a copy of the executable after `codesign --remove-signature`."""


def profile_expiry(app: Path, run_command: CommandRunner) -> datetime:
    """ExpirationDate from `security cms -D -i <app>/embedded.mobileprovision`."""


def build(
    target: str,
    config: LocalConfig,
    phone: Phone,
    results: Path,
    run_command: CommandRunner,
    now: datetime,
) -> Dict[str, Any]: ...


def latest_build(results: Path, target: str) -> Optional[Dict[str, Any]]: ...
```

```python
# runner/doctor.py

@dataclass
class DoctorFinding:
    name: str
    ok: bool
    detail: str


def doctor(
    config: LocalConfig,
    phone: Phone,
    plan: Optional[Plan],
    results: Path,
    run_command: CommandRunner,
    devices: DeviceControl,
    now: datetime,
) -> List[DoctorFinding]: ...
```

`xcodebuild_arguments` gives:

```text
xcodebuild -project SyncBench.xcodeproj -scheme SyncBench -configuration Release
  -destination id=<udid> -derivedDataPath build/<target>
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration
  DEVELOPMENT_TEAM=<team ID> PRODUCT_BUNDLE_IDENTIFIER=<bundle ID>
  IPHONEOS_DEPLOYMENT_TARGET=<26.0 or 18.0>
  BENCH_BUILD_ID=<build ID> BENCH_GIT_COMMIT=<commit> BENCH_GIT_DIRTY=<YES or NO>
  BENCH_BUILD_TARGET=<target>
  build
```

`build` reads the commit (`git rev-parse HEAD`) and whether the tree is dirty (`git status --porcelain`), runs `xcodegen generate` and `xcodebuild`, copies `SyncBench.app` to `results/builds/<build ID>/` and writes `build-info.json` there. That file has `buildID`, `commit`, `dirty`, `target`, `deploymentTarget`, `xcodeVersion`, `xcodeBuild`, `swiftVersion`, `sdkVersion`, `codeHash`, `profileExpires`, `app`, `builtAt`, and `settings`: `SWIFT_VERSION`, `SWIFT_OPTIMIZATION_LEVEL`, `SWIFT_COMPILATION_MODE`, `SWIFT_DEFAULT_ACTOR_ISOLATION`, `SWIFT_APPROACHABLE_CONCURRENCY`, `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT`, `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES`, `SWIFT_ENFORCE_EXCLUSIVE_ACCESS`, `IPHONEOS_DEPLOYMENT_TARGET`, `ARCHS` and `ENABLE_TESTABILITY` (from `xcodebuild -showBuildSettings -json` with the same arguments). It never writes the team ID or the bundle ID. It also writes `results/builds/latest-<target>.json` with the build ID and the app path.

`doctor` checks: the Xcode version and build; the `swiftc` version; `xcodegen` is installed; the phone is listed, available and in Developer Mode; its iOS build equals the plan's `iosBuild` when the plan sets one; the phone is unlocked; a build for the plan's target exists, and its profile is valid until now plus the time limits of the pending runs plus the settle time.

- [ ] **Step 1: Record the fixtures** with the phone connected: `xcrun devicectl list devices --json-output <file>`, and `xcrun devicectl device info lockState --device <udid> --json-output <file>`, once locked and once unlocked. Replace UDIDs, ECIDs, serial numbers, device names and every other identifier with placeholders.
- [ ] **Step 2: Write the failing tests**
  - `test_fixtures_have_no_identifiers`: no file under `scripts/tests/fixtures` holds a UDID-like value other than the placeholders, a real ECID or serial number, or the name "Ivan".
  - `test_build_id_format`: `make_build_id("0123456789abcdef", False, "ios26", datetime(2026, 11, 5, tzinfo=timezone.utc))` is `"0123456789ab-clean-ios26-20261105T000000Z"`.
  - `test_ios18_arguments`: deployment target 18.0 and every `BENCH_*` setting.
  - `test_build_info_has_no_personal_values` (fake command runner): neither the team ID nor the bundle ID appears in `build-info.json`.
  - `test_profile_expiry_is_read`; `test_code_hash_ignores_the_signature`.
  - `test_doctor_findings`: wrong Xcode, no `xcodegen`, Developer Mode off, phone locked, other iOS build, profile too short.
  - `test_devices_and_lock_state_are_read`.
- [ ] **Step 3: Run the tests.** Expected: failures.
- [ ] **Step 4: Implement** the modules and both commands.
- [ ] **Step 5: Run the tests.** Expected: all pass.
- [ ] **Step 6: Check on the phone**: `python3 scripts/bench.py doctor --phone <key>`, then `python3 scripts/bench.py build --target ios26 --phone <key>`. Expected: `build-info.json` is written; `profileExpires` is about 7 days ahead; `git status` shows nothing under `results/` or `build/`.
- [ ] **Step 7: Commit**: `git commit -m "Add build and doctor commands"`

---

### Task 13: Device control

**Files:**
- Modify: `scripts/runner/device_control.py`
- Create: `scripts/tests/test_device_control.py`; fixtures `install.json`, `launch.json`, `await-exited.json`, `await-timeout.txt` (the return code and output of a wait that timed out), `processes.json`, `terminate.json`, `copy-from.json`, `crash-logs.json`, `malformed.json`

**Interfaces** (new methods of `DeviceControl`):

```python
def install(self, udid: str, app: Path) -> None: ...

def launch(self, udid: str, bundle_id: str, app_arguments: List[str]) -> int:
    """Returns the process ID."""

def await_termination(self, udid: str, pid: int, timeout_seconds: int) -> Tuple[bool, Optional[int]]:
    """Returns (exited, exit code)."""

def running_pids(self, udid: str, bundle_id: str) -> List[int]: ...

def terminate(self, udid: str, pid: int) -> None: ...

def copy_from_app(self, udid: str, bundle_id: str, source: str, destination: Path) -> bool:
    """False when the file does not exist on the phone."""

def crash_logs(self, udid: str, name_contains: str) -> List[str]: ...

def copy_crash_log(self, udid: str, name: str, destination: Path) -> bool: ...
```

The commands, exactly; each also gets `--json-output <file in the scratch folder>`:

```text
xcrun devicectl device install app --device <udid> <app>

xcrun devicectl device process launch --device <udid> --terminate-existing \
    <bundle ID> -- <app arguments>

xcrun devicectl device process awaitTermination --device <udid> \
    --pid <pid> --timeout <seconds>

xcrun devicectl device info processes --device <udid>

xcrun devicectl device process terminate --device <udid> --pid <pid> --kill

xcrun devicectl device copy from --device <udid> \
    --domain-type appDataContainer --domain-identifier <bundle ID> \
    --source Documents/runs/<name> --destination <path>

xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs

xcrun devicectl device copy from --device <udid> \
    --domain-type systemCrashLogs \
    --source <name> --destination <path>
```

A command that fails, or that returns JSON without the expected fields, raises `DeviceControlError`.

- [ ] **Step 1: Record the fixtures** with the Task 12 build: install it; launch the first run of `plans/smoke-base-comparison.json` (request from `make_request` and `encode_request`); wait for it; copy its result file and `.done`; list the processes; launch without arguments and terminate; list the crash logs; wait on the idle app with `--timeout 1`. Scrub them as in Task 12. Check the copied file with `python3 scripts/bench.py check`: expected `completed` and accepted.
- [ ] **Step 2: Write the failing tests**: `test_launch_returns_pid_and_passes_arguments_after_double_dash`, `test_await_exited_and_timed_out`, `test_running_pids_filters_by_bundle`, `test_copy_of_missing_file_returns_false`, `test_crash_logs_filtered_by_name`, `test_malformed_json_raises_with_command_and_raw_file`, `test_commands_are_exact` (a fake command runner records the arguments).
- [ ] **Step 3: Run the tests.** Expected: failures.
- [ ] **Step 4: Implement** the methods.
- [ ] **Step 5: Run the tests.** Expected: all pass, including `test_fixtures_have_no_identifiers`.
- [ ] **Step 6: Commit**: `git commit -m "Add device control"`

---

### Task 14: Sessions: run, status, calibrate

**Files:**
- Create: `scripts/runner/sessions.py`, `scripts/runner/calibration.py`, `scripts/tests/fake_device.py`, `scripts/tests/test_sessions.py`, `scripts/tests/test_calibration.py`
- Modify: `scripts/bench.py` (`run`, `status`, `calibrate`)

**Interfaces:**

```python
# runner/sessions.py

@dataclass
class SessionSummary:
    session_id: str
    accepted: int
    rejected: int
    refused: int
    stop_reason: Optional[str]


def run_session(
    plan: Plan,
    phone: Phone,
    config: LocalConfig,
    results: Path,
    devices: DeviceControl,
    build_info: Dict[str, Any],
    sleep: Callable[[float], None] = time.sleep,
    now: Callable[[], datetime] = utc_now,
    log: Callable[[str], None] = print,
) -> SessionSummary: ...


def status_report(plan: Plan, phone_key: str, results: Path) -> str: ...
```

```python
# runner/calibration.py

def derive_core_map(calibration_file: Path) -> Dict[str, Any]:
    """{"performance": [...], "efficiency": [...], "medianTicksByCPU": {...}}"""
```

`run_session`, in order:
1. `doctor` must pass; otherwise stop and list the failed findings. The plan's build target must match `build_info`. Load the run state from `state_path(results, plan, phone.key, build_info["codeHash"])`.
2. Create `results/<phone key>/<session ID>/` (session ID: UTC time and plan name) with `session.json` and `session.log`. `session.json` holds the phone key, model and iOS build, the build ID and code hash, `dev` (true when the build came from a dirty tree), the plan name and hash, and the start time. Start `caffeinate -i -w <own process ID>`.
3. Install the build, then sleep for the settle time.
4. For each pending run, until it has an outcome:
   - give the attempt the next number and a new attempt ID;
   - if the phone is locked, stop the session (`phone locked`);
   - launch; on `DeviceControlError`, record `launchFailed` and stop the session;
   - wait for the app to exit, up to the run's time limit. If the wait itself fails, check `running_pids` every 30 s until the limit;
   - if the app still runs at the limit, terminate it. The status is `timeout`, and no later step changes it;
   - copy the result file and the `.done` file, one at a time (a timed-out attempt usually has neither);
   - if the app exited by itself and left no `.done` file: status `crashed`; copy the crash logs that name `SyncBench` and are newer than the launch into `crash/<attempt ID>/`;
   - if there is a `.done` file: run `check_attempt` and save the verdict as `<attempt ID>.check.json`;
   - record the attempt in the run state and save it; append one line to `session.log`: time, run ID, attempt ID, status, accepted, reasons;
   - a thermal refusal: below `max_thermal_retries`, sleep for `thermal_wait_seconds` and try again; otherwise stop the session (`thermal`);
   - any other refusal stops the session (`refused: <reason code>`);
   - three attempts in a row that are neither accepted nor refused stop the session (`3 failures in a row`);
   - otherwise sleep for the pause and go to the next run.
5. Write the end time and the summary into `session.json`.

`calibrate --phone <key>` runs `plans/calibration.json` through `run_session`, then `derive_core_map` on the accepted file. It keeps only the samples whose `cpuAtStart` equals `cpuAtEnd`, takes the median ticks for each CPU, and calls the fastest `logicalCPUCount` CPUs of performance level 0 `performance`. It writes `results/<phone key>/calibration.json`: the core map, the attempt ID it came from, and the phone facts from the `run` line.

- [ ] **Step 1: Write the failing tests.** `FakeDevice` plays one scripted result per launch (`complete`, `refuse-thermal`, `refuse-battery`, `crash`, `hang`, `locked`) and writes result files with `make_attempt_lines` for the request it receives.
  - `test_all_runs_accepted_and_logged`;
  - `test_thermal_refusal_retries_with_a_new_attempt_id` (sleep is called with the thermal wait; both attempts are kept);
  - `test_thermal_retries_used_up_stop_the_session`;
  - `test_other_refusal_stops_the_session` (`refused: battery`);
  - `test_crash_copies_crash_logs_and_continues`;
  - `test_hang_is_terminated_as_timeout` (terminate gets that process ID);
  - `test_locked_phone_stops_and_next_session_resumes` (the second session starts at the next pending run);
  - `test_new_code_hash_starts_a_new_state`: runs accepted with one code hash are run again by a session whose build has another code hash;
  - `test_launch_failure_stops_the_session`;
  - `test_three_failures_in_a_row_stop_the_session`;
  - `test_status_report_counts`;
  - `test_core_map_from_synthetic_calibration`: CPUs 0–3 take about twice the ticks of CPUs 4–5, and performance level 0 has 2 CPUs, so `performance` is `[4, 5]`.
- [ ] **Step 2: Run the tests.** Expected: failures.
- [ ] **Step 3: Implement** the session loop and the three commands.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit**: `git commit -m "Add run, status and calibrate commands"`

---

### Task 15: Acceptance on one iPhone

**Files:**
- Create: `docs/build-checks/2026-11-phase-1.md`, `docs/phase-1-acceptance.md`
- Modify: `README.md` (how to use `doctor`, `build`, `calibrate`, `run`, `status` and `check`; the phone preparation list from the design's run protocol)

Ivan prepares the phone (see Prerequisites). Never print the values from `local.json`.

- [ ] **Step 1: Base comparison, iOS 26 build.** Run `python3 scripts/bench.py build --target ios26 --phone <key>`, then `python3 scripts/bench.py run --phone <key> --plan plans/smoke-base-comparison.json`. Expected: both runs accepted.
- [ ] **Step 2: Crash and hang.** Run `python3 scripts/bench.py run --phone <key> --plan plans/crash-and-hang.json`. Expected: `crash` is marked `crashed` and its crash log is copied; `hang` is marked `timeout` and the app is terminated; both attempts keep their files.
- [ ] **Step 3: Calibration.** Run `python3 scripts/bench.py calibrate --phone <key>`. Expected: the core map is written, and the number of performance CPUs equals `hw.perflevel0.logicalcpu`.
- [ ] **Step 4: iOS 18 build.** Run `build --target ios18`, then `run --plan plans/smoke-base-comparison-ios18.json`. Expected: both runs accepted; the `run` lines show `minimumOS` 18.0.
- [ ] **Step 5: Disassembly, by hand, for both builds.** List the measured loops, then disassemble the ones to read:

```bash
APP=results/builds/<build ID>/SyncBench.app/SyncBench
xcrun nm "$APP" | grep BaseComparisonLoops | xcrun swift-demangle
xcrun llvm-objdump --no-show-raw-insn --disassemble-symbols='<mangled name>' "$APP"
```

  Write into `docs/build-checks/2026-11-phase-1.md`:
  - whether all 60 loops of the iOS 26 build exist as separate symbols;
  - whether the `mutex` loops call `os_unfair_lock_lock` and `os_unfair_lock_unlock` directly;
  - whether the lock loops call `swift_allocObject`, `swift_retain` or `swift_release`;
  - which instructions the atomic increments use: expected `ldaddal` (lock-like rows) and `ldadd` (relaxed rows) in the iOS 26 build, and `ldaxr` / `stlxr` and `ldxr` / `stxr` loops in the iOS 18 build;
  - what the compiler did with the `unsynchronized` loops, and which wrappers call `swift_beginAccess`.

  If something is unexpected, stop and report.
- [ ] **Step 6: Hash stability.** Build `ios26` again from the same commit. Expected: the same `codeHash`. If it differs, write down both builds and stop for a decision.
- [ ] **Step 7: Write `docs/phase-1-acceptance.md`**: the phone model and iOS build, the session IDs and their results, what the runs taught us (for example, the clock-read cost, or how `devicectl` reports the process ID), and what plans 2 and 3 must take into account.
- [ ] **Step 8: Commit**: `git commit -m "Record phase 1 acceptance on device"`
