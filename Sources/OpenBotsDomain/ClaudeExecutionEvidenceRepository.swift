import Foundation

/// Stores admitted protocol observations, never provider-authored claims about
/// effective effort, context capacity, account allowance or billing.
public protocol ClaudeExecutionEvidenceRepository: Sendable {
    func recordTextTurnExecutionEvidence(id: RunID, expectedRevision: Int64, token: UUID,
        evidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot
    func finishTextTurnWithExecutionEvidence(id: RunID, expectedRevision: Int64, token: UUID,
        text: String, outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
        evidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot
    func textTurnExecutionEvidence(id: RunID) async throws -> ClaudeExecutionEvidence?
}
