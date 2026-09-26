import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsPersistence
@testable import OpenBotsUI

/// Archive Team
/// takes a team out of the sidebar and the archive window brings it back.
@MainActor
final class TeamArchiveWorkspaceTests: XCTestCase {
    private func setUp(_ fixture: ReferenceLocalWorkspaceFixture) async throws
        -> (SQLiteStore, DurableWorkspaceModel, TeamChatSnapshot) {
        let store = try fixture.open()
        let teams = TeamChatService(teams: store, provisioning: store, teamConversations: store, teammates: store, selection: store)
        let workspace = DurableWorkspaceModel(service: fixture.chatService(store: store), hiringService: ReferenceUnusedHiringService(),
            profileService: TeammateProfileService(repository: store),
            archiveService: TeammateArchiveService(repository: store),
            teamArchiveService: TeamArchiveService(repository: store),
            draftService: ConversationDraftService(repository: store), teamService: teams)
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let lead = try XCTUnwrap(workspace.selectedTeammate)
        await workspace.createTeammateImmediately()
        let member = try XCTUnwrap(workspace.selectedTeammate)
        let team = try await teams.createTeamChat(.init(name: "Face Check", leadID: lead.id, memberIDs: [lead.id, member.id]))
        await workspace.refreshTeams()
        return (store, workspace, team)
    }

    func testArchiveTeamTakesTheOpenTeamOutOfTheSidebarAndRestoreBringsItBack() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (store, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        let teamID = team.team.id.rawValue
        workspace.sidebar.selection = teamID
        await workspace.selectionTask?.value
        XCTAssertEqual(workspace.conversation.conversationID, team.conversation.id.rawValue)

        await workspace.archiveTeam(id: teamID)
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        XCTAssertEqual(workspace.sidebar.teamRows.map(\.id), [], "The team leaves the sidebar")
        XCTAssertNil(workspace.sidebar.selection, "Its chat does not stay open")
        XCTAssertNil(workspace.conversation.conversationID)
        XCTAssertEqual(workspace.archiveModel?.archivedTeams.map(\.id), [team.team.id])
        let archivedTeam = try await store.team(id: team.team.id)
        XCTAssertEqual(archivedTeam?.lifecycle, .archived)
        XCTAssertEqual(workspace.sidebar.rows.count, 2, "Its bots stay where they are")

        let archived = try XCTUnwrap(workspace.archiveModel?.archivedTeams.first)
        await workspace.restoreTeam(archived)
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        XCTAssertEqual(workspace.sidebar.teamRows.map(\.id), [teamID])
        XCTAssertEqual(workspace.archiveModel?.archivedTeams, [])
    }

    func testArchivingAnUnselectedTeamLeavesTheOpenChatAlone() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (_, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        let open = try XCTUnwrap(workspace.sidebar.selection)
        let openChat = workspace.conversation.conversationID
        XCTAssertNotEqual(open, team.team.id.rawValue)

        await workspace.archiveTeam(id: team.team.id.rawValue)
        XCTAssertEqual(workspace.sidebar.teamRows, [])
        XCTAssertEqual(workspace.sidebar.selection, open)
        XCTAssertEqual(workspace.conversation.conversationID, openChat)
    }

    func testARefusedArchiveRefreshesTheTeamSoTheRetryWorks() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (store, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        // Another writer moves the team after the sidebar read it.
        _ = try await store.execute(sql: "UPDATE teams SET updated_at=updated_at+1 WHERE id=?;",
                                    bindings: [.text(team.team.id.persistedValue)])
        await workspace.archiveTeam(id: team.team.id.rawValue)
        XCTAssertEqual(workspace.archiveModel?.errorMessage, "This team changed in another operation. Try again.")
        XCTAssertEqual(workspace.sidebar.teamRows.map(\.id), [team.team.id.rawValue])
        workspace.archiveModel?.errorMessage = nil
        await workspace.archiveTeam(id: team.team.id.rawValue)
        XCTAssertNil(workspace.archiveModel?.errorMessage, "The retry reads the team afresh")
        XCTAssertEqual(workspace.sidebar.teamRows, [])
    }

