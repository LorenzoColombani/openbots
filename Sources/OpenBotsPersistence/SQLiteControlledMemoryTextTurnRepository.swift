import Foundation
import OpenBotsDomain

extension SQLiteStore: ControlledMemoryTextTurnRepository {
    public func beginControlledMemoryTextTurn(request: WorkRequest, userMessage: Message,
        expectedPreviousSequence: Int64, ownerID: UUID, token: UUID, now: Date,
        leaseDuration: TimeInterval) async throws -> TextTurnSnapshot {
        try beginTextTurnTransaction(request: request, userMessage: userMessage,
            expectedPreviousSequence: expectedPreviousSequence, ownerID: ownerID, token: token,
            now: now, leaseDuration: leaseDuration, controlled: true)
    }

    public func checkpointControlledMemoryTextTurn(id: RunID, expectedRevision: Int64, token: UUID,
        inputEvidence: TextTurnInputEvidence, executionEvidence: ClaudeExecutionEvidence?,
        now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            var current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            try requireControlledTextTurn(current)
            let before = try readTextTurnSnapshot(current)
            guard current.state == .starting || current.state == .running else { throw RunJournalError.invalidTransition }
            let state = try nextTextInputState(before.inputState, evidence: inputEvidence)
            if let executionEvidence {
                try storeTextExecutionEvidence(current, evidence: executionEvidence, token: token,
                    terminalRevision: nil, allowsResult: false)
            }
            if current.state == .starting, state != .queued {
                current = try updateJournal(current, state: .running, lease: current.lease, kind: .stateChanged, now: now)
            }
            if state != before.inputState {
                try writeTextInput(current, state: state, delivery: state == .submitted ? .submitted : .acknowledged, now: now)
                current = try updateJournal(current, state: current.state, lease: current.lease,
                    kind: state == .submitted ? .inputSubmitted : .inputAcknowledged,
                    messageID: current.request.initiatingMessageID, now: now)
            }
            current = try updateJournal(current, state: current.state, lease: current.lease, kind: .stateChanged, now: now)
            return try readTextTurnSnapshot(current)
        }
    }

    public func finishControlledMemoryTextTurn(id: RunID, expectedRevision: Int64, token: UUID,
        publication: MemoryConversationPublication, validation: MemoryConversationPublicationValidation,
        executionEvidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            let existing = try requiredJournalRecord(id)
            try requireControlledTextTurn(existing)
            if existing.state == .succeeded {
                guard let saved = try controlledPublicationRow(runID: id),
                      let marker = try controlledTextMarker(id),
                      try marker.text("admission_token") == token.uuidString.lowercased(),
                      try marker.optionalInteger("finish_revision") == expectedRevision,
                      saved.publication == publication, saved.authority == validation.authority,
                      saved.userSourceStamps == validation.userSourceStamps,
                      try MemoryConversationPublicationValidation.digest(of: publication) == validation.publicationDigest,
                      try textExecutionEvidenceRow(existing)?.evidence == executionEvidence else { throw RunJournalError.staleRevision }
                return try readTextTurnSnapshot(existing)
            }
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            let before = try readTextTurnSnapshot(current)
            let identity = try textIdentity(current.request)
            guard current.state == .running, before.inputState == .acknowledged, before.replyText.isEmpty,
                  publication.receipt.runID == id, publication.receipt.messageID == identity.replyMessageID,
                  publication.receipt.intent == .reply, executionEvidence.initializedModel != nil,
                  validation.checkedAt.timeIntervalSince1970.isFinite, validation.checkedAt <= now,
                  publication.receipt.createdAt >= current.request.submittedAt,
                  publication.receipt.createdAt <= validation.checkedAt,
                  now.timeIntervalSince(validation.checkedAt) < MemoryConversationPublicationValidation.lifetime,
                  try MemoryConversationPublicationValidation.digest(of: publication) == validation.publicationDigest,
                  let frozen = current.request.readContextReceipt else { throw TextTurnRepositoryError.invalidEvidence }
            // The final projection can use fewer admitted claims, never a new
            // source or scope. Revalidate the full input as well as the projection.
            let selected = try frozen.selecting(messageIDs: validation.authority.messages.map(\.messageID),
                memoryDocumentIDs: validation.authority.memoryDocuments.map(\.documentID))
                .qualifying(with: validation.authority.claimReferences ?? [])
            guard selected == validation.authority,
                  Set(validation.authority.claimReferences ?? []).isSubset(of: Set(frozen.claimReferences ?? [])) else {
                throw ReadContextError.staleReferences
            }
            try validateReadContextReceipt(frozen)
            try validateReadContextReceipt(validation.authority)
            try validateJournalContext(current.request)
            let record = try controlledPublicationRecord(current, publication: publication, validation: validation, now: now)
            try validateConversationPublicationShape(record)
            try validateConversationPublicationSources(record)
            try validateConversationPublicationLineage(record)
            guard try conversationPublicationRow(id: publication.receipt.id) == nil else {
                throw MemoryConversationPublicationRepositoryError.conflictingIdentity
            }
            let json = try conversationPublicationJSON(StoredConversationPublication(record))
            try storeTextExecutionEvidence(current, evidence: executionEvidence, token: token,
                terminalRevision: expectedRevision, allowsResult: true)
            let changed = try execute(sql: """
                UPDATE controlled_memory_text_turns SET publication_id=?,publication_json=?,publication_digest=?,finish_revision=?
                WHERE run_id=? AND publication_id IS NULL AND admission_token=?;
                """, bindings: [.text(publication.receipt.id.uuidString.lowercased()), .text(json),
                    .text(validation.publicationDigest), .integer(expectedRevision), .text(id.persistedValue),
                    .text(token.uuidString.lowercased())])
            guard changed == 1 else { throw RunJournalError.staleRevision }
            return try terminateTextTurn(current, text: publication.text, inputState: before.inputState,
                outcome: .succeeded, diagnosticCode: nil, kind: .stateChanged, now: now)
        }
    }

    public func failControlledMemoryTextTurn(id: RunID, expectedRevision: Int64, token: UUID,
        outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?, now: Date) async throws -> TextTurnSnapshot {
        guard outcome != .succeeded else { throw TextTurnRepositoryError.invalidEvidence }
        return try transaction {
            let existing = try requiredJournalRecord(id)
            try requireControlledTextTurn(existing)
            if journalTerminal(existing.state) {
                guard existing.state == (outcome == .failed ? .failed : .interrupted),
                      let savedEvidence = try textExecutionEvidenceRow(existing), savedEvidence.token == token,
                      savedEvidence.terminalRevision == expectedRevision,
                      try textTurnDiagnosticMatches(existing, diagnosticCode: diagnosticCode) else { throw RunJournalError.staleRevision }
                return try readTextTurnSnapshot(existing)
            }
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            try requireControlledTextTurn(current)
            let before = try readTextTurnSnapshot(current)
            guard let evidence = try textExecutionEvidenceRow(current)?.evidence else { throw TextTurnRepositoryError.invalidEvidence }
            try storeTextExecutionEvidence(current, evidence: evidence, token: token,
                terminalRevision: expectedRevision, allowsResult: false)
            return try terminateTextTurn(current, text: "", inputState: before.inputState,
                outcome: outcome, diagnosticCode: diagnosticCode, kind: .stateChanged, now: now)
        }
    }
}

