import Foundation
import OpenBotsDomain

public struct ProjectDirectoryDraft: Equatable, Sendable {
    public let name: String
    public let summary: String?
    public let memberIDs: Set<TeammateID>

    public init(
        name: String,
        summary: String? = nil,
        memberIDs: Set<TeammateID>
    ) {
        self.name = name
        self.summary = summary
        self.memberIDs = memberIDs
    }
}

public struct TeamDirectoryDraft: Equatable, Sendable {
    public let name: String
    public let summary: String?
    public let leadID: TeammateID
    public let memberIDs: Set<TeammateID>

    public init(
        name: String,
        summary: String? = nil,
        leadID: TeammateID,
        memberIDs: Set<TeammateID>
    ) {
        self.name = name
        self.summary = summary
        self.leadID = leadID
        self.memberIDs = memberIDs
    }
}

public struct ProjectDirectorySnapshot: Equatable, Sendable, Identifiable {
    public let project: Project
    public let members: [Teammate]

    public var id: ProjectID { project.id }

    public init(project: Project, members: [Teammate]) {
        self.project = project
        self.members = members
    }
}

public struct TeamDirectorySnapshot: Equatable, Sendable, Identifiable {
    public let team: Team
    public let members: [Teammate]

    public var id: TeamID { team.id }

    public init(team: Team, members: [Teammate]) {
        self.team = team
        self.members = members
    }
}

public enum ProjectTeamDirectoryError: Error, Equatable, Sendable {
    case teammateNotFound(TeammateID)
    case teammateNotActive(TeammateID)
    case teamLeadNotMember(TeammateID)
}

public protocol ProjectTeamDirectoryServing: Sendable {
    func createProject(_ draft: ProjectDirectoryDraft) async throws -> ProjectDirectorySnapshot
    func createTeam(_ draft: TeamDirectoryDraft) async throws -> TeamDirectorySnapshot
    func activeProjects() async throws -> [ProjectDirectorySnapshot]
    func activeTeams() async throws -> [TeamDirectorySnapshot]
}

/// Owns only the durable Project/Team directory boundary. Markdown memory,
/// conversations, handoffs, filesystem roots, credentials, and runtime work
/// are deliberately absent from this service and remain separately gated.
public actor ProjectTeamDirectoryService: ProjectTeamDirectoryServing {
    private let teammateRepository: any TeammateRepository
    private let projectRepository: any ProjectRepository
    private let projectProvisioningRepository: any ProjectProvisioningRepository
    private let teamRepository: any TeamRepository
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator

    public init(
        teammateRepository: any TeammateRepository,
        projectRepository: any ProjectRepository,
        projectProvisioningRepository: any ProjectProvisioningRepository,
        teamRepository: any TeamRepository,
        clock: any OpenBotsClock = SystemClock(),
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()
    ) {
        self.teammateRepository = teammateRepository
        self.projectRepository = projectRepository
        self.projectProvisioningRepository = projectProvisioningRepository
        self.teamRepository = teamRepository
        self.clock = clock
        self.uuidGenerator = uuidGenerator
    }

    public func createProject(
        _ draft: ProjectDirectoryDraft
    ) async throws -> ProjectDirectorySnapshot {
        let members = try await resolveMembers(draft.memberIDs, requiringActive: true)
        let timestamp = clock.now()
        let project = try Project(
            id: ProjectID(uuidGenerator.next()),
            name: draft.name,
            summary: draft.summary,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await projectProvisioningRepository.provisionProject(
            project,
            initialMemberIDs: draft.memberIDs
        )
        return ProjectDirectorySnapshot(project: project, members: members)
    }

    public func createTeam(
        _ draft: TeamDirectoryDraft
    ) async throws -> TeamDirectorySnapshot {
        guard draft.memberIDs.contains(draft.leadID) else {
            throw ProjectTeamDirectoryError.teamLeadNotMember(draft.leadID)
        }
        let members = try await resolveMembers(draft.memberIDs, requiringActive: true)
        let timestamp = clock.now()
        let team = try Team(
            id: TeamID(uuidGenerator.next()),
            name: draft.name,
            summary: draft.summary,
            leadID: draft.leadID,
            memberIDs: draft.memberIDs,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try await teamRepository.insert(team)
        return TeamDirectorySnapshot(team: team, members: members)
    }

    public func activeProjects() async throws -> [ProjectDirectorySnapshot] {
        let projects = try await projectRepository.listProjects(includingArchived: false)
        var snapshots: [ProjectDirectorySnapshot] = []
        snapshots.reserveCapacity(projects.count)
        for project in projects {
            let memberIDs = try await projectRepository.activeMemberIDs(projectID: project.id)
            let members = try await resolveMembers(memberIDs, requiringActive: false)
            snapshots.append(ProjectDirectorySnapshot(project: project, members: members))
        }
        return snapshots
    }

    public func activeTeams() async throws -> [TeamDirectorySnapshot] {
        let teams = try await teamRepository.listTeams(includingArchived: false)
        var snapshots: [TeamDirectorySnapshot] = []
        snapshots.reserveCapacity(teams.count)
        for team in teams {
            let members = try await resolveMembers(team.memberIDs, requiringActive: false)
            snapshots.append(TeamDirectorySnapshot(team: team, members: members))
        }
        return snapshots
    }

    private func resolveMembers(
        _ memberIDs: Set<TeammateID>,
        requiringActive: Bool
    ) async throws -> [Teammate] {
        var teammates: [Teammate] = []
        teammates.reserveCapacity(memberIDs.count)
        for teammateID in memberIDs.sorted(by: { $0.persistedValue < $1.persistedValue }) {
            guard let teammate = try await teammateRepository.teammate(id: teammateID) else {
                throw ProjectTeamDirectoryError.teammateNotFound(teammateID)
            }
            if requiringActive, teammate.lifecycle != .active {
                throw ProjectTeamDirectoryError.teammateNotActive(teammateID)
            }
            teammates.append(teammate)
        }
        return teammates
    }
}
