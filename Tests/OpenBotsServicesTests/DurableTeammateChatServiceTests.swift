import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

private struct DurableChatFixedClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private final class DurableChatSequenceUUIDGenerator: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        precondition(!values.isEmpty, "Test UUID sequence exhausted")
        return values.removeFirst()
    }
}

private struct ProvisionCall: Equatable, Sendable {
    let teammate: Teammate
    let conversation: Conversation
    let fixtureGreeting: Message?
    let selectConversation: Bool
}

private struct DurableChatRepositorySnapshot: Equatable, Sendable {
    let teammates: [Teammate]
    let conversations: [Conversation]
    let messages: [Message]
    let selectedConversationID: ConversationID?
    let provisionCalls: [ProvisionCall]
    let teammateInsertCount: Int
    let conversationInsertCount: Int
    let messageAppendAttemptCount: Int
    let pageRequests: [PageRequest]
}

private actor DurableChatRepositoryFake:
    TeammateRepository,
    ConversationRepository,
    MessageRepository,
    DirectChatProvisioningRepository,
    ChatSelectionRepository
{
    private var teammates: [TeammateID: Teammate]
    private var conversations: [ConversationID: Conversation]
    private var messages: [ConversationID: [Message]]
    private var selection: ConversationID?
    private var provisionCalls: [ProvisionCall] = []
    private var teammateInsertCount = 0
    private var conversationInsertCount = 0
    private var messageAppendAttemptCount = 0
    private var pageRequests: [PageRequest] = []
    private let provisioningFailure: RepositoryError?
    private let failingAppendSequences: Set<Int64>

    init(
        teammates: [Teammate] = [],
        conversations: [Conversation] = [],
        messages: [Message] = [],
        selection: ConversationID? = nil,
        provisioningFailure: RepositoryError? = nil,
        failingAppendSequences: Set<Int64> = []
    ) {
        self.teammates = Dictionary(uniqueKeysWithValues: teammates.map { ($0.id, $0) })
        self.conversations = Dictionary(
            uniqueKeysWithValues: conversations.map { ($0.id, $0) }
        )
        self.messages = Dictionary(
            grouping: messages,
            by: \.conversationID
        )
        self.selection = selection
        self.provisioningFailure = provisioningFailure
        self.failingAppendSequences = failingAppendSequences
    }

    func teammate(id: TeammateID) async throws -> Teammate? {
        teammates[id]
    }

    func listTeammates(includingArchived: Bool) async throws -> [Teammate] {
        teammates.values
            .filter { includingArchived || $0.lifecycle != .archived }
            .sorted { $0.id.persistedValue < $1.id.persistedValue }
    }

    func insert(_ teammate: Teammate) async throws {
        teammateInsertCount += 1
        guard teammates[teammate.id] == nil else {
            throw RepositoryError.alreadyExists(
                entity: "teammate",
                id: teammate.id.persistedValue
            )
        }
        teammates[teammate.id] = teammate
    }

    func update(
        _ teammate: Teammate,
        expectedProfileRevision: UInt64
    ) async throws {
        guard teammates[teammate.id]?.profile.revision == expectedProfileRevision else {
            throw RepositoryError.optimisticLockFailed(
                entity: "teammate",
                id: teammate.id.persistedValue
            )
        }
        teammates[teammate.id] = teammate
    }

    func conversation(id: ConversationID) async throws -> Conversation? {
        conversations[id]
    }

    func conversations(
        for teammateID: TeammateID,
        includingArchived: Bool
    ) async throws -> [Conversation] {
        conversations.values
            .filter { conversation in
                guard case let .direct(subjectID) = conversation.kind,
                      subjectID == teammateID else {
                    return false
                }
                return includingArchived || conversation.lifecycle != .archived
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.persistedValue < $1.id.persistedValue
            }
    }

    func insert(
        _ conversation: Conversation,
        participantIDs: Set<TeammateID>
    ) async throws {
        conversationInsertCount += 1
        guard conversations[conversation.id] == nil else {
            throw RepositoryError.alreadyExists(
                entity: "conversation",
                id: conversation.id.persistedValue
            )
        }
        conversations[conversation.id] = conversation
    }

    func update(_ conversation: Conversation) async throws {
        guard conversations[conversation.id] != nil else {
            throw RepositoryError.notFound(
                entity: "conversation",
                id: conversation.id.persistedValue
            )
        }
        conversations[conversation.id] = conversation
    }

    func provisionDirectChat(
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws {
        provisionCalls.append(
            ProvisionCall(
                teammate: teammate,
                conversation: conversation,
                fixtureGreeting: fixtureGreeting,
                selectConversation: selectConversation
            )
        )
        if let provisioningFailure {
            throw provisioningFailure
        }

        guard case .direct(teammate.id) = conversation.kind else {
            throw RepositoryError.unavailable(reason: "invalid direct-chat fixture")
        }
        if let fixtureGreeting {
            guard fixtureGreeting.conversationID == conversation.id,
                  fixtureGreeting.sequence == 1,
                  fixtureGreeting.author == .teammate(teammate.id) else {
                throw RepositoryError.unavailable(reason: "invalid greeting fixture")
            }
        }

        teammates[teammate.id] = teammate
        conversations[conversation.id] = conversation
        if let fixtureGreeting {
            messages[conversation.id, default: []].append(fixtureGreeting)
        }
        if selectConversation {
            selection = conversation.id
        }
    }

    func selectedConversationID() async throws -> ConversationID? {
        selection
    }

    func setSelectedConversationID(_ conversationID: ConversationID?) async throws {
        selection = conversationID
    }

    func append(
        _ message: Message,
        expectedPreviousSequence: Int64
    ) async throws {
        messageAppendAttemptCount += 1
        // Deliberately permit actor reentrancy. Without the service's FIFO send
        // gate, rapid callers can both observe the same latest sequence.
        await Task.yield()

        let existing = messages[message.conversationID, default: []]
        let actualSequence = existing.map(\.sequence).max() ?? 0
        guard actualSequence == expectedPreviousSequence,
              message.sequence == actualSequence + 1 else {
            throw RepositoryError.sequenceConflict(
                conversationID: message.conversationID,
                expected: expectedPreviousSequence,
                actual: actualSequence
            )
        }
        if failingAppendSequences.contains(message.sequence) {
            throw RepositoryError.unavailable(reason: "injected append failure")
        }
        guard !existing.contains(where: { $0.id == message.id }) else {
            throw RepositoryError.alreadyExists(
                entity: "message",
                id: message.id.persistedValue
            )
        }
        messages[message.conversationID, default: []].append(message)
    }

    func message(id: MessageID) async throws -> Message? {
        messages.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    func page(
        conversationID: ConversationID,
        request: PageRequest
    ) async throws -> Page<Message> {
        pageRequests.append(request)
        let boundary = request.beforeSequence ?? Int64.max
        let descending = messages[conversationID, default: []]
            .filter { $0.sequence < boundary }
            .sorted { $0.sequence > $1.sequence }
        let hasMore = descending.count > request.limit
        let selected = descending.prefix(request.limit).reversed()
        return Page(elements: Array(selected), hasMore: hasMore)
    }

    func updateDeliveryState(
        messageID: MessageID,
        from expectedState: MessageDeliveryState,
        to newState: MessageDeliveryState,
        updatedAt: Date
    ) async throws {
        for conversationID in messages.keys {
            guard let index = messages[conversationID]?.firstIndex(where: { $0.id == messageID })
            else {
                continue
            }
            guard messages[conversationID]?[index].deliveryState == expectedState else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "message",
                    id: messageID.persistedValue
                )
            }
            messages[conversationID]?[index].deliveryState = newState
            messages[conversationID]?[index].updatedAt = updatedAt
            return
        }
        throw RepositoryError.notFound(entity: "message", id: messageID.persistedValue)
    }

    func snapshot() -> DurableChatRepositorySnapshot {
        DurableChatRepositorySnapshot(
            teammates: teammates.values.sorted {
                $0.id.persistedValue < $1.id.persistedValue
            },
            conversations: conversations.values.sorted {
                $0.id.persistedValue < $1.id.persistedValue
            },
            messages: messages.values.flatMap { $0 }.sorted {
                if $0.conversationID != $1.conversationID {
                    return $0.conversationID.persistedValue
                        < $1.conversationID.persistedValue
                }
                return $0.sequence < $1.sequence
            },
            selectedConversationID: selection,
            provisionCalls: provisionCalls,
            teammateInsertCount: teammateInsertCount,
            conversationInsertCount: conversationInsertCount,
            messageAppendAttemptCount: messageAppendAttemptCount,
            pageRequests: pageRequests
        )
    }
}

