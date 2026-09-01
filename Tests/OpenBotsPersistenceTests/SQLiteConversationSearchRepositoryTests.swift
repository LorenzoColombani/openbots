import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Bounded local conversation search")
struct SQLiteConversationSearchRepositoryTests {
    @Test("Requests reject empty, overlong and excessive terms or results")
    func requestBounds() throws {
        for query in ["", " \n\t", String(repeating: "x", count: 201), "a b c d e f g h i", "a\0b", "x" + String(repeating: "\u{301}", count: 4_096)] {
            #expect(throws: DomainValidationError.self) { try ConversationSearchRequest(query: query) }
        }
        for limit in [0, -1, 51, Int.max] {
            #expect(throws: DomainValidationError.self) { try ConversationSearchRequest(query: "valid", limit: limit) }
        }
        let exact = try ConversationSearchRequest(query: String(repeating: "🐙", count: 200), limit: 50)
        #expect(exact.terms.count == 1 && exact.limit == 50)
        #expect(try ConversationSearchRequest(query: "  alpha\n beta\t").terms == ["alpha", "beta"])
    }

    @Test("Search survives reopen, keeps direct identities, and resolves current titles")
    func roundTrip() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let messageID: MessageID
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            messageID = try await fixture.append(store, text: "Research comet trajectories", author: .teammate(fixture.teammateID)).id
        }
        let reopened = try fixture.open()
        let page = try await reopened.search(ConversationSearchRequest(query: "research"))
        #expect(page.teammates.map(\.teammate.id) == [fixture.teammateID])
        #expect(page.teammates.first?.conversationID == fixture.conversationID)
        let hit = try #require(page.messages.first)
        #expect(hit.id == messageID && hit.conversationID == fixture.conversationID)
        #expect(hit.teammateID == fixture.teammateID && hit.teammateName == "Ada Search")
        #expect(hit.author == .teammate(fixture.teammateID) && hit.authorName == "Ada Search")
        #expect(hit.snippet.contains("comet") && hit.sequence == 1 && hit.createdAt == fixture.date)
        #expect(!page.hasMoreTeammates && !page.hasMoreMessages)
        _ = try await reopened.execute(sql: "UPDATE conversations SET title='Renamed conversation' WHERE id=?;", bindings: [.text(fixture.conversationID.persistedValue)])
        let target = try #require(try await reopened.resolveMessage(id: messageID))
        #expect(target.currentTitle == "Renamed conversation" && target.sequence == 1)
        #expect(target.conversationID == fixture.conversationID && target.teammateID == fixture.teammateID)
        #expect(try await reopened.resolveMessage(id: MessageID(UUID())) == nil)
        // Schema trust follows the linked SQLite: OFF once FTS5 may run inside triggers (>= 3.44.0),
        // ON on the older system libraries of macOS 14/15. See SQLiteSchemaTrust.
        let expectedTrust: Int64 = SQLiteSchemaTrust.requiresTrustedSchema(
            libraryVersionNumber: SQLiteSchemaTrust.linkedLibraryVersionNumber) ? 1 : 0
        #expect(try await reopened.query(sql: "PRAGMA trusted_schema;").first?.integer("trusted_schema") == expectedTrust)
    }

    @Test("Migration nine backfills ordered text without changing prior durable state")
    func migrationBackfill() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        var checksums: [String] = []
        let messageID: MessageID
        let draft: ConversationDraftSnapshot
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            let message = try fixture.message(parts: [.text("second"), .text("first")], ordinals: [1, 0])
            try await store.append(message, expectedPreviousSequence: 0)
            messageID = message.id
            draft = try await store.saveDraft(conversationID: fixture.conversationID, text: "private draft never index", expectedRevision: 0, updatedAt: fixture.date)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=8 ORDER BY version;").map { try $0.text("checksum") }
            try await store.removeSearchMigrationForTest()
        }
        let reopened = try fixture.open()
        #expect(try await reopened.runtimeFacts().migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(try await reopened.loadDraft(conversationID: fixture.conversationID) == draft)
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=8 ORDER BY version;").map { try $0.text("checksum") } == checksums)
        let page = try await reopened.search(ConversationSearchRequest(query: "first second"))
        #expect(page.messages.map(\.id) == [messageID])
        #expect(page.messages.first?.snippet == "first second")
        #expect(try await reopened.query(sql: "SELECT count(*) AS total FROM conversation_message_search;").first?.integer("total") == 1)
        #expect(try await reopened.search(ConversationSearchRequest(query: "private")).messages.isEmpty)
    }

    @Test("Literal query terms cannot inject FTS operators, prefixes or profile wildcards")
    func literalTerms() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let literal = try await fixture.append(store, text: "alpha OR beta near quoted word")
        _ = try await fixture.append(store, text: "alphabet beta", sequence: 2)
        #expect(try await store.search(ConversationSearchRequest(query: "alpha OR beta")).messages.map(\.id) == [literal.id])
        #expect(try await store.search(ConversationSearchRequest(query: "alpha*")).messages.map(\.id) == [literal.id])
        #expect(try await store.search(ConversationSearchRequest(query: "\"alpha\"")).messages.map(\.id) == [literal.id])
        for query in ["*", "\"", "-", "NEAR(alpha,beta)", "alpha OR missing", "' OR 1=1 --"] {
            #expect(try await store.search(ConversationSearchRequest(query: query)).messages.isEmpty)
        }
        for query in ["%", "_", "\\", "' OR"] {
            #expect(try await store.search(ConversationSearchRequest(query: query)).teammates.isEmpty)
        }
        _ = try await store.execute(sql: "UPDATE teammates SET title='100%_literal\\title' WHERE id=?;", bindings: [.text(fixture.teammateID.persistedValue)])
        for query in ["%", "_", "\\"] {
            #expect(try await store.search(ConversationSearchRequest(query: query)).teammates.map(\.id) == [fixture.teammateID])
        }
    }

    @Test("Whole words use unicode61 case and accent matching, not implicit prefixes")
    func wordSemantics() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let found = try await fixture.append(store, text: "CAFÉ orbit")
        _ = try await fixture.append(store, text: "orbital cafeteria", sequence: 2)
        #expect(try await store.search(ConversationSearchRequest(query: "cafe orbit")).messages.map(\.id) == [found.id])
        #expect(try await store.search(ConversationSearchRequest(query: "orb")).messages.isEmpty)
        #expect(try await store.search(ConversationSearchRequest(query: "ada research")).teammates.map(\.id) == [fixture.teammateID])
        #expect(try await store.search(ConversationSearchRequest(query: "ada unavailable")).teammates.isEmpty)
    }

    @Test("Part inserts, updates, moves, classification changes and deletes update one index row")
    func triggerMaintenance() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let first = try await fixture.append(store, text: "obsolete")
        let second = try await fixture.append(store, text: "destination", sequence: 2)
        _ = try await store.execute(sql: "UPDATE message_parts SET text_value='replacement' WHERE id=?;", bindings: [.text(first.parts[0].id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "obsolete")).messages.isEmpty)
        #expect(try await store.search(ConversationSearchRequest(query: "replacement")).messages.map(\.id) == [first.id])
        _ = try await store.execute(sql: "UPDATE message_parts SET message_id=?,ordinal=1 WHERE id=?;", bindings: [.text(second.id.persistedValue), .text(first.parts[0].id.persistedValue)])
        #expect(try await store.resolveMessage(id: first.id) == nil)
        #expect(try await store.search(ConversationSearchRequest(query: "replacement")).messages.map(\.id) == [second.id])
        #expect(try await store.query(sql: "SELECT count(*) AS total FROM conversation_message_search;").first?.integer("total") == 1)
        _ = try await store.execute(sql: "UPDATE messages SET output_class='workAudit' WHERE id=?;", bindings: [.text(second.id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "destination")).messages.isEmpty)
        _ = try await store.execute(sql: "UPDATE messages SET output_class='conversation' WHERE id=?;", bindings: [.text(second.id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "destination")).messages.map(\.id) == [second.id])
        _ = try await store.execute(sql: "UPDATE messages SET author_kind='system' WHERE id=?;", bindings: [.text(second.id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "destination")).messages.isEmpty)
        _ = try await store.execute(sql: "UPDATE messages SET author_kind='user' WHERE id=?;", bindings: [.text(second.id.persistedValue)])
        _ = try await store.execute(sql: "UPDATE message_parts SET kind='status' WHERE id=?;", bindings: [.text(first.parts[0].id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "replacement")).messages.isEmpty)
        _ = try await store.execute(sql: "DELETE FROM messages WHERE id=?;", bindings: [.text(second.id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "destination")).messages.isEmpty)
        #expect(try await store.resolveMessage(id: second.id) == nil)
        #expect(try await store.query(sql: "SELECT count(*) AS total FROM conversation_message_search;").first?.integer("total") == 0)
    }

    @Test("Ordered snippets follow part ordinals and individual text deletion")
    func partOrderAndDelete() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try fixture.message(parts: [.text("alpha"), .text("beta")])
        try await store.append(message, expectedPreviousSequence: 0)
        _ = try await store.execute(sql: "UPDATE message_parts SET ordinal=2 WHERE id=?;", bindings: [.text(message.parts[0].id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "alpha beta")).messages.first?.snippet == "beta alpha")
        _ = try await store.execute(sql: "DELETE FROM message_parts WHERE id=?;", bindings: [.text(message.parts[0].id.persistedValue)])
        #expect(try await store.search(ConversationSearchRequest(query: "alpha")).messages.isEmpty)
        #expect(try await store.search(ConversationSearchRequest(query: "beta")).messages.map(\.id) == [message.id])
        _ = try await store.execute(sql: "DELETE FROM message_parts WHERE id=?;", bindings: [.text(message.parts[1].id.persistedValue)])
        #expect(try await store.resolveMessage(id: message.id) == nil)
        #expect(try await store.query(sql: "SELECT count(*) AS total FROM conversation_message_search;").first?.integer("total") == 0)
    }

    @Test("Invalid search metadata is rejected rather than used as a jump target")
    func malformedMetadata() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try await fixture.append(store, text: "malformed")
        _ = try await store.execute(sql: "UPDATE messages SET sequence=? WHERE id=?;", bindings: [.integer(Int64.max), .text(message.id.persistedValue)])
        await #expect(throws: SQLiteStoreError.self) { try await store.resolveMessage(id: message.id) }
        await #expect(throws: SQLiteStoreError.self) { try await store.search(ConversationSearchRequest(query: "malformed")) }
        _ = try await store.execute(sql: "UPDATE messages SET sequence=1,created_at=1e999,updated_at=1e999 WHERE id=?;", bindings: [.text(message.id.persistedValue)])
        await #expect(throws: SQLiteStoreError.self) { try await store.search(ConversationSearchRequest(query: "malformed")) }
    }

    @Test("Index updates roll back with the failed message mutation")
    func transactionalRollback() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try await fixture.append(store, text: "original")
        await #expect(throws: SearchRollback.self) {
            try await store.rollbackSearchMutation(partID: message.parts[0].id)
        }
        #expect(try await store.search(ConversationSearchRequest(query: "original")).messages.map(\.id) == [message.id])
        #expect(try await store.search(ConversationSearchRequest(query: "uncommitted")).messages.isEmpty)
    }

    @Test("Drafts, status, system, audit, artifact and profile-instruction text are not indexed")
    func privateAndNonConversationExclusions() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let ordinary = try await fixture.append(store, text: "ordinary needle")
        let records: [(OutputClass, MessageAuthor, MessagePartContent)] = [
            (.conversation, .user, .status("statusneedle")),
            (.conversation, .system, .text("systemneedle")),
            (.workAudit, .user, .text("auditneedle")),
            (.artifact, .user, .text("artifactneedle"))
        ]
        for (offset, record) in records.enumerated() {
            let message = try fixture.message(parts: [record.2], sequence: Int64(offset + 2), author: record.1, output: record.0)
            try await store.append(message, expectedPreviousSequence: message.sequence - 1)
            #expect(try await store.resolveMessage(id: message.id) == nil)
        }
        _ = try await store.saveDraft(conversationID: fixture.conversationID, text: "draftsecretneedle", expectedRevision: 0, updatedAt: fixture.date)
        _ = try await store.execute(sql: "UPDATE teammates SET detailed_instructions='instructionsecretneedle' WHERE id=?;", bindings: [.text(fixture.teammateID.persistedValue)])
        for query in ["statusneedle", "systemneedle", "auditneedle", "artifactneedle", "draftsecretneedle", "instructionsecretneedle"] {
            let page = try await store.search(ConversationSearchRequest(query: query))
            #expect(page.messages.isEmpty && page.teammates.isEmpty)
        }
        #expect(try await store.query(sql: "SELECT message_id FROM conversation_message_search;").map { try $0.text("message_id") } == [ordinary.id.persistedValue])
    }

    @Test("Hidden, archived, missing exact participant and non-direct chats fail fresh resolution", arguments: SearchExclusion.allCases)
    fileprivate func activeScope(exclusion: SearchExclusion) async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try await fixture.append(store, text: "research visible")
        #expect(try await store.search(ConversationSearchRequest(query: "research")).messages.count == 1)
        try await exclusion.apply(store, fixture: fixture)
        let page = try await store.search(ConversationSearchRequest(query: "research"))
        #expect(page.teammates.isEmpty && page.messages.isEmpty)
        #expect(try await store.resolveMessage(id: message.id) == nil)
    }

    @Test("Two visible direct chats retain distinct IDs, authors and bounded result flags")
    func isolationAndLimits() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let otherID = TeammateID(UUID())
        let otherConversationID = ConversationID(UUID())
        try await fixture.seed(store, teammateID: otherID, conversationID: otherConversationID, name: "Mira Search")
        let first = try await fixture.append(store, text: "shared match", author: .teammate(otherID))
        let second = try fixture.message(parts: [.text("shared match")], conversationID: otherConversationID)
        try await store.append(second, expectedPreviousSequence: 0)
        let one = try await store.search(ConversationSearchRequest(query: "search", limit: 1))
        #expect(one.teammates.count == 1 && one.hasMoreTeammates)
        let messages = try await store.search(ConversationSearchRequest(query: "shared", limit: 1))
        #expect(messages.messages.count == 1 && messages.hasMoreMessages)
        let both = try await store.search(ConversationSearchRequest(query: "shared", limit: 2))
        #expect(Set(both.messages.map(\.id)) == [first.id, second.id] && !both.hasMoreMessages)
        let firstHit = try #require(both.messages.first { $0.id == first.id })
        #expect(firstHit.teammateID == fixture.teammateID && firstHit.author == .teammate(otherID))
        #expect(firstHit.authorName == "Mira Search")
    }

    @Test("Ten thousand saved messages use FTS and materialize only bounded result snippets")
    func boundedVolume() async throws {
        let fixture = try SearchStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await store.seedSearchVolume(conversationID: fixture.conversationID)
        let started = ContinuousClock.now
        let page = try await store.search(ConversationSearchRequest(query: "volume", limit: 30))
        let duration = started.duration(to: .now)
        #expect(page.messages.count == 30 && page.hasMoreMessages)
        #expect(page.messages.allSatisfy { $0.snippet.count <= 500 })
        #expect(try await store.query(sql: "SELECT count(*) AS total FROM conversation_message_search;").first?.integer("total") == 10_000)
        let plan = try await store.query(sql: "EXPLAIN QUERY PLAN SELECT rowid FROM conversation_message_search WHERE conversation_message_search MATCH ? LIMIT 31;", bindings: [.text("\"volume\"")])
        #expect(try plan.contains { try $0.text("detail").contains("VIRTUAL TABLE INDEX") })
        print("Search diagnostic: 10,000 indexed messages, 30 returned in \(duration); no wall-clock pass threshold.")
    }
}

