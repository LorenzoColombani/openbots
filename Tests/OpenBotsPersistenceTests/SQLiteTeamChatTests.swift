import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Team chats in SQLite")
struct SQLiteTeamChatTests {
    @Test("Provisioning writes the team, its memberships, its conversation and the participants in one commit")
    func provisionTeamWritesTheWholeAggregate() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: true)

        let reopened = try f.open()
        let saved = try #require(try await reopened.team(id: team.id))
        #expect(saved.memberIDs == [f.ada, f.mira])
        #expect(saved.leadID == f.mira)
        let savedConversation = try #require(try await reopened.teamConversation(teamID: team.id))
        #expect(savedConversation.id == conversation.id)
        #expect(savedConversation.kind == .team(teamID: team.id))
        #expect(try await reopened.activeParticipantIDs(conversationID: conversation.id) == [f.ada, f.mira])
        #expect(try await reopened.selectedConversationID() == conversation.id)
        #expect(try await reopened.conversations(for: f.ada, includingArchived: false).map(\.id).contains(conversation.id))
    }

    @Test("An archived member refuses the whole aggregate; nothing is written")
    func archivedMemberRefusesEverything() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;", bindings: [.text(f.ada.persistedValue)])
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        await #expect(throws: RepositoryError.self) {
            try await store.provisionTeam(team, conversation: conversation, selectConversation: true)
        }
        #expect(try await store.team(id: team.id) == nil)
        #expect(try await store.teamConversation(teamID: team.id) == nil)
        #expect(try await store.conversation(id: conversation.id) == nil)
        #expect(try await store.selectedConversationID() == nil)
    }

    @Test("A conversation of another kind or another team is refused before any write")
    func mismatchedConversationIsRefused() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let wrongKind = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: f.ada), createdAt: f.date, updatedAt: f.date)
        await #expect(throws: DomainValidationError.self) {
            try await store.provisionTeam(team, conversation: wrongKind, selectConversation: false)
        }
        let otherTeam = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: TeamID(UUID())), createdAt: f.date, updatedAt: f.date)
        await #expect(throws: DomainValidationError.self) {
            try await store.provisionTeam(team, conversation: otherTeam, selectConversation: false)
        }
        #expect(try await store.team(id: team.id) == nil)
        #expect(try await store.listTeams(includingArchived: true).isEmpty)
    }

    @Test("Editing rewrites the memberships, the conversation title and the participants in one commit")
    func editRewritesTheWholeAggregate() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)

        // The expectation is read back out of the store rather than reused from
        // the in-memory team, so this pins the round trip the guard compares:
        // a REAL column into a `Date` and back into a binding.
        let stored = try #require(try await store.team(id: team.id))
        let edited = try Team(id: team.id, name: "Research Team", leadID: f.zed, memberIDs: [f.mira, f.zed],
                              createdAt: f.date, updatedAt: f.date.addingTimeInterval(100))
        let retitled = try Conversation(id: conversation.id, kind: conversation.kind, title: "Research Team",
                                        createdAt: conversation.createdAt, updatedAt: conversation.updatedAt)
        try await store.updateTeam(edited, conversation: retitled, expectedUpdatedAt: stored.updatedAt)

        let reopened = try f.open()
        let saved = try #require(try await reopened.team(id: team.id))
        #expect(saved.name == "Research Team")
        #expect(saved.memberIDs == [f.mira, f.zed])
        #expect(saved.leadID == f.zed)
        // A durable turn is authorised by an unrevoked membership *and* an
        // unclosed participant row, so the participants must move with the
        // memberships or the added member is routed to and then refused.
        #expect(try await reopened.activeParticipantIDs(conversationID: conversation.id) == [f.mira, f.zed])
        // Conversation search and the export filenames read this title.
        #expect(try await reopened.conversation(id: conversation.id)?.title == "Research Team")
        #expect(try await reopened.conversations(for: f.ada, includingArchived: false).map(\.id).contains(conversation.id) == false)
        #expect(try await reopened.conversations(for: f.zed, includingArchived: false).map(\.id).contains(conversation.id))
    }

    @Test("An edit that keeps an already-held member archived since is accepted; adding an archived bot is still refused")
    func editKeepsAnArchivedMemberButRefusesANewOne() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)
        _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;",
                                    bindings: [.text(f.ada.persistedValue)])

        // Ada was archived after joining. A rename must not evict it, so the
        // active-member guard covers only the bots joining now.
        let renamed = try Team(id: team.id, name: "Research Team", leadID: f.mira, memberIDs: [f.ada, f.mira],
                               createdAt: f.date, updatedAt: f.date.addingTimeInterval(100))
        try await store.updateTeam(renamed, conversation: conversation, expectedUpdatedAt: f.date)
        #expect(try await store.team(id: team.id)?.memberIDs == [f.ada, f.mira])
        #expect(try await store.activeParticipantIDs(conversationID: conversation.id) == [f.ada, f.mira])

        // Joining an archived bot is still refused, and writes nothing.
        _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;",
                                    bindings: [.text(f.zed.persistedValue)])
        let widened = try Team(id: team.id, name: "Widened", leadID: f.mira, memberIDs: [f.ada, f.mira, f.zed],
                               createdAt: f.date, updatedAt: f.date.addingTimeInterval(200))
        // The expectation names the instant the rename above published, so the
        // refusal can only come from the archived bot and not from a stale row.
        await #expect(throws: RepositoryError.self) {
            try await store.updateTeam(widened, conversation: conversation,
                                       expectedUpdatedAt: f.date.addingTimeInterval(100))
        }
        #expect(try await store.team(id: team.id)?.name == "Research Team")
        #expect(try await store.team(id: team.id)?.memberIDs == [f.ada, f.mira])
    }

    @Test("A member added through the team row alone is refused read context; the aggregate edit admits it")
    func addedMemberIsOnlyAuthorisedByTheAggregate() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)

        /// Exactly what `OfficialClaudeTextReplyService` asks for on a team
        /// turn: no persisted context row, so the zero selection is used.
        func loadZedContext() async throws {
            let rows = try await store.query(sql: "SELECT profile_revision FROM teammates WHERE id=?;",
                                             bindings: [.text(f.zed.persistedValue)])
            let row = try #require(rows.first)
            _ = try await store.loadReadContextCandidates(ReadContextRequest(
                conversationID: conversation.id, teammateID: f.zed,
                profileRevision: UInt64(try row.integer("profile_revision")),
                selection: ConversationContextSelection(conversationID: conversation.id, teammateID: f.zed),
                beforeSequence: 1))
        }

        let widened = try Team(id: team.id, name: team.name, leadID: f.mira, memberIDs: [f.ada, f.mira, f.zed],
                               createdAt: f.date, updatedAt: f.date.addingTimeInterval(100))
        // Memberships alone. `TeamMentionRouting` would already send "@Zed" to
        // Zed, but the read-context authority wants an unclosed participant row
        // too, so the turn is refused after the message has been routed.
        try await store.update(widened)
        await #expect(throws: ReadContextError.unavailable) { try await loadZedContext() }

        // The aggregate edit moves the participant row with the membership. The
        // team row alone was just rewritten, so the expectation is what that
        // write published, not what the team was provisioned with.
        try await store.updateTeam(widened, conversation: conversation,
                                   expectedUpdatedAt: f.date.addingTimeInterval(100))
        try await loadZedContext()
    }

    @Test("A member removed and re-added later holds exactly one unclosed participant row")
    func reAddedMemberHoldsOneParticipantRow() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)

        func save(_ members: Set<TeammateID>, at seconds: TimeInterval, expecting: TimeInterval) async throws {
            let next = try Team(id: team.id, name: team.name, leadID: f.mira, memberIDs: members,
                                createdAt: f.date, updatedAt: f.date.addingTimeInterval(seconds))
            try await store.updateTeam(next, conversation: conversation,
                                       expectedUpdatedAt: f.date.addingTimeInterval(expecting))
        }
        try await save([f.mira, f.zed], at: 100, expecting: 0)
        try await save([f.ada, f.mira, f.zed], at: 200, expecting: 100)

        #expect(try await store.activeParticipantIDs(conversationID: conversation.id) == [f.ada, f.mira, f.zed])
        // `activeParticipantIDs` returns a set, so it reads the same for one
        // unclosed row and for two. The read-context authority refuses a
        // teammate holding two exactly as it refuses one holding none, so the
        // row count is what actually proves the re-add revived instead of
        // inserting a second row.
        let rows = try await store.query(
            sql: "SELECT COUNT(*) AS total FROM conversation_participants WHERE conversation_id=? AND teammate_id=? AND left_at IS NULL;",
            bindings: [.text(conversation.id.persistedValue), .text(f.ada.persistedValue)])
        #expect(try rows.first?.integer("total") == 1)
    }

    @Test("An edit naming another team's conversation, an archived member or a missing team writes nothing",
          arguments: ["otherConversation", "archivedMember", "missingTeam"])
    func editRefusalsWriteNothing(_ mode: String) async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)

        var editedID = team.id
        var target = conversation
        if mode == "otherConversation" {
            let stranger = try Team(id: TeamID(UUID()), name: "Other", leadID: f.mira, memberIDs: [f.ada, f.mira],
                                    createdAt: f.date, updatedAt: f.date)
            target = try f.teamConversation(stranger)
        } else if mode == "archivedMember" {
            _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;",
                                        bindings: [.text(f.zed.persistedValue)])
        } else {
            // A team row that was never written: the conversation matches it,
            // so the refusal comes from the team update, not the kind guard.
            editedID = TeamID(UUID())
            target = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: editedID),
                                      title: "Ghost", createdAt: f.date, updatedAt: f.date)
        }
        let edited = try Team(id: editedID, name: "Research Team", leadID: f.mira, memberIDs: [f.mira, f.zed],
                              createdAt: f.date, updatedAt: f.date.addingTimeInterval(100))
        await #expect(throws: Error.self) {
            try await store.updateTeam(edited, conversation: target, expectedUpdatedAt: f.date)
        }

        let saved = try #require(try await store.team(id: team.id))
        #expect(saved.name == "QA Team")
        #expect(saved.memberIDs == [f.ada, f.mira])
        #expect(saved.leadID == f.mira)
        #expect(try await store.activeParticipantIDs(conversationID: conversation.id) == [f.ada, f.mira])
        #expect(try await store.conversation(id: conversation.id)?.title == "QA Team")
    }

    @Test("A second writer between the read and the write refuses the stale edit; nothing is revoked or resurrected")
    func aStaleEditIsRefusedAndChangesNothing() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)

        // Both writers derive a roster from the team as it stands here.
        let readInstant = try #require(try await store.team(id: team.id)).updatedAt

        // The first swaps Ada for Zed and publishes.
        let first = try Team(id: team.id, name: "Research Team", leadID: f.mira, memberIDs: [f.mira, f.zed],
                             createdAt: f.date, updatedAt: f.date.addingTimeInterval(100))
        let firstTitle = try Conversation(id: conversation.id, kind: conversation.kind, title: "Research Team",
                                          createdAt: conversation.createdAt, updatedAt: conversation.updatedAt)
        try await store.updateTeam(first, conversation: firstTitle, expectedUpdatedAt: readInstant)

        // The second still holds the roster it read, so writing it would revoke
        // the member the first added and resurrect the one it removed.
        let stale = try Team(id: team.id, name: "Stale Team", leadID: f.mira, memberIDs: [f.ada, f.mira],
                             createdAt: f.date, updatedAt: f.date.addingTimeInterval(200))
        let staleTitle = try Conversation(id: conversation.id, kind: conversation.kind, title: "Stale Team",
                                          createdAt: conversation.createdAt, updatedAt: conversation.updatedAt)
        await #expect(throws: RepositoryError.optimisticLockFailed(entity: "team", id: team.id.persistedValue)) {
            try await store.updateTeam(stale, conversation: staleTitle, expectedUpdatedAt: readInstant)
        }

        let reopened = try f.open()
        let saved = try #require(try await reopened.team(id: team.id))
        #expect(saved.name == "Research Team")
        #expect(saved.updatedAt == f.date.addingTimeInterval(100))
        // Zed keeps the membership the first writer gave it and Ada stays
        // revoked, which is exactly what the stale roster would have undone.
        #expect(saved.memberIDs == [f.mira, f.zed])
        #expect(try await reopened.activeParticipantIDs(conversationID: conversation.id) == [f.mira, f.zed])
        // The refusal rolls back the whole transaction, title included.
        #expect(try await reopened.conversation(id: conversation.id)?.title == "Research Team")
    }

    @Test("The saved selection may point at a team conversation and still at a direct chat")
    func selectionAcceptsBothKinds() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)
        try await store.setSelectedConversationID(conversation.id)
        #expect(try await store.selectedConversationID() == conversation.id)
        try await store.setSelectedConversationID(f.adaChat)
        #expect(try await store.selectedConversationID() == f.adaChat)
        _ = try await store.execute(sql: "UPDATE teams SET lifecycle='archived' WHERE id=?;", bindings: [.text(team.id.persistedValue)])
        await #expect(throws: TeammateArchiveError.self) {
            try await store.setSelectedConversationID(conversation.id)
        }
    }
}

