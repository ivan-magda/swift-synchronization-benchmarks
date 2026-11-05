import Foundation
import Testing

@testable import SyncBench

// Catches an omitted check, a reordered refusal, or a smoke run refused by preflight.
@Test(arguments: PreflightCase.all)
func preflightDecision(_ preflightCase: PreflightCase) {
    #expect(
        Preflight.decide(
            preflightCase.conditions,
            build: preflightCase.build,
            request: preflightCase.request
        ) == preflightCase.expected
    )
}

// Catches a failed numeric sysctl being accepted as zero, or skipped level indexes.
@Test func phoneFactsAreConsistent() {
    let facts = PhoneFacts.read()

    #expect(facts.cpuCount >= 1)
    #expect(facts.timebaseNumerator > 0)
    #expect(facts.timebaseDenominator > 0)
    #expect(facts.performanceLevels.map(\.index) == Array(0..<facts.performanceLevels.count))
}

// Catches a missing main-thread bridge or an incorrectly scaled UIKit snapshot.
@Test func conditionsCaptureFromRunThread() async throws {
    let conditions = await onBenchmarkThread { Conditions.captureFromRunThread() }

    #expect(conditions.ticks > 0)
    #expect((-1...1000).contains(conditions.batteryLevelPermille))
    #expect((0...1000).contains(conditions.screenBrightnessPermille))
    #expect(["active", "inactive", "background"].contains(conditions.applicationState))

    let formatter = ISO8601DateFormatter()
    #expect(formatter.date(from: conditions.wallClock) != nil)
    #expect(conditions.wallClock.hasSuffix("Z"))
    #expect(!conditions.wallClock.contains("."))
}

// Catches duplicate observers, a retained observer after stop, or stale changes on restart.
@Test func thermalMonitorRecordsOnlyWhileStarted() {
    let monitor = ThermalMonitor()
    let center = NotificationCenter.default

    center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    monitor.start()
    monitor.start()

    let before = Clock.now()
    center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    let changes = monitor.stop()

    #expect(changes.count == 1)
    #expect(changes.allSatisfy { $0.ticks >= before && $0.ticks <= Clock.now() })
    #expect(
        changes.allSatisfy { ["nominal", "fair", "serious", "critical"].contains($0.thermalState) }
    )

    center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    #expect(monitor.stop().count == 1)

    monitor.start()
    #expect(monitor.stop().isEmpty)
}

struct PreflightCase: Sendable {
    let conditions: Conditions
    let build: BuildInfo
    let request: RunRequest
    let expected: PreflightDecision

    init(
        thermalState: String = "nominal",
        lowPowerMode: Bool = false,
        batteryState: String = "charging",
        debuggerAttached: Bool = false,
        applicationState: String = "active",
        environment: [String: String] = [:],
        configuration: String = "Release",
        smoke: Bool = false,
        expected: PreflightDecision
    ) {
        conditions = Conditions(
            thermalState: thermalState,
            lowPowerMode: lowPowerMode,
            batteryState: batteryState,
            batteryLevelPermille: 800,
            screenBrightnessPermille: 500,
            debuggerAttached: debuggerAttached,
            applicationState: applicationState,
            environment: environment,
            ticks: 1,
            wallClock: "2026-11-05T00:00:00Z"
        )
        build = BuildInfo(
            buildID: "test",
            commit: "test",
            dirty: false,
            target: "ios26",
            minimumOS: "26.0",
            configuration: configuration
        )

        var request = RunRequest.golden
        request.smoke = smoke
        self.request = request
        self.expected = expected
    }

    static let all: [PreflightCase] = [
        PreflightCase(expected: .proceed),
        PreflightCase(batteryState: "full", expected: .proceed),
        PreflightCase(
            configuration: "Debug",
            expected: .refuse(.configuration, detail: "configuration=Debug (requires Release)")
        ),
        PreflightCase(
            debuggerAttached: true,
            expected: .refuse(.debugger, detail: "debuggerAttached=true")
        ),
        PreflightCase(
            thermalState: "fair",
            expected: .refuse(.thermal, detail: "thermalState=fair")
        ),
        PreflightCase(
            lowPowerMode: true,
            expected: .refuse(.lowPower, detail: "lowPowerMode=true")
        ),
        PreflightCase(
            batteryState: "unplugged",
            expected: .refuse(.battery, detail: "batteryState=unplugged")
        ),
        PreflightCase(
            batteryState: "unknown",
            expected: .refuse(.battery, detail: "batteryState=unknown")
        ),
        PreflightCase(
            applicationState: "inactive",
            expected: .refuse(.applicationState, detail: "applicationState=inactive")
        ),
        PreflightCase(
            applicationState: "background",
            expected: .refuse(.applicationState, detail: "applicationState=background")
        ),
        PreflightCase(
            environment: ["PTHREAD_MUTEX_DEFAULT_POLICY": ""],
            expected: .refuse(.environment, detail: "environment=PTHREAD_MUTEX_DEFAULT_POLICY")
        ),
        PreflightCase(
            environment: ["PTHREAD_MUTEX_USE_ULOCK": "1"],
            expected: .refuse(.environment, detail: "environment=PTHREAD_MUTEX_USE_ULOCK")
        ),
        PreflightCase(
            environment: ["PTHREAD_MUTEX_ADAPTIVE_SPIN": "1"],
            expected: .refuse(.environment, detail: "environment=PTHREAD_MUTEX_ADAPTIVE_SPIN")
        ),
        PreflightCase(
            environment: ["LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"],
            expected: .refuse(
                .environment,
                detail: "environment=LIBDISPATCH_COOPERATIVE_POOL_STRICT"
            )
        ),
        PreflightCase(
            environment: ["SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL": "1"],
            expected: .refuse(
                .environment,
                detail: "environment=SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL"
            )
        ),
        PreflightCase(
            thermalState: "fair",
            lowPowerMode: true,
            expected: .refuse(.thermal, detail: "thermalState=fair; lowPowerMode=true")
        ),
        PreflightCase(
            thermalState: "critical",
            lowPowerMode: true,
            batteryState: "unplugged",
            debuggerAttached: true,
            applicationState: "background",
            environment: ["PTHREAD_MUTEX_USE_ULOCK": "1"],
            configuration: "Debug",
            expected: .refuse(
                .configuration,
                detail:
                    "configuration=Debug (requires Release); debuggerAttached=true; thermalState=critical; lowPowerMode=true; batteryState=unplugged; applicationState=background; environment=PTHREAD_MUTEX_USE_ULOCK"
            )
        ),
        PreflightCase(
            thermalState: "critical",
            lowPowerMode: true,
            batteryState: "unplugged",
            debuggerAttached: true,
            applicationState: "background",
            environment: ["PTHREAD_MUTEX_USE_ULOCK": "1"], configuration: "Debug", smoke: true,
            expected: .proceed),
    ]
}
