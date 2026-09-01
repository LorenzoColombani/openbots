import Foundation
import OpenBotsDomain

/// Normal local work never fabricates a teammate response or queues a future
/// runtime request. Synthetic exchanges belong only to the explicit review harness.
public enum LocalChatMode: Equatable, Sendable {
    case localOnly
    case reviewFixture
}

public struct DurableTeammateDraft: Equatable, Sendable {
    public let teammateID: TeammateID
    public let displayName: String
    public let role: String
    public let appearance: AgentAppearance

    public init(
        teammateID: TeammateID,
        displayName: String? = nil,
        role: String,
        appearance: AgentAppearance
    ) {
        self.teammateID = teammateID
        self.displayName = displayName ?? Self.defaultName(for: appearance)
        self.role = role
        self.appearance = appearance
    }

    private static func defaultName(for appearance: AgentAppearance) -> String {
        guard appearance.mode == .creature else { return "New Bot" }
        switch appearance.builtInAvatarID {
        case "fin": return "Yogurt"
        case "guide": return "Canobi"
        default: return "New Bot"
        }
    }
}

public struct DurableDirectChatSnapshot: Equatable, Sendable, Identifiable {
    public let teammate: Teammate
    public let conversation: Conversation

    public var id: ConversationID { conversation.id }

    public init(teammate: Teammate, conversation: Conversation) {
        self.teammate = teammate
        self.conversation = conversation
    }
}

public struct DurableChatSelectionSnapshot: Equatable, Sendable {
    public let teammate: Teammate
    public let conversation: Conversation

    public init(teammate: Teammate, conversation: Conversation) {
        self.teammate = teammate
        self.conversation = conversation
    }
}

public struct DurableMessagePageSnapshot: Equatable, Sendable {
    public let conversationID: ConversationID
    public let messages: [Message]
    public let hasMore: Bool
    public let nextBeforeSequence: Int64?

    public init(
        conversationID: ConversationID,
        messages: [Message],
        hasMore: Bool,
        nextBeforeSequence: Int64?
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.hasMore = hasMore
        self.nextBeforeSequence = nextBeforeSequence
    }
}

public struct DurableTeammateChatCreationSnapshot: Equatable, Sendable {
    public let teammate: Teammate
    public let conversation: Conversation
    public let fixtureGreeting: Message?
    public let selection: DurableChatSelectionSnapshot

    public init(
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selection: DurableChatSelectionSnapshot
    ) {
        self.teammate = teammate
        self.conversation = conversation
        self.fixtureGreeting = fixtureGreeting
        self.selection = selection
    }
}

public struct DurableLocalFixtureExchangeSnapshot: Equatable, Sendable {
    public let userMessage: Message
    public let fixtureReply: Message

    public init(userMessage: Message, fixtureReply: Message) {
        self.userMessage = userMessage
        self.fixtureReply = fixtureReply
    }
}

public enum DurableTeammateChatError: Error, Equatable, Sendable {
    case teammateUnavailable(TeammateID)
    case conversationUnavailable(ConversationID)
    case conversationIsNotActiveDirectChat(
        conversationID: ConversationID,
        teammateID: TeammateID
    )
    case messageSequenceExhausted(ConversationID)
    case localMessageSavingUnavailable
    case reviewFixtureUnavailable
    /// A nontransactional adapter committed this user message but could not
    /// append its local fixture reply. Retrying the user send would duplicate it.
    case fixtureReplyUnavailable(userMessage: Message)
}

