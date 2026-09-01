import Foundation
import OpenBotsDomain

extension SQLiteStore: TextTurnRepository {
    public func beginTextTurn(request: WorkRequest, userMessage: Message, expectedPreviousSequence: Int64,
                              ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval) async throws -> TextTurnSnapshot {
        guard request.textTurnIdentity?.controlledMemoryPolicyVersion == nil else { throw TextTurnRepositoryError.invalidRequest }
        return try beginTextTurnTransaction(request: request, userMessage: userMessage,
            expectedPreviousSequence: expectedPreviousSequence, ownerID: ownerID, token: token,
            now: now, leaseDuration: leaseDuration, controlled: false)
    }

    func beginTextTurnTransaction(request: WorkRequest, userMessage: Message, expectedPreviousSequence: Int64,
                                 ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval,
                                 controlled: Bool) throws -> TextTurnSnapshot {
        try validateJournalRequest(request)
        let identity = try textIdentity(request)
        try identity.executionRequest?.validated()
        guard controlled ? identity.controlledMemoryPolicyVersion == 1 : identity.controlledMemoryPolicyVersion == nil else {
            throw TextTurnRepositoryError.invalidRequest
        }
        if controlled {
            guard identity.executionRequest != nil, let receipt = request.readContextReceipt,
                  receipt.qualificationVersion == 1, receipt.claimReferences != nil else {
                throw TextTurnRepositoryError.invalidRequest
            }
        }
        let expiry = try journalExpiry(now: now, duration: leaseDuration)
        guard request.submittedAt <= now, userMessage.id == request.initiatingMessageID,
              userMessage.conversationID == request.conversationID, userMessage.author == .user,
              userMessage.outputClass == .conversation, userMessage.deliveryState == .pending,
              userMessage.createdAt == request.submittedAt, userMessage.updatedAt == request.submittedAt,
              userMessage.parts.count == 1, userMessage.parts[0].content == .text(request.initialInput.text),
              userMessage.sequence < Int64.max, userMessage.id != identity.replyMessageID,
              userMessage.parts[0].id != identity.replyPartID else { throw TextTurnRepositoryError.invalidRequest }
        let reply = try Message(id: identity.replyMessageID, conversationID: request.conversationID,
            sequence: userMessage.sequence + 1, author: controlled ? .system : .teammate(request.teammateID), deliveryState: .pending,
            parts: [MessagePart(id: identity.replyPartID, ordinal: 0, content: .status(Self.textTurnPendingStatus))],
            createdAt: request.submittedAt, updatedAt: request.submittedAt)
        let frozen = try journalJSON(request, maximum: 8 * 1_024 * 1_024)
        return try transaction {
            if let receipt = request.readContextReceipt {
                guard receipt.conversationID == request.conversationID,
                      receipt.teammateID == request.teammateID,
                      receipt.profileRevision == request.profileRevision,
                      receipt.selectedProjectID == request.selectedProjectID,
                      receipt.messages.allSatisfy({ $0.sequence < userMessage.sequence }) else {
                    throw ReadContextError.invalidRequest
                }
                // Source/authority freshness and turn creation share one transaction.
                try validateReadContextReceipt(receipt)
            }
            try validateJournalContext(request)
            if let execution = identity.executionRequest {
                guard let teammate = try teammateRows(whereClause: "t.id=?", bindings: [.text(request.teammateID.persistedValue)]).first,
                      teammate.profile.revision == request.profileRevision,
                      execution.selection.model.utf8.elementsEqual(teammate.requestedClaudeModel.utf8),
                      execution.selection.effort.utf8.elementsEqual(teammate.requestedClaudeEffort.utf8),
                      execution.selection.contextWindow.utf8.elementsEqual(teammate.requestedClaudeContextWindow.utf8) else {
                    throw TextTurnRepositoryError.invalidRequest
                }
            }
            guard try query(sql: "SELECT 1 AS found FROM work_runs WHERE teammate_id=? AND state NOT IN ('succeeded','failed','interrupted') LIMIT 1;",
                bindings: [.text(request.teammateID.persistedValue)]).isEmpty else { throw RunJournalError.conflictingActiveRun }
            try appendMessageGraph(userMessage, expectedPreviousSequence: expectedPreviousSequence)
            try appendMessageGraph(reply, expectedPreviousSequence: userMessage.sequence)
            try validateJournalInput(request.initialInput, conversationID: request.conversationID, submittedAt: request.submittedAt)
            _ = try execute(sql: """
                INSERT INTO work_runs(id,teammate_id,conversation_id,initiating_message_id,selected_project_id,
                    profile_revision,state,created_at,updated_at) VALUES (?,?,?,?,?,?,'queued',?,?);
                """, bindings: [.text(request.runID.persistedValue), .text(request.teammateID.persistedValue),
                    .text(request.conversationID.persistedValue), .text(request.initiatingMessageID.persistedValue),
                    request.selectedProjectID.map { .text($0.persistedValue) } ?? .null,
                    .integer(Int64(request.profileRevision)), .real(request.submittedAt.timeIntervalSince1970),
                    .real(request.submittedAt.timeIntervalSince1970)])
            _ = try execute(sql: "INSERT INTO run_journal_metadata(run_id,request_json,origin,revision) VALUES (?,?,'executor',1);",
                bindings: [.text(request.runID.persistedValue), .text(frozen)])
            try insertJournalInput(request.initialInput, runID: request.runID, submittedAt: request.submittedAt, now: request.submittedAt)
            try insertJournalEntry(id: request.runID, revision: 1, kind: .enqueued, state: .queued,
                messageID: request.initiatingMessageID, now: request.submittedAt)
            let queued = try requiredJournalRecord(request.runID)
            let lease = RunLease(ownerID: ownerID, token: token, generation: 1, expiresAt: expiry)
            let claimed = try updateJournal(queued, state: .starting, lease: lease, kind: .claimed, now: now)
            if controlled {
                _ = try execute(sql: "INSERT INTO controlled_memory_text_turns(run_id,policy_version,admission_token) VALUES (?,1,?);",
                    bindings: [.text(request.runID.persistedValue), .text(token.uuidString.lowercased())])
            }
            if let execution = identity.executionRequest {
                try storeTextExecutionEvidence(claimed, evidence: .init(request: execution, initializedModel: nil, resultModel: nil),
                    token: token, terminalRevision: nil, allowsResult: false)
            }
            return try readTextTurnSnapshot(claimed)
        }
    }

