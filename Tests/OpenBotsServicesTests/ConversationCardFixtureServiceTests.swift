import Foundation
import OpenBotsDomain
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private final class CardSequenceUUIDGenerator: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64

    init(startingAt: UInt64) {
        nextValue = startingAt
    }

    func next() -> UUID {
        lock.lock()
        defer {
            nextValue += 1
            lock.unlock()
        }
        return serviceCardUUID(nextValue)
    }
}

@Test("Fixture service resolves a question exactly once through its frozen route")
func fixtureQuestionResolution() async throws {
    let question = try makeFixtureQuestion()
    let service = try ConversationCardFixtureService(
        keychain: InMemoryKeychainClient(),
        questionCards: [question]
    )

    let resolved = try await service.answerQuestion(
        cardID: question.id,
        route: question.route,
        answer: .choice(question.choices[0].id)
    )
    #expect(resolved.resolution == .answered(.choice(question.choices[0].id)))

    await #expect(throws: ConversationCardActionError.self) {
        try await service.declineQuestion(
            cardID: question.id,
            route: question.route
        )
    }
}

@Test("Connector Reopen is a local attempt receipt and leaves every authorization axis unchanged")
func connectorReopenIsAttemptOnly() async throws {
    let connector = try makeConnectorCard()
    let keychain = InMemoryKeychainClient()
    let service = try ConversationCardFixtureService(
        keychain: keychain,
        connectorCards: [connector],
        uuidGenerator: CardSequenceUUIDGenerator(startingAt: 900)
    )

    let reopened = try await service.reopenProviderAuthentication(
        cardID: connector.id,
        route: connector.route
    )

    #expect(reopened.state == connector.state)
    #expect(reopened.state.installation == .notInstalled)
    #expect(reopened.state.accountAuthentication == .notAuthenticated)
    #expect(reopened.state.perBotGrant == .notGranted)
    #expect(reopened.state.perActionApproval == .notRequested)
    #expect(
        reopened.lastAuthenticationAttemptID
            == ProviderAuthenticationAttemptID(serviceCardUUID(900))
    )
    #expect(reopened.authenticationAttemptCount == 1)
    #expect(await keychain.recordedOperations().isEmpty)
}

@Test("Secret submission uses one purpose-typed fake store and never exposes sentinel material")
func secretSubmissionIsOpaqueAndPurposeTyped() async throws {
    let sentinel = "OPENBOTS-SECRET-SENTINEL-NEVER-DESCRIBE"
    let secret = Data(sentinel.utf8)
    let card = try makeSecretCard()
    let keychain = InMemoryKeychainClient()
    let service = try ConversationCardFixtureService(
        keychain: keychain,
        secretCards: [card],
        uuidGenerator: CardSequenceUUIDGenerator(startingAt: 910)
    )

    let wrongRoute = ConversationCardRoute(
        id: card.route.id,
        conversationID: ConversationID(serviceCardUUID(999)),
        messageID: card.route.messageID,
        messagePartID: card.route.messagePartID,
        cardID: card.id
    )
    var rejectedDescription = ""
    do {
        _ = try await service.submitSecret(
            cardID: card.id,
            route: wrongRoute,
            secret: secret
        )
        Issue.record("Expected the stale route to be rejected")
    } catch {
        rejectedDescription = String(describing: error)
    }
    #expect(rejectedDescription.contains(sentinel) == false)
    #expect(await keychain.recordedOperations().isEmpty)

    let submitted = try await service.submitSecret(
        cardID: card.id,
        route: card.route,
        secret: secret
    )
    let expectedReceipt = SecretReceiptID(serviceCardUUID(910))
    #expect(submitted.state == .present(receiptID: expectedReceipt))

    let serviceOperations = await service.recordedSecretOperations()
    #expect(
        serviceOperations == [
            PreviewSecretOperation(
                cardID: card.id,
                receiptID: expectedReceipt,
                kind: .store,
                byteCount: secret.count
            )
        ]
    )
    let keychainOperations = await keychain.recordedOperations()
    let expectedReference = KeychainItemReference.previewConnectorSecret(
        connectorID: card.connectorID.rawValue,
        bindingID: card.bindingID.rawValue
    )
    #expect(keychainOperations.count == 1)
    #expect(keychainOperations.first?.reference == expectedReference)
    #expect(keychainOperations.first?.kind == .store(byteCount: secret.count))
    #expect(await keychain.contains(expectedReference))

    var duplicateDescription = ""
    do {
        _ = try await service.submitSecret(
            cardID: card.id,
            route: card.route,
            secret: secret
        )
        Issue.record("Expected a second store to be rejected")
    } catch {
        duplicateDescription = String(describing: error)
    }

    let descriptions = [
        String(describing: submitted),
        String(describing: serviceOperations),
        String(describing: keychainOperations),
        rejectedDescription,
        duplicateDescription
    ]
    #expect(descriptions.allSatisfy { !$0.contains(sentinel) })
    #expect(await keychain.recordedOperations().count == 1)
    #expect(await service.recordedSecretOperations().count == 1)
}

