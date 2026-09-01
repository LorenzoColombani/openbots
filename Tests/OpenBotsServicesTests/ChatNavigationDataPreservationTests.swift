import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Test("Normal chat navigation, creation and local saving preserve existing directory, context and history across reopen")
func chatNavigationPreservesStoredWorkContext() async throws {
    let fixture = try ChatPreservationFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    // End the first service/store lifetime before reopening the same disposable
    // database. No app paths, live services or user-owned data participate.
    let preserved = try await { () async throws -> ChatPreservationReceipt in
        let store = try fixture.open()
        let existing = try await fixture.seed(store)
        let directoryRows = try await fixture.directoryRows(in: store)
        #expect(directoryRows["projects"]?.count == 2)
        #expect(directoryRows["teams"]?.count == 2)
        #expect(directoryRows["project_memberships"]?.count == 4)
        #expect(directoryRows["team_memberships"]?.count == 4)
        #expect(directoryRows["conversation_context_selections"]?.count == 2)
        try await fixture.rejectDirectoryWrites(in: store)

        let chat = fixture.chatService(store)
        #expect(Set(try await chat.activeDirectChats().map(\.id)) == Set(existing.map { $0.chat.id }))
        #expect(try await chat.selectedDirectChat()?.conversation.id == existing[0].chat.id)
        try await fixture.navigateExistingChats(existing, using: chat, store: store)
        #expect(try await fixture.directoryRows(in: store) == directoryRows)

        let created = try await chat.createTeammateAndDirectChat(DurableTeammateDraft(
            teammateID: TeammateID(UUID()), displayName: "New local teammate", role: "Research",
            appearance: existing[0].chat.teammate.appearance
        ))
        #expect(created.fixtureGreeting == nil)
        #expect(try await chat.loadMessages(conversationID: created.conversation.id,
            beforeSequence: nil, limit: 10).messages.isEmpty)
        #expect(try await chat.selectedDirectChat()?.conversation.id == created.conversation.id)
        let messageID = MessageID(UUID())
        let exactText = "  Keep this new local note\nwithout changing earlier work.  "
        let saved = try await chat.saveMessageLocally(
            conversationID: created.conversation.id, teammateID: created.teammate.id,
            userMessageID: messageID, text: exactText
        )
        #expect(saved.id == messageID && saved.author == .user && saved.sequence == 1)
        #expect(saved.parts.count == 1)
        #expect(saved.parts.first?.content == .text(exactText))
        #expect(saved.deliveryState == .completed)
        #expect(try await chat.loadMessages(conversationID: created.conversation.id,
            beforeSequence: nil, limit: 10).messages == [saved])
        try await fixture.navigateExistingChats(existing, using: chat, store: store)
        #expect(try await fixture.directoryRows(in: store) == directoryRows)
        try await chat.select(teammateID: created.teammate.id, conversationID: created.conversation.id)
        return ChatPreservationReceipt(
            existing: existing, directoryRows: directoryRows, created: created, saved: saved
        )
    }()

    let reopened = try fixture.open()
    let chat = fixture.chatService(reopened)
    #expect(try await fixture.directoryRows(in: reopened) == preserved.directoryRows)
    let selected = try #require(try await chat.selectedDirectChat())
    #expect(selected.teammate == preserved.created.teammate)
    #expect(selected.conversation.id == preserved.created.conversation.id)
    #expect(Set(try await chat.activeDirectChats().map(\.id)) ==
        Set(preserved.existing.map { $0.chat.id } + [preserved.created.conversation.id]))
    #expect(try await chat.loadMessages(conversationID: preserved.created.conversation.id,
        beforeSequence: nil, limit: 10).messages == [preserved.saved])
    try await fixture.navigateExistingChats(preserved.existing, using: chat, store: reopened)
    #expect(try await fixture.directoryRows(in: reopened) == preserved.directoryRows)
}

private struct PreservedDirectChat: Sendable {
    let chat: DurableDirectChatSnapshot
    let messages: [Message]
}

private struct ChatPreservationReceipt: Sendable {
    let existing: [PreservedDirectChat]
    let directoryRows: [String: [[String]]]
    let created: DurableTeammateChatCreationSnapshot
    let saved: Message
}

private struct ChatPreservationClock: OpenBotsClock {
    // Whole seconds round-trip exactly through Date's reference epoch and
    // SQLite's Unix-epoch REAL without hiding differences in full-record checks.
    func now() -> Date { Date(timeIntervalSince1970: 1_780_000_100) }
}

