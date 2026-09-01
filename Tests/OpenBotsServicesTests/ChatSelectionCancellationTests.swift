import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("ChatSelectionCancellationTests")
struct ChatSelectionCancellationTests {
    @Test("Constructing the service and pre-cancelled selection requests perform no reads or writes")
    func cancelledBeforeValidation() async throws {
        let chat = try selectionTestChat()
        let repository = SelectionRepositoryDouble(chats: [chat])
        let service = selectionTestService(repository)
        #expect(await repository.validationReads == 0)
        #expect(await repository.writes.isEmpty)
        for clear in [false, true] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if clear { try await service.clearSelection() }
                else { try await service.select(teammateID: chat.teammate.id, conversationID: chat.conversation.id) }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(await repository.validationReads == 0)
        #expect(await repository.writes.isEmpty)
    }

    @Test("Cancellation during either validation read never reaches a selection write", arguments: [false, true])
    func cancelledDuringValidation(suspendTeammate: Bool) async throws {
        let chat = try selectionTestChat()
        let prior = ConversationID(UUID())
        let suspension = SelectionReadSuspension()
        let repository = SelectionRepositoryDouble(
            chats: [chat], selection: prior, suspendedConversationID: chat.conversation.id,
            suspendTeammate: suspendTeammate, suspension: suspension
        )
        let service = selectionTestService(repository)
        let task = Task { try await service.select(teammateID: chat.teammate.id, conversationID: chat.conversation.id) }
        await suspension.waitUntilEntered()
        task.cancel()
        await suspension.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await repository.writes.isEmpty)
        #expect(try await repository.selectedConversationID() == prior)
    }

    @Test("A newer select or clear supersedes old suspended validation", arguments: [false, true])
    func supersededValidation(clear: Bool) async throws {
        let old = try selectionTestChat()
        let newer = try selectionTestChat()
        let suspension = SelectionReadSuspension()
        let repository = SelectionRepositoryDouble(
            chats: [old, newer], suspendedConversationID: old.conversation.id, suspension: suspension
        )
        let service = selectionTestService(repository)
        let task = Task { try await service.select(teammateID: old.teammate.id, conversationID: old.conversation.id) }
        await suspension.waitUntilEntered()
        if clear { try await service.clearSelection() }
        else { try await service.select(teammateID: newer.teammate.id, conversationID: newer.conversation.id) }
        await suspension.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let expected = clear ? nil : newer.conversation.id
        #expect(await repository.writes == [expected])
        #expect(try await repository.selectedConversationID() == expected)
    }

    @Test("An invalid teammate identity cannot reach the selection writer")
    func invalidIdentity() async throws {
        let chat = try selectionTestChat()
        let repository = SelectionRepositoryDouble(chats: [chat])
        let service = selectionTestService(repository)
        let other = TeammateID(UUID())
        await #expect(throws: DurableTeammateChatError.conversationIsNotActiveDirectChat(
            conversationID: chat.conversation.id, teammateID: other
        )) {
            try await service.select(teammateID: other, conversationID: chat.conversation.id)
        }
        #expect(await repository.writes.isEmpty)
    }

    @Test("Successful selection and clear each perform exactly one write")
    func successfulCommit() async throws {
        let chat = try selectionTestChat()
        let repository = SelectionRepositoryDouble(chats: [chat])
        let service = selectionTestService(repository)
        try await service.select(teammateID: chat.teammate.id, conversationID: chat.conversation.id)
        try await service.clearSelection()
        #expect(await repository.writes == [chat.conversation.id, nil])
    }

    @Test("Cancellation after a completed repository commit is not misreported as rollback")
    func completedCommitIsAcknowledged() async throws {
        let chat = try selectionTestChat()
        let repository = SelectionRepositoryDouble(chats: [chat], cancelAfterCommit: true)
        let service = selectionTestService(repository)
        let task = Task { try await service.select(teammateID: chat.teammate.id, conversationID: chat.conversation.id) }
        try await task.value
        #expect(task.isCancelled)
        #expect(await repository.writes == [chat.conversation.id])
        #expect(try await repository.selectedConversationID() == chat.conversation.id)
    }
}

