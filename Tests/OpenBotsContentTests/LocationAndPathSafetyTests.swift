import Foundation
import XCTest
@testable import OpenBotsContent

final class LocationAndPathSafetyTests: XCTestCase {
    func testHighChurnLocationRequiresIndependentLocalProviderAndNoIndexEvidence() throws {
        let validator = HighChurnLocationValidator()
        let safeURL = URL(fileURLWithPath: "/private/tmp/Working.noindex/Workspace")
        XCTAssertNoThrow(try validator.validate(safeURL, observation: safeLocalObservation))

        XCTAssertThrowsError(
            try validator.validate(
                URL(fileURLWithPath: "/private/tmp/Working/Workspace"),
                observation: safeLocalObservation
            )
        ) { XCTAssertEqual($0 as? HighChurnLocationViolation, .missingNoIndexBoundary) }

        let provider = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            fileProviderStatus: .managed(providerIdentifier: "fixture")
        )
        XCTAssertThrowsError(try validator.validate(safeURL, observation: provider)) {
            XCTAssertEqual($0 as? HighChurnLocationViolation, .fileProviderManaged)
        }

        let ubiquitous = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: true,
            fileProviderStatus: .notManaged
        )
        XCTAssertThrowsError(try validator.validate(safeURL, observation: ubiquitous)) {
            XCTAssertEqual($0 as? HighChurnLocationViolation, .ubiquitousItem)
        }

        let unknown = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            fileProviderStatus: .uncertain(reason: "fixture")
        )
        XCTAssertThrowsError(try validator.validate(safeURL, observation: unknown)) {
            XCTAssertEqual($0 as? HighChurnLocationViolation, .fileProviderUnknown)
        }
    }

    func testKnownProviderAncestryDetectionIsReadOnlyAndConservative() {
        let detector = KnownFileProviderAncestryDetector()
        XCTAssertEqual(
            detector.status(for: URL(fileURLWithPath: "/private/tmp/FixtureHome/Library/Mobile Documents/com~apple~CloudDocs/A")),
            .managed(providerIdentifier: "iCloud Drive")
        )
        XCTAssertEqual(
            detector.status(for: URL(fileURLWithPath: "/private/tmp/FixtureHome/Library/CloudStorage/Provider/A")),
            .managed(providerIdentifier: nil)
        )
        XCTAssertEqual(
            detector.status(for: URL(fileURLWithPath: "/private/tmp/FixtureHome/OpenBots Next Preview Content")),
            .uncertain(reason: "No supported File Provider ownership lookup was performed")
        )
    }

    func testContainmentRejectsSiblingPrefixTraversalAndSymlinkEscape() throws {
        let fixture = try ContentTemporaryFixture()
        let root = fixture.root.appending(path: "Owned", directoryHint: .isDirectory)
        let sibling = fixture.root.appending(path: "Owned-Evil", directoryHint: .isDirectory)
        let outside = fixture.root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appending(path: "secret.txt")
        try Data("fixture".utf8).write(to: outsideFile)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let safety = PathSafety()
        let canonicalRoot = try safety.canonicalExistingDirectory(root)
        XCTAssertFalse(safety.isComponentContained(sibling, in: root))
        XCTAssertThrowsError(
            try safety.canonicalExistingItem(
                root.appending(path: "../Outside/secret.txt"),
                containedIn: canonicalRoot
            )
        ) { XCTAssertEqual($0 as? PathSafetyError, .escapesRoot) }
        XCTAssertThrowsError(
            try safety.canonicalExistingItem(link.appending(path: "secret.txt"), containedIn: canonicalRoot)
        ) {
            guard case .symlinkEncountered = $0 as? PathSafetyError else {
                return XCTFail("Expected symlink rejection, got \($0)")
            }
        }
    }

    func testFutureChildRejectsPatternsAndCollision() throws {
        let fixture = try ContentTemporaryFixture()
        let parent = fixture.root.appending(path: "Delivery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let canonical = try PathSafety().canonicalExistingDirectory(parent)
        XCTAssertThrowsError(try PathSafety().exclusiveFutureChild(named: "../escape", of: canonical)) {
            XCTAssertEqual($0 as? PathSafetyError, .invalidFinalComponent)
        }
        let existing = parent.appending(path: "exists.pdf")
        try Data().write(to: existing)
        XCTAssertThrowsError(try PathSafety().exclusiveFutureChild(named: "exists.pdf", of: canonical)) {
            XCTAssertEqual($0 as? PathSafetyError, .destinationAlreadyExists)
        }
    }
}
