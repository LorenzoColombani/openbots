import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@Suite("DurableWorkspaceCardIntegrationTests")
@MainActor
struct DurableWorkspaceCardIntegrationTests {
    @Test("A conversation fixture is built once and keeps interaction state scoped across switches")
    func fixtureIdentityAndStateStayConversationScoped() async throws {
        let first = try makeCardWorkspaceChat(name: "Ada", seed: 31)
        let second = try makeCardWorkspaceChat(name: "Mira", seed: 32)
        let service = CardWorkspaceServiceSpy(
            chats: [first.chat, second.chat],
            selected: DurableChatSelectionSnapshot(
                teammate: first.chat.teammate,
                conversation: first.chat.conversation
            ),
            messages: [
                first.chat.conversation.id: [first.greeting],
                second.chat.conversation.id: [second.greeting]
            ]
        )
        let factory = CardFixtureFactorySpy()
        let model = DurableWorkspaceModel(mode: .reviewFixture,
            service: service,
            hiringService: UnusedCardHiringService(),
            cardFixtureFactory: factory.make(conversationID:)
        )

        try await model.loadInitialWorkspace()

        let firstConversationID = first.chat.conversation.id.rawValue
        let firstPresentation = try #require(factory.presentation(for: firstConversationID))
        let firstRegistry = try #require(model.cardInteractions)
        #expect(firstRegistry === firstPresentation.interactions)
        #expect(factory.buildCount(for: firstConversationID) == 1)
        let firstMessageIDs = model.conversation.messageRows.map(\.id)
        let firstPartIDs = firstPresentation.message.parts.map(\.id)

        let firstQuestion = try #require(questionModel(in: firstPresentation))
        firstQuestion.freeText = "Ada-only question draft"
        let firstSecret = try #require(secretModel(in: firstPresentation))
        let secretSentinel = "OPENBOTS-CARD-SECRET-SENTINEL-DO-NOT-DESCRIBE"
        firstSecret.transientInput = secretSentinel
        #expect(firstSecret.submitSecret())
        #expect(firstSecret.transientInput.isEmpty)

        try await select(
            second.chat,
            in: model
        )

        let secondConversationID = second.chat.conversation.id.rawValue
        let secondPresentation = try #require(factory.presentation(for: secondConversationID))
        let secondRegistry = try #require(model.cardInteractions)
        #expect(secondRegistry === secondPresentation.interactions)
        #expect(secondRegistry !== firstRegistry)
        #expect(factory.buildCount(for: secondConversationID) == 1)

        let secondQuestion = try #require(questionModel(in: secondPresentation))
        let secondSecret = try #require(secretModel(in: secondPresentation))
        #expect(secondQuestion.freeText.isEmpty)
        #expect(secondSecret.transientInput.isEmpty)
        #expect(secondSecret.state == .awaitingInput)
        secondQuestion.freeText = "Mira-only question draft"
        secondSecret.transientInput = "Mira-only secret draft"

        for _ in 0..<200 {
            if case .present = firstSecret.state { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(firstSecret.state.isTerminal)
        #expect(secondSecret.state == .awaitingInput)
        #expect(secondSecret.transientInput == "Mira-only secret draft")

        try await select(first.chat, in: model)

        #expect(model.cardInteractions === firstRegistry)
        #expect(factory.buildCount(for: firstConversationID) == 1)
        #expect(model.conversation.messageRows.map(\.id) == firstMessageIDs)
        #expect(firstPresentation.message.parts.map(\.id) == firstPartIDs)
        #expect(firstQuestion.freeText == "Ada-only question draft")
        #expect(firstSecret.transientInput.isEmpty)

        try await select(second.chat, in: model)
        #expect(model.cardInteractions === secondRegistry)
        #expect(factory.buildCount(for: secondConversationID) == 1)
        #expect(secondQuestion.freeText == "Mira-only question draft")
        #expect(secondSecret.transientInput == "Mira-only secret draft")

        let descriptions = [
            firstPresentation.message.body,
            firstPresentation.message.accessibilityBody,
            String(describing: firstPresentation.message),
            String(describing: firstSecret),
            String(reflecting: firstSecret)
        ]
        #expect(descriptions.allSatisfy { !$0.contains(secretSentinel) })
        #expect(await factory.recorder.secretByteCounts == [secretSentinel.utf8.count])
        #expect(await service.sendCount == 0)
        #expect(
            await service.durableMessageIDs(in: first.chat.conversation.id)
                == [first.greeting.id]
        )
        #expect(
            await service.durableMessageIDs(in: second.chat.conversation.id)
                == [second.greeting.id]
        )
    }

