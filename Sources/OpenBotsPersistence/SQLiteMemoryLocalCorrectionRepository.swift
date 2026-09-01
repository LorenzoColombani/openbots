import Foundation
import OpenBotsDomain

extension SQLiteStore: MemoryLocalCorrectionRepository {
    public func recoverableMemoryLocalCorrections(limit: Int) async throws -> MemoryLocalCorrectionRecoveryPage {
        guard (1...16).contains(limit) else { throw MemoryLocalCorrectionError.invalidRequest }
        return try transaction {
            try Task.checkCancellation()
            // Only this finite metadata page is enumerated. Each selected exact
            // record then passes the same strict bounded decoder as direct lookup.
            let rows = try query(sql: """
                SELECT user_message_id,state,revision FROM memory_local_corrections
                WHERE state IN ('admitted','committedUnacknowledged')
                ORDER BY created_at,user_message_id LIMIT ?;
                """, bindings: [.integer(Int64(limit + 1))])
            let markers = try rows.prefix(limit).map { row in
                let id = try parseID(MessageID.self, row.text("user_message_id"))
                guard let record = try localCorrectionRow(id),
                      record.state == .admitted || record.state == .committedUnacknowledged,
                      record.state.rawValue == (try row.text("state")),
                      record.revision == (try row.integer("revision")) else {
                    throw MemoryLocalCorrectionError.invalidState
                }
                return MemoryLocalCorrectionRecoveryMarker(record: record)
            }
            return MemoryLocalCorrectionRecoveryPage(markers: markers, hasMore: rows.count > limit)
        }
    }

    public func memoryLocalCorrection(userMessageID: MessageID) async throws -> MemoryLocalCorrectionRecord? {
        try localCorrectionRow(userMessageID)
    }

    public func admitMemoryLocalCorrection(_ request: MemoryLocalCorrectionRequest,
                                           text: String) async throws -> MemoryLocalCorrectionRecord {
        _ = try request.validated()
        guard !text.isEmpty, text.utf8.count <= 8_192, !text.contains("\0"),
              MemoryClaimDigests.bytes(Data(text.utf8)) == request.commandDigest else {
            throw MemoryLocalCorrectionError.invalidRequest
        }
        let encoded = try MemoryClaimDigests.canonicalData(request)
        guard encoded.count <= 65_536 else { throw MemoryLocalCorrectionError.invalidRequest }
        return try transaction {
            try Task.checkCancellation()
            if let prior = try localCorrectionRow(request.userMessageID) {
                guard try MemoryClaimDigests.canonicalData(prior.request) == encoded,
                      case let .text(original) = prior.userMessage.parts[0].content,
                      original.utf8.elementsEqual(text.utf8) else { throw MemoryLocalCorrectionError.conflictingCommand }
                return prior
            }
            try localCorrectionAuthority(request)
            if let anchor = request.targetAnchor {
                try validateMemoryLocalCorrectionAnchor(anchor, request: request)
            } else if request.inventoryComplete && !request.captureNewClaim { try localInventory(request, replacing: nil) }
            let user = try Message(id: request.userMessageID, conversationID: request.authority.conversationID,
                sequence: request.expectedPreviousSequence + 1, author: .user, deliveryState: .completed,
                parts: [MessagePart(id: request.userPartID, ordinal: 0, content: .text(text))],
                createdAt: request.createdAt, updatedAt: request.createdAt)
            try appendMessageGraph(user, expectedPreviousSequence: request.expectedPreviousSequence)
            _ = try execute(sql: """
                INSERT INTO memory_local_corrections(user_message_id,operation_id,conversation_id,
                    acknowledgement_message_id,request_json,command_digest,state,revision,created_at,updated_at)
                VALUES (?,?,?,?,?,?,'admitted',1,?,?);
                """, bindings: [.text(request.userMessageID.persistedValue), .text(request.operationID.uuidString.lowercased()),
                    .text(request.authority.conversationID.persistedValue), .text(request.acknowledgementMessageID.persistedValue),
                    .text(String(decoding: encoded, as: UTF8.self)), .text(request.commandDigest),
                    .real(request.createdAt.timeIntervalSince1970), .real(request.createdAt.timeIntervalSince1970)])
            guard let saved = try localCorrectionRow(request.userMessageID) else { throw MemoryLocalCorrectionError.invalidState }
            return saved
        }
    }