private func selectionTestService(_ repository: SelectionRepositoryDouble) -> DurableTeammateChatService {
    DurableTeammateChatService(
        teammateRepository: repository, conversationRepository: repository,
        messageRepository: repository, provisioningRepository: repository, selectionRepository: repository
    )
}

private func selectionTestChat() throws -> DurableDirectChatSnapshot {
    let now = Date(timeIntervalSince1970: 1_000)
    let teammate = try Teammate(
        id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Ada", role: "Research partner"),
        appearance: AgentAppearance(
            mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
            paletteToken: "sky", eyeDialect: "round", nonColorIdentityCue: "single crest",
            accessibleIdentityDescription: "Round creature with one crest"
        ), createdAt: now, updatedAt: now
    )
    let conversation = try Conversation(
        id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id), title: "Ada",
        createdAt: now, updatedAt: now
    )
    return DurableDirectChatSnapshot(teammate: teammate, conversation: conversation)
}

private actor SelectionRepositoryDouble:
    TeammateRepository, ConversationRepository, MessageRepository,
    DirectChatProvisioningRepository, ChatSelectionRepository
{
    private let chats: [DurableDirectChatSnapshot]
    private let suspendedConversationID: ConversationID?
    private let suspendTeammate: Bool
    private let suspension: SelectionReadSuspension?
    private let cancelAfterCommit: Bool
    private var selection: ConversationID?
    private(set) var validationReads = 0
    private(set) var writes: [ConversationID?] = []

    init(
        chats: [DurableDirectChatSnapshot], selection: ConversationID? = nil,
        suspendedConversationID: ConversationID? = nil, suspendTeammate: Bool = false,
        suspension: SelectionReadSuspension? = nil, cancelAfterCommit: Bool = false
    ) {
        self.chats = chats
        self.selection = selection
        self.suspendedConversationID = suspendedConversationID
        self.suspendTeammate = suspendTeammate
        self.suspension = suspension
        self.cancelAfterCommit = cancelAfterCommit
    }

    func teammate(id: TeammateID) async throws -> Teammate? {
        validationReads += 1
        let chat = chats.first { $0.teammate.id == id }
        if suspendTeammate, chat?.conversation.id == suspendedConversationID, let suspension {
            await suspension.suspend()
        }
        return chat?.teammate
    }

    func conversation(id: ConversationID) async throws -> Conversation? {
        validationReads += 1
        if !suspendTeammate, id == suspendedConversationID, let suspension { await suspension.suspend() }
        return chats.first { $0.conversation.id == id }?.conversation
    }

    func selectedConversationID() async throws -> ConversationID? { selection }
    func setSelectedConversationID(_ conversationID: ConversationID?) async throws {
        writes.append(conversationID)
        selection = conversationID
        if cancelAfterCommit { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { throw unexpectedCall() }
    func insert(_ teammate: Teammate) async throws { throw unexpectedCall() }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws { throw unexpectedCall() }
    func conversations(for teammateID: TeammateID, includingArchived: Bool) async throws -> [Conversation] { throw unexpectedCall() }
    func insert(_ conversation: Conversation, participantIDs: Set<TeammateID>) async throws { throw unexpectedCall() }
    func update(_ conversation: Conversation) async throws { throw unexpectedCall() }
    func provisionDirectChat(teammate: Teammate, conversation: Conversation, fixtureGreeting: Message?, selectConversation: Bool) async throws { throw unexpectedCall() }
    func append(_ message: Message, expectedPreviousSequence: Int64) async throws { throw unexpectedCall() }
    func message(id: MessageID) async throws -> Message? { throw unexpectedCall() }
    func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message> { throw unexpectedCall() }
    func updateDeliveryState(messageID: MessageID, from expectedState: MessageDeliveryState, to newState: MessageDeliveryState, updatedAt: Date) async throws { throw unexpectedCall() }
    private func unexpectedCall() -> RepositoryError { .unavailable(reason: "Unexpected repository operation in selection test") }
}

private actor SelectionReadSuspension {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { readWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() { readWaiter?.resume(); readWaiter = nil }
}
