import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@Suite("Team creation model")
@MainActor
struct TeamCreationModelTests {
    func identity(_ n: UInt8, _ name: String) -> TeammateIdentitySnapshot {
        TeammateIdentitySnapshot(id: UUID(uuidString: String(format: "b3000000-0000-0000-0000-%012d", n))!,
                                 name: name, role: "Role", appearance: .fixture(seed: UInt64(n)))
    }

    @Test("Creating needs a name, at least two members and a lead among them")
    func submitRules() async {
        let ada = identity(1, "Ada"), mira = identity(2, "Mira")
        let model = TeamCreationModel(candidates: [mira, ada]) { _, _, _ in }
        #expect(model.candidates.map(\.name) == ["Ada", "Mira"])
        #expect(model.name == "New Team")
        #expect(!model.canSubmit)
        model.toggleMember(ada.id)
        #expect(model.leadID == ada.id)
        #expect(!model.canSubmit)
        model.toggleMember(mira.id)
        #expect(model.canSubmit)
        model.leadID = mira.id
        model.toggleMember(mira.id)
        #expect(model.leadID == ada.id)
        #expect(!model.canSubmit)
        model.toggleMember(mira.id)
        model.name = "   "
        #expect(!model.canSubmit)
        model.name = String(repeating: "x", count: 121)
        #expect(!model.canSubmit)
        model.name = "QA Team"
        #expect(model.canSubmit)
    }

    @Test("Submitting passes the trimmed name, the lead and the members once; a failure keeps the sheet with a message")
    func submitPassesTheDraft() async {
        let ada = identity(1, "Ada"), mira = identity(2, "Mira")
        @MainActor final class Recorder { var received: [(String, UUID, Set<UUID>)] = [] }
        let recorder = Recorder()
        let model = TeamCreationModel(candidates: [ada, mira]) { name, lead, members in recorder.received.append((name, lead, members)) }
        model.toggleMember(ada.id); model.toggleMember(mira.id); model.leadID = mira.id
        model.name = "  QA Team "
        #expect(await model.submit())
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.0 == "QA Team")
        #expect(recorder.received.first?.1 == mira.id)
        #expect(recorder.received.first?.2 == [ada.id, mira.id])
        #expect(!(await model.submit()))
        #expect(recorder.received.count == 1)