    public func acknowledgeMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                                  now: Date) async throws -> MemoryLocalCorrectionRecord {
        try transaction {
            try Task.checkCancellation()
            guard let record = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.notFound }
            if record.state == .acknowledged { return record }
            guard record.state == .admitted || record.state == .committedUnacknowledged,
                  record.revision == expectedRevision,
                  now.timeIntervalSince1970.isFinite, now >= record.updatedAt,
                  record.request.inventoryComplete || record.request.captureNewClaim || record.request.targetAnchor != nil else { throw MemoryLocalCorrectionError.invalidState }
            let request = record.request
            try localCorrectionAuthority(request)
            try localLatestUser(record)
            guard let row = try query(sql: "SELECT state,intent_json FROM memory_publication_intents WHERE id=?;",
                bindings: [.text(request.operationID.uuidString.lowercased())]).first,
                  try row.text("state") == "committed" else { throw MemoryLocalCorrectionError.publicationNotCommitted }
            let bytes = Data(try row.text("intent_json").utf8)
            guard bytes.count <= 131_072 else { throw MemoryLocalCorrectionError.invalidState }
            let intent = try JSONDecoder().decode(MemoryPublicationIntent.self, from: bytes).validated()
            guard intent.id == request.operationID, intent.document.id == request.documentID,
                  intent.actor == .user(messageID: userMessageID), intent.authority == request.authority,
                  intent.userMessageEvidence.contains(where: {
                      $0.messageID == userMessageID && $0.contentDigest == request.commandDigest
                          && $0.updatedAt == record.userMessage.updatedAt
                  }), try !memoryPublicationBlocksUseRow(documentID: intent.document.id),
                  try !query(sql: "SELECT 1 AS found FROM memory_documents WHERE id=? AND revision=? AND content_digest=?;",
                    bindings: [.text(intent.document.id.persistedValue), .integer(Int64(intent.document.revision)),
                               .text(intent.document.contentDigest)]).isEmpty else {
                throw MemoryLocalCorrectionError.publicationNotCommitted
            }
            if let anchor = request.targetAnchor {
                try validateMemoryLocalCorrectionAnchor(anchor, request: request, intent: intent, afterCommit: true)
            } else if !request.captureNewClaim { try localInventory(request, replacing: intent) }
            let acknowledgement = try Message(id: request.acknowledgementMessageID,
                conversationID: request.authority.conversationID, sequence: record.userMessage.sequence + 1,
                author: .system, deliveryState: .completed,
                parts: [MessagePart(id: request.acknowledgementPartID, ordinal: 0,
                                    content: .text(MemoryLocalCorrectionAcknowledgement.text))], createdAt: now, updatedAt: now)
            try appendMessageGraph(acknowledgement, expectedPreviousSequence: record.userMessage.sequence)
            try Task.checkCancellation()
            let changed = try execute(sql: """
                UPDATE memory_local_corrections SET state='acknowledged',revision=revision+1,updated_at=?
                WHERE user_message_id=? AND state IN ('admitted','committedUnacknowledged') AND revision=?;
                """, bindings: [.real(now.timeIntervalSince1970), .text(userMessageID.persistedValue), .integer(expectedRevision)])
            guard changed == 1, let result = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.invalidState }
            return result
        }
    }

    public func clarifyMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                              kind: MemoryLocalCorrectionClarificationKind, now: Date) async throws -> MemoryLocalCorrectionRecord {
        try transaction {
            try Task.checkCancellation()
            guard let record = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.notFound }
            // The exact stored question is a historical retry, not a new claim
            // that current memory or conversation authority remains unchanged.
            if record.clarification != nil { return record }
            guard record.state == .admitted, record.revision == expectedRevision,
                  record.revision < Int64.max, now.timeIntervalSince1970.isFinite,
                  now >= record.updatedAt else { throw MemoryLocalCorrectionError.invalidState }
            let request = record.request
            try localCorrectionAuthority(request)
            try localLatestUser(record)
            // Even an aborted/pending intent makes "nothing changed" unsuitable.
            // Never turn an uncertain or committed mutation into clarification.
            guard try query(sql: "SELECT id FROM memory_publication_intents WHERE id=? OR document_id=? LIMIT 1;",
                bindings: [.text(request.operationID.uuidString.lowercased()), .text(request.documentID.persistedValue)]).isEmpty else {
                throw MemoryLocalCorrectionError.invalidState
            }
            let question = try Message(id: request.acknowledgementMessageID,
                conversationID: request.authority.conversationID, sequence: record.userMessage.sequence + 1,
                author: .system, deliveryState: .completed,
                parts: [MessagePart(id: request.acknowledgementPartID, ordinal: 0, content: .text(kind.text))],
                createdAt: now, updatedAt: now)
            try appendMessageGraph(question, expectedPreviousSequence: record.userMessage.sequence)
            _ = try execute(sql: """
                INSERT INTO memory_local_correction_clarifications
                    (user_message_id,operation_id,reply_message_id,reply_part_id,kind,created_at)
                VALUES (?,?,?,?,?,?);
                """, bindings: [.text(userMessageID.persistedValue), .text(request.operationID.uuidString.lowercased()),
                    .text(question.id.persistedValue), .text(request.acknowledgementPartID.persistedValue),
                    .text(kind.rawValue), .real(now.timeIntervalSince1970)])
            try Task.checkCancellation()
            let changed = try execute(sql: """
                UPDATE memory_local_corrections SET state='failed',failure_code='contextUnavailable',
                    revision=revision+1,updated_at=? WHERE user_message_id=? AND state='admitted' AND revision=?;
                """, bindings: [.real(now.timeIntervalSince1970), .text(userMessageID.persistedValue), .integer(expectedRevision)])
            guard changed == 1, let result = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.invalidState }
            return result
        }
    }

    public func failMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                          failure: MemoryLocalCorrectionFailure, now: Date) async throws -> MemoryLocalCorrectionRecord {
        try transaction {
            guard let record = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.notFound }
            if record.state == .acknowledged || record.state == .failed { return record }
            guard record.revision == expectedRevision, now.timeIntervalSince1970.isFinite,
                  now >= record.updatedAt else { throw MemoryLocalCorrectionError.invalidState }
            let committed = try !query(sql: "SELECT 1 AS found FROM memory_publication_intents WHERE id=? AND state='committed';",
                bindings: [.text(record.request.operationID.uuidString.lowercased())]).isEmpty
            if committed {
                _ = try execute(sql: """
                    UPDATE memory_local_corrections SET state='committedUnacknowledged',failure_code=NULL,
                        revision=revision+1,updated_at=? WHERE user_message_id=? AND revision=?;
                    """, bindings: [.real(now.timeIntervalSince1970), .text(userMessageID.persistedValue), .integer(expectedRevision)])
                guard let result = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.invalidState }
                return result
            }
            guard record.state == .admitted else { throw MemoryLocalCorrectionError.invalidState }
            _ = try execute(sql: """
                UPDATE memory_local_corrections SET state='failed',failure_code=?,revision=revision+1,updated_at=?
                WHERE user_message_id=? AND state='admitted' AND revision=?;
                """, bindings: [.text(failure.rawValue), .real(now.timeIntervalSince1970),
                                 .text(userMessageID.persistedValue), .integer(expectedRevision)])
            if failure == .cancelled {
                // Preserve files and the aborted intent. Recovery cannot turn a
                // cancelled local action into a later successful update.
                _ = try execute(sql: """
                    UPDATE memory_publication_intents SET state='aborted',revision=revision+1,updated_at=MAX(updated_at,?)
                    WHERE id=? AND state='pending';
                    """, bindings: [.real(now.timeIntervalSince1970), .text(record.request.operationID.uuidString.lowercased())])
            }
            guard let result = try localCorrectionRow(userMessageID) else { throw MemoryLocalCorrectionError.invalidState }
            return result
        }
    }
}

