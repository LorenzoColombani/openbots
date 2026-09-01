import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private struct FixedClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private struct FixedUUIDGenerator: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private actor TeammateRepositorySpy: TeammateRepository {
    private var values: [TeammateID: Teammate] = [:]

    func teammate(id: TeammateID) async throws -> Teammate? { values[id] }

    func listTeammates(includingArchived: Bool) async throws -> [Teammate] {
        values.values
            .filter { includingArchived || $0.lifecycle != .archived }
            .sorted { $0.id.persistedValue < $1.id.persistedValue }
    }

    func insert(_ teammate: Teammate) async throws {
        guard values[teammate.id] == nil else {
            throw RepositoryError.alreadyExists(entity: "teammate", id: teammate.id.persistedValue)
        }
        values[teammate.id] = teammate
    }

    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        guard values[teammate.id]?.profile.revision == expectedProfileRevision else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammate.id.persistedValue)
        }
        values[teammate.id] = teammate
    }
}

@Test("Quick creation persists one stable teammate identity and functional creature profile")
func quickCreatePersistsTeammate() async throws {
    let repository = TeammateRepositorySpy()
    let uuid = UUID(uuidString: "85000000-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 850)
    let service = TeammateProfileService(
        repository: repository,
        clock: FixedClock(value: now),
        uuidGenerator: FixedUUIDGenerator(value: uuid)
    )

    let teammate = try await service.createQuickTeammate(
        QuickTeammateDraft(displayName: " Ada ", role: " Research partner ")
    )

    #expect(teammate.id == TeammateID(uuid))
    #expect(teammate.profile.displayName == "Ada")
    #expect(teammate.profile.role == "Research partner")
    #expect(teammate.appearance.mode == .creature)
    #expect(!teammate.appearance.nonColorIdentityCue.isEmpty)
    #expect(teammate.createdAt == now)
    #expect(try await repository.teammate(id: teammate.id) == teammate)
}

@Test("Appearance generation is deterministic for the persistent UUID")
func deterministicAppearance() async throws {
    let uuid = UUID(uuidString: "85000000-0000-0000-0000-000000000002")!
    let firstRepository = TeammateRepositorySpy()
    let secondRepository = TeammateRepositorySpy()
    let first = TeammateProfileService(
        repository: firstRepository,
        uuidGenerator: FixedUUIDGenerator(value: uuid)
    )
    let second = TeammateProfileService(
        repository: secondRepository,
        uuidGenerator: FixedUUIDGenerator(value: uuid)
    )

    let firstTeammate = try await first.createQuickTeammate(
        QuickTeammateDraft(displayName: "Lin", role: "Builder")
    )
    let secondTeammate = try await second.createQuickTeammate(
        QuickTeammateDraft(displayName: "Lin", role: "Builder")
    )

    #expect(firstTeammate.appearance == secondTeammate.appearance)
}
