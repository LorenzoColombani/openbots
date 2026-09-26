import Foundation
import OpenBotsDomain

public protocol TeamArchiving: Sendable {
    func archivedTeams() async throws -> [Team]
    func archiveTeam(id: TeamID, expectedUpdatedAt: Date) async throws -> Team
    func restoreTeam(id: TeamID, expectedUpdatedAt: Date) async throws -> Team
}

/// Archive and restore change only a team's lifecycle: its chat, memberships
/// and records stay, and nothing is cancelled.
public actor TeamArchiveService: TeamArchiving {
    private let repository: any TeamArchiveRepository
    private let clock: any OpenBotsClock

    public init(repository: any TeamArchiveRepository, clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository
        self.clock = clock
    }

    public func archivedTeams() async throws -> [Team] {
        try await repository.archivedTeams()
    }

    public func archiveTeam(id: TeamID, expectedUpdatedAt: Date) async throws -> Team {
        try Task.checkCancellation()
        return try await repository.archiveTeam(id: id, expectedUpdatedAt: expectedUpdatedAt, now: clock.now())
    }

    public func restoreTeam(id: TeamID, expectedUpdatedAt: Date) async throws -> Team {
        try Task.checkCancellation()
        return try await repository.restoreTeam(id: id, expectedUpdatedAt: expectedUpdatedAt, now: clock.now())
    }
}
