import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Persistent composer drafts")
struct SQLiteConversationDraftRepositoryTests {
    @Test("Exact UTF-8 drafts survive reopen and remain isolated by conversation")
    func roundTripAndIsolation() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let firstText = "  \tHello\r\n\0after-null e\u{301} ☁️\n  "
        let secondText = "Unrelated composer\n"
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            #expect(try await store.loadDraft(conversationID: fixture.directID) == nil)
            _ = try await store.saveDraft(conversationID: fixture.directID, text: firstText, expectedRevision: 0, updatedAt: fixture.date)
            _ = try await store.saveDraft(conversationID: fixture.projectChatID, text: secondText, expectedRevision: 0, updatedAt: fixture.date)
        }
        let reopened = try fixture.open()
        let first = try #require(try await reopened.loadDraft(conversationID: fixture.directID))
        let second = try #require(try await reopened.loadDraft(conversationID: fixture.projectChatID))
        #expect(first.text.utf8.elementsEqual(firstText.utf8))
        #expect(second.text.utf8.elementsEqual(secondText.utf8))
        #expect(first.revision == 1 && second.revision == 1)
        #expect(first.updatedAt == fixture.date)
        #expect(try await reopened.loadDraft(conversationID: fixture.teamChatID) == nil)
        let columns = try await reopened.query(sql: "PRAGMA table_info(conversation_drafts);")
        #expect(try columns.map { try $0.text("name") } == ["conversation_id", "text", "revision", "updated_at"])
    }

    @Test("An empty draft is a persistent revisioned tombstone, not absence")
    func emptyTombstone() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        _ = try await store.saveDraft(conversationID: fixture.directID, text: "pending", expectedRevision: 0, updatedAt: fixture.date)
        let cleared = try await store.saveDraft(conversationID: fixture.directID, text: "", expectedRevision: 1, updatedAt: fixture.date.addingTimeInterval(1))
        #expect(cleared.text == "" && cleared.revision == 2)
        let reopened = try fixture.open()
        #expect(try await reopened.loadDraft(conversationID: fixture.directID) == cleared)
        await #expect(throws: ConversationDraftError.staleRevision) {
            try await reopened.saveDraft(conversationID: fixture.directID, text: "old text", expectedRevision: 1, updatedAt: fixture.date)
        }
        await #expect(throws: ConversationDraftError.staleRevision) {
            try await reopened.saveDraft(conversationID: fixture.directID, text: "pretend absent", expectedRevision: 0, updatedAt: fixture.date)
        }
        #expect(try await reopened.loadDraft(conversationID: fixture.directID) == cleared)
    }

    @Test("Direct, project and team conversations each support their own draft")
    func allConversationKinds() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        for conversationID in [fixture.directID, fixture.projectChatID, fixture.teamChatID] {
            let saved = try await store.saveDraft(conversationID: conversationID, text: conversationID.persistedValue, expectedRevision: 0, updatedAt: fixture.date)
            #expect(try await store.loadDraft(conversationID: conversationID) == saved)
        }
    }

    @Test("Two connections cannot both commit from the same expected revision")
    func concurrentCAS() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let first = try fixture.open()
        let second = try fixture.open()
        try await fixture.seed(first)
        let outcomes = await withTaskGroup(of: DraftWriteOutcome.self, returning: [DraftWriteOutcome].self) { group in
            for (store, text) in [(first, "first writer"), (second, "second writer")] {
                group.addTask {
                    do {
                        let saved = try await store.saveDraft(conversationID: fixture.directID, text: text, expectedRevision: 0, updatedAt: fixture.date)
                        return .saved(saved)
                    } catch ConversationDraftError.staleRevision {
                        return .stale
                    } catch {
                        Issue.record("Unexpected draft write failure: \(type(of: error))")
                        return .unexpected
                    }
                }
            }
            var outcomes: [DraftWriteOutcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        let successes = outcomes.compactMap { if case let .saved(snapshot) = $0 { snapshot } else { nil } }
        #expect(successes.count == 1)
        #expect(outcomes.filter { if case .stale = $0 { true } else { false } }.count == 1)
        #expect(try await first.loadDraft(conversationID: fixture.directID) == successes.first)
    }

    @Test("Missing or archived conversations reject reads and writes without changing data")
    func conversationValidation() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let missing = ConversationID(UUID())
        await #expect(throws: ConversationDraftError.conversationNotFound) { try await store.loadDraft(conversationID: missing) }
        await #expect(throws: ConversationDraftError.conversationNotFound) {
            try await store.saveDraft(conversationID: missing, text: "missing", expectedRevision: 0, updatedAt: fixture.date)
        }
        let saved = try await store.saveDraft(conversationID: fixture.directID, text: "preserve", expectedRevision: 0, updatedAt: fixture.date)
        _ = try await store.execute(sql: "UPDATE conversations SET lifecycle='archived' WHERE id=?;", bindings: [.text(fixture.directID.persistedValue)])
        await #expect(throws: ConversationDraftError.conversationArchived) { try await store.loadDraft(conversationID: fixture.directID) }
        await #expect(throws: ConversationDraftError.conversationArchived) {
            try await store.saveDraft(conversationID: fixture.directID, text: "overwrite", expectedRevision: 1, updatedAt: fixture.date)
        }
        _ = try await store.execute(sql: "UPDATE conversations SET lifecycle='active' WHERE id=?;", bindings: [.text(fixture.directID.persistedValue)])
        #expect(try await store.loadDraft(conversationID: fixture.directID) == saved)
    }

    @Test("UTF-8 byte bounds are inclusive and never replace an existing draft on failure")
    func textBounds() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let exactLimit = String(repeating: "🐙", count: ConversationDraftSnapshot.maximumUTF8ByteCount / 4)
        #expect(exactLimit.utf8.count == 1_048_576)
        let saved = try await store.saveDraft(conversationID: fixture.directID, text: exactLimit, expectedRevision: 0, updatedAt: fixture.date)
        #expect(try await store.loadDraft(conversationID: fixture.directID)?.text.utf8.elementsEqual(exactLimit.utf8) == true)
        await #expect(throws: DomainValidationError.self) {
            try await store.saveDraft(conversationID: fixture.directID, text: exactLimit + "x", expectedRevision: 1, updatedAt: fixture.date)
        }
        #expect(try await store.loadDraft(conversationID: fixture.directID) == saved)
    }

    @Test("Snapshot decoding validates bounds, positive revision and finite timestamps")
    func domainValidation() throws {
        let id = ConversationID(UUID())
        let date = Date(timeIntervalSince1970: 100)
        for revision in [UInt64(0), UInt64.max] {
            #expect(throws: ConversationDraftError.invalidRevision) {
                try ConversationDraftSnapshot(conversationID: id, text: "", revision: revision, updatedAt: date)
            }
        }
        for invalid in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(throws: ConversationDraftError.invalidTimestamp) {
                try ConversationDraftSnapshot(conversationID: id, text: "", revision: 1, updatedAt: Date(timeIntervalSince1970: invalid))
            }
        }
        let original = try ConversationDraftSnapshot(conversationID: id, text: " \0 e\u{301}\n", revision: 1, updatedAt: date)
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ConversationDraftSnapshot.self, from: encoded) == original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["revision"] = 0
        #expect(throws: ConversationDraftError.invalidRevision) {
            try JSONDecoder().decode(ConversationDraftSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object["revision"] = 1
        object["text"] = String(repeating: "x", count: ConversationDraftSnapshot.maximumUTF8ByteCount + 1)
        #expect(throws: DomainValidationError.self) {
            try JSONDecoder().decode(ConversationDraftSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let decomposed = try ConversationDraftSnapshot(conversationID: id, text: "e\u{301}", revision: 1, updatedAt: date)
        let precomposed = try ConversationDraftSnapshot(conversationID: id, text: "é", revision: 1, updatedAt: date)
        #expect(decomposed != precomposed)
    }

    @Test("Invalid revision and timestamp cannot mutate or overflow a saved draft")
    func invalidWriteMetadata() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let saved = try await store.saveDraft(conversationID: fixture.directID, text: "retain", expectedRevision: 0, updatedAt: fixture.date)
        for revision in [UInt64(Int64.max), UInt64.max] {
            await #expect(throws: ConversationDraftError.invalidRevision) {
                try await store.saveDraft(conversationID: fixture.directID, text: "overflow", expectedRevision: revision, updatedAt: fixture.date)
            }
        }
        await #expect(throws: ConversationDraftError.invalidTimestamp) {
            try await store.saveDraft(conversationID: fixture.directID, text: "bad clock", expectedRevision: 1, updatedAt: Date(timeIntervalSince1970: .infinity))
        }
        #expect(try await store.loadDraft(conversationID: fixture.directID) == saved)
    }

    @Test("An aborted draft update rolls back exact text and revision")
    func rollback() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let saved = try await store.saveDraft(conversationID: fixture.directID, text: "original\0tail", expectedRevision: 0, updatedAt: fixture.date)
        _ = try await store.execute(sql: "CREATE TRIGGER draft_failure AFTER UPDATE ON conversation_drafts BEGIN SELECT RAISE(ABORT,'injected draft failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.saveDraft(conversationID: fixture.directID, text: "new", expectedRevision: 1, updatedAt: fixture.date)
        }
        #expect(try await store.loadDraft(conversationID: fixture.directID) == saved)
    }

    @Test("Malformed stored drafts fail closed instead of being returned or overwritten")
    func malformedRows() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        _ = try await store.saveDraft(conversationID: fixture.directID, text: "valid", expectedRevision: 0, updatedAt: fixture.date)
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=ON;")
        _ = try await store.execute(sql: "UPDATE conversation_drafts SET revision=0;")
        await #expect(throws: ConversationDraftError.invalidRevision) { try await store.loadDraft(conversationID: fixture.directID) }
        await #expect(throws: ConversationDraftError.invalidRevision) {
            try await store.saveDraft(conversationID: fixture.directID, text: "overwrite", expectedRevision: 0, updatedAt: fixture.date)
        }
        _ = try await store.execute(sql: "UPDATE conversation_drafts SET revision=1,text=?;", bindings: [.text(String(repeating: "x", count: 1_048_577))])
        await #expect(throws: DomainValidationError.self) { try await store.loadDraft(conversationID: fixture.directID) }
        _ = try await store.execute(sql: "UPDATE conversation_drafts SET text='valid',updated_at=1e999;")
        await #expect(throws: ConversationDraftError.invalidTimestamp) { try await store.loadDraft(conversationID: fixture.directID) }
    }

    @Test("Migration eight preserves existing profile photo metadata and saved context")
    func migrationPreservation() async throws {
        let fixture = try DraftStoreFixture()
        defer { fixture.remove() }
        let photo = try ProfilePhotoAsset(id: ProfileAssetID(UUID()), width: 64, height: 64, byteCount: 128, sha256: String(repeating: "a", count: 64))
        var context: ConversationContextSelection?
        var checksums: [String] = []
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            try await store.insertAsset(photo)
            context = try await store.saveContext(ConversationContextSelection(conversationID: fixture.directID, teammateID: fixture.teammateID, projectID: fixture.projectID))
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=7 ORDER BY version;").map { try $0.text("checksum") }
            _ = try await store.execute(sql: "DROP TABLE conversation_drafts;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=8;")
        }
        let reopened = try fixture.open()
        #expect(try await reopened.runtimeFacts().migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(try await reopened.asset(id: photo.id) == photo)
        #expect(try await reopened.loadContext(conversationID: fixture.directID) == context)
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=7 ORDER BY version;").map { try $0.text("checksum") } == checksums)
        #expect(try await reopened.loadDraft(conversationID: fixture.directID) == nil)
        #expect(try await reopened.teammate(id: fixture.teammateID)?.profile.displayName == "Draft Keeper")
    }
}

