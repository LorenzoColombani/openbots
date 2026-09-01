import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private struct DirectoryFixedClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private final class DirectorySequenceUUIDGenerator: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        precondition(!values.isEmpty, "The test UUID sequence is exhausted.")
        return values.removeFirst()
    }
}

private struct DirectoryWriteCounts: Equatable, Sendable {
    var projectInserts = 0
    var projectProvisions = 0
    var teamInserts = 0
}

private actor DirectoryRepositoryFake:
    TeammateRepository,
    ProjectRepository,
    ProjectProvisioningRepository,
    TeamRepository
{
    private var teammates: [TeammateID: Teammate]
    private var projects: [ProjectID: Project] = [:]
    private var projectMembers: [ProjectID: Set<TeammateID>] = [:]
    private var teams: [TeamID: Team] = [:]
    private var counts = DirectoryWriteCounts()

    init(teammates: [Teammate]) {
        self.teammates = Dictionary(uniqueKeysWithValues: teammates.map { ($0.id, $0) })
    }

    func teammate(id: TeammateID) async throws -> Teammate? { teammates[id] }

    func listTeammates(includingArchived: Bool) async throws -> [Teammate] {
        teammates.values
            .filter { includingArchived || $0.lifecycle != .archived }
            .sorted { $0.id.persistedValue < $1.id.persistedValue }
    }

    func insert(_ teammate: Teammate) async throws {
        teammates[teammate.id] = teammate
    }

    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        teammates[teammate.id] = teammate
    }

    func project(id: ProjectID) async throws -> Project? { projects[id] }

    func listProjects(includingArchived: Bool) async throws -> [Project] {
        projects.values
            .filter { includingArchived || $0.lifecycle == .active }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.persistedValue < $1.id.persistedValue
            }
    }

    func insert(_ project: Project) async throws {
        counts.projectInserts += 1
        projects[project.id] = project
    }

    func update(_ project: Project) async throws {
        projects[project.id] = project
    }

    func setMembership(_ membership: ProjectMembership) async throws {
        if membership.isActive {
            projectMembers[membership.projectID, default: []].insert(membership.teammateID)
        } else {
            projectMembers[membership.projectID, default: []].remove(membership.teammateID)
        }
    }

    func activeMemberIDs(projectID: ProjectID) async throws -> Set<TeammateID> {
        projectMembers[projectID, default: []]
    }

    func provisionProject(
        _ project: Project,
        initialMemberIDs: Set<TeammateID>
    ) async throws {
        counts.projectProvisions += 1
        projects[project.id] = project
        projectMembers[project.id] = initialMemberIDs
    }

    func team(id: TeamID) async throws -> Team? { teams[id] }

    func listTeams(includingArchived: Bool) async throws -> [Team] {
        teams.values
            .filter { includingArchived || $0.lifecycle == .active }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.persistedValue < $1.id.persistedValue
            }
    }

    func insert(_ team: Team) async throws {
        counts.teamInserts += 1
        teams[team.id] = team
    }

    func update(_ team: Team) async throws {
        teams[team.id] = team
    }

    func writeCounts() -> DirectoryWriteCounts { counts }
}