    @Test("Loading earlier durable messages preserves one synthetic card row without persistence")
    func loadingEarlierNeverDuplicatesOrPersistsCardFixture() async throws {
        let fixture = try makeCardWorkspaceChat(name: "Ada", seed: 41)
        let laterMessages = try (2...3).map { sequence in
            try cardWorkspaceMessage(
                conversationID: fixture.chat.conversation.id,
                teammateID: fixture.chat.teammate.id,
                sequence: Int64(sequence),
                text: "Durable message \(sequence)"
            )
        }
        let durableMessages = [fixture.greeting] + laterMessages
        let service = CardWorkspaceServiceSpy(
            chats: [fixture.chat],
            selected: DurableChatSelectionSnapshot(
                teammate: fixture.chat.teammate,
                conversation: fixture.chat.conversation
            ),
            messages: [fixture.chat.conversation.id: durableMessages]
        )
        let factory = CardFixtureFactorySpy()
        let model = DurableWorkspaceModel(mode: .reviewFixture,
            service: service,
            hiringService: UnusedCardHiringService(),
            cardFixtureFactory: factory.make(conversationID:)
        )

        try await model.loadInitialWorkspace(messageLimit: 1)

        let conversationID = fixture.chat.conversation.id.rawValue
        let presentation = try #require(factory.presentation(for: conversationID))
        let originalRegistry = try #require(model.cardInteractions)
        let originalCardRow = try #require(
            model.conversation.messageRows.first(where: { $0.id == presentation.message.id })
        )
        #expect(model.conversation.messageRows.filter { $0.id == presentation.message.id }.count == 1)
        #expect(model.conversation.hasEarlierMessages)