extension SQLiteStore {
    func requireRawTextTurn(_ current: RunJournalRecord) throws {
        guard current.request.textTurnIdentity?.controlledMemoryPolicyVersion == nil,
              try controlledTextMarker(current.id) == nil else { throw TextTurnRepositoryError.invalidRequest }
    }

    func requireControlledTextTurn(_ current: RunJournalRecord) throws {
        guard current.origin == .executor, current.request.textTurnIdentity?.controlledMemoryPolicyVersion == 1,
              current.request.textTurnIdentity?.executionRequest != nil,
              current.request.readContextReceipt?.qualificationVersion == 1,
              let marker = try controlledTextMarker(current.id), try marker.integer("policy_version") == 1 else {
            throw TextTurnRepositoryError.invalidRequest
        }
        guard try (marker.optionalText("publication_id") != nil) == (current.state == .succeeded) else {
            throw TextTurnRepositoryError.invalidRequest
        }
    }

    func controlledTextMarker(_ id: RunID) throws -> SQLiteRow? {
        try query(sql: "SELECT run_id,policy_version,admission_token,publication_id,finish_revision FROM controlled_memory_text_turns WHERE run_id=?;",
            bindings: [.text(id.persistedValue)]).first
    }

    func controlledPublicationRow(publicationID: UUID) throws -> MemoryConversationPublicationRecord? {
        guard let row = try query(sql: "SELECT run_id FROM controlled_memory_text_turns WHERE publication_id=?;",
            bindings: [.text(publicationID.uuidString.lowercased())]).first else { return nil }
        return try controlledPublicationRow(runID: parseID(RunID.self, row.text("run_id")))
    }

