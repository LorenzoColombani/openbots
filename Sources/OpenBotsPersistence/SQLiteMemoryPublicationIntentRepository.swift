import CryptoKit
import Foundation
import OpenBotsDomain

extension SQLiteStore: MemoryPublicationIntentRepository {
    public func prepareMemoryPublication(_ intent: MemoryPublicationIntent) async throws -> MemoryPublicationIntentRecord {
        _ = try intent.validated()
        let encoded = try publicationJSON(intent)
        return try transaction {
            if let existing = try memoryPublicationRow(id: intent.id) {
                guard try publicationJSON(existing.intent) == encoded else { throw MemoryPublicationError.conflictingOperation }
                if existing.state == .pending { try validateMemoryPublicationAdmission(intent) }
                return existing
            }
            try validateMemoryPublicationAdmission(intent)
            let occupied = try query(sql: """
                SELECT id FROM memory_publication_intents
                WHERE document_id=? OR staging_relative_path=? OR final_relative_path=?
                   OR (predecessor_id=? AND state='pending') LIMIT 1;
                """, bindings: [.text(intent.document.id.persistedValue), .text(intent.stagingRelativePath),
                    .text(intent.document.relativePath), intent.expectedPredecessor.map { .text($0.id.persistedValue) } ?? .null])
            guard occupied.isEmpty else { throw MemoryPublicationError.conflictingOperation }
            _ = try execute(sql: """
                INSERT INTO memory_publication_intents
                (id,document_id,predecessor_id,intent_json,staging_relative_path,final_relative_path,
                 content_digest,byte_count,state,revision,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?,?,'pending',1,?,?);
                """, bindings: [.text(intent.id.uuidString.lowercased()), .text(intent.document.id.persistedValue),
                    intent.expectedPredecessor.map { .text($0.id.persistedValue) } ?? .null,
                    .text(String(decoding: encoded, as: UTF8.self)), .text(intent.stagingRelativePath),
                    .text(intent.document.relativePath), .text(intent.document.contentDigest), .integer(Int64(intent.byteCount)),
                    .real(intent.createdAt.timeIntervalSince1970), .real(intent.createdAt.timeIntervalSince1970)])
            return MemoryPublicationIntentRecord(intent: intent, state: .pending, revision: 1, updatedAt: intent.createdAt)
        }
    }

    public func memoryPublication(id: UUID) async throws -> MemoryPublicationIntentRecord? {
        try memoryPublicationRow(id: id)
    }

    public func committedMemoryPublication(documentID: MemoryDocumentID) async throws -> MemoryPublicationIntentRecord? {
        guard let row = try query(sql: "SELECT id FROM memory_publication_intents WHERE document_id=? AND state='committed';",
            bindings: [.text(documentID.persistedValue)]).first else { return nil }
        guard let id = try UUID(uuidString: row.text("id")),
              let record = try memoryPublicationRow(id: id), record.intent.document.id == documentID,
              record.state == .committed else { throw MemoryPublicationError.invalidStoredState }
        return record
    }

    public func pendingMemoryPublications(limit: Int) async throws -> [MemoryPublicationIntentRecord] {
        guard (1...100).contains(limit) else { throw MemoryPublicationError.invalidLimit }
        return try query(sql: "SELECT * FROM memory_publication_intents WHERE state='pending' ORDER BY created_at,id LIMIT ?;",
            bindings: [.integer(Int64(limit))]).map(decodeMemoryPublication)
    }

