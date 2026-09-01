import Foundation
import OpenBotsContent
import OpenBotsDomain
import XCTest
@testable import OpenBotsServices

final class KnowledgeSnapshotDeliveryBrokerTests: XCTestCase {
    func testInspectionAndMissingTrustedAuthorityCannotBecomeDelivery() async throws {
        let fixture = try DeliveryBrokerFixture(); defer { fixture.remove() }
        let qualified = try makeSnapshot(markdown: "Synthetic confirmed fixture")
        let inspection = try KnowledgeSnapshotRenderer().render(sources: qualified.sources, generatedAt: qualified.generatedAt)
        let target = fixture.root.appending(path: "Denied.md")
        let defaultBroker = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker())
        for snapshot in [inspection, qualified] {
            await assertDeliveryError(.sharingDenied) {
                _ = try await defaultBroker.freeze(workspaceSnapshotID: UUID(), snapshot: snapshot, exactTarget: target)
            }
        }
        let injected = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker(), sharing: DeliveryFixtureSharingValidator())
        await assertDeliveryError(.sharingDenied) {
            _ = try await injected.freeze(workspaceSnapshotID: UUID(), snapshot: inspection, exactTarget: target)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testChangedSharingAuthorityConsumesTokenWithoutWritingOrEditingFrozenBytes() async throws {
        let fixture = try DeliveryBrokerFixture(); defer { fixture.remove() }
        let snapshot = try makeSnapshot(markdown: "Frozen qualified fixture")
        let validator = DeliveryRevocableSharingValidator()
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker(), sharing: validator)
        let workspace = UUID(), target = fixture.root.appending(path: "Revoked.md")
        let delivery = try await broker.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        await validator.revoke()
        await assertDeliveryError(.sharingDenied) { _ = try await broker.create(workspaceSnapshotID: workspace, delivery: delivery) }
        await assertDeliveryError(.staleOrUnknownToken) { _ = try await broker.create(workspaceSnapshotID: workspace, delivery: delivery) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(snapshot.contentDigest, MemoryClaimDigests.bytes(snapshot.data))
    }

    func testFrozenRenderedSnapshotWritesExactBytesOnceAndReturnsProvenanceReceipt() async throws {
        let fixture = try DeliveryBrokerFixture()
        defer { fixture.remove() }
        let snapshot = try makeSnapshot(markdown: "The exact frozen body.")
        let workspaceID = UUID(uuidString: "b5100000-0000-0000-0000-000000000001")!
        let target = fixture.root.appending(path: "Knowledge Snapshot.md")
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker(), sharing: DeliveryFixtureSharingValidator())

        let delivery = try await broker.freeze(
            workspaceSnapshotID: workspaceID,
            snapshot: snapshot,
            exactTarget: target
        )
        let exactTarget = URL(fileURLWithPath: delivery.exactDisplayPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactTarget.path))

        let receipt = try await broker.create(
            workspaceSnapshotID: workspaceID,
            delivery: delivery
        )
        XCTAssertEqual(try Data(contentsOf: exactTarget), snapshot.data)
        XCTAssertEqual(receipt.token, delivery.token)
        XCTAssertEqual(receipt.exactDisplayPath, delivery.exactDisplayPath)
        XCTAssertEqual(receipt.byteCount, snapshot.data.count)
        XCTAssertEqual(receipt.contentDigest, snapshot.contentDigest)
        XCTAssertEqual(receipt.documentCount, snapshot.sourceCount)
        XCTAssertEqual(receipt.snapshotGeneratedAt, snapshot.generatedAt)
        XCTAssertEqual(
            receipt.disclosure,
            KnowledgeSnapshotDeliveryReceipt.nonAuthoritativeDisclosure
        )
        try assertMode0600(at: exactTarget)

        await assertDeliveryError(.staleOrUnknownToken) {
            _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: delivery)
        }
        XCTAssertEqual(try Data(contentsOf: exactTarget), snapshot.data)
    }

    func testWorkspaceTokenAndExactPathMismatchesAreRejectedWithoutConsumingValidAction() async throws {
        let fixture = try DeliveryBrokerFixture()
        defer { fixture.remove() }
        let snapshot = try makeSnapshot(markdown: "Scoped snapshot")
        let workspaceID = UUID(uuidString: "b5100000-0000-0000-0000-000000000010")!
        let target = fixture.root.appending(path: "Scoped.md")
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker(), sharing: DeliveryFixtureSharingValidator())
        let delivery = try await broker.freeze(
            workspaceSnapshotID: workspaceID,
            snapshot: snapshot,
            exactTarget: target
        )

        let unknown = FrozenKnowledgeSnapshotDelivery(
            token: KnowledgeSnapshotDeliveryToken(UUID()),
            exactDisplayPath: delivery.exactDisplayPath
        )
        await assertDeliveryError(.staleOrUnknownToken) {
            _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: unknown)
        }
        await assertDeliveryError(.workspaceMismatch) {
            _ = try await broker.create(workspaceSnapshotID: UUID(), delivery: delivery)
        }
        let wrongPath = FrozenKnowledgeSnapshotDelivery(
            token: delivery.token,
            exactDisplayPath: fixture.root.appending(path: "Different.md").path
        )
        await assertDeliveryError(.targetMismatch) {
            _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: wrongPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: delivery)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: delivery.exactDisplayPath)),
            snapshot.data
        )
    }

    func testCollisionPreservesExistingItemAndConsumesOneShotAction() async throws {
        let fixture = try DeliveryBrokerFixture()
        defer { fixture.remove() }
        let snapshot = try makeSnapshot(markdown: "Must not replace existing bytes")
        let workspaceID = UUID(uuidString: "b5100000-0000-0000-0000-000000000020")!
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker(), sharing: DeliveryFixtureSharingValidator())
        let delivery = try await broker.freeze(
            workspaceSnapshotID: workspaceID,
            snapshot: snapshot,
            exactTarget: fixture.root.appending(path: "Collision.md")
        )
        let exactTarget = URL(fileURLWithPath: delivery.exactDisplayPath)
        let existing = Data("Existing user-owned content".utf8)
        try existing.write(to: exactTarget)

        do {
            _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: delivery)
            XCTFail("Expected exclusive create-new collision.")
        } catch let error as ExternalCreateNewError {
            XCTAssertEqual(error, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: exactTarget), existing)
        await assertDeliveryError(.staleOrUnknownToken) {
            _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: delivery)
        }
        XCTAssertEqual(try Data(contentsOf: exactTarget), existing)
    }

    func testReleaseRevokesPendingActionWithoutCreatingOrCleaningAnyFile() async throws {
        let fixture = try DeliveryBrokerFixture()
        defer { fixture.remove() }
        let snapshot = try makeSnapshot(markdown: "Released snapshot")
        let workspaceID = UUID(uuidString: "b5100000-0000-0000-0000-000000000030")!
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: DeliveryLocationChecker(), sharing: DeliveryFixtureSharingValidator())
        let delivery = try await broker.freeze(
            workspaceSnapshotID: workspaceID,
            snapshot: snapshot,
            exactTarget: fixture.root.appending(path: "Released.md")
        )

        let firstRelease = await broker.release(delivery)
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.exactDisplayPath))
        let repeatedRelease = await broker.release(delivery)
        XCTAssertFalse(repeatedRelease)
        await assertDeliveryError(.staleOrUnknownToken) {
            _ = try await broker.create(workspaceSnapshotID: workspaceID, delivery: delivery)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.exactDisplayPath))
    }

    private func makeSnapshot(markdown: String) throws -> NonAuthoritativeKnowledgeSnapshot {
        let id = MemoryDocumentID(UUID(uuidString: "b5100000-0000-0000-0000-000000000100")!)
        let scope = MemoryScope.teammate(TeammateID(UUID(uuidString: "b5100000-0000-0000-0000-000000000101")!))
        let claim = MemoryClaim(id: MemoryClaimID(UUID()), body: markdown,
            assessment: MemoryClaimAssessment(level: .confirmed, basis: "Synthetic test authority.",
                assessor: MemoryClaimAssessor(kind: .app, identity: "test-only"), assessedAt: Date(timeIntervalSince1970: 1_760_100_000)),
            provenance: [], observedAt: Date(timeIntervalSince1970: 1_760_100_000))
        let artifact = MemoryClaimArtifact(documentID: id, revision: 1, scope: scope, claims: [claim])
        let bytes = try MemoryClaimCodec().encode(artifact)
        let source = try KnowledgeSnapshotSource(
            documentID: id,
            title: "Working agreement",
            scope: scope,
            author: .user,
            revision: 1,
            contentDigest: MemoryClaimDigests.bytes(bytes),
            updatedAt: Date(timeIntervalSince1970: 1_760_100_000),
            revisionStatus: .current,
            markdown: String(decoding: bytes, as: UTF8.self)
        )
        return try KnowledgeSnapshotRenderer().renderQualifiedSharing(
            sources: [source],
            generatedAt: Date(timeIntervalSince1970: 1_760_100_100)
        )
    }

    private func assertMode0600(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(mode, 0o600)
    }
}

