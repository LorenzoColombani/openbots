import Foundation
import OpenBotsDomain

/// One explicit new user action. Old saved messages are never an outbox.
public struct ClaudeTextTurnSubmission: Equatable, Sendable {
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let userMessageID: MessageID
    public let text: String
    public let attachmentIDs: [AttachmentID]
    /// Sent while the bot was still working on the previous message: that
    /// turn was stopped, its finished work kept, and this one carries the
    /// correction.
    public let correctsRunningTurn: Bool

    public init(conversationID: ConversationID, teammateID: TeammateID,
                userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID] = [],
                correctsRunningTurn: Bool = false) {
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.userMessageID = userMessageID
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.correctsRunningTurn = correctsRunningTurn
    }
}

public enum ClaudeTextTurnStage: Equatable, Sendable {
    case selectingContext
    case checkingReadiness
    case starting
    case responding
    case saving
}

/// One card on the chat path: the CLI asked whether a tool use may go ahead and
/// the app is waiting for the user. Answered through `decideApproval`; gone
/// when the turn ends or the card expires.
public struct ClaudeTextApproval: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let runID: RunID
    public let requestID: String
    public let toolName: String
    public let title: String
    public let detail: String
    public let target: String
    public let expiresAt: Date
    /// The folder or script "Allow for this turn" would cover, when this card
    /// offers it, until the turn ends. Nil on a card that must be answered
    /// every time (a plain command, a helper, a connector).
    public let turnScopeFolder: String?
    /// Absolute path the card can reveal (a run-code script).
    public let openablePath: String?
    /// The login handoff: the bot hands the user the screen. Its two
    /// answers are Hand back (allow) and I couldn't do it (deny).
    public let handsOverScreen: Bool
    /// A member's file the lead's reply would return is gone. Its two answers are Choose
    /// the File… (`replaceMissingFile`) and Continue Without It (deny).
    public let asksForMissingFile: Bool
    /// The screenshot the bot took of the user's screen before this web call
    /// asks, shown on the card as well. Held in memory for the card on screen only:
    /// never in the approvals row, the record or the database.
    public let screenPicture: Data?

    public init(id: UUID, runID: RunID, requestID: String, toolName: String,
                title: String, detail: String, target: String, expiresAt: Date,
                turnScopeFolder: String? = nil, openablePath: String? = nil, handsOverScreen: Bool = false,
                asksForMissingFile: Bool = false, screenPicture: Data? = nil) {
        self.id = id; self.runID = runID; self.requestID = requestID; self.toolName = toolName
        self.title = title; self.detail = detail; self.target = target; self.expiresAt = expiresAt
        self.turnScopeFolder = turnScopeFolder
        self.openablePath = openablePath
        self.handsOverScreen = handsOverScreen
        self.asksForMissingFile = asksForMissingFile
        self.screenPicture = screenPicture
    }
}

/// One choice on a question card.
public struct ClaudeTextQuestionOption: Equatable, Sendable, Identifiable {
    public let label: String
    public let detail: String
    public var id: String { label }
    public init(label: String, detail: String) { self.label = label; self.detail = detail }
}

/// A question the bot asks the user through the CLI's question tool,
/// shown above the composer: up to six choices, free text, or a secret. One
/// tool call may ask several in turn; `position` and `count` say where this
/// one stands. Answered through `answerUserQuestion`; gone when the turn ends
/// or the card expires.
public struct ClaudeTextQuestion: Equatable, Sendable, Identifiable {
    public static let maximumOptions = 6
    public let id: UUID
    public let runID: RunID
    public let requestID: String
    public let header: String
    public let prompt: String
    public let options: [ClaudeTextQuestionOption]
    public let allowsMultiple: Bool
    /// The question asks for a password, token or key: the card masks what
    /// the user types and the record never keeps it.
    public let isSecret: Bool
    public let position: Int
    public let count: Int
    public let expiresAt: Date

    public init(id: UUID, runID: RunID, requestID: String, header: String, prompt: String,
                options: [ClaudeTextQuestionOption], allowsMultiple: Bool, isSecret: Bool,
                position: Int, count: Int, expiresAt: Date) {
        self.id = id; self.runID = runID; self.requestID = requestID; self.header = header; self.prompt = prompt
        self.options = options; self.allowsMultiple = allowsMultiple; self.isSecret = isSecret
        self.position = position; self.count = count; self.expiresAt = expiresAt
    }

