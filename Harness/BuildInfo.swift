import Foundation

/// Metadata embedded by the build script before signing.
struct BuildInfo: Codable, Equatable, Sendable {
    /// "unknown" for an Xcode build made without the script.
    var buildID: String
    var commit: String
    var dirty: Bool
    var target: String
    var minimumOS: String
    var configuration: String

    static func current(bundle: Bundle = .main) -> BuildInfo {
        let minimumOS = value(forKey: "MinimumOSVersion", in: bundle) ?? "unknown"
        let defaultTarget = minimumOS.hasPrefix("18.") ? "ios18" : "ios26"
        let dirtyValue = value(forKey: "BenchGitDirty", in: bundle) ?? ""
        let isDirty = ["1", "true", "YES"].contains(dirtyValue)
        #if DEBUG
            let configuration = "Debug"
        #else
            let configuration = "Release"
        #endif
        return BuildInfo(
            buildID: value(forKey: "BenchBuildID", in: bundle) ?? "unknown",
            commit: value(forKey: "BenchGitCommit", in: bundle) ?? "unknown",
            dirty: isDirty,
            target: value(forKey: "BenchBuildTarget", in: bundle) ?? defaultTarget,
            minimumOS: minimumOS,
            configuration: configuration
        )
    }

    private static func value(forKey key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty,
            !value.hasPrefix("$(")
        else {
            return nil
        }
        return value
    }
}
