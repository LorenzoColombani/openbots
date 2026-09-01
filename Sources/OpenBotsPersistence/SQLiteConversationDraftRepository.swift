import Foundation
import OpenBotsDomain

extension SQLiteStore: ConversationDraftRepository {
    public func loadDraft(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? {
        try transaction {
            try validateDraftConversation(conversationID)
            return try readDraftRow(conversationID: conversationID)
        }
    }

    public func saveDraft(
        conversationID: ConversationID, text: String,
        expectedRevision: UInt64, updatedAt: Date
    ) async throws -> ConversationDraftSnapshot {
        guard expectedRevision < UInt64(Int64.max) else {
            throw ConversationDraftError.invalidRevision
        }
        let snapshot = try ConversationDraftSnapshot(
            conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: updatedAt
        )
        return try transaction {
            try validateDraftConversation(conversationID)
            let existing = try readDraftRow(conversationID: conversationID)
            guard (existing?.revision ?? 0) == expectedRevision else {
                throw ConversationDraftError.staleRevision
            }
            _ = try execute(
                sql: """
                INSERT INTO conversation_drafts(conversation_id,text,revision,updated_at) VALUES (?,?,?,?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    text=excluded.text, revision=excluded.revision, updated_at=excluded.updated_at;
                """,
                bindings: [
                    .text(conversationID.persistedValue), .text(text),
                    .integer(Int64(snapshot.revision)), .real(updatedAt.timeIntervalSince1970)
                ]
            )
            return snapshot
        }
    }

    private func validateDraftConversation(_ id: ConversationID) throws {
        guard let row = try query(
            sql: "SELECT lifecycle FROM conversations WHERE id=?;",
            bindings: [.text(id.persistedValue)]
        ).first else { throw ConversationDraftError.conversationNotFound }
        switch try row.text("lifecycle") {
        case "active": return
        case "archived": throw ConversationDraftError.conversationArchived
        default: throw SQLiteStoreError.invalidRow(reason: "composer draft conversation lifecycle is invalid")
        }
    }

    private func readDraftRow(conversationID: ConversationID) throws -> ConversationDraftSnapshot? {
        guard let row = try query(
            sql: "SELECT text,revision,updated_at FROM conversation_drafts WHERE conversation_id=?;",
            bindings: [.text(conversationID.persistedValue)]
        ).first else { return nil }
        let revision = try row.integer("revision")
        guard revision > 0 else { throw ConversationDraftError.invalidRevision }
        return try ConversationDraftSnapshot(
            conversationID: conversationID, text: row.text("text"), revision: UInt64(revision),
            updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
        )
    }
}
