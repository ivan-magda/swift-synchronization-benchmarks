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
        func value(_ key: String) -> String? {
            guard let text = bundle.object(forInfoDictionaryKey: key) as? String,
                !text.isEmpty, !text.hasPrefix("$(")
            else { return nil }
            return text
        }
        let minimumOS = value("MinimumOSVersion") ?? "unknown"
        #if DEBUG
            let configuration = "Debug"
        #else
            let configuration = "Release"
        #endif
        return BuildInfo(
            buildID: value("BenchBuildID") ?? "unknown",
            commit: value("BenchGitCommit") ?? "unknown",
            dirty: ["1", "true", "YES"].contains(value("BenchGitDirty") ?? ""),
            target: value("BenchBuildTarget") ?? (minimumOS.hasPrefix("18.") ? "ios18" : "ios26"),
            minimumOS: minimumOS,
            configuration: configuration
        )
    }
}
