import Foundation

private func decodeCardUUID<T: OpenBotsIdentifier>(
    _ type: T.Type,
    from decoder: any Decoder
) throws -> T {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let uuid = UUID(uuidString: value) else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a UUID string for \(T.self)."
        )
    }
    return T(uuid)
}

private func encodeCardUUID<T: OpenBotsIdentifier>(
    _ value: T,
    to encoder: any Encoder
) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.persistedValue)
}

public struct ConversationCardID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

public struct ConversationCardChoiceID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

public struct ConversationCardRouteID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

public struct ConnectorID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

public struct ConnectorBindingID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

public struct ProviderAuthenticationAttemptID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

public struct SecretReceiptID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        self = try decodeCardUUID(Self.self, from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeCardUUID(self, to: encoder)
    }
}

/// A frozen route binds a UI action to one exact card revision. Card actions
/// reject both a route for another card and a superseded route for this card.
public struct ConversationCardRoute: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationCardRouteID
    public let conversationID: ConversationID
    public let messageID: MessageID
    public let messagePartID: MessagePartID
    public let cardID: ConversationCardID

    public init(
        id: ConversationCardRouteID,
        conversationID: ConversationID,
        messageID: MessageID,
        messagePartID: MessagePartID,
        cardID: ConversationCardID
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.messagePartID = messagePartID
        self.cardID = cardID
    }
}

public enum ConversationCardActionError: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongCard(expected: ConversationCardID, actual: ConversationCardID)
    case wrongConversation(expected: ConversationID, actual: ConversationID)
    case wrongMessage(expected: MessageID, actual: MessageID)
    case wrongMessagePart(expected: MessagePartID, actual: MessagePartID)
    case staleRoute(expected: ConversationCardRouteID, actual: ConversationCardRouteID)
    case alreadyResolved(cardID: ConversationCardID)
    case invalidChoice(ConversationCardChoiceID)
    case freeTextDisabled
    case emptyFreeText
    case secretAlreadyPresent(cardID: ConversationCardID)
    case emptySecret

    public var description: String {
        switch self {
        case let .wrongCard(expected, actual):
            "Card action targeted \(actual), but this card is \(expected)."
        case let .wrongConversation(expected, actual):
            "Card action targeted conversation \(actual), but expected \(expected)."
        case let .wrongMessage(expected, actual):
            "Card action targeted message \(actual), but expected \(expected)."
        case let .wrongMessagePart(expected, actual):
            "Card action targeted message part \(actual), but expected \(expected)."
        case let .staleRoute(expected, actual):
            "Card action route \(actual) is stale; expected \(expected)."
        case let .alreadyResolved(cardID):
            "Card \(cardID) has already been resolved."
        case let .invalidChoice(choiceID):
            "Choice \(choiceID) does not belong to this question."
        case .freeTextDisabled:
            "This question does not accept a free-text answer."
        case .emptyFreeText:
            "A free-text answer cannot be empty."
        case let .secretAlreadyPresent(cardID):
            "Card \(cardID) already has an opaque secret-presence receipt."
        case .emptySecret:
            "A secret cannot be empty."
        }
    }
}

private func validate(
    route: ConversationCardRoute,
    expected: ConversationCardRoute
) throws {
    guard route.cardID == expected.cardID else {
        throw ConversationCardActionError.wrongCard(
            expected: expected.cardID,
            actual: route.cardID
        )
    }
    guard route.conversationID == expected.conversationID else {
        throw ConversationCardActionError.wrongConversation(
            expected: expected.conversationID,
            actual: route.conversationID
        )
    }
    guard route.messageID == expected.messageID else {
        throw ConversationCardActionError.wrongMessage(
            expected: expected.messageID,
            actual: route.messageID
        )
    }
    guard route.messagePartID == expected.messagePartID else {
        throw ConversationCardActionError.wrongMessagePart(
            expected: expected.messagePartID,
            actual: route.messagePartID
        )
    }
    guard route.id == expected.id else {
        throw ConversationCardActionError.staleRoute(
            expected: expected.id,
            actual: route.id
        )
    }
}

