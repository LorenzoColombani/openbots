import Foundation
import XCTest
@testable import OpenBotsDomain

final class ConversationCardDomainTests: XCTestCase {
    func testQuestionRequiresOneToSixUniquelyIdentifiedChoices() throws {
        XCTAssertThrowsError(
            try makeQuestion(choiceCount: 0)
        ) { error in
            XCTAssertEqual(
                error as? DomainValidationError,
                .invalid(
                    field: "question choices",
                    reason: "must contain between 1 and 6 choices"
                )
            )
        }
        XCTAssertNoThrow(try makeQuestion(choiceCount: 1))
        XCTAssertNoThrow(try makeQuestion(choiceCount: 6))
        XCTAssertThrowsError(try makeQuestion(choiceCount: 7))

        let duplicateID = ConversationCardChoiceID(cardUUID(20))
        let duplicates = [
            try QuestionCardChoice(id: duplicateID, label: "First"),
            try QuestionCardChoice(id: duplicateID, label: "Second")
        ]
        XCTAssertThrowsError(
            try InlineQuestionCard(
                id: ConversationCardID(cardUUID(1)),
                prompt: "Choose one",
                choices: duplicates,
                allowsFreeText: false,
                conversationID: ConversationID(cardUUID(3)),
                messageID: MessageID(cardUUID(4)),
                messagePartID: MessagePartID(cardUUID(5)),
                routeID: ConversationCardRouteID(cardUUID(2))
            )
        )
    }

    func testQuestionResolvesExactlyOnceToAnswerOrDecline() throws {
        var answered = try makeQuestion(choiceCount: 2)
        let selectedID = answered.choices[1].id
        try answered.answer(.choice(selectedID), using: answered.route)
        XCTAssertEqual(answered.resolution, .answered(.choice(selectedID)))
        XCTAssertThrowsError(
            try answered.decline(using: answered.route)
        ) { error in
            XCTAssertEqual(
                error as? ConversationCardActionError,
                .alreadyResolved(cardID: answered.id)
            )
        }

        var declined = try makeQuestion(choiceCount: 1)
        try declined.decline(using: declined.route)
        XCTAssertEqual(declined.resolution, .declined)
        XCTAssertThrowsError(
            try declined.answer(.choice(declined.choices[0].id), using: declined.route)
        )
    }

    func testQuestionRefusesWrongStaleAndInvalidRoutesAndAnswers() throws {
        let original = try makeQuestion(choiceCount: 1, allowsFreeText: false)

        var wrongCard = original
        let wrongCardRoute = ConversationCardRoute(
            id: wrongCard.route.id,
            conversationID: wrongCard.route.conversationID,
            messageID: wrongCard.route.messageID,
            messagePartID: wrongCard.route.messagePartID,
            cardID: ConversationCardID(cardUUID(90))
        )
        XCTAssertThrowsError(
            try wrongCard.answer(.choice(wrongCard.choices[0].id), using: wrongCardRoute)
        ) { error in
            XCTAssertEqual(
                error as? ConversationCardActionError,
                .wrongCard(expected: wrongCard.id, actual: wrongCardRoute.cardID)
            )
        }
        XCTAssertNil(wrongCard.resolution)

        var stale = original
        let staleRoute = ConversationCardRoute(
            id: ConversationCardRouteID(cardUUID(91)),
            conversationID: stale.route.conversationID,
            messageID: stale.route.messageID,
            messagePartID: stale.route.messagePartID,
            cardID: stale.id
        )
        XCTAssertThrowsError(
            try stale.decline(using: staleRoute)
        ) { error in
            XCTAssertEqual(
                error as? ConversationCardActionError,
                .staleRoute(expected: stale.route.id, actual: staleRoute.id)
            )
        }
        XCTAssertNil(stale.resolution)

        var invalidChoice = original
        let foreignChoiceID = ConversationCardChoiceID(cardUUID(92))
        XCTAssertThrowsError(
            try invalidChoice.answer(.choice(foreignChoiceID), using: invalidChoice.route)
        ) { error in
            XCTAssertEqual(
                error as? ConversationCardActionError,
                .invalidChoice(foreignChoiceID)
            )
        }

        var textDisabled = original
        XCTAssertThrowsError(
            try textDisabled.answer(.freeText("A custom answer"), using: textDisabled.route)
        ) { error in
            XCTAssertEqual(error as? ConversationCardActionError, .freeTextDisabled)
        }
    }