@Test("Project and Team creation preserve exact identity, membership, lead, and active listings")
func projectAndTeamCreationRoundTripThroughDirectory() async throws {
    let timestamp = Date(timeIntervalSince1970: 9_300)
    let first = try directoryTeammate(value: 1, name: "Mika", at: timestamp)
    let second = try directoryTeammate(value: 2, name: "Rook", at: timestamp)
    let projectUUID = directoryUUID(100)
    let teamUUID = directoryUUID(101)
    let repository = DirectoryRepositoryFake(teammates: [first, second])
    let service = ProjectTeamDirectoryService(
        teammateRepository: repository,
        projectRepository: repository,
        projectProvisioningRepository: repository,
        teamRepository: repository,
        clock: DirectoryFixedClock(value: timestamp),
        uuidGenerator: DirectorySequenceUUIDGenerator([projectUUID, teamUUID])
    )

    let projectSnapshot = try await service.createProject(
        ProjectDirectoryDraft(
            name: "  Atlas  ",
            summary: "  Shared research  ",
            memberIDs: [first.id, second.id]
        )
    )
    let teamSnapshot = try await service.createTeam(
        TeamDirectoryDraft(
            name: "  Research Studio  ",
            leadID: second.id,
            memberIDs: [first.id, second.id]
        )
    )

    #expect(projectSnapshot.project.id == ProjectID(projectUUID))
    #expect(projectSnapshot.project.name == "Atlas")
    #expect(projectSnapshot.project.summary == "Shared research")
    #expect(projectSnapshot.project.createdAt == timestamp)
    #expect(projectSnapshot.members.map(\.id) == [first.id, second.id])
    #expect(teamSnapshot.team.id == TeamID(teamUUID))
    #expect(teamSnapshot.team.name == "Research Studio")
    #expect(teamSnapshot.team.leadID == second.id)
    #expect(teamSnapshot.team.memberIDs == [first.id, second.id])
    #expect(teamSnapshot.members.map(\.id) == [first.id, second.id])
    #expect(try await service.activeProjects() == [projectSnapshot])
    #expect(try await service.activeTeams() == [teamSnapshot])
    #expect(
        await repository.writeCounts()
            == DirectoryWriteCounts(projectInserts: 0, projectProvisions: 1, teamInserts: 1)
    )
}

@Test("Missing, archived, and nonmember-lead drafts fail before repository writes")
func invalidMembershipFailsBeforeWrites() async throws {
    let timestamp = Date(timeIntervalSince1970: 9_301)
    let active = try directoryTeammate(value: 10, name: "Mika", at: timestamp)
    var archived = try directoryTeammate(value: 11, name: "Rook", at: timestamp)
    archived.lifecycle = .archived
    let missingID = TeammateID(directoryUUID(12))
    let outsideLeadID = TeammateID(directoryUUID(13))
    let repository = DirectoryRepositoryFake(teammates: [active, archived])
    let service = ProjectTeamDirectoryService(
        teammateRepository: repository,
        projectRepository: repository,
        projectProvisioningRepository: repository,
        teamRepository: repository,
        clock: DirectoryFixedClock(value: timestamp),
        uuidGenerator: DirectorySequenceUUIDGenerator([directoryUUID(200)])
    )

    await #expect(throws: ProjectTeamDirectoryError.teammateNotFound(missingID)) {
        try await service.createProject(
            ProjectDirectoryDraft(name: "Missing", memberIDs: [active.id, missingID])
        )
    }
    await #expect(throws: ProjectTeamDirectoryError.teammateNotActive(archived.id)) {
        try await service.createProject(
            ProjectDirectoryDraft(name: "Archived", memberIDs: [archived.id])
        )
    }
    await #expect(throws: ProjectTeamDirectoryError.teamLeadNotMember(outsideLeadID)) {
        try await service.createTeam(
            TeamDirectoryDraft(
                name: "Invalid lead",
                leadID: outsideLeadID,
                memberIDs: [active.id]
            )
        )
    }

    #expect(await repository.writeCounts() == DirectoryWriteCounts())
}

private func directoryTeammate(
    value: Int,
    name: String,
    at timestamp: Date
) throws -> Teammate {
    let id = TeammateID(directoryUUID(value))
    return try Teammate(
        id: id,
        profile: TeammateProfile(displayName: name, role: "Research"),
        appearance: AgentAppearance(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: UInt64(value),
            silhouette: "round",
            paletteToken: "sky",
            eyeDialect: "bright",
            nonColorIdentityCue: "single crest",
            accessibleIdentityDescription: "Round creature with a single crest"
        ),
        createdAt: timestamp,
        updatedAt: timestamp
    )
}

private func directoryUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "93000000-0000-0000-0000-%012d", value))!
}
