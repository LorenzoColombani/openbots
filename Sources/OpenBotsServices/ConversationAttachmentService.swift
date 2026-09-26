import Foundation
import OpenBotsContent
import OpenBotsDomain

public enum ConversationAttachmentError: Error, Equatable, Sendable {
    case unavailable
    case invalidMessageRoute
    case attachmentUnavailable
    case invalidPreviewPage
}

/// Turns the files a bot made into chips on its saved reply.
public protocol ProducedFileAttaching: Sendable {
    /// Copies each file into the app's attachment store and links it to the
    /// reply, in order. A file that cannot be taken is skipped, never fatal.
    func attachProducedFiles(_ files: [URL], toReply messageID: MessageID,
                             conversationID: ConversationID) async -> [AttachmentAsset]
    /// Links every member's chips in one transaction before the lead's reply
    /// becomes visible. Missing assets and failed writes must fail the
    /// compilation; a partial delivery cannot return the handoffs. With no
    /// `limit`, capacity fails it too. With one, only the first `limit`
    /// chips come, and `leftOut` counts the rest,
    /// which stay on the members' own replies in the work record.
    func carryAttachments(fromReplies sourceIDs: [MessageID], toReply messageID: MessageID,
                          conversationID: ConversationID,
                          limit: Int?) async throws -> (carried: [AttachmentAsset], leftOut: Int)
    /// Every chip on the members' replies, each once, in order, with its
    /// record when the record is there and its owned copy passes the check;
    /// nil marks a chip that is gone. A reply that is gone, or in another chat, throws.
    func returnedChips(fromReplies sourceIDs: [MessageID],
                       conversationID: ConversationID) async throws -> [ReturnedChip]
    /// A file the user chose in a missing chip's place, taken as an owned copy for
    /// this chat. Its record is written when it is carried.
    func takeReplacement(_ url: URL, conversationID: ConversationID) async throws -> AttachmentAsset
    /// Links chips already resolved, in order, the way `carryAttachments`
    /// does: the first `limit` come and `leftOut` counts the rest.
    func carry(_ assets: [AttachmentAsset], toReply messageID: MessageID,
               conversationID: ConversationID, limit: Int?) async throws -> (carried: [AttachmentAsset], leftOut: Int)
}

/// One chip a lead turn would return: whose reply it is on, and its record,
/// or nil when the chip is gone.
public struct ReturnedChip: Equatable, Sendable {
    public let replyID: MessageID
    public let attachmentID: AttachmentID
    public let asset: AttachmentAsset?
    /// The file's name when the record says it, even when the copy is gone.
    public let displayName: String?
    public init(replyID: MessageID, attachmentID: AttachmentID, asset: AttachmentAsset?, displayName: String?) {
        self.replyID = replyID; self.attachmentID = attachmentID; self.asset = asset; self.displayName = displayName
    }
}

extension ConversationAttachmentService: ProducedFileAttaching {
    public func attachProducedFiles(_ files: [URL], toReply messageID: MessageID,
                                    conversationID: ConversationID) async -> [AttachmentAsset] {
        var assets: [AttachmentAsset] = []
        for file in files.prefix(AttachmentDraftSnapshot.maximumAttachments) {
            guard let taken = try? await take(file, conversationID: conversationID) else {
                AgenticDiagnosticsLog.note("deliverable", "a produced file could not be taken as a chip")
                continue
            }
            assets.append(taken)
        }
        return await link(assets, toReply: messageID, conversationID: conversationID)
    }

