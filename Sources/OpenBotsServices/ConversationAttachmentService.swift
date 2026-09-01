import Foundation
import OpenBotsContent
import OpenBotsDomain

public enum ConversationAttachmentError: Error, Equatable, Sendable {
    case unavailable
    case invalidMessageRoute
    case attachmentUnavailable
    case invalidPreviewPage
}

public protocol AttachmentContentValidating: Sendable {
    func validateAttachments(ids: [AttachmentID], conversationID: ConversationID) async throws
}

/// Coordinates immutable owned content and SQLite links. No user source path
/// survives an import, and removing a draft never deletes bytes or the source.
public actor ConversationAttachmentService: AttachmentContentValidating {
    public typealias Importer = @Sendable (URL, AttachmentID) async throws -> StoredAttachmentContent
    public typealias Verifier = @Sendable (AttachmentAsset) async throws -> Void
    public typealias Location = @Sendable (AttachmentAsset) async throws -> URL
    public typealias Previewer = @Sendable (AttachmentAsset, Int) async throws -> AttachmentPreview

    private let repository: any AttachmentRepository
    private let messages: any MessageRepository
    private let importer: Importer
    private let verifier: Verifier
    private let location: Location
    private let previewer: Previewer?
    private let clock: any OpenBotsClock

    public init(repository: any AttachmentRepository, messages: any MessageRepository,
                importer: @escaping Importer, verifier: @escaping Verifier,
                location: @escaping Location, clock: any OpenBotsClock = SystemClock(),
                previewer: Previewer? = nil) {
        self.repository = repository
        self.messages = messages
        self.importer = importer
        self.verifier = verifier
        self.location = location
        self.clock = clock
        self.previewer = previewer
    }

    public func draft(conversationID: ConversationID) async throws -> AttachmentDraftSnapshot {
        try await repository.draft(conversationID: conversationID)
    }

    public func importFile(_ url: URL, operationID: UUID,
                           conversationID: ConversationID) async throws -> AttachmentAsset {
        // Validate the owner before reading a selected source. Publication is
        // exclusive; a later DB failure leaves an owned orphan, never cleanup
        // authority over the selected file or an existing published object.
        _ = try await repository.draft(conversationID: conversationID)
        try Task.checkCancellation()
        let id = AttachmentID(operationID)
        let stored = try await importer(url, id)
        try Task.checkCancellation()
        guard stored.id == id else { throw ConversationAttachmentError.attachmentUnavailable }
        let asset = try AttachmentAsset(
            id: id, conversationID: conversationID, displayName: stored.displayName,
            typeIdentifier: stored.typeIdentifier, byteCount: stored.byteCount,
            sha256: stored.sha256, createdAt: clock.now()
        )
        try await verifier(asset)
        try Task.checkCancellation()
        _ = try await repository.stage(asset)
        // Once registration commits, return its identity even if cancellation
        // arrived at that boundary. The draft model can remove this exact link.
        return asset
    }

    public func remove(id: AttachmentID, conversationID: ConversationID) async throws -> AttachmentDraftSnapshot {
        try await repository.removeDraftAttachment(id: id, conversationID: conversationID)
    }

    public func validateAttachments(ids: [AttachmentID], conversationID: ConversationID) async throws {
        guard Set(ids).count == ids.count else { throw ConversationAttachmentError.attachmentUnavailable }
        for id in ids {
            try Task.checkCancellation()
            guard let asset = try await repository.attachment(id: id, conversationID: conversationID) else {
                throw ConversationAttachmentError.attachmentUnavailable
            }
            try await verifier(asset)
        }
    }

    public func attachment(messageID: MessageID, partID: MessagePartID,
                           attachmentID: AttachmentID) async throws -> AttachmentAsset {
        guard let message = try await messages.message(id: messageID),
              message.parts.contains(where: { $0.id == partID && $0.content == .attachment(attachmentID) }),
              let asset = try await repository.attachment(id: attachmentID, conversationID: message.conversationID)
        else { throw ConversationAttachmentError.invalidMessageRoute }
        return asset
    }

    /// Used only after an explicit Reveal action. Returning this owned path is
    /// not permission to execute it, mutate it, or clean its original source.
    public func revealLocation(messageID: MessageID, partID: MessagePartID,
                               attachmentID: AttachmentID) async throws -> URL {
        let asset = try await attachment(messageID: messageID, partID: partID, attachmentID: attachmentID)
        return try await location(asset)
    }

    /// A view-only operation tied to an existing typed message part. The
    /// renderer receives verified owned bytes through the injected boundary,
    /// never an original source URL or external-file capability.
    public func preview(messageID: MessageID, partID: MessagePartID,
                        attachmentID: AttachmentID, pageNumber: Int = 1) async throws -> AttachmentPreview {
        guard (1...AttachmentPreviewLimits.maximumPDFPages).contains(pageNumber) else {
            throw ConversationAttachmentError.invalidPreviewPage
        }
        guard let previewer else { throw ConversationAttachmentError.unavailable }
        try Task.checkCancellation()
        let asset = try await attachment(messageID: messageID, partID: partID, attachmentID: attachmentID)
        try Task.checkCancellation()
        let result = try await previewer(asset, pageNumber)
        try Task.checkCancellation()
        try result.validate(requestedPage: pageNumber)
        return result
    }
}