    public func commitMemoryPublication(id: UUID, expectedRevision: Int64, validation: MemoryPublicationValidation,
                                        now: Date) async throws -> MemoryPublicationIntentRecord {
        try transaction {
            guard let record = try memoryPublicationRow(id: id) else { throw MemoryPublicationError.notFound }
            let intent = record.intent
            guard validation.authority == intent.authority, validation.evidenceDigest == intent.evidenceDigest,
                  validation.policyDigest == intent.policyDigest, validation.contentDigest == intent.document.contentDigest,
                  validation.byteCount == intent.byteCount else { throw MemoryPublicationError.invalidEvidence }
            if record.state == .committed {
                // Exact retries stay idempotent even when a later successor now exists.
                guard let document = try publicationDocument(id: intent.document.id),
                      try publicationJSON(document) == publicationJSON(intent.document) else {
                    throw MemoryPublicationError.invalidStoredState
                }
                return record
            }
            guard record.state == .pending, record.revision == expectedRevision,
                  now.timeIntervalSince1970.isFinite, now >= record.updatedAt else {
                throw MemoryPublicationError.invalidTransition
            }
            try validateMemoryPublicationAdmission(intent)
            try insertPublicationDocument(intent.document)
            let changed = try execute(sql: """
                UPDATE memory_publication_intents SET state='committed',revision=revision+1,updated_at=?
                WHERE id=? AND state='pending' AND revision=?;
                """, bindings: [.real(now.timeIntervalSince1970), .text(id.uuidString.lowercased()), .integer(expectedRevision)])
            guard changed == 1 else { throw MemoryPublicationError.invalidTransition }
            return MemoryPublicationIntentRecord(intent: intent, state: .committed, revision: record.revision + 1, updatedAt: now)
        }
    }

    public func abortMemoryPublication(id: UUID, expectedRevision: Int64, now: Date) async throws -> MemoryPublicationIntentRecord {
        try transaction {
            guard let record = try memoryPublicationRow(id: id) else { throw MemoryPublicationError.notFound }
            if record.state == .aborted { return record }
            guard record.state == .pending, record.revision == expectedRevision,
                  now.timeIntervalSince1970.isFinite, now >= record.updatedAt else {
                throw MemoryPublicationError.invalidTransition
            }
            let changed = try execute(sql: """
                UPDATE memory_publication_intents SET state='aborted',revision=revision+1,updated_at=?
                WHERE id=? AND state='pending' AND revision=?;
                """, bindings: [.real(now.timeIntervalSince1970), .text(id.uuidString.lowercased()), .integer(expectedRevision)])
            guard changed == 1 else { throw MemoryPublicationError.invalidTransition }
            return MemoryPublicationIntentRecord(intent: record.intent, state: .aborted, revision: record.revision + 1, updatedAt: now)
        }
    }

    public func memoryPublicationBlocksUse(documentID: MemoryDocumentID) async throws -> Bool {
        try transaction { try memoryPublicationBlocksUseRow(documentID: documentID) }
    }

    public func withdrawnMemoryClaimIDs(documentID: MemoryDocumentID) async throws -> [UUID] {
        try transaction { try publicationChain(documentID: documentID).withdrawn.sorted { $0.uuidString < $1.uuidString } }
    }
}

extension SQLiteStore {
    /// Synchronous for read-context admission inside its existing transaction.
    /// Only the exact pending operation may be ignored by its own commit; this
    /// never admits an old head, malformed chain, or missing withdrawal marker.
    func memoryPublicationBlocksUseRow(documentID: MemoryDocumentID,
                                       excludingMemoryPublicationID: UUID? = nil) throws -> Bool {
        let chain = try publicationChain(documentID: documentID)
        return chain.head != documentID || chain.abortedAtHead
            || chain.pending.contains { $0 != excludingMemoryPublicationID }
    }

