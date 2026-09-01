import Foundation

/// Frozen provenance for the app's text-only reply adapter. Its presence does
/// not authorize a process or make an unrelated executor run recoverable.
public struct TextTurnIdentity: Codable, Equatable, Sendable {
    public let appOwnerID: UUID
    public let replyMessageID: MessageID
    public let replyPartID: MessagePartID
    public let executionRequest: ClaudeExecutionRequest?
    public let controlledMemoryPolicyVersion: UInt16?

    public init(appOwnerID: UUID, replyMessageID: MessageID, replyPartID: MessagePartID,
                executionRequest: ClaudeExecutionRequest? = nil,
                controlledMemoryPolicyVersion: UInt16? = nil) {
        self.appOwnerID = appOwnerID
        self.replyMessageID = replyMessageID
        self.replyPartID = replyPartID
        self.executionRequest = executionRequest
        self.controlledMemoryPolicyVersion = controlledMemoryPolicyVersion
    }
}

public enum TextTurnInputEvidence: Equatable, Sendable {
    case none
    /// The exact frozen input was written to the owned process.
    case submitted
    /// A correlated runtime event proved acceptance of the frozen input.
    case acknowledged
}

public enum TextTurnOutcome: Equatable, Sendable {
    case succeeded, failed, interrupted
}

/// A finite app-authored failure classification. No provider text, account data,
/// paths or associated values may be stored through this diagnostic channel.
public enum TextTurnDiagnosticCode: String, Codable, Equatable, Sendable, CaseIterable {
    case duplicateInitialization = "duplicateInitialization"
    case initializationSessionMismatch = "initializationSessionMismatch"
    case initializationToolsInvalid = "initializationToolsInvalid"
    case initializationMCPInvalid = "initializationMCPInvalid"
    case initializationPluginsInvalid = "initializationPluginsInvalid"
    case initializationPermissionMismatch = "initializationPermissionMismatch"
    case initializationKeySourceInvalid = "initializationKeySourceInvalid"
    case initializationModelInvalid = "initializationModelInvalid"
    case invalidJSON = "invalidJSON"
    case invalidEnvelope = "invalidEnvelope"
    case unexpectedEvent = "unexpectedEvent"
    case eventAfterResult = "eventAfterResult"
    case invalidCommandLifecycle = "invalidCommandLifecycle"
    case commandLifecycleRejected = "commandLifecycleRejected"
    case invalidKeepAlive = "invalidKeepAlive"
    case unexpectedSystemEvent = "unexpectedSystemEvent"
    case nestedToolEvent = "nestedToolEvent"
    case invalidStatusMetadata = "invalidStatusMetadata"
    case statusPermissionMismatch = "statusPermissionMismatch"
    case replayNotConfirmed = "replayNotConfirmed"
    case replayDuplicate = "replayDuplicate"
    case replaySessionMismatch = "replaySessionMismatch"
    case replayMessageMismatch = "replayMessageMismatch"
    case replayContentInvalid = "replayContentInvalid"
    case replayTextMismatch = "replayTextMismatch"
    case responseMismatch = "responseMismatch"
    case providerFailure = "providerFailure"
    case finalModelMismatch = "finalModelMismatch"
    case executableRejected = "executableRejected"
    case launchFailed = "launchFailed"
    case inputWriteFailed = "inputWriteFailed"
    case deadlineExceeded = "deadlineExceeded"
    case outputLimitExceeded = "outputLimitExceeded"
    case streamReadFailed = "streamReadFailed"
    case processFailed = "processFailed"
    case incompleteResult = "incompleteResult"
}

public struct TextTurnSnapshot: Equatable, Sendable {
    public let run: RunJournalRecord
    public let replyText: String
    public let inputState: RunInputState

    public init(run: RunJournalRecord, replyText: String, inputState: RunInputState) {
        self.run = run; self.replyText = replyText; self.inputState = inputState
    }
}

/// An explicit assertion supplied only by the process-owning service after it
/// proves absence. Task cancellation and an expired lease are not that proof.
public struct TextTurnProcessAbsence: Equatable, Sendable {
    public let runID: RunID
    public let leaseOwnerID: UUID

    public init(runID: RunID, leaseOwnerID: UUID) {
        self.runID = runID; self.leaseOwnerID = leaseOwnerID
    }
}

/// Bounded provenance for either side of a text turn. `messageID` always identifies
/// its initiating user message, including when only `replyMessageID` was queried.
/// Absence means no proven association; an old local-only message stays local-only.
public struct TextTurnMessageProvenance: Equatable, Sendable {
    public let messageID: MessageID
    public let replyMessageID: MessageID
    public let runID: RunID
    public let state: WorkRunState
    public let inputState: RunInputState

    public init(messageID: MessageID, replyMessageID: MessageID, runID: RunID,
                state: WorkRunState, inputState: RunInputState) {
        self.messageID = messageID; self.replyMessageID = replyMessageID
        self.runID = runID; self.state = state; self.inputState = inputState
    }
}

public enum TextTurnRepositoryError: Error, Equatable, Sendable {
    case invalidRequest, invalidReply, invalidEvidence, unavailable, processAbsenceMismatch
}

/// One repository transaction per operation. Complete reply snapshots avoid
/// replaying a delta twice; the run revision and lease fence every live write.
public protocol TextTurnRepository: Sendable {
    func beginTextTurn(request: WorkRequest, userMessage: Message, expectedPreviousSequence: Int64,
                       ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval) async throws -> TextTurnSnapshot
    func checkpointTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                            inputEvidence: TextTurnInputEvidence, now: Date) async throws -> TextTurnSnapshot
    /// An optional static diagnostic is committed with a failed/interrupted turn,
    /// separately from its actual reply text. Success cannot carry a diagnostic.
    func finishTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                        outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?,
                        now: Date) async throws -> TextTurnSnapshot
    func pendingTextTurns(appOwnerID: UUID, limit: Int) async throws -> [TextTurnSnapshot]
    func interruptTextTurn(id: RunID, expectedRevision: Int64, appOwnerID: UUID,
                           processAbsence: TextTurnProcessAbsence, now: Date) async throws -> TextTurnSnapshot
    /// Accepts at most 100 unique user/reply IDs from one conversation. Each turn
    /// appears once even when both sides are requested; at most 100 rows escape.
    func textTurnProvenance(conversationID: ConversationID,
                            messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance]
}

public extension TextTurnRepository {
    /// Preserve existing callers without allowing an implementation to silently
    /// discard a diagnostic supplied through the required method above.
    func finishTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
                        outcome: TextTurnOutcome, now: Date) async throws -> TextTurnSnapshot {
        try await finishTextTurn(id: id, expectedRevision: expectedRevision, token: token,
            text: text, outcome: outcome, diagnosticCode: nil, now: now)
    }
}
