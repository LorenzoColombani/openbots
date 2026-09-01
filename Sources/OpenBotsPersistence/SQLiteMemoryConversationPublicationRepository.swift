import Foundation
import OpenBotsDomain

extension SQLiteStore: MemoryConversationPublicationRepository {
    public func appendMemoryConversationPublication(_ request: MemoryConversationPublicationAppend,
                                                     now: Date) async throws -> MemoryConversationPublicationRecord {
        let proposed = try conversationPublicationRecord(request, now: now)
        let encoded = try conversationPublicationJSON(StoredConversationPublication(proposed))
        return try transaction {
            if let existing = try conversationPublicationRow(id: proposed.publication.receipt.id) {
                let retry = MemoryConversationPublicationRecord(publication: proposed.publication,
                    userMessage: proposed.userMessage, replyMessage: proposed.replyMessage,
                    authority: proposed.authority, userSourceStamps: proposed.userSourceStamps, storedAt: existing.storedAt)
                guard try conversationPublicationJSON(StoredConversationPublication(existing)).utf8.elementsEqual(
                    conversationPublicationJSON(StoredConversationPublication(retry)).utf8) else {
                    throw MemoryConversationPublicationRepositoryError.conflictingIdentity
                }
                // Historical retry, not new publication authority. No row changes.
                return existing
            }
            let validation = request.validation
            guard validation.checkedAt.timeIntervalSince1970.isFinite,
                  proposed.publication.receipt.createdAt <= validation.checkedAt,
                  validation.checkedAt <= now,
                  now.timeIntervalSince(validation.checkedAt) < MemoryConversationPublicationValidation.lifetime else {
                throw MemoryConversationPublicationRepositoryError.invalidValidation
            }
            do { try validateReadContextReceipt(validation.authority) }
            catch { throw MemoryConversationPublicationRepositoryError.authorityChanged }
            try validateConversationPublicationSources(proposed)
            try validateConversationPublicationLineage(proposed)
            let receipt = proposed.publication.receipt
            guard try query(sql: """
                SELECT id FROM memory_conversation_publications
                WHERE local_operation_id=? OR user_message_id IN (?,?) OR reply_message_id IN (?,?) LIMIT 1;
                """, bindings: [.text(receipt.runID.persistedValue), .text(proposed.userMessage.id.persistedValue),
                    .text(receipt.messageID.persistedValue), .text(proposed.userMessage.id.persistedValue),
                    .text(receipt.messageID.persistedValue)]).isEmpty,
                  try query(sql: "SELECT id FROM messages WHERE id IN (?,?) LIMIT 1;",
                    bindings: [.text(proposed.userMessage.id.persistedValue), .text(receipt.messageID.persistedValue)]).isEmpty,
                  try query(sql: "SELECT id FROM work_runs WHERE id=? LIMIT 1;",
                    bindings: [.text(receipt.runID.persistedValue)]).isEmpty else {
                throw MemoryConversationPublicationRepositoryError.conflictingIdentity
            }
            guard try query(sql: "SELECT id FROM work_runs WHERE teammate_id=? AND state NOT IN ('succeeded','failed','interrupted') LIMIT 1;",
                bindings: [.text(receipt.teammateID.persistedValue)]).isEmpty else {
                throw MemoryConversationPublicationRepositoryError.conflictingActiveRun
            }
            try appendMessageGraph(proposed.userMessage, expectedPreviousSequence: request.expectedPreviousSequence)
            try appendMessageGraph(proposed.replyMessage, expectedPreviousSequence: proposed.userMessage.sequence)
            _ = try execute(sql: """
                INSERT INTO memory_conversation_publications
                (id,local_operation_id,conversation_id,teammate_id,user_message_id,reply_message_id,record_json,rendered_digest,created_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, bindings: [.text(receipt.id.uuidString.lowercased()), .text(receipt.runID.persistedValue),
                    .text(proposed.authority.conversationID.persistedValue), .text(receipt.teammateID.persistedValue),
                    .text(proposed.userMessage.id.persistedValue), .text(receipt.messageID.persistedValue), .text(encoded),
                    .text(receipt.renderedTextDigest), .real(proposed.storedAt.timeIntervalSince1970)])
            return proposed
        }
    }

    public func memoryConversationPublication(id: UUID) async throws -> MemoryConversationPublicationRecord? {
        try transaction { try conversationPublicationRow(id: id) }
    }

    public func memoryConversationPublication(messageID: MessageID, conversationID: ConversationID)
        async throws -> MemoryConversationPublicationRecord? {
        try transaction {
            let rows = try query(sql: """
                SELECT id FROM memory_conversation_publications
                WHERE conversation_id=? AND (user_message_id=? OR reply_message_id=?) LIMIT 2;
                """, bindings: [.text(conversationID.persistedValue), .text(messageID.persistedValue), .text(messageID.persistedValue)])
            guard rows.count <= 1 else { throw MemoryConversationPublicationRepositoryError.invalidStoredState }
            guard let row = rows.first, let id = UUID(uuidString: try row.text("id")) else {
                return try controlledPublicationRow(messageID: messageID, conversationID: conversationID)
            }
            return try conversationPublicationRow(id: id)
        }
    }
}

struct StoredConversationPublication: Codable {
    let completeUnits: [String]
    let receipt: MemoryPublicationReceipt
    let omittedUnitCount: Int
    let userMessage: Message
    let replyMessage: Message
    let authority: ReadContextReceipt
    let userSourceStamps: [MemoryPublicationUserMessageEvidence]
    let storedAt: Date
    let providerRunID: RunID?

    init(_ value: MemoryConversationPublicationRecord) {
        completeUnits = value.publication.completeUnits; receipt = value.publication.receipt
        omittedUnitCount = value.publication.omittedUnitCount; userMessage = value.userMessage
        replyMessage = value.replyMessage; authority = value.authority
        userSourceStamps = value.userSourceStamps; storedAt = value.storedAt
        providerRunID = value.providerRunID
    }
    var record: MemoryConversationPublicationRecord {
        .init(publication: .init(completeUnits: completeUnits, receipt: receipt, omittedUnitCount: omittedUnitCount),
              userMessage: userMessage, replyMessage: replyMessage, authority: authority,
              userSourceStamps: userSourceStamps, storedAt: storedAt, providerRunID: providerRunID)
    }
}

extension SQLiteStore {
    /// Historical projection lookup for another database-local transaction.
    /// Callers must independently revalidate the new operation's authority.
    func localMemoryPublicationForAnchor(id: UUID) throws -> MemoryConversationPublicationRecord? {
        try conversationPublicationRow(id: id)
    }

    private func conversationPublicationRecord(_ request: MemoryConversationPublicationAppend,
                                                now: Date) throws -> MemoryConversationPublicationRecord {
        let publication = request.publication, receipt = publication.receipt
        guard now.timeIntervalSince1970.isFinite, receipt.createdAt.timeIntervalSince1970.isFinite,
              receipt.createdAt <= now, request.expectedPreviousSequence >= 0,
              request.expectedPreviousSequence <= Int64.max - 2,
              request.userMessageID != receipt.messageID, request.userPartID != request.replyPartID,
              (1...65_536).contains(request.userText.utf8.count),
              try MemoryConversationPublicationValidation.digest(of: publication) == request.validation.publicationDigest else {
            throw MemoryConversationPublicationRepositoryError.invalidValidation
        }
        let user = try Message(id: request.userMessageID, conversationID: request.validation.authority.conversationID,
            sequence: request.expectedPreviousSequence + 1, author: .user, deliveryState: .completed,
            parts: [MessagePart(id: request.userPartID, ordinal: 0, content: .text(request.userText))],
            createdAt: receipt.createdAt, updatedAt: receipt.createdAt)
        let reply = try Message(id: receipt.messageID, conversationID: request.validation.authority.conversationID,
            sequence: user.sequence + 1, author: .system, deliveryState: .completed,
            parts: [MessagePart(id: request.replyPartID, ordinal: 0, content: .text(publication.text))],
            createdAt: receipt.createdAt, updatedAt: receipt.createdAt)
        let record = MemoryConversationPublicationRecord(publication: publication, userMessage: user, replyMessage: reply,
            authority: request.validation.authority, userSourceStamps: request.validation.userSourceStamps, storedAt: now)
        try validateConversationPublicationShape(record)
        return record
    }

    func validateConversationPublicationShape(_ record: MemoryConversationPublicationRecord) throws {
        let p = record.publication, r = p.receipt, a = record.authority
        guard r.policyVersion == 1, r.teammateID == a.teammateID, r.selectedProjectID == a.selectedProjectID,
              (1...145).contains(p.completeUnits.count), p.completeUnits.allSatisfy({ !$0.isEmpty }),
              (1...MemoryPublicationLimits.renderedBytes).contains(p.text.utf8.count),
              r.renderedTextDigest == MemoryClaimDigests.bytes(Data(p.text.utf8)),
              r.omittedUnitCount == p.omittedUnitCount, (0...MemoryPublicationLimits.units).contains(p.omittedUnitCount),
              r.units.count <= MemoryPublicationLimits.units,
              r.dependencies.count <= MemoryPublicationLimits.dependencyReferences,
              Set(r.dependencies.map(\.reference)).count == r.dependencies.count,
              record.userSourceStamps.count <= 96,
              Set(record.userSourceStamps.map(\.messageID)).count == record.userSourceStamps.count,
              r.createdAt.timeIntervalSince1970.isFinite, record.storedAt.timeIntervalSince1970.isFinite,
              record.storedAt >= r.createdAt,
              record.userMessage.id != r.messageID, record.replyMessage.id == r.messageID,
              record.userMessage.conversationID == a.conversationID, record.replyMessage.conversationID == a.conversationID,
              record.userMessage.sequence > 0, record.userMessage.sequence < Int64.max,
              record.replyMessage.sequence == record.userMessage.sequence + 1,
              record.userMessage.author == .user, record.replyMessage.author == .system,
              record.userMessage.deliveryState == .completed, record.replyMessage.deliveryState == .completed,
              record.userMessage.outputClass == .conversation, record.replyMessage.outputClass == .conversation,
              record.userMessage.parts.count == 1, record.replyMessage.parts.count == 1,
              record.userMessage.parts[0].ordinal == 0, record.replyMessage.parts[0].ordinal == 0,
              record.userMessage.parts[0].id != record.replyMessage.parts[0].id,
              case let .text(userText) = record.userMessage.parts[0].content,
              (1...65_536).contains(userText.utf8.count), record.replyMessage.parts[0].content == .text(p.text),
              Set(r.units.flatMap(\.references)).count == r.units.flatMap(\.references).count,
              r.units.allSatisfy({ $0.references.count <= MemoryPublicationLimits.referencesPerUnit }),
              r.units.flatMap(\.references).allSatisfy({ ref in r.dependencies.contains { $0.reference == ref } }),
              Set(a.claimReferences ?? []) == Set(r.dependencies.map(\.reference)),
              (try? a.qualifying(with: r.dependencies.map(\.reference))) != nil,
              r.dependencies.isEmpty || a.qualificationVersion == 1 else {
            throw MemoryConversationPublicationRepositoryError.invalidRequest
        }
        if let runID = record.providerRunID {
            guard runID == r.runID, r.intent == .reply,
                  record.userMessage.createdAt == record.replyMessage.createdAt,
                  record.userMessage.createdAt <= r.createdAt,
                  record.userMessage.updatedAt == record.storedAt, record.replyMessage.updatedAt == record.storedAt else {
                throw MemoryConversationPublicationRepositoryError.invalidRequest
            }
        } else {
            guard record.userMessage.createdAt == r.createdAt, record.userMessage.updatedAt == r.createdAt,
                  record.replyMessage.createdAt == r.createdAt, record.replyMessage.updatedAt == r.createdAt else {
                throw MemoryConversationPublicationRepositoryError.invalidRequest
            }
        }
        if let limitation = r.units.compactMap({ $0.kind.explanationLimitation }).first {
            guard r.intent == .explanation, r.units.count == 1,
                  r.units[0].references.isEmpty, r.dependencies.isEmpty,
                  a.messages.isEmpty, a.memoryDocuments.isEmpty, (a.claimReferences ?? []).isEmpty,
                  record.userSourceStamps.isEmpty, r.lineage == .independent,
                  r.omittedUnitCount == 0, p.completeUnits == [limitation.text] else {
                throw MemoryConversationPublicationRepositoryError.invalidRequest
            }
        }
        for dependency in r.dependencies {
            guard dependency.decision.dependency == dependency.reference, dependency.decision.disposition != .deny,
                  dependency.sourceStamps.count <= 16, dependency.evidenceStamps.count <= 16,
                  a.memoryDocuments.contains(where: {
                    $0.documentID == dependency.reference.documentID && $0.revision == dependency.reference.documentRevision
                        && $0.contentDigest == dependency.reference.contentDigest && $0.scope == dependency.scope
                  }) else { throw MemoryConversationPublicationRepositoryError.invalidRequest }
            switch dependency.scope {
            case .user: throw MemoryConversationPublicationRepositoryError.authorityChanged
            case .teammate(let id):
                guard id == a.teammateID else { throw MemoryConversationPublicationRepositoryError.authorityChanged }
            case .project(let id):
                guard id == a.selectedProjectID, a.projectMembershipJoinedAt != nil else {
                    throw MemoryConversationPublicationRepositoryError.authorityChanged
                }
            }
        }
    }

    func validateConversationPublicationSources(_ record: MemoryConversationPublicationRecord) throws {
        var userIDs: Set<MessageID> = []
        for dependency in record.publication.receipt.dependencies {
            let sources = dependency.sourceStamps + dependency.evidenceStamps.map(\.source)
            for source in sources {
                guard source.scope == dependency.scope else { throw MemoryConversationPublicationRepositoryError.invalidSource }
                switch source.kind {
                case .userMessage:
                    guard let uuid = UUID(uuidString: source.sourceID) else { throw MemoryConversationPublicationRepositoryError.invalidSource }
                    let id = MessageID(uuid); userIDs.insert(id)
                    guard let stamp = record.userSourceStamps.first(where: { $0.messageID == id }),
                          stamp.contentDigest == source.contentDigest, stamp.updatedAt.timeIntervalSince1970.isFinite else {
                        throw MemoryConversationPublicationRepositoryError.invalidSource
                    }
                    let rows = try query(sql: """
                        SELECT m.sequence,m.created_at,m.updated_at,
                            CASE WHEN length(CAST(p.text_value AS BLOB)) BETWEEN 1 AND 65536 THEN p.text_value END AS body
                        FROM messages m JOIN message_parts p ON p.message_id=m.id AND p.ordinal=0
                        WHERE m.id=? AND m.conversation_id=? AND m.author_kind='user' AND m.author_teammate_id IS NULL
                            AND m.output_class='conversation' AND p.kind='text' AND p.referenced_id IS NULL
                            AND NOT EXISTS(SELECT 1 FROM message_parts x WHERE x.message_id=m.id AND x.ordinal!=0) LIMIT 2;
                        """, bindings: [.text(id.persistedValue), .text(record.authority.conversationID.persistedValue)])
                    guard rows.count == 1, let row = rows.first, let body = try row.optionalText("body"),
                          try row.integer("sequence") > 0, try row.integer("sequence") < record.userMessage.sequence,
                          try source.sourceRevision == UInt64(row.integer("sequence")),
                          try source.observedAt?.timeIntervalSince1970 == row.real("created_at"),
                          try stamp.updatedAt.timeIntervalSince1970 == row.real("updated_at"),
                          MemoryClaimDigests.bytes(Data(body.utf8)) == stamp.contentDigest else {
                        throw MemoryConversationPublicationRepositoryError.invalidSource
                    }
                case .appObservation:
                    // The only registered app predicate in this increment.
                    let id = record.authority.teammateID
                    guard source.sourceID == "teammate.saved-name:" + id.persistedValue,
                          let row = try query(sql: "SELECT display_name,profile_revision,updated_at FROM teammates WHERE id=?;",
                            bindings: [.text(id.persistedValue)]).first else {
                        throw MemoryConversationPublicationRepositoryError.invalidSource
                    }
                    struct NameStamp: Encodable { let id: TeammateID; let name: String; let revision: UInt64; let updatedAt: Date }
                    let revision = try checkedUInt64(row.integer("profile_revision"), field: "profile revision")
                    let updated = Date(timeIntervalSince1970: try row.real("updated_at"))
                    let digest = try MemoryClaimDigests.bytes(MemoryClaimDigests.canonicalData(NameStamp(
                        id: id, name: row.text("display_name"), revision: revision, updatedAt: updated)))
                    guard source.sourceRevision == revision, source.observedAt == updated, source.contentDigest == digest else {
                        throw MemoryConversationPublicationRepositoryError.invalidSource
                    }
                case .modelInference, .modelEcho:
                    // Retained provenance only. Neither may be evidence authority.
                    guard !dependency.evidenceStamps.contains(where: { $0.source == source }) else {
                        throw MemoryConversationPublicationRepositoryError.invalidSource
                    }
                case .sourceDocument, .unknown:
                    throw MemoryConversationPublicationRepositoryError.invalidSource
                }
            }
        }
        guard userIDs == Set(record.userSourceStamps.map(\.messageID)) else {
            throw MemoryConversationPublicationRepositoryError.invalidSource
        }
    }

    func validateConversationPublicationLineage(_ record: MemoryConversationPublicationRecord) throws {
        let current = record.publication.receipt
        var visited: Set<UUID> = [], visiting: Set<UUID> = []
        func walk(_ lineage: MemoryPublicationLineage) throws {
            switch lineage {
            case .independent: return
            case .unknown: throw MemoryConversationPublicationRepositoryError.invalidLineage
            case .derived(let ids):
                guard !ids.isEmpty, ids.count <= MemoryPublicationLimits.ancestorReceipts, Set(ids).count == ids.count else {
                    throw MemoryConversationPublicationRepositoryError.invalidLineage
                }
                for id in ids {
                    guard id != current.id, !visiting.contains(id) else { throw MemoryConversationPublicationRepositoryError.invalidLineage }
                    if visited.contains(id) { continue }
                    guard visited.count + visiting.count < MemoryPublicationLimits.ancestorReceipts,
                          let previous = try conversationPublicationRow(id: id),
                          previous.authority.conversationID == record.authority.conversationID,
                          previous.publication.receipt.teammateID == current.teammateID,
                          previous.publication.receipt.selectedProjectID == current.selectedProjectID,
                          previous.replyMessage.sequence < record.userMessage.sequence,
                          previous.publication.receipt.createdAt <= current.createdAt,
                          previous.publication.receipt.intent != .historyOverview || current.intent == .historyOverview,
                          previous.publication.receipt.dependencies.allSatisfy({ dependency in
                            current.dependencies.contains { $0.reference == dependency.reference
                                && $0.scope == dependency.scope && $0.sourceStamps == dependency.sourceStamps
                                && $0.evidenceStamps == dependency.evidenceStamps }
                          }) else { throw MemoryConversationPublicationRepositoryError.invalidLineage }
                    visiting.insert(id)
                    try walk(previous.publication.receipt.lineage)
                    visiting.remove(id); visited.insert(id)
                }
            }
        }
        try walk(current.lineage)
    }

    func conversationPublicationRow(id: UUID) throws -> MemoryConversationPublicationRecord? {
        guard let row = try query(sql: """
            SELECT id,local_operation_id,conversation_id,teammate_id,user_message_id,reply_message_id,rendered_digest,created_at,
                CASE WHEN length(CAST(record_json AS BLOB)) BETWEEN 1 AND 131072 THEN record_json END AS record_json
            FROM memory_conversation_publications WHERE id=?;
            """, bindings: [.text(id.uuidString.lowercased())]).first else {
            return try controlledPublicationRow(publicationID: id)
        }
        do {
            guard let json = try row.optionalText("record_json") else { throw MemoryConversationPublicationRepositoryError.invalidStoredState }
            let stored = try JSONDecoder().decode(StoredConversationPublication.self, from: Data(json.utf8))
            let record = stored.record, receipt = stored.receipt
            guard record.providerRunID == nil else { throw MemoryConversationPublicationRepositoryError.invalidStoredState }
            try validateConversationPublicationShape(record)
            guard try conversationPublicationJSON(stored).utf8.elementsEqual(json.utf8),
                  receipt.id == id, try row.text("id") == id.uuidString.lowercased(),
                  try row.text("local_operation_id") == receipt.runID.persistedValue,
                  try row.text("conversation_id") == record.authority.conversationID.persistedValue,
                  try row.text("teammate_id") == receipt.teammateID.persistedValue,
                  try row.text("user_message_id") == record.userMessage.id.persistedValue,
                  try row.text("reply_message_id") == record.replyMessage.id.persistedValue,
                  try row.text("rendered_digest") == receipt.renderedTextDigest,
                  try row.real("created_at") == record.storedAt.timeIntervalSince1970,
                  try conversationPublicationMessageMatches(record.userMessage),
                  try conversationPublicationMessageMatches(record.replyMessage) else {
                throw MemoryConversationPublicationRepositoryError.invalidStoredState
            }
            return record
        } catch { throw MemoryConversationPublicationRepositoryError.invalidStoredState }
    }

    func conversationPublicationMessageMatches(_ message: Message) throws -> Bool {
        guard let row = try query(sql: "SELECT * FROM messages WHERE id=?;", bindings: [.text(message.id.persistedValue)]).first,
              try row.text("conversation_id") == message.conversationID.persistedValue,
              try row.integer("sequence") == message.sequence,
              try row.text("author_kind") == (message.author == .user ? "user" : "system"),
              try row.optionalText("author_teammate_id") == nil,
              try row.text("output_class") == "conversation", try row.text("delivery_state") == "completed",
              try row.real("created_at") == message.createdAt.timeIntervalSince1970,
              try row.real("updated_at") == message.updatedAt.timeIntervalSince1970 else { return false }
        let parts = try query(sql: """
            SELECT id,ordinal,kind,referenced_id,
                CASE WHEN length(CAST(text_value AS BLOB)) BETWEEN 1 AND 65536 THEN text_value END AS body
            FROM message_parts WHERE message_id=? ORDER BY ordinal LIMIT 2;
            """, bindings: [.text(message.id.persistedValue)])
        guard parts.count == 1, let part = parts.first,
              try part.text("id") == message.parts[0].id.persistedValue, try part.integer("ordinal") == 0,
              try part.text("kind") == "text", try part.optionalText("referenced_id") == nil,
              case let .text(text) = message.parts[0].content, let body = try part.optionalText("body"),
              body.utf8.elementsEqual(text.utf8) else { return false }
        return true
    }

    func conversationPublicationJSON<T: Encodable>(_ value: T) throws -> String {
        let bytes = try MemoryClaimDigests.canonicalData(value)
        guard (1...131_072).contains(bytes.count) else { throw MemoryConversationPublicationRepositoryError.invalidRequest }
        return String(decoding: bytes, as: UTF8.self)
    }
}
