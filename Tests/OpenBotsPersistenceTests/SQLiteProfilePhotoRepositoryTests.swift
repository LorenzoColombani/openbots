import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Immutable profile photo metadata")
struct SQLiteProfilePhotoRepositoryTests {
    @Test("Exact path-free photo metadata survives reopen")
    func metadataRoundTrip() async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let asset = try photoAsset(width: 512, height: 320, byteCount: 65_536)
        do {
            let store = try fixture.open()
            #expect(try await store.asset(id: asset.id) == nil)
            try await store.insertAsset(asset)
        }
        let reopened = try fixture.open()
        #expect(try await reopened.asset(id: asset.id) == asset)
        let columnRows = try await reopened.query(sql: "PRAGMA table_info(profile_photo_assets);")
        #expect(try columnRows.map { try $0.text("name") } == ["id", "width", "height", "byte_count", "sha256"])
        let encoded = try JSONEncoder().encode(asset)
        #expect(try JSONDecoder().decode(ProfilePhotoAsset.self, from: encoded) == asset)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(fixture.directory.path))
    }

    @Test("Identical and changed metadata collide instead of replacing an existing identity")
    func immutableIdentity() async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let original = try photoAsset()
        try await store.insertAsset(original)
        let expected = RepositoryError.alreadyExists(entity: "profile photo asset", id: original.id.persistedValue)
        await #expect(throws: expected) { try await store.insertAsset(original) }
        let altered = try photoAsset(id: original.id, width: 128, height: 128, byteCount: 400, digest: String(repeating: "b", count: 64))
        await #expect(throws: expected) { try await store.insertAsset(altered) }
        let otherConnection = try fixture.open()
        await #expect(throws: expected) { try await otherConnection.insertAsset(altered) }
        #expect(try await otherConnection.asset(id: original.id) == original)
    }

    @Test("Dimensions and byte count enforce exact lower and upper bounds")
    func boundedMetadata() throws {
        _ = try photoAsset(width: 1, height: 1, byteCount: 1)
        _ = try photoAsset(width: 512, height: 512, byteCount: 4_194_304)
        for invalid in [-1, 0, 513, Int.max] {
            #expect(throws: DomainValidationError.self) { try photoAsset(width: invalid) }
            #expect(throws: DomainValidationError.self) { try photoAsset(height: invalid) }
        }
        for invalid in [-1, 0, 4_194_305, Int.max] {
            #expect(throws: DomainValidationError.self) { try photoAsset(byteCount: invalid) }
        }
    }

    @Test("Digests accept only exactly 64 lowercase ASCII hexadecimal characters")
    func digestValidation() throws {
        _ = try photoAsset(digest: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        for invalid in [
            String(repeating: "A", count: 64), String(repeating: "g", count: 64),
            String(repeating: "a", count: 63), String(repeating: "a", count: 65),
            " " + String(repeating: "a", count: 63), String(repeating: "０", count: 64),
            String(repeating: "a", count: 63) + "\0"
        ] {
            #expect(throws: DomainValidationError.self) { try photoAsset(digest: invalid) }
        }
    }

    @Test("Codable decoding cannot bypass metadata validation")
    func decoderValidation() throws {
        let encoded = try JSONEncoder().encode(photoAsset())
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, invalid) in [
            ("width", 0 as Any), ("height", 513 as Any),
            ("byteCount", 4_194_305 as Any), ("sha256", String(repeating: "A", count: 64) as Any)
        ] {
            var mutated = original
            mutated[key] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: mutated)
            #expect(throws: DomainValidationError.self) {
                try JSONDecoder().decode(ProfilePhotoAsset.self, from: bytes)
            }
        }
    }

    @Test("SQLite checks reject malformed metadata before publication")
    func databaseConstraints() async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let invalidRows: [(Int64, Int64, Int64, String)] = [
            (0, 1, 1, String(repeating: "a", count: 64)),
            (1, 513, 1, String(repeating: "a", count: 64)),
            (1, 1, 4_194_305, String(repeating: "a", count: 64)),
            (1, 1, 1, String(repeating: "A", count: 64)),
            (1, 1, 1, String(repeating: "a", count: 63))
        ]
        for row in invalidRows {
            await #expect(throws: SQLiteStoreError.self) {
                try await store.execute(
                    sql: "INSERT INTO profile_photo_assets(id,width,height,byte_count,sha256) VALUES (?,?,?,?,?);",
                    bindings: [.text(ProfileAssetID(UUID()).persistedValue), .integer(row.0), .integer(row.1), .integer(row.2), .text(row.3)]
                )
            }
        }
        #expect(try await store.query(sql: "SELECT COUNT(*) AS count FROM profile_photo_assets;").first?.integer("count") == 0)
    }

    @Test("Reading malformed stored metadata fails closed even if checks were bypassed", arguments: [
        "width", "height", "byte_count", "sha256"
    ])
    func malformedRows(column: String) async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let asset = try photoAsset()
        try await store.insertAsset(asset)
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=ON;")
        let changedValue: SQLiteBinding = column == "sha256" ? .text("not-a-digest") : .integer(0)
        // Column comes only from the four literal test arguments above.
        _ = try await store.execute(sql: "UPDATE profile_photo_assets SET \(column)=? WHERE id=?;", bindings: [changedValue, .text(asset.id.persistedValue)])
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=OFF;")
        await #expect(throws: DomainValidationError.self) { try await store.asset(id: asset.id) }
    }

    @Test("An aborted insert rolls back and leaves existing metadata unchanged")
    func insertRollback() async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let original = try photoAsset()
        let rejected = try photoAsset()
        try await store.insertAsset(original)
        _ = try await store.execute(sql: """
            CREATE TRIGGER injected_photo_insert_failure AFTER INSERT ON profile_photo_assets
            BEGIN SELECT RAISE(ABORT,'injected photo failure'); END;
            """)
        await #expect(throws: SQLiteStoreError.self) { try await store.insertAsset(rejected) }
        #expect(try await store.asset(id: rejected.id) == nil)
        #expect(try await store.asset(id: original.id) == original)
    }

    @Test("Stored digest cannot hide a malformed tail after a valid C-string prefix")
    func embeddedNullDigest() async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let asset = try photoAsset()
        try await store.insertAsset(asset)
        await #expect(throws: SQLiteStoreError.self) {
            try await store.execute(sql: "UPDATE profile_photo_assets SET sha256=sha256 || char(0) || 'hidden';")
        }
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=ON;")
        _ = try await store.execute(sql: "UPDATE profile_photo_assets SET sha256=sha256 || char(0) || 'hidden';")
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=OFF;")
        await #expect(throws: DomainValidationError.self) { try await store.asset(id: asset.id) }
    }

    @Test("Migration seven preserves version-six profiles and conversation contexts")
    func migrationPreservesExistingData() async throws {
        let fixture = try PhotoMetadataFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 10)
        let teammate = try Teammate(
            id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Aster", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 32, silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date
        )
        let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id), createdAt: date, updatedAt: date)
        let expectedContext = ConversationContextSelection(conversationID: conversation.id, teammateID: teammate.id, revision: 1)
        var earlierChecksums: [String] = []
        do {
            let store = try fixture.open()
            try await store.provisionDirectChat(teammate: teammate, conversation: conversation, fixtureGreeting: nil, selectConversation: true)
            _ = try await store.saveContext(ConversationContextSelection(conversationID: conversation.id, teammateID: teammate.id))
            earlierChecksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version <= 6 ORDER BY version;").map { try $0.text("checksum") }
            _ = try await store.execute(sql: "DROP TABLE profile_photo_assets;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=7;")
        }
        let reopened = try fixture.open()
        #expect(try await reopened.runtimeFacts().migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(try await reopened.teammate(id: teammate.id) == teammate)
        #expect(try await reopened.conversation(id: conversation.id) == conversation)
        #expect(try await reopened.loadContext(conversationID: conversation.id) == expectedContext)
        #expect(try await reopened.selectedConversationID() == conversation.id)
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version <= 6 ORDER BY version;").map { try $0.text("checksum") } == earlierChecksums)
        #expect(try await reopened.query(sql: "SELECT COUNT(*) AS count FROM profile_photo_assets;").first?.integer("count") == 0)
    }
}

private func photoAsset(
    id: ProfileAssetID = ProfileAssetID(UUID()), width: Int = 256, height: Int = 256,
    byteCount: Int = 1_024, digest: String = String(repeating: "a", count: 64)
) throws -> ProfilePhotoAsset {
    try ProfilePhotoAsset(id: id, width: width, height: height, byteCount: byteCount, sha256: digest)
}

private struct PhotoMetadataFixture {
    let directory: URL
    let receipt: ProtectionDecisionReceipt

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-photo-metadata-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
