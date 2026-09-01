import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

actor S3AProjectTeamDirectoryFake: ProjectTeamDirectoryServing {
    private var projects: [ProjectDirectorySnapshot]
    private var teams: [TeamDirectorySnapshot]
    private let teammatesByID: [TeammateID: Teammate]
    private(set) var projectDrafts: [ProjectDirectoryDraft] = []
    private(set) var teamDrafts: [TeamDirectoryDraft] = []

    init(
        teammates: [Teammate],
        projects: [ProjectDirectorySnapshot] = [],
        teams: [TeamDirectorySnapshot] = []
    ) {
        teammatesByID = Dictionary(uniqueKeysWithValues: teammates.map { ($0.id, $0) })
        self.projects = projects
        self.teams = teams
    }

    func createProject(_ draft: ProjectDirectoryDraft) async throws -> ProjectDirectorySnapshot {
        projectDrafts.append(draft)
        let now = Date(timeIntervalSince1970: 1_781_000_000 + Double(projectDrafts.count))
        let project = try Project(
            id: ProjectID(UUID()),
            name: draft.name,
            summary: draft.summary,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = ProjectDirectorySnapshot(
            project: project,
            members: draft.memberIDs.compactMap { teammatesByID[$0] }
        )
        projects.append(snapshot)
        return snapshot
    }

    func createTeam(_ draft: TeamDirectoryDraft) async throws -> TeamDirectorySnapshot {
        teamDrafts.append(draft)
        let now = Date(timeIntervalSince1970: 1_781_100_000 + Double(teamDrafts.count))
        let team = try Team(
            id: TeamID(UUID()),
            name: draft.name,
            summary: draft.summary,
            leadID: draft.leadID,
            memberIDs: draft.memberIDs,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = TeamDirectorySnapshot(
            team: team,
            members: draft.memberIDs.compactMap { teammatesByID[$0] }
        )
        teams.append(snapshot)
        return snapshot
    }

    func activeProjects() async throws -> [ProjectDirectorySnapshot] { projects }
    func activeTeams() async throws -> [TeamDirectorySnapshot] { teams }

    func recordedProjectDrafts() -> [ProjectDirectoryDraft] { projectDrafts }
    func recordedTeamDrafts() -> [TeamDirectoryDraft] { teamDrafts }
}

func s3ATeammate(_ number: UInt8, name: String, role: String) throws -> Teammate {
    let id = UUID(uuidString: String(format: "a3000000-0000-0000-0000-%012d", number))!
    let now = Date(timeIntervalSince1970: 1_781_200_000 + Double(number))
    return try Teammate(
        id: TeammateID(id),
        profile: TeammateProfile(displayName: name, role: role),
        appearance: AgentAppearance(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: UInt64(number),
            silhouette: "soft-arch",
            paletteToken: "violet-coral",
            eyeDialect: "round-alert",
            nonColorIdentityCue: "brow notch " + String(number),
            accessibleIdentityDescription: "Violet creature with brow notch " + String(number)
        ),
        createdAt: now,
        updatedAt: now
    )
}

func s3AProject(
    _ number: UInt8,
    name: String,
    members: [Teammate]
) throws -> ProjectDirectorySnapshot {
    let id = UUID(uuidString: String(format: "a3100000-0000-0000-0000-%012d", number))!
    let now = Date(timeIntervalSince1970: 1_781_300_000 + Double(number))
    return ProjectDirectorySnapshot(
        project: try Project(
            id: ProjectID(id),
            name: name,
            summary: name + " review summary",
            createdAt: now,
            updatedAt: now
        ),
        members: members
    )
}

func s3ATeam(
    _ number: UInt8,
    name: String,
    members: [Teammate],
    lead: Teammate
) throws -> TeamDirectorySnapshot {
    let id = UUID(uuidString: String(format: "a3200000-0000-0000-0000-%012d", number))!
    let now = Date(timeIntervalSince1970: 1_781_400_000 + Double(number))
    return TeamDirectorySnapshot(
        team: try Team(
            id: TeamID(id),
            name: name,
            summary: name + " review summary",
            leadID: lead.id,
            memberIDs: Set(members.map(\.id)),
            createdAt: now,
            updatedAt: now
        ),
        members: members
    )
}

@Test("Normal collaboration creates projects and teams without a review fixture")
@MainActor
func collaborationModelCreatesDirectoryItemsThroughService() async throws {
    let mira = try s3ATeammate(1, name: "Mira", role: "Research lead")
    let ada = try s3ATeammate(2, name: "Ada", role: "Source verifier")
    let service = S3AProjectTeamDirectoryFake(teammates: [mira, ada])
    let model = CollaborationWorkspaceModel(
        directoryService: service,
        availableTeammates: [TeammateIdentitySnapshot(mira), TeammateIdentitySnapshot(ada)]
    )
    model.activateConversation(UUID(), selectedTeammateID: mira.id.rawValue)
    await model.load()

    model.beginCreation(.project)
    #expect(model.draftMemberIDs == [mira.id.rawValue])
    model.draftName = "  Atlas Launch  "
    model.draftSummary = "  Local review project  "
    model.toggleDraftMember(ada.id.rawValue)
    await model.submitCreation()

    let projectDraft = try #require(await service.recordedProjectDrafts().first)
    #expect(projectDraft.name == "Atlas Launch")
    #expect(projectDraft.summary == "Local review project")
    #expect(projectDraft.memberIDs == [mira.id, ada.id])
    #expect(model.selectedProject?.name == "Atlas Launch")
    #expect(model.creationKind == nil)

    model.beginCreation(.team)
    model.draftName = "Research Studio"
    model.toggleDraftMember(ada.id.rawValue)
    model.selectDraftLead(ada.id.rawValue)
    await model.submitCreation()

    let teamDraft = try #require(await service.recordedTeamDrafts().first)
    #expect(teamDraft.name == "Research Studio")
    #expect(teamDraft.leadID == ada.id)
    #expect(teamDraft.memberIDs == [mira.id, ada.id])
    #expect(model.selectedTeam?.leadID == ada.id.rawValue)
    #expect(!model.isReviewFixtureEnabled)
    #expect(model.reviewPresentation == nil)
    #expect(model.reviewFailure == nil)
    #expect(model.conversationFixtureMessage(for: UUID()) == nil)
}

@Test("Normal collaboration never manufactures a handoff row when context changes")
@MainActor
func collaborationNormalContextHasNoSyntheticHandoff() async throws {
    let teammate = try s3ATeammate(5, name: "Mira", role: "Research lead")
    let model = CollaborationWorkspaceModel(
        directoryService: S3AProjectTeamDirectoryFake(teammates: [teammate])
    )
    await model.load()
    for conversationID in [UUID(), UUID()] {
        model.activateConversation(conversationID, selectedTeammateID: teammate.id.rawValue)
        model.selectReviewVariant(.needsRecovery)
        #expect(model.reviewVariant == .successfulFanIn)
        #expect(model.reviewPresentation == nil)
        #expect(model.reviewFailure == nil)
        #expect(model.conversationFixtureMessage(for: conversationID) == nil)
    }
    model.activateConversation(nil, selectedTeammateID: nil)
    #expect(model.reviewPresentation == nil)
}

@Test("Work context and review outcome stay scoped to each conversation")
@MainActor
func collaborationModelScopesContextPerConversation() async throws {
    let mira = try s3ATeammate(3, name: "Mira", role: "Research lead")
    let ada = try s3ATeammate(4, name: "Ada", role: "Source verifier")
    let atlas = try s3AProject(1, name: "Atlas", members: [mira])
    let beacon = try s3AProject(2, name: "Beacon", members: [ada])
    let research = try s3ATeam(1, name: "Research", members: [mira, ada], lead: mira)
    let service = S3AProjectTeamDirectoryFake(
        teammates: [mira, ada],
        projects: [atlas, beacon],
        teams: [research]
    )
    let model = CollaborationWorkspaceModel(
        directoryService: service,
        reviewFixtureService: try CollaborationReviewFixtureService()
    )
    await model.load()
    let conversationA = UUID()
    let conversationB = UUID()

    model.activateConversation(conversationA, selectedTeammateID: mira.id.rawValue)
    model.selectProject(nil)
    model.selectTeam(research.team.id.rawValue)
    model.selectReviewVariant(.needsRecovery)

    model.activateConversation(conversationB, selectedTeammateID: ada.id.rawValue)
    #expect(model.selectedProjectID == atlas.project.id.rawValue)
    #expect(model.reviewVariant == .successfulFanIn)
    model.selectProject(beacon.project.id.rawValue)

    model.activateConversation(conversationA, selectedTeammateID: mira.id.rawValue)
    #expect(model.selectedProjectID == nil)
    #expect(model.selectedTeamID == research.team.id.rawValue)
    #expect(model.reviewVariant == .needsRecovery)
}

@Test("Conversation handoff fixture keeps row identity while its state changes")
@MainActor
func collaborationFixtureMessageHasStableConversationIdentity() throws {
    let service = S3AProjectTeamDirectoryFake(teammates: [])
    let model = CollaborationWorkspaceModel(
        directoryService: service,
        reviewFixtureService: try CollaborationReviewFixtureService()
    )
    let firstConversation = UUID()
    let secondConversation = UUID()
    #expect(model.isReviewFixtureEnabled)
    model.activateConversation(firstConversation, selectedTeammateID: nil)

    let initial = try #require(model.conversationFixtureMessage(for: firstConversation))
    #expect(initial.parts.count == 2)
    #expect(initial.accessibilityBody.contains("did not read or write authoritative Markdown"))
    guard case .handoff(let initialTrail) = initial.parts[1].content else {
        Issue.record("Expected a typed handoff part")
        return
    }
    #expect(initialTrail.state == .returnedToOrigin)

    model.selectReviewVariant(.needsRecovery)
    let recovery = try #require(model.conversationFixtureMessage(for: firstConversation))
    #expect(recovery.id == initial.id)
    #expect(recovery.parts.map(\.id) == initial.parts.map(\.id))
    guard case .handoff(let recoveryTrail) = recovery.parts[1].content else {
        Issue.record("Expected a typed handoff part")
        return
    }
    #expect(recoveryTrail.state == .needsRecovery)

    model.activateConversation(secondConversation, selectedTeammateID: nil)
    let second = try #require(model.conversationFixtureMessage(for: secondConversation))
    #expect(second.id != initial.id)
}
