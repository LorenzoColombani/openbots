import Foundation
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsRuntime
import OpenBotsServices
@testable import OpenBotsUI
import Testing

/// Bots that hire bots, on screen: a hire made by a reply
/// shows its bot in the sidebar and the team, never moves the person's
/// selection, and its note reads as the app's own line, not a failed reply.
/// Over the real store, the real reply and hiring services, and a CLI stand-in.
@MainActor
@Suite("A hire on screen")
struct HireWorkspaceTests {
    @Test("The hired bot's row appears at the top while the person's chat stays selected, and the note reads as OpenBots, before and after a relaunch")
    func theHireAppearsWithoutMovingTheSelection() async throws {
        let setup = try await HireWorkspaceSetup()
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        #expect(model.sidebar.selection == setup.kite.rawValue)

        model.conversation.composerText = "We need someone watching prices."
        model.conversation.sendCurrentText()
        let note = "Kite hired @Scout (\"Price watching\")."
        try await eventually { model.conversation.messages.contains { $0.body == note } }

        let scoutRow = try #require(model.sidebar.rows.first)
        #expect(scoutRow.name == "Scout", "the hired bot is at the top")
        #expect(model.sidebar.selection == setup.kite.rawValue, "the conversation the hire came from stays selected")
        #expect(model.conversation.conversationID == setup.kiteChat.rawValue)
        let presented = try #require(model.conversation.messages.last)
        #expect(presented.body == note)
        #expect(presented.author == .system(label: "OpenBots"))
        #expect(presented.deliveryNotice == DurableWorkspaceModel.hireNoteNotice)
        #expect(presented.deliveryNotice != "OpenBots status · no Claude reply received")

        // A relaunch reads the note back from the store and still knows it.
        let reopened = setup.workspace()
        defer { reopened.finishShutdown() }
        try await reopened.loadInitialWorkspace()
        #expect(reopened.sidebar.selection == setup.kite.rawValue)
        let saved = try #require(reopened.conversation.messages.last)
        #expect(saved.body == note)
        #expect(saved.deliveryNotice == DurableWorkspaceModel.hireNoteNotice)
    }

    @Test("A hire from the open team conversation joins the team's roster on screen, and the team stays open")
    func aTeamHireJoinsTheRosterOnScreen() async throws {
        let setup = try await HireWorkspaceSetup()
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        model.sidebar.selection = setup.teamID.rawValue
        // The conversation id switches before the team finishes opening, and a
        // send while it reads "Opening the team conversation…" is refused. Under
        // a parallel run the send used to land in that window, so no turn ran.
        try await eventually {
            model.conversation.conversationID == setup.teamChat.rawValue && model.conversation.inputAvailability == .ready
        }

        model.conversation.composerText = "We need someone watching prices."
        model.conversation.sendCurrentText()
        try await eventually { model.selectedTeam?.members.contains { $0.profile.displayName == "Scout" } == true }
        #expect(model.sidebar.selection == setup.teamID.rawValue)
        #expect(model.sidebar.rows.contains { $0.name == "Scout" })
        try await eventually { model.conversation.messages.contains { $0.body == "Kite hired @Scout (\"Price watching\")." } }
    }

    @Test("Details shows a bot's seat under its own heading, one labelled line per field it has, and nothing when it has none")
    func detailsShowsTheSeat() throws {
        let seat = try TeammateSeat(purview: "Competitor prices", never: "Bookkeeping, which Ledger owns", escalate: "Any spend")
        #expect(BotSeatCopy.heading == "Seat")
        #expect(BotSeatCopy.rows(seat).map(\.label) == ["Owns", "Hands off", "Escalates"])
        #expect(BotSeatCopy.rows(seat).map(\.text) == ["Competitor prices", "Bookkeeping, which Ledger owns", "Any spend"])
        #expect(BotSeatCopy.rows(nil).isEmpty)
        let full = try TeammateSeat(purview: "a", never: "b", interfaces: "c", escalate: "d")
        #expect(BotSeatCopy.rows(full).map(\.label) == ["Owns", "Hands off", "Works with", "Escalates"])
    }

