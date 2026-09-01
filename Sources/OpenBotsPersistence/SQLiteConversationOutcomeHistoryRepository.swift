import Foundation
import OpenBotsDomain

extension SQLiteStore: ConversationOutcomeHistoryRepository {
    /// This is a status projection, not a run/proposal loader. Frozen requests,
    /// envelopes, messages, profile text and lease values never enter its rows.
    public func outcomeHistory(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistoryPage {
        try transaction {
            let scope: [SQLiteBinding] = [.text(request.conversationID.persistedValue), .text(request.teammateID.persistedValue)]
            guard try !query(sql: """
                SELECT 1 AS visible FROM conversations c JOIN teammates t ON t.id=c.subject_id
                WHERE c.id=? AND t.id=? AND \(Self.visibleOutcomeConversation) LIMIT 1;
                """, bindings: scope).isEmpty else {
                return ConversationOutcomeHistoryPage(request: request, scope: .unavailable, records: [], hasMore: false)
            }
            let bound = SQLiteBinding.integer(Int64(request.limit + 1))
            let runRows = try query(sql: """
                SELECT CASE WHEN length(CAST(r.id AS BLOB))=36 THEN r.id END AS id,
                    CASE WHEN length(CAST(r.state AS BLOB))<=32 THEN r.state END AS state,
                    CASE WHEN length(CAST(m.origin AS BLOB))<=32 THEN m.origin END AS origin,
                    r.created_at,r.updated_at,
                    EXISTS (SELECT 1 FROM run_input_receipts i WHERE i.run_id=r.id
                        AND i.state IN ('queued','submitted')) AS unconfirmed_input,
                    EXISTS (SELECT 1 FROM run_input_receipts i WHERE i.run_id=r.id
                        AND i.state='outcomeUnknown') AS unknown_input,
                    EXISTS (SELECT 1 FROM run_input_receipts i WHERE i.run_id=r.id
                        AND i.state NOT IN ('queued','submitted','acknowledged','outcomeUnknown')) AS invalid_input
                FROM work_runs r LEFT JOIN run_journal_metadata m ON m.run_id=r.id
                WHERE r.conversation_id=? AND r.teammate_id=?
                ORDER BY r.updated_at DESC,r.id ASC LIMIT ?;
                """, bindings: scope + [bound])
            let proposalRows = try query(sql: """
                SELECT CASE WHEN length(CAST(id AS BLOB))=36 THEN id END AS id,
                    CASE WHEN length(CAST(state AS BLOB))<=32 THEN state END AS state,updated_at
                FROM action_proposals WHERE conversation_id=? AND teammate_id=?
                ORDER BY updated_at DESC,id ASC LIMIT ?;
                """, bindings: scope + [bound])

            // Each family contributes at most limit+1, enough to determine the
            // exact combined prefix and hasMore without scanning full payloads.
            let records = try (runRows.map { try decodeOutcomeRun($0, request: request) }
                + proposalRows.map { try decodeOutcomeProposal($0, request: request) })
                .sorted { first, second in
                    if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
                    let a = Self.outcomeOrder(first.event), b = Self.outcomeOrder(second.event)
                    return a.kind == b.kind ? a.id < b.id : a.kind < b.kind
                }
            return ConversationOutcomeHistoryPage(request: request, scope: .available,
                records: Array(records.prefix(request.limit)), hasMore: records.count > request.limit)
        }
    }

    private static let visibleOutcomeConversation = """
    c.kind='direct' AND c.lifecycle='active' AND c.subject_id=t.id
    AND t.lifecycle='active' AND t.is_hidden=0
    AND EXISTS (SELECT 1 FROM conversation_participants p
        WHERE p.conversation_id=c.id AND p.teammate_id=t.id AND p.left_at IS NULL)
    """

    private func decodeOutcomeRun(_ row: SQLiteRow, request: ConversationOutcomeHistoryRequest) throws -> SavedOutcomeRecord {
        do {
            let rawID = try row.text("id"), id = try parseID(RunID.self, rawID)
            let created = try row.real("created_at"), updated = try row.real("updated_at")
            guard id.persistedValue == rawID, created.isFinite, updated.isFinite, updated >= created,
                  let state = WorkRunState(rawValue: try row.text("state")),
                  let origin = RunOrigin(rawValue: try row.text("origin")),
                  try row.integer("invalid_input") == 0 else {
                throw ConversationOutcomeHistoryError.invalidRepositoryResponse
            }
            return SavedOutcomeRecord(conversationID: request.conversationID, teammateID: request.teammateID,
                updatedAt: Date(timeIntervalSince1970: updated), event: .run(id: id, origin: origin, state: state,
                    hasUnconfirmedInput: try row.integer("unconfirmed_input") == 1,
                    hasUnknownInput: try row.integer("unknown_input") == 1))
        } catch { throw ConversationOutcomeHistoryError.invalidRepositoryResponse }
    }

    private func decodeOutcomeProposal(_ row: SQLiteRow, request: ConversationOutcomeHistoryRequest) throws -> SavedOutcomeRecord {
        do {
            let rawID = try row.text("id"), id = try parseID(ApprovalID.self, rawID)
            let updated = try row.real("updated_at")
            guard id.persistedValue == rawID, updated.isFinite,
                  let state = ActionProposalState(rawValue: try row.text("state")) else {
                throw ConversationOutcomeHistoryError.invalidRepositoryResponse
            }
            return SavedOutcomeRecord(conversationID: request.conversationID, teammateID: request.teammateID,
                updatedAt: Date(timeIntervalSince1970: updated), event: .proposal(id: id, state: state))
        } catch { throw ConversationOutcomeHistoryError.invalidRepositoryResponse }
    }

    private static func outcomeOrder(_ event: SavedOutcomeEvent) -> (kind: Int, id: String) {
        switch event {
        case .run(let id, _, _, _, _): (0, id.persistedValue)
        case .proposal(let id, _): (1, id.persistedValue)
        }
    }
}
