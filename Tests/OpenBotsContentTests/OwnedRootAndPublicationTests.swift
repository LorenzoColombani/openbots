import Foundation
import XCTest
@testable import OpenBotsContent

final class OwnedRootAndPublicationTests: XCTestCase {
    func testVerifiedMarkerIsRequiredBeforeLifecyclePlan() throws {
        let fixture = try ContentTemporaryFixture()
        let installationID = UUID()
        let rootID = UUID()
        try fixture.materializeOwnedRoot(
            fixture.layout.applicationSupportRoot,
            installationID: installationID,
            rootID: rootID
        )
        let verified = try OwnedRootVerifier().verify(
            fixture.layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: rootID
        )
        let plan = OwnedLifecyclePlanner().plan(.remove, for: verified)
        XCTAssertEqual(plan.exactRoot, fixture.layout.applicationSupportRoot.url)
        XCTAssertEqual(plan.expectedInstallationID, installationID)
        XCTAssertEqual(plan.expectedRootID, rootID)
        XCTAssertFalse(plan.followsSymbolicLinks)
    }

    func testMarkerMismatchAndUnsafePermissionsFailClosed() throws {
        let fixture = try ContentTemporaryFixture()
        let installationID = UUID()
        let rootID = UUID()
        try fixture.materializeOwnedRoot(
            fixture.layout.contentRoot,
            installationID: installationID,
            rootID: rootID
        )
        XCTAssertThrowsError(
            try OwnedRootVerifier().verify(
                fixture.layout.contentRoot,
                expectedInstallationID: installationID,
                expectedRootID: UUID()
            )
        ) { XCTAssertEqual($0 as? OwnedRootError, .markerMismatch) }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.layout.contentRoot.ownershipMarkerURL.path
        )
        XCTAssertThrowsError(
            try OwnedRootVerifier().verify(
                fixture.layout.contentRoot,
                expectedInstallationID: installationID,
                expectedRootID: rootID
            )
        ) {
            guard case .markerPermissionsUnsafe = $0 as? OwnedRootError else {
                return XCTFail("Expected permission failure, got \($0)")
            }
        }
    }

    func testOwnedPublicationPlanRequiresContainedExclusiveSameVolumePaths() throws {
        let fixture = try ContentTemporaryFixture()
        let installationID = UUID()
        let supportID = UUID()
        let contentID = UUID()
        try fixture.materializeOwnedRoot(
            fixture.layout.applicationSupportRoot,
            installationID: installationID,
            rootID: supportID
        )
        try fixture.materializeOwnedRoot(
            fixture.layout.contentRoot,
            installationID: installationID,
            rootID: contentID
        )
        let sourceDirectory = fixture.layout.applicationSupportRoot.url.appending(path: "Staging")
        let destinationDirectory = fixture.layout.contentRoot.url.appending(path: "Artifacts")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appending(path: "ready.pdf")
        try Data("ready".utf8).write(to: source)

        let verifier = OwnedRootVerifier()
        let support = try verifier.verify(
            fixture.layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: supportID
        )
        let content = try verifier.verify(
            fixture.layout.contentRoot,
            expectedInstallationID: installationID,
            expectedRootID: contentID
        )
        let destination = destinationDirectory.appending(path: "final.pdf")
        let plan = try OwnedPublicationPlanner().plan(
            source: source,
            inside: support,
            destination: destination,
            inside: content
        )
        XCTAssertEqual(plan.source, source)
        XCTAssertEqual(plan.destination, destination)
        XCTAssertTrue(plan.requiresExclusiveAtomicRename)

        try Data("collision".utf8).write(to: destination)
        XCTAssertThrowsError(
            try OwnedPublicationPlanner().plan(
                source: source,
                inside: support,
                destination: destination,
                inside: content
            )
        ) { XCTAssertEqual($0 as? PathSafetyError, .destinationAlreadyExists) }
    }

    func testOwnedPublicationRejectsSymlinkDestinationParent() throws {
        let fixture = try ContentTemporaryFixture()
        let installationID = UUID()
        let supportID = UUID()
        let contentID = UUID()
        try fixture.materializeOwnedRoot(
            fixture.layout.applicationSupportRoot,
            installationID: installationID,
            rootID: supportID
        )
        try fixture.materializeOwnedRoot(
            fixture.layout.contentRoot,
            installationID: installationID,
            rootID: contentID
        )
        let source = fixture.layout.applicationSupportRoot.url.appending(path: "ready.pdf")
        try Data("ready".utf8).write(to: source)
        let external = fixture.root.appending(path: "External", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let link = fixture.layout.contentRoot.url.appending(path: "Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        let verifier = OwnedRootVerifier()
        let support = try verifier.verify(
            fixture.layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: supportID
        )
        let content = try verifier.verify(
            fixture.layout.contentRoot,
            expectedInstallationID: installationID,
            expectedRootID: contentID
        )
        XCTAssertThrowsError(
            try OwnedPublicationPlanner().plan(
                source: source,
                inside: support,
                destination: link.appending(path: "escaped.pdf"),
                inside: content
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appending(path: "escaped.pdf").path))
    }
}
