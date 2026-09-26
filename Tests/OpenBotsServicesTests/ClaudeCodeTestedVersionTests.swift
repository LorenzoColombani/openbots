import Foundation
@testable import OpenBotsServices
import Testing

/// Claude Code updates itself under the app, and each version can change how it talks to
/// it. Settings says when the installed one is newer than the last one tested.
@Suite("Settings says when Claude Code is newer than the version OpenBots was last tested with")
struct ClaudeCodeTestedVersionTests {
    @Test("The last tested version is the newest captured wire among the test fixtures")
    func lastTestedIsTheNewestFixture() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenBotsRuntimeTests/Fixtures")
        let versions = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { $0.hasPrefix("claude-cli-") }.map { String($0.dropFirst("claude-cli-".count)) }
        // Every fixture folder is named by a version, or the order below would be meaningless.
        #expect(versions.allSatisfy { ClaudeCodeTestedVersion.isNewer($0, than: "0.0") }, "\(versions)")
        let newest = try #require(versions.max { ClaudeCodeTestedVersion.isNewer($1, than: $0) })
        #expect(ClaudeCodeTestedVersion.lastTested == newest)
    }

    @Test("Versions compare by their numbers, not as text")
    func versionsCompareByNumber() {
        #expect(ClaudeCodeTestedVersion.isNewer("2.1.283", than: "2.1.282"))
        #expect(ClaudeCodeTestedVersion.isNewer("2.1.1000", than: "2.1.282"))
        #expect(ClaudeCodeTestedVersion.isNewer("2.2.0", than: "2.1.282"))
        #expect(!ClaudeCodeTestedVersion.isNewer("2.1.282", than: "2.1.282"))
        #expect(!ClaudeCodeTestedVersion.isNewer("2.1.99", than: "2.1.282"))
        #expect(!ClaudeCodeTestedVersion.isNewer("latest", than: "2.1.282"))
    }

    @Test("The installed version is read from where the claude link points, nothing is run")
    func installedVersionIsReadFromTheLink() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("obversion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin"), versions = home.appendingPathComponent(".local/share/claude/versions")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        #expect(ClaudeCodeTestedVersion.installedVersion(home: home) == nil)
        try Data().write(to: versions.appendingPathComponent("2.1.290"))
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("claude").path,
                                                   withDestinationPath: versions.appendingPathComponent("2.1.290").path)
        #expect(ClaudeCodeTestedVersion.installedVersion(home: home) == "2.1.290")
        // A link to a link, relative: followed to the version it names.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("claude"))
        try FileManager.default.createSymbolicLink(atPath: versions.appendingPathComponent("current").path,
                                                   withDestinationPath: "2.1.290")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("claude").path,
                                                   withDestinationPath: "../share/claude/versions/current")
        #expect(ClaudeCodeTestedVersion.installedVersion(home: home) == "2.1.290")
    }

    @Test("The warning names both versions in plain words, and says nothing when the installed one was tested")
    func theWarningIsPlain() throws {
        let warning = try #require(ClaudeCodeTestedVersion.warning(installed: "2.1.290", lastTested: "2.1.282"))
        #expect(warning.contains("2.1.290") && warning.contains("2.1.282"), "\(warning)")
        #expect(ClaudeCodeTestedVersion.warning(installed: "2.1.282", lastTested: "2.1.282") == nil)
        #expect(ClaudeCodeTestedVersion.warning(installed: nil, lastTested: "2.1.282") == nil)
    }
}