private struct ChatPreservationFixture {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    private let tables = [
        "projects", "teams", "project_memberships", "team_memberships", "conversation_context_selections"
    ]

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextChatPreservation-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)
        ))
    }

    func chatService(_ store: SQLiteStore) -> DurableTeammateChatService {
        DurableTeammateChatService(
            mode: .localOnly, teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store,
            clock: ChatPreservationClock()
        )
    }

    func seed(_ store: SQLiteStore) async throws -> [PreservedDirectChat] {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        var existing: [PreservedDirectChat] = []
        for number in 1...2 {
            let teammate = try Teammate(
                id: TeammateID(UUID()),
                profile: TeammateProfile(displayName: "Saved teammate \(number)", role: "Research"),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1,
                    deterministicSeed: UInt64(number), silhouette: "round", paletteToken: "sky",
                    eyeDialect: "bright", nonColorIdentityCue: "crest",
                    accessibleIdentityDescription: "Round creature with a crest"),
                createdAt: date, updatedAt: date
            )
            let conversation = try Conversation(
                id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id),
                title: "Saved conversation \(number)", createdAt: date, updatedAt: date
            )
            try await store.provisionDirectChat(teammate: teammate, conversation: conversation,
                fixtureGreeting: nil, selectConversation: number == 1)
            var messages: [Message] = []
            for sequence in 1...2 {
                let message = try Message(
                    id: MessageID(UUID()), conversationID: conversation.id, sequence: Int64(sequence),
                    author: sequence == 1 ? .user : .teammate(teammate.id), deliveryState: .completed,
                    parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                        content: .text("  Saved history \(number).\(sequence)\nKeep exact text and identity.  "))],
                    createdAt: date, updatedAt: date
                )
                try await store.append(message, expectedPreviousSequence: Int64(sequence - 1))
                messages.append(message)
            }
            existing.append(PreservedDirectChat(
                chat: DurableDirectChatSnapshot(teammate: teammate, conversation: conversation), messages: messages
            ))
        }

        let members = Set(existing.map { $0.chat.teammate.id })
        for index in existing.indices {
            let project = try Project(id: ProjectID(UUID()), name: "Saved project \(index)",
                summary: "Preserve project summary\nand timestamps.", createdAt: date, updatedAt: date)
            let team = try Team(id: TeamID(UUID()), name: "Saved team \(index)",
                summary: "Preserve the designated lead and membership.",
                leadID: existing[1 - index].chat.teammate.id, memberIDs: members,
                createdAt: date, updatedAt: date)
            try await store.provisionProject(project, initialMemberIDs: members)
            try await store.insert(team)
            let target = existing[index].chat
            let first = try await store.saveContext(ConversationContextSelection(
                conversationID: target.id, teammateID: target.teammate.id, projectID: project.id
            ))
            let saved = try await store.saveContext(ConversationContextSelection(
                conversationID: target.id, teammateID: target.teammate.id,
                projectID: project.id, teamID: team.id, revision: first.revision
            ))
            #expect(saved.revision == 2)
            if index == 1 {
                // Retain an invalidated context too: ordinary chat must never
                // clear old references, revive membership, or rewrite archives.
                _ = try await store.execute(sql: "UPDATE projects SET lifecycle='archived' WHERE id=?;",
                    bindings: [.text(project.id.persistedValue)])
                _ = try await store.execute(sql: "UPDATE teams SET lifecycle='archived' WHERE id=?;",
                    bindings: [.text(team.id.persistedValue)])
                _ = try await store.execute(sql: "UPDATE project_memberships SET revoked_at=? WHERE project_id=? AND teammate_id=?;",
                    bindings: [.real(date.addingTimeInterval(10).timeIntervalSince1970),
                        .text(project.id.persistedValue), .text(target.teammate.id.persistedValue)])
                _ = try await store.execute(sql: "UPDATE team_memberships SET revoked_at=? WHERE team_id=? AND teammate_id=?;",
                    bindings: [.real(date.addingTimeInterval(10).timeIntervalSince1970),
                        .text(team.id.persistedValue), .text(target.teammate.id.persistedValue)])
                await #expect(throws: ConversationContextError.selectionInvalidated(revision: 2)) {
                    try await store.loadContext(conversationID: target.id)
                }
            }
        }
        return existing
    }

    func navigateExistingChats(
        _ existing: [PreservedDirectChat], using service: DurableTeammateChatService, store: SQLiteStore
    ) async throws {
        for saved in existing.reversed() {
            try await service.select(teammateID: saved.chat.teammate.id, conversationID: saved.chat.id)
            let selected = try #require(try await service.selectedDirectChat())
            #expect(selected.teammate == saved.chat.teammate)
            #expect(selected.conversation == saved.chat.conversation)
            #expect(try await store.conversation(id: saved.chat.id) == saved.chat.conversation)
            let page = try await service.loadMessages(conversationID: saved.chat.id,
                beforeSequence: nil, limit: 1)
            #expect(page.messages == Array(saved.messages.suffix(1)))
            #expect(page.hasMore)
            let before = try #require(page.nextBeforeSequence)
            let earlier = try await service.loadMessages(conversationID: saved.chat.id,
                beforeSequence: before, limit: 1)
            #expect(earlier.messages + page.messages == saved.messages)
            #expect(!earlier.hasMore)
        }
    }

    func directoryRows(in store: SQLiteStore) async throws -> [String: [[String]]] {
        var result: [String: [[String]]] = [:]
        for table in tables {
            // The table names are a fixed fixture allowlist. Capture every
            // column, including nullable membership dates and raw invalidated
            // context IDs that typed readers deliberately withhold.
            let metadata = try await store.query(sql: "PRAGMA table_info(\(table));")
            let columns = try metadata.map { try $0.text("name") }
            try #require(!columns.isEmpty)
            let projection = columns.map { "quote(\($0)) AS \($0)" }.joined(separator: ",")
            let ordering = columns.joined(separator: ",")
            let rows = try await store.query(sql: "SELECT \(projection) FROM \(table) ORDER BY \(ordering);")
            result[table] = try rows.map { row in try columns.map { try row.text($0) } }
        }
        return result
    }

    func rejectDirectoryWrites(in store: SQLiteStore) async throws {
        // These guards exist only inside this disposable database and survive
        // reopen. Even an attempted no-op rewrite must abort the chat operation.
        for table in tables {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                _ = try await store.execute(sql: """
                    CREATE TRIGGER preserve_\(table)_\(operation.lowercased()) BEFORE \(operation) ON \(table)
                    BEGIN SELECT RAISE(ABORT, 'chat must preserve stored work context'); END;
                    """)
            }
        }
    }
}
