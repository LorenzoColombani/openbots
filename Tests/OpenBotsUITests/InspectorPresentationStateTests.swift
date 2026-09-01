import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@Suite("Inspector presentation state")
@MainActor
struct InspectorPresentationStateTests {
    @Test("Repeated native presentation writebacks publish neither object nor property changes")
    func repeatedStateRequestsDoNotPublish() throws {
        let model = try makeModel()
        var objectChangeCount = 0
        var states: [Bool] = []
        let objectSubscription = model.objectWillChange.sink { objectChangeCount += 1 }
        let stateSubscription = model.$isInspectorPresented.dropFirst().sink { states.append($0) }

        for _ in 0..<8 { model.hideInspector() }
        #expect(objectChangeCount == 0)
        #expect(states.isEmpty)

        model.showInspector()
        for _ in 0..<8 { model.showInspector() }
        #expect(model.isInspectorPresented)
        #expect(objectChangeCount == 1)
        #expect(states == [true])

        model.hideInspector()
        for _ in 0..<8 { model.hideInspector() }
        #expect(!model.isInspectorPresented)
        #expect(objectChangeCount == 2)
        #expect(states == [true, false])
        withExtendedLifetime((objectSubscription, stateSubscription)) {}
    }

    @Test("Open, close, and toggle each publish exactly one real state transition")
    func realTransitionsPublishOnce() throws {
        let model = try makeModel()
        var objectChangeCount = 0
        var states: [Bool] = []
        let objectSubscription = model.objectWillChange.sink { objectChangeCount += 1 }
        let stateSubscription = model.$isInspectorPresented.dropFirst().sink { states.append($0) }

        model.showInspector()
        model.hideInspector()
        model.toggleInspector()
        model.toggleInspector()

        #expect(!model.isInspectorPresented)
        #expect(objectChangeCount == 4)
        #expect(states == [true, false, true, false])
        withExtendedLifetime((objectSubscription, stateSubscription)) {}
    }

    @Test("Presentation requests preserve work context, review state, and an unfinished team draft")
    func presentationPreservesContextAndDraft() async throws {
        let teammate = try s3ATeammate(61, name: "Inspector Fixture", role: "Local reviewer")
        let project = try s3AProject(61, name: "Inspector Project", members: [teammate])
        let team = try s3ATeam(61, name: "Inspector Team", members: [teammate], lead: teammate)
        let service = S3AProjectTeamDirectoryFake(
            teammates: [teammate], projects: [project], teams: [team]
        )
        let model = CollaborationWorkspaceModel(
            directoryService: service,
            reviewFixtureService: try CollaborationReviewFixtureService(),
            availableTeammates: [TeammateIdentitySnapshot(teammate)]
        )
        await model.load()
        let conversationID = UUID()
        model.activateConversation(conversationID, selectedTeammateID: teammate.id.rawValue)
        model.selectReviewVariant(.needsRecovery)
        model.beginCreation(.team)
        model.draftName = "Unfinished draft"
        model.draftSummary = "Keep these unsaved details."
        let handoff = model.conversationFixtureMessage(for: conversationID)

        model.showInspector()
        model.hideInspector()
        model.hideInspector()
        model.showInspector()
        model.toggleInspector()
        model.toggleInspector()

        #expect(model.isInspectorPresented)
        #expect(model.selectedProjectID == project.project.id.rawValue)
        #expect(model.selectedTeamID == team.team.id.rawValue)
        #expect(model.reviewVariant == .needsRecovery)
        #expect(model.conversationFixtureMessage(for: conversationID) == handoff)
        #expect(model.creationKind == .team)
        #expect(model.draftName == "Unfinished draft")
        #expect(model.draftSummary == "Keep these unsaved details.")
        #expect(model.draftMemberIDs == [teammate.id.rawValue])
        #expect(model.draftLeadID == teammate.id.rawValue)
        #expect(!model.isSubmittingCreation)
        #expect(model.creationFailure == nil)
        #expect(await service.recordedProjectDrafts().isEmpty)
        #expect(await service.recordedTeamDrafts().isEmpty)
    }