        model.conversation.loadEarlierMessages()
        for _ in 0..<200 where model.conversation.messageRows.count < 3 {
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(model.conversation.messageRows.filter { $0.id == presentation.message.id }.count == 1)
        #expect(
            model.conversation.messageRows.first(where: { $0.id == presentation.message.id })
                === originalCardRow
        )
        #expect(model.cardInteractions === originalRegistry)
        #expect(factory.buildCount(for: conversationID) == 1)
        #expect(await service.sendCount == 0)
        #expect(await service.loadRequestCount == 2)
        #expect(
            await service.durableMessageIDs(in: fixture.chat.conversation.id)
                == durableMessages.map(\.id)
        )
    }

    @Test("Omitting the fixture factory preserves the durable-only workspace")
    func nilFactoryPreservesDurableOnlyBehavior() async throws {
        let fixture = try makeCardWorkspaceChat(name: "Ada", seed: 51)
        let service = CardWorkspaceServiceSpy(
            chats: [fixture.chat],
            selected: DurableChatSelectionSnapshot(
                teammate: fixture.chat.teammate,
                conversation: fixture.chat.conversation
            ),
            messages: [fixture.chat.conversation.id: [fixture.greeting]]
        )
        let model = DurableWorkspaceModel(mode: .reviewFixture,
            service: service,
            hiringService: UnusedCardHiringService()
        )

        try await model.loadInitialWorkspace()

        #expect(model.cardInteractions == nil)
        #expect(model.conversation.messageRows.map(\.id) == [fixture.greeting.id.rawValue])
        #expect(await service.sendCount == 0)
        #expect(
            await service.durableMessageIDs(in: fixture.chat.conversation.id)
                == [fixture.greeting.id]
        )
    }

    private func select(
        _ chat: DurableDirectChatSnapshot,
        in model: DurableWorkspaceModel
    ) async throws {
        model.sidebar.selection = chat.teammate.id.rawValue
        for _ in 0..<300 {
            if model.conversation.conversationID == chat.conversation.id.rawValue,
               model.conversation.inputAvailability == .ready {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The selected durable conversation did not finish opening.")
    }

    private func questionModel(
        in presentation: ConversationCardFixturePresentation
    ) -> QuestionCardInteractionModel? {
        for part in presentation.message.parts {
            guard case .question(let card) = part.content else { continue }
            return presentation.interactions.question(
                messageID: presentation.message.id,
                partID: part.id,
                cardID: card.id
            )
        }
        return nil
    }

    private func secretModel(
        in presentation: ConversationCardFixturePresentation
    ) -> SecretCardInteractionModel? {
        for part in presentation.message.parts {
            guard case .secret(let card) = part.content else { continue }
            return presentation.interactions.secret(
                messageID: presentation.message.id,
                partID: part.id,
                cardID: card.id
            )
        }
        return nil
    }
}

@MainActor
private final class CardFixtureFactorySpy {
    let recorder = CardActionRecorder()
    private var buildCounts: [UUID: Int] = [:]
    private var presentations: [UUID: ConversationCardFixturePresentation] = [:]

    func make(conversationID: UUID) -> ConversationCardFixturePresentation? {
        buildCounts[conversationID, default: 0] += 1

        let messageID = UUID()
        let statusPartID = UUID()
        let questionPartID = UUID()
        let questionCardID = UUID()
        let questionChoiceID = UUID()
        let questionRoute = ConversationCardInteractionRoute(
            conversationID: conversationID,
            messageID: messageID,
            messagePartID: questionPartID,
            cardID: questionCardID,
            actionRouteID: UUID()
        )
        let questionSnapshot = ChatQuestionCardSnapshot(
            id: questionCardID,
            prompt: "Choose a local fixture path",
            choices: [
                ChatQuestionChoiceSnapshot(
                    id: questionChoiceID,
                    title: "Continue locally"
                )
            ],
            allowsFreeText: true
        )

        let secretPartID = UUID()
        let secretCardID = UUID()
        let secretRoute = ConversationCardInteractionRoute(
            conversationID: conversationID,
            messageID: messageID,
            messagePartID: secretPartID,
            cardID: secretCardID,
            actionRouteID: UUID()
        )
        let secretSnapshot = ChatSecretCardSnapshot(
            id: secretCardID,
            label: "Preview connector secret",
            purpose: "Process-local fixture only",
            presence: .absent
        )

        let registry = ConversationCardInteractionModel(conversationID: conversationID)
        let recorder = recorder
        let question = QuestionCardInteractionModel(
            route: questionRoute,
            snapshot: questionSnapshot,
            submit: { route, attemptID, _ in
                await recorder.recordQuestion(conversationID: route.conversationID)
                return ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: nil)
                )
            }
        )
        let secretReceiptID = UUID()
        let secret = SecretCardInteractionModel(
            route: secretRoute,
            snapshot: secretSnapshot,
            submit: { route, attemptID, secret in
                let byteCount = secret.utf8.count
                try? await Task.sleep(for: .milliseconds(40))
                await recorder.recordSecret(
                    conversationID: route.conversationID,
                    byteCount: byteCount
                )
                return ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: secretReceiptID)
                )
            }
        )
        _ = registry.register(question)
        _ = registry.register(secret)

        let message = ChatMessageSnapshot(
            id: messageID,
            author: .system(label: "OpenBots Preview"),
            parts: [
                ChatMessagePartSnapshot(
                    id: statusPartID,
                    ordinal: 0,
                    content: .status("Process-local card fixture; no runtime or real Keychain ran.")
                ),
                ChatMessagePartSnapshot(
                    id: questionPartID,
                    ordinal: 1,
                    content: .question(questionSnapshot)
                ),
                ChatMessagePartSnapshot(
                    id: secretPartID,
                    ordinal: 2,
                    content: .secret(secretSnapshot)
                )
            ],
            delivery: .sent,
            timestamp: Date(timeIntervalSince1970: 12_000)
        )
        let presentation = ConversationCardFixturePresentation(
            message: message,
            interactions: registry
        )
        presentations[conversationID] = presentation
        return presentation
    }

    func buildCount(for conversationID: UUID) -> Int {
        buildCounts[conversationID, default: 0]
    }

    func presentation(for conversationID: UUID) -> ConversationCardFixturePresentation? {
        presentations[conversationID]
    }
}

private actor CardActionRecorder {
    private(set) var questionConversationIDs: [UUID] = []
    private(set) var secretConversationIDs: [UUID] = []
    private(set) var secretByteCounts: [Int] = []

    func recordQuestion(conversationID: UUID) {
        questionConversationIDs.append(conversationID)
    }

    func recordSecret(conversationID: UUID, byteCount: Int) {
        secretConversationIDs.append(conversationID)
        secretByteCounts.append(byteCount)
    }
}

