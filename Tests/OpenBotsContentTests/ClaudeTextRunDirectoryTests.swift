import Darwin
import Foundation
@testable import OpenBotsContent
import XCTest

final class ClaudeTextRunDirectoryTests: XCTestCase {
    func testCreatesFreshEmptyPrivateWorkingAndTemporaryDirectories() throws {
        let fixture = try TextRunDirectoryFixture()
        let runID = UUID()
        let result = try fixture.create(runID)
        XCTAssertEqual(result.workingDirectory, fixture.turns.appending(path: "\(runID.uuidString)/Work.noindex", directoryHint: .isDirectory))
        XCTAssertEqual(result.temporaryDirectory, fixture.turns.appending(path: "\(runID.uuidString)/Temp.noindex", directoryHint: .isDirectory))
        for directory in [fixture.turns, result.workingDirectory.deletingLastPathComponent(), result.workingDirectory, result.temporaryDirectory] {
            let metadata = try fixture.metadata(directory)
            XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
            XCTAssertEqual(metadata.st_mode & 0o7777, 0o700)
            XCTAssertEqual(metadata.st_uid, geteuid())
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: result.workingDirectory.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: result.temporaryDirectory.path).isEmpty)
        let second = try fixture.create(UUID())
        XCTAssertNotEqual(second, result)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: second.workingDirectory.path).isEmpty)
    }

    func testRepeatedRunIDNeverOverwritesPriorWorkingFilesOrDirectories() throws {
        let fixture = try TextRunDirectoryFixture()
        let id = UUID(), result = try fixture.create(id)
        let preserved = result.workingDirectory.appending(path: "preserved.txt")
        let bytes = Data("preexisting completed item".utf8)
        try bytes.write(to: preserved, options: .withoutOverwriting)
        let workBefore = try fixture.metadata(result.workingDirectory)
        let fileBefore = try fixture.metadata(preserved)
        XCTAssertThrowsError(try fixture.create(id)) { XCTAssertEqual($0 as? ClaudeTextRunDirectoryError, .collision) }
        XCTAssertEqual(try fixture.metadata(result.workingDirectory).st_ino, workBefore.st_ino)
        XCTAssertEqual(try fixture.metadata(preserved).st_ino, fileBefore.st_ino)
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
    }

    func testExistingSymlinkOrRegularFileAtRunIDIsNeverFollowedOrReplaced() throws {
        for symlink in [false, true] {
            let fixture = try TextRunDirectoryFixture(createTurns: true)
            let id = UUID()
            let destination = fixture.turns.appending(path: id.uuidString)
            let preserved = fixture.container.home.appending(path: "unrelated.txt")
            let bytes = Data("untouched unrelated item".utf8)
            try bytes.write(to: preserved)
            if symlink {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: preserved)
            } else {
                try bytes.write(to: destination)
            }
            let before = try fixture.metadata(destination)
            XCTAssertThrowsError(try fixture.create(id)) { XCTAssertEqual($0 as? ClaudeTextRunDirectoryError, .collision) }
            XCTAssertEqual(try fixture.metadata(destination).st_ino, before.st_ino)
            XCTAssertEqual(try fixture.metadata(destination).st_mode, before.st_mode)
            XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        }
    }

    func testSymlinkAtProtectedParentIsRejectedWithoutFollowingIt() throws {
        for location in TextRunDirectoryFixture.Location.allCases {
            let fixture = try TextRunDirectoryFixture(createTurns: true)
            let path = fixture.url(location), original = path.appendingPathExtension("preserved")
            try FileManager.default.moveItem(at: path, to: original)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
            let before = try fixture.metadata(path)
            XCTAssertThrowsError(try fixture.create(UUID()), "\(location)")
            XCTAssertEqual(try fixture.metadata(path).st_ino, before.st_ino)
            XCTAssertEqual(try fixture.metadata(path).st_mode & S_IFMT, S_IFLNK)
        }
    }

    func testUnsafeProtectedPermissionsAndMissingParentAreRejectedWithoutRepair() throws {
        for location in TextRunDirectoryFixture.Location.allCases {
            let fixture = try TextRunDirectoryFixture(createTurns: true)
            let path = fixture.url(location)
            try fixture.setMode(0o755, at: path)
            XCTAssertThrowsError(try fixture.create(UUID()), "\(location)")
            XCTAssertEqual(try fixture.metadata(path).st_mode & 0o7777, 0o755)
        }
        let missing = try TextRunDirectoryFixture()
        try FileManager.default.removeItem(at: missing.claude)
        XCTAssertThrowsError(try missing.create(UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.claude.path))
    }

    func testMismatchedVerifiedRootCannotCreateTextTurnDirectories() throws {
        let fixture = try TextRunDirectoryFixture(), other = try ContentTemporaryFixture()
        XCTAssertThrowsError(try ClaudeTextRunDirectoryStore().create(runID: UUID(),
            applicationSupportRoot: fixture.root, layout: other.layout)) {
            XCTAssertEqual($0 as? ClaudeTextRunDirectoryError, .rootMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.turns.path))
    }

    func testOpaqueFakeCLIProfileIsNotReadRepairedOrChanged() throws {
        let fixture = try TextRunDirectoryFixture()
        // Synthetic test-only profile. No real Claude path or credential is used.
        let profile = fixture.container.layout.claudeCLIProfileRoot
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        let opaque = profile.appending(path: "opaque-fixture")
        let bytes = Data("synthetic profile sentinel".utf8)
        try bytes.write(to: opaque)
        try fixture.setMode(0, at: opaque)
        try fixture.setMode(0, at: profile)
        defer {
            try? fixture.setMode(0o700, at: profile)
            try? fixture.setMode(0o600, at: opaque)
        }
        let before = try fixture.metadata(profile)
        let result = try fixture.create(UUID())
        let after = try fixture.metadata(profile)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mode, before.st_mode)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        XCTAssertEqual(after.st_atimespec.tv_sec, before.st_atimespec.tv_sec)
        XCTAssertEqual(after.st_atimespec.tv_nsec, before.st_atimespec.tv_nsec)
        XCTAssertFalse(result.workingDirectory.path.hasPrefix(profile.path + "/"))
        XCTAssertFalse(result.temporaryDirectory.path.hasPrefix(profile.path + "/"))
        try fixture.setMode(0o700, at: profile)
        XCTAssertEqual(try fixture.metadata(opaque).st_mode & 0o7777, 0)
        try fixture.setMode(0o600, at: opaque)
        XCTAssertEqual(try Data(contentsOf: opaque), bytes)
    }
}

