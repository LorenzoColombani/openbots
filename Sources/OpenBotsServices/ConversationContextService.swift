import OpenBotsDomain

public protocol ConversationContextServing: Sendable {
    func load(conversationID: ConversationID, teammateID: TeammateID) async throws -> ConversationContextSelection
    func save(
        conversationID: ConversationID, teammateID: TeammateID,
        projectID: ProjectID?, teamID: TeamID?, expectedRevision: UInt64
    ) async throws -> ConversationContextSelection
}

/// Stores only an explicit context choice. No runtime, memory content,
/// filesystem capability, credential, or automatic first-project selection.
public actor ConversationContextService: ConversationContextServing {
    private let repository: any ConversationContextRepository

    public init(repository: any ConversationContextRepository) {
        self.repository = repository
    }

    public func load(
        conversationID: ConversationID, teammateID: TeammateID
    ) async throws -> ConversationContextSelection {
        let selection = try await repository.loadContext(conversationID: conversationID)
        guard selection.conversationID == conversationID else {
            throw ConversationContextError.invalidRepositoryResponse
        }
        guard selection.teammateID == teammateID else {
            throw ConversationContextError.teammateMismatch
        }
        guard selection.revision <= UInt64(Int64.max),
              selection.revision != 0 || (selection.projectID == nil && selection.teamID == nil) else {
            throw ConversationContextError.invalidRepositoryResponse
        }
        return selection
    }

    public func save(
        conversationID: ConversationID, teammateID: TeammateID,
        projectID: ProjectID?, teamID: TeamID?, expectedRevision: UInt64
    ) async throws -> ConversationContextSelection {
        guard expectedRevision < UInt64(Int64.max) else {
            throw ConversationContextError.invalidRevision
        }
        let saved = try await repository.saveContext(ConversationContextSelection(
            conversationID: conversationID, teammateID: teammateID,
            projectID: projectID, teamID: teamID, revision: expectedRevision
        ))
        guard saved.conversationID == conversationID,
              saved.teammateID == teammateID,
              saved.projectID == projectID, saved.teamID == teamID,
              saved.revision == expectedRevision + 1 else {
            throw ConversationContextError.invalidRepositoryResponse
        }
        return saved
    }
}
