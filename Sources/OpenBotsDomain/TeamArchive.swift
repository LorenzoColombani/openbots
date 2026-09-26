import Foundation

public enum TeamArchiveError: Error, Equatable, Sendable {
    case notFound
    /// The team changed after the caller read it.
    case staleTeam
    /// A run in the team's chat has not finished, or a handoff there is staged,
    /// accepted or working.
    case unresolvedWork
    case invalidTransition
    case invalidDate
}

/// A team leaves the sidebar and comes back. The lifecycle change, the
/// unfinished-work check and clearing a
/// selection of its chat are one transaction. Its chat, memberships and
/// records are never touched.
public protocol TeamArchiveRepository: Sendable {
    func archivedTeams() async throws -> [Team]
    func archiveTeam(id: TeamID, expectedUpdatedAt: Date, now: Date) async throws -> Team
    func restoreTeam(id: TeamID, expectedUpdatedAt: Date, now: Date) async throws -> Team
}
