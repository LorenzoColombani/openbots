import Foundation

public struct WorkInput: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let sequence: Int64
    public let text: String
    public let attachmentIDs: [AttachmentID]

    public init(
        messageID: MessageID,
        sequence: Int64,
        text: String,
        attachmentIDs: [AttachmentID] = []
    ) throws {
        guard sequence > 0 else {
            throw DomainValidationError.invalid(field: "input sequence", reason: "must be positive")
        }
        guard !text.isEmpty || !attachmentIDs.isEmpty else {
            throw DomainValidationError.empty(field: "work input")
        }
        self.messageID = messageID
        self.sequence = sequence
        self.text = text
        self.attachmentIDs = attachmentIDs
    }
}

public struct WorkRequest: Codable, Equatable, Sendable {
    public let runID: RunID
    public let teammateID: TeammateID
    public let conversationID: ConversationID
    public let initiatingMessageID: MessageID
    public let selectedProjectID: ProjectID?
    public let profileRevision: UInt64
    public let initialInput: WorkInput
    public let submittedAt: Date
    /// Nil for existing fixtures and other executor adapters.
    public let textTurnIdentity: TextTurnIdentity?
    /// App-selected context provenance only, never copied prompt or memory bodies.
    /// Older requests decode without this receipt and retain their recorded scope.
    public let readContextReceipt: ReadContextReceipt?

    public init(
        runID: RunID,
        teammateID: TeammateID,
        conversationID: ConversationID,
        initiatingMessageID: MessageID,
        selectedProjectID: ProjectID? = nil,
        profileRevision: UInt64,
        initialInput: WorkInput,
        submittedAt: Date,
        textTurnIdentity: TextTurnIdentity? = nil,
        readContextReceipt: ReadContextReceipt? = nil
    ) throws {
        guard profileRevision > 0 else {
            throw DomainValidationError.invalid(field: "profile revision", reason: "must be positive")
        }
        guard initiatingMessageID == initialInput.messageID else {
            throw DomainValidationError.invalid(
                field: "initiating message",
                reason: "must match the initial input message"
            )
        }
        self.runID = runID
        self.teammateID = teammateID
        self.conversationID = conversationID
        self.initiatingMessageID = initiatingMessageID
        self.selectedProjectID = selectedProjectID
        self.profileRevision = profileRevision
        self.initialInput = initialInput
        self.submittedAt = submittedAt
        self.textTurnIdentity = textTurnIdentity
        self.readContextReceipt = readContextReceipt
    }
}

public struct SteeringInput: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let sequence: Int64
    public let text: String
    public let attachmentIDs: [AttachmentID]
    public let submittedAt: Date

    public init(
        messageID: MessageID,
        sequence: Int64,
        text: String,
        attachmentIDs: [AttachmentID] = [],
        submittedAt: Date
    ) throws {
        let input = try WorkInput(
            messageID: messageID,
            sequence: sequence,
            text: text,
            attachmentIDs: attachmentIDs
        )
        self.messageID = input.messageID
        self.sequence = input.sequence
        self.text = input.text
        self.attachmentIDs = input.attachmentIDs
        self.submittedAt = submittedAt
    }
}

public enum SteeringSubmissionState: String, Codable, Sendable {
    /// The input was handed to the runtime transport; acceptance requires an acknowledgement event.
    case submitted
}

public struct SteeringSubmission: Codable, Equatable, Sendable {
    public let runID: RunID
    public let messageID: MessageID
    public let sequence: Int64
    public let state: SteeringSubmissionState

    public init(runID: RunID, messageID: MessageID, sequence: Int64) {
        self.runID = runID
        self.messageID = messageID
        self.sequence = sequence
        self.state = .submitted
    }
}

public enum WorkWaitReason: String, Codable, Sendable {
    case question
    case authentication
    case macOSPermission
    case exactApproval
}

public struct WorkFailure: Codable, Equatable, Sendable {
    public let code: String
    public let userMessage: String
    public let isRecoverable: Bool

    public init(code: String, userMessage: String, isRecoverable: Bool) throws {
        self.code = try DomainText.required(code, field: "failure code", maximum: 120)
        self.userMessage = try DomainText.required(userMessage, field: "failure message", maximum: 2_000)
        self.isRecoverable = isRecoverable
    }
}

public enum WorkEvent: Equatable, Sendable {
    case started
    case inputAcknowledged(messageID: MessageID, sequence: Int64)
    case conversationDelta(messageID: MessageID, text: String)
    case waitingForUser(WorkWaitReason)
    case artifactPublished(ArtifactID)
    case failed(WorkFailure)
    case finished
}

public enum WorkRunState: String, Codable, Sendable {
    case queued
    case starting
    case running
    case waitingForUser
    case stopping
    case succeeded
    case failed
    case interrupted

    public func applying(_ event: WorkRunEvent) throws -> Self {
        switch (self, event) {
        case (.queued, .begin): .starting
        case (.starting, .started): .running
        case (.running, .waitForUser): .waitingForUser
        case (.waitingForUser, .resume): .running
        case (.running, .requestStop), (.waitingForUser, .requestStop): .stopping
        case (.running, .finish), (.waitingForUser, .finish): .succeeded
        case (.queued, .fail), (.starting, .fail), (.running, .fail), (.waitingForUser, .fail), (.stopping, .fail): .failed
        case (.starting, .interrupt), (.running, .interrupt), (.waitingForUser, .interrupt), (.stopping, .interrupt): .interrupted
        default:
            throw LifecycleTransitionError.illegalTransition(
                entity: "work run",
                state: rawValue,
                event: event.rawValue
            )
        }
    }
}

public enum WorkRunEvent: String, Sendable {
    case begin
    case started
    case waitForUser
    case resume
    case requestStop
    case finish
    case fail
    case interrupt
}

/// Executor implementations plug in behind this boundary. Domain and UI do not choose a shell architecture.
public protocol TeammateExecutor: Sendable {
    func start(_ request: WorkRequest) async throws
    func steer(_ input: SteeringInput, into runID: RunID) async throws -> SteeringSubmission
    func events(for runID: RunID) async -> AsyncThrowingStream<WorkEvent, any Error>
    func requestStop(runID: RunID) async throws
}
