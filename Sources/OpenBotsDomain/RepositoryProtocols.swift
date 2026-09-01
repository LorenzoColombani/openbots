import Foundation

public enum RepositoryError: Error, Equatable, Sendable {
    case notFound(entity: String, id: String)
    case alreadyExists(entity: String, id: String)
    case optimisticLockFailed(entity: String, id: String)
    case sequenceConflict(conversationID: ConversationID, expected: Int64, actual: Int64)
    case protectionModeMismatch
    case unavailable(reason: String)
}

public protocol TeammateRepository: Sendable {
    func teammate(id: TeammateID) async throws -> Teammate?
    func listTeammates(includingArchived: Bool) async throws -> [Teammate]
    func insert(_ teammate: Teammate) async throws
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws
}

public protocol ProjectRepository: Sendable {
    func project(id: ProjectID) async throws -> Project?
    func listProjects(includingArchived: Bool) async throws -> [Project]
    func insert(_ project: Project) async throws
    func update(_ project: Project) async throws
    func setMembership(_ membership: ProjectMembership) async throws
    func activeMemberIDs(projectID: ProjectID) async throws -> Set<TeammateID>
}

/// Creates one project and its initial teammate memberships as a single
/// durable aggregate. Callers must not reproduce this operation by inserting
/// the project and then issuing independent membership writes, because a
/// failure could otherwise publish a partially configured project.
public protocol ProjectProvisioningRepository: Sendable {
    func provisionProject(
        _ project: Project,
        initialMemberIDs: Set<TeammateID>
    ) async throws
}

public protocol TeamRepository: Sendable {
    func team(id: TeamID) async throws -> Team?
    func listTeams(includingArchived: Bool) async throws -> [Team]
    func insert(_ team: Team) async throws
    func update(_ team: Team) async throws
}

public protocol ConversationRepository: Sendable {
    func conversation(id: ConversationID) async throws -> Conversation?
    func conversations(for teammateID: TeammateID, includingArchived: Bool) async throws -> [Conversation]
    func insert(_ conversation: Conversation, participantIDs: Set<TeammateID>) async throws
    func update(_ conversation: Conversation) async throws
}

/// Creates the smallest durable chat aggregate in one repository transaction.
///
/// The optional greeting is deliberately named as a fixture at this boundary:
/// its human-visible content must disclose that no production runtime produced
/// it. The application service owns that wording; persistence validates the
/// stable identities and sequence before storing the supplied message exactly.
public protocol DirectChatProvisioningRepository: Sendable {
    func provisionDirectChat(
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws
}

/// Persists the provisional, chat-led teammate hiring flow. A hiring draft is
/// not a teammate and owns no capabilities. Confirmation is the only boundary
/// that may atomically create the supplied durable teammate/direct-chat graph.
public protocol HiringDraftRepository: Sendable {
    func latestHiringDraft() async throws -> HiringDraftSnapshot?

    @discardableResult
    func createHiringDraft(_ snapshot: HiringDraftSnapshot) async throws -> HiringDraftSnapshot

    @discardableResult
    func reviseHiringDraft(
        _ draft: HiringDraft,
        expectedRevision: UInt64,
        appending turns: [HiringTurn]
    ) async throws -> HiringDraftSnapshot

    func cancelHiringDraft(id: HiringDraftID, expectedRevision: UInt64) async throws

    func confirmHiringDraft(
        id: HiringDraftID,
        expectedRevision: UInt64,
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws
}

/// Persists only the current direct-chat navigation choice. This is separate
/// from teammate and conversation mutation so presentation models can restore
/// selection without receiving a database handle or a broad settings surface.
public protocol ChatSelectionRepository: Sendable {
    func selectedConversationID() async throws -> ConversationID?
    func setSelectedConversationID(_ conversationID: ConversationID?) async throws
}

public protocol MessageRepository: Sendable {
    func append(_ message: Message, expectedPreviousSequence: Int64) async throws
    func message(id: MessageID) async throws -> Message?
    func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message>
    func updateDeliveryState(
        messageID: MessageID,
        from expectedState: MessageDeliveryState,
        to newState: MessageDeliveryState,
        updatedAt: Date
    ) async throws
}

public protocol MemoryRepository: Sendable {
    func authorityContract() async throws -> MemoryAuthorityContract
    func document(id: MemoryDocumentID) async throws -> MemoryDocument?
    func allDocuments() async throws -> [MemoryDocument]
    func documents(scope: MemoryScope) async throws -> [MemoryDocument]
    func insert(_ document: MemoryDocument) async throws
    func insertRevision(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) async throws
}

public extension MemoryRepository {
    func authorityContract() async throws -> MemoryAuthorityContract {
        .appOwnedMarkdownV1
    }

    func allDocuments() async throws -> [MemoryDocument] {
        throw RepositoryError.unavailable(
            reason: "This memory repository cannot enumerate every scope."
        )
    }

    func insertRevision(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) async throws {
        guard document.supersedes == expectedPredecessorID else {
            throw RepositoryError.optimisticLockFailed(
                entity: "memory predecessor",
                id: expectedPredecessorID?.persistedValue ?? "initial"
            )
        }
        try await insert(document)
    }
}

public protocol CapabilityGrantRepository: Sendable {
    func activeGrants(teammateID: TeammateID) async throws -> [CapabilityGrant]
    func insert(_ grant: CapabilityGrant) async throws
    func update(_ grant: CapabilityGrant) async throws
}

public protocol ApprovalRepository: Sendable {
    func approval(id: ApprovalID) async throws -> ApprovalRequest?
    func insert(_ approval: ApprovalRequest) async throws
    func update(_ approval: ApprovalRequest, expectedState: ApprovalState) async throws
}
