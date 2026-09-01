import Darwin
import Foundation
import XCTest
@testable import OpenBotsContent

final class ClaudeSignInCommandFileTests: XCTestCase {
    func testCreatesOneCompletePrivateExecutableWithoutOpeningCLIProfile() throws {
        let fixture = try SignInCommandFixture()
        let profile = fixture.container.layout.claudeCLIProfileRoot
        // Deliberately opaque sibling: the command store must neither follow nor inspect it.
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: fixture.container.home)
        let script = "#!/bin/sh\n# Fixture only — α\nprintf '%s\\n' 'not a real login'\n"
        let file = try fixture.create(script: script)

        XCTAssertEqual(file.deletingLastPathComponent(), fixture.handoffs)
        XCTAssertEqual(file.pathExtension, "command")
        XCTAssertNotNil(UUID(uuidString: file.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: file), Data(script.utf8))
        let value = try fixture.metadata(file)
        XCTAssertEqual(value.st_mode & S_IFMT, mode_t(S_IFREG))
        XCTAssertEqual(value.st_mode & 0o7777, 0o700)
        XCTAssertEqual(value.st_uid, geteuid())
        XCTAssertEqual(value.st_nlink, 1)
        XCTAssertEqual(try fixture.metadata(fixture.handoffs).st_mode & 0o7777, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.handoffs.path), [file.lastPathComponent])
        XCTAssertEqual(try fixture.metadata(profile).st_mode & S_IFMT, mode_t(S_IFLNK))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.claude.path).sorted(), ["CLIProfile", "SignInHandoffs"])
    }

    func testRepeatedCreationPreservesExistingCommandAndUnrelatedEntries() throws {
        let fixture = try SignInCommandFixture(createHandoffs: true)
        let unrelated = fixture.handoffs.appending(path: "do-not-touch")
        try Data("existing opaque item".utf8).write(to: unrelated)
        try fixture.setMode(0o000, at: unrelated)
        let first = try fixture.create(script: "#!/bin/sh\n# first\n")
        let before = try fixture.metadata(first)
        let second = try fixture.create(script: "#!/bin/sh\n# second\n")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "#!/bin/sh\n# first\n")
        XCTAssertEqual(try fixture.metadata(first).st_ino, before.st_ino)
        XCTAssertEqual(try fixture.metadata(unrelated).st_mode & 0o7777, 0)
    }

    func testRejectsEmptyNULAndOversizedUTF8BeforeFilesystemMutation() throws {
        for script in ["", "#!/bin/sh\0invalid", String(repeating: "x", count: 32_769), String(repeating: "α", count: 16_385)] {
            let fixture = try SignInCommandFixture()
            fixture.assertFailure(.invalidScript, script: script)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffs.path))
        }
        let fixture = try SignInCommandFixture()
        let atLimit = String(repeating: "x", count: ClaudeSignInCommandFileStore.maximumScriptBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.create(script: atLimit)).count, 32_768)
    }

    func testWrongLayoutAndRootKindRejectWithoutWriting() throws {
        let fixture = try SignInCommandFixture()
        let other = try ContentTemporaryFixture()
        XCTAssertThrowsError(try ClaudeSignInCommandFileStore().create(
            script: SignInCommandFixture.script, applicationSupportRoot: fixture.root, layout: other.layout
        )) { XCTAssertEqual($0 as? ClaudeSignInCommandFileError, .rootMismatch) }
        let installationID = UUID()
        let rootID = UUID()
        try fixture.container.materializeOwnedRoot(
            fixture.container.layout.cacheRoot, installationID: installationID, rootID: rootID
        )
        let cache = try OwnedRootVerifier().verify(
            fixture.container.layout.cacheRoot, expectedInstallationID: installationID, expectedRootID: rootID
        )
        XCTAssertThrowsError(try ClaudeSignInCommandFileStore().create(
            script: SignInCommandFixture.script, applicationSupportRoot: cache, layout: fixture.container.layout
        )) { XCTAssertEqual($0 as? ClaudeSignInCommandFileError, .rootMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffs.path))
    }

    func testMissingProtectedAncestorsAndMarkerAreNeverCreated() throws {
        for location in SignInCommandFixture.Location.allCases where location != .handoffs {
            let fixture = try SignInCommandFixture()
            let url = fixture.url(location)
            try FileManager.default.removeItem(at: url)
            fixture.assertFailure(.missingParent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(location)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffs.path))
        }
    }

    func testSymlinkAtEveryProtectedAncestorOrMarkerIsRejected() throws {
        for location in SignInCommandFixture.Location.allCases {
            let fixture = try SignInCommandFixture(createHandoffs: true)
            let url = fixture.url(location)
            let original = url.appendingPathExtension("original")
            try FileManager.default.moveItem(at: url, to: original)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
            fixture.assertFailure(.rejected(.symbolicLink))
        }
    }

    func testSymlinkInNonownedAncestorIsAlsoRejected() throws {
        let fixture = try SignInCommandFixture()
        let home = fixture.container.home
        let original = home.appendingPathExtension("original")
        try FileManager.default.moveItem(at: home, to: original)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: original)
        fixture.assertFailure(.rejected(.symbolicLink))
    }

    func testNonDirectoriesAndUnsafePermissionsAreRejectedWithoutRepair() throws {
        for location in SignInCommandFixture.Location.allCases {
            let fixture = try SignInCommandFixture(createHandoffs: true)
            let url = fixture.url(location)
            let mode: mode_t = location == .marker ? 0o644 : 0o755
            try fixture.setMode(mode, at: url)
            fixture.assertFailure(.rejected(.unsafePermissions))
            XCTAssertEqual(try fixture.metadata(url).st_mode & 0o7777, mode)
        }
        for location in SignInCommandFixture.Location.allCases where location != .marker {
            let fixture = try SignInCommandFixture(createHandoffs: true)
            let url = fixture.url(location)
            try FileManager.default.removeItem(at: url)
            try Data("not a directory".utf8).write(to: url)
            try fixture.setMode(0o700, at: url)
            fixture.assertFailure(.rejected(.wrongFileType))
        }
        let fixture = try SignInCommandFixture()
        try fixture.setMode(0o1700, at: fixture.claude)
        fixture.assertFailure(.rejected(.unsafePermissions))
    }

    func testRootMarkerMustBePrivateSingleLinkBoundedRegularFile() throws {
        let fifoFixture = try SignInCommandFixture()
        try FileManager.default.removeItem(at: fifoFixture.marker)
        XCTAssertEqual(mkfifo(fifoFixture.marker.path, 0o600), 0)
        fifoFixture.assertFailure(.rejected(.wrongFileType))

        let linkedFixture = try SignInCommandFixture()
        XCTAssertEqual(link(linkedFixture.marker.path, linkedFixture.container.home.appending(path: "marker-link").path), 0)
        linkedFixture.assertFailure(.rejected(.unexpectedHardLinks))

        let oversizedFixture = try SignInCommandFixture()
        try Data(repeating: 0x20, count: ClaudeProfileInspector.maximumMarkerBytes + 1).write(to: oversizedFixture.marker)
        oversizedFixture.assertFailure(.rejected(.markerTooLarge))
    }

    func testEveryRootMarkerIdentityFieldIsRevalidated() throws {
        let changes: [(String, Any)] = [
            ("formatVersion", 2), ("bundleIdentifier", "com.example.other"), ("kind", "caches"),
            ("installationID", UUID().uuidString), ("rootID", UUID().uuidString)
        ]
        for (field, value) in changes {
            let fixture = try SignInCommandFixture()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.marker)) as? [String: Any])
            object[field] = value
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.marker)
            fixture.assertFailure(.rootMismatch)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.handoffs.path), field)
        }
    }

    func testExistingRegularSymlinkHardlinkOrDirectoryFilenameNeverOverwritten() throws {
        for kind in 0..<4 {
            let fixture = try SignInCommandFixture(createHandoffs: true)
            let identifier = UUID()
            let destination = fixture.command(identifier)
            let original = fixture.container.home.appending(path: "preserved")
            let payload = Data("preserve existing content".utf8)
            try payload.write(to: original)
            switch kind {
            case 0: try payload.write(to: destination)
            case 1: try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: original)
            case 2: XCTAssertEqual(link(original.path, destination.path), 0)
            default: try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            let before = try fixture.metadata(destination)
            fixture.assertFailure(.collision, using: ClaudeSignInCommandFileStore(identifier: identifier))
            XCTAssertEqual(try fixture.metadata(destination).st_ino, before.st_ino)
            XCTAssertEqual(try Data(contentsOf: original), payload)
            if kind == 0 { XCTAssertEqual(try Data(contentsOf: destination), payload) }
        }
    }

    func testReplacingAnyProtectedPathDuringWriteRejectsPublication() throws {
        for location in SignInCommandFixture.Location.allCases {
            let fixture = try SignInCommandFixture()
            let identifier = UUID()
            let store = ClaudeSignInCommandFileStore(identifier: identifier, beforePublication: {
                let url = fixture.url(location)
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("previous"))
                if location == .marker {
                    try Data("{}".utf8).write(to: url)
                    try fixture.setMode(0o600, at: url)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    try fixture.setMode(0o700, at: url)
                }
            })
            fixture.assertFailure(.rejected(.changedIdentity), using: store)
        }
    }

    func testCommandReplacementHardlinkAndInPlaceMutationRejectPublication() throws {
        for mutation in 0..<3 {
            let fixture = try SignInCommandFixture()
            let identifier = UUID()
            let store = ClaudeSignInCommandFileStore(identifier: identifier, beforePublication: {
                let file = fixture.command(identifier)
                switch mutation {
                case 0:
                    try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("previous"))
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.marker)
                case 1:
                    guard link(file.path, fixture.handoffs.appending(path: "extra-link").path) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                default:
                    let fd = open(file.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                    defer { close(fd) }
                    guard ftruncate(fd, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
                }
            })
            fixture.assertFailure(.rejected(.changedIdentity), using: store)
            if mutation != 0 {
                XCTAssertEqual(try fixture.metadata(fixture.command(identifier)).st_mode & 0o7777, 0o600)
            }
        }
    }

    func testMarkerInPlaceMutationRejectsPublicationAndLeavesCommandNonexecutable() throws {
        let fixture = try SignInCommandFixture()
        let identifier = UUID()
        let store = ClaudeSignInCommandFileStore(identifier: identifier, beforePublication: {
            let fd = open(fixture.marker.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            guard ftruncate(fd, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        })
        fixture.assertFailure(.rejected(.changedIdentity), using: store)
        XCTAssertEqual(try fixture.metadata(fixture.command(identifier)).st_mode & 0o7777, 0o600)
    }
}

private final class SignInCommandFixture: @unchecked Sendable {
    enum Location: CaseIterable, Sendable {
        case applicationSupport, marker, highChurn, runtime, claude, handoffs
    }

    static let script = "#!/bin/sh\n# Nonexecuted fixture only.\n"
    let container: ContentTemporaryFixture
    let root: VerifiedOwnedRoot
    var marker: URL { container.layout.applicationSupportRoot.ownershipMarkerURL }
    var claude: URL { container.layout.runtimeRoot.appending(path: "Claude", directoryHint: .isDirectory) }
    var handoffs: URL { claude.appending(path: "SignInHandoffs", directoryHint: .isDirectory) }

    init(createHandoffs: Bool = false) throws {
        container = try ContentTemporaryFixture()
        let installationID = UUID()
        let rootID = UUID()
        try container.materializeOwnedRoot(
            container.layout.applicationSupportRoot, installationID: installationID, rootID: rootID
        )
        root = try OwnedRootVerifier().verify(
            container.layout.applicationSupportRoot, expectedInstallationID: installationID, expectedRootID: rootID
        )
        for location in [Location.highChurn, .runtime, .claude] + (createHandoffs ? [.handoffs] : []) {
            try FileManager.default.createDirectory(at: url(location), withIntermediateDirectories: false)
            try setMode(0o700, at: url(location))
        }
    }

    func create(
        script: String = SignInCommandFixture.script,
        using store: ClaudeSignInCommandFileStore = ClaudeSignInCommandFileStore()
    ) throws -> URL {
        try store.create(script: script, applicationSupportRoot: root, layout: container.layout)
    }

    func assertFailure(
        _ expected: ClaudeSignInCommandFileError,
        script: String = SignInCommandFixture.script,
        using store: ClaudeSignInCommandFileStore = ClaudeSignInCommandFileStore(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try create(script: script, using: store), file: file, line: line) {
            XCTAssertEqual($0 as? ClaudeSignInCommandFileError, expected, file: file, line: line)
        }
    }

    func command(_ identifier: UUID) -> URL { handoffs.appending(path: "\(identifier.uuidString).command") }

    func url(_ location: Location) -> URL {
        switch location {
        case .applicationSupport: container.layout.applicationSupportRoot.url
        case .marker: marker
        case .highChurn: container.layout.highChurnRoot
        case .runtime: container.layout.runtimeRoot
        case .claude: claude
        case .handoffs: handoffs
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
