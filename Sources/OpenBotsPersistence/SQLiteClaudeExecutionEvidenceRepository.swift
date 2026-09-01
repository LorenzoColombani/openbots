import Foundation
import OpenBotsDomain

extension SQLiteStore: ClaudeExecutionEvidenceRepository {
    public func recordTextTurnExecutionEvidence(id: RunID, expectedRevision: Int64, token: UUID,
        evidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            guard current.state == .starting || current.state == .running else { throw RunJournalError.invalidTransition }
            _ = try readTextTurnSnapshot(current)
            try storeTextExecutionEvidence(current, evidence: evidence, token: token, terminalRevision: nil, allowsResult: false)
            let changed = try updateJournal(current, state: current.state, lease: current.lease, kind: .stateChanged, now: now)
            return try readTextTurnSnapshot(changed)
        }
    }

    public func finishTextTurnWithExecutionEvidence(id: RunID, expectedRevision: Int64, token: UUID,
        text: String, outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
        evidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot {
        try transaction {
            let existing = try requiredJournalRecord(id)
            try requireRawTextTurn(existing)
            if journalTerminal(existing.state) {
                let saved = try readTextTurnSnapshot(existing)
                guard let row = try textExecutionEvidenceRow(existing), row.token == token,
                      row.terminalRevision == expectedRevision, row.evidence == evidence,
                      saved.replyText.utf8.elementsEqual(text.utf8),
                      existing.state == Self.executionTerminalState(outcome),
                      try textTurnDiagnosticMatches(existing, diagnosticCode: diagnosticCode) else {
                    throw RunJournalError.staleRevision
                }
                return saved
            }
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            let before = try readTextTurnSnapshot(current)
            try validateTextSnapshot(text, previous: before.replyText)
            if outcome == .succeeded {
                guard current.state == .running, before.inputState == .acknowledged,
                      diagnosticCode == nil, !text.isEmpty else { throw TextTurnRepositoryError.invalidEvidence }
            }
            try storeTextExecutionEvidence(current, evidence: evidence, token: token,
                terminalRevision: expectedRevision, allowsResult: outcome == .succeeded)
            return try terminateTextTurn(current, text: text, inputState: before.inputState,
                outcome: outcome, diagnosticCode: diagnosticCode, kind: .stateChanged, now: now)
        }
    }

    public func textTurnExecutionEvidence(id: RunID) async throws -> ClaudeExecutionEvidence? {
        try transaction {
            guard try !query(sql: "SELECT id FROM work_runs WHERE id=?;", bindings: [.text(id.persistedValue)]).isEmpty else { return nil }
            let current = try requiredJournalRecord(id)
            return try textExecutionEvidenceRow(current)?.evidence
        }
    }
}

extension SQLiteStore {
    struct TextExecutionEvidenceRow {
        let evidence: ClaudeExecutionEvidence
        let token: UUID
        let terminalRevision: Int64?
    }

    func textExecutionEvidenceRow(_ current: RunJournalRecord) throws -> TextExecutionEvidenceRow? {
        let rows = try query(sql: """
            SELECT CASE WHEN length(CAST(evidence_json AS BLOB)) BETWEEN 1 AND 4096 THEN evidence_json END AS evidence_json,
                admission_token,terminal_revision FROM claude_text_execution_evidence WHERE run_id=?;
            """, bindings: [.text(current.id.persistedValue)])
        guard let row = rows.first else {
            guard current.request.textTurnIdentity?.executionRequest == nil else { throw TextTurnRepositoryError.invalidEvidence }
            return nil
        }
        guard current.origin == .executor, let frozen = current.request.textTurnIdentity?.executionRequest,
              let json = try row.optionalText("evidence_json"), let token = UUID(uuidString: try row.text("admission_token")) else {
            throw TextTurnRepositoryError.invalidEvidence
        }
        let evidence = try JSONDecoder().decode(ClaudeExecutionEvidence.self, from: Data(json.utf8))
        guard evidence.request == frozen,
              try MemoryClaimDigests.canonicalData(evidence) == Data(json.utf8) else { throw TextTurnRepositoryError.invalidEvidence }
        let revision = try row.optionalInteger("terminal_revision")
        if evidence.resultModel != nil {
            guard current.state == .succeeded, revision != nil,
                  try query(sql: "SELECT 1 AS found FROM run_input_receipts WHERE run_id=? AND state='acknowledged' AND sequence=1;",
                    bindings: [.text(current.id.persistedValue)]).count == 1 else { throw TextTurnRepositoryError.invalidEvidence }
        }
        return .init(evidence: evidence, token: token, terminalRevision: revision)
    }