@Test("Active direct chats restore selection and load history incrementally")
func durableChatLoadAndSelection() async throws {
    let fixture = try makeDurableChatFixture(messageCount: 3)
    let repository = DurableChatRepositoryFake(
        teammates: [fixture.teammate],
        conversations: [fixture.conversation],
        messages: fixture.messages,
        selection: fixture.conversation.id
    )
    let service = makeService(repository: repository, generatedUUIDs: [])

    let chats = try await service.activeDirectChats()
    #expect(
        chats == [
            DurableDirectChatSnapshot(
                teammate: fixture.teammate,
                conversation: fixture.conversation
            )
        ]
    )

    let selected = try #require(try await service.selectedDirectChat())
    #expect(selected.teammate == fixture.teammate)
    #expect(selected.conversation == fixture.conversation)

    let newest = try await service.loadMessages(
        conversationID: fixture.conversation.id,
        beforeSequence: nil,
        limit: 2
    )
    #expect(newest.messages.map(\.sequence) == [2, 3])
    #expect(newest.hasMore)
    #expect(newest.nextBeforeSequence == 2)

    let older = try await service.loadMessages(
        conversationID: fixture.conversation.id,
        beforeSequence: newest.nextBeforeSequence,
        limit: 2
    )
    #expect(older.messages.map(\.sequence) == [1])
    #expect(older.hasMore == false)
    #expect(older.nextBeforeSequence == nil)

    try await service.clearSelection()
    #expect(try await service.selectedDirectChat() == nil)
    try await service.select(
        teammateID: fixture.teammate.id,
        conversationID: fixture.conversation.id
    )
    #expect(try await service.selectedDirectChat()?.conversation.id == fixture.conversation.id)
}

