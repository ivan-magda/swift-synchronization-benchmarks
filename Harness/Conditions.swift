import Darwin
import Foundation
import UIKit

extension Conditions {
    static let watchedEnvironment = [
        "PTHREAD_MUTEX_DEFAULT_POLICY",
        "PTHREAD_MUTEX_USE_ULOCK",
        "PTHREAD_MUTEX_ADAPTIVE_SPIN",
        "LIBDISPATCH_COOPERATIVE_POOL_STRICT",
        "SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL",
    ]

    /// Reads UIKit state on the main actor, outside measured blocks.
    @MainActor
    static func capture() -> Conditions {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let application = UIApplication.shared
        let scenes = application.connectedScenes.compactMap { $0 as? UIWindowScene }
        let screen = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?
            .screen

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let process = ProcessInfo.processInfo
        let environment = process.environment.filter { watchedEnvironment.contains($0.key) }
        let batteryLevel = device.batteryLevel

        return Conditions(
            thermalState: process.thermalState.resultName,
            lowPowerMode: process.isLowPowerModeEnabled,
            batteryState: device.batteryState.resultName,
            batteryLevelPermille: batteryLevel < 0 ? -1 : Int((batteryLevel * 1000).rounded()),
            screenBrightnessPermille: Int(((screen?.brightness ?? 0) * 1000).rounded()),
            debuggerAttached: isDebuggerAttached(),
            applicationState: application.applicationState.resultName,
            environment: environment,
            ticks: Clock.now(),
            wallClock: formatter.string(from: Date())
        )
    }

    /// Calls `capture()` on the main thread and waits. Never call it on the main thread.
    static func captureFromRunThread() -> Conditions {
        precondition(pthread_main_np() == 0)

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { capture() }
        }
    }
}

/// Queries this process rather than relying on launch arguments or environment variables.
func isDebuggerAttached() -> Bool {
    var information = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let result = sysctl(&query, u_int(query.count), &information, &size, nil, 0)

    // A failed query cannot establish that measurement conditions are debugger-free.
    guard result == 0, size == MemoryLayout<kinfo_proc>.size else {
        return true
    }

    return information.kp_proc.p_flag & P_TRACED != 0
}

extension ProcessInfo.ThermalState {
    var resultName: String {
        switch self {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }
}

extension UIDevice.BatteryState {
    fileprivate var resultName: String {
        switch self {
        case .unknown:
            "unknown"
        case .unplugged:
            "unplugged"
        case .charging:
            "charging"
        case .full:
            "full"
        @unknown default:
            "unknown"
        }
    }
}

extension UIApplication.State {
    fileprivate var resultName: String {
        switch self {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
    }
}