    func controlledPublicationRow(messageID: MessageID, conversationID: ConversationID) throws -> MemoryConversationPublicationRecord? {
        let rows = try query(sql: """
            SELECT r.id FROM controlled_memory_text_turns c JOIN work_runs r ON r.id=c.run_id
            JOIN run_journal_metadata j ON j.run_id=r.id
            WHERE c.publication_id IS NOT NULL AND r.conversation_id=? AND
                (r.initiating_message_id=? OR CASE WHEN json_valid(j.request_json)
                    THEN json_extract(j.request_json,'$.textTurnIdentity.replyMessageID') END=? COLLATE NOCASE) LIMIT 2;
            """, bindings: [.text(conversationID.persistedValue), .text(messageID.persistedValue), .text(messageID.persistedValue)])
        guard rows.count <= 1 else { throw MemoryConversationPublicationRepositoryError.invalidStoredState }
        guard let row = rows.first else { return nil }
        return try controlledPublicationRow(runID: parseID(RunID.self, row.text("id")))
    }

    func controlledPublicationRow(runID: RunID) throws -> MemoryConversationPublicationRecord? {
        guard let row = try query(sql: """
            SELECT publication_id,publication_digest,finish_revision,
                CASE WHEN length(CAST(publication_json AS BLOB)) BETWEEN 1 AND 131072 THEN publication_json END AS publication_json
            FROM controlled_memory_text_turns WHERE run_id=? AND publication_id IS NOT NULL;
            """, bindings: [.text(runID.persistedValue)]).first else { return nil }
        do {
            guard let json = try row.optionalText("publication_json") else { throw TextTurnRepositoryError.invalidReply }
            let stored = try JSONDecoder().decode(StoredConversationPublication.self, from: Data(json.utf8))
            let record = stored.record
            let run = try requiredJournalRecord(runID)
            let identity = try textIdentity(run.request)
            try requireControlledTextTurn(run)
            try validateConversationPublicationShape(record)
            guard run.state == .succeeded, record.providerRunID == runID,
                  record.publication.receipt.runID == runID, record.publication.receipt.messageID == identity.replyMessageID,
                  record.userMessage.id == run.request.initiatingMessageID,
                  record.authority.conversationID == run.request.conversationID,
                  record.authority.teammateID == run.request.teammateID,
                  try row.text("publication_id") == record.publication.receipt.id.uuidString.lowercased(),
                  try row.text("publication_digest") == MemoryConversationPublicationValidation.digest(of: record.publication),
                  try row.integer("finish_revision") + 1 == run.revision,
                  try conversationPublicationJSON(stored).utf8.elementsEqual(json.utf8),
                  try conversationPublicationMessageMatches(record.userMessage),
                  try conversationPublicationMessageMatches(record.replyMessage),
                  try textExecutionEvidenceRow(run)?.terminalRevision == row.integer("finish_revision") else {
                throw MemoryConversationPublicationRepositoryError.invalidStoredState
            }
            return record
        } catch { throw MemoryConversationPublicationRepositoryError.invalidStoredState }
    }

    private func controlledPublicationRecord(_ current: RunJournalRecord, publication: MemoryConversationPublication,
                                            validation: MemoryConversationPublicationValidation, now: Date) throws -> MemoryConversationPublicationRecord {
        let identity = try textIdentity(current.request)
        guard let row = try query(sql: """
            SELECT m.sequence,m.created_at,p.id,p.text_value FROM messages m JOIN message_parts p ON p.message_id=m.id
            WHERE m.id=? AND m.conversation_id=? AND m.author_kind='user' AND m.output_class='conversation'
                AND p.ordinal=0 AND p.kind='text' AND p.referenced_id IS NULL
                AND NOT EXISTS(SELECT 1 FROM message_parts x WHERE x.message_id=m.id AND x.ordinal!=0);
            """, bindings: [.text(current.request.initiatingMessageID.persistedValue), .text(current.request.conversationID.persistedValue)]).first,
              try row.text("text_value").utf8.elementsEqual(current.request.initialInput.text.utf8) else {
            throw TextTurnRepositoryError.invalidRequest
        }
        let created = Date(timeIntervalSince1970: try row.real("created_at"))
        let user = try Message(id: current.request.initiatingMessageID, conversationID: current.request.conversationID,
            sequence: row.integer("sequence"), author: .user, deliveryState: .completed,
            parts: [MessagePart(id: parseID(MessagePartID.self, row.text("id")), ordinal: 0, content: .text(row.text("text_value")))],
            createdAt: created, updatedAt: now)
        let reply = try Message(id: identity.replyMessageID, conversationID: current.request.conversationID,
            sequence: user.sequence + 1, author: .system, deliveryState: .completed,
            parts: [MessagePart(id: identity.replyPartID, ordinal: 0, content: .text(publication.text))],
            createdAt: created, updatedAt: now)
        return .init(publication: publication, userMessage: user, replyMessage: reply,
            authority: validation.authority, userSourceStamps: validation.userSourceStamps, storedAt: now, providerRunID: current.id)
    }
}
