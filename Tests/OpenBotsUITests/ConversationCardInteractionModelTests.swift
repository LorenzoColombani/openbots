import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsUI

private actor CardActionRecorder {
    private(set) var questions: [QuestionCardAnswerRequest] = []
    private(set) var secrets: [String] = []
    private(set) var routes: [ConversationCardInteractionRoute] = []

    func record(
        route: ConversationCardInteractionRoute,
        question: QuestionCardAnswerRequest
    ) {
        routes.append(route)
        questions.append(question)
    }

    func record(route: ConversationCardInteractionRoute, secret: String) {
        routes.append(route)
        secrets.append(secret)
    }
}

private func interactionUUID(_ suffix: UInt64) -> UUID {
    let value = String(format: "%012llx", suffix)
    return UUID(uuidString: "79000000-0000-0000-0000-\(value)")!
}

private func interactionRoute(
    conversation: UInt64 = 1,
    message: UInt64 = 2,
    part: UInt64 = 3,
    card: UInt64 = 4,
    action: UInt64 = 5
) -> ConversationCardInteractionRoute {
    ConversationCardInteractionRoute(
        conversationID: interactionUUID(conversation),
        messageID: interactionUUID(message),
        messagePartID: interactionUUID(part),
        cardID: interactionUUID(card),
        actionRouteID: interactionUUID(action)
    )
}

@Test("UI and Domain card routes round-trip every frozen identity")
func domainRouteRoundTrip() {
    let domain = ConversationCardRoute(
        id: ConversationCardRouteID(interactionUUID(5)),
        conversationID: ConversationID(interactionUUID(1)),
        messageID: MessageID(interactionUUID(2)),
        messagePartID: MessagePartID(interactionUUID(3)),
        cardID: ConversationCardID(interactionUUID(4))
    )

    let presentation = ConversationCardInteractionRoute(domain)

    #expect(presentation.conversationID == domain.conversationID.rawValue)
    #expect(presentation.messageID == domain.messageID.rawValue)
    #expect(presentation.messagePartID == domain.messagePartID.rawValue)
    #expect(presentation.cardID == domain.cardID.rawValue)
    #expect(presentation.actionRouteID == domain.id.rawValue)
    #expect(presentation.domainRoute == domain)
}

private func questionSnapshot(
    cardID: UUID = interactionUUID(4),
    choiceCount: Int = 2,
    allowsFreeText: Bool = true
) -> ChatQuestionCardSnapshot {
    ChatQuestionCardSnapshot(
        id: cardID,
        prompt: "How should I continue?",
        choices: (0..<choiceCount).map { index in
            ChatQuestionChoiceSnapshot(
                id: interactionUUID(UInt64(20 + index)),
                title: "Choice \(index + 1)"
            )
        },
        allowsFreeText: allowsFreeText
    )
}

@MainActor
private func waitForCardState(
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
}

@Test("A question answers once and cannot be resolved again")
@MainActor
func questionTerminalAnswerIsOneShot() async {
    let recorder = CardActionRecorder()
    let route = interactionRoute()
    let snapshot = questionSnapshot()
    let model = QuestionCardInteractionModel(
        route: route,
        snapshot: snapshot,
        submit: { route, attemptID, answer in
            await recorder.record(route: route, question: answer)
            return ConversationCardActionResult(
                route: route,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: interactionUUID(30))
            )
        }
    )

    #expect(model.answer(choiceID: snapshot.choices[0].id))
    #expect(model.state == .submitting)
    #expect(model.answer(choiceID: snapshot.choices[1].id) == false)
    #expect(model.decline() == false)
    await waitForCardState { model.state == .answered }

    #expect(model.state == .answered)
    #expect(model.state.isTerminal)
    #expect(model.decline() == false)
    #expect(await recorder.questions == [.choice(snapshot.choices[0].id)])
    #expect(await recorder.routes == [route])
}

@Test("Question decline is explicit and invalid choice contracts are read only")
@MainActor
func questionDeclineAndChoiceBounds() async {
    let route = interactionRoute()
    let valid = questionSnapshot()
    let declined = QuestionCardInteractionModel(
        route: route,
        snapshot: valid,
        submit: { route, attemptID, _ in
            ConversationCardActionResult(
                route: route,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: nil)
            )
        }
    )
    #expect(declined.decline())
    await waitForCardState { declined.state == .declined }
    #expect(declined.state == .declined)
    #expect(declined.answer(choiceID: valid.choices[0].id) == false)

    for count in [0, 7] {
        let invalid = QuestionCardInteractionModel(
            route: route,
            snapshot: questionSnapshot(choiceCount: count),
            submit: { route, attemptID, _ in
                ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: nil)
                )
            }
        )
        #expect(invalid.canInteract == false)
        #expect(invalid.decline() == false)
    }
}

