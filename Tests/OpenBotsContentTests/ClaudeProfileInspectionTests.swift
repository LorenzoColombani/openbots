import Darwin
import Foundation
import XCTest
@testable import OpenBotsContent

final class ClaudeProfileInspectionTests: XCTestCase {
    func testValidProfileLeavesOpaqueClaudeStateAndBackupsUntouched() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        let opaque = fixture.profile.appending(path: ".credentials.json")
        let backup = fixture.backups.appending(path: "opaque-auth-state")
        let payload = Data("fixture only: must remain opaque to the inspector".utf8)
        try payload.write(to: opaque)
        try payload.write(to: backup)
        try fixture.setMode(0o000, at: opaque)
        try fixture.setMode(0o000, at: backup)
        let fifo = fixture.profile.appending(path: "settings.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(
            at: fixture.backups.appending(path: "unknown-state"),
            withDestinationURL: fixture.container.home.appending(path: ".claude")
        )
        let before = try fixture.metadata(fixture.marker)
        let profileBefore = try fixture.metadata(fixture.profile)

        XCTAssertEqual(fixture.inspect(), .metadataVerified)
        let after = try fixture.metadata(fixture.marker)
        let profileAfter = try fixture.metadata(fixture.profile)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(profileBefore.st_mtimespec.tv_sec, profileAfter.st_mtimespec.tv_sec)
        XCTAssertEqual(profileBefore.st_mtimespec.tv_nsec, profileAfter.st_mtimespec.tv_nsec)
        XCTAssertEqual(try fixture.metadata(opaque).st_mode & 0o7777, 0)
        XCTAssertEqual(try fixture.metadata(backup).st_mode & 0o7777, 0)
        try fixture.setMode(0o600, at: opaque)
        try fixture.setMode(0o600, at: backup)
        XCTAssertEqual(try Data(contentsOf: opaque), payload)
        XCTAssertEqual(try Data(contentsOf: backup), payload)
    }

    func testMissingProfileIsReportedWithoutBootstrap() throws {
        let fixture = try ClaudeProfileInspectionFixture(createProfile: false)
        XCTAssertEqual(fixture.inspect(), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.container.layout.highChurnRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profile.path))
    }

    func testMissingRequiredEntryIsReportedWithoutRepair() throws {
        for missing in ["backups", ClaudeProfileInspector.markerFilename] {
            let fixture = try ClaudeProfileInspectionFixture()
            let url = fixture.profile.appending(path: missing)
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(fixture.inspect(), .missing, missing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testMismatchedLayoutOrOwnedRootKindIsRejected() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        let other = try ContentTemporaryFixture()
        XCTAssertEqual(
            ClaudeProfileInspector().inspect(applicationSupportRoot: fixture.root, layout: other.layout),
            .rejected(.rootMismatch)
        )
        let installationID = UUID()
        let rootID = UUID()
        try fixture.container.materializeOwnedRoot(
            fixture.container.layout.cacheRoot, installationID: installationID, rootID: rootID
        )
        let wrongRoot = try OwnedRootVerifier().verify(
            fixture.container.layout.cacheRoot,
            expectedInstallationID: installationID,
            expectedRootID: rootID
        )
        XCTAssertEqual(
            ClaudeProfileInspector().inspect(applicationSupportRoot: wrongRoot, layout: fixture.container.layout),
            .rejected(.rootMismatch)
        )
    }

    func testSymlinkAtEveryOwnedPathOrMarkerIsRejected() throws {
        for location in ClaudeProfileInspectionFixture.Location.allCases {
            let fixture = try ClaudeProfileInspectionFixture()
            let url = fixture.url(location)
            let original = url.appendingPathExtension("original")
            try FileManager.default.moveItem(at: url, to: original)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
            XCTAssertEqual(fixture.inspect(), .rejected(.symbolicLink), "\(location)")
        }
    }

    func testNonDirectoryAncestorsAndBackupsAreRejected() throws {
        for location in ClaudeProfileInspectionFixture.Location.allCases where !location.isMarker {
            let fixture = try ClaudeProfileInspectionFixture()
            let url = fixture.url(location)
            try FileManager.default.removeItem(at: url)
            try Data("not a directory".utf8).write(to: url)
            try fixture.setMode(0o700, at: url)
            XCTAssertEqual(fixture.inspect(), .rejected(.wrongFileType), "\(location)")
        }
    }

    func testNonregularMarkerDoesNotBlockOrReadItsTarget() throws {
        for useFIFO in [false, true] {
            let fixture = try ClaudeProfileInspectionFixture()
            try FileManager.default.removeItem(at: fixture.marker)
            if useFIFO {
                XCTAssertEqual(mkfifo(fixture.marker.path, 0o600), 0)
            } else {
                try FileManager.default.createDirectory(at: fixture.marker, withIntermediateDirectories: false)
            }
            XCTAssertEqual(fixture.inspect(), .rejected(.wrongFileType))
        }
    }

    func testMarkerHardLinkIsRejectedBeforeReading() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        let otherName = fixture.profile.appending(path: "opaque-state")
        XCTAssertEqual(link(fixture.marker.path, otherName.path), 0)
        XCTAssertEqual(fixture.inspect(), .rejected(.unexpectedHardLinks))
    }

    func testExactPermissionsAreRequiredAndNeverRepaired() throws {
        for location in ClaudeProfileInspectionFixture.Location.allCases {
            let fixture = try ClaudeProfileInspectionFixture()
            let url = fixture.url(location)
            let mode: mode_t = location.isMarker ? 0o644 : 0o755
            try fixture.setMode(mode, at: url)
            XCTAssertEqual(fixture.inspect(), .rejected(.unsafePermissions), "\(location)")
            XCTAssertEqual(try fixture.metadata(url).st_mode & 0o7777, mode)
        }
        let fixture = try ClaudeProfileInspectionFixture()
        try fixture.setMode(0o1600, at: fixture.marker)
        XCTAssertEqual(fixture.inspect(), .rejected(.unsafePermissions))
    }

    func testWrongOwnerMetadataIsRejectedWithoutRequiringPrivilegedChown() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        var marker = try fixture.metadata(fixture.marker)
        marker.st_uid = geteuid() == 0 ? 1 : 0
        XCTAssertEqual(ClaudeProfileMetadataPolicy.markerIssue(marker), .wrongOwner)
        var directory = try fixture.metadata(fixture.profile)
        directory.st_uid = marker.st_uid
        XCTAssertEqual(ClaudeProfileMetadataPolicy.directoryIssue(directory), .wrongOwner)
        XCTAssertEqual(fixture.inspect(), .metadataVerified)
    }

    func testOversizedAndEmptyMarkerAreRejected() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        try Data(repeating: 0x20, count: ClaudeProfileInspector.maximumMarkerBytes + 1).write(to: fixture.marker)
        XCTAssertEqual(fixture.inspect(), .rejected(.markerTooLarge))
        try Data().write(to: fixture.marker)
        XCTAssertEqual(fixture.inspect(), .rejected(.invalidMarker))
    }

    func testMalformedOrNonPreviewMarkersAreRejected() throws {
        let cases = [
            "not json",
            "{}",
            "{\"schemaVersion\":2,\"bundleIdentifier\":\"com.lorenzocolombani.openbotsnext.preview\",\"role\":\"preview\"}",
            "{\"schemaVersion\":1,\"bundleIdentifier\":\"com.example.other\",\"role\":\"preview\"}",
            "{\"schemaVersion\":1,\"bundleIdentifier\":\"com.lorenzocolombani.openbotsnext.preview\",\"role\":\"probe\"}"
        ]
        for value in cases {
            let fixture = try ClaudeProfileInspectionFixture()
            try Data(value.utf8).write(to: fixture.marker)
            XCTAssertEqual(fixture.inspect(), .rejected(.invalidMarker))
        }
    }

    func testMarkerAtTheReadLimitRemainsBoundedAndValid() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        var marker = ClaudeProfileInspectionFixture.markerData
        marker.append(Data(repeating: 0x20, count: ClaudeProfileInspector.maximumMarkerBytes - marker.count))
        try marker.write(to: fixture.marker)
        XCTAssertEqual(fixture.inspect(), .metadataVerified)
    }

    func testReplacementOfAnyObservedPathRejectsTheReceipt() throws {
        for location in ClaudeProfileInspectionFixture.Location.allCases {
            let fixture = try ClaudeProfileInspectionFixture()
            let inspector = ClaudeProfileInspector(afterMarkerRead: {
                let url = fixture.url(location)
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("previous"))
                if location.isMarker {
                    try ClaudeProfileInspectionFixture.markerData.write(to: url)
                    try fixture.setMode(0o600, at: url)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    try fixture.setMode(0o700, at: url)
                }
            })
            XCTAssertEqual(fixture.inspect(using: inspector), .rejected(.changedIdentity), "\(location)")
        }
    }

    func testInPlaceMarkerChangeRejectsTheReceipt() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        let inspector = ClaudeProfileInspector(afterMarkerRead: {
            let fd = open(fixture.marker.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            guard ftruncate(fd, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        })
        XCTAssertEqual(fixture.inspect(using: inspector), .rejected(.changedIdentity))
    }

    func testSubstitutedOwnedRootIdentityIsRejectedBeforeProfileAdmission() throws {
        for replaceDirectory in [false, true] {
            let fixture = try ClaudeProfileInspectionFixture()
            if replaceDirectory {
                let original = fixture.root.url.appendingPathExtension("previous")
                try FileManager.default.moveItem(at: fixture.root.url, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root.url)
            }
            let unrelated = OwnedRootMarker(installationID: UUID(), rootID: UUID(), kind: .applicationSupport)
            try JSONEncoder().encode(unrelated).write(to: fixture.url(.rootMarker))
            XCTAssertEqual(fixture.inspect(), .rejected(.rootMismatch))
        }
    }

    func testMissingOwnedRootMarkerIsNotRecreated() throws {
        let fixture = try ClaudeProfileInspectionFixture()
        try FileManager.default.removeItem(at: fixture.url(.rootMarker))
        XCTAssertEqual(fixture.inspect(), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url(.rootMarker).path))
    }

    func testEveryOwnedRootMarkerIdentityFieldMustMatchTheVerifiedRoot() throws {
        let changes: [(String, Any)] = [
            ("formatVersion", 2),
            ("bundleIdentifier", "com.example.other"),
            ("kind", "caches"),
            ("installationID", UUID().uuidString),
            ("rootID", UUID().uuidString)
        ]
        for (field, value) in changes {
            let fixture = try ClaudeProfileInspectionFixture()
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url(.rootMarker))) as? [String: Any]
            )
            object[field] = value
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.url(.rootMarker))
            XCTAssertEqual(fixture.inspect(), .rejected(.rootMismatch), field)
        }
    }

    func testInaccessibleNonownedAncestorIsUnavailable() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses ordinary directory read permissions") }
        let fixture = try ClaudeProfileInspectionFixture()
        let originalMode = try fixture.metadata(fixture.container.home).st_mode & 0o7777
        try fixture.setMode(0, at: fixture.container.home)
        defer { try? fixture.setMode(originalMode, at: fixture.container.home) }
        XCTAssertEqual(fixture.inspect(), .unavailable)
    }
}