@Test("Creation preserves exact identity and appearance in one atomic provisioning call")
func durableChatAtomicCreation() async throws {
    let repository = DurableChatRepositoryFake()
    let teammateID = TeammateID(uuid("91000000-0000-0000-0000-000000000001"))
    let conversationUUID = uuid("91000000-0000-0000-0000-000000000002")
    let greetingUUID = uuid("91000000-0000-0000-0000-000000000003")
    let greetingPartUUID = uuid("91000000-0000-0000-0000-000000000004")
    let appearance = try exactAppearance(seed: 9_100)
    let service = makeService(
        repository: repository,
        generatedUUIDs: [conversationUUID, greetingUUID, greetingPartUUID]
    )

    let created = try await service.createTeammateAndDirectChat(
        DurableTeammateDraft(
            teammateID: teammateID,
            displayName: "  Ada  ",
            role: "  Research partner  ",
            appearance: appearance
        )
    )

    #expect(created.teammate.id == teammateID)
    #expect(created.teammate.profile.displayName == "Ada")
    #expect(created.teammate.profile.role == "Research partner")
    #expect(created.teammate.appearance == appearance)
    #expect(created.conversation.id == ConversationID(conversationUUID))
    let greeting = try #require(created.fixtureGreeting)
    #expect(greeting.id == MessageID(greetingUUID))
    #expect(greeting.author == .teammate(teammateID))
    #expect(greeting.sequence == 1)
    #expect(greeting.text.contains(DurableTeammateChatService.fixtureGreetingPrefix))
    #expect(greeting.text.contains("No Claude runtime or tool ran."))
    #expect(created.selection.conversation.id == created.conversation.id)

    let state = await repository.snapshot()
    #expect(state.provisionCalls.count == 1)
    #expect(state.provisionCalls.first?.teammate == created.teammate)
    #expect(state.provisionCalls.first?.conversation == created.conversation)
    #expect(state.provisionCalls.first?.fixtureGreeting == created.fixtureGreeting)
    #expect(state.provisionCalls.first?.selectConversation == true)
    #expect(state.teammateInsertCount == 0)
    #expect(state.conversationInsertCount == 0)
    #expect(state.messageAppendAttemptCount == 0)
    #expect(state.teammates == [created.teammate])
    #expect(state.conversations == [created.conversation])
    #expect(state.messages == [greeting])
    #expect(state.selectedConversationID == created.conversation.id)
}