        struct Boom: Error {}
        let failing = TeamCreationModel(candidates: [ada, mira]) { _, _, _ in throw Boom() }
        failing.toggleMember(ada.id); failing.toggleMember(mira.id)
        #expect(!(await failing.submit()))
        #expect(failing.submissionError == "OpenBots couldn’t create this team. Nothing was saved.")
        #expect(failing.canSubmit)
    }

    @Test("An edit is seeded with the team\'s name, members and lead, and carries the edit copy")
    func editModeSeedsTheTeam() async {
        let ada = identity(1, "Ada"), mira = identity(2, "Mira"), zed = identity(3, "Zed")
        let stranger = UUID()
        let model = TeamCreationModel(mode: .edit, candidates: [zed, mira, ada], name: "QA Team",
                                      memberIDs: [ada.id, mira.id, stranger], leadID: mira.id) { _, _, _ in }
        #expect(model.candidates.map(\.name) == ["Ada", "Mira", "Zed"])
        #expect(model.name == "QA Team")
        // A seed outside the candidates cannot be drawn as a checkbox, so it is
        // dropped rather than silently resubmitted.
        #expect(model.selectedMemberIDs == [ada.id, mira.id])
        #expect(model.leadID == mira.id)
        #expect(model.canSubmit)
        #expect(model.title == "Team Settings")
        #expect(model.submitTitle == "Save Changes")
        #expect(model.submitIdentifier == "team-save")
        #expect(model.submitHelp == "Save the team’s members and lead")
    }

    @Test("A lead seeded outside the seeded members is dropped; the create copy and identifiers are unchanged")
    func editLeadOutsideMembersIsDropped() async {
        let ada = identity(1, "Ada"), mira = identity(2, "Mira"), zed = identity(3, "Zed")
        let model = TeamCreationModel(mode: .edit, candidates: [ada, mira, zed], name: "QA Team",
                                      memberIDs: [ada.id, mira.id], leadID: zed.id) { _, _, _ in }
        #expect(model.leadID == nil)
        #expect(!model.canSubmit)
        model.leadID = ada.id
        #expect(model.canSubmit)

        let creating = TeamCreationModel(candidates: [ada, mira]) { _, _, _ in }
        #expect(creating.mode == .create)
        #expect(creating.title == "New Team")
        #expect(creating.name == "New Team")
        #expect(creating.submitTitle == "Create Team")
        #expect(creating.submitIdentifier == "team-create")
        #expect(creating.submitHelp == "Create Team")
        #expect(creating.selectedMemberIDs.isEmpty)
        #expect(creating.leadID == nil)
    }

    @Test("Unticking an edit's lead leaves the role empty until a replacement is named")
    func editUntickingTheLeadLeavesItUnset() async {
        let ada = identity(1, "Ada"), mira = identity(2, "Mira"), zed = identity(3, "Zed")
        let model = TeamCreationModel(mode: .edit, candidates: [ada, mira, zed], name: "QA Team",
                                      memberIDs: [ada.id, mira.id, zed.id], leadID: mira.id) { _, _, _ in }
        // Ada sorts first among the members that remain, which is exactly who
        // a silent promotion would hand the role to.
        model.toggleMember(mira.id)
        #expect(model.leadID == nil)
        #expect(!model.canSubmit)
        // Naming a lead is the deliberate act that unblocks the save; reticking
        // the bot that was removed is one way to do it.
        model.toggleMember(mira.id)
        #expect(model.leadID == mira.id)
        #expect(model.canSubmit)
    }

    @Test("A refused save keeps the edit sheet with its own message")
    func editFailureKeepsTheSheet() async {
        struct Boom: Error {}
        let ada = identity(1, "Ada"), mira = identity(2, "Mira")
        let model = TeamCreationModel(mode: .edit, candidates: [ada, mira], name: "QA Team",
                                      memberIDs: [ada.id, mira.id], leadID: mira.id) { _, _, _ in throw Boom() }
        #expect(!(await model.submit()))
        #expect(model.submissionError == "OpenBots couldn’t save these changes. The team is unchanged.")
        #expect(model.canSubmit)
    }

    @Test("A save refused because the team changed elsewhere says so instead of calling the team unchanged")
    func staleEditNamesTheOtherWriter() async {
        let ada = identity(1, "Ada"), mira = identity(2, "Mira")
        let teamID = TeamID(UUID())
        @MainActor final class Attempts { var count = 0 }
        let attempts = Attempts()
        let model = TeamCreationModel(mode: .edit, candidates: [ada, mira], name: "QA Team",
                                      memberIDs: [ada.id, mira.id], leadID: mira.id) { _, _, _ in
            attempts.count += 1
            throw TeamChatError.teamChangedElsewhere(teamID)
        }
        #expect(!(await model.submit()))
        #expect(model.submissionError == "Someone else changed this team while it was open. Nothing was saved; "
            + "close and reopen the editor to see the current roster.")
        // The roster on screen was read before the other writer's, so pressing
        // Save again would publish it over theirs. The control the message
        // sends the user to is the one that stays live.
        #expect(!model.canSubmit)
        #expect(!(await model.submit()))
        #expect(model.submissionError == "Someone else changed this team while it was open. Nothing was saved; "
            + "close and reopen the editor to see the current roster.",
            "a refused second Save cleared the message that explains why Save is dead")
        #expect(attempts.count == 1, "a second Save reached the writer the refusal was about")
    }

    @Test("A sidebar holding only teams is not empty, so the first-bot invitation stays off it")
    func aSidebarHoldingOnlyTeamsIsNotEmpty() {
        let sidebar = SidebarModel()
        #expect(sidebar.isEmpty)
        let team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "QA Team", leadName: "Mira",
                                   members: [.init(id: UUID(), name: "Mira"), .init(id: UUID(), name: "Ada")],
                                   lastActivityAt: nil)
        sidebar.replaceTeams([team])
        // Every member archived leaves the team with no bot row of its own,
        // and the invitation to start a first bot covers the whole list.
        #expect(sidebar.rows.isEmpty)
        #expect(!sidebar.isEmpty)
        sidebar.replaceTeams([])
        #expect(sidebar.isEmpty)
    }

    @Test("The sidebar keeps a team selection when bot rows are replaced")
    func sidebarKeepsTeamSelection() {
        let sidebar = SidebarModel()
        let team = TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "QA Team", leadName: "Mira", members: [.init(id: UUID(), name: "Ada"), .init(id: UUID(), name: "Mira")], lastActivityAt: nil)
        sidebar.replaceTeams([team])
        sidebar.selection = team.id
        sidebar.replace(rows: [])
        #expect(sidebar.selection == team.id)
        #expect(sidebar.teamRows.first?.memberSummary == "Lead: Mira · 2 members")
        sidebar.replaceTeams([])
        #expect(sidebar.selection == nil)
    }
}