private final class ClaudeProfileInspectionFixture: @unchecked Sendable {
    enum Location: CaseIterable, Sendable {
        case applicationSupport, rootMarker, highChurn, runtime, claude, profile, backups, marker

        var isMarker: Bool { self == .marker || self == .rootMarker }
    }

    static let markerData = Data(
        "{\"schemaVersion\":1,\"bundleIdentifier\":\"com.lorenzocolombani.openbotsnext.preview\",\"role\":\"preview\"}".utf8
    )

    let container: ContentTemporaryFixture
    let root: VerifiedOwnedRoot
    var profile: URL { container.layout.claudeCLIProfileRoot }
    var backups: URL { profile.appending(path: "backups", directoryHint: .isDirectory) }
    var marker: URL { profile.appending(path: ClaudeProfileInspector.markerFilename) }

    init(createProfile: Bool = true) throws {
        container = try ContentTemporaryFixture()
        let installationID = UUID()
        let rootID = UUID()
        try container.materializeOwnedRoot(
            container.layout.applicationSupportRoot, installationID: installationID, rootID: rootID
        )
        root = try OwnedRootVerifier().verify(
            container.layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: rootID
        )
        if createProfile {
            for location in [Location.highChurn, .runtime, .claude, .profile, .backups] {
                try FileManager.default.createDirectory(at: url(location), withIntermediateDirectories: false)
                try setMode(0o700, at: url(location))
            }
            try Self.markerData.write(to: marker)
            try setMode(0o600, at: marker)
        }
    }

    func inspect(using inspector: ClaudeProfileInspector = ClaudeProfileInspector()) -> ClaudeProfileInspectionResult {
        inspector.inspect(applicationSupportRoot: root, layout: container.layout)
    }

    func url(_ location: Location) -> URL {
        switch location {
        case .applicationSupport: container.layout.applicationSupportRoot.url
        case .rootMarker: container.layout.applicationSupportRoot.ownershipMarkerURL
        case .highChurn: container.layout.highChurnRoot
        case .runtime: container.layout.runtimeRoot
        case .claude: profile.deletingLastPathComponent()
        case .profile: profile
        case .backups: backups
        case .marker: marker
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
