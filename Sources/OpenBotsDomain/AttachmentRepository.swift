public enum AttachmentRepositoryError: Error, Equatable, Sendable {
    case conversationUnavailable
    case assetNotFound
    case assetOwnerMismatch
    case assetCollision
    case draftLimitReached
    case draftItemMissing
    case invalidRevision
    case invalidExchange
    case sequenceExhausted
}

public protocol AttachmentRepository: Sendable {
    func draft(conversationID: ConversationID) async throws -> AttachmentDraftSnapshot
    /// Additive and idempotent only for exact immutable metadata. A known asset
    /// never resurrects a removed/consumed link; explicit reattachment needs a new ID.
    func stage(_ asset: AttachmentAsset) async throws -> AttachmentDraftSnapshot
    func removeDraftAttachment(id: AttachmentID, conversationID: ConversationID) async throws -> AttachmentDraftSnapshot
    /// Metadata is readable only in its owning chat and while draft/message bound.
    func attachment(id: AttachmentID, conversationID: ConversationID) async throws -> AttachmentAsset?
    /// Append one local user message and consume only its captured attachment
    /// links atomically. No teammate reply or runtime request is created.
    func commitLocalMessage(
        userMessage: Message, expectedPreviousSequence: Int64, attachmentIDs: [AttachmentID]
    ) async throws
    /// Append both local-fixture messages and consume only the captured draft
    /// links in one transaction. Text-draft persistence remains a separate seam.
    func commitLocalFixtureExchange(
        userMessage: Message, fixtureReply: Message,
        expectedPreviousSequence: Int64, attachmentIDs: [AttachmentID]
    ) async throws
}

public extension AttachmentRepository {
    func commitLocalMessage(
        userMessage: Message, expectedPreviousSequence: Int64, attachmentIDs: [AttachmentID]
    ) async throws {
        // Review-only repositories must implement the atomic local path before
        // normal saves may consume any staged attachment links.
        throw AttachmentRepositoryError.invalidExchange
    }
}