private enum DraftWriteOutcome: Sendable {
    case saved(ConversationDraftSnapshot)
    case stale
    case unexpected
}

private struct DraftStoreFixture: Sendable {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_000)
    let teammateID = TeammateID(UUID())
    let directID = ConversationID(UUID())
    let projectID = ProjectID(UUID())
    let projectChatID = ConversationID(UUID())
    let teamID = TeamID(UUID())
    let teamChatID = ConversationID(UUID())

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-draft-tests-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(
            id: teammateID, profile: TeammateProfile(displayName: "Draft Keeper", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date
        )
        try await store.provisionDirectChat(teammate: teammate, conversation: Conversation(id: directID, kind: .direct(teammateID: teammateID), createdAt: date, updatedAt: date), fixtureGreeting: nil, selectConversation: false)
        try await store.provisionProject(Project(id: projectID, name: "Project Drafts", createdAt: date, updatedAt: date), initialMemberIDs: [teammateID])
        try await store.insert(Team(id: teamID, name: "Team Drafts", leadID: teammateID, memberIDs: [teammateID], createdAt: date, updatedAt: date))
        try await store.insert(Conversation(id: projectChatID, kind: .project(projectID: projectID), createdAt: date, updatedAt: date), participantIDs: [teammateID])
        try await store.insert(Conversation(id: teamChatID, kind: .team(teamID: teamID), createdAt: date, updatedAt: date), participantIDs: [teammateID])
    }
}