struct TeamChatStoreFixture {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 10)
    let ada = TeammateID(UUID()), mira = TeammateID(UUID()), zed = TeammateID(UUID())
    let adaChat = ConversationID(UUID()), miraChat = ConversationID(UUID()), zedChat = ConversationID(UUID())

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("team-chat-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func bot(_ id: TeammateID, name: String) throws -> Teammate {
        try Teammate(id: id, profile: TeammateProfile(displayName: name, role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round with crest"),
            createdAt: date, updatedAt: date)
    }
    func seedBots(_ store: SQLiteStore) async throws {
        for (id, chat, name) in [(ada, adaChat, "Ada"), (mira, miraChat, "Mira"), (zed, zedChat, "Zed")] {
            try await store.provisionDirectChat(teammate: bot(id, name: name),
                conversation: Conversation(id: chat, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                fixtureGreeting: nil, selectConversation: false)
        }
    }
    func team(store: SQLiteStore, members: Set<TeammateID>, lead: TeammateID) throws -> Team {
        try Team(id: TeamID(UUID()), name: "QA Team", leadID: lead, memberIDs: members, createdAt: date, updatedAt: date)
    }
    func teamConversation(_ team: Team) throws -> Conversation {
        try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: team.name, createdAt: date, updatedAt: date)
    }
}
