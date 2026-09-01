import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

@Suite("Persistent bot sidebar order")
struct SQLiteBotSidebarOrderTests {
    @Test("Schema 13 initializes former pin/recency order and current schema preserves moves on two real reopens")
    func migrationAndReopen() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        var expected: [TeammateID] = []
        var preserved: [String: [String]] = [:]
        var earlierChecksums: [String] = []
        weak var closed: SQLiteStore?
        do {
            let store = try f.open(); closed = store
            let a = try await f.seed(store, number: 1, pinned: false, recency: 30, content: true)
            let b = try await f.seed(store, number: 2, pinned: true, recency: 10, content: true)
            let c = try await f.seed(store, number: 3, pinned: false, recency: 20, content: true)
            expected = [b.id, a.id, c.id]
            earlierChecksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=13 ORDER BY version;")
                .map { try $0.text("checksum") }
            try await f.removeOrderingMigrationFromSyntheticStore(store)
            // The prior schema permits repeated active membership records.
            // Its EXISTS-based chat loader still displayed each bot only once.
            _ = try await store.execute(sql: """
                INSERT INTO conversation_participants(conversation_id,teammate_id,joined_at,left_at)
                VALUES (?,?,10001,NULL);
                """, bindings: [.text(f.conversationID(1).persistedValue), .text(a.id.persistedValue)])
            preserved = try await f.contentRows(store)
        }
        #expect(closed == nil)
        var saved: BotSidebarOrder!
        do {
            let migrated = try f.open(); closed = migrated
            let initial = try await migrated.loadBotSidebarOrder()
            #expect(initial.teammateIDs == expected)
            #expect(initial.revision == 1)
            #expect(try await migrated.runtimeFacts().migrationCount == SchemaMigrator.migrations.count)
            #expect(try await migrated.integrityCheck())
            #expect(try await f.contentRows(migrated) == preserved)
            #expect(try await migrated.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=13 ORDER BY version;")
                .map { try $0.text("checksum") } == earlierChecksums)
            saved = try await BotSidebarOrderService(repository: migrated).saveOrder(Array(expected.reversed()), expectedRevision: initial.revision)
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.loadBotSidebarOrder() == saved)
        #expect(try await f.chatService(reopened).activeDirectChats().map(\.teammate.id) == saved.teammateIDs)
        #expect(try await f.contentRows(reopened) == preserved)
        #expect(try await reopened.integrityCheck())
    }

    @Test("Empty, adjacent, reverse and unchanged orders preserve content and independent selection")
    func permutationsPreserveEveryOtherRow() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        let empty = try await store.loadBotSidebarOrder()
        #expect(try await store.saveBotSidebarOrder([], expectedRevision: empty.revision) == empty)
        let a = try await f.seed(store, number: 1, pinned: true, content: true)
        let single = try await store.loadBotSidebarOrder()
        #expect(try await store.saveBotSidebarOrder([a.id], expectedRevision: single.revision) == single)
        let b = try await f.seed(store, number: 2, content: true)
        let c = try await f.seed(store, number: 3, content: true)
        let before = try await f.contentRows(store)
        let service = BotSidebarOrderService(repository: store)
        let initial = try await service.loadOrder()
        #expect(initial.teammateIDs == [c.id, b.id, a.id])
        let adjacent = try await service.saveOrder([b.id, a.id, c.id], expectedRevision: initial.revision)
        #expect(adjacent.revision == initial.revision + 1)
        let reversed = try await service.saveOrder([c.id, a.id, b.id], expectedRevision: adjacent.revision)
        #expect(try await service.saveOrder(reversed.teammateIDs, expectedRevision: reversed.revision) == reversed)
        #expect(try await f.chatService(store).activeDirectChats().map(\.teammate.id) == reversed.teammateIDs)
        #expect(try await f.contentRows(store) == before)
        #expect(try await store.selectedConversationID() == f.conversationID(3))
    }

    @Test("Messages, pin changes and profile edits do not override manual order")
    func recencyAndProfileDoNotResort() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        var a = try await f.seed(store, number: 1)
        let b = try await f.seed(store, number: 2, pinned: true)
        let initial = try await store.loadBotSidebarOrder()
        let ordered = try await store.saveBotSidebarOrder([b.id, a.id], expectedRevision: initial.revision)
        try await store.append(f.message(number: 1, recency: 1_000), expectedPreviousSequence: 0)
        a.isPinned = true
        a.profile = try a.profile.revised(displayName: "Edited, still in place")
        a.updatedAt = f.at(2_000)
        try await store.update(a, expectedProfileRevision: 1)
        #expect(try await store.loadBotSidebarOrder() == ordered)
        #expect(try await f.chatService(store).activeDirectChats().map(\.teammate.id) == [b.id, a.id])
    }

    @Test("Creation prepends durably without changing existing active or Archived order")
    func newBotPrecedesSavedOrderAfterReopen() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        var expected: [TeammateID] = []
        var archivedBefore: [Teammate] = []
        weak var closed: SQLiteStore?
        do {
            let store = try f.open(); closed = store
            let a = try await f.seed(store, number: 1, content: true)
            let b = try await f.seed(store, number: 2, pinned: true, content: true)
            let c = try await f.seed(store, number: 3)
            let d = try await f.seed(store, number: 4)
            _ = try await store.archiveTeammate(id: c.id, expectedProfileRevision: 1, now: f.at(10))
            _ = try await store.archiveTeammate(id: d.id, expectedProfileRevision: 1, now: f.at(20))
            let before = try await store.loadBotSidebarOrder()
            _ = try await store.saveBotSidebarOrder([a.id, b.id], expectedRevision: before.revision)
            archivedBefore = try await store.archivedTeammates()

            let created = try await f.seed(store, number: 5)
            expected = [created.id, a.id, b.id]
            #expect(try await store.loadBotSidebarOrder().teammateIDs == expected)
            #expect(try await store.archivedTeammates() == archivedBefore)
            #expect(try await store.teammate(id: a.id) == a)
            #expect(try await store.teammate(id: b.id) == b)
            #expect(try await store.loadDraft(conversationID: f.conversationID(1))?.text == f.draft)
            #expect(try await store.page(conversationID: f.conversationID(2), request: PageRequest(limit: 5)).elements.count == 1)
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.loadBotSidebarOrder().teammateIDs == expected)
        #expect(try await f.chatService(reopened).activeDirectChats().map(\.teammate.id) == expected)
        #expect(try await reopened.archivedTeammates() == archivedBefore)
    }

    @Test("Failed top insertion rolls back the new bot and leaves saved order intact")
    func failedPrependRollsBackCreation() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, number: 1)
        let before = try await store.loadBotSidebarOrder()
        _ = try await store.execute(sql: """
            CREATE TRIGGER fixture_prepend_failure BEFORE INSERT ON bot_sidebar_order
            WHEN NEW.position=0 AND NEW.teammate_id='\(f.teammateID(2).persistedValue)'
            BEGIN SELECT RAISE(ABORT,'synthetic prepend failure'); END;
            """)
        await #expect(throws: SQLiteStoreError.self) { try await f.seed(store, number: 2) }
        #expect(try await store.loadBotSidebarOrder() == before)
        #expect(try await store.teammate(id: f.teammateID(2)) == nil)
        #expect(try await store.conversation(id: f.conversationID(2)) == nil)
        #expect(try await store.selectedConversationID() == f.conversationID(1))
    }

    @Test("Duplicate, omitted, invented and stale UUID permutations are rejected atomically")
    func invalidAndStaleSaves() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        let a = try await f.seed(store, number: 1, content: true)
        let b = try await f.seed(store, number: 2, content: true)
        let initial = try await store.loadBotSidebarOrder()
        let before = try await f.contentRows(store)
        for invalid in [[a.id, a.id], [a.id], [a.id, TeammateID(UUID())], []] {
            await #expect(throws: BotSidebarOrderError.invalidMembership) {
                try await store.saveBotSidebarOrder(invalid, expectedRevision: initial.revision)
            }
            #expect(try await store.loadBotSidebarOrder() == initial)
        }
        let saved = try await store.saveBotSidebarOrder([a.id, b.id], expectedRevision: initial.revision)
        await #expect(throws: BotSidebarOrderError.staleRevision) {
            try await store.saveBotSidebarOrder(initial.teammateIDs, expectedRevision: initial.revision)
        }
        #expect(try await store.loadBotSidebarOrder() == saved)
        #expect(try await f.contentRows(store) == before)
    }

    @Test("A failed position insertion rolls back the entire reorder and its revision")
    func failedWriteRollsBack() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        let a = try await f.seed(store, number: 1, content: true)
        let b = try await f.seed(store, number: 2, content: true)
        let original = try await store.loadBotSidebarOrder()
        let before = try await f.contentRows(store)
        _ = try await store.execute(sql: """
            CREATE TRIGGER fixture_order_failure BEFORE INSERT ON bot_sidebar_order
            WHEN NEW.position=1 BEGIN SELECT RAISE(ABORT,'synthetic order failure'); END;
            """)
        await #expect(throws: SQLiteStoreError.self) {
            try await store.saveBotSidebarOrder([a.id, b.id], expectedRevision: original.revision)
        }
        #expect(try await store.loadBotSidebarOrder() == original)
        #expect(try await f.contentRows(store) == before)
    }

    @Test("Independent connections cannot both overwrite the same revision")
    func competingSaves() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let first = try f.open()
        let a = try await f.seed(first, number: 1)
        let b = try await f.seed(first, number: 2)
        let c = try await f.seed(first, number: 3)
        let second = try f.open()
        let initial = try await first.loadBotSidebarOrder()
        async let one = try? first.saveBotSidebarOrder([a.id, b.id, c.id], expectedRevision: initial.revision)
        async let two = try? second.saveBotSidebarOrder([b.id, a.id, c.id], expectedRevision: initial.revision)
        let outcomes = await (one, two)
        #expect((outcomes.0 != nil) != (outcomes.1 != nil))
        #expect(try await first.loadBotSidebarOrder() == (outcomes.0 ?? outcomes.1))
    }

    @Test("New bots prepend and restored bots append; archive preserves survivors and fences an old drag")
    func membershipChangesFenceStaleDrag() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let first = try f.open()
        let a = try await f.seed(first, number: 1, content: true)
        let b = try await f.seed(first, number: 2, pinned: true, content: true)
        let initial = try await first.loadBotSidebarOrder()
        let second = try f.open()
        let c = try await f.seed(second, number: 3, pinned: true, recency: 99)
        let withNew = try await first.loadBotSidebarOrder()
        #expect(withNew.teammateIDs == [c.id, b.id, a.id])
        await #expect(throws: BotSidebarOrderError.staleRevision) {
            try await first.saveBotSidebarOrder([b.id, a.id], expectedRevision: initial.revision)
        }
        let moved = try await first.saveBotSidebarOrder([c.id, a.id, b.id], expectedRevision: withNew.revision)
        let archived = try await second.archiveTeammate(id: b.id, expectedProfileRevision: 1, now: f.at(100))
        let withoutArchived = try await first.loadBotSidebarOrder()
        #expect(withoutArchived.teammateIDs == [c.id, a.id])
        await #expect(throws: BotSidebarOrderError.staleRevision) {
            try await first.saveBotSidebarOrder([a.id, b.id, c.id], expectedRevision: moved.revision)
        }
        await #expect(throws: BotSidebarOrderError.invalidMembership) {
            try await first.saveBotSidebarOrder([a.id, b.id, c.id], expectedRevision: withoutArchived.revision)
        }
        let restored = try await second.restoreTeammate(id: b.id, expectedProfileRevision: archived.profile.revision, now: f.at(101))
        let withRestored = try await first.loadBotSidebarOrder()
        #expect(withRestored.teammateIDs == [c.id, a.id, b.id])
        #expect(withRestored.revision > withoutArchived.revision)
        #expect(restored.id == b.id)
        #expect(restored.appearance == b.appearance)
        #expect(restored.isPinned == b.isPinned)
        #expect(try await first.selectedConversationID() == f.conversationID(3))
        #expect(try await first.loadDraft(conversationID: f.conversationID(2))?.text == f.draft)
        #expect(try await first.page(conversationID: f.conversationID(2), request: PageRequest(limit: 5)).elements.count == 1)
        await #expect(throws: BotSidebarOrderError.staleRevision) {
            try await first.saveBotSidebarOrder([a.id, c.id], expectedRevision: withoutArchived.revision)
        }
    }

    @Test("Failed create and failed archive cannot leave half-updated order membership")
    func lifecycleTransactionRollback() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        let a = try await f.seed(store, number: 1)
        let original = try await store.loadBotSidebarOrder()
        _ = try await store.execute(sql: """
            CREATE TRIGGER fixture_order_failure BEFORE UPDATE ON bot_sidebar_order_state
            BEGIN SELECT RAISE(ABORT,'synthetic order state failure'); END;
            """)
        await #expect(throws: SQLiteStoreError.self) { try await f.seed(store, number: 2) }
        #expect(try await store.teammate(id: f.teammateID(2)) == nil)
        #expect(try await store.conversation(id: f.conversationID(2)) == nil)
        await #expect(throws: SQLiteStoreError.self) {
            try await store.archiveTeammate(id: a.id, expectedProfileRevision: 1, now: f.at(100))
        }
        #expect(try await store.teammate(id: a.id) == a)
        #expect(try await store.loadBotSidebarOrder() == original)
        #expect(try await store.selectedConversationID() == f.conversationID(1))
    }

    @Test("A simultaneous roster change either follows the move or makes its revision stale", arguments: ["create", "archive", "restore"])
    func competingMembershipChange(action: String) async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let first = try f.open()
        let a = try await f.seed(first, number: 1)
        let b = try await f.seed(first, number: 2)
        let second = try f.open()
        let restoredRevision: UInt64
        if action == "restore" {
            restoredRevision = try await second.archiveTeammate(id: b.id, expectedProfileRevision: 1, now: f.at(100)).profile.revision
        } else { restoredRevision = 0 }
        if action != "create" { try await f.seed(first, number: 3) }
        let initial = try await first.loadBotSidebarOrder()
        let permutation = Array(initial.teammateIDs.reversed())
        async let move = try? first.saveBotSidebarOrder(permutation, expectedRevision: initial.revision)
        async let membership = f.changeMembership(second, action: action, restoreRevision: restoredRevision)
        let (saved, _) = try await (move, membership)
        let priorToChange = saved?.teammateIDs ?? initial.teammateIDs
        let expected: [TeammateID]
        switch action {
        case "create": expected = [f.teammateID(3)] + priorToChange
        case "archive": expected = priorToChange.filter { $0 != b.id }
        default: expected = priorToChange + [b.id]
        }
        let current = try await first.loadBotSidebarOrder()
        #expect(current.teammateIDs == expected)
        #expect(Set(current.teammateIDs).count == current.teammateIDs.count)
        #expect(current.teammateIDs.contains(a.id))
    }

    @Test("Cancellation and exhausted revisions do not change confirmed order")
    func cancellationAndExhaustion() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        let a = try await f.seed(store, number: 1)
        let b = try await f.seed(store, number: 2)
        let original = try await store.loadBotSidebarOrder()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.saveBotSidebarOrder([b.id, a.id], expectedRevision: original.revision)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.loadBotSidebarOrder() == original)
        _ = try await store.execute(sql: "UPDATE bot_sidebar_order_state SET revision=?;", bindings: [.integer(Int64.max)])
        await #expect(throws: BotSidebarOrderError.revisionExhausted) {
            try await store.saveBotSidebarOrder([a.id, b.id], expectedRevision: UInt64(Int64.max))
        }
        let exhausted = try await store.loadBotSidebarOrder()
        #expect(exhausted.teammateIDs == original.teammateIDs)
        #expect(try await store.saveBotSidebarOrder(original.teammateIDs, expectedRevision: UInt64(Int64.max)) == exhausted)
    }

    @Test("Ordinary direct-chat inserts and conversation membership changes use the same order rules")
    func ordinaryRepositoryMembershipPaths() async throws {
        let f = try SidebarOrderFixture(); defer { f.remove() }
        let store = try f.open()
        let a = try f.teammate(number: 1)
        try await store.insert(a)
        #expect(try await store.loadBotSidebarOrder().teammateIDs.isEmpty)
        var conversation = try f.conversation(number: 1)
        try await store.insert(conversation, participantIDs: [a.id])
        let b = try await f.seed(store, number: 2)
        #expect(try await store.loadBotSidebarOrder().teammateIDs == [b.id, a.id])
        conversation.lifecycle = .archived
        try await store.update(conversation)
        #expect(try await store.loadBotSidebarOrder().teammateIDs == [b.id])
        conversation.lifecycle = .active
        try await store.update(conversation)
        #expect(try await store.loadBotSidebarOrder().teammateIDs == [b.id, a.id])
        _ = try await store.execute(sql: "UPDATE conversation_participants SET left_at=10001 WHERE teammate_id=?;", bindings: [.text(b.id.persistedValue)])
        #expect(try await store.loadBotSidebarOrder().teammateIDs == [a.id])
        _ = try await store.execute(sql: "UPDATE conversation_participants SET left_at=NULL WHERE teammate_id=?;", bindings: [.text(b.id.persistedValue)])
        #expect(try await store.loadBotSidebarOrder().teammateIDs == [a.id, b.id])
    }
}