    /// Whether a question reads as asking for a secret, by its own words.
    /// Whole words only, and "token" in the singular: since a secret card may
    /// carry the bot's choices (Claude Code 2.1.282 requires them), the words
    /// alone decide, and an ordinary question about the model's context tokens
    /// or a secretary must not mask what the user types.
    public static func asksForASecret(header: String, prompt: String) -> Bool {
        (header + " " + prompt).range(of: #"\b(passwords?|passphrases?|secrets?|token|api ?keys?|credentials?|private keys?)\b"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// What the user answered: the chosen labels, typed text, or both.
public struct ClaudeTextQuestionAnswer: Equatable, Sendable {
    public let chosen: [String]
    public let text: String?
    public init(chosen: [String] = [], text: String? = nil) { self.chosen = chosen; self.text = text }
    public var typed: String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isEmpty: Bool { chosen.isEmpty && typed.isEmpty }
    /// The one string the tool's answer map takes for a question.
    public var value: String {
        var parts = chosen
        if !typed.isEmpty { parts.append(typed) }
        return parts.joined(separator: ", ")
    }
}

public enum ClaudeTextTurnProgress: Equatable, Sendable {
    case stage(ClaudeTextTurnStage)
    /// A work turn asks before a consequential action; the card waits for the user.
    case approvalRequired(ClaudeTextApproval)
    /// The card was answered, expired, withdrawn by the CLI or ended with the turn.
    case approvalResolved(id: UUID)
    /// The bot asks the user a question; the card waits for the user.
    case questionAsked(ClaudeTextQuestion)
    /// The question was answered, dismissed, expired or ended with the turn.
    case questionResolved(id: UUID)
    /// One short line of what the bot is doing on the Mac ("Read notes.md").
    case activity(String)
    /// What Control this Mac last saw of the user's screen, a PNG or JPEG, for
    /// the watch pane's preview. Shown from memory, never saved.
    case screenPicture(Data)
    /// The reply's bubbles settled so far, in order (a short first line
    /// at once, beats, then the answer whole). Each list extends the last; the
    /// partial text behind them is checkpointed but never painted.
    case bubbles([String])
    /// Bounded context selected by OpenBots. Preparation does not prove dispatch.
    case contextPrepared(ClaudeContextDisclosure)
    /// Startup metadata only; the CLI may later reject or remap this model.
    case modelObserved(requested: String, observed: String)
    /// Acknowledged successful result.modelUsage, emitted only after final save.
    case modelConfirmed(requested: String, observed: String)
    case userMessageSaved(Message)
    /// Committed provider output or a locally rendered system reply. The message
    /// author/provenance distinguishes them; this callback is not provider proof.
    case assistantMessageSaved(Message)
    /// The bot's reply hired a teammate: saved, with its own chat,
    /// and in the team when the hire came from one. Nothing is selected.
    case teammateHired(TeammateHire)
    /// The one app-authored line naming this reply's hires and refusals,
    /// saved after the reply however the turn ended. Not a Claude reply.
    case hireNoteSaved(Message)
    /// The one app-authored line naming this reply's workers, saved after the
    /// reply however the turn ended.
    case workerNoteSaved(Message)
    /// A new bot set itself up: its profile and switches are saved.
    case selfSetUp(teammateID: TeammateID, BotSelfSetup)
    /// The one app-authored line saying what the new bot became, saved after
    /// the reply however the turn ended.
    case selfSetupNoteSaved(Message)
    /// The workers this reply started, to run now that the reply is saved
    /// whole. Sent only for a completed reply; the caller runs each one and
    /// wakes the bot with its result.
    case workersStarted([TeammateWorker])
}

public enum ClaudeTextTurnProblem: Equatable, Sendable {
    case unavailable
    case busy
    case attachmentsNotSupported
    case invalidInput
    case modelUnavailable
    case effortUnavailable
    case contextWindowUnavailable
    case contextTooLarge
    case contextUnavailable
    case contextChanged
    case memoryPublicationNotReady
    case memoryAcknowledgementPending
    case setupRequired
    case subscriptionNotVerified
    case managedPolicyPresentOrUnknown
    case runtimeUnavailable
    case invalidResponse
    case timedOut
    case persistenceFailed
    /// A granted turn used every round of tool calls the command allowed and
    /// still had not answered. Neither the connection nor the provider failed.
    case turnLimitReached
    /// The same on a turn with Control this Mac, whose rounds are on the
    /// user's Mac: the user did not renew them, its card went unanswered, or
    /// the reply reached the most calls one window of rounds may make, where
    /// no card is offered. Said apart,
    /// because the sentence for a web turn names web tool calls.
    case macControlRoundsUsedUp
    /// A resumed turn named a session the CLI no longer has. The
    /// stored id is dropped; the next message starts fresh.
    case sessionLost
    /// The bot decided not to answer this turn. Nothing failed: not the app,
    /// not the connection, not the provider. Whatever it had already said is
    /// kept, and nothing is resent.
    case declined
}

/// What the parser refused, when a turn failed on the wire: the diagnostic code
/// and the Claude Code version that sent the frame. The person reads both,
/// because a CLI update is the usual cause and the version says so.
public struct ClaudeTextRefusedFrame: Equatable, Sendable {
    public let code: TextTurnDiagnosticCode
    public let claudeCodeVersion: String?
    public init(code: TextTurnDiagnosticCode, claudeCodeVersion: String?) {
        self.code = code; self.claudeCodeVersion = claudeCodeVersion
    }
}

public enum ClaudeTextTurnOutcome: Equatable, Sendable {
    case completed
    case stopped
    case failed(ClaudeTextTurnProblem, refusedFrame: ClaudeTextRefusedFrame? = nil)
}

public struct ClaudeTextTurnResult: Equatable, Sendable {
    public let outcome: ClaudeTextTurnOutcome
    public let savedUserMessage: Message?
    public let savedReplyMessage: Message?

    public init(outcome: ClaudeTextTurnOutcome, savedUserMessage: Message? = nil,
                savedReplyMessage: Message? = nil) {
        self.outcome = outcome
        self.savedUserMessage = savedUserMessage
        self.savedReplyMessage = savedReplyMessage
    }
}

/// One user click on a staged handoff card. Old records are never an outbox.
public struct HandoffLegSubmission: Equatable, Sendable {
    public let handoffID: HandoffID
    public init(handoffID: HandoffID) { self.handoffID = handoffID }
}

/// The lead compiling one finished leg for the user: the member's
/// reply is the input the lead answers, and the answer is the room's.
public struct HandoffReportSubmission: Equatable, Sendable {
    public let handoffID: HandoffID
    public init(handoffID: HandoffID) { self.handoffID = handoffID }
}

/// A worker's end, to wake the bot that started it.
public struct WorkerResultSubmission: Equatable, Sendable {
    public let worker: TeammateWorker
    public let result: TeammateWorkerResult
    public init(worker: TeammateWorker, result: TeammateWorkerResult) {
        self.worker = worker; self.result = result
    }
}

public protocol ClaudeTextReplyServing: Sendable {
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult
    /// The user's answer to one card. False when the card is gone.
    func decideApproval(id: UUID, allow: Bool) async -> Bool
    /// Approve one card and let the same tool work in the same folder for the
    /// rest of this turn without asking again. False when the card is gone or
    /// offers no such scope. Never outlives the turn.
    func allowApprovalForTurn(id: UUID) async -> Bool
    /// Choose the File… on a missing-file card: the file the user picked goes in the
    /// missing one's place. False when the card is gone or the file cannot be
    /// taken; the card then stays up.
    func replaceMissingFile(id: UUID, with url: URL) async -> Bool
    /// The user's answer to one question, or nil to dismiss it. False when the
    /// question is gone.
    func answerUserQuestion(id: UUID, answer: ClaudeTextQuestionAnswer?) async -> Bool
    func messageProvenance(conversationID: ConversationID,
                           messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance]
    /// The last saved reply's recorded execution evidence for a conversation, if any.
    func latestExecutionEvidence(conversationID: ConversationID) async throws -> ClaudeExecutionEvidence?
    /// Runs the receiver's leg of a staged handoff. The brief is saved as a
    /// message authored by the sender; the reply is the receiver's.
    func sendHandoffLeg(_ submission: HandoffLegSubmission,
                        onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult
    /// Runs the lead on a member's finished leg. The report is saved as a
    /// work-channel message authored by the member; the reply is the lead's,
    /// for the user.
    func sendHandoffReport(_ submission: HandoffReportSubmission,
                           onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult
    /// Wakes a worker's holder with the worker's result. The result is saved
    /// as the app's own work note; the holder's answer is for the person.
    func sendWorkerResult(_ submission: WorkerResultSubmission,
                          onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult
    /// Leaves one line in a chat, as the app: what a quit did to a worker.
    /// False when it could not be saved.
    func saveWorkerLine(_ line: String, conversationID: ConversationID) async -> Bool
    /// The same line, handed back as saved so the open chat can show it at
    /// once (for example a worker the user's Stop ended). Nil when not saved.
    func saveWorkerNote(_ line: String, conversationID: ConversationID) async -> Message?
}

public extension ClaudeTextReplyServing {
    func sendWorkerResult(_ submission: WorkerResultSubmission,
                          onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        .init(outcome: .failed(.unavailable))
    }
    func saveWorkerLine(_ line: String, conversationID: ConversationID) async -> Bool { false }
    /// Saves through `saveWorkerLine`; a service that cannot hand the row
    /// back shows it on the next read of the chat.
    func saveWorkerNote(_ line: String, conversationID: ConversationID) async -> Message? {
        _ = await saveWorkerLine(line, conversationID: conversationID)
        return nil
    }
    func sendHandoffReport(_ submission: HandoffReportSubmission,
                           onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        .init(outcome: .failed(.unavailable))
    }
    func latestExecutionEvidence(conversationID: ConversationID) async throws -> ClaudeExecutionEvidence? { nil }
    func decideApproval(id: UUID, allow: Bool) async -> Bool { false }
    func allowApprovalForTurn(id: UUID) async -> Bool { false }
    func replaceMissingFile(id: UUID, with url: URL) async -> Bool { false }
    func answerUserQuestion(id: UUID, answer: ClaudeTextQuestionAnswer?) async -> Bool { false }
    func sendHandoffLeg(_ submission: HandoffLegSubmission,
                        onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        .init(outcome: .failed(.unavailable))
    }
}
