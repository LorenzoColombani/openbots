import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

/// A team leaves the sidebar by Archive Team and comes back by Restore. Only
/// its lifecycle moves; its chat, its memberships and every record stay.
@Suite("Reversible team archive")
struct SQLiteTeamArchiveTests {
    private func seeded() async throws -> (TeamChatStoreFixture, SQLiteStore, Team, Conversation) {
        let f = try TeamChatStoreFixture()
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: true)
        return (f, store, team, conversation)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 10 + seconds) }

    @Test("Archive and restore move only the team's lifecycle, and archiving closes its open chat")
    func archiveAndRestore() async throws {
        let (f, store, team, conversation) = try await seeded(); defer { f.remove() }
        #expect(try await store.selectedConversationID() == conversation.id)
        let archived = try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
        #expect(archived.lifecycle == .archived)
        #expect(archived.updatedAt == at(5))
        #expect(archived.memberIDs == team.memberIDs && archived.leadID == team.leadID && archived.name == team.name)
        #expect(try await store.selectedConversationID() == nil, "Its chat does not stay open behind the archive")
        #expect(try await store.listTeams(includingArchived: false).isEmpty)
        #expect(try await store.archivedTeams() == [archived])
        #expect(try await store.conversation(id: conversation.id)?.lifecycle == .active, "The chat itself is kept")
        #expect(try await store.activeParticipantIDs(conversationID: conversation.id) == [f.ada, f.mira])

        let restored = try await store.restoreTeam(id: team.id, expectedUpdatedAt: archived.updatedAt, now: at(9))
        #expect(restored.lifecycle == .active && restored.updatedAt == at(9))
        #expect(try await store.archivedTeams().isEmpty)
        #expect(try await store.listTeams(includingArchived: false) == [restored])
        #expect(try await store.teamConversation(teamID: team.id)?.id == conversation.id)
    }

    @Test("Unfinished work in the team's chat refuses the archive and changes nothing",
          arguments: ["queued", "starting", "running", "waitingForUser", "stopping"])
    func unfinishedWorkRefuses(state: String) async throws {
        let (f, store, team, conversation) = try await seeded(); defer { f.remove() }
        let message = try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Hello team"))],
            createdAt: f.date, updatedAt: f.date)
        try await store.append(message, expectedPreviousSequence: 0)
        let runID = RunID(UUID())
        _ = try await store.execute(sql: """
            INSERT INTO work_runs(id,teammate_id,conversation_id,initiating_message_id,selected_project_id,profile_revision,state,created_at,updated_at)
            VALUES (?,?,?,?,NULL,1,?,10,10);
            """, bindings: [.text(runID.persistedValue), .text(f.mira.persistedValue), .text(conversation.id.persistedValue),
                            .text(message.id.persistedValue), .text(state)])
        await #expect(throws: TeamArchiveError.unresolvedWork) {
            try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
        }
        #expect(try await store.team(id: team.id)?.lifecycle == .active)
        #expect(try await store.selectedConversationID() == conversation.id)
        #expect(try await store.query(sql: "SELECT state FROM work_runs WHERE id=?;",
                                      bindings: [.text(runID.persistedValue)]).first?.text("state") == state,
                "Nothing was cancelled")

        _ = try await store.execute(sql: "UPDATE work_runs SET state='succeeded' WHERE id=?;", bindings: [.text(runID.persistedValue)])
        #expect(try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5)).lifecycle == .archived)
    }

    @Test("A handoff still live or waiting for the user refuses the archive; one needing recovery does not",
          arguments: ["staged", "accepted", "working", "needsRecovery"])
    func handoffsInTheTeamChat(state: String) async throws {
        let (f, store, team, conversation) = try await seeded(); defer { f.remove() }
        let record = HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()),
            legID: HandoffLegID(UUID()), originConversationID: conversation.id, senderID: f.mira, receiverID: f.ada,
            createdAt: f.date), brief: HandoffBrief(goal: "Check", constraints: [], inputReferences: [],
            requestedOutput: "A line", exclusions: [], stopOrApprovalBoundary: "Stop after one line")),
            sourceMessageID: nil, briefMessageID: nil, replyMessageID: nil, runID: nil)
        try await store.insert(record)
        if state != "staged" {
            _ = try await store.execute(sql: "UPDATE handoffs SET state=?, recovery_json=? WHERE id=?;",
                bindings: [.text(state), state == "needsRecovery" ? .text(#"{"code":"interrupted"}"#) : .null,
                           .text(record.handoff.provenance.handoffID.persistedValue)])
        }
        if state == "needsRecovery" {
            #expect(try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5)).lifecycle == .archived,
                    "A broken leg must not keep the team from ever being archived")
        } else {
            await #expect(throws: TeamArchiveError.unresolvedWork) {
                try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
            }
            #expect(try await store.team(id: team.id)?.lifecycle == .active)
        }
    }

    @Test("No message reaches an archived team's chat, whatever checked before")
    func noMessageAfterArchive() async throws {
        let (f, store, team, conversation) = try await seeded(); defer { f.remove() }
        _ = try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
        let late = try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Sent late"))],
            createdAt: f.date, updatedAt: f.date)
        await #expect(throws: TeamArchiveError.invalidTransition) {
            try await store.append(late, expectedPreviousSequence: 0)
        }
        #expect(try await store.query(sql: "SELECT COUNT(*) AS n FROM messages WHERE conversation_id=?;",
                                      bindings: [.text(conversation.id.persistedValue)]).first?.integer("n") == 0)
        _ = try await store.restoreTeam(id: team.id, expectedUpdatedAt: at(5), now: at(6))
        try await store.append(late, expectedPreviousSequence: 0)
    }

    @Test("A stale team, a missing team and the wrong state are refused")
    func refusals() async throws {
        let (f, store, team, _) = try await seeded(); defer { f.remove() }
        await #expect(throws: TeamArchiveError.staleTeam) {
            try await store.archiveTeam(id: team.id, expectedUpdatedAt: at(1), now: at(5))
        }
        await #expect(throws: TeamArchiveError.notFound) {
            try await store.archiveTeam(id: TeamID(UUID()), expectedUpdatedAt: team.updatedAt, now: at(5))
        }
        await #expect(throws: TeamArchiveError.invalidTransition) {
            try await store.restoreTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
        }
        let archived = try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
        await #expect(throws: TeamArchiveError.invalidTransition) {
            try await store.archiveTeam(id: team.id, expectedUpdatedAt: archived.updatedAt, now: at(6))
        }
        #expect(try await store.team(id: team.id) == archived)
    }

    @Test("The lead of an archived team is refused by Delete in words, not by the database")
    func archivedTeamLeadIsRefusedByDelete() async throws {
        let (f, store, team, _) = try await seeded(); defer { f.remove() }
        _ = try await store.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt, now: at(5))
        let lead = try #require(try await store.teammate(id: f.mira))
        await #expect(throws: TeammateDeleteError.isTeamLead(teamName: "QA Team")) {
            _ = try await store.deleteTeammate(id: f.mira, expectedProfileRevision: lead.profile.revision, now: at(6))
        }
        #expect(try await store.teammate(id: f.mira) != nil)
    }
}