@Test("Conversation card routing never crosses conversation, message, part, or type")
@MainActor
func conversationRouteIsolation() {
    let route = interactionRoute()
    let question = QuestionCardInteractionModel(
        route: route,
        snapshot: questionSnapshot(),
        submit: { route, attemptID, _ in
            ConversationCardActionResult(
                route: route,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: nil)
            )
        }
    )
    let owner = ConversationCardInteractionModel(conversationID: route.conversationID)
    let foreign = ConversationCardInteractionModel(conversationID: interactionUUID(100))

    #expect(owner.register(question))
    #expect(foreign.register(question) == false)
    #expect(
        owner.question(
            messageID: route.messageID,
            partID: route.messagePartID,
            cardID: route.cardID
        ) === question
    )
    #expect(
        owner.question(
            messageID: interactionUUID(101),
            partID: route.messagePartID,
            cardID: route.cardID
        ) == nil
    )
    #expect(
        owner.question(
            messageID: route.messageID,
            partID: interactionUUID(102),
            cardID: route.cardID
        ) == nil
    )
    #expect(
        owner.secret(
            messageID: route.messageID,
            partID: route.messagePartID,
            cardID: route.cardID
        ) == nil
    )
}

@Test("Connector reopening changes only its attempt state and remains retryable")
@MainActor
func connectorReopenIsNarrowAndRetryable() async {
    let route = interactionRoute()
    let snapshot = ChatConnectorSetupCardSnapshot(
        id: route.cardID,
        connectorName: "Calendar fixture",
        installation: .installed,
        authentication: .failed,
        botGrant: .revoked,
        actionApproval: .denied
    )
    let model = ConnectorSetupCardInteractionModel(
        route: route,
        snapshot: snapshot,
        reopenAuthentication: { route, attemptID in
            ConversationCardActionResult(
                route: route,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: interactionUUID(40))
            )
        }
    )

    #expect(model.reopen())
    await waitForCardState {
        if case .reopened = model.state { return true }
        return false
    }
    #expect(model.snapshot == snapshot)
    #expect(model.snapshot.installation == .installed)
    #expect(model.snapshot.botGrant == .revoked)
    #expect(model.snapshot.actionApproval == .denied)
    #expect(model.canReopenAuthentication)
    #expect(model.reopen())
    await waitForCardState {
        if case .reopened = model.state { return true }
        return false
    }
    #expect(model.canReopenAuthentication)
}

@Test("Secret input clears synchronously and only opaque presence remains")
@MainActor
func secretClearingAndOpaqueReceipt() async {
    let recorder = CardActionRecorder()
    let route = interactionRoute()
    let snapshot = ChatSecretCardSnapshot(
        id: route.cardID,
        label: "Calendar token",
        purpose: "Used only by the selected connector fixture",
        presence: .absent
    )
    let receiptID = interactionUUID(50)
    let sentinel = "s2b-secret-sentinel-very-private"
    let model = SecretCardInteractionModel(
        route: route,
        snapshot: snapshot,
        submit: { route, attemptID, secret in
            await recorder.record(route: route, secret: secret)
            return ConversationCardActionResult(
                route: route,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: receiptID)
            )
        }
    )
    model.transientInput = sentinel

    #expect(model.submitSecret())
    #expect(model.transientInput.isEmpty)
    #expect(!String(describing: model).contains(sentinel))
    #expect(!String(reflecting: model).contains(sentinel))
    #expect(!snapshot.accessibilityDescription.contains(sentinel))
    await waitForCardState { model.state == .present(receiptID: receiptID) }

    #expect(model.state == .present(receiptID: receiptID))
    #expect(model.state.isTerminal)
    #expect(model.transientInput.isEmpty)
    #expect(await recorder.secrets == [sentinel])
    #expect(model.submitSecret() == false)
}

@Test("Invalidated or misrouted async completions cannot mutate another card")
@MainActor
func staleResultRejection() async {
    let route = interactionRoute()
    let model = QuestionCardInteractionModel(
        route: route,
        snapshot: questionSnapshot(),
        submit: { route, attemptID, _ in
            try? await Task.sleep(for: .milliseconds(5))
            return ConversationCardActionResult(
                route: route,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: nil)
            )
        }
    )
    #expect(model.decline())
    model.invalidatePendingAction()
    #expect(model.state == .ready)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.state == .ready)

    let wrongRoute = interactionRoute(conversation: 200)
    let misrouted = QuestionCardInteractionModel(
        route: route,
        snapshot: questionSnapshot(),
        submit: { _, attemptID, _ in
            ConversationCardActionResult(
                route: wrongRoute,
                attemptID: attemptID,
                outcome: .succeeded(receiptID: nil)
            )
        }
    )
    #expect(misrouted.decline())
    await waitForCardState { misrouted.state == .failed }
    #expect(misrouted.state == .failed)
}