    func testQuestionRefusesRouteFromAnotherConversationMessageOrPart() throws {
        let original = try makeQuestion(choiceCount: 1)
        let identityChanges: [(ConversationCardRoute, ConversationCardActionError)] = [
            (
                ConversationCardRoute(
                    id: original.route.id,
                    conversationID: ConversationID(cardUUID(93)),
                    messageID: original.route.messageID,
                    messagePartID: original.route.messagePartID,
                    cardID: original.id
                ),
                .wrongConversation(
                    expected: original.route.conversationID,
                    actual: ConversationID(cardUUID(93))
                )
            ),
            (
                ConversationCardRoute(
                    id: original.route.id,
                    conversationID: original.route.conversationID,
                    messageID: MessageID(cardUUID(94)),
                    messagePartID: original.route.messagePartID,
                    cardID: original.id
                ),
                .wrongMessage(
                    expected: original.route.messageID,
                    actual: MessageID(cardUUID(94))
                )
            ),
            (
                ConversationCardRoute(
                    id: original.route.id,
                    conversationID: original.route.conversationID,
                    messageID: original.route.messageID,
                    messagePartID: MessagePartID(cardUUID(95)),
                    cardID: original.id
                ),
                .wrongMessagePart(
                    expected: original.route.messagePartID,
                    actual: MessagePartID(cardUUID(95))
                )
            )
        ]

        for (route, expectedError) in identityChanges {
            var question = original
            XCTAssertThrowsError(
                try question.answer(.choice(question.choices[0].id), using: route)
            ) { error in
                XCTAssertEqual(error as? ConversationCardActionError, expectedError)
            }
            XCTAssertNil(question.resolution)
        }
    }

    func testQuestionAcceptsBoundedOptionalFreeText() throws {
        var question = try makeQuestion(choiceCount: 1, allowsFreeText: true)
        try question.answer(.freeText("  A considered alternative  "), using: question.route)
        XCTAssertEqual(
            question.resolution,
            .answered(.freeText("A considered alternative"))
        )

        var empty = try makeQuestion(choiceCount: 1, allowsFreeText: true)
        XCTAssertThrowsError(
            try empty.answer(.freeText(" \n "), using: empty.route)
        ) { error in
            XCTAssertEqual(error as? ConversationCardActionError, .emptyFreeText)
        }
        XCTAssertNil(empty.resolution)
    }

    func testConnectorReopenRecordsAttemptWithoutChangingFourIndependentAxes() throws {
        let initial = ConnectorSetupState(
            installation: .installed,
            accountAuthentication: .notAuthenticated,
            perBotGrant: .revoked,
            perActionApproval: .denied
        )
        var card = try ConnectorSetupCard(
            id: ConversationCardID(cardUUID(30)),
            connectorID: ConnectorID(cardUUID(31)),
            providerName: "Local fixture provider",
            conversationID: ConversationID(cardUUID(34)),
            messageID: MessageID(cardUUID(35)),
            messagePartID: MessagePartID(cardUUID(36)),
            routeID: ConversationCardRouteID(cardUUID(32)),
            state: initial
        )
        let attemptID = ProviderAuthenticationAttemptID(cardUUID(33))

        try card.recordProviderAuthenticationAttempt(attemptID, using: card.route)

        XCTAssertEqual(card.state, initial)
        XCTAssertEqual(card.state.installation, .installed)
        XCTAssertEqual(card.state.accountAuthentication, .notAuthenticated)
        XCTAssertEqual(card.state.perBotGrant, .revoked)
        XCTAssertEqual(card.state.perActionApproval, .denied)
        XCTAssertEqual(card.lastAuthenticationAttemptID, attemptID)
        XCTAssertEqual(card.authenticationAttemptCount, 1)
    }

    func testSecretCardExposesOnlyOpaquePresenceStates() throws {
        var card = try SecretEntryCard(
            id: ConversationCardID(cardUUID(40)),
            connectorID: ConnectorID(cardUUID(41)),
            bindingID: ConnectorBindingID(cardUUID(42)),
            label: "Access token",
            conversationID: ConversationID(cardUUID(46)),
            messageID: MessageID(cardUUID(47)),
            messagePartID: MessagePartID(cardUUID(48)),
            routeID: ConversationCardRouteID(cardUUID(43))
        )
        XCTAssertEqual(card.state, .absent)

        let receiptID = SecretReceiptID(cardUUID(44))
        try card.markPresent(receiptID: receiptID, using: card.route)
        XCTAssertEqual(card.state, .present(receiptID: receiptID))
        XCTAssertThrowsError(
            try card.markFailed(
                receiptID: SecretReceiptID(cardUUID(45)),
                using: card.route
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationCardActionError,
                .secretAlreadyPresent(cardID: card.id)
            )
        }
    }

    func testCardIdentifiersRoundTripAsStableUUIDStrings() throws {
        let id = ConversationCardID(cardUUID(70))
        let encoded = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(id.persistedValue)\"")
        XCTAssertEqual(try JSONDecoder().decode(ConversationCardID.self, from: encoded), id)
    }

    private func makeQuestion(
        choiceCount: Int,
        allowsFreeText: Bool = true
    ) throws -> InlineQuestionCard {
        let choices = try (0..<choiceCount).map { index in
            try QuestionCardChoice(
                id: ConversationCardChoiceID(cardUUID(UInt64(index + 10))),
                label: "Choice \(index + 1)"
            )
        }
        return try InlineQuestionCard(
            id: ConversationCardID(cardUUID(1)),
            prompt: "How should I continue?",
            choices: choices,
            allowsFreeText: allowsFreeText,
            conversationID: ConversationID(cardUUID(3)),
            messageID: MessageID(cardUUID(4)),
            messagePartID: MessagePartID(cardUUID(5)),
            routeID: ConversationCardRouteID(cardUUID(2))
        )
    }
}

private func cardUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a2000000-0000-0000-0000-%012llu", value))!
}
