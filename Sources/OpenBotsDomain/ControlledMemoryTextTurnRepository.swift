import Foundation

/// A controlled turn never accepts provider prose for a durable message. Only
/// the host's complete, revalidated publication may finish its existing pair.
public protocol ControlledMemoryTextTurnRepository: Sendable {
    func beginControlledMemoryTextTurn(request: WorkRequest, userMessage: Message,
        expectedPreviousSequence: Int64, ownerID: UUID, token: UUID, now: Date,
        leaseDuration: TimeInterval) async throws -> TextTurnSnapshot
    func checkpointControlledMemoryTextTurn(id: RunID, expectedRevision: Int64, token: UUID,
        inputEvidence: TextTurnInputEvidence, executionEvidence: ClaudeExecutionEvidence?,
        now: Date) async throws -> TextTurnSnapshot
    func finishControlledMemoryTextTurn(id: RunID, expectedRevision: Int64, token: UUID,
        publication: MemoryConversationPublication, validation: MemoryConversationPublicationValidation,
        executionEvidence: ClaudeExecutionEvidence, now: Date) async throws -> TextTurnSnapshot
    /// Success is rejected. Failure/interruption keeps only an app-owned status.
    func failControlledMemoryTextTurn(id: RunID, expectedRevision: Int64, token: UUID,
        outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?, now: Date) async throws -> TextTurnSnapshot
}