private final class TextRunDirectoryFixture {
    enum Location: CaseIterable {
        case applicationSupport, highChurn, runtime, claude, turns
    }
    let container: ContentTemporaryFixture
    let root: VerifiedOwnedRoot
    var claude: URL { container.layout.runtimeRoot.appending(path: "Claude", directoryHint: .isDirectory) }
    var turns: URL { claude.appending(path: "TextTurns", directoryHint: .isDirectory) }

    init(createTurns: Bool = false) throws {
        container = try ContentTemporaryFixture()
        let installationID = UUID(), rootID = UUID()
        try container.materializeOwnedRoot(container.layout.applicationSupportRoot, installationID: installationID, rootID: rootID)
        root = try OwnedRootVerifier().verify(container.layout.applicationSupportRoot,
            expectedInstallationID: installationID, expectedRootID: rootID)
        for location in [Location.highChurn, .runtime, .claude] + (createTurns ? [.turns] : []) {
            try FileManager.default.createDirectory(at: url(location), withIntermediateDirectories: false)
            try setMode(0o700, at: url(location))
        }
    }
    func create(_ runID: UUID) throws -> ClaudeTextRunDirectories {
        try ClaudeTextRunDirectoryStore().create(runID: runID, applicationSupportRoot: root, layout: container.layout)
    }
    func url(_ location: Location) -> URL {
        switch location {
        case .applicationSupport: container.layout.applicationSupportRoot.url
        case .highChurn: container.layout.highChurnRoot
        case .runtime: container.layout.runtimeRoot
        case .claude: claude
        case .turns: turns
        }
    }
    func setMode(_ mode: mode_t, at url: URL) throws {
        guard chmod(url.path, mode) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return value
    }
}