private enum SearchRollback: Error { case injected }

private enum SearchExclusion: CaseIterable, Sendable {
    case hidden, archivedTeammate, pendingArchive, archivedConversation, leftParticipant, wrongParticipant, projectConversation

    func apply(_ store: SQLiteStore, fixture: SearchStoreFixture) async throws {
        let sql: String
        let bindings: [SQLiteBinding]
        switch self {
        case .hidden: sql = "UPDATE teammates SET is_hidden=1 WHERE id=?;"; bindings = [.text(fixture.teammateID.persistedValue)]
        case .archivedTeammate: sql = "UPDATE teammates SET lifecycle='archived' WHERE id=?;"; bindings = [.text(fixture.teammateID.persistedValue)]
        case .pendingArchive: sql = "UPDATE teammates SET lifecycle='archivePendingRunResolution' WHERE id=?;"; bindings = [.text(fixture.teammateID.persistedValue)]
        case .archivedConversation: sql = "UPDATE conversations SET lifecycle='archived' WHERE id=?;"; bindings = [.text(fixture.conversationID.persistedValue)]
        case .leftParticipant: sql = "UPDATE conversation_participants SET left_at=2000 WHERE conversation_id=?;"; bindings = [.text(fixture.conversationID.persistedValue)]
        case .wrongParticipant:
            let other = TeammateID(UUID())
            try await fixture.seed(store, teammateID: other, conversationID: ConversationID(UUID()), name: "Different")
            // An unrelated active participant cannot substitute for the conversation's subject.
            sql = "UPDATE conversation_participants SET teammate_id=? WHERE conversation_id=?;"
            bindings = [.text(other.persistedValue), .text(fixture.conversationID.persistedValue)]
        case .projectConversation: sql = "UPDATE conversations SET kind='project' WHERE id=?;"; bindings = [.text(fixture.conversationID.persistedValue)]
        }
        _ = try await store.execute(sql: sql, bindings: bindings)
    }
}