    @Test("Details says a hired bot's profile was written by its hirer and not yet reviewed, and says nothing once the person has saved it")
    func detailsNamesTheHirerUntilThePersonSaves() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        func bot(hirer: String?) throws -> Teammate {
            try Teammate(id: TeammateID(UUID()),
                profile: TeammateProfile(displayName: "Scout", role: "Price watching", seat: TeammateSeat(purview: "Competitor prices")),
                appearance: CreatureAllocation(id: UUID()).appearance(), createdAt: date, updatedAt: date,
                profileWrittenByHirer: hirer)
        }
        #expect(BotSeatCopy.authorLine(for: try bot(hirer: "Kite"))
            == "Written by @Kite when hiring; you have not reviewed it yet.")
        #expect(BotSeatCopy.authorLine(for: try bot(hirer: nil)) == nil)
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition never held")
}

/// Kite (selected, holding both hire switches) and Ledger, on the QA Team with
/// Kite leading, over a real store; a reply service whose CLI stand-in hires
/// Scout once per turn.
@MainActor
private struct HireWorkspaceSetup {
    let fixture: ReferenceLocalWorkspaceFixture
    let store: SQLiteStore
    let switches: AgenticJobAccessStore
    let kite = TeammateID(UUID()), ledger = TeammateID(UUID())
    let kiteChat = ConversationID(UUID()), teamID = TeamID(UUID()), teamChat = ConversationID(UUID())

    init() async throws {
        fixture = try ReferenceLocalWorkspaceFixture()
        store = try fixture.open()
        let date = Date(timeIntervalSince1970: 9_000)
        for (id, chat, name, selected) in [(kite, kiteChat, "Kite", true), (ledger, ConversationID(UUID()), "Ledger", false)] {
            let bot = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: "Teammate"),
                appearance: try CreatureAllocation(id: id.rawValue).appearance(), createdAt: date, updatedAt: date)
            try await store.provisionDirectChat(teammate: bot,
                conversation: Conversation(id: chat, kind: .direct(teammateID: id), title: name, createdAt: date, updatedAt: date),
                fixtureGreeting: nil, selectConversation: selected)
        }
        try await store.provisionTeam(Team(id: teamID, name: "QA Team", leadID: kite, memberIDs: [kite, ledger], createdAt: date, updatedAt: date),
            conversation: Conversation(id: teamChat, kind: .team(teamID: teamID), title: "QA Team", createdAt: date, updatedAt: date),
            selectConversation: false)
        switches = AgenticJobAccessStore(reportWriteFailure: { _ in })
        await switches.setAppEnabled(true, capability: .hire)
        await switches.setBotEnabled(true, capability: .hire, teammateID: kite)
    }

    func remove() { try? FileManager.default.removeItem(at: fixture.directory) }

    func workspace() -> DurableWorkspaceModel {
        let chats = fixture.chatService(store: store)
        let teams = TeamChatService(teams: store, provisioning: store, teamConversations: store, teammates: store, selection: store)
        let target = try! ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/HireWorkspace.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/HireWorkspace.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/HireWorkspace.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        let hiring = TeammateHiringService(access: switches, teammates: store, conversations: store, chats: chats, teamChats: teams)
        let reply = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store, messages: store,
            preparer: HireWorkspacePreparer(target: target), runner: HireWorkspaceRunner(), appOwnerID: UUID(),
            teams: store, handoffs: store, webAccess: switches, activity: store, hiring: hiring)
        return DurableWorkspaceModel(mode: .localOnly, service: chats, textReplyService: reply, agenticJobAccess: switches,
            hiringService: ReferenceUnusedHiringService(), teamService: teams)
    }
}

private struct HireWorkspacePreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

/// The CLI side: the bot's reply announces one hire call and hands it to the
/// host; the host's answer is not waited for, because this suite reads the
/// screen, not the wire.
private struct HireWorkspaceRunner: ClaudeTextOnlyRunning {
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        if request.grantsHiring, control != nil {
            let input = (try? JSONSerialization.data(withJSONObject: ["handle": "Scout", "purpose": "Price watching"],
                                                     options: [.sortedKeys])) ?? Data()
            await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_hire", toolName: ClaudeTextHirePolicy.qualifiedToolName, inputJSON: input)))
            await onEvent(.hireRequested(ClaudeTextHireCall(requestID: "call-1", toolUseID: "toolu_hire",
                                                            argumentsJSON: input, isOwnCall: true)))
            await onEvent(.toolFinished(toolUseID: "toolu_hire", failed: false))
        }
        let text = "Scout is on it."
        await onEvent(.textSnapshot(text))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: text, confirmedActualModel: request.expectedResolvedModel))
    }
}
