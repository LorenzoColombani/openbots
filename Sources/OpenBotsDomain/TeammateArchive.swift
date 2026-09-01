import Foundation

public enum TeammateArchiveError: Error, Equatable, Sendable {
    case notFound
    case staleRevision
    case unresolvedWork
    case invalidTransition
    case revisionExhausted
    case invalidDate
}

/// Lifecycle changes, revision fencing, unresolved-work checks and clearing a
/// matching navigation selection are one transaction. No content is deleted.
public protocol TeammateArchiveRepository: Sendable {
    func archivedTeammates() async throws -> [Teammate]
    func archiveTeammate(
        id: TeammateID, expectedProfileRevision: UInt64, now: Date
    ) async throws -> Teammate
    func restoreTeammate(
        id: TeammateID, expectedProfileRevision: UInt64, now: Date
    ) async throws -> Teammate
}
