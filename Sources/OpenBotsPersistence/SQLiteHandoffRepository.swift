import Foundation
import OpenBotsDomain

extension SQLiteStore: HandoffRepository {
    /// The schema caps these columns in bytes. `DomainText` caps graphemes, and
    /// a grapheme is not a byte, so the repository refuses an oversized value
    /// with a domain error instead of letting a CHECK constraint fire.
    static let handoffBriefByteLimit = 262_144
    static let handoffResultSummaryByteLimit = 65_536
    static let handoffRecoveryByteLimit = 16_384

    public func insert(_ record: HandoffRecord) async throws {
        let brief = try encodeHandoffJSON(record.brief)
        try Self.requireHandoffBytes(brief, field: "handoff brief", limit: Self.handoffBriefByteLimit)
        guard record.briefMessageID == nil, record.replyMessageID == nil, record.runID == nil else {
            throw DomainValidationError.invalid(field: "handoff insertion",
                reason: "a new handoff has no brief message, reply or run")
        }
        return try transaction {
            guard record.state == .staged else {
                throw DomainValidationError.invalid(field: "handoff insertion", reason: "a new handoff starts staged")
            }
            guard (1...HandoffRecord.maximumChainHops).contains(record.hopCount) else {
                throw DomainValidationError.invalid(field: "handoff chain", reason: "the hop limit was reached")
            }
            if let original = record.originalUserMessageID {
                guard try query(sql: "SELECT 1 FROM messages WHERE id=? AND conversation_id=? AND author_kind='user';",
                    bindings: [.text(original.persistedValue), .text(record.conversationID.persistedValue)]).count == 1 else {
                    throw DomainValidationError.invalid(field: "handoff chain", reason: "the original user message must belong to this conversation")
                }
            }
            let p = record.handoff.provenance
            _ = try execute(sql: """
                INSERT INTO handoffs(id,leg_id,origin_conversation_id,sender_teammate_id,receiver_teammate_id,brief_json,state,
                    source_message_id,brief_message_id,reply_message_id,run_id,result_summary,recovery_json,created_at,last_transition_at,completed_at,returned_at,
                    chain_id,parent_handoff_id,hop_count,original_user_message_id)
                VALUES (?,?,?,?,?,?,?,?,NULL,NULL,NULL,NULL,NULL,?,?,NULL,NULL,?,?,?,?);
                """, bindings: [.text(p.handoffID.persistedValue), .text(p.legID.persistedValue), .text(p.originConversationID.persistedValue),
                    .text(p.senderID.persistedValue), .text(p.receiverID.persistedValue), .text(brief),
                    .text(record.state.rawValue), record.sourceMessageID.map { .text($0.persistedValue) } ?? .null,
                    .real(p.createdAt.timeIntervalSince1970), .real(record.handoff.lastTransitionAt.timeIntervalSince1970),
                    .text(record.chainID.persistedValue), record.parentHandoffID.map { .text($0.persistedValue) } ?? .null,
                    .integer(Int64(record.hopCount)), record.originalUserMessageID.map { .text($0.persistedValue) } ?? .null])
        }
    }

    public func update(_ record: HandoffRecord, expectedState: HandoffState) async throws {
        try transaction { try writeHandoffUpdate(record, expectedState: expectedState) }
    }

    /// One record's move, written inside a transaction the caller holds:
    /// `update`'s own, or Delete's when it ends a deleted bot's open handoffs.
    func writeHandoffUpdate(_ record: HandoffRecord, expectedState: HandoffState) throws {
        if let summary = record.handoff.resultSummary {
            try Self.requireHandoffBytes(summary, field: "handoff result summary", limit: Self.handoffResultSummaryByteLimit)
        }
        let recovery = try record.handoff.recovery.map { try encodeHandoffJSON($0) }
        if let recovery {
            try Self.requireHandoffBytes(recovery, field: "handoff recovery", limit: Self.handoffRecoveryByteLimit)
        }
        let changes = try execute(sql: """
            UPDATE handoffs SET state=?, brief_message_id=?, reply_message_id=?, run_id=?, result_summary=?, recovery_json=?,
                last_transition_at=?, completed_at=?, returned_at=?
            WHERE id=? AND state=?;
            """, bindings: [.text(record.state.rawValue),
                record.briefMessageID.map { .text($0.persistedValue) } ?? .null,
                record.replyMessageID.map { .text($0.persistedValue) } ?? .null,
                record.runID.map { .text($0.persistedValue) } ?? .null,
                record.handoff.resultSummary.map(SQLiteBinding.text) ?? .null,
                recovery.map { SQLiteBinding.text($0) } ?? .null,
                .real(record.handoff.lastTransitionAt.timeIntervalSince1970),
                record.handoff.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.handoff.returnedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(record.id.persistedValue), .text(expectedState.rawValue)])
        guard changes == 1 else {
            throw RepositoryError.optimisticLockFailed(entity: "handoff", id: record.id.persistedValue)
        }
    }

    public func record(id: HandoffID) async throws -> HandoffRecord? {
        try handoffRows(whereClause: "id=?", bindings: [.text(id.persistedValue)]).first
    }

    /// Newest first, capped at the 200 most recent. A conversation's handoff
    /// trail is a bounded read, never an unbounded scan of its whole history.
    public func records(conversationID: ConversationID) async throws -> [HandoffRecord] {
        try handoffRows(whereClause: "origin_conversation_id=?", bindings: [.text(conversationID.persistedValue)],
                        limit: 200)
    }

