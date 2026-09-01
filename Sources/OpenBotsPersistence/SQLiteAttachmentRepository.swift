import Foundation
import OpenBotsDomain

extension SQLiteStore: AttachmentRepository {
    public func draft(conversationID: ConversationID) async throws -> AttachmentDraftSnapshot {
        try transaction {
            _ = try validateAttachmentConversation(conversationID)
            return try readAttachmentDraft(conversationID)
        }
    }

    public func stage(_ asset: AttachmentAsset) async throws -> AttachmentDraftSnapshot {
        try transaction {
            _ = try validateAttachmentConversation(asset.conversationID)
            let current = try readAttachmentDraft(asset.conversationID)
            if let existing = try readAttachmentAsset(asset.id) {
                guard existing.conversationID == asset.conversationID else { throw AttachmentRepositoryError.assetOwnerMismatch }
                guard existing == asset else { throw AttachmentRepositoryError.assetCollision }
                // A delayed/retried receipt cannot resurrect a consumed or removed link.
                return current
            }
            guard current.attachments.count < AttachmentDraftSnapshot.maximumAttachments else {
                throw AttachmentRepositoryError.draftLimitReached
            }
            let revision = try nextAttachmentRevision(current.revision)
            let maximumOrdinal = try query(
                sql: "SELECT MAX(ordinal) AS maximum FROM conversation_draft_attachment_links WHERE conversation_id=?;",
                bindings: [.text(asset.conversationID.persistedValue)]
            ).first?.optionalInteger("maximum") ?? -1
            guard maximumOrdinal < Int64.max else { throw AttachmentRepositoryError.invalidRevision }
            _ = try execute(
                sql: "INSERT INTO attachment_assets(id,conversation_id,display_name,type_identifier,byte_count,sha256,created_at) VALUES (?,?,?,?,?,?,?);",
                bindings: [
                    .text(asset.id.persistedValue), .text(asset.conversationID.persistedValue), .text(asset.displayName),
                    .text(asset.typeIdentifier), .integer(asset.byteCount), .text(asset.sha256), .real(asset.createdAt.timeIntervalSince1970)
                ]
            )
            try writeAttachmentRevision(revision, conversationID: asset.conversationID)
            _ = try execute(
                sql: "INSERT INTO conversation_draft_attachment_links(conversation_id,attachment_id,ordinal) VALUES (?,?,?);",
                bindings: [.text(asset.conversationID.persistedValue), .text(asset.id.persistedValue), .integer(maximumOrdinal + 1)]
            )
            return try readAttachmentDraft(asset.conversationID)
        }
    }

    public func removeDraftAttachment(id: AttachmentID, conversationID: ConversationID) async throws -> AttachmentDraftSnapshot {
        try transaction {
            _ = try validateAttachmentConversation(conversationID)
            let current = try readAttachmentDraft(conversationID)
            if let asset = try readAttachmentAsset(id), asset.conversationID != conversationID {
                throw AttachmentRepositoryError.assetOwnerMismatch
            }
            guard current.attachments.contains(where: { $0.id == id }) else { return current }
            let revision = try nextAttachmentRevision(current.revision)
            _ = try execute(
                sql: "DELETE FROM conversation_draft_attachment_links WHERE conversation_id=? AND attachment_id=?;",
                bindings: [.text(conversationID.persistedValue), .text(id.persistedValue)]
            )
            try writeAttachmentRevision(revision, conversationID: conversationID)
            return try readAttachmentDraft(conversationID)
        }
    }

    public func attachment(id: AttachmentID, conversationID: ConversationID) async throws -> AttachmentAsset? {
        try transaction {
            _ = try validateAttachmentConversation(conversationID)
            guard let asset = try readAttachmentAsset(id) else { return nil }
            guard asset.conversationID == conversationID else { throw AttachmentRepositoryError.assetOwnerMismatch }
            let linked = try query(
                sql: """
                SELECT 1 AS found WHERE EXISTS (
                    SELECT 1 FROM conversation_draft_attachment_links WHERE conversation_id=? AND attachment_id=?
                ) OR EXISTS (
                    SELECT 1 FROM message_parts p JOIN messages m ON m.id=p.message_id
                    WHERE m.conversation_id=? AND p.kind='attachment' AND p.referenced_id=?
                );
                """,
                bindings: [.text(conversationID.persistedValue), .text(id.persistedValue), .text(conversationID.persistedValue), .text(id.persistedValue)]
            )
            return linked.isEmpty ? nil : asset
        }
    }