extension SQLiteStore {
    /// Called inside publication prepare/commit's transaction. Non-local
    /// publications have no marker; local proposals cannot bypass their frozen
    /// complete inventory, actor, cancellation or no-active-run conditions.
    func validateMemoryLocalOperationForPublication(intent: MemoryPublicationIntent) throws {
        guard let row = try query(sql: "SELECT user_message_id FROM memory_local_corrections WHERE operation_id=?;",
            bindings: [.text(intent.id.uuidString.lowercased())]).first else { return }
        let id = try parseID(MessageID.self, row.text("user_message_id"))
        guard let record = try localCorrectionRow(id), record.state == .admitted,
              record.request.inventoryComplete || record.request.captureNewClaim || record.request.targetAnchor != nil,
              intent.document.id == record.request.documentID,
              intent.actor == .user(messageID: id), intent.authority == record.request.authority else {
            throw MemoryLocalCorrectionError.invalidState
        }
        try localCorrectionAuthority(record.request)
        try localLatestUser(record)
        if let anchor = record.request.targetAnchor {
            try validateMemoryLocalCorrectionAnchor(anchor, request: record.request, intent: intent)
        } else if !record.request.captureNewClaim { try localInventory(record.request, replacing: nil) }
    }

    private func localCorrectionAuthority(_ request: MemoryLocalCorrectionRequest) throws {
        let base = try request.authority.selecting(messageIDs: [], memoryDocumentIDs: [])
        try validateReadContextReceipt(base)
        let direct = try query(sql: """
            SELECT id FROM conversations WHERE id=? AND kind='direct' AND subject_id=? AND lifecycle='active';
            """, bindings: [.text(base.conversationID.persistedValue), .text(base.teammateID.persistedValue)])
        guard direct.count == 1 else { throw MemoryLocalCorrectionError.invalidRequest }
        guard try query(sql: "SELECT id FROM work_runs WHERE teammate_id=? AND state NOT IN ('succeeded','failed','interrupted') LIMIT 1;",
            bindings: [.text(base.teammateID.persistedValue)]).isEmpty else { throw MemoryLocalCorrectionError.busy }
    }

