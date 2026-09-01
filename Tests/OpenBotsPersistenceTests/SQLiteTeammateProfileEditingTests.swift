import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsPersistence

final class SQLiteTeammateProfileEditingTests: XCTestCase {
    func testNewModelAllocationPersistsAndNeverReassignsExistingCreatureOrPhoto() async throws {
        let fixture = try ProfileEditingSQLiteFixture()
        defer { fixture.remove() }
        let creature = try fixture.teammate()
        let photo = try Teammate(id: TeammateID(UUID()), profile: creature.profile,
            appearance: AgentAppearance(mode: .photo, grammarVersion: 1, deterministicSeed: 98,
                silhouette: "round", paletteToken: "mint", eyeDialect: "calm",
                nonColorIdentityCue: "leaf ears", accessibleIdentityDescription: "Saved photo fallback",
                profileAssetID: ProfileAssetID(UUID())), createdAt: creature.createdAt, updatedAt: creature.updatedAt)
        do {
            let store = try fixture.open()
            try await store.insert(creature)
            try await store.insert(photo)
        }
        var observed: Set<String> = []
        for index in 0..<32 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "87000000-0000-0000-0000-%012x", index)))
            let created: Teammate
            do {
                let store = try fixture.open()
                let service = TeammateProfileService(repository: store, clock: ProfileEditingSQLiteClock(),
                    uuidGenerator: AvatarAllocationUUID(value: id))
                created = try await service.createQuickTeammate(.init(displayName: "New Bot", role: "Local test"))
                observed.insert(created.appearance.builtInAvatarID ?? "legacy")
            }
            let reopened = try fixture.open()
            let loaded = try await reopened.teammate(id: created.id)
            let unchangedCreature = try await reopened.teammate(id: creature.id)
            let unchangedPhoto = try await reopened.teammate(id: photo.id)
            XCTAssertEqual(loaded?.appearance, created.appearance)
            XCTAssertEqual(unchangedCreature, creature)
            XCTAssertEqual(unchangedPhoto, photo)
        }
        XCTAssertEqual(observed, Set(["pillow", "fin", "kite", "bean", "guide", "legacy"]))
    }

    func testBuiltInChoicesSurviveReopenWithoutChangingLegacyIdentity() async throws {
        let fixture = try ProfileEditingSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        do {
            let store = try fixture.open()
            try await store.insert(original)
            // Reconstruct a version-12 synthetic database to exercise the new
            // migration with a real existing appearance row. Never live data.
            _ = try await store.execute(sql: "ALTER TABLE agent_appearances DROP COLUMN built_in_avatar_id;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=13;")
        }
        do {
            let migrated = try fixture.open()
            let loaded = try await migrated.teammate(id: original.id)
            XCTAssertEqual(loaded, original)
            XCTAssertNil(loaded?.appearance.builtInAvatarID)
        }
        for avatar in BuiltInAvatar.allCases {
            let saved: Teammate
            do {
                let store = try fixture.open()
                let found = try await store.teammate(id: original.id)
                let current = try XCTUnwrap(found)
                let service = TeammateProfileService(repository: store, clock: ProfileEditingSQLiteClock())
                saved = try await service.saveProfile(
                    teammateID: current.id, expectedRevision: current.profile.revision,
                    draft: TeammateProfileEditDraft(displayName: current.profile.displayName,
                        title: current.profile.title, role: current.profile.role,
                        detailedInstructions: current.profile.detailedInstructions, builtInAvatar: avatar)
                )
            }
            let reopened = try fixture.open()
            let loaded = try await reopened.teammate(id: original.id)
            XCTAssertEqual(loaded?.appearance, saved.appearance)
            XCTAssertEqual(loaded?.appearance.builtInAvatarID, avatar.rawValue)
            XCTAssertEqual(loaded?.appearance.deterministicSeed, original.appearance.deterministicSeed)
            XCTAssertEqual(loaded?.appearance.accessibleIdentityDescription, original.appearance.accessibleIdentityDescription)
            let roster = try await reopened.listTeammates(includingArchived: true)
            XCTAssertEqual(roster.count, 1)
        }
    }

    func testServiceSaveSurvivesReopenAndPreservesHistorySettingsConversationAndGrant() async throws {
        let fixture = try ProfileEditingSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        let conversation = try Conversation(
            id: ConversationID(UUID()),
            kind: .direct(teammateID: original.id),
            title: "Existing conversation",
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        let grant = CapabilityGrant(
            id: CapabilityGrantID(UUID()),
            teammateID: original.id,
            capability: .userSelectedRead,
            scope: .userSelectedRead(reference: "synthetic-existing-grant"),
            grantedAt: original.createdAt
        )
        let saved: Teammate
        do {
            let store = try fixture.open()
            try await store.insert(original)
            try await store.insert(conversation, participantIDs: [original.id])
            try await store.insert(grant)
            let service = TeammateProfileService(repository: store, clock: ProfileEditingSQLiteClock())
            saved = try await service.saveProfile(
                teammateID: original.id,
                expectedRevision: original.profile.revision,
                draft: TeammateProfileEditDraft(
                    displayName: "Ada Updated",
                    title: "Research partner",
                    role: "Sources and synthesis",
                    detailedInstructions: "Explain uncertainty.",
                    creature: TeammateCreatureDraft(
                        silhouette: "cloud",
                        paletteToken: "mint",
                        eyeDialect: "bright",
                        nonColorIdentityCue: "two antennae"
                    )
                )
            )
        }
        let reopened = try fixture.open()
        let loaded = try await reopened.teammate(id: original.id)
        // SQLite stores epoch seconds as REAL. Foundation Date uses a different
        // epoch internally, so converting a fractional timestamp can lose a
        // fraction of a microsecond. Compare the exact serialized timestamp;
        // all other identity/profile/appearance fields remain exact.
        var serialized = saved
        serialized.updatedAt = Date(timeIntervalSince1970: saved.updatedAt.timeIntervalSince1970)
        XCTAssertEqual(loaded, serialized)
        XCTAssertEqual(loaded?.updatedAt.timeIntervalSince1970, saved.updatedAt.timeIntervalSince1970)
        XCTAssertLessThanOrEqual(abs(serialized.updatedAt.timeIntervalSince(saved.updatedAt)), 0.000_001)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.profile.revision, original.profile.revision + 1)
        XCTAssertEqual(saved.appearance.revision, original.appearance.revision + 1)
        XCTAssertEqual(saved.appearance.grammarVersion, original.appearance.grammarVersion)
        XCTAssertEqual(saved.appearance.deterministicSeed, original.appearance.deterministicSeed)
        XCTAssertEqual(saved.lifecycle, original.lifecycle)
        XCTAssertEqual(saved.isPinned, original.isPinned)
        XCTAssertEqual(saved.isHidden, original.isHidden)
        XCTAssertEqual(saved.notificationPreference, original.notificationPreference)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        let persistedConversation = try await reopened.conversation(id: conversation.id)
        let persistedGrants = try await reopened.activeGrants(teammateID: original.id)
        XCTAssertEqual(persistedConversation, conversation)
        XCTAssertEqual(persistedGrants, [grant])
        let history = try await reopened.query(
            sql: "SELECT revision,display_name FROM teammate_profile_revisions WHERE teammate_id=? ORDER BY revision;",
            bindings: [.text(original.id.persistedValue)]
        )
        XCTAssertEqual(try history.map { try $0.integer("revision") }, [1, 2])
        XCTAssertEqual(try history.map { try $0.text("display_name") }, ["Ada", "Ada Updated"])
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.uint16Value, 0o600)
    }

    func testCompetingConnectionsPublishExactlyOneProfileRevision() async throws {
        let fixture = try ProfileEditingSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        let firstStore = try fixture.open()
        try await firstStore.insert(original)
        let secondStore = try fixture.open()
        let services = [
            TeammateProfileService(repository: firstStore),
            TeammateProfileService(repository: secondStore)
        ]
        let successes = await withTaskGroup(of: Bool.self) { group in
            for (index, service) in services.enumerated() {
                group.addTask {
                    do {
                        _ = try await service.saveProfile(
                            teammateID: original.id,
                            expectedRevision: original.profile.revision,
                            draft: TeammateProfileEditDraft(displayName: "Editor \(index)", role: "Researcher")
                        )
                        return true
                    } catch {
                        XCTAssertEqual(error as? RepositoryError, .optimisticLockFailed(entity: "teammate", id: original.id.persistedValue))
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 1)
        let reopened = try fixture.open()
        let loaded = try await reopened.teammate(id: original.id)
        XCTAssertEqual(loaded?.profile.revision, 2)
        XCTAssertEqual(loaded?.appearance, original.appearance)
        let historyCount = try await reopened.query(sql: "SELECT COUNT(*) AS count FROM teammate_profile_revisions;").first?.integer("count")
        XCTAssertEqual(historyCount, 2)
    }

    func testLateAppearanceFailureRollsBackProfileAndRevisionHistory() async throws {
        let fixture = try ProfileEditingSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        let store = try fixture.open()
        try await store.insert(original)
        _ = try await store.execute(sql: """
            CREATE TRIGGER profile_edit_late_failure BEFORE UPDATE ON agent_appearances
            BEGIN SELECT RAISE(ABORT, 'fixture appearance update failure'); END;
            """)
        let service = TeammateProfileService(repository: store)
        do {
            _ = try await service.saveProfile(
                teammateID: original.id,
                expectedRevision: original.profile.revision,
                draft: TeammateProfileEditDraft(displayName: "Should roll back", role: "Changed")
            )
            XCTFail("A late appearance failure must not publish a partial edit.")
        } catch is SQLiteStoreError {
            // Expected: the whole graph remains at its previous revision.
        }
        let loaded = try await store.teammate(id: original.id)
        let historyCount = try await store.query(sql: "SELECT COUNT(*) AS count FROM teammate_profile_revisions;").first?.integer("count")
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(historyCount, 1)
    }

    func testUnrepresentableExpectedRevisionRejectsWithoutOverflowOrWrites() async throws {
        let fixture = try ProfileEditingSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        let store = try fixture.open()
        try await store.insert(original)
        var impossible = original
        impossible.profile = try TeammateProfile(displayName: "Invalid", role: "Invalid", revision: UInt64.max)
        do {
            try await store.update(impossible, expectedProfileRevision: UInt64.max)
            XCTFail("SQLite cannot represent UInt64.max; this must reject without trapping.")
        } catch let error as SQLiteStoreError {
            XCTAssertEqual(error, .invalidRow(reason: "profile revision exceeds SQLite INTEGER"))
        }
        let loaded = try await store.teammate(id: original.id)
        let historyCount = try await store.query(sql: "SELECT COUNT(*) AS count FROM teammate_profile_revisions;").first?.integer("count")
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(historyCount, 1)
    }
}

private struct AvatarAllocationUUID: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private struct ProfileEditingSQLiteClock: OpenBotsClock {
    func now() -> Date { Date(timeIntervalSinceReferenceDate: 123_456_789.123_456_78) }
}

private struct ProfileEditingSQLiteFixture {
    let directory: URL
    let databaseURL: URL
    let receipt: ProtectionDecisionReceipt

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("openbots-profile-editing-\(UUID().uuidString).noindex", isDirectory: true)
        databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: databaseURL, protection: .ordinarySQLite(decision: receipt)))
    }

    func teammate() throws -> Teammate {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        return try Teammate(
            id: TeammateID(UUID(uuidString: "92000000-0000-0000-0000-000000000010")!),
            profile: TeammateProfile(displayName: "Ada", role: "Researcher"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 777, silhouette: "round", paletteToken: "sky", eyeDialect: "calm", nonColorIdentityCue: "soft crown", accessibleIdentityDescription: "Round creature with soft crown"),
            lifecycle: .active,
            isPinned: true,
            isHidden: true,
            notificationPreference: .disabled,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