    private func validateMemoryPublicationAdmission(_ intent: MemoryPublicationIntent) throws {
        try validateMemoryLocalOperationForPublication(intent: intent)
        do { try validateReadContextReceipt(intent.authority, excludingMemoryPublicationID: intent.id) }
        catch { throw MemoryPublicationError.authorityChanged }
        for reference in intent.userMessageEvidence {
            let rows = try query(sql: """
                SELECT m.updated_at,m.created_at,
                    CASE WHEN length(CAST(p.text_value AS BLOB)) BETWEEN 1 AND 65536 THEN p.text_value END AS body
                FROM messages m JOIN message_parts p ON p.message_id=m.id AND p.ordinal=0
                WHERE m.id=? AND m.conversation_id=? AND m.author_kind='user' AND m.author_teammate_id IS NULL
                    AND m.output_class='conversation' AND p.kind='text' AND p.referenced_id IS NULL
                    AND NOT EXISTS(SELECT 1 FROM message_parts other WHERE other.message_id=m.id AND other.ordinal!=0)
                LIMIT 2;
                """, bindings: [.text(reference.messageID.persistedValue), .text(intent.authority.conversationID.persistedValue)])
            guard rows.count == 1, let row = rows.first, let body = try row.optionalText("body"),
                  try row.real("updated_at") == reference.updatedAt.timeIntervalSince1970,
                  try row.real("created_at").isFinite, try row.real("created_at") <= row.real("updated_at"),
                  SHA256.hash(data: Data(body.utf8)).map({ String(format: "%02x", $0) }).joined() == reference.contentDigest else {
                throw MemoryPublicationError.invalidEvidence
            }
        }
        if case .user(let messageID) = intent.actor {
            // Recheck the verifier's latest-command rule in the same transaction:
            // an old literal command cannot regain authority after a newer turn.
            let latest = try query(sql: "SELECT id FROM messages WHERE conversation_id=? ORDER BY sequence DESC LIMIT 1;",
                bindings: [.text(intent.authority.conversationID.persistedValue)]).first
            guard try latest?.text("id") == messageID.persistedValue else { throw MemoryPublicationError.invalidEvidence }
        }
        let existing = try query(sql: "SELECT id FROM memory_documents WHERE id=? OR relative_path=? LIMIT 1;",
            bindings: [.text(intent.document.id.persistedValue), .text(intent.document.relativePath)])
        guard existing.isEmpty else { throw MemoryPublicationError.conflictingOperation }
        if let expected = intent.expectedPredecessor {
            guard let actual = try publicationDocument(id: expected.id),
                  try publicationJSON(actual) == publicationJSON(expected) else { throw MemoryPublicationError.stalePredecessor }
            let chain = try publicationChain(documentID: expected.id)
            guard chain.head == expected.id else { throw MemoryPublicationError.stalePredecessor }
            guard !chain.pending.contains(where: { $0 != intent.id }) else { throw MemoryPublicationError.conflictingOperation }
            guard chain.withdrawn.isSubset(of: Set(intent.withdrawnClaimIDs)) else { throw MemoryPublicationError.withdrawnClaim }
        }
    }

