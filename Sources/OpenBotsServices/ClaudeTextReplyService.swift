import Foundation
import OpenBotsDomain

/// One explicit new user action. Old saved messages are never an outbox.
public struct ClaudeTextTurnSubmission: Equatable, Sendable {
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let userMessageID: MessageID
    public let text: String
    public let attachmentIDs: [AttachmentID]

    public init(conversationID: ConversationID, teammateID: TeammateID,
                userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID] = []) {
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.userMessageID = userMessageID
        self.text = text
        self.attachmentIDs = attachmentIDs
    }
}

public enum ClaudeTextTurnStage: Equatable, Sendable {
    case selectingContext
    case checkingReadiness
    case starting
    case responding
    case saving
}

public enum ClaudeTextTurnProgress: Equatable, Sendable {
    case stage(ClaudeTextTurnStage)
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
}

public enum ClaudeTextTurnOutcome: Equatable, Sendable {
    case completed
    case stopped
    case failed(ClaudeTextTurnProblem)
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

public protocol ClaudeTextReplyServing: Sendable {
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult
    func messageProvenance(conversationID: ConversationID,
                           messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance]
}
