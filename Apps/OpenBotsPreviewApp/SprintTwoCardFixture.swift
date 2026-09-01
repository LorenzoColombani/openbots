import Foundation
import OpenBotsDomain
import OpenBotsSecurity
import OpenBotsServices
import OpenBotsUI

/// Builds the process-local Sprint 2B review row. Every dependency is a local
/// fake owned by the returned conversation presentation; no production
/// credential, provider, runtime, network, filesystem, grant, or approval path
/// is reachable from these adapters.
@MainActor
enum SprintTwoCardFixture {
    static func make(
        conversationID: UUID
    ) -> ConversationCardFixturePresentation? {
        do {
            let messageID = MessageID(UUID())
            let disclosurePartID = MessagePartID(UUID())
            let questionPartID = MessagePartID(UUID())
            let connectorPartID = MessagePartID(UUID())
            let secretPartID = MessagePartID(UUID())

            let questionCard = try InlineQuestionCard(
                id: ConversationCardID(UUID()),
                prompt: "Which outcome should I prioritize for the next review?",
                choices: [
                    try QuestionCardChoice(
                        id: ConversationCardChoiceID(UUID()),
                        label: "A working prototype"
                    ),
                    try QuestionCardChoice(
                        id: ConversationCardChoiceID(UUID()),
                        label: "Verified research"
                    ),
                    try QuestionCardChoice(
                        id: ConversationCardChoiceID(UUID()),
                        label: "A polished deliverable"
                    )
                ],
                allowsFreeText: true,
                conversationID: ConversationID(conversationID),
                messageID: messageID,
                messagePartID: questionPartID,
                routeID: ConversationCardRouteID(UUID())
            )

            let connectorCard = try ConnectorSetupCard(
                id: ConversationCardID(UUID()),
                connectorID: ConnectorID(UUID()),
                providerName: "GitHub",
                conversationID: ConversationID(conversationID),
                messageID: messageID,
                messagePartID: connectorPartID,
                routeID: ConversationCardRouteID(UUID()),
                state: ConnectorSetupState(
                    installation: .installed,
                    accountAuthentication: .notAuthenticated,
                    perBotGrant: .notGranted,
                    perActionApproval: .notRequested
                )
            )

            let secretCard = try SecretEntryCard(
                id: ConversationCardID(UUID()),
                connectorID: connectorCard.connectorID,
                bindingID: ConnectorBindingID(UUID()),
                label: "Preview connector token",
                conversationID: ConversationID(conversationID),
                messageID: messageID,
                messagePartID: secretPartID,
                routeID: ConversationCardRouteID(UUID())
            )

            let service = try ConversationCardFixtureService(
                keychain: InMemoryKeychainClient(),
                questionCards: [questionCard],
                connectorCards: [connectorCard],
                secretCards: [secretCard]
            )
            let interactions = ConversationCardInteractionModel(
                conversationID: conversationID
            )

            let questionRoute = questionCard.route
            let questionInteraction = QuestionCardInteractionModel(
                route: ConversationCardInteractionRoute(questionRoute),
                snapshot: ChatQuestionCardSnapshot(questionCard),
                submit: { [service, questionRoute] route, attemptID, request in
                    guard route.domainRoute == questionRoute else {
                        return failedResult(route: route, attemptID: attemptID)
                    }
                    do {
                        switch request {
                        case .choice(let choiceID):
                            _ = try await service.answerQuestion(
                                cardID: questionRoute.cardID,
                                route: questionRoute,
                                answer: .choice(ConversationCardChoiceID(choiceID))
                            )
                        case .freeText(let answer):
                            _ = try await service.answerQuestion(
                                cardID: questionRoute.cardID,
                                route: questionRoute,
                                answer: .freeText(answer)
                            )
                        case .decline:
                            _ = try await service.declineQuestion(
                                cardID: questionRoute.cardID,
                                route: questionRoute
                            )
                        }
                        return succeededResult(route: route, attemptID: attemptID)
                    } catch {
                        return failedResult(route: route, attemptID: attemptID)
                    }
                }
            )

            let connectorRoute = connectorCard.route
            let connectorInteraction = ConnectorSetupCardInteractionModel(
                route: ConversationCardInteractionRoute(connectorRoute),
                snapshot: ChatConnectorSetupCardSnapshot(connectorCard),
                reopenAuthentication: { [service, connectorRoute] route, attemptID in
                    guard route.domainRoute == connectorRoute else {
                        return failedResult(route: route, attemptID: attemptID)
                    }
                    do {
                        let card = try await service.reopenProviderAuthentication(
                            cardID: connectorRoute.cardID,
                            route: connectorRoute
                        )
                        return succeededResult(
                            route: route,
                            attemptID: attemptID,
                            receiptID: card.lastAuthenticationAttemptID?.rawValue
                        )
                    } catch {
                        return failedResult(route: route, attemptID: attemptID)
                    }
                }
            )

            let secretRoute = secretCard.route
            let secretInteraction = SecretCardInteractionModel(
                route: ConversationCardInteractionRoute(secretRoute),
                snapshot: ChatSecretCardSnapshot(
                    secretCard,
                    purpose: "Stored only in this process-local preview; no provider receives it."
                ),
                submit: { [service, secretRoute] route, attemptID, secret in
                    guard route.domainRoute == secretRoute else {
                        return failedResult(route: route, attemptID: attemptID)
                    }
                    do {
                        let card = try await service.submitSecret(
                            cardID: secretRoute.cardID,
                            route: secretRoute,
                            secret: Data(secret.utf8)
                        )
                        guard case .present(let receiptID) = card.state else {
                            return failedResult(route: route, attemptID: attemptID)
                        }
                        return succeededResult(
                            route: route,
                            attemptID: attemptID,
                            receiptID: receiptID.rawValue
                        )
                    } catch {
                        return failedResult(route: route, attemptID: attemptID)
                    }
                }
            )

            guard interactions.register(questionInteraction),
                  interactions.register(connectorInteraction),
                  interactions.register(secretInteraction) else {
                return nil
            }

            let message = ChatMessageSnapshot(
                id: messageID.rawValue,
                author: .system(label: "OpenBots Preview"),
                parts: [
                    ChatMessagePartSnapshot(
                        id: disclosurePartID.rawValue,
                        ordinal: 0,
                        content: .status(ConversationCardFixtureService.disclosure)
                    ),
                    ChatMessagePartSnapshot(
                        id: questionPartID.rawValue,
                        ordinal: 1,
                        content: .question(ChatQuestionCardSnapshot(questionCard))
                    ),
                    ChatMessagePartSnapshot(
                        id: connectorPartID.rawValue,
                        ordinal: 2,
                        content: .connectorSetup(
                            ChatConnectorSetupCardSnapshot(connectorCard)
                        )
                    ),
                    ChatMessagePartSnapshot(
                        id: secretPartID.rawValue,
                        ordinal: 3,
                        content: .secret(
                            ChatSecretCardSnapshot(
                                secretCard,
                                purpose: "Stored only in this process-local preview; no provider receives it."
                            )
                        )
                    )
                ],
                delivery: .sent,
                timestamp: Date()
            )
            return ConversationCardFixturePresentation(
                message: message,
                interactions: interactions
            )
        } catch {
            return nil
        }
    }

    nonisolated private static func succeededResult(
        route: ConversationCardInteractionRoute,
        attemptID: UUID,
        receiptID: UUID? = nil
    ) -> ConversationCardActionResult {
        ConversationCardActionResult(
            route: route,
            attemptID: attemptID,
            outcome: .succeeded(receiptID: receiptID)
        )
    }

    nonisolated private static func failedResult(
        route: ConversationCardInteractionRoute,
        attemptID: UUID
    ) -> ConversationCardActionResult {
        ConversationCardActionResult(
            route: route,
            attemptID: attemptID,
            outcome: .failed(receiptID: nil)
        )
    }
}