public struct QuestionCardChoice: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationCardChoiceID
    public let label: String

    public init(id: ConversationCardChoiceID, label: String) throws {
        self.id = id
        self.label = try DomainText.required(
            label,
            field: "question choice label",
            maximum: 160
        )
    }
}

public enum QuestionCardAnswer: Codable, Equatable, Sendable {
    case choice(ConversationCardChoiceID)
    case freeText(String)
}

public enum QuestionCardResolution: Codable, Equatable, Sendable {
    case answered(QuestionCardAnswer)
    case declined
}

public struct InlineQuestionCard: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationCardID
    public let prompt: String
    public let choices: [QuestionCardChoice]
    public let allowsFreeText: Bool
    public let route: ConversationCardRoute
    public private(set) var resolution: QuestionCardResolution?

    public init(
        id: ConversationCardID,
        prompt: String,
        choices: [QuestionCardChoice],
        allowsFreeText: Bool,
        conversationID: ConversationID,
        messageID: MessageID,
        messagePartID: MessagePartID,
        routeID: ConversationCardRouteID
    ) throws {
        guard (1...6).contains(choices.count) else {
            throw DomainValidationError.invalid(
                field: "question choices",
                reason: "must contain between 1 and 6 choices"
            )
        }
        guard Set(choices.map(\.id)).count == choices.count else {
            throw DomainValidationError.invalid(
                field: "question choices",
                reason: "choice identities must be unique"
            )
        }
        self.id = id
        self.prompt = try DomainText.required(
            prompt,
            field: "question prompt",
            maximum: 2_000
        )
        self.choices = choices
        self.allowsFreeText = allowsFreeText
        route = ConversationCardRoute(
            id: routeID,
            conversationID: conversationID,
            messageID: messageID,
            messagePartID: messagePartID,
            cardID: id
        )
        resolution = nil
    }

    public mutating func answer(
        _ answer: QuestionCardAnswer,
        using submittedRoute: ConversationCardRoute
    ) throws {
        try validatePendingAction(using: submittedRoute)
        switch answer {
        case let .choice(choiceID):
            guard choices.contains(where: { $0.id == choiceID }) else {
                throw ConversationCardActionError.invalidChoice(choiceID)
            }
            resolution = .answered(.choice(choiceID))
        case let .freeText(value):
            guard allowsFreeText else {
                throw ConversationCardActionError.freeTextDisabled
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ConversationCardActionError.emptyFreeText
            }
            guard trimmed.count <= 2_000 else {
                throw DomainValidationError.tooLong(
                    field: "question free-text answer",
                    maximum: 2_000
                )
            }
            resolution = .answered(.freeText(trimmed))
        }
    }

    public mutating func decline(using submittedRoute: ConversationCardRoute) throws {
        try validatePendingAction(using: submittedRoute)
        resolution = .declined
    }

    private func validatePendingAction(
        using submittedRoute: ConversationCardRoute
    ) throws {
        guard resolution == nil else {
            throw ConversationCardActionError.alreadyResolved(cardID: id)
        }
        try validate(
            route: submittedRoute,
            expected: route
        )
    }
}

public enum ConnectorInstallationState: String, Codable, Sendable {
    case notInstalled
    case installed
    case failed
}

public enum ConnectorAccountAuthenticationState: String, Codable, Sendable {
    case notAuthenticated
    case authenticated
    case failed
}

public enum ConnectorPerBotGrantState: String, Codable, Sendable {
    case notGranted
    case granted
    case revoked
}

public enum ConnectorPerActionApprovalState: String, Codable, Sendable {
    case notRequested
    case pending
    case approved
    case denied
}

/// These are deliberately independent dimensions. No one value implies or
/// mutates any other authorization layer.
public struct ConnectorSetupState: Codable, Equatable, Sendable {
    public var installation: ConnectorInstallationState
    public var accountAuthentication: ConnectorAccountAuthenticationState
    public var perBotGrant: ConnectorPerBotGrantState
    public var perActionApproval: ConnectorPerActionApprovalState