@Test("Empty secret records only an opaque failed state and performs no store")
func emptySecretFailsWithoutStore() async throws {
    let card = try makeSecretCard()
    let keychain = InMemoryKeychainClient()
    let service = try ConversationCardFixtureService(
        keychain: keychain,
        secretCards: [card],
        uuidGenerator: CardSequenceUUIDGenerator(startingAt: 920)
    )

    await #expect(throws: ConversationCardActionError.emptySecret) {
        _ = try await service.submitSecret(
            cardID: card.id,
            route: card.route,
            secret: Data()
        )
    }

    let failed = try await service.secretCard(id: card.id)
    #expect(
        failed.state
            == .failed(receiptID: SecretReceiptID(serviceCardUUID(920)))
    )
    #expect(await keychain.recordedOperations().isEmpty)
    #expect(await service.recordedSecretOperations().isEmpty)
}

@Test("Fixture initialization rejects a card identity reused across card kinds")
func duplicateCardIdentityIsRejected() throws {
    let question = try makeFixtureQuestion()
    let connector = try ConnectorSetupCard(
        id: question.id,
        connectorID: ConnectorID(serviceCardUUID(301)),
        providerName: "Fixture provider",
        conversationID: ConversationID(serviceCardUUID(304)),
        messageID: MessageID(serviceCardUUID(305)),
        messagePartID: MessagePartID(serviceCardUUID(306)),
        routeID: ConversationCardRouteID(serviceCardUUID(302)),
        state: ConnectorSetupState(
            installation: .notInstalled,
            accountAuthentication: .notAuthenticated,
            perBotGrant: .notGranted,
            perActionApproval: .notRequested
        )
    )

    #expect(throws: ConversationCardFixtureServiceError.self) {
        _ = try ConversationCardFixtureService(
            keychain: InMemoryKeychainClient(),
            questionCards: [question],
            connectorCards: [connector]
        )
    }
}

private func makeFixtureQuestion() throws -> InlineQuestionCard {
    try InlineQuestionCard(
        id: ConversationCardID(serviceCardUUID(100)),
        prompt: "Which source should I use?",
        choices: [
            try QuestionCardChoice(
                id: ConversationCardChoiceID(serviceCardUUID(101)),
                label: "Primary source"
            ),
            try QuestionCardChoice(
                id: ConversationCardChoiceID(serviceCardUUID(102)),
                label: "Local document"
            )
        ],
        allowsFreeText: true,
        conversationID: ConversationID(serviceCardUUID(104)),
        messageID: MessageID(serviceCardUUID(105)),
        messagePartID: MessagePartID(serviceCardUUID(106)),
        routeID: ConversationCardRouteID(serviceCardUUID(103))
    )
}

private func makeConnectorCard() throws -> ConnectorSetupCard {
    try ConnectorSetupCard(
        id: ConversationCardID(serviceCardUUID(200)),
        connectorID: ConnectorID(serviceCardUUID(201)),
        providerName: "Fixture provider",
        conversationID: ConversationID(serviceCardUUID(203)),
        messageID: MessageID(serviceCardUUID(204)),
        messagePartID: MessagePartID(serviceCardUUID(205)),
        routeID: ConversationCardRouteID(serviceCardUUID(202)),
        state: ConnectorSetupState(
            installation: .notInstalled,
            accountAuthentication: .notAuthenticated,
            perBotGrant: .notGranted,
            perActionApproval: .notRequested
        )
    )
}

private func makeSecretCard() throws -> SecretEntryCard {
    try SecretEntryCard(
        id: ConversationCardID(serviceCardUUID(300)),
        connectorID: ConnectorID(serviceCardUUID(301)),
        bindingID: ConnectorBindingID(serviceCardUUID(302)),
        label: "Fixture API token",
        conversationID: ConversationID(serviceCardUUID(304)),
        messageID: MessageID(serviceCardUUID(305)),
        messagePartID: MessagePartID(serviceCardUUID(306)),
        routeID: ConversationCardRouteID(serviceCardUUID(303))
    )
}

private func serviceCardUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a3000000-0000-0000-0000-%012llu", value))!
}