    public func commitLocalMessage(
        userMessage: Message, expectedPreviousSequence: Int64, attachmentIDs: [AttachmentID]
    ) async throws {
        guard expectedPreviousSequence >= 0, expectedPreviousSequence < Int64.max else {
            throw AttachmentRepositoryError.sequenceExhausted
        }
        guard userMessage.author == .user, userMessage.outputClass == .conversation,
              userMessage.deliveryState == .completed,
              userMessage.sequence == expectedPreviousSequence + 1,
              userMessage.parts.allSatisfy({ if case .text = $0.content { true } else if case .attachment = $0.content { true } else { false } }),
              messageAttachmentIDs(userMessage) == attachmentIDs,
              Set(attachmentIDs).count == attachmentIDs.count,
              attachmentIDs.count <= AttachmentDraftSnapshot.maximumAttachments,
              userMessage.createdAt.timeIntervalSince1970.isFinite,
              userMessage.updatedAt.timeIntervalSince1970.isFinite else {
            throw AttachmentRepositoryError.invalidExchange
        }
        try transaction {
            _ = try validateAttachmentConversation(userMessage.conversationID)
            let current = try readAttachmentDraft(userMessage.conversationID)
            try validateCapturedAttachments(attachmentIDs, conversationID: userMessage.conversationID, draft: current)
            let revision = attachmentIDs.isEmpty ? current.revision : try nextAttachmentRevision(current.revision)
            try appendMessageGraph(userMessage, expectedPreviousSequence: expectedPreviousSequence)
            try consumeCapturedAttachments(attachmentIDs, conversationID: userMessage.conversationID, revision: revision)
        }
    }

    public func commitLocalFixtureExchange(
        userMessage: Message, fixtureReply: Message,
        expectedPreviousSequence: Int64, attachmentIDs: [AttachmentID]
    ) async throws {
        guard expectedPreviousSequence >= 0, expectedPreviousSequence <= Int64.max - 2 else {
            throw AttachmentRepositoryError.sequenceExhausted
        }
        guard userMessage.author == .user, userMessage.outputClass == .conversation,
              userMessage.deliveryState == .completed, fixtureReply.deliveryState == .completed,
              fixtureReply.outputClass == .conversation, userMessage.id != fixtureReply.id,
              userMessage.conversationID == fixtureReply.conversationID,
              userMessage.sequence == expectedPreviousSequence + 1,
              fixtureReply.sequence == expectedPreviousSequence + 2,
              userMessage.parts.allSatisfy({ if case .text = $0.content { true } else if case .attachment = $0.content { true } else { false } }),
              fixtureReply.parts.allSatisfy({ if case .text = $0.content { true } else { false } }),
              messageAttachmentIDs(userMessage) == attachmentIDs,
              Set(attachmentIDs).count == attachmentIDs.count,
              attachmentIDs.count <= AttachmentDraftSnapshot.maximumAttachments,
              userMessage.createdAt.timeIntervalSince1970.isFinite,
              userMessage.updatedAt.timeIntervalSince1970.isFinite,
              fixtureReply.createdAt.timeIntervalSince1970.isFinite,
              fixtureReply.updatedAt.timeIntervalSince1970.isFinite else {
            throw AttachmentRepositoryError.invalidExchange
        }
        try transaction {
            let teammateID = try validateAttachmentConversation(userMessage.conversationID)
            guard fixtureReply.author == .teammate(teammateID) else { throw AttachmentRepositoryError.invalidExchange }
            let current = try readAttachmentDraft(userMessage.conversationID)
            try validateCapturedAttachments(attachmentIDs, conversationID: userMessage.conversationID, draft: current)
            // Import completion order may differ from the user's visible order.
            // The frozen IDs already match the exact message-part order above;
            // current draft links establish membership, not send ordering.
            let revision = attachmentIDs.isEmpty ? current.revision : try nextAttachmentRevision(current.revision)
            try appendMessageGraph(userMessage, expectedPreviousSequence: expectedPreviousSequence)
            try appendMessageGraph(fixtureReply, expectedPreviousSequence: userMessage.sequence)
            try consumeCapturedAttachments(attachmentIDs, conversationID: userMessage.conversationID, revision: revision)
        }
    }

    private func validateCapturedAttachments(
        _ attachmentIDs: [AttachmentID], conversationID: ConversationID, draft: AttachmentDraftSnapshot
    ) throws {
        for id in attachmentIDs {
            guard let asset = try readAttachmentAsset(id) else { throw AttachmentRepositoryError.assetNotFound }
            guard asset.conversationID == conversationID else { throw AttachmentRepositoryError.assetOwnerMismatch }
            guard draft.attachments.contains(where: { $0.id == id }) else { throw AttachmentRepositoryError.draftItemMissing }
        }
    }

