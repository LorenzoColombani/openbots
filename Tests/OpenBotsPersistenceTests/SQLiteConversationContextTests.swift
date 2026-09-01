import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Durable direct conversation context")
struct SQLiteConversationContextTests {
    @Test("Selection and explicit empty choice survive reopen without changing conversation kind")
    func reopenAndIsolation() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            let initial = try await store.loadContext(conversationID: fixture.firstChat)
            #expect(initial == fixture.selection())
            let first = try await store.saveContext(fixture.selection(project: fixture.project, team: fixture.team))
            let second = try await store.saveContext(fixture.selection(second: true, project: fixture.otherProject))
            #expect(first.revision == 1)
            #expect(second.revision == 1)
        }
        let reopened = try fixture.open()
        #expect(try await reopened.loadContext(conversationID: fixture.firstChat)
                == fixture.selection(project: fixture.project, team: fixture.team, revision: 1))
        #expect(try await reopened.loadContext(conversationID: fixture.secondChat)
                == fixture.selection(second: true, project: fixture.otherProject, revision: 1))
        #expect(try await reopened.conversation(id: fixture.firstChat)?.kind == .direct(teammateID: fixture.first))
        #expect(try await reopened.conversation(id: fixture.secondChat)?.kind == .direct(teammateID: fixture.second))
        let clear = try await reopened.saveContext(fixture.selection(revision: 1))
        #expect(clear == fixture.selection(revision: 2))
        let thirdConnection = try fixture.open()
        #expect(try await thirdConnection.loadContext(conversationID: fixture.firstChat) == clear)
        #expect(try await thirdConnection.loadContext(conversationID: fixture.secondChat).projectID == fixture.otherProject)
    }

    @Test("CAS rejects stale creation, overwrite and clear across connections")
    func revisionConflicts() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let firstConnection = try fixture.open()
        let secondConnection = try fixture.open()
        try await fixture.seed(firstConnection)
        _ = try await firstConnection.saveContext(fixture.selection(project: fixture.project))
        await #expect(throws: ConversationContextError.staleRevision) {
            try await secondConnection.saveContext(fixture.selection(team: fixture.team))
        }
        _ = try await firstConnection.saveContext(fixture.selection(team: fixture.team, revision: 1))
        await #expect(throws: ConversationContextError.staleRevision) {
            try await secondConnection.saveContext(fixture.selection(revision: 1))
        }
        #expect(try await secondConnection.loadContext(conversationID: fixture.firstChat)
                == fixture.selection(team: fixture.team, revision: 2))
    }

    @Test("Archive and membership revocation hide scope IDs but permit exact explicit clear", arguments: [
        "projectArchive", "teamArchive", "projectRevocation", "teamRevocation"
    ])
    func invalidationAndRecovery(change: String) async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        _ = try await store.saveContext(fixture.selection(project: fixture.project, team: fixture.team))
        switch change {
        case "projectArchive":
            _ = try await store.execute(sql: "UPDATE projects SET lifecycle='archived' WHERE id=?;", bindings: [.text(fixture.project.persistedValue)])
        case "teamArchive":
            _ = try await store.execute(sql: "UPDATE teams SET lifecycle='archived' WHERE id=?;", bindings: [.text(fixture.team.persistedValue)])
        case "projectRevocation":
            _ = try await store.execute(sql: "UPDATE project_memberships SET revoked_at=100 WHERE project_id=?;", bindings: [.text(fixture.project.persistedValue)])
        default:
            _ = try await store.execute(sql: "UPDATE team_memberships SET revoked_at=100 WHERE team_id=?;", bindings: [.text(fixture.team.persistedValue)])
        }
        await #expect(throws: ConversationContextError.selectionInvalidated(revision: 1)) {
            try await store.loadContext(conversationID: fixture.firstChat)
        }
        // Read is non-destructive: the original revision and references stay
        // durable until a deliberate clear/replacement is committed.
        let row = try await store.query(sql: "SELECT project_id,team_id,revision FROM conversation_context_selections;").first
        #expect(try row?.text("project_id") == fixture.project.persistedValue)
        #expect(try row?.text("team_id") == fixture.team.persistedValue)
        #expect(try row?.integer("revision") == 1)
        let clear = try await store.saveContext(fixture.selection(revision: 1))
        #expect(clear == fixture.selection(revision: 2))
        #expect(try await store.loadContext(conversationID: fixture.firstChat) == clear)
    }

    @Test("Unauthorized project or team cannot replace an accepted choice")
    func rejectsNonmemberAndMissingScopes() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let saved = try await store.saveContext(fixture.selection(project: fixture.project))
        await #expect(throws: ConversationContextError.projectUnavailable) {
            try await store.saveContext(fixture.selection(project: fixture.otherProject, revision: 1))
        }
        await #expect(throws: ConversationContextError.teamUnavailable) {
            try await store.saveContext(fixture.selection(second: true, team: fixture.team))
        }
        await #expect(throws: ConversationContextError.projectUnavailable) {
            try await store.saveContext(fixture.selection(project: ProjectID(UUID()), revision: 1))
        }
        await #expect(throws: ConversationContextError.teamUnavailable) {
            try await store.saveContext(fixture.selection(team: TeamID(UUID()), revision: 1))
        }
        #expect(try await store.loadContext(conversationID: fixture.firstChat) == saved)
        #expect(try await store.loadContext(conversationID: fixture.secondChat).revision == 0)
    }

    @Test("Exact active direct teammate identity and active participant are mandatory")
    func identityBoundary() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        await #expect(throws: ConversationContextError.teammateMismatch) {
            try await store.saveContext(ConversationContextSelection(
                conversationID: fixture.firstChat, teammateID: fixture.second
            ))
        }
        await #expect(throws: ConversationContextError.conversationNotFound) {
            try await store.loadContext(conversationID: ConversationID(UUID()))
        }
        let group = try Conversation(id: ConversationID(UUID()), kind: .project(projectID: fixture.project), createdAt: fixture.date, updatedAt: fixture.date)
        try await store.insert(group, participantIDs: [fixture.first])
        await #expect(throws: ConversationContextError.conversationUnavailable) {
            try await store.saveContext(ConversationContextSelection(conversationID: group.id, teammateID: fixture.first))
        }
        _ = try await store.execute(sql: "UPDATE conversation_participants SET left_at=100 WHERE conversation_id=?;", bindings: [.text(fixture.firstChat.persistedValue)])
        await #expect(throws: ConversationContextError.conversationUnavailable) {
            try await store.loadContext(conversationID: fixture.firstChat)
        }
        await #expect(throws: ConversationContextError.conversationUnavailable) {
            try await store.saveContext(fixture.selection())
        }
    }

    @Test("Archived teammate or conversation cannot load or save context", arguments: [false, true])
    func inactiveOwner(archiveTeammate: Bool) async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        _ = try await store.saveContext(fixture.selection(project: fixture.project))
        let sql = archiveTeammate
            ? "UPDATE teammates SET lifecycle='archived';"
            : "UPDATE conversations SET lifecycle='archived';"
        _ = try await store.execute(sql: sql)
        let expected: ConversationContextError = archiveTeammate ? .teammateUnavailable : .conversationUnavailable
        await #expect(throws: expected) { try await store.loadContext(conversationID: fixture.firstChat) }
        await #expect(throws: expected) { try await store.saveContext(fixture.selection(revision: 1)) }
    }

    @Test("Failed commit leaves the earlier selection and revision intact")
    func transactionRollback() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let saved = try await store.saveContext(fixture.selection(project: fixture.project))
        _ = try await store.execute(sql: """
            CREATE TRIGGER context_write_failure AFTER UPDATE ON conversation_context_selections
            BEGIN SELECT RAISE(ABORT,'injected context failure'); END;
            """)
        await #expect(throws: SQLiteStoreError.self) {
            try await store.saveContext(fixture.selection(team: fixture.team, revision: 1))
        }
        #expect(try await store.loadContext(conversationID: fixture.firstChat) == saved)
    }

    @Test("Revision overflow cannot trap, truncate or write")
    func revisionRange() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        for revision in [UInt64(Int64.max), UInt64.max] {
            await #expect(throws: ConversationContextError.invalidRevision) {
                try await store.saveContext(fixture.selection(revision: revision))
            }
        }
        #expect(try await store.loadContext(conversationID: fixture.firstChat).revision == 0)
    }

    @Test("Migration six preserves version-five data and leaves selections unassigned")
    func migrationFromFive() async throws {
        let fixture = try ContextStoreFixture()
        defer { fixture.remove() }
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            _ = try await store.execute(sql: "DROP TABLE conversation_context_selections;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=6;")
        }
        let reopened = try fixture.open()
        #expect(try await reopened.runtimeFacts().migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(try await reopened.loadContext(conversationID: fixture.firstChat) == fixture.selection())
        #expect(try await reopened.project(id: fixture.project)?.name == "First Project")
    }
}

