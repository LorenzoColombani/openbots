import Foundation

/// Frozen provenance for the app's text-only reply adapter. Its presence does
/// not authorize a process or make an unrelated executor run recoverable.
public struct TextTurnIdentity: Codable, Equatable, Sendable {
    public let appOwnerID: UUID
    public let replyMessageID: MessageID
    public let replyPartID: MessagePartID
    public let executionRequest: ClaudeExecutionRequest?
    public let controlledMemoryPolicyVersion: UInt16?
    /// The handoff leg this reply's turn belongs to, when it was driven by a
    /// handoff delivery rather than a direct chat message. Absent on old JSON.
    public let handoffLegID: HandoffLegID?
    /// The finished leg whose report this turn answers: the lead compiling a
    /// member's result for the user. Absent on old JSON.
    public let handoffReportLegID: HandoffLegID?
    /// The throwaway worker whose result this turn answers: its holder woken
    /// by the app when the worker finished. The input is
    /// the app's own work note, never the user's. Absent on old JSON.
    public let workerResultID: UUID?

    public init(appOwnerID: UUID, replyMessageID: MessageID, replyPartID: MessagePartID,
                executionRequest: ClaudeExecutionRequest? = nil,
                controlledMemoryPolicyVersion: UInt16? = nil,
                handoffLegID: HandoffLegID? = nil,
                handoffReportLegID: HandoffLegID? = nil,
                workerResultID: UUID? = nil) {
        self.appOwnerID = appOwnerID
        self.replyMessageID = replyMessageID
        self.replyPartID = replyPartID
        self.executionRequest = executionRequest
        self.controlledMemoryPolicyVersion = controlledMemoryPolicyVersion
        self.handoffLegID = handoffLegID
        self.handoffReportLegID = handoffReportLegID
        self.workerResultID = workerResultID
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
    /// The bot decided not to answer. Nothing failed — not this app, not the
    /// connection, not the provider — so a reader of the saved turn is not sent
    /// after a fault that never happened.
    case declined

    /// The reply row a declined turn saves when the bot said nothing at all,
    /// and the durable record of the decision itself: the run state beneath it
    /// is the ordinary `failed`, so this sentence is what tells a later read
    /// that the turn was declined rather than broken. It is deliberately not a
    /// new column or a new run state. A build older than this one reads it as
    /// an ordinary saved status, shows it, and falls back to its general
    /// notice; a schema change would instead make that build refuse the whole
    /// database. Writer and reader must use this constant and nothing else.
    public static let declinedReplyStatus =
        "The bot decided not to answer this one. Nothing went wrong, your text is kept and nothing will be resent."
}

/// A finite app-authored failure classification. No provider text, account data,
/// paths or associated values may be stored through this diagnostic channel.
public enum TextTurnDiagnosticCode: String, Codable, Equatable, Sendable, CaseIterable {
    case duplicateInitialization = "duplicateInitialization"
    case initializationSessionMismatch = "initializationSessionMismatch"
    case initializationToolsInvalid = "initializationToolsInvalid"
    case initializationMCPInvalid = "initializationMCPInvalid"
    case initializationPluginsInvalid = "initializationPluginsInvalid"
    /// The CLI announced a skill, a slash command, an agent the turn never
    /// defined, or an output style: something loaded from a folder, which the
    /// command forbids. Either the CLI's fences moved or files planted under
    /// the bot's folder were read.
    case initializationExtensionsInvalid = "initializationExtensionsInvalid"
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
    /// The CLI ended the run because one more assistant message than
    /// `--max-turns` allows was needed. The turn is the app's own limit, so a
    /// reader of the saved status is not sent after a provider or connection
    /// fault that never happened.
    case turnLimitReached = "turnLimitReached"
    case finalModelMismatch = "finalModelMismatch"
    case executableRejected = "executableRejected"
    case launchFailed = "launchFailed"
    case inputWriteFailed = "inputWriteFailed"
    case deadlineExceeded = "deadlineExceeded"
    case outputLimitExceeded = "outputLimitExceeded"
    case streamReadFailed = "streamReadFailed"
    case processFailed = "processFailed"
    case incompleteResult = "incompleteResult"
    /// A resumed turn named a session the CLI no longer has: the
    /// stored id is dropped and the next turn starts fresh.
    case sessionNotFound = "sessionNotFound"
}

public struct TextTurnSnapshot: Equatable, Sendable {
    public let run: RunJournalRecord
    public let replyText: String
    public let inputState: RunInputState
    /// How the turn ended, read back from what was saved, or nil while it runs.
    public let outcome: TextTurnOutcome?

    public init(run: RunJournalRecord, replyText: String, inputState: RunInputState,
                outcome: TextTurnOutcome? = nil) {
        self.run = run; self.replyText = replyText; self.inputState = inputState
        self.outcome = outcome
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
    /// The bot the run was journalled against. A team conversation needs it to
    /// name the member behind a reply the memory rules store app-qualified.
    public let teammateID: TeammateID
    public let state: WorkRunState
    public let inputState: RunInputState
    /// How the turn ended, where the run has ended at all. `state` alone cannot
    /// tell a declined turn from a broken one: both are journalled `failed`.
    public let outcome: TextTurnOutcome?

    public init(messageID: MessageID, replyMessageID: MessageID, runID: RunID,
                teammateID: TeammateID, state: WorkRunState, inputState: RunInputState,
                outcome: TextTurnOutcome? = nil) {
        self.messageID = messageID; self.replyMessageID = replyMessageID
        self.runID = runID; self.teammateID = teammateID
        self.state = state; self.inputState = inputState
        self.outcome = outcome
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
    /// The bot's most recent text turn for the user in this conversation, in
    /// the conversation's own order: the turn whose request sits last. Nil when
    /// the bot has none there. A team leg it ran for a lead, or the report it
    /// compiles from a member's words, is never it: those requests are a bot's
    /// text, not the user's. A correction reads it to quote the turn it
    /// stopped; the snapshot's `outcome` says whether that turn was in fact
    /// interrupted, and its `replyText` is what the bot had written by then.
    func latestTextTurn(conversationID: ConversationID, teammateID: TeammateID) async throws -> TextTurnSnapshot?
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
