import Foundation
import OpenBotsDomain
import OpenBotsSecurity

public enum ConversationCardFixtureServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicateCardID(ConversationCardID)
    case questionCardNotFound(ConversationCardID)
    case connectorCardNotFound(ConversationCardID)
    case secretCardNotFound(ConversationCardID)
    case secretSubmissionInProgress(ConversationCardID)
    case secretStoreFailed(receiptID: SecretReceiptID)

    public var description: String {
        switch self {
        case let .duplicateCardID(cardID):
            "Fixture card identity \(cardID) is duplicated."
        case let .questionCardNotFound(cardID):
            "Question fixture card \(cardID) is unavailable."
        case let .connectorCardNotFound(cardID):
            "Connector fixture card \(cardID) is unavailable."
        case let .secretCardNotFound(cardID):
            "Secret fixture card \(cardID) is unavailable."
        case let .secretSubmissionInProgress(cardID):
            "Secret fixture card \(cardID) already has a store operation in progress."
        case let .secretStoreFailed(receiptID):
            "The preview secret store failed. Receipt: \(receiptID)."
        }
    }
}

public struct PreviewSecretOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case store
    }

    public let cardID: ConversationCardID
    public let receiptID: SecretReceiptID
    public let kind: Kind
    public let byteCount: Int

    public init(
        cardID: ConversationCardID,
        receiptID: SecretReceiptID,
        kind: Kind,
        byteCount: Int
    ) {
        self.cardID = cardID
        self.receiptID = receiptID
        self.kind = kind
        self.byteCount = byteCount
    }
}

/// A deterministic, executor-independent card service for the preview UI.
///
/// The concrete `InMemoryKeychainClient` parameter is intentional: production
/// Keychain implementations cannot be injected into this fixture service. The
/// service owns no runtime, network, connector-authentication, or filesystem
/// dependency and never returns submitted secret bytes.
public actor ConversationCardFixtureService {
    public static let disclosure =
        "Local card preview — no provider authentication, connector network, Claude runtime, or tool ran."

    private let keychain: InMemoryKeychainClient
    private let uuidGenerator: any UUIDGenerator
    private var questionCards: [ConversationCardID: InlineQuestionCard]
    private var connectorCards: [ConversationCardID: ConnectorSetupCard]
    private var secretCards: [ConversationCardID: SecretEntryCard]
    private var secretOperations: [PreviewSecretOperation] = []
    private var secretSubmissionsInFlight: Set<ConversationCardID> = []

    public init(
        keychain: InMemoryKeychainClient,
        questionCards: [InlineQuestionCard] = [],
        connectorCards: [ConnectorSetupCard] = [],
        secretCards: [SecretEntryCard] = [],
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()
    ) throws {
        let allIDs = questionCards.map(\.id)
            + connectorCards.map(\.id)
            + secretCards.map(\.id)
        guard Set(allIDs).count == allIDs.count else {
            let duplicated = allIDs.first { candidate in
                allIDs.filter { $0 == candidate }.count > 1
            }!
            throw ConversationCardFixtureServiceError.duplicateCardID(duplicated)
        }
        self.keychain = keychain
        self.uuidGenerator = uuidGenerator
        self.questionCards = Dictionary(
            uniqueKeysWithValues: questionCards.map { ($0.id, $0) }
        )
        self.connectorCards = Dictionary(
            uniqueKeysWithValues: connectorCards.map { ($0.id, $0) }
        )
        self.secretCards = Dictionary(
            uniqueKeysWithValues: secretCards.map { ($0.id, $0) }
        )
    }

    public func questionCard(id: ConversationCardID) throws -> InlineQuestionCard {
        guard let card = questionCards[id] else {
            throw ConversationCardFixtureServiceError.questionCardNotFound(id)
        }
        return card
    }

    public func answerQuestion(
        cardID: ConversationCardID,
        route: ConversationCardRoute,
        answer: QuestionCardAnswer
    ) throws -> InlineQuestionCard {
        guard var card = questionCards[cardID] else {
            throw ConversationCardFixtureServiceError.questionCardNotFound(cardID)
        }
        try card.answer(answer, using: route)
        questionCards[cardID] = card
        return card
    }

    public func declineQuestion(
        cardID: ConversationCardID,
        route: ConversationCardRoute
    ) throws -> InlineQuestionCard {
        guard var card = questionCards[cardID] else {
            throw ConversationCardFixtureServiceError.questionCardNotFound(cardID)
        }
        try card.decline(using: route)
        questionCards[cardID] = card
        return card
    }

    public func connectorCard(id: ConversationCardID) throws -> ConnectorSetupCard {
        guard let card = connectorCards[id] else {
            throw ConversationCardFixtureServiceError.connectorCardNotFound(id)
        }
        return card
    }

    /// Simulates only the preview's "Reopen" intent. It does not launch a
    /// browser, authenticate an account, install a connector, grant a bot, or
    /// approve an action.
    public func reopenProviderAuthentication(
        cardID: ConversationCardID,
        route: ConversationCardRoute
    ) throws -> ConnectorSetupCard {
        guard var card = connectorCards[cardID] else {
            throw ConversationCardFixtureServiceError.connectorCardNotFound(cardID)
        }
        try card.recordProviderAuthenticationAttempt(
            ProviderAuthenticationAttemptID(uuidGenerator.next()),
            using: route
        )
        connectorCards[cardID] = card
        return card
    }

    public func secretCard(id: ConversationCardID) throws -> SecretEntryCard {
        guard let card = secretCards[id] else {
            throw ConversationCardFixtureServiceError.secretCardNotFound(id)
        }
        return card
    }

    /// Stores through the OpenBots-owned, purpose-typed preview connector
    /// reference. The result exposes only an opaque presence receipt.
    public func submitSecret(
        cardID: ConversationCardID,
        route: ConversationCardRoute,
        secret: Data
    ) async throws -> SecretEntryCard {
        guard var card = secretCards[cardID] else {
            throw ConversationCardFixtureServiceError.secretCardNotFound(cardID)
        }
        try card.ensureCanSubmit(using: route)
        guard secretSubmissionsInFlight.insert(cardID).inserted else {
            throw ConversationCardFixtureServiceError.secretSubmissionInProgress(cardID)
        }
        defer { secretSubmissionsInFlight.remove(cardID) }

        let receiptID = SecretReceiptID(uuidGenerator.next())
        guard !secret.isEmpty else {
            try card.markFailed(receiptID: receiptID, using: route)
            secretCards[cardID] = card
            throw ConversationCardActionError.emptySecret
        }

        let reference = KeychainItemReference.previewConnectorSecret(
            connectorID: card.connectorID.rawValue,
            bindingID: card.bindingID.rawValue
        )
        do {
            try await keychain.store(secret, at: reference)
            try card.markPresent(receiptID: receiptID, using: route)
        } catch let error as ConversationCardActionError {
            throw error
        } catch {
            try card.markFailed(receiptID: receiptID, using: route)
            secretCards[cardID] = card
            throw ConversationCardFixtureServiceError.secretStoreFailed(
                receiptID: receiptID
            )
        }

        secretCards[cardID] = card
        secretOperations.append(
            PreviewSecretOperation(
                cardID: cardID,
                receiptID: receiptID,
                kind: .store,
                byteCount: secret.count
            )
        )
        return card
    }

    public func recordedSecretOperations() -> [PreviewSecretOperation] {
        secretOperations
    }
}
