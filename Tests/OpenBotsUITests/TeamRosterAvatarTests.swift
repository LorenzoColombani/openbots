import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class TeamRosterAvatarTests: XCTestCase {
    func testRosterUsesMemberIDsAndExistingLiveModelsAcrossMembershipChanges() {
        let bots = (0..<5).map { index in
            TeammateRowSnapshot(id: UUID(), name: "Same name", role: "Bot \(index)", activity: .idle, identitySeed: UInt64(index))
        }
        let sidebar = SidebarModel(rows: bots)
        var team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "Actual team", leadName: bots[0].name,
            members: [bots[3], bots[0], bots[2]].map { .init(id: $0.id, name: $0.name) }, lastActivityAt: nil)
        let original = TeamRosterAvatarPolicy.rows(for: team, from: sidebar.rowModels)
        XCTAssertEqual(original.map(\.id), [bots[3].id, bots[0].id, bots[2].id])
        XCTAssertTrue(original[0] === sidebar.rowModels[3])
        sidebar.update(.init(identity: bots[3].identity, activity: .speaking))
        XCTAssertEqual(original[0].snapshot.activity, .speaking, "The team uses the live model, not a reconstructed idle identity")
        team = TeamRowSnapshot(id: team.id, conversationID: UUID(), name: team.name, leadName: bots[0].name,
            members: [bots[0], bots[4]].map { .init(id: $0.id, name: $0.name) }, lastActivityAt: nil)
        XCTAssertEqual(TeamRosterAvatarPolicy.rows(for: team, from: sidebar.rowModels).map(\.id), [bots[0].id, bots[4].id])
        XCTAssertTrue(TeamRosterAvatarPolicy.accessibilityLabel(for: team).contains("2 members"))
        XCTAssertTrue(TeamRosterAvatarPolicy.accessibilityLabel(for: team).contains("Members: Same name, Same name"))
    }

    /// A hidden bot keeps its seat and shows in its teams. Its live row feeds the team
    /// surfaces and never the list, and Unhide never draws it twice.
    func testAHiddenMemberHasATeamRowAndNoListRow() {
        let mira = TeammateRowSnapshot(id: UUID(), name: "Mira", role: "Lead", activity: .idle, identitySeed: 1)
        let ada = TeammateRowSnapshot(id: UUID(), name: "Ada", role: "Member", activity: .idle, identitySeed: 2)
        let sidebar = SidebarModel(rows: [mira])
        sidebar.replaceHiddenMembers([ada])
        XCTAssertEqual(sidebar.rows.map(\.id), [mira.id])
        XCTAssertEqual(sidebar.teamMemberRowModels.map(\.id), [mira.id, ada.id])
        let seat = sidebar.hiddenMemberRowModels[0]
        sidebar.update(.init(identity: ada.identity, activity: .speaking))
        XCTAssertEqual(sidebar.rows.map(\.id), [mira.id], "An update never lists a hidden member")
        XCTAssertEqual(seat.snapshot.activity, .speaking)
        sidebar.replaceHiddenMembers([ada])
        XCTAssertTrue(sidebar.hiddenMemberRowModels[0] === seat, "A refresh keeps the face already on screen")
        // Unhide lists her before the team snapshot has caught up.
        sidebar.replace(rows: [mira, ada])
        XCTAssertEqual(sidebar.teamMemberRowModels.map(\.id), [mira.id, ada.id])
        XCTAssertTrue(sidebar.teamMemberRowModels[1] === sidebar.rowModels[1])
    }

    func testNormalFeedbackHidesOnlyTransportAndKeepsAcknowledgementCardsAndFailures() {
        for phase in [ClaudeTextReplyPhase.sending, .responding, .saving] {
            XCTAssertFalse(NormalBusyFeedbackPolicy.showsCaption(for: phase))
        }
        for phase in [ClaudeTextReplyPhase.stopping, .stopped, .failed(.persistenceFailed)] {
            XCTAssertTrue(NormalBusyFeedbackPolicy.showsCaption(for: phase))
        }
        let identity = TeammateRowSnapshot(id: UUID(), name: "Ada", role: "Member", activity: .speaking, identitySeed: 3).identity
        var message = ChatMessageSnapshot(id: UUID(), author: .teammate(identity), parts: [], delivery: .pending,
            streamState: .streaming, timestamp: Date())
        XCTAssertTrue(NormalBusyFeedbackPolicy.hidesPlaceholder(message))
        message = .init(id: message.id, author: message.author, body: "I’ll check the notes.", delivery: .pending,
            streamState: .streaming, timestamp: message.timestamp)
        XCTAssertFalse(NormalBusyFeedbackPolicy.hidesPlaceholder(message), "A committed acknowledgement remains content")
        message.deliveryNotice = "Actual Claude reply · partial text saved"
        XCTAssertNil(NormalBusyFeedbackPolicy.deliveryNotice(for: message))
        message.deliveryNotice = "Claude delivery outcome unknown"
        XCTAssertEqual(NormalBusyFeedbackPolicy.deliveryNotice(for: message), "Claude delivery outcome unknown")
        let question = ChatQuestionCardSnapshot(id: UUID(), prompt: "Which source?", choices: [], allowsFreeText: true)
        message = .init(id: message.id, author: message.author, parts: [.init(id: UUID(), ordinal: 0, content: .question(question))],
            delivery: .pending, streamState: .streaming, timestamp: message.timestamp)
        XCTAssertFalse(NormalBusyFeedbackPolicy.hidesPlaceholder(message))
        message = .init(id: message.id, author: message.author,
            parts: [.init(id: UUID(), ordinal: 0, content: .status("Claude could not complete this reply"))],
            delivery: .failed("Saved text is kept"), streamState: .failed("Interrupted"), timestamp: message.timestamp)
        XCTAssertFalse(NormalBusyFeedbackPolicy.hidesPlaceholder(message))
        message = .init(id: message.id, author: message.author, parts: [], delivery: .pending,
            streamState: .failed("Interrupted before content"), timestamp: message.timestamp)
        XCTAssertFalse(NormalBusyFeedbackPolicy.hidesPlaceholder(message), "A failure cannot disappear merely because it has no body")
    }

    /// Every sent message once carried
    /// "Saved on this Mac · Claude delivery not verified", the fallback for a
    /// message with no recorded delivery. A sent message's routine save is not
    /// news; the same words under a message that is not sent still show.
    func testTheUnverifiedFallbackIsHiddenUnderASentMessageOnly() {
        let fallback = "Saved on this Mac · Claude delivery not verified"
        var message = ChatMessageSnapshot(id: UUID(), author: .user, body: "Hello", delivery: .sent,
                                          streamState: .notStreaming, timestamp: Date())
        message.deliveryNotice = fallback
        XCTAssertNil(NormalBusyFeedbackPolicy.deliveryNotice(for: message))
        message = .init(id: message.id, author: .user, body: "Hello", delivery: .pending,
                        streamState: .notStreaming, timestamp: message.timestamp)
        message.deliveryNotice = fallback
        XCTAssertEqual(NormalBusyFeedbackPolicy.deliveryNotice(for: message), fallback)
    }

    func testSpeakingContinuesTheExistingWorkingLoopAndReduceMotionStillFreezesIt() {
        for seed: UInt64 in [1, 27, 402] {
            XCTAssertEqual(CharacterIdleMotion.keyframes(seed: seed, activity: .speaking),
                           CharacterIdleMotion.keyframes(seed: seed, activity: .thinkingOrWorking))
            for phase in CharacterIdlePhase.allCases {
                XCTAssertEqual(CharacterIdleMotion.transform(activity: .speaking, mode: .creature, phase: phase,
                    reduceMotion: true, sceneIsActive: true, isVisible: true), .identity)
            }
        }
    }

    func testBoundedRosterAndFourthWorkingMemberRenderAndReactWithoutAVisibleWindow() async throws {
        _ = NSApplication.shared
        let bots = (0..<4).map { index in
            TeammateRowSnapshot(id: UUID(), name: "Member \(index)", role: "Team member", activity: .idle, identitySeed: UInt64(index))
        }
        let sidebar = SidebarModel(rows: bots)
        let team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "Four members", leadName: bots[0].name,
            members: bots.map { .init(id: $0.id, name: $0.name) }, lastActivityAt: nil)
        sidebar.replaceTeams([team])
        let controller = NSHostingController(rootView: RosterFixture(sidebar: sidebar))
        controller.sizingOptions = []
        let window = RosterTestWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 150)
        try await settle(controller.view)
        XCTAssertEqual(faceCount(controller.view), 3, "A four-member roster must use three real artwork leaves and an overflow count")
        sidebar.update(.init(identity: bots[3].identity, activity: .speaking))
        try await settle(controller.view)
        XCTAssertEqual(faceCount(controller.view), 3, "Work in the member's own chat never shows in the team's indicator")
        sidebar.update(.init(identity: bots[3].identity, activity: .idle))
        sidebar.setWorkingAvatarByConversation([team.conversationID: .init(teammateID: bots[3].id, activity: .speaking)])
        try await settle(controller.view)
        XCTAssertEqual(faceCount(controller.view), 4, "The actual fourth member must appear in the main-chat indicator even though its face is beyond the cluster bound")
        sidebar.setWorkingAvatarByConversation([team.conversationID: .init(teammateID: bots[3].id, activity: .waitingForUser)])
        try await settle(controller.view)
        XCTAssertEqual(faceCount(controller.view), 4, "Waiting for a user keeps the real member visible")
        sidebar.setWorkingAvatarByConversation([:])
        try await settle(controller.view)
        XCTAssertEqual(faceCount(controller.view), 3, "An ended turn removes the working indicator")
        sidebar.replaceTeams([.init(id: team.id, conversationID: team.conversationID, name: team.name, leadName: bots[0].name,
            members: [.init(id: bots[0].id, name: bots[0].name)], lastActivityAt: nil)])
        try await settle(controller.view)
        XCTAssertEqual(faceCount(controller.view), 1, "Membership changes must replace the composite identity")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func faceCount(_ view: NSView) -> Int {
        (view is CharacterMotionVisibilityView ? 1 : 0) + view.subviews.reduce(0) { $0 + faceCount($1) }
    }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A member working in its own chat once
    /// showed a working badge beside its name in the team header, because the
    /// header's member buttons read the bot's own row. Inside a team, a member
    /// moves only when this conversation's turn is theirs.
    func testTeamSurfacesShowAMemberWorkingOnlyForThisConversationsTurn() {
        let ada = UUID(), mira = UUID()
        XCTAssertEqual(TeamRosterAvatarPolicy.activity(of: ada, in: nil), .idle,
                       "Busy in her own chat, no turn here: still inside the team")
        let adaHere = ConversationWorkingAvatar(teammateID: ada, activity: .waitingForUser)
        XCTAssertEqual(TeamRosterAvatarPolicy.activity(of: ada, in: adaHere), .waitingForUser)
        XCTAssertEqual(TeamRosterAvatarPolicy.activity(of: mira, in: adaHere), .idle)
    }

    /// The team header's names: a member busy
    /// in its own chat reads Idle there; the team's own turn reads through, for
    /// a live member and for one whose row has not loaded yet. SwiftUI builds no
    /// accessibility tree offscreen, so the header's own per-member answer is
    /// checked here and the drawn value on the installed app.
    func testTheTeamHeaderNamesReadThisConversationsTurnNotTheBotsOwnChat() {
        let ada = TeammateRowSnapshot(id: UUID(), name: "Ada", role: "Member", activity: .thinkingOrWorking, identitySeed: 3)
        let mira = TeammateRowSnapshot(id: UUID(), name: "Mira", role: "Member", activity: .idle, identitySeed: 4)
        let team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "Crew", leadName: ada.name,
            members: [ada, mira].map { .init(id: $0.id, name: $0.name) }, lastActivityAt: nil)
        func header(_ working: ConversationWorkingAvatar?) -> SelectedTeamHeader {
            SelectedTeamHeader(row: team, memberRows: [TeammateRowModel(snapshot: ada)],
                members: [ada.identity, mira.identity], openMemberSettings: { _ in }, workingAvatar: working)
        }
        XCTAssertEqual(header(nil).activity(of: ada.id), .idle, "Working in her own chat does not show inside the team")
        XCTAssertEqual(header(.init(teammateID: ada.id, activity: .thinkingOrWorking)).activity(of: ada.id), .thinkingOrWorking)
        let miraHere = header(.init(teammateID: mira.id, activity: .speaking))
        XCTAssertEqual(miraHere.activity(of: mira.id), .speaking, "A member whose row has not loaded still shows the team's turn")
        XCTAssertEqual(miraHere.activity(of: ada.id), .idle)
    }

    /// The roster face of a member whose row has not loaded yet follows this
    /// team's turn too: it used to stay idle.
    func testARosterFaceWithoutALiveRowStillMovesForThisTeamsTurn() async throws {
        let mira = TeammateRowSnapshot(id: UUID(), name: "Mira", role: "Member", activity: .idle, identitySeed: 4)
        let team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "Crew", leadName: mira.name,
            members: [.init(id: mira.id, name: mira.name)], lastActivityAt: nil)
        func workingFaces(_ working: ConversationWorkingAvatar?) async throws -> [String] {
            let host = NSHostingController(rootView: TeamRosterAvatar(row: team, memberRows: [],
                fallbackMembers: [mira.identity], workingAvatar: working))
            host.sizingOptions = []
            host.view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
            try await settle(host.view)
            func targets(in view: NSView) -> [CharacterWorkingAccessibilityView] {
                (view as? CharacterWorkingAccessibilityView).map { [$0] } ?? view.subviews.flatMap(targets(in:))
            }
            return targets(in: host.view).map { $0.accessibilityIdentifier() }
        }
        let quiet = try await workingFaces(nil)
        XCTAssertEqual(quiet, [])
        let here = try await workingFaces(.init(teammateID: mira.id, activity: .thinkingOrWorking))
        XCTAssertEqual(here, ["working-avatar-\(mira.id.uuidString)-in-\(team.conversationID.uuidString)"])
    }

    /// A loaded member busy in its own chat stays still on the team's face; the
    /// team's own turn moves it.
    func testALiveMemberBusyInItsOwnChatStaysStillOnTheTeamsFace() async throws {
        let ada = TeammateRowModel(snapshot: .init(id: UUID(), name: "Ada", role: "Member",
                                                   activity: .thinkingOrWorking, identitySeed: 3))
        let team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "Crew", leadName: "Ada",
            members: [.init(id: ada.id, name: "Ada")], lastActivityAt: nil)
        func workingFaces(_ working: ConversationWorkingAvatar?) async throws -> [String] {
            let host = NSHostingController(rootView: TeamRosterAvatar(row: team, memberRows: [ada], workingAvatar: working))
            host.sizingOptions = []
            host.view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
            try await settle(host.view)
            func targets(in view: NSView) -> [CharacterWorkingAccessibilityView] {
                (view as? CharacterWorkingAccessibilityView).map { [$0] } ?? view.subviews.flatMap(targets(in:))
            }
            return targets(in: host.view).map { $0.accessibilityIdentifier() }
        }
        let ownChat = try await workingFaces(nil)
        XCTAssertEqual(ownChat, [], "Her own chat's work does not move her face inside the team")
        let here = try await workingFaces(.init(teammateID: ada.id, activity: .thinkingOrWorking))
        XCTAssertEqual(here, ["working-avatar-\(ada.id.uuidString)-in-\(team.conversationID.uuidString)"])
    }

    /// The composer's working line and a bubble's face ask whether the chat on
    /// screen is a team's, never how many bots take part: a team of one is still
    /// a team. Outside a team they follow the bot's row.
    func testTheWorkingLineAndBubblesFollowTheTeamTurnInATeamAndTheBotsRowElsewhere() {
        let ada = UUID(), mira = UUID()
        let adaHere = ConversationWorkingAvatar(teammateID: ada, activity: .thinkingOrWorking)
        XCTAssertNil(TeamRosterAvatarPolicy.override(of: ada, team: nil), "A direct chat follows the bot's own row")
        XCTAssertEqual(TeamRosterAvatarPolicy.override(of: ada, team: .some(nil)), .idle,
                       "A team with nobody working here: still, whatever the bot does in its own chat")
        XCTAssertEqual(TeamRosterAvatarPolicy.override(of: ada, team: .some(adaHere)), .thinkingOrWorking)
        XCTAssertEqual(TeamRosterAvatarPolicy.override(of: mira, team: .some(adaHere)), .idle)
    }
}

private struct RosterFixture: View {
    @ObservedObject var sidebar: SidebarModel
    var body: some View {
        if let team = sidebar.teamRows.first {
            let members = TeamRosterAvatarPolicy.rows(for: team, from: sidebar.rowModels)
            HStack {
                TeamRosterAvatar(row: team, memberRows: members)
                ForEach(members) { member in
                    WorkingBotIndicator(row: member,
                        activityOverride: TeamRosterAvatarPolicy.override(of: member.id,
                            team: .some(sidebar.workingAvatarByConversation[team.conversationID])),
                        conversationID: team.conversationID)
                }
            }
        }
    }
}

@MainActor
private final class RosterTestWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