private struct SearchStoreFixture: Sendable {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_000)
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-search-tests-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func seed(_ store: SQLiteStore, teammateID: TeammateID? = nil, conversationID: ConversationID? = nil, name: String = "Ada Search") async throws {
        let id = teammateID ?? self.teammateID
        let teammate = try Teammate(
            id: id, profile: TeammateProfile(displayName: name, title: "Scientist", role: name == "Different" ? "Other" : "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date
        )
        try await store.provisionDirectChat(teammate: teammate, conversation: Conversation(id: conversationID ?? self.conversationID, kind: .direct(teammateID: id), createdAt: date, updatedAt: date), fixtureGreeting: nil, selectConversation: false)
    }

    func message(parts: [MessagePartContent], ordinals: [Int]? = nil, sequence: Int64 = 1, author: MessageAuthor = .user, output: OutputClass = .conversation, conversationID: ConversationID? = nil) throws -> Message {
        try Message(
            id: MessageID(UUID()), conversationID: conversationID ?? self.conversationID, sequence: sequence,
            author: author, outputClass: output, deliveryState: .completed,
            parts: parts.enumerated().map { try MessagePart(id: MessagePartID(UUID()), ordinal: ordinals?[$0.offset] ?? $0.offset, content: $0.element) },
            createdAt: date, updatedAt: date
        )
    }

    @discardableResult func append(_ store: SQLiteStore, text: String, sequence: Int64 = 1, author: MessageAuthor = .user) async throws -> Message {
        let message = try message(parts: [.text(text)], sequence: sequence, author: author)
        try await store.append(message, expectedPreviousSequence: sequence - 1)
        return message
    }
}

