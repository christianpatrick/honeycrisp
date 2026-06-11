import Foundation

/// Build metadata shared by the CLI and the menu bar app.
public enum HoneycrispInfo {
    /// The compiled fallback version. The git tag is the source of truth:
    /// the packaging script stamps it into the bundle's Info.plist and
    /// `version` prefers that at runtime. This constant only surfaces for a
    /// bare `swift run`, where there is no bundle to read.
    public static let fallbackVersion = "0.3.0"

    /// A bundle's CFBundleShortVersionString when present and non-empty,
    /// else the compiled fallback. Pure so the fallback rule is testable
    /// without depending on the test runner's own bundle.
    public static func resolveVersion(bundleShortVersion: String?) -> String {
        if let bundleShortVersion, !bundleShortVersion.isEmpty { return bundleShortVersion }
        return fallbackVersion
    }

    /// The version shown in the panel, Settings, the CLI, and MCP serverInfo.
    /// In the packaged app (and the bundled CLI inside it, whose Bundle.main
    /// resolves to the app) this is the Info.plist value stamped from the git
    /// tag; otherwise the fallback.
    public static var version: String {
        resolveVersion(
            bundleShortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }
}