    public func checkpointTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                                   inputEvidence: TextTurnInputEvidence, now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            var current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            try requireRawTextTurn(current)
            let before = try readTextTurnSnapshot(current)
            guard current.state == .starting || current.state == .running else { throw RunJournalError.invalidTransition }
            let inputState = try nextTextInputState(before.inputState, evidence: inputEvidence)
            guard text.isEmpty || inputState == .submitted || inputState == .acknowledged else {
                throw TextTurnRepositoryError.invalidEvidence
            }
            try validateTextSnapshot(text, previous: before.replyText)
            if current.state == .starting, inputState != .queued {
                current = try updateJournal(current, state: .running, lease: current.lease, kind: .stateChanged, now: now)
            }
            if inputState != before.inputState {
                try writeTextInput(current, state: inputState, delivery: inputState == .submitted ? .submitted : .acknowledged, now: now)
                current = try updateJournal(current, state: current.state, lease: current.lease,
                    kind: inputState == .submitted ? .inputSubmitted : .inputAcknowledged,
                    messageID: current.request.initiatingMessageID, now: now)
            }
            try writeTextReply(current, text: text, delivery: .pending, status: Self.textTurnPendingStatus, now: now)
            current = try updateJournal(current, state: current.state, lease: current.lease, kind: .stateChanged, now: now)
            return try readTextTurnSnapshot(current)
        }
    }

    public func finishTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                               outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
                               now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            try requireRawTextTurn(current)
            let before = try readTextTurnSnapshot(current)
            try validateTextSnapshot(text, previous: before.replyText)
            if outcome == .succeeded {
                guard diagnosticCode == nil, current.state == .running,
                      before.inputState == .acknowledged, !text.isEmpty else {
                    throw TextTurnRepositoryError.invalidEvidence
                }
            }
            return try terminateTextTurn(current, text: text, inputState: before.inputState,
                outcome: outcome, diagnosticCode: diagnosticCode, kind: .stateChanged, now: now)
        }
    }

    public func pendingTextTurns(appOwnerID: UUID, limit: Int) async throws -> [TextTurnSnapshot] {
        guard (1...100).contains(limit) else { throw RunJournalError.invalidLimit }
        return try transaction {
            let rows = try query(sql: """
                SELECT r.id FROM work_runs r JOIN run_journal_metadata m ON m.run_id=r.id
                WHERE m.origin='executor' AND r.state NOT IN ('succeeded','failed','interrupted')
                    AND CASE WHEN json_valid(m.request_json)
                        THEN json_extract(m.request_json,'$.textTurnIdentity.appOwnerID') END=? COLLATE NOCASE
                ORDER BY r.updated_at,r.id LIMIT ?;
                """, bindings: [.text(appOwnerID.uuidString), .integer(Int64(limit))])
            return try rows.map { row in
                let current = try requiredJournalRecord(parseID(RunID.self, row.text("id")))
                guard try textIdentity(current.request).appOwnerID == appOwnerID else { throw TextTurnRepositoryError.invalidRequest }
                return try readTextTurnSnapshot(current)
            }
        }
    }

    public func interruptTextTurn(id: RunID, expectedRevision: Int64, appOwnerID: UUID,
                                  processAbsence: TextTurnProcessAbsence, now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            let current = try journalCAS(id, revision: expectedRevision, now: now)
            let before = try readTextTurnSnapshot(current)
            guard try textIdentity(current.request).appOwnerID == appOwnerID,
                  processAbsence.runID == id, current.lease?.ownerID == processAbsence.leaseOwnerID,
                  !journalTerminal(current.state) else { throw TextTurnRepositoryError.processAbsenceMismatch }
            return try terminateTextTurn(current, text: before.replyText, inputState: before.inputState,
                outcome: .interrupted, diagnosticCode: nil, kind: .recovered, now: now)
        }
    }

    public func textTurnProvenance(conversationID: ConversationID,
                                   messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        guard messageIDs.count <= 100, Set(messageIDs).count == messageIDs.count else { throw RunJournalError.invalidLimit }
        guard !messageIDs.isEmpty else { return [] }
        return try transaction {
            let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ",")
            let rows = try query(sql: """
                SELECT r.id FROM work_runs r JOIN run_journal_metadata m ON m.run_id=r.id
                WHERE r.conversation_id=? AND m.origin='executor'
                    AND (r.initiating_message_id IN (\(placeholders))
                        OR CASE WHEN json_valid(m.request_json)
                            THEN json_extract(m.request_json,'$.textTurnIdentity.replyMessageID') END IN (\(placeholders)))
                    AND CASE WHEN json_valid(m.request_json)
                        THEN json_type(m.request_json,'$.textTurnIdentity') END='object'
                ORDER BY r.id LIMIT 101;
                """, bindings: [.text(conversationID.persistedValue)]
                    + messageIDs.map { .text($0.persistedValue) } + messageIDs.map { .text($0.persistedValue) })
            guard rows.count <= 100 else { throw TextTurnRepositoryError.invalidRequest }
            var seen: Set<MessageID> = []
            return try rows.map { row in
                let snapshot = try readTextTurnSnapshot(requiredJournalRecord(parseID(RunID.self, row.text("id"))))
                let request = snapshot.run.request, identity = try textIdentity(request)
                guard request.conversationID == conversationID, seen.insert(request.initiatingMessageID).inserted else {
                    throw TextTurnRepositoryError.invalidRequest
                }
                return TextTurnMessageProvenance(messageID: request.initiatingMessageID, replyMessageID: identity.replyMessageID,
                    runID: snapshot.run.id, state: snapshot.run.state, inputState: snapshot.inputState)
            }
        }
    }

    private static let textTurnPendingStatus = "Waiting for Claude's reply."
    private static let textTurnReplyLimit = 1_024 * 1_024
    private static let textTurnDiagnosticLimit = 128

    private static func textTurnDiagnosticStatus(_ code: TextTurnDiagnosticCode) -> String {
        "OpenBots diagnostic: \(code.rawValue)"
    }

    func textIdentity(_ request: WorkRequest) throws -> TextTurnIdentity {
        guard let identity = request.textTurnIdentity, identity.replyMessageID != request.initiatingMessageID,
              request.initialInput.sequence == 1, request.initialInput.attachmentIDs.isEmpty,
              !request.initialInput.text.isEmpty else { throw TextTurnRepositoryError.invalidRequest }
        return identity
    }

    func readTextTurnSnapshot(_ current: RunJournalRecord) throws -> TextTurnSnapshot {
        guard current.origin == .executor else { throw TextTurnRepositoryError.invalidRequest }
        let identity = try textIdentity(current.request)
        let controlled = identity.controlledMemoryPolicyVersion != nil
        if controlled { try requireControlledTextTurn(current) } else { try requireRawTextTurn(current) }
        let rows = try query(sql: """
            SELECT m.conversation_id,m.author_kind,m.author_teammate_id,m.output_class,m.delivery_state,
                p.id,p.ordinal,p.kind,p.text_value,p.referenced_id
            FROM messages m JOIN message_parts p ON p.message_id=m.id WHERE m.id=?
            ORDER BY p.ordinal LIMIT 3;
            """, bindings: [.text(identity.replyMessageID.persistedValue)])
        guard (1...2).contains(rows.count), let row = rows.first,
              try row.text("conversation_id") == current.request.conversationID.persistedValue,
              try row.text("author_kind") == (controlled ? "system" : "teammate"),
              try row.optionalText("author_teammate_id") == (controlled ? nil : current.request.teammateID.persistedValue),
              try row.text("output_class") == "conversation", try row.text("id") == identity.replyPartID.persistedValue,
              try row.integer("ordinal") == 0, try row.optionalText("referenced_id") == nil,
              MessageDeliveryState(rawValue: try row.text("delivery_state")) != nil else {
            throw TextTurnRepositoryError.invalidReply
        }
        let kind = try row.text("kind"), saved = try row.text("text_value")
        guard kind == "status" || kind == "text", saved.utf8.count <= Self.textTurnReplyLimit,
              kind != "text" || !saved.isEmpty else { throw TextTurnRepositoryError.invalidReply }
        if controlled {
            if current.state == .succeeded {
                guard kind == "text", let publication = try controlledPublicationRow(runID: current.id),
                      publication.publication.text.utf8.elementsEqual(saved.utf8) else { throw TextTurnRepositoryError.invalidReply }
            } else if kind != "status" { throw TextTurnRepositoryError.invalidReply }
        }
        if rows.count == 2 {
            let diagnostic = rows[1]
            guard current.state == .failed || current.state == .interrupted,
                  try diagnostic.integer("ordinal") == 1, try diagnostic.text("kind") == "status",
                  try diagnostic.optionalText("referenced_id") == nil,
                  UUID(uuidString: try diagnostic.text("id")) != nil else {
                throw TextTurnRepositoryError.invalidReply
            }
            let status = try diagnostic.text("text_value")
            guard status.utf8.count <= Self.textTurnDiagnosticLimit,
                  TextTurnDiagnosticCode.allCases.contains(where: { Self.textTurnDiagnosticStatus($0) == status }) else {
                throw TextTurnRepositoryError.invalidReply
            }
        }
        let receipts = try query(sql: "SELECT * FROM run_input_receipts WHERE run_id=? LIMIT 2;",
            bindings: [.text(current.id.persistedValue)])
        guard let receipt = receipts.onlyTextTurnRow else { throw TextTurnRepositoryError.invalidRequest }
        let input = try decodeJournalInput(receipt, request: current.request)
        return TextTurnSnapshot(run: current, replyText: kind == "text" ? saved : "", inputState: input.state)
    }

    func nextTextInputState(_ current: RunInputState, evidence: TextTurnInputEvidence) throws -> RunInputState {
        switch (current, evidence) {
        case (_, .none): current
        case (.queued, .submitted), (.submitted, .submitted): .submitted
        case (.submitted, .acknowledged), (.acknowledged, .acknowledged): .acknowledged
        default: throw TextTurnRepositoryError.invalidEvidence
        }
    }

    func validateTextSnapshot(_ text: String, previous: String) throws {
        guard text.utf8.count <= Self.textTurnReplyLimit, text.utf8.starts(with: previous.utf8) else {
            throw TextTurnRepositoryError.invalidReply
        }
    }

    func writeTextInput(_ current: RunJournalRecord, state: RunInputState,
                                delivery: MessageDeliveryState, now: Date) throws {
        _ = try execute(sql: "UPDATE run_input_receipts SET state=?,updated_at=? WHERE run_id=? AND message_id=? AND sequence=1;",
            bindings: [.text(state.rawValue), .real(now.timeIntervalSince1970), .text(current.id.persistedValue),
                .text(current.request.initiatingMessageID.persistedValue)])
        _ = try execute(sql: "UPDATE messages SET delivery_state=?,updated_at=? WHERE id=?;",
            bindings: [.text(delivery.rawValue), .real(now.timeIntervalSince1970), .text(current.request.initiatingMessageID.persistedValue)])
    }

    private func writeTextReply(_ current: RunJournalRecord, text: String, delivery: MessageDeliveryState,
                                status: String, now: Date) throws {
        let identity = try textIdentity(current.request)
        _ = try execute(sql: "UPDATE message_parts SET kind=?,text_value=? WHERE id=? AND message_id=?;",
            bindings: [.text(text.isEmpty ? "status" : "text"), .text(text.isEmpty ? status : text),
                .text(identity.replyPartID.persistedValue), .text(identity.replyMessageID.persistedValue)])
        // Reply snapshots are output records, not input transport events. Their
        // completion is committed with the run, without fabricating an input ACK.
        _ = try execute(sql: "UPDATE messages SET delivery_state=?,updated_at=? WHERE id=?;",
            bindings: [.text(delivery.rawValue), .real(now.timeIntervalSince1970), .text(identity.replyMessageID.persistedValue)])
        _ = try execute(sql: "UPDATE conversations SET updated_at=MAX(updated_at,?) WHERE id=?;",
            bindings: [.real(now.timeIntervalSince1970), .text(current.request.conversationID.persistedValue)])
    }

    func terminateTextTurn(_ current: RunJournalRecord, text: String, inputState: RunInputState,
                                   outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
                                   kind: RunJournalEntryKind, now: Date) throws -> TextTurnSnapshot {
        let state: WorkRunState
        let replyDelivery: MessageDeliveryState
        let userDelivery: MessageDeliveryState
        let status: String
        switch outcome {
        case .succeeded:
            state = .succeeded; replyDelivery = .completed; userDelivery = .completed; status = "Reply completed."
        case .failed:
            state = .failed; replyDelivery = .failed; userDelivery = .failed; status = "Claude could not complete this reply."
        case .interrupted:
            state = .interrupted; replyDelivery = .outcomeUnknown
            userDelivery = inputState == .acknowledged ? .outcomeUnknown : .failed
            status = "Reply interrupted. No automatic retry was started."
        }
        let receiptState: RunInputState = outcome != .succeeded && inputState == .submitted ? .outcomeUnknown : inputState
        try writeTextReply(current, text: text, delivery: replyDelivery, status: status, now: now)
        if let diagnosticCode {
            let diagnostic = Self.textTurnDiagnosticStatus(diagnosticCode)
            guard diagnostic.utf8.count <= Self.textTurnDiagnosticLimit else { throw TextTurnRepositoryError.invalidEvidence }
            let identity = try textIdentity(current.request)
            _ = try execute(sql: """
                INSERT INTO message_parts(id,message_id,ordinal,kind,text_value,referenced_id)
                VALUES (?,?,1,'status',?,NULL);
                """, bindings: [.text(MessagePartID(UUID()).persistedValue),
                    .text(identity.replyMessageID.persistedValue), .text(diagnostic)])
        }
        try writeTextInput(current, state: receiptState, delivery: userDelivery, now: now)
        let terminal = try updateJournal(current, state: state, lease: nil, kind: kind, now: now)
        return try readTextTurnSnapshot(terminal)
    }
}

private extension Array where Element == SQLiteRow {
    var onlyTextTurnRow: SQLiteRow? { count == 1 ? first : nil }
}