private extension SQLiteStore {
    func removeSearchMigrationForTest() throws {
        try transaction {
            for suffix in ["message_insert", "message_delete", "message_update", "part_insert", "part_delete", "part_update"] {
                _ = try execute(sql: "DROP TRIGGER conversation_search_\(suffix);")
            }
            _ = try execute(sql: "DROP VIEW conversation_search_documents;")
            _ = try execute(sql: "DROP TABLE conversation_message_search;")
            _ = try execute(sql: "DELETE FROM schema_migrations WHERE version=9;")
        }
    }

    func rollbackSearchMutation(partID: MessagePartID) throws {
        try transaction {
            _ = try execute(sql: "UPDATE message_parts SET text_value='uncommitted' WHERE id=?;", bindings: [.text(partID.persistedValue)])
            throw SearchRollback.injected
        }
    }

    func seedSearchVolume(conversationID: ConversationID) throws {
        try transaction {
            _ = try execute(sql: """
                WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<10000)
                INSERT INTO messages(id,conversation_id,sequence,author_kind,author_teammate_id,output_class,delivery_state,created_at,updated_at)
                SELECT printf('10000000-0000-0000-0000-%012d',n),?,n,'user',NULL,'conversation','completed',n,n FROM numbers;
                """, bindings: [.text(conversationID.persistedValue)])
            _ = try execute(sql: """
                INSERT INTO message_parts(id,message_id,ordinal,kind,text_value,referenced_id)
                SELECT printf('20000000-0000-0000-0000-%012d',sequence),id,0,'text',
                    'volume ' || sequence || ' ' || replace(hex(zeroblob(350)),'0','x'),NULL
                FROM messages WHERE conversation_id=?;
                """, bindings: [.text(conversationID.persistedValue)])
        }
    }
}
