import Foundation

/// Which host build is running (T-145): read from the app bundle's Info.plist, which `scripts/bundle-host.sh`
/// fills with the build time (`CFBundleVersion`) and the git commit (`MBGitCommit`).
///
/// A `swift run` binary has no bundle Info.plist, so every field is then `unknown`; that never fails.
public struct BuildInfo: Sendable, Equatable {
    public static let unknown = "unknown"
    public static let versionKey = "CFBundleShortVersionString"
    public static let buildKey = "CFBundleVersion"
    public static let shaKey = "MBGitCommit"

    /// Marketing version, e.g. `0.1`.
    public let version: String
    /// Build number (`YYYYMMDDhhmmss` from the bundle script).
    public let build: String
    /// Short git commit, `-dirty` suffixed for an unclean tree.
    public let sha: String

    public init(version: String, build: String, sha: String) {
        self.version = Self.clean(version)
        self.build = Self.clean(build)
        self.sha = Self.clean(sha)
    }

    /// `Bundle.main.infoDictionary` in the app. A missing key, a non-string value, an empty string or a template
    /// placeholder the bundle script did not fill (`__BUILD__`) becomes `unknown`.
    public init(infoDictionary: [String: Any]?) {
        let dict = infoDictionary ?? [:]
        self.init(version: dict[Self.versionKey] as? String ?? "",
                  build: dict[Self.buildKey] as? String ?? "",
                  sha: dict[Self.shaKey] as? String ?? "")
    }

    /// The `ev=app_start` fields: `version=… build=… sha=… os=…`. Whitespace inside a value becomes `_` so every
    /// field stays one `key=value` token (`ProcessInfo.operatingSystemVersionString` contains spaces).
    public func logFields(os: String) -> String {
        "version=\(Self.token(version)) build=\(Self.token(build)) sha=\(Self.token(sha)) os=\(Self.token(os))"
    }

    /// The disabled menu line: `Sürüm 0.1 (<sha>, <build>)`.
    public var menuTitle: String { "Sürüm \(version) (\(sha), \(build))" }

    private static func clean(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return unknown }
        if trimmed.count > 4, trimmed.hasPrefix("__"), trimmed.hasSuffix("__") { return unknown }
        return trimmed
    }

    private static func token(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return unknown }
        return String(trimmed.map { $0.isWhitespace || $0 == "=" ? "_" : $0 })
    }
}