@Test("Rapid sends remain ordered and persist exact caller messages plus explicit fixture replies")
func durableChatRapidSendOrderingAndProvenance() async throws {
    let fixture = try makeDurableChatFixture(messageCount: 1)
    let repository = DurableChatRepositoryFake(
        teammates: [fixture.teammate],
        conversations: [fixture.conversation],
        messages: fixture.messages,
        selection: fixture.conversation.id
    )
    let generated = (1...6).map {
        uuid(String(format: "92000000-0000-0000-0000-%012d", $0))
    }
    let service = makeService(repository: repository, generatedUUIDs: generated)
    let firstID = MessageID(uuid("92000000-0000-0000-0001-000000000001"))
    let secondID = MessageID(uuid("92000000-0000-0000-0001-000000000002"))
    let firstText = "  Keep these exact spaces.\n"
    let secondText = "Second rapid steering input"

    let firstTask = Task {
        try await service.sendMessageToLocalFixture(
            conversationID: fixture.conversation.id,
            teammateID: fixture.teammate.id,
            userMessageID: firstID,
            text: firstText
        )
    }
    await Task.yield()
    let secondTask = Task {
        try await service.sendMessageToLocalFixture(
            conversationID: fixture.conversation.id,
            teammateID: fixture.teammate.id,
            userMessageID: secondID,
            text: secondText
        )
    }
    let exchanges = try await [firstTask.value, secondTask.value]

    let state = await repository.snapshot()
    let newMessages = state.messages.filter { $0.sequence > 1 }
    #expect(newMessages.map(\.sequence) == [2, 3, 4, 5])
    #expect(newMessages.map(\.author) == [
        .user,
        .teammate(fixture.teammate.id),
        .user,
        .teammate(fixture.teammate.id)
    ])

    let durableUsers = newMessages.filter { $0.author == .user }
    #expect(Set(durableUsers.map(\.id)) == Set([firstID, secondID]))
    #expect(Set(durableUsers.map(\.text)) == Set([firstText, secondText]))

    let fixtureReplies = newMessages.filter {
        $0.author == .teammate(fixture.teammate.id)
    }
    #expect(fixtureReplies.count == 2)
    #expect(fixtureReplies.allSatisfy { $0.text == DurableTeammateChatService.fixtureReplyText })
    #expect(fixtureReplies.allSatisfy { $0.text.contains("No Claude runtime or tool ran.") })
    #expect(exchanges.map(\.userMessage.id).allSatisfy { [firstID, secondID].contains($0) })
    #expect(state.pageRequests.filter { $0.limit == 1 }.count == 2)
}

