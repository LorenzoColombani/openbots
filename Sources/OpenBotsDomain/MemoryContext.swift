import Foundation

/// The exact scope inputs used to assemble one teammate turn. Memberships are
/// supplied as a current snapshot; this value performs no repository or file
/// access and cannot retain a previous project's selection.
public struct MemoryContextRequest: Codable, Equatable, Sendable {
    public let teammateID: TeammateID
    public let selectedProjectID: ProjectID?
    public let activeProjectMemberships: Set<ProjectID>

    public init(
        teammateID: TeammateID,
        selectedProjectID: ProjectID?,
        activeProjectMemberships: Set<ProjectID>
    ) {
        self.teammateID = teammateID
        self.selectedProjectID = selectedProjectID
        self.activeProjectMemberships = activeProjectMemberships
    }
}

/// An identity and scope presented to the selector. Content, titles, paths,
/// and digests are deliberately absent so an excluded candidate cannot leak
/// through this boundary.
public struct MemoryContextCandidate: Codable, Equatable, Sendable {
    public let documentID: MemoryDocumentID
    public let scope: MemoryScope

    public init(documentID: MemoryDocumentID, scope: MemoryScope) {
        self.documentID = documentID
        self.scope = scope
    }
}

public enum MemoryContextExclusionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case otherTeammate
    case noSelectedProject
    case differentProject
    case inactiveMembership
}

/// The safe output of scope selection. Included identities may be resolved by
/// a later, separately authorized content reader. Exclusions are counts only:
/// excluded document identities and metadata never cross this boundary.
public struct MemoryContextManifest: Codable, Equatable, Sendable {
    public let includedDocumentIDs: [MemoryDocumentID]
    public let exclusionCounts: [MemoryContextExclusionReason: Int]

    public var totalExcludedCount: Int {
        exclusionCounts.values.reduce(0, +)
    }

    public init(
        includedDocumentIDs: [MemoryDocumentID],
        exclusionCounts: [MemoryContextExclusionReason: Int]
    ) throws {
        guard Set(includedDocumentIDs).count == includedDocumentIDs.count else {
            throw DomainValidationError.invalid(
                field: "memory context manifest",
                reason: "included document identities must be unique"
            )
        }
        guard exclusionCounts.values.allSatisfy({ $0 > 0 }) else {
            throw DomainValidationError.invalid(
                field: "memory context exclusions",
                reason: "recorded exclusion counts must be positive"
            )
        }
        self.includedDocumentIDs = includedDocumentIDs
        self.exclusionCounts = exclusionCounts
    }
}