    @Test("Hiding either inline editor preserves exact edits, members, and lead until explicit cancellation",
          arguments: [CollaborationCreationKind.project, .team])
    func hidingPreservesUnfinishedCreation(_ kind: CollaborationCreationKind) async throws {
        let ada = try s3ATeammate(62, name: "Ada Pane", role: "Writer")
        let mira = try s3ATeammate(63, name: "Mira Pane", role: "Reviewer")
        let toni = try s3ATeammate(64, name: "Toni Pane", role: "Researcher")
        let service = S3AProjectTeamDirectoryFake(teammates: [ada, mira, toni])
        let model = CollaborationWorkspaceModel(
            directoryService: service,
            availableTeammates: [ada, mira, toni].map(TeammateIdentitySnapshot.init)
        )
        model.activateConversation(UUID(), selectedTeammateID: ada.id.rawValue)
        await model.load()
        model.beginCreation(kind)
        model.draftName = "  Unfinished \(kind.visibleName)  "
        model.draftSummary = "Keep the exact\n  unfinished details."
        model.toggleDraftMember(mira.id.rawValue)
        model.toggleDraftMember(toni.id.rawValue)
        model.toggleDraftMember(ada.id.rawValue)
        if kind == .team { model.selectDraftLead(toni.id.rawValue) }

        for _ in 0..<2 {
            model.toggleInspector()
            #expect(!model.isInspectorPresented)
            #expect(model.creationKind == kind)
            model.toggleInspector()
            #expect(model.isInspectorPresented)
        }

        #expect(model.draftName == "  Unfinished \(kind.visibleName)  ")
        #expect(model.draftSummary == "Keep the exact\n  unfinished details.")
        #expect(model.draftMemberIDs == [mira.id.rawValue, toni.id.rawValue])
        #expect(model.draftLeadID == (kind == .team ? toni.id.rawValue : nil))
        #expect(model.canSubmitCreation)
        #expect(!model.isSubmittingCreation)
        #expect(model.creationFailure == nil)
        #expect(await service.recordedProjectDrafts().isEmpty)
        #expect(await service.recordedTeamDrafts().isEmpty)

        model.cancelCreation()
        model.hideInspector()
        model.showInspector()
        #expect(model.creationKind == nil)
        #expect(model.draftName.isEmpty && model.draftSummary.isEmpty)
        #expect(model.draftMemberIDs.isEmpty && model.draftLeadID == nil)
        #expect(await service.recordedProjectDrafts().isEmpty)
        #expect(await service.recordedTeamDrafts().isEmpty)
    }

    @Test("Changing conversation while the pane is hidden still cancels its unfinished editor",
          arguments: [CollaborationCreationKind.project, .team])
    func hiddenEditorRetainsConversationCancellation(_ kind: CollaborationCreationKind) async throws {
        let ada = try s3ATeammate(65, name: "Ada Scope", role: "Writer")
        let mira = try s3ATeammate(66, name: "Mira Scope", role: "Reviewer")
        let service = S3AProjectTeamDirectoryFake(teammates: [ada, mira])
        let model = CollaborationWorkspaceModel(
            directoryService: service,
            availableTeammates: [ada, mira].map(TeammateIdentitySnapshot.init)
        )
        model.activateConversation(UUID(), selectedTeammateID: ada.id.rawValue)
        await model.load()
        model.beginCreation(kind)
        model.draftName = "Only belongs to the first conversation"
        model.draftSummary = "Do not silently retarget this draft."
        model.toggleDraftMember(mira.id.rawValue)
        if kind == .team { model.selectDraftLead(mira.id.rawValue) }
        model.hideInspector()

        model.activateConversation(UUID(), selectedTeammateID: mira.id.rawValue)
        #expect(!model.isInspectorPresented)
        model.showInspector()
        #expect(model.creationKind == nil)
        #expect(model.draftName.isEmpty && model.draftSummary.isEmpty)
        #expect(model.draftMemberIDs.isEmpty && model.draftLeadID == nil)
        #expect(!model.isSubmittingCreation)
        #expect(await service.recordedProjectDrafts().isEmpty)
        #expect(await service.recordedTeamDrafts().isEmpty)
    }