private struct SidebarOrderFixture: Sendable {
    let root: URL
    let receipt: ProtectionDecisionReceipt
    let draft = "  Draft café 🦊\nexact\0bytes\t  "

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsSidebarOrderTests-\(UUID()).noindex")
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(timeIntervalSince1970: 10_000), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 10_000 + seconds) }
    func teammateID(_ number: Int) -> TeammateID { TeammateID(UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!) }
    func conversationID(_ number: Int) -> ConversationID { ConversationID(UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", number))!) }

    func teammate(number: Int, pinned: Bool = false, recency: TimeInterval = 0) throws -> Teammate {
        try Teammate(id: teammateID(number),
            profile: TeammateProfile(displayName: "Ordering Fixture \(number)", role: "Synthetic local work", detailedInstructions: "Keep this profile exact."),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 3, deterministicSeed: UInt64(number),
                silhouette: "cloud", paletteToken: "violet", eyeDialect: "calm", nonColorIdentityCue: "soft crown",
                accessibleIdentityDescription: "Saved identity \(number)", builtInAvatarID: "guide", revision: 7),
            isPinned: pinned, notificationPreference: .disabled, createdAt: at(0), updatedAt: at(recency))
    }

    func conversation(number: Int, recency: TimeInterval = 0) throws -> Conversation {
        try Conversation(id: conversationID(number), kind: .direct(teammateID: teammateID(number)),
                         title: "Saved chat \(number)", createdAt: at(0), updatedAt: at(recency))
    }

    @discardableResult
    func seed(_ store: SQLiteStore, number: Int, pinned: Bool = false, recency: TimeInterval = 0, content: Bool = false) async throws -> Teammate {
        let teammate = try teammate(number: number, pinned: pinned, recency: recency)
        try await store.provisionDirectChat(teammate: teammate, conversation: conversation(number: number, recency: recency), fixtureGreeting: nil, selectConversation: true)
        if content {
            try await store.append(message(number: number, recency: recency), expectedPreviousSequence: 0)
            _ = try await store.saveDraft(conversationID: conversationID(number), text: draft, expectedRevision: 0, updatedAt: at(recency))
            _ = try await store.stage(AttachmentAsset(id: AttachmentID(UUID()), conversationID: conversationID(number),
                displayName: "fixture.txt", typeIdentifier: "public.plain-text", byteCount: 6,
                sha256: String(repeating: "a", count: 64), createdAt: at(0)))
        }
        return teammate
    }

    func message(number: Int, recency: TimeInterval) throws -> Message {
        try Message(id: MessageID(UUID()), conversationID: conversationID(number), sequence: 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Exact synthetic message café\0 \n"))],
            createdAt: at(recency), updatedAt: at(recency))
    }

    func chatService(_ store: SQLiteStore) -> DurableTeammateChatService {
        DurableTeammateChatService(teammateRepository: store, conversationRepository: store, messageRepository: store,
                                  provisioningRepository: store, selectionRepository: store)
    }

    func changeMembership(_ store: SQLiteStore, action: String, restoreRevision: UInt64) async throws {
        switch action {
        case "create": try await seed(store, number: 3)
        case "archive": _ = try await store.archiveTeammate(id: teammateID(2), expectedProfileRevision: 1, now: at(100))
        default: _ = try await store.restoreTeammate(id: teammateID(2), expectedProfileRevision: restoreRevision, now: at(101))
        }
    }

    func removeOrderingMigrationFromSyntheticStore(_ store: SQLiteStore) async throws {
        let triggers = try await store.query(sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'bot_sidebar_order_%';")
        for trigger in triggers {
            let name = try trigger.text("name")
            _ = try await store.execute(sql: "DROP TRIGGER \"\(name)\";")
        }
        _ = try await store.execute(sql: "DROP VIEW bot_sidebar_active_memberships;")
        _ = try await store.execute(sql: "DROP TABLE bot_sidebar_order;")
        _ = try await store.execute(sql: "DROP TABLE bot_sidebar_order_state;")
        _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=14;")
    }

    /// Compare content bytes rather than quote(text), which truncates at NUL.
    func contentRows(_ store: SQLiteStore) async throws -> [String: [String]] {
        let excluded: Set<String> = ["bot_sidebar_order", "bot_sidebar_order_state", "schema_migrations"]
        let tables = try await store.query(sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
        var result: [String: [String]] = [:]
        for table in tables {
            let name = try table.text("name")
            guard !excluded.contains(name) else { continue }
            let columns = try await store.query(sql: "PRAGMA table_info(\"\(name)\");")
            let projection = try columns.map {
                let column = try $0.text("name")
                return "typeof(\"\(column)\") || ':' || hex(CAST(\"\(column)\" AS BLOB))"
            }.joined(separator: " || '|' || ")
            result[name] = try await store.query(sql: "SELECT \(projection) AS saved FROM \"\(name)\" ORDER BY saved;").map { try $0.text("saved") }
        }
        return result
    }
}
