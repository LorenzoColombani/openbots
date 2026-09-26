import Foundation
import OpenBotsDomain

public enum TeammateNavigationError: Error, Equatable, Sendable {
    case notFound
    case staleRevision
    case notActive
}

/// Pin/unpin and hide/unhide change navigation only. They never stop a run,
/// revoke a capability, or rewrite transcript or memory.
public protocol TeammateNavigating: Sendable {
    func setPinned(id: TeammateID, pinned: Bool, expectedProfileRevision: UInt64) async throws -> Teammate
    func setHidden(id: TeammateID, hidden: Bool, expectedProfileRevision: UInt64) async throws -> Teammate
    func hiddenTeammates() async throws -> [Teammate]
}

public actor TeammateNavigationService: TeammateNavigating {
    private let repository: any TeammateRepository
    private let clock: any OpenBotsClock

    public init(repository: any TeammateRepository, clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository
        self.clock = clock
    }

    public func hiddenTeammates() async throws -> [Teammate] {
        try await repository.listTeammates(includingArchived: false)
            .filter { $0.lifecycle == .active && $0.isHidden }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending
            }
    }

    public func setPinned(id: TeammateID, pinned: Bool, expectedProfileRevision: UInt64) async throws -> Teammate {
        try await mutate(id: id, expectedProfileRevision: expectedProfileRevision) { teammate in
            teammate.isPinned = pinned
        }
    }

    public func setHidden(id: TeammateID, hidden: Bool, expectedProfileRevision: UInt64) async throws -> Teammate {
        try await mutate(id: id, expectedProfileRevision: expectedProfileRevision) { teammate in
            teammate.isHidden = hidden
        }
    }

    private func mutate(
        id: TeammateID,
        expectedProfileRevision: UInt64,
        body: (inout Teammate) -> Void
    ) async throws -> Teammate {
        guard var teammate = try await repository.teammate(id: id) else {
            throw TeammateNavigationError.notFound
        }
        guard teammate.profile.revision == expectedProfileRevision else {
            throw TeammateNavigationError.staleRevision
        }
        guard teammate.lifecycle == .active else {
            throw TeammateNavigationError.notActive
        }
        body(&teammate)
        teammate.updatedAt = max(teammate.updatedAt, clock.now())
        do {
            try await repository.update(teammate, expectedProfileRevision: expectedProfileRevision)
        } catch let error as RepositoryError {
            if case .optimisticLockFailed = error { throw TeammateNavigationError.staleRevision }
            throw error
        }
        return teammate
    }
}