@Test("Provisioning and reply failures never fabricate a complete durable result")
func durableChatFailureBehavior() async throws {
    let provisioningError = RepositoryError.unavailable(
        reason: "injected provisioning failure"
    )
    let failedCreationRepository = DurableChatRepositoryFake(
        provisioningFailure: provisioningError
    )
    let failedCreationService = makeService(
        repository: failedCreationRepository,
        generatedUUIDs: [
            uuid("93000000-0000-0000-0000-000000000001"),
            uuid("93000000-0000-0000-0000-000000000002"),
            uuid("93000000-0000-0000-0000-000000000003")
        ]
    )

    await #expect(throws: RepositoryError.self) {
        try await failedCreationService.createTeammateAndDirectChat(
            DurableTeammateDraft(
                teammateID: TeammateID(
                    uuid("93000000-0000-0000-0000-000000000004")
                ),
                displayName: "Ada",
                role: "Researcher",
                appearance: try exactAppearance(seed: 9_300)
            )
        )
    }
    let failedCreationState = await failedCreationRepository.snapshot()
    #expect(failedCreationState.provisionCalls.count == 1)
    #expect(failedCreationState.teammates.isEmpty)
    #expect(failedCreationState.conversations.isEmpty)
    #expect(failedCreationState.messages.isEmpty)
    #expect(failedCreationState.selectedConversationID == nil)

    let fixture = try makeDurableChatFixture(messageCount: 1)
    let failedReplyRepository = DurableChatRepositoryFake(
        teammates: [fixture.teammate],
        conversations: [fixture.conversation],
        messages: fixture.messages,
        failingAppendSequences: [3]
    )
    let userID = MessageID(uuid("93000000-0000-0000-0001-000000000001"))
    let failedReplyService = makeService(
        repository: failedReplyRepository,
        generatedUUIDs: [
            uuid("93000000-0000-0000-0001-000000000002"),
            uuid("93000000-0000-0000-0001-000000000003"),
            uuid("93000000-0000-0000-0001-000000000004")
        ]
    )

    var committedUser: Message?
    do {
        _ = try await failedReplyService.sendMessageToLocalFixture(
            conversationID: fixture.conversation.id,
            teammateID: fixture.teammate.id,
            userMessageID: userID,
            text: "Exact durable input"
        )
        Issue.record("A failed nontransactional fixture reply must report its committed user message.")
    } catch let DurableTeammateChatError.fixtureReplyUnavailable(userMessage) {
        committedUser = userMessage
    }
    let failedReplyState = await failedReplyRepository.snapshot()
    #expect(failedReplyState.messages.map(\.sequence) == [1, 2])
    #expect(failedReplyState.messages.last?.id == userID)
    #expect(failedReplyState.messages.last?.text == "Exact durable input")
    #expect(committedUser == failedReplyState.messages.last)
    #expect(committedUser?.deliveryState == .completed)
    #expect(failedReplyState.messageAppendAttemptCount == 2)
    #expect(
        failedReplyState.messages.contains {
            $0.text == DurableTeammateChatService.fixtureReplyText
        } == false
    )
}

@Test("A real SQLite message repository automatically uses the atomic fixture exchange")
func durableChatInfersSQLiteTransactionBoundary() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextChatAtomicInference-\(UUID()).noindex", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
    let store = try SQLiteStore(configuration: SQLiteStoreConfiguration(
        fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: receipt)))
    let fixture = try makeDurableChatFixture(messageCount: 1)
    try await store.provisionDirectChat(teammate: fixture.teammate, conversation: fixture.conversation,
                                      fixtureGreeting: fixture.messages[0], selectConversation: true)
    _ = try await store.execute(sql: "CREATE TRIGGER reject_inferred_reply BEFORE INSERT ON messages WHEN NEW.sequence=3 BEGIN SELECT RAISE(ABORT,'injected reply failure'); END;")
    // No explicit attachment repository: capability is inferred from the real message store.
    let service = DurableTeammateChatService(mode: .reviewFixture, teammateRepository: store, conversationRepository: store,
        messageRepository: store, provisioningRepository: store, selectionRepository: store,
        clock: DurableChatFixedClock(value: Date(timeIntervalSince1970: 9_000)))
    let userID = MessageID(UUID())
    await #expect(throws: SQLiteStoreError.self) {
        try await service.sendMessageToLocalFixture(conversationID: fixture.conversation.id,
            teammateID: fixture.teammate.id, userMessageID: userID, text: "Must roll back with its reply")
    }
    #expect(try await store.message(id: userID) == nil)
    #expect(try await store.page(conversationID: fixture.conversation.id, request: PageRequest(limit: 10)).elements == fixture.messages)
}