private struct ContextStoreFixture {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 10)
    let first = TeammateID(UUID())
    let second = TeammateID(UUID())
    let firstChat = ConversationID(UUID())
    let secondChat = ConversationID(UUID())
    let project = ProjectID(UUID())
    let otherProject = ProjectID(UUID())
    let team = TeamID(UUID())

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-context-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)
        ))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func selection(second useSecond: Bool = false, project: ProjectID? = nil, team: TeamID? = nil, revision: UInt64 = 0) -> ConversationContextSelection {
        ConversationContextSelection(conversationID: useSecond ? secondChat : firstChat, teammateID: useSecond ? second : first, projectID: project, teamID: team, revision: revision)
    }

    func seed(_ store: SQLiteStore) async throws {
        for (id, chat, name) in [(first, firstChat, "First"), (second, secondChat, "Second")] {
            let teammate = try Teammate(
                id: id, profile: TeammateProfile(displayName: name, role: "Research"),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round with crest"),
                createdAt: date, updatedAt: date
            )
            let conversation = try Conversation(id: chat, kind: .direct(teammateID: id), createdAt: date, updatedAt: date)
            try await store.provisionDirectChat(teammate: teammate, conversation: conversation, fixtureGreeting: nil, selectConversation: false)
        }
        try await store.provisionProject(Project(id: project, name: "First Project", createdAt: date, updatedAt: date), initialMemberIDs: [first])
        try await store.provisionProject(Project(id: otherProject, name: "Second Project", createdAt: date, updatedAt: date), initialMemberIDs: [second])
        try await store.insert(Team(id: team, name: "First Team", leadID: first, memberIDs: [first], createdAt: date, updatedAt: date))
    }
}
