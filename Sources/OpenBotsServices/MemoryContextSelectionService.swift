import OpenBotsDomain

public enum MemoryContextSelectionError: Error, Equatable, Sendable {
    /// The identity is intentionally omitted so an excluded document cannot
    /// leak through a diagnostic or user-facing error.
    case duplicateCandidateIdentity
}

/// Pure scope selection. This service performs no repository, Markdown,
/// filesystem, runtime, or authorization work.
public struct MemoryContextSelectionService: Sendable {
    public init() {}

    public func manifest(
        candidates: [MemoryContextCandidate],
        request: MemoryContextRequest
    ) throws -> MemoryContextManifest {
        guard Set(candidates.map(\.documentID)).count == candidates.count else {
            throw MemoryContextSelectionError.duplicateCandidateIdentity
        }

        var included: [MemoryDocumentID] = []
        var exclusionCounts: [MemoryContextExclusionReason: Int] = [:]
        included.reserveCapacity(candidates.count)

        for candidate in candidates {
            if candidate.scope.isReadable(
                by: request.teammateID,
                selectedProjectID: request.selectedProjectID,
                activeProjectMemberships: request.activeProjectMemberships
            ) {
                included.append(candidate.documentID)
            } else {
                let reason = exclusionReason(for: candidate.scope, request: request)
                exclusionCounts[reason, default: 0] += 1
            }
        }

        return try MemoryContextManifest(
            includedDocumentIDs: included,
            exclusionCounts: exclusionCounts
        )
    }

    private func exclusionReason(
        for scope: MemoryScope,
        request: MemoryContextRequest
    ) -> MemoryContextExclusionReason {
        switch scope {
        case .user:
            // `MemoryScope.isReadable` always includes user memory. Retain a
            // fail-closed fallback without inventing an excluded identity.
            return .noSelectedProject
        case .teammate:
            return .otherTeammate
        case let .project(projectID):
            guard let selectedProjectID = request.selectedProjectID else {
                return .noSelectedProject
            }
            guard projectID == selectedProjectID else {
                return .differentProject
            }
            return .inactiveMembership
        }
    }
}