    private func publicationJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard !bytes.isEmpty, bytes.count <= 131_072 else { throw MemoryPublicationError.invalidIntent }
        return bytes
    }

    private func memoryPublicationRow(id: UUID) throws -> MemoryPublicationIntentRecord? {
        guard let row = try query(sql: "SELECT * FROM memory_publication_intents WHERE id=?;",
            bindings: [.text(id.uuidString.lowercased())]).first else { return nil }
        let record = try decodeMemoryPublication(row)
        let document = try publicationDocument(id: record.intent.document.id)
        if record.state == .committed {
            guard let document, try publicationJSON(document) == publicationJSON(record.intent.document) else {
                throw MemoryPublicationError.invalidStoredState
            }
        } else if document != nil { throw MemoryPublicationError.invalidStoredState }
        return record
    }

    private func decodeMemoryPublication(_ row: SQLiteRow) throws -> MemoryPublicationIntentRecord {
        do {
            let bytes = Data(try row.text("intent_json").utf8)
            guard !bytes.isEmpty, bytes.count <= 131_072 else { throw MemoryPublicationError.invalidStoredState }
            let intent = try JSONDecoder().decode(MemoryPublicationIntent.self, from: bytes).validated()
            let revision = try row.integer("revision")
            let updated = try row.real("updated_at")
            guard try publicationJSON(intent) == bytes,
                  try row.text("id") == intent.id.uuidString.lowercased(),
                  try row.text("document_id") == intent.document.id.persistedValue,
                  try row.optionalText("predecessor_id") == intent.expectedPredecessor?.id.persistedValue,
                  try row.text("staging_relative_path") == intent.stagingRelativePath,
                  try row.text("final_relative_path") == intent.document.relativePath,
                  try row.text("content_digest") == intent.document.contentDigest,
                  try row.integer("byte_count") == Int64(intent.byteCount),
                  try row.real("created_at") == intent.createdAt.timeIntervalSince1970,
                  let state = MemoryPublicationState(rawValue: try row.text("state")),
                  updated.isFinite, updated >= intent.createdAt.timeIntervalSince1970,
                  (state == .pending ? revision == 1 && updated == intent.createdAt.timeIntervalSince1970 : revision == 2) else {
                throw MemoryPublicationError.invalidStoredState
            }
            return MemoryPublicationIntentRecord(intent: intent, state: state, revision: revision,
                updatedAt: Date(timeIntervalSince1970: updated))
        } catch { throw MemoryPublicationError.invalidStoredState }
    }

    /// Metadata only; both directions are bounded and ambiguous/missing links
    /// fail closed. Current unreadable artifacts never fall back to ancestors.
    private func publicationChain(documentID: MemoryDocumentID) throws -> MemoryPublicationChain {
        guard var root = try publicationDocument(id: documentID) else { throw MemoryPublicationError.notFound }
        var ancestors: Set<MemoryDocumentID> = [root.id]
        while let parentID = root.supersedes {
            guard ancestors.count < 256, ancestors.insert(parentID).inserted,
                  let parent = try publicationDocument(id: parentID),
                  publicationIsSuccessor(root, of: parent) else { throw MemoryPublicationError.invalidStoredState }
            root = parent
        }
        var visited: Set<MemoryDocumentID> = []
        var current = root
        var pending: Set<UUID> = []
        var withdrawn: Set<UUID> = []
        var abortedAtHead = false
        while true {
            guard visited.count < 256, visited.insert(current.id).inserted else { throw MemoryPublicationError.invalidStoredState }
            let own = try query(sql: "SELECT * FROM memory_publication_intents WHERE document_id=? LIMIT 2;",
                bindings: [.text(current.id.persistedValue)])
            guard own.count <= 1 else { throw MemoryPublicationError.invalidStoredState }
            if let row = own.first {
                let record = try decodeMemoryPublication(row)
                guard record.state == .committed, try publicationJSON(record.intent.document) == publicationJSON(current),
                      withdrawn.isSubset(of: Set(record.intent.withdrawnClaimIDs)) else { throw MemoryPublicationError.invalidStoredState }
                withdrawn.formUnion(record.intent.withdrawnClaimIDs)
            } else if !withdrawn.isEmpty {
                // Old generic insertion may not silently bypass a withdrawal.
                throw MemoryPublicationError.invalidStoredState
            }
            let pendingRows = try query(sql: "SELECT * FROM memory_publication_intents WHERE predecessor_id=? AND state='pending' LIMIT 2;",
                bindings: [.text(current.id.persistedValue)])
            guard pendingRows.count <= 1 else { throw MemoryPublicationError.invalidStoredState }
            for row in pendingRows { pending.insert(try decodeMemoryPublication(row).intent.id) }
            let next = try query(sql: "SELECT id FROM memory_documents WHERE supersedes_id=? LIMIT 2;",
                bindings: [.text(current.id.persistedValue)])
            guard next.count <= 1 else { throw MemoryPublicationError.invalidStoredState }
            guard let nextRow = next.first else {
                // A failed correction cannot restore its predecessor to active
                // use. A separately authorized successful successor resolves this
                // fence; an abort itself never retries or publishes anything.
                if let aborted = try query(sql: """
                    SELECT * FROM memory_publication_intents
                    WHERE predecessor_id=? AND state='aborted' ORDER BY id LIMIT 1;
                    """, bindings: [.text(current.id.persistedValue)]).first {
                    _ = try decodeMemoryPublication(aborted)
                    abortedAtHead = true
                }
                break
            }
            guard let successor = try publicationDocument(id: parseID(MemoryDocumentID.self, nextRow.text("id"))),
                  publicationIsSuccessor(successor, of: current) else { throw MemoryPublicationError.invalidStoredState }
            current = successor
        }
        guard visited.contains(documentID) else { throw MemoryPublicationError.invalidStoredState }
        return MemoryPublicationChain(head: current.id, pending: pending, withdrawn: withdrawn, abortedAtHead: abortedAtHead)
    }

    private func publicationIsSuccessor(_ child: MemoryDocument, of parent: MemoryDocument) -> Bool {
        parent.revision < UInt64(Int64.max) && child.supersedes == parent.id && child.revision == parent.revision + 1
            && child.scope == parent.scope && child.createdAt == parent.createdAt
    }

    private func publicationDocument(id: MemoryDocumentID) throws -> MemoryDocument? {
        guard let row = try query(sql: "SELECT * FROM memory_documents WHERE id=?;", bindings: [.text(id.persistedValue)]).first else { return nil }
        let scope: MemoryScope
        switch (try row.text("scope_kind"), try row.optionalText("scope_id")) {
        case ("user", nil): scope = .user
        case ("teammate", .some(let value)): scope = .teammate(try parseID(TeammateID.self, value))
        case ("project", .some(let value)): scope = .project(try parseID(ProjectID.self, value))
        default: throw MemoryPublicationError.invalidStoredState
        }
        let author: MemoryAuthor
        switch (try row.text("author_kind"), try row.optionalText("author_teammate_id")) {
        case ("user", nil): author = .user
        case ("system", nil): author = .system
        case ("teammate", .some(let value)): author = .teammate(try parseID(TeammateID.self, value))
        default: throw MemoryPublicationError.invalidStoredState
        }
        return try MemoryDocument(id: id, scope: scope, author: author, title: row.text("title"), relativePath: row.text("relative_path"),
            revision: checkedUInt64(row.integer("revision"), field: "memory revision"), contentDigest: row.text("content_digest"),
            supersedes: row.optionalText("supersedes_id").map { try parseID(MemoryDocumentID.self, $0) },
            createdAt: Date(timeIntervalSince1970: row.real("created_at")), updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
    }

    private func insertPublicationDocument(_ document: MemoryDocument) throws {
        let scopeKind: String; let scopeID: String
        switch document.scope {
        case .teammate(let id): scopeKind = "teammate"; scopeID = id.persistedValue
        case .project(let id): scopeKind = "project"; scopeID = id.persistedValue
        case .user: throw MemoryPublicationError.authorityChanged
        }
        _ = try execute(sql: """
            INSERT INTO memory_documents(id,scope_kind,scope_id,author_kind,author_teammate_id,title,relative_path,
                revision,content_digest,supersedes_id,created_at,updated_at) VALUES (?,?,?,?,NULL,?,?,?,?,?,?,?);
            """, bindings: [.text(document.id.persistedValue), .text(scopeKind), .text(scopeID),
                .text(document.author == .user ? "user" : "system"), .text(document.title), .text(document.relativePath),
                .integer(try checkedInt64(document.revision, field: "memory revision")), .text(document.contentDigest),
                document.supersedes.map { .text($0.persistedValue) } ?? .null,
                .real(document.createdAt.timeIntervalSince1970), .real(document.updatedAt.timeIntervalSince1970)])
    }
}

private struct MemoryPublicationChain {
    let head: MemoryDocumentID
    let pending: Set<UUID>
    let withdrawn: Set<UUID>
    let abortedAtHead: Bool
}