    func testAMessageStillSavingInTheOpenTeamChatRefusesTheArchive() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (store, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        let teamID = team.team.id.rawValue
        workspace.sidebar.selection = teamID
        await workspace.selectionTask?.value
        workspace.conversation.composerText = "Sent just before archiving"
        workspace.conversation.sendCurrentText()
        XCTAssertTrue(workspace.conversation.hasPendingSubmissions)
        await workspace.archiveTeam(id: teamID)
        XCTAssertEqual(workspace.archiveModel?.errorMessage,
            "Wait for the message in this team’s chat to finish saving before archiving.")
        let stillActive = try await store.team(id: team.team.id)
        XCTAssertEqual(stillActive?.lifecycle, .active)
        XCTAssertEqual(workspace.sidebar.selection, teamID)
    }

    func testADraftThatCannotBeSavedRefusesTheArchiveAndKeepsTheText() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (store, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        let teamID = team.team.id.rawValue
        workspace.sidebar.selection = teamID
        await workspace.selectionTask?.value
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        let old = try await store.loadDraft(conversationID: team.conversation.id)
        _ = try await ConversationDraftService(repository: store).save(
            conversationID: team.conversation.id, text: "Another editor's draft", expectedRevision: old?.revision ?? 0)
        workspace.conversation.composerText = "My unsaved team draft"
        await workspace.archiveTeam(id: teamID)
        XCTAssertTrue(workspace.archiveModel?.errorMessage?.contains("draft could not be saved") == true)
        XCTAssertEqual(workspace.conversation.composerText, "My unsaved team draft")
        let stillActive = try await store.team(id: team.team.id)
        XCTAssertEqual(stillActive?.lifecycle, .active)
    }

    /// A bot still replying in its own chat once said "a message in this team's chat is saving". Saving is per chat.
    func testAMessageSavingInOneChatCountsForThatChatOnly() async throws {
        let botChat = UUID(), teamChat = UUID()
        let model = ConversationModel(conversationID: botChat,
            submit: { _, _, _ in try? await Task.sleep(for: .seconds(5)) })
        defer { model.beginShutdown() }
        model.composerText = "Still replying"
        model.sendCurrentText()
        XCTAssertTrue(model.hasPendingSubmissions(in: botChat))
        XCTAssertFalse(model.hasPendingSubmissions(in: teamChat))
        model.show(conversationID: teamChat, title: "Crew", messages: [])
        XCTAssertTrue(model.hasPendingSubmissions(in: botChat), "The save keeps its own chat after a switch")
        XCTAssertFalse(model.hasPendingSubmissions(in: teamChat))
    }

    func testAMessageSavingInAnotherChatDoesNotBlockArchivingATeam() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (store, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        XCTAssertNotEqual(workspace.sidebar.selection, team.team.id.rawValue, "A bot's own chat is open")
        workspace.conversation.composerText = "Still saving in the bot's chat"
        workspace.conversation.sendCurrentText()
        XCTAssertTrue(workspace.conversation.hasPendingSubmissions)
        await workspace.archiveTeam(id: team.team.id.rawValue)
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        let archived = try await store.team(id: team.team.id)
        XCTAssertEqual(archived?.lifecycle, .archived)
    }

    func testTheArchiveWindowListsBotsAndTeamsApartAndSaysWhyARefusalHappened() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (_, workspace, team) = try await setUp(fixture)
        defer { workspace.finishShutdown() }
        let archive = try XCTUnwrap(workspace.archiveModel)
        await workspace.archiveTeam(id: team.team.id.rawValue)
        await archive.load()
        XCTAssertEqual(archive.archivedBots, [], "The team's bots are not archived with it")
        XCTAssertEqual(archive.archivedTeams.map(\.id), [team.team.id], "A fresh load lists the archived team under Teams")
        XCTAssertEqual(BotArchiveModel.teamMessage(for: TeamArchiveError.unresolvedWork),
            "This team still has work in progress or a handoff waiting for you. Let it finish or stop it before archiving. Nothing was cancelled.")
        XCTAssertEqual(BotArchiveModel.teamMessage(for: TeamArchiveError.staleTeam),
            "This team changed in another operation. Try again.")
    }
}
