import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

// A bot's seat is part of its profile: saved with it, read back by
// every path that reads a bot, kept in its revision history, carried through a
// profile edit and an archive round trip, and absent from every bot saved
// before seats existed.
struct SQLiteTeammateSeatTests {
    private static let seatColumns = ["seat_purview", "seat_never", "seat_interfaces", "seat_escalate"]

    @Test("Migration 28 keeps every existing bot and its history exactly, with no seat, and leaves earlier checksums alone")
    func migrationKeepsExistingRows() async throws {
        let fixture = try SeatSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate(seat: nil)
        let checksums: [String]
        do {
            let store = try fixture.open()
            try await store.insert(original)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=27 ORDER BY version;")
                .map { try $0.text("checksum") }
            // Only this synthetic database is rolled back to the schema before seats.
            for table in ["teammates", "teammate_profile_revisions"] {
                for column in Self.seatColumns {
                    _ = try await store.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column);")
                }
            }
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=28;")
        }
        let reopened = try fixture.open()
        let loaded = try #require(try await reopened.teammate(id: original.id))
        #expect(loaded == original)
        #expect(loaded.profile.seat == nil)
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=27 ORDER BY version;")
            .map { try $0.text("checksum") } == checksums)
        #expect(try await reopened.query(sql: "SELECT name FROM schema_migrations WHERE version=28;")
            .first?.text("name") == "teammate-seat")
        let history = try await reopened.query(sql: "SELECT seat_purview,seat_never,seat_interfaces,seat_escalate FROM teammate_profile_revisions;")
        #expect(history.count == 1)
        for column in Self.seatColumns { #expect(try history.first?.optionalText(column) == nil) }
    }

    @Test("Migration 29 keeps every existing bot exactly, with no hirer named on any profile, and leaves earlier checksums alone")
    func hirerMigrationKeepsExistingRows() async throws {
        let fixture = try SeatSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate(seat: TeammateSeat(purview: "Competitor prices"))
        let checksums: [String]
        do {
            let store = try fixture.open()
            try await store.insert(original)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=28 ORDER BY version;")
                .map { try $0.text("checksum") }
            // Only this synthetic database is rolled back to the schema before the hirer was kept.
            _ = try await store.execute(sql: "ALTER TABLE teammates DROP COLUMN profile_written_by_hirer;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=29;")
        }
        let reopened = try fixture.open()
        let loaded = try #require(try await reopened.teammate(id: original.id))
        #expect(loaded == original)
        #expect(loaded.profileWrittenByHirer == nil, "a bot saved before the column was made by the person")
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=28 ORDER BY version;")
            .map { try $0.text("checksum") } == checksums)
        #expect(try await reopened.query(sql: "SELECT name FROM schema_migrations WHERE version=29;")
            .first?.text("name") == "hired-profile-author")
    }

    /// A hired bot's role, instructions and seat come
    /// from another bot's reply. Until the person saves the profile, the app
    /// keeps who wrote them, so nothing presents them as the person's.
    @Test("A hired bot keeps who wrote its profile through a reopen, the roster, search, an archive round trip and a pin; the person's own save clears it")
    func hirerSurvivesUntilThePersonSaves() async throws {
        let fixture = try SeatSQLiteFixture()
        defer { fixture.remove() }
        var original = try fixture.teammate(seat: TeammateSeat(purview: "Competitor prices"))
        original.profileWrittenByHirer = "Kite"
        do {
            let store = try fixture.open()
            try await store.insert(original)
            let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: original.id),
                createdAt: original.createdAt, updatedAt: original.updatedAt)
            try await store.insert(conversation, participantIDs: [original.id])
        }
        let reopened = try fixture.open()
        #expect(try await reopened.teammate(id: original.id)?.profileWrittenByHirer == "Kite")
        #expect(try await reopened.listTeammates(includingArchived: true).first?.profileWrittenByHirer == "Kite")
        #expect(try await reopened.search(ConversationSearchRequest(query: "Scout")).teammates.first?.teammate.profileWrittenByHirer == "Kite")
        let archived = try await reopened.archiveTeammate(id: original.id, expectedProfileRevision: 1, now: Date(timeIntervalSince1970: 2_000))
        #expect(archived.profileWrittenByHirer == "Kite")
        let restored = try await reopened.restoreTeammate(id: original.id, expectedProfileRevision: 2, now: Date(timeIntervalSince1970: 3_000))
        #expect(restored.profileWrittenByHirer == "Kite")
        // A write that is not the person's profile save keeps it.
        var pinned = try #require(try await reopened.teammate(id: original.id))
        pinned.isPinned = true
        try await reopened.update(pinned, expectedProfileRevision: 3)
        #expect(try await reopened.teammate(id: original.id)?.profileWrittenByHirer == "Kite")

        // The person saves the profile, even changing only its effort: it is theirs now.
        let saved = try await TeammateProfileService(repository: reopened).saveProfile(teammateID: original.id,
            expectedRevision: 3, draft: TeammateProfileEditDraft(displayName: "Scout", role: "Price watching", claudeEffort: "low"))
        #expect(saved.profileWrittenByHirer == nil)
        #expect(try await fixture.open().teammate(id: original.id)?.profileWrittenByHirer == nil)
    }

    @Test("A seat is saved with the bot and read back by the roster, a reopen, search, a profile edit, the history and an archive round trip")
    func seatSurvivesEveryRead() async throws {
        let fixture = try SeatSQLiteFixture()
        defer { fixture.remove() }
        let seat = try TeammateSeat(purview: "Competitor prices", never: "Bookkeeping, which Ledger owns",
                                    interfaces: "Ledger, for costs", escalate: "Any spend")
        let original = try fixture.teammate(seat: seat)
        do {
            let store = try fixture.open()
            try await store.insert(original)
            let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: original.id),
                createdAt: original.createdAt, updatedAt: original.updatedAt)
            try await store.insert(conversation, participantIDs: [original.id])
            // The person's profile edit names no seat and keeps it.
            let service = TeammateProfileService(repository: store)
            _ = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: "Scout renamed", role: "Price watching"))
        }
        let reopened = try fixture.open()
        let loaded = try #require(try await reopened.teammate(id: original.id))
        #expect(loaded.profile.seat == seat)
        #expect(loaded.profile.revision == 2)
        #expect(try await reopened.listTeammates(includingArchived: true).first?.profile.seat == seat)
        #expect(try await reopened.search(ConversationSearchRequest(query: "renamed")).teammates.first?.teammate.profile.seat == seat)
        let history = try await reopened.query(sql: "SELECT revision,seat_purview,seat_never,seat_interfaces,seat_escalate FROM teammate_profile_revisions ORDER BY revision;")
        #expect(try history.map { try $0.optionalText("seat_purview") } == ["Competitor prices", "Competitor prices"])
        #expect(try history.map { try $0.optionalText("seat_never") } == ["Bookkeeping, which Ledger owns", "Bookkeeping, which Ledger owns"])
        #expect(try history.map { try $0.optionalText("seat_interfaces") } == ["Ledger, for costs", "Ledger, for costs"])
        #expect(try history.map { try $0.optionalText("seat_escalate") } == ["Any spend", "Any spend"])

        // A seat changed through the repository is saved, and one cleared is gone.
        var changed = loaded
        changed.profile = try loaded.profile.revised(seat: TeammateSeat(purview: "Supplier prices"))
        try await reopened.update(changed, expectedProfileRevision: 2)
        #expect(try await reopened.teammate(id: original.id)?.profile.seat == TeammateSeat(purview: "Supplier prices"))
        var cleared = try #require(try await reopened.teammate(id: original.id))
        cleared.profile = try cleared.profile.revised(seat: .some(nil))
        try await reopened.update(cleared, expectedProfileRevision: 3)
        #expect(try await reopened.teammate(id: original.id)?.profile.seat == nil)

        var seated = try #require(try await reopened.teammate(id: original.id))
        seated.profile = try seated.profile.revised(seat: seat)
        try await reopened.update(seated, expectedProfileRevision: 4)
        let archived = try await reopened.archiveTeammate(id: original.id, expectedProfileRevision: 5, now: Date(timeIntervalSince1970: 2_000))
        #expect(archived.profile.seat == seat)
        #expect(try await reopened.archivedTeammates().first?.profile.seat == seat)
        let restored = try await reopened.restoreTeammate(id: original.id, expectedProfileRevision: 6, now: Date(timeIntervalSince1970: 3_000))
        #expect(restored.profile.seat == seat)
        #expect(try await fixture.open().teammate(id: original.id)?.profile.seat == seat)
    }
}

private struct SeatSQLiteFixture {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("teammate-seat-\(UUID().uuidString).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("OpenBots.sqlite"),
            protection: .ordinarySQLite(decision: receipt)))
    }
    func teammate(seat: TeammateSeat?) throws -> Teammate {
        let now = Date(timeIntervalSince1970: 1_000)
        return try Teammate(id: TeammateID(UUID()),
            profile: TeammateProfile(displayName: "Scout", role: "Price watching", detailedInstructions: "Check daily.", seat: seat),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1,
                silhouette: "round", paletteToken: "sky", eyeDialect: "calm", nonColorIdentityCue: "crown",
                accessibleIdentityDescription: "Round creature"), createdAt: now, updatedAt: now)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
