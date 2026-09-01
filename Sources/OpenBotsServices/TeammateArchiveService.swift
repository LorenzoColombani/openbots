import Foundation
import OpenBotsDomain

public protocol TeammateArchiving: Sendable {
    func archivedTeammates() async throws -> [Teammate]
    func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate
    func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate
}

/// Archive and restore only change durable lifecycle. This service has no
/// executor, cancellation, scheduling, attachment or filesystem authority.
public actor TeammateArchiveService: TeammateArchiving {
    private let repository: any TeammateArchiveRepository
    private let clock: any OpenBotsClock

    public init(repository: any TeammateArchiveRepository, clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository
        self.clock = clock
    }

    public func archivedTeammates() async throws -> [Teammate] {
        try await repository.archivedTeammates()
    }

    public func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        try Task.checkCancellation()
        return try await repository.archiveTeammate(id: id, expectedProfileRevision: expectedProfileRevision, now: clock.now())
    }

    public func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        try Task.checkCancellation()
        return try await repository.restoreTeammate(id: id, expectedProfileRevision: expectedProfileRevision, now: clock.now())
    }
}
