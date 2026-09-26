import Foundation

/// Claude Code updates itself under the app: the binary at `~/.local/bin/claude`
/// is shared with interactive Claude Code, and each version can change how it
/// talks to OpenBots. Settings says when the installed
/// one is newer than the last one the app was tested with. Opening Settings stays inert: the version is
/// read from where the link points, and nothing is run.
public enum ClaudeCodeTestedVersion {
    /// The newest Claude Code whose wire the tests replay. A test holds this
    /// equal to the newest `Tests/OpenBotsRuntimeTests/Fixtures/claude-cli-<version>`
    /// folder, so capturing a new version is what moves it.
    public static let lastTested = "2.1.282"

    /// Whether `version` is a later dotted number than `other`. Anything that
    /// is not a plain dotted version is never newer.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        guard let a = numbers(version), let b = numbers(other) else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The version `~/.local/bin/claude` points at: the native installer links
    /// it to `~/.local/share/claude/versions/<version>`. Nil when there is no
    /// link, or its target is not named by a version.
    public static func installedVersion(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        // A link to a link is followed, relative targets from the link's own
        // folder, up to eight hops.
        var link = home.appendingPathComponent(".local/bin/claude")
        var target: URL?
        for _ in 0..<8 {
            guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { break }
            let resolved = next.hasPrefix("/") ? URL(fileURLWithPath: next)
                : link.deletingLastPathComponent().appendingPathComponent(next).standardizedFileURL
            target = resolved
            link = resolved
        }
        guard let name = target?.lastPathComponent else { return nil }
        return numbers(name) == nil ? nil : name
    }

    /// What Settings says, or nil when there is nothing to say.
    public static func warning(installed: String?, lastTested: String = lastTested) -> String? {
        guard let installed, isNewer(installed, than: lastTested) else { return nil }
        return "Claude Code \(installed) is newer than \(lastTested), the last version OpenBots was tested with. "
            + "If replies start failing, this update is the likely reason."
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 4 else { return nil }
        let values = parts.map { part in part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) ? Int(part) : nil }
        return values.contains(nil) ? nil : values.compactMap { $0 }
    }
}