    func handoffRows(whereClause: String, bindings: [SQLiteBinding], limit: Int? = nil) throws -> [HandoffRecord] {
        // Newest first is a total order: same-instant records fall back to
        // insertion order, never to a random identifier.
        let clause = limit.map { " LIMIT \($0)" } ?? ""
        return try query(sql: "SELECT * FROM handoffs WHERE \(whereClause) ORDER BY created_at DESC, rowid DESC\(clause);",
                         bindings: bindings).map { row in
            guard let state = HandoffState(rawValue: try row.text("state")) else {
                throw SQLiteStoreError.invalidRow(reason: "unknown handoff state")
            }
            let provenance = try HandoffProvenance(
                handoffID: parseID(HandoffID.self, row.text("id")), legID: parseID(HandoffLegID.self, row.text("leg_id")),
                originConversationID: parseID(ConversationID.self, row.text("origin_conversation_id")),
                senderID: parseID(TeammateID.self, row.text("sender_teammate_id")),
                receiverID: parseID(TeammateID.self, row.text("receiver_teammate_id")),
                createdAt: Date(timeIntervalSince1970: row.real("created_at")))
            let handoff = try Handoff(rehydrating: provenance, brief: decodeHandoffJSON(HandoffBrief.self, row.text("brief_json")), state: state,
                recovery: row.optionalText("recovery_json").map { try decodeHandoffJSON(HandoffRecovery.self, $0) },
                lastTransitionAt: Date(timeIntervalSince1970: row.real("last_transition_at")),
                resultSummary: row.optionalText("result_summary"),
                completedAt: row.optionalReal("completed_at").map(Date.init(timeIntervalSince1970:)),
                returnedAt: row.optionalReal("returned_at").map(Date.init(timeIntervalSince1970:)))
            return HandoffRecord(handoff: handoff,
                sourceMessageID: try row.optionalText("source_message_id").map { try parseID(MessageID.self, $0) },
                briefMessageID: try row.optionalText("brief_message_id").map { try parseID(MessageID.self, $0) },
                replyMessageID: try row.optionalText("reply_message_id").map { try parseID(MessageID.self, $0) },
                runID: try row.optionalText("run_id").map { try parseID(RunID.self, $0) },
                chainID: try parseID(HandoffID.self, row.text("chain_id")),
                parentHandoffID: try row.optionalText("parent_handoff_id").map { try parseID(HandoffID.self, $0) },
                hopCount: Int(try row.integer("hop_count")),
                originalUserMessageID: try row.optionalText("original_user_message_id").map { try parseID(MessageID.self, $0) })
        }
    }

    /// The handoff a leg turn must match to be admitted: accepted, this
    /// receiver, this origin. Admission is the only place the state matters.
    func handoffLegParties(legID: HandoffLegID) throws -> (sender: TeammateID, receiver: TeammateID, conversationID: ConversationID)? {
        guard let row = try query(sql: """
            SELECT sender_teammate_id, receiver_teammate_id, origin_conversation_id FROM handoffs h
            WHERE leg_id=? AND state='accepted' AND hop_count BETWEEN 1 AND \(HandoffRecord.maximumChainHops)
              AND NOT EXISTS (SELECT 1 FROM handoffs bad WHERE bad.chain_id=h.chain_id AND bad.state='needsRecovery');
            """,
                                  bindings: [.text(legID.persistedValue)]).first else { return nil }
        return (try parseID(TeammateID.self, row.text("sender_teammate_id")), try parseID(TeammateID.self, row.text("receiver_teammate_id")),
                try parseID(ConversationID.self, row.text("origin_conversation_id")))
    }

    /// A leg that finished with a reply, for the lead's report turn.
    func handoffLegReportParties(legID: HandoffLegID) throws -> (sender: TeammateID, receiver: TeammateID, conversationID: ConversationID)? {
        guard let row = try query(sql: """
            SELECT sender_teammate_id, receiver_teammate_id, origin_conversation_id FROM handoffs h
            WHERE leg_id=? AND state='succeeded' AND reply_message_id IS NOT NULL AND report_run_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM handoffs child WHERE child.parent_handoff_id=h.id)
              AND NOT EXISTS (SELECT 1 FROM handoffs bad WHERE bad.chain_id=h.chain_id AND bad.state='needsRecovery');
            """,
                                  bindings: [.text(legID.persistedValue)]).first else { return nil }
        return (try parseID(TeammateID.self, row.text("sender_teammate_id")), try parseID(TeammateID.self, row.text("receiver_teammate_id")),
                try parseID(ConversationID.self, row.text("origin_conversation_id")))
    }

    /// Who authored a report turn's stored input: the leg's receiver, for any
    /// leg state, for the same reason as `handoffLegSender`.
    func handoffLegReceiver(legID: HandoffLegID) throws -> TeammateID? {
        guard let row = try query(sql: "SELECT receiver_teammate_id FROM handoffs WHERE leg_id=?;",
                                  bindings: [.text(legID.persistedValue)]).first else { return nil }
        return try parseID(TeammateID.self, row.text("receiver_teammate_id"))
    }

    /// Who authored a leg's stored input, for any leg state. Rehydrating a
    /// committed turn must not depend on the leg still being `accepted`: the
    /// receiver moves it to `working` and beyond while the turn is running.
    func handoffLegSender(legID: HandoffLegID) throws -> TeammateID? {
        guard let row = try query(sql: "SELECT sender_teammate_id FROM handoffs WHERE leg_id=?;",
                                  bindings: [.text(legID.persistedValue)]).first else { return nil }
        return try parseID(TeammateID.self, row.text("sender_teammate_id"))
    }
}

private extension SQLiteStore {
    static func requireHandoffBytes(_ value: String, field: String, limit: Int) throws {
        guard value.utf8.count <= limit else {
            throw DomainValidationError.invalid(field: field, reason: "encodes to more than \(limit) bytes")
        }
    }
}

private func encodeHandoffJSON<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decodeHandoffJSON<Value: Decodable>(_ type: Value.Type, _ value: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(value.utf8))
}
