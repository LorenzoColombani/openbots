import Foundation
import OpenBotsDomain
import XCTest
@testable import OpenBotsContent

final class ExternalCapabilityTests: XCTestCase {
    func testProviderManagedReadCanBeBroadButConveysNoWriteType() throws {
        let fixture = try ContentTemporaryFixture()
        let selected = fixture.root.appending(path: "Provider Read", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let providerObservation = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: true,
            fileProviderStatus: .managed(providerIdentifier: "fixture")
        )
        let capability = try ExternalReadCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .teammate(TeammateID(UUID())),
            selectedRoot: selected,
            recursive: true,
            locationChecker: StaticLocationChecker(value: providerObservation)
        )
        XCTAssertTrue(capability.recursive)
        XCTAssertEqual(capability.locationObservation, providerObservation)
        XCTAssertEqual(capability.canonicalRoot, selected)
    }

    func testExactExternalDeliveryIsExclusiveAndCannotReplayAsOverwrite() throws {
        let fixture = try ContentTemporaryFixture()
        let delivery = fixture.root.appending(path: "Provider Delivery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let target = delivery.appending(path: "result.pdf")
        let checker = StaticLocationChecker(value: safeLocalObservation)
        let first = Data("completed artifact".utf8)
        let capability = try ExternalCreateNewCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .application,
            exactSelectedTarget: target,
            expectedByteCount: first.count,
            locationChecker: checker
        )
        let plan = ExternalCreateNewPlan(capability: capability)
        let writer = ExternalCreateNewWriter(locationChecker: checker)
        XCTAssertThrowsError(try writer.write(Data(), using: plan)) {
            XCTAssertEqual(
                $0 as? ExternalCreateNewError,
                .byteCountMismatch(expected: first.count, actual: 0)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let receipt = try writer.write(first, using: plan)
        XCTAssertEqual(receipt.byteCount, first.count)
        XCTAssertEqual(try Data(contentsOf: target), first)

        XCTAssertThrowsError(try writer.write(first, using: plan)) {
            XCTAssertEqual($0 as? ExternalCreateNewError, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: target), first)
    }

    func testChangedProviderOrMountObservationFailsBeforeWrite() throws {
        let fixture = try ContentTemporaryFixture()
        let delivery = fixture.root.appending(path: "Delivery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let target = delivery.appending(path: "result.pdf")
        let capability = try ExternalCreateNewCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .application,
            exactSelectedTarget: target,
            expectedByteCount: 1,
            locationChecker: StaticLocationChecker(value: safeLocalObservation)
        )
        let changed = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: true,
            fileProviderStatus: .managed(providerIdentifier: "changed"),
            volumeIdentifier: "different-volume"
        )
        let writer = ExternalCreateNewWriter(locationChecker: StaticLocationChecker(value: changed))
        XCTAssertThrowsError(try writer.write(Data("x".utf8), using: ExternalCreateNewPlan(capability: capability))) {
            XCTAssertEqual($0 as? ExternalCreateNewError, .locationChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRenamedParentAndReplacementDirectoryFailIdentityCheck() throws {
        let fixture = try ContentTemporaryFixture()
        let delivery = fixture.root.appending(path: "Delivery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let target = delivery.appending(path: "result.pdf")
        let checker = StaticLocationChecker(value: safeLocalObservation)
        let capability = try ExternalCreateNewCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .application,
            exactSelectedTarget: target,
            expectedByteCount: 1,
            locationChecker: checker
        )
        let moved = fixture.root.appending(path: "Moved Delivery", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: delivery, to: moved)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try ExternalCreateNewWriter(locationChecker: checker).write(
                Data("x".utf8),
                using: ExternalCreateNewPlan(capability: capability)
            )
        ) { XCTAssertEqual($0 as? ExternalCreateNewError, .parentChanged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appending(path: "result.pdf").path))
    }

    func testSymlinkParentReplacementCannotEscapeCapability() throws {
        let fixture = try ContentTemporaryFixture()
        let delivery = fixture.root.appending(path: "Delivery", directoryHint: .isDirectory)
        let outside = fixture.root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = delivery.appending(path: "result.pdf")
        let checker = StaticLocationChecker(value: safeLocalObservation)
        let capability = try ExternalCreateNewCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .application,
            exactSelectedTarget: target,
            expectedByteCount: 1,
            locationChecker: checker
        )
        try FileManager.default.removeItem(at: delivery)
        try FileManager.default.createSymbolicLink(at: delivery, withDestinationURL: outside)

        XCTAssertThrowsError(
            try ExternalCreateNewWriter(locationChecker: checker).write(
                Data("x".utf8),
                using: ExternalCreateNewPlan(capability: capability)
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending(path: "result.pdf").path))
    }

    func testIntermediateSymlinkCannotReuseTheOriginalParentIdentity() throws {
        let fixture = try ContentTemporaryFixture()
        let grantedAncestor = fixture.root.appending(path: "Granted", directoryHint: .isDirectory)
        let delivery = grantedAncestor.appending(path: "Delivery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let target = delivery.appending(path: "result.pdf")
        let checker = StaticLocationChecker(value: safeLocalObservation)
        let capability = try ExternalCreateNewCapability.grant(
            id: CapabilityGrantID(UUID()),
            holder: .application,
            exactSelectedTarget: target,
            expectedByteCount: 1,
            locationChecker: checker
        )
        let movedAncestor = fixture.root.appending(path: "Original", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: grantedAncestor, to: movedAncestor)
        try FileManager.default.createSymbolicLink(
            at: grantedAncestor,
            withDestinationURL: movedAncestor
        )

        XCTAssertThrowsError(
            try ExternalCreateNewWriter(locationChecker: checker).write(
                Data("x".utf8),
                using: ExternalCreateNewPlan(capability: capability)
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: movedAncestor
                    .appending(path: "Delivery")
                    .appending(path: "result.pdf")
                    .path
            )
        )
    }
}
