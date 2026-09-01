/// One direct conversation's chosen work context. This does not change the
/// conversation kind, grant membership, or authorize a future runtime turn.
/// Repositories revalidate live membership whenever this value is loaded/saved.
public struct ConversationContextSelection: Equatable, Sendable {
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let projectID: ProjectID?
    public let teamID: TeamID?
    /// Zero means that this conversation has no persisted selection yet.
    public let revision: UInt64

    public init(
        conversationID: ConversationID,
        teammateID: TeammateID,
        projectID: ProjectID? = nil,
        teamID: TeamID? = nil,
        revision: UInt64 = 0
    ) {
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.projectID = projectID
        self.teamID = teamID
        self.revision = revision
    }
}

/// Path-free recovery reasons. Invalidation deliberately carries only the
/// revision: unavailable project/team identities must not become usable scope.
public enum ConversationContextError: Error, Equatable, Sendable {
    case conversationNotFound
    case conversationUnavailable
    case teammateMismatch
    case teammateUnavailable
    case projectUnavailable
    case teamUnavailable
    case selectionInvalidated(revision: UInt64)
    case staleRevision
    case invalidRevision
    case invalidRepositoryResponse
}

public protocol ConversationContextRepository: Sendable {
    func loadContext(conversationID: ConversationID) async throws -> ConversationContextSelection

    /// Uses `selection.revision` as a compare-and-swap precondition. Returns
    /// the newly committed selection with its successor revision. Clearing is
    /// explicit: save both IDs as nil at the current revision, even when the
    /// prior selection is invalidated. No automatic clear or default occurs.
    func saveContext(_ selection: ConversationContextSelection) async throws -> ConversationContextSelection
}