    public init(
        installation: ConnectorInstallationState,
        accountAuthentication: ConnectorAccountAuthenticationState,
        perBotGrant: ConnectorPerBotGrantState,
        perActionApproval: ConnectorPerActionApprovalState
    ) {
        self.installation = installation
        self.accountAuthentication = accountAuthentication
        self.perBotGrant = perBotGrant
        self.perActionApproval = perActionApproval
    }
}

public struct ConnectorSetupCard: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationCardID
    public let connectorID: ConnectorID
    public let providerName: String
    public let route: ConversationCardRoute
    public var state: ConnectorSetupState
    public private(set) var lastAuthenticationAttemptID: ProviderAuthenticationAttemptID?
    public private(set) var authenticationAttemptCount: UInt64

    public init(
        id: ConversationCardID,
        connectorID: ConnectorID,
        providerName: String,
        conversationID: ConversationID,
        messageID: MessageID,
        messagePartID: MessagePartID,
        routeID: ConversationCardRouteID,
        state: ConnectorSetupState
    ) throws {
        self.id = id
        self.connectorID = connectorID
        self.providerName = try DomainText.required(
            providerName,
            field: "connector provider name",
            maximum: 160
        )
        route = ConversationCardRoute(
            id: routeID,
            conversationID: conversationID,
            messageID: messageID,
            messagePartID: messagePartID,
            cardID: id
        )
        self.state = state
        lastAuthenticationAttemptID = nil
        authenticationAttemptCount = 0
    }

    /// Records only that the preview's provider-authentication action was
    /// requested. It neither authenticates an account nor changes installation,
    /// bot grant, or consequential-action approval state.
    public mutating func recordProviderAuthenticationAttempt(
        _ attemptID: ProviderAuthenticationAttemptID,
        using submittedRoute: ConversationCardRoute
    ) throws {
        try validate(
            route: submittedRoute,
            expected: route
        )
        lastAuthenticationAttemptID = attemptID
        authenticationAttemptCount += 1
    }
}

public enum SecretCardState: Codable, Equatable, Sendable {
    case absent
    case present(receiptID: SecretReceiptID)
    case failed(receiptID: SecretReceiptID)
}

public struct SecretEntryCard: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationCardID
    public let connectorID: ConnectorID
    public let bindingID: ConnectorBindingID
    public let label: String
    public let route: ConversationCardRoute
    public private(set) var state: SecretCardState

    public init(
        id: ConversationCardID,
        connectorID: ConnectorID,
        bindingID: ConnectorBindingID,
        label: String,
        conversationID: ConversationID,
        messageID: MessageID,
        messagePartID: MessagePartID,
        routeID: ConversationCardRouteID
    ) throws {
        self.id = id
        self.connectorID = connectorID
        self.bindingID = bindingID
        self.label = try DomainText.required(
            label,
            field: "secret label",
            maximum: 160
        )
        route = ConversationCardRoute(
            id: routeID,
            conversationID: conversationID,
            messageID: messageID,
            messagePartID: messagePartID,
            cardID: id
        )
        state = .absent
    }

    public mutating func markPresent(
        receiptID: SecretReceiptID,
        using submittedRoute: ConversationCardRoute
    ) throws {
        try ensureCanSubmit(using: submittedRoute)
        state = .present(receiptID: receiptID)
    }

    public mutating func markFailed(
        receiptID: SecretReceiptID,
        using submittedRoute: ConversationCardRoute
    ) throws {
        try ensureCanSubmit(using: submittedRoute)
        state = .failed(receiptID: receiptID)
    }

    public func ensureCanSubmit(
        using submittedRoute: ConversationCardRoute
    ) throws {
        if case .present = state {
            throw ConversationCardActionError.secretAlreadyPresent(cardID: id)
        }
        try validate(
            route: submittedRoute,
            expected: route
        )
    }
}