@Test("Normal local creation and saves persist only user work, without a greeting or reply")
func durableChatLocalOnlyPersistence() async throws {
    let repository = DurableChatRepositoryFake()
    let service = DurableTeammateChatService(
        teammateRepository: repository, conversationRepository: repository,
        messageRepository: repository, provisioningRepository: repository, selectionRepository: repository
    )
    let created = try await service.createTeammateAndDirectChat(DurableTeammateDraft(
        teammateID: TeammateID(UUID()), displayName: "Local partner", role: "Research",
        appearance: exactAppearance(seed: 9_901)
    ))
    #expect(created.fixtureGreeting == nil)
    #expect(await repository.snapshot().messages.isEmpty)
    #expect(await repository.snapshot().selectedConversationID == created.conversation.id)

    let firstID = MessageID(UUID())
    let secondID = MessageID(UUID())
    let exactText = "  Exact local note\nwith whitespace  "
    async let firstSave = service.saveMessageLocally(
        conversationID: created.conversation.id, teammateID: created.teammate.id,
        userMessageID: firstID, text: exactText
    )
    async let secondSave = service.saveMessageLocally(
        conversationID: created.conversation.id, teammateID: created.teammate.id,
        userMessageID: secondID, text: "Another saved note"
    )
    let saves = try await [firstSave, secondSave]
    let snapshot = await repository.snapshot()
    #expect(snapshot.messages.map(\.sequence) == [1, 2])
    #expect(Set(saves.map(\.id)) == [firstID, secondID])
    #expect(snapshot.messages.allSatisfy { $0.author == .user && $0.deliveryState == .completed })
    #expect(snapshot.messages.first(where: { $0.id == firstID })?.text == exactText)
    #expect(snapshot.messages.count == 2)
    await #expect(throws: DurableTeammateChatError.reviewFixtureUnavailable) {
        try await service.sendMessageToLocalFixture(
            conversationID: created.conversation.id, teammateID: created.teammate.id,
            userMessageID: MessageID(UUID()), text: "Must not create a simulated reply"
        )
    }
    #expect(await repository.snapshot().messages == snapshot.messages)
}

private func makeService(
    repository: DurableChatRepositoryFake,
    generatedUUIDs: [UUID]
) -> DurableTeammateChatService {
    DurableTeammateChatService(mode: .reviewFixture,
        teammateRepository: repository,
        conversationRepository: repository,
        messageRepository: repository,
        provisioningRepository: repository,
        selectionRepository: repository,
        clock: DurableChatFixedClock(value: Date(timeIntervalSince1970: 9_000)),
        uuidGenerator: DurableChatSequenceUUIDGenerator(generatedUUIDs)
    )
}

private func makeDurableChatFixture(
    messageCount: Int
) throws -> (teammate: Teammate, conversation: Conversation, messages: [Message]) {
    let timestamp = Date(timeIntervalSince1970: 8_000)
    let teammateID = TeammateID(uuid("90000000-0000-0000-0000-000000000001"))
    let conversationID = ConversationID(
        uuid("90000000-0000-0000-0000-000000000002")
    )
    let teammate = try Teammate(
        id: teammateID,
        profile: TeammateProfile(displayName: "Ada", role: "Researcher"),
        appearance: exactAppearance(seed: 9_000),
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let conversation = try Conversation(
        id: conversationID,
        kind: .direct(teammateID: teammateID),
        title: "Ada",
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let messages = try (1...messageCount).map { index in
        try Message(
            id: MessageID(
                uuid(String(format: "90000000-0000-0000-0001-%012d", index))
            ),
            conversationID: conversationID,
            sequence: Int64(index),
            author: index.isMultiple(of: 2) ? .user : .teammate(teammateID),
            deliveryState: .completed,
            parts: [
                try MessagePart(
                    id: MessagePartID(
                        uuid(String(format: "90000000-0000-0000-0002-%012d", index))
                    ),
                    ordinal: 0,
                    content: .text("Message \(index)")
                )
            ],
            createdAt: timestamp.addingTimeInterval(TimeInterval(index)),
            updatedAt: timestamp.addingTimeInterval(TimeInterval(index))
        )
    }
    return (teammate, conversation, messages)
}

private func exactAppearance(seed: UInt64) throws -> AgentAppearance {
    try AgentAppearance(
        mode: .creature,
        grammarVersion: 7,
        deterministicSeed: seed,
        silhouette: "tall-tuft",
        paletteToken: "violet-coral",
        eyeDialect: "wide-curious",
        nonColorIdentityCue: "forehead spark",
        accessibleIdentityDescription: "Tall tuft creature with wide curious eyes and a forehead spark",
        revision: 4
    )
}

private func uuid(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        preconditionFailure("Invalid test UUID: \(value)")
    }
    return uuid
}

private extension Message {
    var text: String {
        parts.compactMap { part in
            guard case let .text(value) = part.content else { return nil }
            return value
        }
        .joined(separator: "\n")
    }
}
