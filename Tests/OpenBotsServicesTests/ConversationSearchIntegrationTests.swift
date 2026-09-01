import Foundation
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsServices
import Testing

@Suite("Composed local search integration")
struct ConversationSearchIntegrationTests {
    @Test("Created teammate and saved fixture message can be searched, opened and found after a true store reopen")
    func createSendSearchResolvePageAndReopen() async throws {
        let fixture = try SearchIntegrationFixture()
        defer { fixture.remove() }

        let saved = try await createAndSearch(in: fixture)
        // Only immutable domain receipts cross the initial service scope; this
        // weak check proves reopening is not merely a second live connection.
        #expect(saved.initialStore.value == nil)

        let reopened = try fixture.open()
        let search = ConversationSearchService(repository: reopened)
        let chat = fixture.chatService(store: reopened)
        let draftService = ConversationDraftService(repository: reopened, clock: fixture.clock)

        let rosterResult = try await search.search(ConversationSearchRequest(query: "Ada Integration"))
        #expect(rosterResult.teammates.map(\.teammate.id) == [saved.teammateID])
        #expect(rosterResult.teammates.map(\.conversationID) == [saved.conversationID])

        let result = try await search.search(ConversationSearchRequest(query: "observatorycheck", limit: 1))
        #expect(result.messages.map(\.id) == [saved.message.id])
        #expect(!result.hasMoreMessages)
        let target = try #require(try await search.resolveMessage(id: saved.message.id))
        #expect(target == saved.target)
        try await chat.select(teammateID: target.teammateID, conversationID: target.conversationID)
        let selected = try #require(try await chat.selectedDirectChat())
        #expect(selected.teammate.id == saved.teammateID && selected.conversation.id == saved.conversationID)

        let targetPage = try await chat.loadMessages(
            conversationID: target.conversationID, beforeSequence: target.sequence + 1, limit: 1
        )
        #expect(targetPage.messages == [saved.message])
        #expect(targetPage.hasMore && targetPage.nextBeforeSequence == target.sequence)
        #expect(targetPage.conversationID == saved.conversationID)
        #expect(try await draftService.load(conversationID: saved.conversationID) == saved.draft)
        #expect(try await search.search(ConversationSearchRequest(query: "uncatalogueddraftmarker")).messages.isEmpty)
        #expect(try await reopened.runtimeFacts().protectionMode == .ordinarySQLite)
    }

    private func createAndSearch(in fixture: SearchIntegrationFixture) async throws -> SearchIntegrationReceipt {
        let store = try fixture.open()
        let search = ConversationSearchService(repository: store)
        let chat = fixture.chatService(store: store)
        let draftService = ConversationDraftService(repository: store, clock: fixture.clock)
        let teammateID = TeammateID(UUID())
        let created = try await chat.createTeammateAndDirectChat(DurableTeammateDraft(
            teammateID: teammateID, displayName: "Ada Integration", role: "Research partner",
            appearance: AgentAppearance(
                mode: .creature, grammarVersion: 1, deterministicSeed: 7, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature with a crest"
            )
        ))
        let messageID = MessageID(UUID())
        let exchange = try await chat.sendMessageToLocalFixture(
            conversationID: created.conversation.id, teammateID: teammateID,
            userMessageID: messageID, text: "Prepare the observatorycheck report."
        )
        #expect(exchange.userMessage.id == messageID && exchange.userMessage.sequence == 2)
        #expect(exchange.userMessage.deliveryState == .completed)
        #expect(exchange.fixtureReply.parts.map(\.content) == [.text(DurableTeammateChatService.fixtureReplyText)])

        // The target is no longer in the latest bounded page, so selecting it
        // genuinely needs the resolved sequence instead of loading a whole chat.
        let later = try await chat.sendMessageToLocalFixture(
            conversationID: created.conversation.id, teammateID: teammateID,
            userMessageID: MessageID(UUID()), text: "A later, unrelated note."
        )
        let newest = try await chat.loadMessages(conversationID: created.conversation.id, beforeSequence: nil, limit: 2)
        #expect(newest.messages.map(\.id) == [later.userMessage.id, later.fixtureReply.id])
        #expect(newest.hasMore && !newest.messages.contains { $0.id == messageID })

        let draft = try await draftService.save(
            conversationID: created.conversation.id, text: "uncatalogueddraftmarker — not sent",
            expectedRevision: 0
        )
        #expect(try await search.search(ConversationSearchRequest(query: "uncatalogueddraftmarker")).messages.isEmpty)
        let result = try await search.search(ConversationSearchRequest(query: "observatorycheck", limit: 1))
        let hit = try #require(result.messages.first)
        #expect(result.messages.count == 1 && !result.hasMoreMessages)
        #expect(hit.id == messageID && hit.conversationID == created.conversation.id)
        #expect(hit.teammateID == teammateID && hit.author == .user)
        #expect(hit.snippet.contains("observatorycheck"))
        let target = try #require(try await search.resolveMessage(id: hit.id))
        #expect(target.id == messageID && target.sequence == exchange.userMessage.sequence)
        #expect(target.currentTitle == "Ada Integration")
        let page = try await chat.loadMessages(
            conversationID: target.conversationID, beforeSequence: target.sequence + 1, limit: 1
        )
        #expect(page.messages == [exchange.userMessage])
        #expect(page.hasMore && page.nextBeforeSequence == exchange.userMessage.sequence)

        return SearchIntegrationReceipt(
            initialStore: WeakSearchIntegrationStore(store), teammateID: teammateID,
            conversationID: created.conversation.id, message: exchange.userMessage,
            target: target, draft: draft
        )
    }
}

private struct SearchIntegrationReceipt {
    let initialStore: WeakSearchIntegrationStore
    let teammateID: TeammateID
    let conversationID: ConversationID
    let message: Message
    let target: MessageSearchTarget
    let draft: ConversationDraftSnapshot
}

private final class WeakSearchIntegrationStore {
    weak var value: SQLiteStore?
    init(_ value: SQLiteStore) { self.value = value }
}

private struct SearchIntegrationClock: OpenBotsClock {
    func now() -> Date { Date(timeIntervalSince1970: 15_000) }
}

private struct SearchIntegrationFixture {
    let root: URL
    let protectionReceipt: ProtectionDecisionReceipt
    let clock = SearchIntegrationClock()

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextSearchIntegration-\(UUID()).noindex", isDirectory: true)
        protectionReceipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: root.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protectionReceipt)
        ))
    }

    func chatService(store: SQLiteStore) -> DurableTeammateChatService {
        DurableTeammateChatService(mode: .reviewFixture,
            teammateRepository: store, conversationRepository: store, messageRepository: store,
            provisioningRepository: store, selectionRepository: store, clock: clock
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
