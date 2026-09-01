import Foundation
import OpenBotsDomain
import XCTest
@testable import OpenBotsPersistence

final class SQLiteProjectTeamProvisioningTests: XCTestCase {
    private let receipt = try! ProtectionDecisionReceipt(
        decisionID: UUID(uuidString: "94000000-0000-0000-0000-000000000001")!,
        selectedAt: Date(timeIntervalSince1970: 9_400),
        rationaleVersion: 2
    )

    func testProjectAndTeamGraphsSurviveFreshReopenWithEmptyMemoryCatalog() async throws {
        let fixture = try ProjectTeamStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let timestamp = Date(timeIntervalSince1970: 9_401)
        let first = try makeTeammate(value: 10, name: "Mika", at: timestamp)
        let second = try makeTeammate(value: 11, name: "Rook", at: timestamp)
        let project = try Project(
            id: ProjectID(uuid(100)),
            name: "Atlas",
            summary: "Shared research",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let team = try Team(
            id: TeamID(uuid(101)),
            name: "Research Studio",
            leadID: second.id,
            memberIDs: [first.id, second.id],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
            let store = try fixture.open()
            try await store.insert(first)
            try await store.insert(second)
            try await store.provisionProject(
                project,
                initialMemberIDs: [first.id, second.id]
            )
            try await store.insert(team)
            let facts = try await store.runtimeFacts()
            XCTAssertEqual(facts.migrationCount, 20)
        }

        let reopened = try fixture.open()
        let reopenedProject = try await reopened.project(id: project.id)
        let reopenedProjectMemberIDs = try await reopened.activeMemberIDs(projectID: project.id)
        let reopenedTeam = try await reopened.team(id: team.id)
        let activeProjects = try await reopened.listProjects(includingArchived: false)
        let activeTeams = try await reopened.listTeams(includingArchived: false)
        XCTAssertEqual(reopenedProject, project)
        XCTAssertEqual(reopenedProjectMemberIDs, [first.id, second.id])
        XCTAssertEqual(reopenedTeam, team)
        XCTAssertEqual(activeProjects, [project])
        XCTAssertEqual(activeTeams, [team])
        let memoryCount = try await reopened.query(
            sql: "SELECT COUNT(*) AS count FROM memory_documents;"
        ).first?.integer("count")
        XCTAssertEqual(memoryCount, 0)
    }

    func testProjectProvisioningRevalidatesMembersBeforePublishingAnyRow() async throws {
        let fixture = try ProjectTeamStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let timestamp = Date(timeIntervalSince1970: 9_402)
        let active = try makeTeammate(value: 20, name: "Mika", at: timestamp)
        var archived = try makeTeammate(value: 21, name: "Rook", at: timestamp)
        archived.lifecycle = .archived
        try await store.insert(active)
        try await store.insert(archived)

        let archivedProject = try Project(
            id: ProjectID(uuid(200)),
            name: "Archived member",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        do {
            try await store.provisionProject(
                archivedProject,
                initialMemberIDs: [active.id, archived.id]
            )
            XCTFail("An archived teammate must not be provisioned into a new project.")
        } catch let error as RepositoryError {
            XCTAssertEqual(
                error,
                .unavailable(reason: "Project members must be active teammates.")
            )
        }
        let projectAfterArchivedRejection = try await store.project(id: archivedProject.id)
        XCTAssertNil(projectAfterArchivedRejection)

        let missingID = TeammateID(uuid(22))
        let missingProject = try Project(
            id: ProjectID(uuid(201)),
            name: "Missing member",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        do {
            try await store.provisionProject(
                missingProject,
                initialMemberIDs: [active.id, missingID]
            )
            XCTFail("A missing teammate must not be provisioned into a new project.")
        } catch let error as RepositoryError {
            XCTAssertEqual(error, .notFound(entity: "teammate", id: missingID.persistedValue))
        }
        let projectAfterMissingRejection = try await store.project(id: missingProject.id)
        XCTAssertNil(projectAfterMissingRejection)
    }

    func testLateProjectMembershipFailureRollsBackProjectAndEarlierMembership() async throws {
        let fixture = try ProjectTeamStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let timestamp = Date(timeIntervalSince1970: 9_403)
        let first = try makeTeammate(value: 30, name: "Mika", at: timestamp)
        let second = try makeTeammate(value: 31, name: "Rook", at: timestamp)
        try await store.insert(first)
        try await store.insert(second)
        _ = try await store.execute(
            sql: """
            CREATE TRIGGER project_membership_late_failure
            BEFORE INSERT ON project_memberships
            WHEN NEW.teammate_id='\(second.id.persistedValue)'
            BEGIN
                SELECT RAISE(ABORT, 'injected late membership failure');
            END;
            """
        )
        let project = try Project(
            id: ProjectID(uuid(300)),
            name: "Rollback fixture",
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
            try await store.provisionProject(
                project,
                initialMemberIDs: [first.id, second.id]
            )
            XCTFail("The injected second-membership failure must abort provisioning.")
        } catch {
            XCTAssertTrue(error is SQLiteStoreError)
        }

        let projectAfterRollback = try await store.project(id: project.id)
        let memberIDsAfterRollback = try await store.activeMemberIDs(projectID: project.id)
        XCTAssertNil(projectAfterRollback)
        XCTAssertTrue(memberIDsAfterRollback.isEmpty)
    }

    func testExistingAtomicTeamInsertRollsBackWhenALaterMemberIsMissing() async throws {
        let fixture = try ProjectTeamStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let timestamp = Date(timeIntervalSince1970: 9_404)
        let lead = try makeTeammate(value: 40, name: "Mika", at: timestamp)
        let missingID = TeammateID(uuid(41))
        try await store.insert(lead)
        let team = try Team(
            id: TeamID(uuid(400)),
            name: "Rollback team",
            leadID: lead.id,
            memberIDs: [lead.id, missingID],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
            try await store.insert(team)
            XCTFail("A missing later member must abort the complete Team aggregate.")
        } catch let error as RepositoryError {
            XCTAssertEqual(
                error,
                .notFound(entity: "teammate", id: missingID.persistedValue)
            )
        }

        let teamAfterRollback = try await store.team(id: team.id)
        XCTAssertNil(teamAfterRollback)
        let membershipCount = try await store.query(
            sql: "SELECT COUNT(*) AS count FROM team_memberships WHERE team_id=?;",
            bindings: [.text(team.id.persistedValue)]
        ).first?.integer("count")
        XCTAssertEqual(membershipCount, 0)
    }

    func testTeamInsertRevalidatesActiveMembersBeforePublishingAnyRow() async throws {
        let fixture = try ProjectTeamStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let timestamp = Date(timeIntervalSince1970: 9_405)
        let active = try makeTeammate(value: 50, name: "Mika", at: timestamp)
        var archived = try makeTeammate(value: 51, name: "Rook", at: timestamp)
        archived.lifecycle = .archived
        try await store.insert(active)
        try await store.insert(archived)
        let team = try Team(
            id: TeamID(uuid(500)),
            name: "Archived member",
            leadID: active.id,
            memberIDs: [active.id, archived.id],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
            try await store.insert(team)
            XCTFail("An archived teammate must not be provisioned into a new team.")
        } catch let error as RepositoryError {
            XCTAssertEqual(
                error,
                .unavailable(reason: "Team members must be active teammates.")
            )
        }

        let teamAfterRejection = try await store.team(id: team.id)
        XCTAssertNil(teamAfterRejection)
        let membershipCount = try await store.query(
            sql: "SELECT COUNT(*) AS count FROM team_memberships WHERE team_id=?;",
            bindings: [.text(team.id.persistedValue)]
        ).first?.integer("count")
        XCTAssertEqual(membershipCount, 0)
    }

    private func makeTeammate(
        value: Int,
        name: String,
        at timestamp: Date
    ) throws -> Teammate {
        try Teammate(
            id: TeammateID(uuid(value)),
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

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "94000000-0000-0000-0000-%012d", value))!
    }
}

private final class ProjectTeamStoreFixture {
    let directory: URL
    let databaseURL: URL
    let receipt: ProtectionDecisionReceipt

    init(receipt: ProtectionDecisionReceipt) throws {
        self.receipt = receipt
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openbots-project-team-tests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: databaseURL,
                protection: .ordinarySQLite(decision: receipt)
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