    func storeTextExecutionEvidence(_ current: RunJournalRecord, evidence: ClaudeExecutionEvidence,
                                   token: UUID, terminalRevision: Int64?, allowsResult: Bool) throws {
        try evidence.validated()
        guard current.origin == .executor, let frozen = current.request.textTurnIdentity?.executionRequest,
              evidence.request == frozen, allowsResult || evidence.resultModel == nil else {
            throw TextTurnRepositoryError.invalidEvidence
        }
        if evidence.resultModel != nil {
            guard current.state == .running, terminalRevision != nil,
                  try query(sql: "SELECT 1 AS found FROM run_input_receipts WHERE run_id=? AND state='acknowledged' AND sequence=1;",
                    bindings: [.text(current.id.persistedValue)]).count == 1 else { throw TextTurnRepositoryError.invalidEvidence }
        }
        // Initial insertion happens in the same transaction as admission.
        let priorRows = try query(sql: "SELECT 1 AS found FROM claude_text_execution_evidence WHERE run_id=?;",
            bindings: [.text(current.id.persistedValue)])
        if !priorRows.isEmpty, let previous = try textExecutionEvidenceRow(current) {
            guard previous.token == token, previous.terminalRevision == nil,
                  previous.evidence.initializedModel == nil || previous.evidence.initializedModel == evidence.initializedModel,
                  previous.evidence.resultModel == nil else { throw TextTurnRepositoryError.invalidEvidence }
            if terminalRevision != nil, previous.evidence.initializedModel != evidence.initializedModel {
                throw TextTurnRepositoryError.invalidEvidence
            }
        }
        let bytes = try MemoryClaimDigests.canonicalData(evidence)
        guard bytes.count <= 4_096 else { throw TextTurnRepositoryError.invalidEvidence }
        _ = try execute(sql: """
            INSERT INTO claude_text_execution_evidence(run_id,evidence_json,admission_token,terminal_revision) VALUES (?,?,?,?)
            ON CONFLICT(run_id) DO UPDATE SET evidence_json=excluded.evidence_json,terminal_revision=excluded.terminal_revision;
            """, bindings: [.text(current.id.persistedValue), .text(String(decoding: bytes, as: UTF8.self)),
                .text(token.uuidString.lowercased()), terminalRevision.map(SQLiteBinding.integer) ?? .null])
    }

    private static func executionTerminalState(_ outcome: TextTurnOutcome) -> WorkRunState {
        switch outcome { case .succeeded: .succeeded; case .failed: .failed; case .interrupted: .interrupted }
    }

    func textTurnDiagnosticMatches(_ current: RunJournalRecord, diagnosticCode: TextTurnDiagnosticCode?) throws -> Bool {
        let identity = try textIdentity(current.request)
        let rows = try query(sql: "SELECT kind,text_value FROM message_parts WHERE message_id=? AND ordinal=1;",
            bindings: [.text(identity.replyMessageID.persistedValue)])
        guard let diagnosticCode else { return rows.isEmpty }
        guard rows.count == 1, let row = rows.first else { return false }
        return try row.text("kind") == "status" && row.text("text_value") == "OpenBots diagnostic: \(diagnosticCode.rawValue)"
    }
}
