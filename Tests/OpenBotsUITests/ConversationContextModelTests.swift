import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

private actor ContextModelServiceFake: ConversationContextServing {
    var stored: [ConversationID: ConversationContextSelection] = [:]
    var invalidated: UInt64?
    var delay: Duration = .zero
    var saves: [ConversationID] = []
    func configure(invalidated: UInt64? = nil, delay: Duration = .zero) {
        self.invalidated = invalidated
        self.delay = delay
    }
    func load(conversationID: ConversationID, teammateID: TeammateID) async throws -> ConversationContextSelection {
        let wait = delay
        try await Task.sleep(for: wait)
        if let invalidated { throw ConversationContextError.selectionInvalidated(revision: invalidated) }
        return stored[conversationID] ?? ConversationContextSelection(conversationID: conversationID, teammateID: teammateID)
    }
    func save(conversationID: ConversationID, teammateID: TeammateID, projectID: ProjectID?, teamID: TeamID?, expectedRevision: UInt64) async throws -> ConversationContextSelection {
        saves.append(conversationID)
        let wait = delay
        try await Task.sleep(for: wait)
        let result = ConversationContextSelection(conversationID: conversationID, teammateID: teammateID,
            projectID: projectID, teamID: teamID, revision: expectedRevision + 1)
        stored[conversationID] = result
        invalidated = nil
        return result
    }
    func savedTargets() -> [ConversationID] { saves }
}

private actor DelayedContextDirectory: ProjectTeamDirectoryServing {
    let backing: S3AProjectTeamDirectoryFake
    init(teammates: [Teammate]) { backing = S3AProjectTeamDirectoryFake(teammates: teammates) }
    func activeProjects() async throws -> [ProjectDirectorySnapshot] { try await backing.activeProjects() }
    func activeTeams() async throws -> [TeamDirectorySnapshot] { try await backing.activeTeams() }
    func createProject(_ draft: ProjectDirectoryDraft) async throws -> ProjectDirectorySnapshot {
        try await Task.sleep(for: .milliseconds(30))
        return try await backing.createProject(draft)
    }
    func createTeam(_ draft: TeamDirectoryDraft) async throws -> TeamDirectorySnapshot {
        try await backing.createTeam(draft)
    }
}

@MainActor
private func contextEventually(_ check: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if check() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(check())
}

@Test("Durable context exposes only confirmed scope and survives a new presentation model")
@MainActor
func contextConfirmedScopeAndReopen() async throws {
    let service = ContextModelServiceFake()
    let model = ConversationContextModel(service: service)
    let chat = UUID(), teammate = UUID(), project = UUID()
    model.activate(conversationID: chat, teammateID: teammate)
    try await contextEventually { model.canSelect }
    #expect(model.selection?.projectID == nil)
    await service.configure(delay: .milliseconds(20))
    model.select(projectID: project, teamID: nil)
    #expect(model.isBusy)
    #expect(model.selection?.projectID == nil)
    model.select(projectID: UUID(), teamID: nil)
    try await contextEventually { !model.isBusy }
    #expect(model.selection?.projectID?.rawValue == project)
    #expect(await service.savedTargets() == [ConversationID(chat)])
    let reopened = ConversationContextModel(service: service)
    reopened.activate(conversationID: chat, teammateID: teammate)
    try await contextEventually { reopened.canSelect }
    #expect(reopened.selection == model.selection)
}

@Test("A delayed context write cannot switch or authorize the newly selected conversation")
@MainActor
func contextWriteDoesNotRetarget() async throws {
    let service = ContextModelServiceFake()
    let model = ConversationContextModel(service: service)
    let first = UUID(), second = UUID(), teammate = UUID()
    model.activate(conversationID: first, teammateID: teammate)
    try await contextEventually { model.canSelect }
    await service.configure(delay: .milliseconds(30))
    model.select(projectID: UUID(), teamID: nil)
    model.activate(conversationID: second, teammateID: teammate)
    #expect(model.selection == nil)
    try await contextEventually { model.canSelect }
    #expect(model.selection?.conversationID.rawValue == second)
    #expect(model.selection?.projectID == nil)
    #expect(await service.savedTargets() == [ConversationID(first)])
}

@Test("Unavailable saved membership exposes no scope and requires an explicit clear")
@MainActor
func contextInvalidationRequiresClear() async throws {
    let service = ContextModelServiceFake()
    await service.configure(invalidated: 4)
    let model = ConversationContextModel(service: service)
    model.activate(conversationID: UUID(), teammateID: UUID())
    try await contextEventually { model.needsExplicitClear }
    #expect(model.selection == nil)
    #expect(await service.savedTargets().isEmpty)
    model.clearUnavailableContext()
    try await contextEventually { model.selection != nil }
    #expect(model.selection?.revision == 5)
    #expect(model.selection?.projectID == nil)
    #expect(!model.needsExplicitClear)
}

@Test("Durable collaboration never defaults to the first project or shows non-member choices")
@MainActor
func contextMembershipPickerAndNoDefault() async throws {
    let teammate = try s3ATeammate(51, name: "Context owner", role: "Research")
    let other = try s3ATeammate(52, name: "Other", role: "Review")
    let admitted = try s3AProject(51, name: "Admitted", members: [teammate])
    let denied = try s3AProject(52, name: "Other scope", members: [other])
    let service = ContextModelServiceFake()
    let model = CollaborationWorkspaceModel(
        directoryService: S3AProjectTeamDirectoryFake(teammates: [teammate, other], projects: [admitted, denied]),
        reviewFixtureService: try CollaborationReviewFixtureService(),
        contextService: service
    )
    await model.load()
    model.activateConversation(UUID(), selectedTeammateID: teammate.id.rawValue)
    try await contextEventually { model.contextModel?.canSelect == true }
    #expect(model.selectedProjectID == nil)
    #expect(model.selectableProjects.map(\.id) == [admitted.id.rawValue])
    model.selectProject(denied.id.rawValue)
    #expect(await service.savedTargets().isEmpty)
    model.selectProject(admitted.id.rawValue)
    try await contextEventually { model.selectedProjectID == admitted.id.rawValue }
}

@Test("Project creation after navigation cannot persist context into another chat or clear its editor")
@MainActor
func contextCreationDoesNotRetargetAfterNavigation() async throws {
    let first = try s3ATeammate(61, name: "First", role: "Research")
    let second = try s3ATeammate(62, name: "Second", role: "Review")
    let service = ContextModelServiceFake()
    let directory = DelayedContextDirectory(teammates: [first, second])
    let model = CollaborationWorkspaceModel(
        directoryService: directory, reviewFixtureService: try CollaborationReviewFixtureService(),
        availableTeammates: [first, second].map(TeammateIdentitySnapshot.init), contextService: service
    )
    await model.load()
    model.activateConversation(UUID(), selectedTeammateID: first.id.rawValue)
    try await contextEventually { model.contextModel?.canSelect == true }
    model.beginCreation(.project)
    model.draftName = "Shared project"
    model.toggleDraftMember(second.id.rawValue)
    let creation = Task { await model.submitCreation() }
    try await contextEventually { model.isSubmittingCreation }
    model.activateConversation(UUID(), selectedTeammateID: second.id.rawValue)
    model.beginCreation(.team)
    model.draftName = "New editor must survive"
    await creation.value
    try await contextEventually { model.contextModel?.canSelect == true }
    #expect(model.projects.count == 1)
    #expect(model.selectedProjectID == nil)
    #expect(model.creationKind == .team)
    #expect(model.draftName == "New editor must survive")
    #expect(await service.savedTargets().isEmpty)
}