    private func localInventory(_ request: MemoryLocalCorrectionRequest, replacing intent: MemoryPublicationIntent?) throws {
        var expected = Set(request.authority.memoryDocuments.map(\.documentID))
        if let intent {
            if let predecessor = intent.expectedPredecessor {
                guard expected.remove(predecessor.id) != nil else { throw MemoryLocalCorrectionError.inventoryChanged }
            }
            expected.insert(intent.document.id)
        }
        let rows = try query(sql: """
            SELECT d.id FROM memory_documents d
            WHERE ((d.scope_kind='teammate' AND d.scope_id=?) OR (d.scope_kind='project' AND d.scope_id=?))
              AND NOT EXISTS(SELECT 1 FROM memory_documents next WHERE next.supersedes_id=d.id)
            ORDER BY d.id LIMIT 5;
            """, bindings: [.text(request.authority.teammateID.persistedValue),
                             request.authority.selectedProjectID.map { .text($0.persistedValue) } ?? .null])
        let actual = try Set(rows.map { try parseID(MemoryDocumentID.self, $0.text("id")) })
        guard rows.count <= 4, actual == expected else { throw MemoryLocalCorrectionError.inventoryChanged }
    }

    private func localLatestUser(_ record: MemoryLocalCorrectionRecord) throws {
        let latest = try query(sql: "SELECT id,sequence FROM messages WHERE conversation_id=? ORDER BY sequence DESC LIMIT 1;",
            bindings: [.text(record.request.authority.conversationID.persistedValue)]).first
        guard try latest?.text("id") == record.request.userMessageID.persistedValue,
              try latest?.integer("sequence") == record.request.expectedPreviousSequence + 1,
              record.userMessage.author == .user, record.userMessage.sequence == record.request.expectedPreviousSequence + 1,
              case let .text(text) = record.userMessage.parts[0].content,
              MemoryClaimDigests.bytes(Data(text.utf8)) == record.request.commandDigest else {
            throw MemoryLocalCorrectionError.conflictingCommand
        }
    }