    private func consumeCapturedAttachments(
        _ attachmentIDs: [AttachmentID], conversationID: ConversationID, revision: Int64
    ) throws {
        for id in attachmentIDs {
            _ = try execute(
                sql: "DELETE FROM conversation_draft_attachment_links WHERE conversation_id=? AND attachment_id=?;",
                bindings: [.text(conversationID.persistedValue), .text(id.persistedValue)]
            )
        }
        if !attachmentIDs.isEmpty { try writeAttachmentRevision(revision, conversationID: conversationID) }
    }

    /// Shared append paths must not turn unknown or other-chat IDs into message references.
    func validateAttachmentReferences(in message: Message) throws {
        let ids = messageAttachmentIDs(message)
        guard ids.count <= AttachmentDraftSnapshot.maximumAttachments, Set(ids).count == ids.count else {
            throw AttachmentRepositoryError.invalidExchange
        }
        for id in ids {
            guard let asset = try readAttachmentAsset(id) else { throw AttachmentRepositoryError.assetNotFound }
            guard asset.conversationID == message.conversationID else { throw AttachmentRepositoryError.assetOwnerMismatch }
        }
    }

    private func messageAttachmentIDs(_ message: Message) -> [AttachmentID] {
        message.parts.compactMap { if case let .attachment(id) = $0.content { id } else { nil } }
    }

    private func validateAttachmentConversation(_ id: ConversationID) throws -> TeammateID {
        guard let row = try query(
            sql: """
            SELECT t.id FROM conversations c JOIN teammates t ON t.id=c.subject_id
            WHERE c.id=? AND c.kind='direct' AND c.lifecycle='active' AND t.lifecycle='active' AND t.is_hidden=0
              AND EXISTS (SELECT 1 FROM conversation_participants p
                          WHERE p.conversation_id=c.id AND p.teammate_id=t.id AND p.left_at IS NULL);
            """,
            bindings: [.text(id.persistedValue)]
        ).first else { throw AttachmentRepositoryError.conversationUnavailable }
        return try parseID(TeammateID.self, row.text("id"))
    }

    private func readAttachmentAsset(_ id: AttachmentID) throws -> AttachmentAsset? {
        guard let row = try query(sql: "SELECT * FROM attachment_assets WHERE id=?;", bindings: [.text(id.persistedValue)]).first else { return nil }
        return try decodeAttachmentAsset(row)
    }

    private func decodeAttachmentAsset(_ row: SQLiteRow) throws -> AttachmentAsset {
        try AttachmentAsset(
            id: parseID(AttachmentID.self, row.text("id")), conversationID: parseID(ConversationID.self, row.text("conversation_id")),
            displayName: row.text("display_name"), typeIdentifier: row.text("type_identifier"),
            byteCount: row.integer("byte_count"), sha256: row.text("sha256"),
            createdAt: Date(timeIntervalSince1970: row.real("created_at"))
        )
    }

    private func readAttachmentDraft(_ conversationID: ConversationID) throws -> AttachmentDraftSnapshot {
        let revisionRow = try query(
            sql: "SELECT revision FROM conversation_attachment_drafts WHERE conversation_id=?;", bindings: [.text(conversationID.persistedValue)]
        ).first
        let revision = try revisionRow?.integer("revision") ?? 0
        guard revisionRow == nil || revision > 0 else { throw AttachmentRepositoryError.invalidRevision }
        let rows = try query(
            sql: """
            SELECT a.*,l.ordinal AS draft_ordinal FROM conversation_draft_attachment_links l
            LEFT JOIN attachment_assets a ON a.id=l.attachment_id
            WHERE l.conversation_id=? ORDER BY l.ordinal LIMIT 25;
            """,
            bindings: [.text(conversationID.persistedValue)]
        )
        guard rows.count <= AttachmentDraftSnapshot.maximumAttachments, rows.isEmpty || revision > 0 else {
            throw AttachmentRepositoryError.invalidRevision
        }
        let assets = try rows.map { row in
            let asset = try decodeAttachmentAsset(row)
            guard asset.conversationID == conversationID else { throw AttachmentRepositoryError.assetOwnerMismatch }
            guard try row.integer("draft_ordinal") >= 0 else { throw AttachmentRepositoryError.invalidRevision }
            return asset
        }
        return AttachmentDraftSnapshot(conversationID: conversationID, revision: revision, attachments: assets)
    }

    private func nextAttachmentRevision(_ current: Int64) throws -> Int64 {
        guard current >= 0, current < Int64.max else { throw AttachmentRepositoryError.invalidRevision }
        return current + 1
    }

    private func writeAttachmentRevision(_ revision: Int64, conversationID: ConversationID) throws {
        _ = try execute(
            sql: """
            INSERT INTO conversation_attachment_drafts(conversation_id,revision) VALUES (?,?)
            ON CONFLICT(conversation_id) DO UPDATE SET revision=excluded.revision;
            """,
            bindings: [.text(conversationID.persistedValue), .integer(revision)]
        )
    }
}
