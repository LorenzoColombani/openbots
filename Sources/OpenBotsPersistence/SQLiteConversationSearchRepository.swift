import Foundation
import OpenBotsDomain

extension SQLiteStore: ConversationSearchRepository {
    public func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        try transaction {
            // Only SQL structure is assembled here. Every user term remains a bound value.
            let profileConditions = request.terms.map { _ in
                "(t.display_name LIKE ? ESCAPE '\\' OR COALESCE(t.title,'') LIKE ? ESCAPE '\\' OR t.role LIKE ? ESCAPE '\\')"
            }.joined(separator: " AND ")
            let profileBindings = request.terms.flatMap { term -> [SQLiteBinding] in
                let pattern = "%" + term.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                return Array(repeating: .text(pattern), count: 3)
            }
            let teammateRows = try query(
                sql: """
                SELECT t.id,t.display_name,t.title,t.role,t.detailed_instructions,t.profile_revision,
                    t.lifecycle,t.is_pinned,t.is_hidden,t.notification_preference,t.claude_model,t.claude_effort,t.claude_context_window,t.created_at,t.updated_at,
                    a.mode,a.grammar_version,a.deterministic_seed,a.silhouette,a.palette_token,
                    a.eye_dialect,a.non_color_identity_cue,a.accessible_identity_description,
                    a.profile_asset_id,a.built_in_avatar_id,a.revision AS appearance_revision,c.id AS conversation_id
                FROM teammates t JOIN agent_appearances a ON a.teammate_id=t.id
                JOIN conversations c ON c.subject_id=t.id
                WHERE \(Self.searchableDirectConversation) AND \(profileConditions)
                ORDER BY t.is_pinned DESC,t.display_name COLLATE NOCASE,t.id LIMIT ?;
                """,
                bindings: profileBindings + [.integer(Int64(request.limit + 1))]
            )
            let teammates = try teammateRows.prefix(request.limit).map { row in
                TeammateSearchHit(
                    teammate: try decodeTeammate(row),
                    conversationID: try parseID(ConversationID.self, row.text("conversation_id"))
                )
            }
            // Quoting every whitespace term makes AND/OR/NOT/NEAR, quotes and '*' ordinary
            // tokenizer input, never query operators. unicode61 provides whole-word matching.
            let match = request.terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND ")
            let rows = try query(
                sql: """
                SELECT m.id,m.conversation_id,m.sequence,m.created_at,m.author_kind,m.author_teammate_id,
                    t.id AS teammate_id,t.display_name AS teammate_name,author.display_name AS author_name,
                    substr(snippet(conversation_message_search,1,'','','…',36),1,500) AS search_snippet
                FROM conversation_message_search
                JOIN messages m ON m.rowid=conversation_message_search.rowid AND m.id=conversation_message_search.message_id
                JOIN conversations c ON c.id=m.conversation_id
                JOIN teammates t ON t.id=c.subject_id
                LEFT JOIN teammates author ON author.id=m.author_teammate_id
                WHERE conversation_message_search MATCH ? AND \(Self.searchableDirectConversation)
                  AND m.output_class='conversation' AND m.author_kind IN ('user','teammate')
                ORDER BY m.created_at DESC,m.conversation_id,m.sequence DESC,m.id LIMIT ?;
                """,
                bindings: [.text(match), .integer(Int64(request.limit + 1))]
            )
            return ConversationSearchPage(
                teammates: teammates, messages: try rows.prefix(request.limit).map(decodeSearchMessage),
                hasMoreTeammates: teammateRows.count > request.limit,
                hasMoreMessages: rows.count > request.limit
            )
        }
    }

    public func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? {
        // Recheck authority from source tables, not from an old search result or index receipt.
        guard let row = try query(
            sql: """
            SELECT m.id,m.conversation_id,m.sequence,t.id AS teammate_id,
                COALESCE(c.title,t.display_name) AS current_title
            FROM messages m JOIN conversations c ON c.id=m.conversation_id
            JOIN teammates t ON t.id=c.subject_id
            WHERE m.id=? AND \(Self.searchableDirectConversation)
                AND m.output_class='conversation' AND m.author_kind IN ('user','teammate')
                AND EXISTS (SELECT 1 FROM message_parts p WHERE p.message_id=m.id AND p.kind='text');
            """,
            bindings: [.text(id.persistedValue)]
        ).first else { return nil }
        let sequence = try row.integer("sequence")
        guard sequence > 0, sequence < Int64.max else { throw SQLiteStoreError.invalidRow(reason: "search target sequence is invalid") }
        return try MessageSearchTarget(
            id: parseID(MessageID.self, row.text("id")),
            conversationID: parseID(ConversationID.self, row.text("conversation_id")),
            teammateID: parseID(TeammateID.self, row.text("teammate_id")),
            sequence: sequence, currentTitle: row.text("current_title")
        )
    }

    private static let searchableDirectConversation = """
    c.kind='direct' AND c.lifecycle='active' AND c.subject_id=t.id
    AND t.lifecycle='active' AND t.is_hidden=0
    AND EXISTS (SELECT 1 FROM conversation_participants participant
                WHERE participant.conversation_id=c.id AND participant.teammate_id=t.id AND participant.left_at IS NULL)
    """

    private func decodeSearchMessage(_ row: SQLiteRow) throws -> MessageSearchHit {
        let author: MessageAuthor
        let authorName: String
        switch try row.text("author_kind") {
        case "user":
            author = .user
            authorName = "You"
        case "teammate":
            author = .teammate(try parseID(TeammateID.self, row.text("author_teammate_id")))
            authorName = try row.text("author_name")
        default: throw SQLiteStoreError.invalidRow(reason: "search message author is invalid")
        }
        let sequence = try row.integer("sequence")
        let timestamp = try row.real("created_at")
        guard sequence > 0, sequence < Int64.max, timestamp.isFinite else {
            throw SQLiteStoreError.invalidRow(reason: "search message metadata is invalid")
        }
        return try MessageSearchHit(
            id: parseID(MessageID.self, row.text("id")),
            conversationID: parseID(ConversationID.self, row.text("conversation_id")),
            teammateID: parseID(TeammateID.self, row.text("teammate_id")),
            teammateName: row.text("teammate_name"), author: author, authorName: authorName,
            snippet: row.text("search_snippet"), sequence: sequence,
            createdAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}