/// Transport-only fixture. Production sharing uses current SQLite/catalog,
/// artifact and registered evidence checks in MemoryClaimSnapshotSharingService.
private struct DeliveryFixtureSharingValidator: KnowledgeSnapshotSharingValidating {
    func validate(snapshot: NonAuthoritativeKnowledgeSnapshot, workspaceSnapshotID: UUID,
                  capabilityID: CapabilityGrantID, exactTarget: URL) async throws {
        guard snapshot.purpose == .qualifiedSharing else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
    }
}

private actor DeliveryRevocableSharingValidator: KnowledgeSnapshotSharingValidating {
    var active = true
    func revoke() { active = false }
    func validate(snapshot: NonAuthoritativeKnowledgeSnapshot, workspaceSnapshotID: UUID,
                  capabilityID: CapabilityGrantID, exactTarget: URL) async throws {
        guard active else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
    }
}

private struct DeliveryLocationChecker: LocationEnvironmentChecking {
    func observation(for url: URL) throws -> LocationObservation {
        LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            fileProviderStatus: .notManaged,
            volumeIdentifier: "delivery-test-volume"
        )
    }
}

private final class DeliveryBrokerFixture {
    let root: URL

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextSnapshotDelivery-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func assertDeliveryError(
    _ expected: KnowledgeSnapshotDeliveryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected delivery operation to fail with \(expected).")
    } catch let error as KnowledgeSnapshotDeliveryError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("Expected KnowledgeSnapshotDeliveryError, received \(error).")
    }
}