public protocol DurableTeammateChatServing: Sendable {
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot]
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot?
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws
    func clearSelection() async throws
    func createTeammateAndDirectChat(
        _ draft: DurableTeammateDraft
    ) async throws -> DurableTeammateChatCreationSnapshot
    func loadMessages(
        conversationID: ConversationID,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> DurableMessagePageSnapshot
    /// Save one user-authored local message. This creates no reply or runtime outbox item.
    func saveMessageLocally(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> Message
    func sendMessageToLocalFixture(
        conversationID: ConversationID,
        teammateID: TeammateID,
        userMessageID: MessageID,
        text: String
    ) async throws -> DurableLocalFixtureExchangeSnapshot
    func sendMessageToLocalFixture(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> DurableLocalFixtureExchangeSnapshot
}

public extension DurableTeammateChatServing {
    func saveMessageLocally(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> Message {
        // Older review adapters must not silently turn a normal save into a
        // simulated exchange just to satisfy the expanded interface.
        throw DurableTeammateChatError.localMessageSavingUnavailable
    }

    func sendMessageToLocalFixture(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        guard attachmentIDs.isEmpty else { throw ConversationAttachmentError.unavailable }
        return try await sendMessageToLocalFixture(conversationID: conversationID,
            teammateID: teammateID, userMessageID: userMessageID, text: text)
    }
}

/// Coordinates the smallest durable teammate/chat vertical slice.
///
/// This actor owns ordering only. Repositories own durability and transactions;
/// no executor, credential provider, network client, or filesystem root is
/// reachable from this service.
public actor DurableTeammateChatService: DurableTeammateChatServing {
    public static let fixtureGreetingPrefix = "Local review fixture —"
    public static let fixtureReplyText =
        "Local review fixture reply — your message was stored by OpenBots’ local demo adapter. No Claude runtime or tool ran."

    private let teammateRepository: any TeammateRepository
    private let conversationRepository: any ConversationRepository
    private let messageRepository: any MessageRepository
    private let provisioningRepository: any DirectChatProvisioningRepository
    private let selectionRepository: any ChatSelectionRepository
    private let attachmentRepository: (any AttachmentRepository)?
    private let attachmentValidator: (any AttachmentContentValidating)?
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator
    private let mode: LocalChatMode

    private var sendTurnIsHeld = false
    private var sendTurnWaiters: [CheckedContinuation<Void, Never>] = []
    private var selectionGeneration: UInt64 = 0

    public init(
        mode: LocalChatMode = .localOnly,
        teammateRepository: any TeammateRepository,
        conversationRepository: any ConversationRepository,
        messageRepository: any MessageRepository,
        provisioningRepository: any DirectChatProvisioningRepository,
        selectionRepository: any ChatSelectionRepository,
        attachmentRepository: (any AttachmentRepository)? = nil,
        attachmentValidator: (any AttachmentContentValidating)? = nil,
        clock: any OpenBotsClock = SystemClock(),
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()
    ) {
        self.teammateRepository = teammateRepository
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.provisioningRepository = provisioningRepository
        self.selectionRepository = selectionRepository
        self.attachmentRepository = attachmentRepository ?? (messageRepository as? any AttachmentRepository)
        self.attachmentValidator = attachmentValidator
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.mode = mode
    }

    public func activeDirectChats() async throws -> [DurableDirectChatSnapshot] {
        let teammates = try await teammateRepository.listTeammates(includingArchived: false)
        var snapshots: [DurableDirectChatSnapshot] = []

        for teammate in teammates where teammate.lifecycle == .active {
            let conversations = try await conversationRepository.conversations(
                for: teammate.id,
                includingArchived: false
            )
            for conversation in conversations
            where conversation.lifecycle == .active
                && conversation.isDirectChat(with: teammate.id) {
                snapshots.append(
                    DurableDirectChatSnapshot(
                        teammate: teammate,
                        conversation: conversation
                    )
                )
            }
        }

        let sidebarOrder = try await (teammateRepository as? any BotSidebarOrderRepository)?.loadBotSidebarOrder()
        let positions = Dictionary(uniqueKeysWithValues: (sidebarOrder?.teammateIDs ?? []).enumerated().map { ($0.element, $0.offset) })
        return snapshots.sorted { left, right in
            if let sidebarOrder, !sidebarOrder.teammateIDs.isEmpty {
                let leftPosition = positions[left.teammate.id] ?? Int.max
                let rightPosition = positions[right.teammate.id] ?? Int.max
                if leftPosition != rightPosition { return leftPosition < rightPosition }
            }
            if left.teammate.isPinned != right.teammate.isPinned {
                return left.teammate.isPinned
            }
            if left.conversation.updatedAt != right.conversation.updatedAt {
                return left.conversation.updatedAt > right.conversation.updatedAt
            }
            return left.conversation.id.persistedValue < right.conversation.id.persistedValue
        }
    }

    public func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? {
        guard let conversationID = try await selectionRepository.selectedConversationID() else {
            return nil
        }
        let directChat = try await activeDirectChat(conversationID: conversationID)
        return DurableChatSelectionSnapshot(
            teammate: directChat.teammate,
            conversation: directChat.conversation
        )
    }

    public func select(
        teammateID: TeammateID,
        conversationID: ConversationID
    ) async throws {
        try Task.checkCancellation()
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let directChat = try await activeDirectChat(conversationID: conversationID)
        try Task.checkCancellation()
        // Validation suspends on repository reads. A newer select or clear
        // invalidates this old intent before it may reach the write boundary.
        guard generation == selectionGeneration else { throw CancellationError() }
        guard directChat.teammate.id == teammateID else {
            throw DurableTeammateChatError.conversationIsNotActiveDirectChat(
                conversationID: conversationID,
                teammateID: teammateID
            )
        }
        try await selectionRepository.setSelectedConversationID(conversationID)
        // Do not report cancellation after a successful repository commit as
        // though the completed navigation change had been rolled back.
    }

    public func clearSelection() async throws {
        try Task.checkCancellation()
        selectionGeneration &+= 1
        try await selectionRepository.setSelectedConversationID(nil)
    }

    public func createTeammateAndDirectChat(
        _ draft: DurableTeammateDraft
    ) async throws -> DurableTeammateChatCreationSnapshot {
        let profile = try TeammateProfile(
            displayName: draft.displayName,
            role: draft.role
        )
        let timestamp = clock.now()
        let teammate = try Teammate(
            id: draft.teammateID,
            profile: profile,
            appearance: draft.appearance,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let conversation = try Conversation(
            id: ConversationID(uuidGenerator.next()),
            kind: .direct(teammateID: teammate.id),
            title: teammate.profile.displayName,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let fixtureGreeting: Message? = if mode == .reviewFixture { try Message(
            id: MessageID(uuidGenerator.next()),
            conversationID: conversation.id,
            sequence: 1,
            author: .teammate(teammate.id),
            deliveryState: .completed,
            parts: [
                try MessagePart(
                    id: MessagePartID(uuidGenerator.next()),
                    ordinal: 0,
                    content: .text(
                        "\(Self.fixtureGreetingPrefix) \(teammate.profile.displayName) is ready for this interface review. No Claude runtime or tool ran."
                    )
                )
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        ) } else { nil }

        try await provisioningRepository.provisionDirectChat(
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: fixtureGreeting,
            selectConversation: true
        )

        let selection = DurableChatSelectionSnapshot(
            teammate: teammate,
            conversation: conversation
        )
        return DurableTeammateChatCreationSnapshot(
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: fixtureGreeting,
            selection: selection
        )
    }

    public func loadMessages(
        conversationID: ConversationID,
        beforeSequence: Int64? = nil,
        limit: Int = 50
    ) async throws -> DurableMessagePageSnapshot {
        guard let conversation = try await conversationRepository.conversation(id: conversationID)
        else {
            throw DurableTeammateChatError.conversationUnavailable(conversationID)
        }
        guard case .direct = conversation.kind else {
            throw DurableTeammateChatError.conversationUnavailable(conversationID)
        }

        let page = try await messageRepository.page(
            conversationID: conversationID,
            request: PageRequest(limit: limit, beforeSequence: beforeSequence)
        )
        return DurableMessagePageSnapshot(
            conversationID: conversationID,
            messages: page.elements,
            hasMore: page.hasMore,
            nextBeforeSequence: page.hasMore ? page.elements.first?.sequence : nil
        )
    }

    public func sendMessageToLocalFixture(
        conversationID: ConversationID,
        teammateID: TeammateID,
        userMessageID: MessageID,
        text: String
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        try await sendMessageToLocalFixture(conversationID: conversationID,
            teammateID: teammateID, userMessageID: userMessageID, text: text, attachmentIDs: [])
    }

    public func sendMessageToLocalFixture(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        guard mode == .reviewFixture else { throw DurableTeammateChatError.reviewFixtureUnavailable }
        await acquireSendTurn()
        defer { releaseSendTurn() }
        try Task.checkCancellation()

        return try await persistFixtureExchange(
            conversationID: conversationID,
            teammateID: teammateID,
            userMessageID: userMessageID,
            text: text,
            attachmentIDs: attachmentIDs
        )
    }

    public func saveMessageLocally(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID] = []
    ) async throws -> Message {
        await acquireSendTurn()
        defer { releaseSendTurn() }
        try Task.checkCancellation()
        let prepared = try await prepareUserMessage(
            conversationID: conversationID, teammateID: teammateID,
            userMessageID: userMessageID, text: text, attachmentIDs: attachmentIDs,
            reservedMessageCount: 1
        )
        if let attachmentRepository {
            try await attachmentRepository.commitLocalMessage(
                userMessage: prepared.message, expectedPreviousSequence: prepared.previousSequence,
                attachmentIDs: attachmentIDs
            )
        } else {
            try await messageRepository.append(prepared.message, expectedPreviousSequence: prepared.previousSequence)
        }
        return prepared.message
    }

    private func persistFixtureExchange(
        conversationID: ConversationID,
        teammateID: TeammateID,
        userMessageID: MessageID,
        text: String,
        attachmentIDs: [AttachmentID]
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        let prepared = try await prepareUserMessage(
            conversationID: conversationID, teammateID: teammateID,
            userMessageID: userMessageID, text: text, attachmentIDs: attachmentIDs,
            reservedMessageCount: 2
        )
        let userMessage = prepared.message
        let replyTimestamp = clock.now()
        let fixtureReply = try Message(
            id: MessageID(uuidGenerator.next()),
            conversationID: conversationID,
            sequence: userMessage.sequence + 1,
            author: .teammate(teammateID),
            deliveryState: .completed,
            parts: [
                try MessagePart(
                    id: MessagePartID(uuidGenerator.next()),
                    ordinal: 0,
                    content: .text(Self.fixtureReplyText)
                )
            ],
            createdAt: replyTimestamp,
            updatedAt: replyTimestamp
        )
        if let attachmentRepository {
            try await attachmentRepository.commitLocalFixtureExchange(
                userMessage: userMessage, fixtureReply: fixtureReply,
                expectedPreviousSequence: prepared.previousSequence, attachmentIDs: attachmentIDs)
        } else {
            try await messageRepository.append(userMessage, expectedPreviousSequence: prepared.previousSequence)
            do {
                try await messageRepository.append(fixtureReply, expectedPreviousSequence: userMessage.sequence)
            } catch {
                throw DurableTeammateChatError.fixtureReplyUnavailable(userMessage: userMessage)
            }
        }

        return DurableLocalFixtureExchangeSnapshot(userMessage: userMessage, fixtureReply: fixtureReply)
    }

    private func prepareUserMessage(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID],
        reservedMessageCount: Int64
    ) async throws -> (message: Message, previousSequence: Int64) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentIDs.isEmpty else {
            throw DomainValidationError.empty(field: "message text")
        }
        let directChat = try await activeDirectChat(conversationID: conversationID)
        guard directChat.teammate.id == teammateID else {
            throw DurableTeammateChatError.conversationIsNotActiveDirectChat(
                conversationID: conversationID,
                teammateID: teammateID
            )
        }

        let latestPage = try await messageRepository.page(
            conversationID: conversationID,
            request: PageRequest(limit: 1)
        )
        let latestSequence = latestPage.elements.last?.sequence ?? 0
        guard latestSequence <= Int64.max - reservedMessageCount else {
            throw DurableTeammateChatError.messageSequenceExhausted(conversationID)
        }

        let userTimestamp = clock.now()
        if !attachmentIDs.isEmpty {
            guard attachmentRepository != nil, let attachmentValidator else {
                throw ConversationAttachmentError.unavailable
            }
            try await attachmentValidator.validateAttachments(ids: attachmentIDs, conversationID: conversationID)
        }
        var userParts: [MessagePart] = []
        if !text.isEmpty {
            userParts.append(try MessagePart(id: MessagePartID(uuidGenerator.next()), ordinal: 0, content: .text(text)))
        }
        for id in attachmentIDs {
            userParts.append(try MessagePart(id: MessagePartID(uuidGenerator.next()), ordinal: userParts.count, content: .attachment(id)))
        }
        let userMessage = try Message(
            id: userMessageID,
            conversationID: conversationID,
            sequence: latestSequence + 1,
            author: .user,
            deliveryState: .completed,
            parts: userParts,
            createdAt: userTimestamp,
            updatedAt: userTimestamp
        )
        return (userMessage, latestSequence)
    }

    private func activeDirectChat(
        conversationID: ConversationID
    ) async throws -> DurableDirectChatSnapshot {
        guard let conversation = try await conversationRepository.conversation(id: conversationID),
              conversation.lifecycle == .active,
              case let .direct(teammateID) = conversation.kind
        else {
            throw DurableTeammateChatError.conversationUnavailable(conversationID)
        }
        guard let teammate = try await teammateRepository.teammate(id: teammateID),
              teammate.lifecycle == .active
        else {
            throw DurableTeammateChatError.teammateUnavailable(teammateID)
        }
        return DurableDirectChatSnapshot(teammate: teammate, conversation: conversation)
    }

    private func acquireSendTurn() async {
        if !sendTurnIsHeld {
            sendTurnIsHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            sendTurnWaiters.append(continuation)
        }
    }

    private func releaseSendTurn() {
        guard !sendTurnWaiters.isEmpty else {
            sendTurnIsHeld = false
            return
        }
        sendTurnWaiters.removeFirst().resume()
    }
}

private extension Conversation {
    func isDirectChat(with teammateID: TeammateID) -> Bool {
        guard case let .direct(subjectID) = kind else { return false }
        return subjectID == teammateID
    }
}
