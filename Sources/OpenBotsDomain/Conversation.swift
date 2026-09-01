import Foundation

public enum ConversationKind: Codable, Equatable, Sendable {
    case direct(teammateID: TeammateID)
    case project(projectID: ProjectID)
    case team(teamID: TeamID)
}

public enum ConversationLifecycle: String, Codable, Sendable {
    case active
    case archived
}

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationID
    public let kind: ConversationKind
    public var title: String?
    public var lifecycle: ConversationLifecycle
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConversationID,
        kind: ConversationKind,
        title: String? = nil,
        lifecycle: ConversationLifecycle = .active,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(
                field: "conversation timestamps",
                reason: "updatedAt cannot precede createdAt"
            )
        }
        self.id = id
        self.kind = kind
        self.title = try DomainText.optional(title, field: "conversation title", maximum: 160)
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MessageAuthor: Codable, Equatable, Sendable {
    case user
    case teammate(TeammateID)
    case system
}

public enum OutputClass: String, Codable, Sendable {
    case conversation
    case workAudit
    case artifact
}

public enum MessageDeliveryState: String, Codable, Sendable {
    /// Durable locally, but not yet accepted by a runtime process.
    case pending
    /// Waiting for a process because no live process can safely accept it.
    case queued
    /// Written to the live process; acceptance is not yet proven.
    case submitted
    /// Correlated runtime replay proved same-process acceptance.
    case acknowledged
    /// Accepted before an interrupted/unknown terminal outcome.
    case outcomeUnknown
    case completed
    case failed

    public func applying(_ event: MessageDeliveryEvent) throws -> Self {
        switch (self, event) {
        case (.pending, .queue): .queued
        case (.pending, .submit), (.queued, .submit): .submitted
        case (.submitted, .acknowledge): .acknowledged
        case (.acknowledged, .markOutcomeUnknown): .outcomeUnknown
        case (.acknowledged, .complete), (.outcomeUnknown, .complete): .completed
        case (.pending, .fail), (.queued, .fail), (.submitted, .fail), (.acknowledged, .fail), (.outcomeUnknown, .fail): .failed
        default:
            throw LifecycleTransitionError.illegalTransition(
                entity: "message delivery",
                state: rawValue,
                event: event.rawValue
            )
        }
    }
}

public enum MessageDeliveryEvent: String, Sendable {
    case queue
    case submit
    case acknowledge
    case markOutcomeUnknown
    case complete
    case fail
}

public enum MessagePartContent: Codable, Equatable, Sendable {
    case text(String)
    case attachment(AttachmentID)
    case artifact(ArtifactID)
    case status(String)
}

public struct MessagePart: Codable, Equatable, Sendable, Identifiable {
    public let id: MessagePartID
    public let ordinal: Int
    public let content: MessagePartContent

    public init(id: MessagePartID, ordinal: Int, content: MessagePartContent) throws {
        guard ordinal >= 0 else {
            throw DomainValidationError.invalid(field: "message part ordinal", reason: "cannot be negative")
        }
        if case let .text(text) = content, text.isEmpty {
            throw DomainValidationError.empty(field: "message text")
        }
        self.id = id
        self.ordinal = ordinal
        self.content = content
    }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public let id: MessageID
    public let conversationID: ConversationID
    public let sequence: Int64
    public let author: MessageAuthor
    public let outputClass: OutputClass
    public var deliveryState: MessageDeliveryState
    public var parts: [MessagePart]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: MessageID,
        conversationID: ConversationID,
        sequence: Int64,
        author: MessageAuthor,
        outputClass: OutputClass = .conversation,
        deliveryState: MessageDeliveryState,
        parts: [MessagePart],
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard sequence > 0 else {
            throw DomainValidationError.invalid(field: "message sequence", reason: "must be positive")
        }
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(field: "message timestamps", reason: "updatedAt cannot precede createdAt")
        }
        guard !parts.isEmpty else { throw DomainValidationError.empty(field: "message parts") }
        let ordinals = parts.map(\.ordinal)
        guard Set(ordinals).count == ordinals.count else {
            throw DomainValidationError.invalid(field: "message parts", reason: "ordinals must be unique")
        }
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.author = author
        self.outputClass = outputClass
        self.deliveryState = deliveryState
        self.parts = parts.sorted { $0.ordinal < $1.ordinal }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