private actor CardWorkspaceServiceSpy: DurableTeammateChatServing {
    private let chats: [DurableDirectChatSnapshot]
    private var selected: DurableChatSelectionSnapshot?
    private let messages: [ConversationID: [Message]]
    private(set) var sendCount = 0
    private(set) var loadRequestCount = 0

    init(
        chats: [DurableDirectChatSnapshot],
        selected: DurableChatSelectionSnapshot?,
        messages: [ConversationID: [Message]]
    ) {
        self.chats = chats
        self.selected = selected
        self.messages = messages
    }

    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { chats }

    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? { selected }

    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        guard let chat = chats.first(where: {
            $0.teammate.id == teammateID && $0.conversation.id == conversationID
        }) else {
            throw CardWorkspaceTestError.unexpectedCall
        }
        selected = DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        )
    }

    func clearSelection() async throws {
        selected = nil
    }

    func createTeammateAndDirectChat(
        _ draft: DurableTeammateDraft
    ) async throws -> DurableTeammateChatCreationSnapshot {
        throw CardWorkspaceTestError.unexpectedCall
    }

    func loadMessages(
        conversationID: ConversationID,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> DurableMessagePageSnapshot {
        loadRequestCount += 1
        let eligible = (messages[conversationID] ?? [])
            .filter { message in
                guard let beforeSequence else { return true }
                return message.sequence < beforeSequence
            }
            .sorted { $0.sequence < $1.sequence }
        let page = Array(eligible.suffix(limit))
        return DurableMessagePageSnapshot(
            conversationID: conversationID,
            messages: page,
            hasMore: eligible.count > limit,
            nextBeforeSequence: eligible.count > limit ? page.first?.sequence : nil
        )
    }

    func sendMessageToLocalFixture(
        conversationID: ConversationID,
        teammateID: TeammateID,
        userMessageID: MessageID,
        text: String
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        sendCount += 1
        throw CardWorkspaceTestError.unexpectedCall
    }

    func durableMessageIDs(in conversationID: ConversationID) -> [MessageID] {
        (messages[conversationID] ?? []).map(\.id)
    }
}

private actor UnusedCardHiringService: HiringConversationServing {
    func loadOrStart() async throws -> HiringConversationSnapshot {
        throw CardWorkspaceTestError.unexpectedCall
    }

    func submit(text: String) async throws -> HiringConversationSnapshot {
        throw CardWorkspaceTestError.unexpectedCall
    }

    func revise(
        field: HiringCandidateField,
        value: String
    ) async throws -> HiringConversationSnapshot {
        throw CardWorkspaceTestError.unexpectedCall
    }

    func cancel() async throws {
        throw CardWorkspaceTestError.unexpectedCall
    }

    func confirm(
        appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot {
        throw CardWorkspaceTestError.unexpectedCall
    }
}

private enum CardWorkspaceTestError: Error {
    case unexpectedCall
}

private func makeCardWorkspaceChat(
    name: String,
    seed: UInt64
) throws -> (chat: DurableDirectChatSnapshot, greeting: Message) {
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let timestamp = Date(timeIntervalSince1970: 11_000 + Double(seed))
    let appearance = try AgentAppearance(
        mode: .creature,
        grammarVersion: 2,
        deterministicSeed: seed,
        silhouette: "sprout",
        paletteToken: "violet",
        eyeDialect: "bright",
        nonColorIdentityCue: "leaf ears",
        accessibleIdentityDescription: "Violet sprout with leaf ears",
        revision: 1
    )
    let teammate = try Teammate(
        id: teammateID,
        profile: TeammateProfile(displayName: name, role: "Local fixture reviewer"),
        appearance: appearance,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let conversation = try Conversation(
        id: conversationID,
        kind: .direct(teammateID: teammateID),
        title: name,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let greeting = try cardWorkspaceMessage(
        conversationID: conversationID,
        teammateID: teammateID,
        sequence: 1,
        text: "Durable local greeting for \(name)."
    )
    return (
        DurableDirectChatSnapshot(teammate: teammate, conversation: conversation),
        greeting
    )
}

private func cardWorkspaceMessage(
    conversationID: ConversationID,
    teammateID: TeammateID,
    sequence: Int64,
    text: String
) throws -> Message {
    let timestamp = Date(timeIntervalSince1970: 11_000 + Double(sequence))
    return try Message(
        id: MessageID(UUID()),
        conversationID: conversationID,
        sequence: sequence,
        author: .teammate(teammateID),
        deliveryState: .completed,
        parts: [
            try MessagePart(
                id: MessagePartID(UUID()),
                ordinal: 0,
                content: .text(text)
            )
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )
}