    @Test("A late creation result cannot select into a new conversation or clear its new inline draft",
          arguments: [CollaborationCreationKind.project, .team])
    func lateCreationKeepsScopeFence(_ kind: CollaborationCreationKind) async throws {
        let ada = try s3ATeammate(67, name: "Ada Late", role: "Writer")
        let mira = try s3ATeammate(68, name: "Mira Late", role: "Reviewer")
        let directory = S3AProjectTeamDirectoryFake(teammates: [ada, mira])
        let service = InspectorDelayedCreationDirectory(directory: directory)
        let model = CollaborationWorkspaceModel(
            directoryService: service,
            availableTeammates: [ada, mira].map(TeammateIdentitySnapshot.init)
        )
        model.activateConversation(UUID(), selectedTeammateID: ada.id.rawValue)
        await model.load()
        model.beginCreation(kind)
        model.draftName = "First conversation creation"
        let submission = Task { await model.submitCreation() }
        for _ in 0..<200 {
            if await service.hasPendingCreation() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await service.hasPendingCreation()
        #expect(pending)
        // Always release below, even if a broken admission path fails this check.
        model.hideInspector()
        model.activateConversation(UUID(), selectedTeammateID: mira.id.rawValue)
        model.beginCreation(kind)
        model.draftName = "Second conversation unfinished"
        model.draftSummary = "Must survive the old completion"
        let members = model.draftMemberIDs
        let lead = model.draftLeadID
        await service.releaseCreation()
        await submission.value

        #expect(model.creationKind == kind)
        #expect(model.draftName == "Second conversation unfinished")
        #expect(model.draftSummary == "Must survive the old completion")
        #expect(model.draftMemberIDs == members && model.draftLeadID == lead)
        #expect(model.selectedProjectID == nil && model.selectedTeamID == nil)
        #expect(!model.isSubmittingCreation)
        #expect(model.creationFailure == nil)
        let projectDrafts = await directory.recordedProjectDrafts()
        let teamDrafts = await directory.recordedTeamDrafts()
        #expect(projectDrafts.count == (kind == .project ? 1 : 0))
        #expect(teamDrafts.count == (kind == .team ? 1 : 0))
        #expect(projectDrafts.first?.name == (kind == .project ? "First conversation creation" : nil))
        #expect(teamDrafts.first?.name == (kind == .team ? "First conversation creation" : nil))
    }

    private func makeModel() throws -> CollaborationWorkspaceModel {
        CollaborationWorkspaceModel(
            directoryService: S3AProjectTeamDirectoryFake(teammates: []),
            reviewFixtureService: try CollaborationReviewFixtureService()
        )
    }
}

private actor InspectorDelayedCreationDirectory: ProjectTeamDirectoryServing {
    private let directory: S3AProjectTeamDirectoryFake
    private var pending: CheckedContinuation<Void, Never>?
    private var released = false

    init(directory: S3AProjectTeamDirectoryFake) { self.directory = directory }

    func activeProjects() async throws -> [ProjectDirectorySnapshot] { try await directory.activeProjects() }
    func activeTeams() async throws -> [TeamDirectorySnapshot] { try await directory.activeTeams() }

    func createProject(_ draft: ProjectDirectoryDraft) async throws -> ProjectDirectorySnapshot {
        await holdCreation()
        return try await directory.createProject(draft)
    }

    func createTeam(_ draft: TeamDirectoryDraft) async throws -> TeamDirectorySnapshot {
        await holdCreation()
        return try await directory.createTeam(draft)
    }

    func hasPendingCreation() -> Bool { pending != nil }

    func releaseCreation() {
        released = true
        pending?.resume()
        pending = nil
    }

    private func holdCreation() async {
        if released { return }
        await withCheckedContinuation { pending = $0 }
    }
}
