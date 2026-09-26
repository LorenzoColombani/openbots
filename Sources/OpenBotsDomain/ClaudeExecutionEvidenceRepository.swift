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
    /// The newest text turn of a conversation that recorded execution evidence,
    /// so a relaunch can still say which model the last saved reply reported.
    func latestTextTurnExecutionEvidence(conversationID: ConversationID) async throws -> ClaudeExecutionEvidence?
}

public extension ClaudeExecutionEvidenceRepository {
    func latestTextTurnExecutionEvidence(conversationID: ConversationID) async throws -> ClaudeExecutionEvidence? { nil }
}