    public func carryAttachments(fromReplies sourceIDs: [MessageID], toReply messageID: MessageID,
                                 conversationID: ConversationID,
                                 limit: Int?) async throws -> (carried: [AttachmentAsset], leftOut: Int) {
        var assets: [AttachmentAsset] = []
        var seen: Set<AttachmentID> = []
        for sourceID in sourceIDs {
            guard let source = try await messages.message(id: sourceID), source.conversationID == conversationID else {
                throw ConversationAttachmentError.invalidMessageRoute
            }
            for part in source.parts {
                guard case .attachment(let id) = part.content, seen.insert(id).inserted else { continue }
                guard let asset = try await repository.attachment(id: id, conversationID: conversationID) else {
                    throw ConversationAttachmentError.attachmentUnavailable
                }
                assets.append(asset)
            }
        }
        // Every chip is found before any is left out: a missing one still fails.
        return try await carry(assets, toReply: messageID, conversationID: conversationID, limit: limit)
    }

    public func returnedChips(fromReplies sourceIDs: [MessageID],
                              conversationID: ConversationID) async throws -> [ReturnedChip] {
        var chips: [ReturnedChip] = []
        var seen: Set<AttachmentID> = []
        for sourceID in sourceIDs {
            guard let source = try await messages.message(id: sourceID), source.conversationID == conversationID else {
                throw ConversationAttachmentError.invalidMessageRoute
            }
            for part in source.parts {
                guard case .attachment(let id) = part.content, seen.insert(id).inserted else { continue }
                // A record that is not there is a missing chip; a read that
                // fails throws, and the carry reads the replies itself as before.
                let asset = try await repository.attachment(id: id, conversationID: conversationID)
                var present = asset
                if let asset {
                    do { try await verifier(asset) } catch { present = nil }
                }
                chips.append(ReturnedChip(replyID: sourceID, attachmentID: id, asset: present,
                                          displayName: asset?.displayName))
            }
        }
        return chips
    }

    public func takeReplacement(_ url: URL, conversationID: ConversationID) async throws -> AttachmentAsset {
        try await take(url, conversationID: conversationID)
    }

    public func carry(_ assets: [AttachmentAsset], toReply messageID: MessageID,
                      conversationID: ConversationID, limit: Int?) async throws -> (carried: [AttachmentAsset], leftOut: Int) {
        var assets = assets
        let leftOut = limit.map { max(0, assets.count - max(0, $0)) } ?? 0
        assets.removeLast(leftOut)
        guard !assets.isEmpty else { return ([], leftOut) }
        // The existing per-message limit applies to the complete chain, not
        // separately to each member. SQLite either links the whole set or none.
        try await repository.attachProducedAssets(assets, toReply: messageID, conversationID: conversationID)
        guard let destination = try await messages.message(id: messageID),
              destination.conversationID == conversationID,
              Set(assets.map(\.id)).isSubset(of: Set(destination.parts.compactMap {
                  if case .attachment(let id) = $0.content { id } else { nil }
              })) else { throw ConversationAttachmentError.attachmentUnavailable }
        return (assets, leftOut)
    }

    /// The bot's file becomes an owned copy the way a picked file does, but it
    /// never passes through the user's draft: the record is written with the
    /// link, in one transaction, and a team chat (which has no draft) takes
    /// it the same way.
    private func take(_ url: URL, conversationID: ConversationID) async throws -> AttachmentAsset {
        let id = AttachmentID(UUID())
        let stored = try await importer(url, id)
        try Task.checkCancellation()
        guard stored.id == id else { throw ConversationAttachmentError.attachmentUnavailable }
        let asset = try AttachmentAsset(
            id: id, conversationID: conversationID, displayName: stored.displayName,
            typeIdentifier: stored.typeIdentifier, byteCount: stored.byteCount,
            sha256: stored.sha256, createdAt: clock.now()
        )
        try await verifier(asset)
        return asset
    }

    private func link(_ assets: [AttachmentAsset], toReply messageID: MessageID,
                      conversationID: ConversationID) async -> [AttachmentAsset] {
        guard !assets.isEmpty else { return [] }
        do {
            try await repository.attachProducedAssets(assets, toReply: messageID, conversationID: conversationID)
        } catch {
            AgenticDiagnosticsLog.error("deliverable", "produced files not linked to the reply: \(String(describing: error).prefix(120))")
            return []
        }
        return assets
    }
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
