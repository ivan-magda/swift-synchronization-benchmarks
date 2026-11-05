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
    ) -> PreflightDecision {
        guard !request.smoke else {
            return .proceed
        }

        var failures: [(reason: RefusalReason, detail: String)] = []
        if build.configuration != "Release" {
            failures.append(
                (.configuration, "configuration=\(build.configuration) (requires Release)")
            )
        }
        if conditions.debuggerAttached {
            failures.append((.debugger, "debuggerAttached=true"))
        }
        if conditions.thermalState != "nominal" {
            failures.append((.thermal, "thermalState=\(conditions.thermalState)"))
        }
        if conditions.lowPowerMode {
            failures.append((.lowPower, "lowPowerMode=true"))
        }
        if conditions.batteryState != "charging" && conditions.batteryState != "full" {
            failures.append((.battery, "batteryState=\(conditions.batteryState)"))
        }
        if conditions.applicationState != "active" {
            failures.append((.applicationState, "applicationState=\(conditions.applicationState)"))
        }
        for name in Conditions.watchedEnvironment where conditions.environment[name] != nil {
            failures.append((.environment, "environment=\(name)"))
        }

        guard let first = failures.first else {
            return .proceed
        }

        return .refuse(first.reason, detail: failures.map(\.detail).joined(separator: "; "))
    }
}