    private func localCorrectionRow(_ id: MessageID) throws -> MemoryLocalCorrectionRecord? {
        guard let row = try query(sql: "SELECT * FROM memory_local_corrections WHERE user_message_id=?;",
            bindings: [.text(id.persistedValue)]).first else { return nil }
        let bytes = Data(try row.text("request_json").utf8)
        guard bytes.count <= 65_536 else { throw MemoryLocalCorrectionError.invalidState }
        let request = try JSONDecoder().decode(MemoryLocalCorrectionRequest.self, from: bytes).validated()
        guard request.userMessageID == id, try row.text("operation_id") == request.operationID.uuidString.lowercased(),
              try row.text("conversation_id") == request.authority.conversationID.persistedValue,
              try row.text("acknowledgement_message_id") == request.acknowledgementMessageID.persistedValue,
              try row.text("command_digest") == request.commandDigest,
              let state = MemoryLocalCorrectionState(rawValue: try row.text("state")),
              try row.integer("revision") > 0 else { throw MemoryLocalCorrectionError.invalidState }
        let failure = try row.optionalText("failure_code").flatMap(MemoryLocalCorrectionFailure.init(rawValue:))
        guard (state == .failed) == (failure != nil) else { throw MemoryLocalCorrectionError.invalidState }
        let user = try localSingleMessage(request.userMessageID, conversationID: request.authority.conversationID,
                                          author: .user, partID: request.userPartID)
        guard case let .text(text) = user.parts[0].content,
              MemoryClaimDigests.bytes(Data(text.utf8)) == request.commandDigest,
              user.createdAt == request.createdAt, user.sequence == request.expectedPreviousSequence + 1 else {
            throw MemoryLocalCorrectionError.invalidState
        }
        let acknowledgement: Message?
        if state == .acknowledged {
            let value = try localSingleMessage(request.acknowledgementMessageID,
                conversationID: request.authority.conversationID, author: .system, partID: request.acknowledgementPartID)
            guard value.sequence == user.sequence + 1, value.deliveryState == .completed,
                  case let .text(text) = value.parts[0].content,
                  text.utf8.elementsEqual(MemoryLocalCorrectionAcknowledgement.text.utf8) else {
                throw MemoryLocalCorrectionError.invalidState
            }
            acknowledgement = value
        } else { acknowledgement = nil }
        let clarification: Message?
        if let question = try query(sql: "SELECT * FROM memory_local_correction_clarifications WHERE user_message_id=?;",
            bindings: [.text(id.persistedValue)]).first {
            guard state == .failed, failure == .contextUnavailable, acknowledgement == nil,
                  try row.integer("revision") >= 2,
                  try question.text("operation_id") == request.operationID.uuidString.lowercased(),
                  try question.text("reply_message_id") == request.acknowledgementMessageID.persistedValue,
                  try question.text("reply_part_id") == request.acknowledgementPartID.persistedValue,
                  let kind = MemoryLocalCorrectionClarificationKind(rawValue: try question.text("kind")),
                  try question.real("created_at").isFinite,
                  try question.real("created_at") >= request.createdAt.timeIntervalSince1970,
                  try question.real("created_at") == row.real("updated_at"),
                  try query(sql: "SELECT id FROM memory_publication_intents WHERE id=? OR document_id=? LIMIT 1;",
                    bindings: [.text(request.operationID.uuidString.lowercased()), .text(request.documentID.persistedValue)]).isEmpty else {
                throw MemoryLocalCorrectionError.invalidState
            }
            let value = try localSingleMessage(request.acknowledgementMessageID,
                conversationID: request.authority.conversationID, author: .system, partID: request.acknowledgementPartID)
            guard value.sequence == user.sequence + 1, value.deliveryState == .completed,
                  value.createdAt.timeIntervalSince1970 == (try question.real("created_at")),
                  value.updatedAt.timeIntervalSince1970 == (try question.real("created_at")),
                  case let .text(text) = value.parts[0].content, text.utf8.elementsEqual(kind.text.utf8) else {
                throw MemoryLocalCorrectionError.invalidState
            }
            clarification = value
        } else { clarification = nil }
        return MemoryLocalCorrectionRecord(request: request, state: state, revision: try row.integer("revision"),
            failure: failure, userMessage: user, acknowledgement: acknowledgement,
            updatedAt: Date(timeIntervalSince1970: try row.real("updated_at")), clarification: clarification)
    }

    private func localSingleMessage(_ id: MessageID, conversationID: ConversationID,
                                     author: MessageAuthor, partID: MessagePartID) throws -> Message {
        guard let row = try query(sql: """
            SELECT m.*,p.id AS part_id,p.text_value FROM messages m JOIN message_parts p ON p.message_id=m.id AND p.ordinal=0
            WHERE m.id=? AND p.kind='text' AND p.referenced_id IS NULL
              AND length(CAST(p.text_value AS BLOB)) BETWEEN 1 AND 8192
              AND NOT EXISTS(SELECT 1 FROM message_parts other WHERE other.message_id=m.id AND other.ordinal!=0);
            """, bindings: [.text(id.persistedValue)]).first,
              try row.text("conversation_id") == conversationID.persistedValue,
              try row.text("author_kind") == (author == .user ? "user" : "system"),
              try row.optionalText("author_teammate_id") == nil, try row.text("output_class") == "conversation",
              try row.text("part_id") == partID.persistedValue,
              let delivery = MessageDeliveryState(rawValue: try row.text("delivery_state")) else {
            throw MemoryLocalCorrectionError.invalidState
        }
        return try Message(id: id, conversationID: conversationID, sequence: row.integer("sequence"), author: author,
            deliveryState: delivery, parts: [MessagePart(id: partID, ordinal: 0, content: .text(row.text("text_value")))],
            createdAt: Date(timeIntervalSince1970: row.real("created_at")), updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
    }
}
