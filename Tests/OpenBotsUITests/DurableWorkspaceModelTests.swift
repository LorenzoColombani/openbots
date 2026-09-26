import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

private actor DurableWorkspaceFakeService: DurableTeammateChatServing {
    private var chats: [DurableDirectChatSnapshot]
    private var selected: DurableChatSelectionSnapshot?
    private var messages: [ConversationID: [Message]]
    private let sendDelaysByText: [String: Duration]
    private let pageDelaysByBeforeSequence: [Int64: Duration]
    private let attachmentStore: WorkspaceDurableAttachmentStore?
    private let attachmentSendGate: WorkspaceAttachmentSendGate?
    /// Holds every `select` until released, so a test can keep a navigation
    /// in flight while something else happens to the roster.
    private let selectionGate: WorkspaceAttachmentSendGate?
    private let attachmentSendOutcome: WorkspaceAttachmentSendOutcome
    private(set) var createdDraft: DurableTeammateDraft?
    private(set) var sentTargets: [(ConversationID, TeammateID, MessageID, String)] = []
    private(set) var messagePageRequests: [(ConversationID, Int64?, Int)] = []
    private(set) var selectionWriteCount = 0
    private(set) var attachmentTargets: [(ConversationID, TeammateID, MessageID, String, [AttachmentID])] = []
    private(set) var localSaveTargets: [(ConversationID, TeammateID, MessageID, String, [AttachmentID])] = []

    init(
        chats: [DurableDirectChatSnapshot] = [],
        selected: DurableChatSelectionSnapshot? = nil,
        messages: [ConversationID: [Message]] = [:],
        sendDelaysByText: [String: Duration] = [:],
        pageDelaysByBeforeSequence: [Int64: Duration] = [:],
        attachmentStore: WorkspaceDurableAttachmentStore? = nil,
        attachmentSendGate: WorkspaceAttachmentSendGate? = nil,
        selectionGate: WorkspaceAttachmentSendGate? = nil,
        attachmentSendOutcome: WorkspaceAttachmentSendOutcome = .success
    ) {
        self.chats = chats
        self.selected = selected
        self.messages = messages
        self.sendDelaysByText = sendDelaysByText
        self.pageDelaysByBeforeSequence = pageDelaysByBeforeSequence
        self.attachmentStore = attachmentStore
        self.attachmentSendGate = attachmentSendGate
        self.selectionGate = selectionGate
        self.attachmentSendOutcome = attachmentSendOutcome
    }

    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { chats }

    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? { selected }

    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        if let selectionGate { await selectionGate.wait() }
        selectionWriteCount += 1
        guard let chat = chats.first(where: {
            $0.teammate.id == teammateID && $0.conversation.id == conversationID
        }) else {
            throw RepositoryError.notFound(entity: "direct chat", id: conversationID.persistedValue)
        }
        selected = DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        )
    }

    func clearSelection() async throws { selected = nil }

    /// New Bot's own path: the placeholder name, the question, selected.
    private(set) var selfSettingCreations: [(TeammateID, String)] = []
    func createSelfSettingTeammateAndDirectChat(
        teammateID: TeammateID, placeholderName: String, appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot {
        selfSettingCreations.append((teammateID, placeholderName))
        let timestamp = Date(timeIntervalSince1970: 9_100)
        let teammate = try Teammate(id: teammateID,
            profile: TeammateProfile(displayName: placeholderName, role: BotSelfSetup.placeholderRole),
            appearance: appearance, createdAt: timestamp, updatedAt: timestamp)
        let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id),
            title: placeholderName, createdAt: timestamp, updatedAt: timestamp)
        let question = try Self.textMessage(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1,
            author: .teammate(teammate.id), text: BotSelfSetup.firstQuestion, timestamp: timestamp)
        let chat = DurableDirectChatSnapshot(teammate: teammate, conversation: conversation)
        chats.append(chat)
        messages[conversation.id] = [question]
        let selection = DurableChatSelectionSnapshot(teammate: teammate, conversation: conversation)
        selected = selection
        return DurableTeammateChatCreationSnapshot(teammate: teammate, conversation: conversation,
                                                   fixtureGreeting: question, selection: selection)
    }
    var selfSettingCount: Int { selfSettingCreations.count }
    var selfSettingNames: [String] { selfSettingCreations.map(\.1) }

    func createTeammateAndDirectChat(
        _ draft: DurableTeammateDraft
    ) async throws -> DurableTeammateChatCreationSnapshot {
        createdDraft = draft
        let timestamp = Date(timeIntervalSince1970: 9_100)
        let teammate = try Teammate(
            id: draft.teammateID,
            profile: TeammateProfile(displayName: draft.displayName, role: draft.role),
            appearance: draft.appearance,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let conversation = try Conversation(
            id: ConversationID(UUID()),
            kind: .direct(teammateID: teammate.id),
            title: teammate.profile.displayName,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let greeting = try Self.textMessage(
            id: MessageID(UUID()),
            conversationID: conversation.id,
            sequence: 1,
            author: .teammate(teammate.id),
            text: "Local review fixture — no Claude runtime or tool ran.",
            timestamp: timestamp
        )
        let chat = DurableDirectChatSnapshot(teammate: teammate, conversation: conversation)
        chats.append(chat)
        messages[conversation.id] = [greeting]
        let selection = DurableChatSelectionSnapshot(
            teammate: teammate,
            conversation: conversation
        )
        selected = selection
        return DurableTeammateChatCreationSnapshot(
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: greeting,
            selection: selection
        )
    }

    func loadMessages(
        conversationID: ConversationID,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> DurableMessagePageSnapshot {
        messagePageRequests.append((conversationID, beforeSequence, limit))
        if let beforeSequence, let delay = pageDelaysByBeforeSequence[beforeSequence] {
            try await Task.sleep(for: delay)
        }
        let all = (messages[conversationID] ?? [])
            .filter { message in
                guard let beforeSequence else { return true }
                return message.sequence < beforeSequence
            }
            .sorted { $0.sequence < $1.sequence }
        let page = Array(all.suffix(limit))
        return DurableMessagePageSnapshot(
            conversationID: conversationID,
            messages: page,
            hasMore: all.count > limit,
            nextBeforeSequence: all.count > limit ? page.first?.sequence : nil
        )
    }

    func sendMessageToLocalFixture(
        conversationID: ConversationID,
        teammateID: TeammateID,
        userMessageID: MessageID,
        text: String
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        if let delay = sendDelaysByText[text] {
            try await Task.sleep(for: delay)
        }
        sentTargets.append((conversationID, teammateID, userMessageID, text))
        let sequence = Int64((messages[conversationID] ?? []).count + 1)
        let timestamp = Date(timeIntervalSince1970: 9_101)
        let user = try Self.textMessage(
            id: userMessageID,
            conversationID: conversationID,
            sequence: sequence,
            author: .user,
            text: text,
            timestamp: timestamp
        )
        let reply = try Self.textMessage(
            id: MessageID(UUID()),
            conversationID: conversationID,
            sequence: sequence + 1,
            author: .teammate(teammateID),
            text: DurableTeammateChatService.fixtureReplyText,
            timestamp: timestamp
        )
        messages[conversationID, default: []].append(contentsOf: [user, reply])
        return DurableLocalFixtureExchangeSnapshot(userMessage: user, fixtureReply: reply)
    }

    func recordedDraft() -> DurableTeammateDraft? { createdDraft }
    func storeActualReplyForTest(_ message: Message) {
        messages[message.conversationID, default: []].removeAll { $0.id == message.id }
        messages[message.conversationID, default: []].append(message)
        messages[message.conversationID]?.sort { $0.sequence < $1.sequence }
    }
    func saveMessageLocally(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> Message {
        localSaveTargets.append((conversationID, teammateID, userMessageID, text, attachmentIDs))
        if let attachmentSendGate { await attachmentSendGate.wait() }
        if attachmentSendOutcome == .failure { throw ConversationAttachmentError.unavailable }
        var parts: [MessagePart] = []
        if !text.isEmpty { parts.append(try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))) }
        for id in attachmentIDs {
            parts.append(try MessagePart(id: MessagePartID(UUID()), ordinal: parts.count, content: .attachment(id)))
        }
        let sequence = Int64((messages[conversationID] ?? []).count + 1)
        let timestamp = Date(timeIntervalSince1970: 9_101)
        let user = try Message(id: userMessageID, conversationID: conversationID, sequence: sequence,
            author: .user, deliveryState: .completed, parts: parts, createdAt: timestamp, updatedAt: timestamp)
        if !attachmentIDs.isEmpty {
            guard let attachmentStore else { throw ConversationAttachmentError.unavailable }
            try await attachmentStore.consume(attachmentIDs, in: conversationID)
        }
        messages[conversationID, default: []].append(user)
        return user
    }
    func recordedLocalTargets() -> [(ConversationID, TeammateID, MessageID, String, [AttachmentID])] { localSaveTargets }
    func sendMessageToLocalFixture(
        conversationID: ConversationID, teammateID: TeammateID,
        userMessageID: MessageID, text: String, attachmentIDs: [AttachmentID]
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        guard let attachmentStore else {
            guard attachmentIDs.isEmpty else { throw ConversationAttachmentError.unavailable }
            return try await sendMessageToLocalFixture(conversationID: conversationID, teammateID: teammateID,
                userMessageID: userMessageID, text: text)
        }
        attachmentTargets.append((conversationID, teammateID, userMessageID, text, attachmentIDs))
        sentTargets.append((conversationID, teammateID, userMessageID, text))
        if let attachmentSendGate { await attachmentSendGate.wait() }
        if attachmentSendOutcome == .failure { throw ConversationAttachmentError.unavailable }
        var parts: [MessagePart] = []
        if !text.isEmpty { parts.append(try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))) }
        for id in attachmentIDs {
            parts.append(try MessagePart(id: MessagePartID(UUID()), ordinal: parts.count, content: .attachment(id)))
        }
        let sequence = Int64((messages[conversationID] ?? []).count + 1)
        let timestamp = Date(timeIntervalSince1970: 9_101)
        let user = try Message(id: userMessageID, conversationID: conversationID, sequence: sequence,
            author: .user, deliveryState: .completed, parts: parts, createdAt: timestamp, updatedAt: timestamp)
        try await attachmentStore.consume(attachmentIDs, in: conversationID)
        messages[conversationID, default: []].append(user)
        if attachmentSendOutcome == .savedUserOnly {
            throw DurableTeammateChatError.fixtureReplyUnavailable(userMessage: user)
        }
        let reply = try Self.textMessage(id: MessageID(UUID()), conversationID: conversationID,
            sequence: sequence + 1, author: .teammate(teammateID), text: "Local attachment fixture reply.", timestamp: timestamp)
        messages[conversationID, default: []].append(reply)
        return DurableLocalFixtureExchangeSnapshot(userMessage: user, fixtureReply: reply)
    }
    func recordedAttachmentTargets() -> [(ConversationID, TeammateID, MessageID, String, [AttachmentID])] { attachmentTargets }
    func recordedTargets() -> [(ConversationID, TeammateID, MessageID, String)] { sentTargets }
    func recordedMessagePageRequests() -> [(ConversationID, Int64?, Int)] {
        messagePageRequests
    }

    private static func textMessage(
        id: MessageID,
        conversationID: ConversationID,
        sequence: Int64,
        author: MessageAuthor,
        text: String,
        timestamp: Date
    ) throws -> Message {
        try Message(
            id: id,
            conversationID: conversationID,
            sequence: sequence,
            author: author,
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
}

private actor DurableWorkspaceHiringFakeService: HiringConversationServing {
    let snapshot: HiringConversationSnapshot
    let confirmation: DurableTeammateChatCreationSnapshot
    private(set) var confirmCount = 0
    private(set) var cancelCount = 0

    init(
        snapshot: HiringConversationSnapshot,
        confirmation: DurableTeammateChatCreationSnapshot
    ) {
        self.snapshot = snapshot
        self.confirmation = confirmation
    }

    func loadOrStart() async throws -> HiringConversationSnapshot { snapshot }
    func submit(text: String) async throws -> HiringConversationSnapshot { snapshot }
    func revise(
        field: HiringCandidateField,
        value: String
    ) async throws -> HiringConversationSnapshot { snapshot }
    func cancel() async throws { cancelCount += 1 }
    func confirm(
        appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot {
        confirmCount += 1
        return confirmation
    }

    func recordedConfirmCount() -> Int { confirmCount }
    func recordedCancelCount() -> Int { cancelCount }
}

private actor WorkspaceSearchFakeService: ConversationSearchServing {
    var target: MessageSearchTarget?
    let delay: Duration
    init(target: MessageSearchTarget?, delay: Duration = .zero) {
        self.target = target
        self.delay = delay
    }
    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        ConversationSearchPage(teammates: [], messages: [], hasMoreTeammates: false, hasMoreMessages: false)
    }
    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return target
    }
    func replaceTarget(_ target: MessageSearchTarget) { self.target = target }
}

@MainActor
@Test("A send from an old search cannot cancel a newer result while its target page loads")
func workspaceSearchNewJumpSurvivesEarlierSend() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "54", name: "Search Sequence", seed: 54)
    let messages = try (1...60).map { sequence in
        try durableWorkspaceMessage(id: UUID(), conversationID: chat.id, teammateID: chat.teammate.id,
            sequence: Int64(sequence), text: "Saved \(sequence)", timestamp: Date(timeIntervalSince1970: Double(sequence)))
    }
    func target(_ message: Message) -> MessageSearchTarget {
        MessageSearchTarget(id: message.id, conversationID: chat.id, teammateID: chat.teammate.id,
                            sequence: message.sequence, currentTitle: "Search Sequence")
    }
    func hit(_ message: Message) -> MessageSearchHit {
        MessageSearchHit(id: message.id, conversationID: chat.id, teammateID: chat.teammate.id,
            teammateName: "Sequence", author: .user, authorName: "You", snippet: "Saved",
            sequence: message.sequence, createdAt: message.createdAt)
    }
    let search = WorkspaceSearchFakeService(target: target(messages[44]))
    let chatService = DurableWorkspaceFakeService(chats: [chat],
        selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        messages: [chat.id: messages], sendDelaysByText: ["Send from result": .milliseconds(50)],
        pageDelaysByBeforeSequence: [26: .milliseconds(100)])
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: chatService, hiringService: try durableHiringFixture().0, searchService: search)
    try await model.loadInitialWorkspace(messageLimit: 20)
    let coordinator = try #require(model.searchCoordinator)
    coordinator.present()
    coordinator.openMessage(hit(messages[44]))
    for _ in 0..<150 {
        if !coordinator.isOpening { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.conversation.searchFocus?.messageID == messages[44].id.rawValue)
    model.conversation.composerText = "Send from result"
    model.conversation.sendCurrentText()
    model.conversation.composerText = "Newest unsent"
    await search.replaceTarget(target(messages[24]))
    coordinator.present()
    coordinator.openMessage(hit(messages[24]))
    for _ in 0..<200 {
        if !coordinator.isOpening { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await chatService.recordedTargets().count == 1)
    #expect(coordinator.notice == nil)
    #expect(!coordinator.isPresented)
    #expect(model.conversation.searchFocus?.messageID == messages[24].id.rawValue)
    #expect(model.conversation.composerText == "Newest unsent")
}

@MainActor
@Test("Search opens only a bounded target page and returns to latest only on explicit action", arguments: [false, true])
func workspaceSearchBoundedJump(sendFromSearch: Bool) async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "51", name: "Search Ada", seed: 51)
    let messages = try (1...200).map { sequence in
        try durableWorkspaceMessage(id: UUID(), conversationID: chat.id, teammateID: chat.teammate.id,
                                    sequence: Int64(sequence), text: "Saved message \(sequence)",
                                    timestamp: Date(timeIntervalSince1970: Double(sequence)))
    }
    let found = messages[44]
    let search = WorkspaceSearchFakeService(target: MessageSearchTarget(
        id: found.id, conversationID: chat.id, teammateID: chat.teammate.id,
        sequence: found.sequence, currentTitle: "Search Ada"
    ))
    let chatService = DurableWorkspaceFakeService(chats: [chat],
        selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        messages: [chat.id: messages])
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: chatService, hiringService: try durableHiringFixture().0,
                                      searchService: search)
    try await model.loadInitialWorkspace(messageLimit: 20)
    model.conversation.composerText = "  Unsent\0draft  "
    let coordinator = try #require(model.searchCoordinator)
    coordinator.present()
    coordinator.openMessage(MessageSearchHit(id: found.id, conversationID: chat.id,
        teammateID: chat.teammate.id, teammateName: "Search Ada", author: .user, authorName: "You",
        snippet: "Saved message 45", sequence: 45, createdAt: found.createdAt))
    for _ in 0..<200 {
        if !coordinator.isOpening { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(!coordinator.isPresented)
    #expect(model.conversation.searchFocus?.messageID == found.id.rawValue)
    #expect(model.conversation.messageRows.count == 20)
    #expect(model.conversation.messageRows.last?.id == found.id.rawValue)
    #expect(model.conversation.composerText == "  Unsent\0draft  ")
    let requests = await chatService.recordedMessagePageRequests()
    #expect(requests.last?.1 == 46)
    #expect(requests.last?.2 == 20)
    if sendFromSearch {
        model.conversation.sendCurrentText()
        model.conversation.composerText = "New unsent draft"
        for _ in 0..<300 {
            if !model.conversation.needsLatestPage { break }
            try await Task.sleep(for: .milliseconds(2))
        }
    } else {
        model.conversation.requestLatestMessages()
    }
    for _ in 0..<200 {
        if !model.conversation.isReturningToLatest { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(!model.conversation.isViewingSearchResult)
    #expect(!model.conversation.isShowingLatestPlaceholder)
    if sendFromSearch {
        #expect(model.conversation.messageRows.contains { $0.id == messages.last?.id.rawValue })
        #expect(!model.conversation.messageRows.contains { $0.id == found.id.rawValue })
        #expect(model.conversation.composerText == "New unsent draft")
        #expect(model.conversation.latestFocus != nil)
    } else {
        #expect(model.conversation.messageRows.last?.id == messages.last?.id.rawValue)
        #expect(model.conversation.latestFocus?.messageID == messages.last?.id.rawValue)
        #expect(model.conversation.composerText == "  Unsent\0draft  ")
    }
}

@MainActor
@Test("A reply to an earlier send cannot pull the reader out of a later search result")
func workspaceSearchKeepsReadingPositionDuringReply() async throws {
    let (chat, found) = try durableWorkspaceFixture(suffix: "53", name: "Search Reader", seed: 53)
    let search = WorkspaceSearchFakeService(target: MessageSearchTarget(
        id: found.id, conversationID: chat.id, teammateID: chat.teammate.id,
        sequence: found.sequence, currentTitle: "Search Reader"))
    let chatService = DurableWorkspaceFakeService(chats: [chat],
        selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        messages: [chat.id: [found]], sendDelaysByText: ["Earlier send": .milliseconds(70)])
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: chatService, hiringService: try durableHiringFixture().0,
                                      searchService: search)
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "Earlier send"
    model.conversation.sendCurrentText()
    model.conversation.composerText = "Keep this draft"
    let coordinator = try #require(model.searchCoordinator)
    coordinator.present()
    coordinator.openMessage(MessageSearchHit(id: found.id, conversationID: chat.id,
        teammateID: chat.teammate.id, teammateName: "Reader", author: .user, authorName: "You",
        snippet: "Saved", sequence: found.sequence, createdAt: found.createdAt))
    for _ in 0..<150 {
        if await chatService.recordedTargets().count == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await chatService.recordedTargets().count == 1)
    #expect(model.conversation.searchFocus?.messageID == found.id.rawValue)
    #expect(model.conversation.messageRows.count == 1)
    #expect(model.conversation.composerText == "Keep this draft")
}

@MainActor
@Test("Closing search fences a late resolved result; a mismatched result never navigates")
func workspaceSearchNavigationFence() async throws {
    let (chat, found) = try durableWorkspaceFixture(suffix: "52", name: "Search Mira", seed: 52)
    let service = WorkspaceSearchFakeService(target: MessageSearchTarget(
        id: found.id, conversationID: chat.id, teammateID: chat.teammate.id,
        sequence: found.sequence, currentTitle: "Search Mira"), delay: .milliseconds(20))
    var navigationCount = 0
    let coordinator = WorkspaceSearchCoordinator(service: service) { _, _ in navigationCount += 1 }
    let hit = MessageSearchHit(id: found.id, conversationID: chat.id, teammateID: chat.teammate.id,
        teammateName: "Mira", author: .user, authorName: "You", snippet: "Saved",
        sequence: found.sequence, createdAt: found.createdAt)
    coordinator.present()
    coordinator.openMessage(hit)
    await Task.yield()
    coordinator.close()
    try await Task.sleep(for: .milliseconds(40))
    #expect(navigationCount == 0)
    #expect(!coordinator.isOpening)

    coordinator.present()
    coordinator.openMessage(MessageSearchHit(id: found.id, conversationID: ConversationID(UUID()),
        teammateID: chat.teammate.id, teammateName: "Mira", author: .user, authorName: "You", snippet: "Saved",
        sequence: found.sequence, createdAt: found.createdAt))
    for _ in 0..<100 {
        if !coordinator.isOpening { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(navigationCount == 0)
    #expect(coordinator.notice != nil)
    #expect(coordinator.isPresented)
}

@MainActor
@Test("Repeated search jumps use distinct requests and invalid targets leave the page intact")
func transcriptSearchIdentity() {
    let conversationID = UUID(), messageID = UUID()
    let model = ConversationModel(conversationID: conversationID,
        messages: [ChatMessageSnapshot(id: messageID, author: .user, body: "Saved", delivery: .sent,
                                       timestamp: Date(timeIntervalSince1970: 1))], composerText: "Unsent")
    model.focusSearchMessage(messageID)
    let first = model.searchFocus
    model.focusSearchMessage(messageID)
    #expect(model.searchFocus?.requestID != first?.requestID)
    let second = model.searchFocus
    model.focusSearchMessage(UUID())
    #expect(model.searchFocus == second)
    #expect(model.composerText == "Unsent")
    model.show(conversationID: UUID(), title: "Other", messages: [])
    #expect(!model.isViewingSearchResult)
}

@MainActor
@Test("Search send immediately separates pending output from historical rows even before persistence")
func transcriptSearchPendingBoundary() {
    let conversationID = UUID(), oldID = UUID(), pendingID = UUID()
    let model = ConversationModel(conversationID: conversationID,
        messages: [ChatMessageSnapshot(id: oldID, author: .user, body: "Old saved context", delivery: .sent,
                                      timestamp: Date(timeIntervalSince1970: 1))],
        composerText: "New message", submit: { _, _, _ in })
    model.focusSearchMessage(oldID)
    model.sendCurrentText(messageID: pendingID)
    #expect(model.messageRows.map(\.id) == [pendingID])
    #expect(model.messageRows.first?.snapshot.delivery == .pending)
    #expect(model.isShowingLatestPlaceholder)
    #expect(!model.isViewingSearchResult)
    #expect(model.needsLatestPage)
}

@Test("Queued tail scrolling rejects changed conversation, search, latest request or tail")
func transcriptSearchTailFence() {
    let conversationID = UUID(), tailID = UUID()
    let request = TranscriptTailScrollRequest(conversationID: conversationID,
        searchRequestID: nil, latestRequestID: nil, tailID: tailID)
    #expect(request.matches(conversationID: conversationID, searchRequestID: nil, latestRequestID: nil, tailID: tailID))
    #expect(!request.matches(conversationID: conversationID, searchRequestID: UUID(), latestRequestID: nil, tailID: tailID))
    #expect(!request.matches(conversationID: UUID(), searchRequestID: nil, latestRequestID: nil, tailID: tailID))
    #expect(!request.matches(conversationID: conversationID, searchRequestID: nil, latestRequestID: UUID(), tailID: tailID))
    #expect(!request.matches(conversationID: conversationID, searchRequestID: nil, latestRequestID: nil, tailID: UUID()))
}

private func durableWorkspaceFixture(
    suffix: String,
    name: String,
    seed: UInt64
) throws -> (DurableDirectChatSnapshot, Message) {
    let teammateID = TeammateID(UUID(uuidString: "92000000-0000-0000-0000-0000000000\(suffix)")!)
    let conversationID = ConversationID(
        UUID(uuidString: "93000000-0000-0000-0000-0000000000\(suffix)")!
    )
    let timestamp = Date(timeIntervalSince1970: 9_200 + Double(seed))
    let appearance = try AgentAppearance(
        mode: .creature,
        grammarVersion: 2,
        deterministicSeed: seed,
        silhouette: "sprout",
        paletteToken: "violet",
        eyeDialect: "bright",
        nonColorIdentityCue: "leaf ears",
        accessibleIdentityDescription: "Violet sprout with leaf ears",
        revision: 3
    )
    let teammate = try Teammate(
        id: teammateID,
        profile: TeammateProfile(displayName: name, role: "Research and synthesis"),
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
    let greeting = try Message(
        id: MessageID(UUID()),
        conversationID: conversationID,
        sequence: 1,
        author: .teammate(teammateID),
        deliveryState: .completed,
        parts: [
            try MessagePart(
                id: MessagePartID(UUID()),
                ordinal: 0,
                content: .text("Local review fixture greeting for \(name).")
            )
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )
    return (DurableDirectChatSnapshot(teammate: teammate, conversation: conversation), greeting)
}

private func durableWorkspaceMessage(
    id: UUID,
    conversationID: ConversationID,
    teammateID: TeammateID,
    sequence: Int64,
    text: String,
    timestamp: Date
) throws -> Message {
    try Message(
        id: MessageID(id),
        conversationID: conversationID,
        sequence: sequence,
        author: sequence.isMultiple(of: 2) ? .user : .teammate(teammateID),
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

private func durableHiringFixture(mode: LocalChatMode = .reviewFixture) throws -> (
    DurableWorkspaceHiringFakeService,
    DurableTeammateChatCreationSnapshot
) {
    let draftUUID = UUID(uuidString: "95000000-0000-0000-0000-000000000001")!
    let draftID = HiringDraftID(draftUUID)
    let timestamp = Date(timeIntervalSince1970: 9_500)
    let draft = try HiringDraft(
        id: draftID,
        phase: .readyForReview,
        displayName: "Nova",
        role: "Research lead",
        responsibilities: "Research and synthesize reliable sources.",
        workingStyle: "Curious, direct, and transparent.",
        skills: "Research, synthesis, and document design.",
        permissionIntent: "May need read access to a selected research folder.",
        projectPlacement: "Launch research intent only.",
        teamPlacement: "Editorial team intent only.",
        revision: 1,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let guide = try HiringTurn(
        id: HiringTurnID(UUID()),
        draftID: draftID,
        sequence: 1,
        author: .guide,
        text: mode == .reviewFixture
            ? HiringConversationModel.previewDisclosure : HiringConversationService.localSetupDisclosure,
        createdAt: timestamp
    )
    let snapshot = HiringConversationSnapshot(
        persisted: try HiringDraftSnapshot(draft: draft, turns: [guide]),
        focusedField: nil
    )
    let appearance = try AgentAppearance(
        mode: .creature,
        grammarVersion: 3,
        deterministicSeed: 95,
        silhouette: "soft-arch",
        paletteToken: "violet-coral",
        eyeDialect: "round-alert",
        nonColorIdentityCue: "single brow notch",
        accessibleIdentityDescription: "Violet creature with a single brow notch",
        revision: 1
    )
    let teammate = try Teammate(
        id: TeammateID(draftUUID),
        profile: TeammateProfile(displayName: "Nova", role: "Research lead"),
        appearance: appearance,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let conversation = try Conversation(
        id: ConversationID(UUID()),
        kind: .direct(teammateID: teammate.id),
        title: teammate.profile.displayName,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let greeting = try Message(
        id: MessageID(UUID()),
        conversationID: conversation.id,
        sequence: 1,
        author: .teammate(teammate.id),
        deliveryState: .completed,
        parts: [
            try MessagePart(
                id: MessagePartID(UUID()),
                ordinal: 0,
                content: .text("Local guided hiring preview — no Claude runtime or tool ran.")
            )
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let creation = DurableTeammateChatCreationSnapshot(
        teammate: teammate,
        conversation: conversation,
        fixtureGreeting: mode == .reviewFixture ? greeting : nil,
        selection: DurableChatSelectionSnapshot(
            teammate: teammate,
            conversation: conversation
        )
    )
    return (
        DurableWorkspaceHiringFakeService(snapshot: snapshot, confirmation: creation),
        creation
    )
}

private actor WorkspaceAttachmentReceiptGate {
    private var queuedReceipt: AttachmentDraftPresentationReceipt?
    private var continuation: CheckedContinuation<AttachmentDraftPresentationReceipt, Never>?

    func wait() async -> AttachmentDraftPresentationReceipt {
        if let queuedReceipt {
            self.queuedReceipt = nil
            return queuedReceipt
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ receipt: AttachmentDraftPresentationReceipt) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: receipt)
        } else {
            queuedReceipt = receipt
        }
    }
}

@MainActor
private func select(
    _ chat: DurableDirectChatSnapshot,
    in model: DurableWorkspaceModel
) async throws {
    model.sidebar.selection = chat.teammate.id.rawValue
    for _ in 0..<300 where model.conversation.conversationID != chat.conversation.id.rawValue {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.conversation.conversationID == chat.conversation.id.rawValue)
    for _ in 0..<300 where model.conversation.inputAvailability != .ready {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.conversation.inputAvailability == .ready)
}

@MainActor
private func waitForAttachmentReady(
    _ model: AttachmentDraftModel,
    operationID: UUID
) async throws {
    for _ in 0..<300 {
        if let row = model.rows.first(where: { $0.id == operationID }),
           case .ready = row.state {
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Test("Durable workspace restores selected UUID full appearance and local history")
@MainActor
func durableWorkspaceRestoresInitialSelection() async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 41)
    let service = DurableWorkspaceFakeService(
        chats: [chat],
        selected: DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        ),
        messages: [chat.conversation.id: [greeting]]
    )
    let hiring = try durableHiringFixture().0
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: hiring)

    try await model.loadInitialWorkspace()

    #expect(model.sidebar.selection == chat.teammate.id.rawValue)
    #expect(model.sidebar.rows.first?.identity == TeammateIdentitySnapshot(chat.teammate))
    #expect(model.conversation.conversationID == chat.conversation.id.rawValue)
    #expect(model.conversation.messages.first?.body.contains("Local review fixture") == true)
    #expect(model.conversation.inputAvailability == .ready)
    #expect(model.conversation.readyDeliveryDescription.contains("Claude and tools are not running"))
}

private actor WorkspaceProfileEditingFake: TeammateProfileEditing {
    private var teammate: Teammate
    init(_ teammate: Teammate) { self.teammate = teammate }
    func loadProfile(teammateID: TeammateID) async throws -> Teammate { teammate }
    func saveProfile(teammateID: TeammateID, expectedRevision: UInt64, draft: TeammateProfileEditDraft) async throws -> Teammate {
        guard teammateID == teammate.id, expectedRevision == teammate.profile.revision else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammateID.persistedValue)
        }
        teammate.profile = try teammate.profile.revised(displayName: draft.displayName, role: draft.role)
        return teammate
    }
}

@Test("Profile save refreshes the exact identity without replacing transcript rows or the composer")
@MainActor
func durableWorkspaceProfileSavePreservesConversation() async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: "81", name: "Original", seed: 41)
    let service = DurableWorkspaceFakeService(
        chats: [chat], selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        messages: [chat.conversation.id: [greeting]]
    )
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
        profileService: WorkspaceProfileEditingFake(chat.teammate))
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "Keep this unsent draft"
    let row = try #require(model.conversation.messageRows.first)
    let sidebarRow = try #require(model.sidebar.rowModels.first)
    let priorMessages = model.conversation.messages
    model.editSelectedProfile()
    let editor = try #require(model.profileEditor)
    await editor.load()
    editor.displayName = "Updated teammate"
    let saved = try #require(await editor.save())
    model.profileDidSave(saved)
    #expect(model.profileEditor == nil)
    #expect(model.sidebar.selection == chat.teammate.id.rawValue)
    #expect(model.sidebar.rows.first?.name == "Updated teammate")
    #expect(model.sidebar.rowModels.first === sidebarRow)
    #expect(model.conversation.title == "Updated teammate")
    #expect(model.conversation.composerText == "Keep this unsent draft")
    #expect(model.conversation.messageRows.first === row)
    #expect(model.conversation.messages == priorMessages)
}

@Test("Renaming a bot refuses a name another active bot carries, and the bot keeps its own name in any case")
@MainActor
func durableWorkspaceRenameRefusesTakenName() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "85", name: "Ada", seed: 85)
    let (rook, greetingB) = try durableWorkspaceFixture(suffix: "86", name: "Rook", seed: 86)
    let service = DurableWorkspaceFakeService(chats: [ada, rook],
        selected: DurableChatSelectionSnapshot(teammate: rook.teammate, conversation: rook.conversation),
        messages: [ada.id: [greetingA], rook.id: [greetingB]])
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
        profileService: WorkspaceProfileEditingFake(rook.teammate))
    defer { model.finishShutdown() }
    try await model.loadInitialWorkspace()
    model.editSelectedProfile()
    let editor = try #require(model.profileEditor)
    await editor.load()

    for typed in ["Ada", "ada", "  ADA "] {
        editor.displayName = typed
        #expect(editor.nameValidationMessage == "There is already a bot called Ada.", "typed \(typed)")
        #expect(editor.canSave == false, "typed \(typed)")
    }
    editor.displayName = "ROOK"
    #expect(editor.nameValidationMessage == nil, "The bot keeps its own name in any case")
    #expect(editor.canSave)
    let saved = try #require(await editor.save())
    #expect(saved.profile.displayName == "ROOK")
}

@Test("Navigating from an unfinished profile preserves its exact teammate draft")
@MainActor
func durableWorkspaceProfileDraftSurvivesNavigation() async throws {
    let (first, _) = try durableWorkspaceFixture(suffix: "82", name: "First", seed: 42)
    let (second, _) = try durableWorkspaceFixture(suffix: "83", name: "Second", seed: 43)
    let service = DurableWorkspaceFakeService(chats: [first, second],
        selected: DurableChatSelectionSnapshot(teammate: first.teammate, conversation: first.conversation))
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
        profileService: WorkspaceProfileEditingFake(first.teammate))
    try await model.loadInitialWorkspace()
    model.editSelectedProfile()
    let editor = try #require(model.profileEditor)
    await editor.load()
    editor.role = "Unfinished draft role"
    model.sidebar.selection = second.teammate.id.rawValue
    for _ in 0..<100 where model.conversation.conversationID != second.conversation.id.rawValue {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.conversation.conversationID == second.conversation.id.rawValue)
    #expect(model.profileEditor == nil)
    model.sidebar.selection = first.teammate.id.rawValue
    for _ in 0..<100 where model.conversation.conversationID != first.conversation.id.rawValue {
        try await Task.sleep(for: .milliseconds(5))
    }
    model.editSelectedProfile()
    #expect(model.profileEditor === editor)
    #expect(model.profileEditor?.role == "Unfinished draft role")
    model.cancelProfileEditing()
    #expect(model.profileEditor == nil)
}

@Test("Durable workspace loads bounded SQLite pages without replacing visible rows")
@MainActor
func durableWorkspaceLoadsEarlierPagesWithStableRows() async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 71)
    let base = Date(timeIntervalSince1970: 9_300)
    let messageIDs = (2...5).map { sequence in
        UUID(uuidString: "96000000-0000-0000-0000-00000000000\(sequence)")!
    }
    let laterMessages = try zip(2...5, messageIDs).map { sequence, id in
        try durableWorkspaceMessage(
            id: id,
            conversationID: chat.conversation.id,
            teammateID: chat.teammate.id,
            sequence: Int64(sequence),
            text: "Message \(sequence)",
            timestamp: base.addingTimeInterval(Double(sequence))
        )
    }
    let service = DurableWorkspaceFakeService(
        chats: [chat],
        selected: DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        ),
        messages: [chat.conversation.id: [greeting] + laterMessages]
    )
    let hiring = try durableHiringFixture().0
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: hiring)

    try await model.loadInitialWorkspace(messageLimit: 2)

    #expect(model.conversation.messageRows.map(\.id) == Array(messageIDs.suffix(2)))
    #expect(model.conversation.hasEarlierMessages)
    let initiallyVisibleRows = model.conversation.messageRows

    model.conversation.loadEarlierMessages()
    for _ in 0..<200 where model.conversation.messageRows.count < 4 {
        try await Task.sleep(for: .milliseconds(2))
    }

    #expect(model.conversation.messageRows.map(\.id) == Array(messageIDs.prefix(4)))
    #expect(model.conversation.messageRows[2] === initiallyVisibleRows[0])
    #expect(model.conversation.messageRows[3] === initiallyVisibleRows[1])
    #expect(model.conversation.hasEarlierMessages)

    let firstPageRows = model.conversation.messageRows
    model.conversation.loadEarlierMessages()
    for _ in 0..<200 where model.conversation.messageRows.count < 5 {
        try await Task.sleep(for: .milliseconds(2))
    }

    #expect(model.conversation.messageRows.first?.id == greeting.id.rawValue)
    #expect(model.conversation.messageRows.dropFirst().map(\.id) == messageIDs)
    #expect(model.conversation.messageRows[3] === firstPageRows[2])
    #expect(model.conversation.messageRows[4] === firstPageRows[3])
    #expect(model.conversation.hasEarlierMessages == false)
    let requests = await service.recordedMessagePageRequests()
    #expect(requests.map(\.1) == [nil, 4, 2])
    #expect(requests.allSatisfy { $0.2 == 2 })
}

@Test("Local reply fixture streams through one row and leaves unrelated identities intact")
@MainActor
func durableWorkspaceFixtureStreamIsRowLocal() async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 72)
    let service = DurableWorkspaceFakeService(
        chats: [chat],
        selected: DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        ),
        messages: [chat.conversation.id: [greeting]]
    )
    let hiring = try durableHiringFixture().0
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: hiring)
    try await model.loadInitialWorkspace()
    let greetingRow = try #require(model.conversation.messageRows.first)
    let greetingSnapshot = greetingRow.snapshot
    let teammateRow = try #require(model.sidebar.rowModels.first)
    let userMessageID = UUID(uuidString: "97000000-0000-0000-0000-000000000001")!
    model.conversation.composerText = "show the row-local fixture"

    model.conversation.sendCurrentText(
        now: Date(timeIntervalSince1970: 9_700),
        messageID: userMessageID
    )

    for _ in 0..<200 {
        if model.conversation.messageRows.last?.snapshot.streamState == .streaming {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    let streamRow = try #require(model.conversation.messageRows.last)
    #expect(streamRow.snapshot.streamState == .streaming)
    #expect(model.conversation.messageRows.first === greetingRow)
    #expect(greetingRow.snapshot == greetingSnapshot)
    #expect(model.sidebar.rowModels.first === teammateRow)
    #expect(model.sidebar.rows.first?.activity == .speaking)

    for _ in 0..<500 {
        if streamRow.snapshot.streamState == .complete { break }
        try await Task.sleep(for: .milliseconds(3))
    }

    #expect(model.conversation.messageRows.last === streamRow)
    #expect(streamRow.snapshot.streamState == .complete)
    #expect(streamRow.snapshot.body == DurableTeammateChatService.fixtureReplyText)
    #expect(model.conversation.messageRows.first === greetingRow)
    #expect(greetingRow.snapshot == greetingSnapshot)
    #expect(model.sidebar.rowModels.first === teammateRow)
    #expect(model.sidebar.rows.first?.activity == .waitingForUser)
}

@Test("Hiring fixture confirmation enters the roster only after atomic hiring succeeds",
      arguments: [LocalChatMode.localOnly, .reviewFixture])
@MainActor
func durableWorkspaceChatLedHiringAppliesAtomicCreation(mode: LocalChatMode) async throws {
    let service = DurableWorkspaceFakeService()
    let (hiringService, expected) = try durableHiringFixture(mode: mode)
    let model = DurableWorkspaceModel(mode: mode, service: service, hiringService: hiringService)
    try await model.loadInitialWorkspace()
    model.beginHiringFixture()
    let hiring = try #require(model.hiringModel)
    await hiring.load()

    #expect(model.sidebar.rows.isEmpty)
    #expect(await hiring.confirmHire())
    #expect(model.sidebar.rows.isEmpty)

    model.completeHiring(from: hiring)

    #expect(await hiringService.recordedConfirmCount() == 1)
    #expect(await hiringService.recordedCancelCount() == 0)
    #expect(await service.recordedDraft() == nil)
    #expect(model.hiringModel == nil)
    #expect(model.sidebar.selection == expected.teammate.id.rawValue)
    #expect(
        model.sidebar.rows.first?.identity
            == TeammateIdentitySnapshot(expected.teammate)
    )
    #expect(model.conversation.conversationID == expected.conversation.id.rawValue)
    #expect(model.conversation.isLocalOnly == (mode == .localOnly))
    if mode == .localOnly {
        #expect(expected.fixtureGreeting == nil)
        #expect(model.conversation.messages.isEmpty)
        #expect(model.conversation.submissionActionTitle == "Save Message")
    } else {
        #expect(model.conversation.messages.first?.body.contains("no Claude runtime") == true)
    }
}

@Test("Inline hiring fixture clears the teammate highlight and cancellation restores the prior chat",
      arguments: [LocalChatMode.localOnly, .reviewFixture])
@MainActor
func durableWorkspaceInlineHiringRestoresPriorSelectionAfterCancel(mode: LocalChatMode) async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 61)
    let service = DurableWorkspaceFakeService(
        chats: [chat],
        selected: DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        ),
        messages: [chat.conversation.id: [greeting]]
    )
    let hiringService = try durableHiringFixture(mode: mode).0
    let model = DurableWorkspaceModel(mode: mode, service: service, hiringService: hiringService)
    try await model.loadInitialWorkspace()
    let exactDraft = "  Keep this unfinished message\nwhile hiring.  "
    model.conversation.composerText = exactDraft
    let messages = model.conversation.messages
    let rowIdentities = model.conversation.messageRows.map(ObjectIdentifier.init)

    model.beginHiringFixture()
    let hiring = try #require(model.hiringModel)

    #expect(model.sidebar.selection == nil)
    #expect(model.conversation.conversationID == chat.conversation.id.rawValue)

    await hiring.load()
    #expect(await hiring.cancel())
    model.completeHiringCancellation(from: hiring)

    #expect(model.hiringModel == nil)
    #expect(model.sidebar.selection == chat.teammate.id.rawValue)
    #expect(model.conversation.conversationID == chat.conversation.id.rawValue)
    #expect(model.conversation.composerText == exactDraft)
    #expect(model.conversation.messages == messages)
    #expect(model.conversation.messageRows.map(ObjectIdentifier.init) == rowIdentities)
    #expect(model.conversation.isLocalOnly == (mode == .localOnly))
    #expect(await hiringService.recordedCancelCount() == 1)
    #expect(await hiringService.recordedConfirmCount() == 0)
    #expect(await service.recordedDraft() == nil)
}

@Test("Immediate send captures its original conversation and a fast switch cannot receive its reply")
@MainActor
func durableWorkspaceSendDoesNotCrossSelection() async throws {
    let (first, firstGreeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 51)
    let (second, secondGreeting) = try durableWorkspaceFixture(suffix: "02", name: "Rook", seed: 52)
    let service = DurableWorkspaceFakeService(
        chats: [first, second],
        selected: DurableChatSelectionSnapshot(
            teammate: first.teammate,
            conversation: first.conversation
        ),
        messages: [
            first.conversation.id: [firstGreeting],
            second.conversation.id: [secondGreeting]
        ]
    )
    let hiring = try durableHiringFixture().0
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: hiring)
    try await model.loadInitialWorkspace()
    let messageID = UUID(uuidString: "94000000-0000-0000-0000-000000000001")!
    model.conversation.composerText = "stay with Ada"

    model.conversation.sendCurrentText(
        now: Date(timeIntervalSince1970: 9_400),
        messageID: messageID
    )
    #expect(model.conversation.messages.last?.id == messageID)
    #expect(model.conversation.messages.last?.delivery == .pending)
    model.sidebar.selection = second.teammate.id.rawValue

    for _ in 0..<200 {
        if await service.recordedTargets().count == 1,
           model.conversation.conversationID == second.conversation.id.rawValue {
            break
        }
        await Task.yield()
    }
    try await Task.sleep(for: .milliseconds(500))

    let target = try #require(await service.recordedTargets().first)
    #expect(target.0 == first.conversation.id)
    #expect(target.1 == first.teammate.id)
    #expect(target.2.rawValue == messageID)
    #expect(target.3 == "stay with Ada")
    #expect(model.conversation.conversationID == second.conversation.id.rawValue)
    #expect(model.conversation.messages == [
        ChatMessageSnapshot(
            id: secondGreeting.id.rawValue,
            author: .teammate(TeammateIdentitySnapshot(second.teammate)),
            body: "Local review fixture greeting for Rook.",
            delivery: .sent,
            timestamp: secondGreeting.createdAt
        )
    ])
}

@Test("Composer text remains scoped to its exact conversation across teammate switches")
@MainActor
func durableWorkspaceComposerDraftsDoNotCrossSelection() async throws {
    let (first, firstGreeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 81)
    let (second, secondGreeting) = try durableWorkspaceFixture(suffix: "02", name: "Rook", seed: 82)
    let service = DurableWorkspaceFakeService(
        chats: [first, second],
        selected: DurableChatSelectionSnapshot(
            teammate: first.teammate,
            conversation: first.conversation
        ),
        messages: [
            first.conversation.id: [firstGreeting],
            second.conversation.id: [secondGreeting]
        ]
    )
    let model = DurableWorkspaceModel(mode: .reviewFixture,
        service: service,
        hiringService: try durableHiringFixture().0
    )
    try await model.loadInitialWorkspace()

    model.conversation.composerText = "Ada-only unsent draft"
    try await select(second, in: model)
    #expect(model.conversation.composerText.isEmpty)

    model.conversation.composerText = "Rook-only unsent draft"
    try await select(first, in: model)
    #expect(model.conversation.composerText == "Ada-only unsent draft")

    try await select(second, in: model)
    #expect(model.conversation.composerText == "Rook-only unsent draft")
}

@Test("A ready attachment draft remains visible only in its originating conversation")
@MainActor
func durableWorkspaceReadyAttachmentDoesNotCrossSelection() async throws {
    let (first, firstGreeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 83)
    let (second, secondGreeting) = try durableWorkspaceFixture(suffix: "02", name: "Rook", seed: 84)
    let service = DurableWorkspaceFakeService(
        chats: [first, second],
        selected: DurableChatSelectionSnapshot(
            teammate: first.teammate,
            conversation: first.conversation
        ),
        messages: [
            first.conversation.id: [firstGreeting],
            second.conversation.id: [secondGreeting]
        ]
    )
    let model = DurableWorkspaceModel(mode: .reviewFixture,
        service: service,
        hiringService: try durableHiringFixture().0,
        attachmentImporter: { url, _ in
            AttachmentDraftPresentationReceipt(
                displayName: url.lastPathComponent,
                byteCount: 12,
                shortHash: "aabbccdd"
            )
        }
    )
    try await model.loadInitialWorkspace()
    let firstDraft = model.attachmentDraft
    let operationID = UUID(uuidString: "98000000-0000-0000-0000-000000000001")!

    #expect(
        firstDraft.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/ada-only.txt"),
            operationID: operationID
        )
    )
    try await waitForAttachmentReady(firstDraft, operationID: operationID)
    #expect(firstDraft.rows.first?.id == operationID)

    try await select(second, in: model)
    let secondDraft = model.attachmentDraft
    #expect(secondDraft !== firstDraft)
    #expect(secondDraft.rows.isEmpty)

    try await select(first, in: model)
    #expect(model.attachmentDraft === firstDraft)
    #expect(model.attachmentDraft.rows.first?.id == operationID)
    if case .ready = model.attachmentDraft.rows.first?.state {
        // Expected ready state remains attached to Ada's presentation model.
    } else {
        Issue.record("Expected Ada's ready attachment preview to be restored")
    }
}

@Test("An attachment import completing after a switch cannot appear in the new conversation")
@MainActor
func durableWorkspacePendingAttachmentCompletionDoesNotCrossSelection() async throws {
    let (first, firstGreeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 85)
    let (second, secondGreeting) = try durableWorkspaceFixture(suffix: "02", name: "Rook", seed: 86)
    let gate = WorkspaceAttachmentReceiptGate()
    let service = DurableWorkspaceFakeService(
        chats: [first, second],
        selected: DurableChatSelectionSnapshot(
            teammate: first.teammate,
            conversation: first.conversation
        ),
        messages: [
            first.conversation.id: [firstGreeting],
            second.conversation.id: [secondGreeting]
        ]
    )
    let model = DurableWorkspaceModel(mode: .reviewFixture,
        service: service,
        hiringService: try durableHiringFixture().0,
        attachmentImporter: { _, _ in await gate.wait() }
    )
    try await model.loadInitialWorkspace()
    let firstDraft = model.attachmentDraft
    let operationID = UUID(uuidString: "98000000-0000-0000-0000-000000000002")!

    #expect(
        firstDraft.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/pending-ada-only.txt"),
            operationID: operationID
        )
    )
    #expect(firstDraft.rows.first?.state == .pending)

    try await select(second, in: model)
    let secondDraft = model.attachmentDraft
    #expect(secondDraft !== firstDraft)
    #expect(secondDraft.rows.isEmpty)

    await gate.release(
        AttachmentDraftPresentationReceipt(
            displayName: "pending-ada-only.txt",
            byteCount: 19,
            shortHash: "11223344"
        )
    )
    try await waitForAttachmentReady(firstDraft, operationID: operationID)

    #expect(model.attachmentDraft === secondDraft)
    #expect(model.attachmentDraft.rows.isEmpty)
    try await select(first, in: model)
    #expect(model.attachmentDraft === firstDraft)
    #expect(model.attachmentDraft.rows.first?.id == operationID)
    if case .ready = model.attachmentDraft.rows.first?.state {
        // Expected completion stayed with the originating conversation.
    } else {
        Issue.record("Expected the pending attachment to finish only in Ada's draft")
    }
}

@Test("Two quick fixture sends keep earlier growth non-tail and Waiting until every reply finishes")
@MainActor
func durableWorkspaceOverlappingFixtureRepliesKeepTruthfulActivity() async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: "01", name: "Ada", seed: 87)
    let secondText = "second overlapping fixture request"
    let service = DurableWorkspaceFakeService(
        chats: [chat],
        selected: DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        ),
        messages: [chat.conversation.id: [greeting]],
        sendDelaysByText: [secondText: .milliseconds(250)]
    )
    let model = DurableWorkspaceModel(mode: .reviewFixture,
        service: service,
        hiringService: try durableHiringFixture().0
    )
    try await model.loadInitialWorkspace()

    model.conversation.composerText = "first overlapping fixture request"
    model.conversation.sendCurrentText(messageID: UUID())
    model.conversation.composerText = secondText
    model.conversation.sendCurrentText(messageID: UUID())

    for _ in 0..<500 {
        let streamingReplies = model.conversation.messageRows.filter {
            if case .teammate = $0.snapshot.author {
                return $0.snapshot.streamState == .streaming
            }
            return false
        }
        if streamingReplies.count == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }

    let overlappingReplies = model.conversation.messageRows.filter {
        if case .teammate = $0.snapshot.author {
            return $0.snapshot.streamState == .streaming
        }
        return false
    }
    #expect(overlappingReplies.count == 2)
    let earlierReplyID = try #require(overlappingReplies.first?.id)
    let tailReplyID = try #require(model.conversation.messageRows.last?.id)
    #expect(earlierReplyID != tailReplyID)
    #expect(
        TranscriptTailFollowPolicy.followsStreamingGrowth(
            isNearBottom: true,
            streamingRowID: earlierReplyID,
            tailRowID: tailReplyID
        ) == false
    )
    #expect(
        TranscriptTailFollowPolicy.followsStreamingGrowth(
            isNearBottom: true,
            streamingRowID: tailReplyID,
            tailRowID: tailReplyID
        )
    )
    #expect(model.sidebar.rows.first?.activity == .speaking)

    for _ in 0..<500 {
        let fixtureReplies = model.conversation.messageRows.filter {
            if case .teammate = $0.snapshot.author {
                return $0.snapshot.streamState != .notStreaming
            }
            return false
        }
        let completed = fixtureReplies.filter { $0.snapshot.streamState == .complete }.count
        let streaming = fixtureReplies.filter { $0.snapshot.streamState == .streaming }.count
        if completed == 1, streaming == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }

    let midpointReplies = model.conversation.messageRows.filter {
        if case .teammate = $0.snapshot.author {
            return $0.snapshot.streamState != .notStreaming
        }
        return false
    }
    #expect(midpointReplies.filter { $0.snapshot.streamState == .complete }.count == 1)
    #expect(midpointReplies.filter { $0.snapshot.streamState == .streaming }.count == 1)
    #expect(model.sidebar.rows.first?.activity == .speaking)
    #expect(model.sidebar.rows.first?.activity != .waitingForUser)

    for _ in 0..<500 {
        let allComplete = model.conversation.messageRows
            .filter {
                if case .teammate = $0.snapshot.author {
                    return $0.snapshot.streamState != .notStreaming
                }
                return false
            }
            .allSatisfy { $0.snapshot.streamState == .complete }
        if allComplete, model.sidebar.rows.first?.activity == .waitingForUser { break }
        try await Task.sleep(for: .milliseconds(3))
    }

    #expect(model.sidebar.rows.first?.activity == .waitingForUser)
}

@Test("Attachment-only workspace send captures its owner and leaves newer and other-chat drafts intact")
@MainActor
func durableWorkspaceDurableAttachmentSendSurvivesSwitchAndNewAddition() async throws {
    let (first, firstGreeting) = try durableWorkspaceFixture(suffix: "61", name: "Attachment Ada", seed: 161)
    let (second, secondGreeting) = try durableWorkspaceFixture(suffix: "62", name: "Attachment Rook", seed: 162)
    let captured = try workspaceDurableAttachment(first.id, suffix: 1)
    let other = try workspaceDurableAttachment(second.id, suffix: 2)
    let store = WorkspaceDurableAttachmentStore(assets: [captured, other])
    let drafts = WorkspaceAttachmentTextDraftStore()
    let gate = WorkspaceAttachmentSendGate()
    let service = DurableWorkspaceFakeService(chats: [first, second],
        selected: DurableChatSelectionSnapshot(teammate: first.teammate, conversation: first.conversation),
        messages: [first.id: [firstGreeting], second.id: [secondGreeting]],
        attachmentStore: store, attachmentSendGate: gate)
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
        draftService: drafts, attachmentDraftFactory: workspaceDurableAttachmentFactory(store))
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.canSend }
    #expect(model.conversation.composerText.isEmpty)
    let originalDraft = model.attachmentDraft
    let messageID = workspaceDurableAttachmentID(20)
    model.conversation.sendCurrentText(messageID: messageID)
    #expect(model.conversation.messageRows.last?.id == messageID)
    #expect(model.conversation.messageRows.last?.snapshot.delivery == .pending)
    #expect(model.conversation.messageRows.last?.snapshot.body == "Saving attachment…")
    try await waitWorkspaceAttachment { await gate.started }
    defer { Task { await gate.release() } }
    let nextID = workspaceDurableAttachmentID(3)
    #expect(originalDraft.selectFile(at: URL(fileURLWithPath: "/private/tmp/later-attachment.txt"), operationID: nextID))
    try await waitForAttachmentReady(originalDraft, operationID: nextID)
    #expect(originalDraft.rows.count == 2)
    let call = try #require(await service.recordedAttachmentTargets().first)
    #expect(call.0 == first.id)
    #expect(call.1 == first.teammate.id)
    #expect(call.2 == MessageID(messageID))
    #expect(call.3.isEmpty, "The pending placeholder must never become saved user text")
    #expect(call.4 == [captured.id])

    try await select(second, in: model)
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed && model.attachmentDraft.canSubmit }
    model.conversation.composerText = "Rook’s draft must remain unchanged"
    let otherDraft = model.attachmentDraft
    await gate.release()
    try await waitWorkspaceAttachment { originalDraft.rows.map(\.id) == [nextID] }
    #expect(model.conversation.conversationID == second.id.rawValue)
    #expect(model.conversation.composerText == "Rook’s draft must remain unchanged")
    #expect(model.attachmentDraft === otherDraft)
    #expect(otherDraft.rows.map(\.id) == [other.id.rawValue])
    #expect(!model.conversation.messageRows.contains(where: { $0.id == messageID }))

    try await select(first, in: model)
    let saved = try #require(model.conversation.messageRows.first(where: { $0.id == messageID })?.snapshot)
    #expect(saved.delivery == .sent)
    let attachmentIDs = saved.parts.compactMap { part -> UUID? in
        guard case .attachment(let attachment) = part.content else { return nil }
        return attachment.id
    }
    #expect(attachmentIDs == [captured.id.rawValue])
    #expect(!saved.body.contains("Saving attachment"))
    #expect(model.attachmentDraft === originalDraft)
    #expect(originalDraft.rows.map(\.id) == [nextID])
    #expect(await store.draft(first.id).attachments.map(\.id) == [AttachmentID(nextID)])
    #expect(await store.draft(second.id).attachments.map(\.id) == [other.id])
    #expect(await service.recordedAttachmentTargets().count == 1)
}

@Test("Workspace distinguishes failed attachment send from saved-user-only fixture recovery", arguments: [false, true])
@MainActor
func durableWorkspaceDurableAttachmentFailurePreservesCorrectAuthority(savedUserOnly: Bool) async throws {
    let (chat, greeting) = try durableWorkspaceFixture(suffix: savedUserOnly ? "64" : "63", name: "Attachment Recovery", seed: 163)
    let attachment = try workspaceDurableAttachment(chat.id, suffix: savedUserOnly ? 5 : 4)
    let store = WorkspaceDurableAttachmentStore(assets: [attachment])
    let drafts = WorkspaceAttachmentTextDraftStore()
    let gate = WorkspaceAttachmentSendGate()
    let service = DurableWorkspaceFakeService(chats: [chat],
        selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        messages: [chat.id: [greeting]], attachmentStore: store, attachmentSendGate: gate,
        attachmentSendOutcome: savedUserOnly ? .savedUserOnly : .failure)
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
        draftService: drafts, attachmentDraftFactory: workspaceDurableAttachmentFactory(store))
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.canSend }
    let rawText = "  Keep the exact draft e\u{301} and its file.  \n"
    model.conversation.composerText = rawText
    let messageID = workspaceDurableAttachmentID(savedUserOnly ? 22 : 21)
    model.conversation.sendCurrentText(messageID: messageID)
    #expect(model.conversation.messageRows.last?.snapshot.delivery == .pending)
    #expect(model.conversation.composerText.isEmpty)
    try await waitWorkspaceAttachment { await gate.started }
    defer { Task { await gate.release() } }
    let capture = try #require(await service.recordedAttachmentTargets().first)
    #expect(capture.0 == chat.id && capture.1 == chat.teammate.id && capture.2 == MessageID(messageID))
    #expect(capture.3.utf8.elementsEqual(rawText.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    #expect(capture.4 == [attachment.id])
    let safetyCopy = try #require(await drafts.load(conversationID: chat.id))
    #expect(safetyCopy.text.utf8.elementsEqual(rawText.utf8))
    await gate.release()
    if savedUserOnly {
        try await waitWorkspaceAttachment {
            model.conversation.messageRows.contains { $0.snapshot.body.contains("do not resend the message") }
        }
        let user = try #require(model.conversation.messageRows.first(where: { $0.id == messageID })?.snapshot)
        #expect(user.delivery == .sent)
        #expect(model.conversation.messageRows.filter { $0.id == messageID }.count == 1)
        #expect(model.attachmentDraft.rows.isEmpty)
        #expect(model.conversation.composerText.isEmpty)
        #expect(await store.draft(chat.id).attachments.isEmpty)
        #expect(await drafts.load(conversationID: chat.id)?.text.isEmpty == true)
        #expect(!model.conversation.canSend)
        let status = try #require(model.conversation.messageRows.first {
            $0.snapshot.body.contains("do not resend the message")
        }?.snapshot)
        #expect(status.delivery == .sent)
        #expect(status.body.contains("Your message was saved"))
        let stored = try await service.loadMessages(conversationID: chat.id, beforeSequence: nil, limit: 20)
        #expect(stored.messages.map(\.id).filter { $0 == MessageID(messageID) }.count == 1)
        #expect(stored.messages.count == 2, "The fake reports exactly the saved user row, not a fabricated reply")
    } else {
        try await waitWorkspaceAttachment {
            guard let row = model.conversation.messageRows.first(where: { $0.id == messageID }) else { return false }
            if case .failed = row.snapshot.delivery { return true }
            return false
        }
        #expect(model.conversation.composerText.utf8.elementsEqual(rawText.utf8))
        #expect(model.attachmentDraft.rows.map(\.id) == [attachment.id.rawValue])
        #expect(await store.draft(chat.id).attachments == [attachment])
        let stored = try await service.loadMessages(conversationID: chat.id, beforeSequence: nil, limit: 20)
        #expect(!stored.messages.contains(where: { $0.id == MessageID(messageID) }))
    }
    #expect(await service.recordedAttachmentTargets().count == 1, "Neither recovery branch may resend automatically")
}

private enum WorkspaceAttachmentSendOutcome: Sendable { case success, failure, savedUserOnly }

@Test("Normal local save preserves history and newer drafts without fixture rows or teammate activity")
@MainActor
func durableWorkspaceLocalOnlyPersistence() async throws {
    let (first, oldGreeting) = try durableWorkspaceFixture(suffix: "91", name: "Local Ada", seed: 191)
    let (second, secondGreeting) = try durableWorkspaceFixture(suffix: "92", name: "Local Rook", seed: 192)
    let drafts = WorkspaceAttachmentTextDraftStore()
    let gate = WorkspaceAttachmentSendGate()
    let service = DurableWorkspaceFakeService(chats: [first, second],
        selected: DurableChatSelectionSnapshot(teammate: first.teammate, conversation: first.conversation),
        messages: [first.id: [oldGreeting], second.id: [secondGreeting]], attachmentSendGate: gate)
    var fixtureFactoryCalls = 0
    let model = DurableWorkspaceModel(service: service, hiringService: try durableHiringFixture().0,
        draftService: drafts, cardFixtureFactory: { _ in fixtureFactoryCalls += 1; return nil })
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed }
    #expect(model.mode == .localOnly)
    #expect(model.conversation.isLocalOnly)
    #expect(model.conversation.submissionActionTitle == "Save Message")
    #expect(model.conversation.readyDeliveryDescription.contains("Claude isn’t connected"))
    #expect(model.conversation.readyDeliveryDescription.contains("Nothing is sent automatically"))
    #expect(model.conversation.messages.map(\.id) == [oldGreeting.id.rawValue])
    #expect(fixtureFactoryCalls == 0)
    let priorActivity = model.sidebar.rows.first(where: { $0.id == first.teammate.id.rawValue })?.activity
    model.conversation.composerText = "Save this local message"
    let messageID = UUID()
    model.conversation.sendCurrentText(messageID: messageID)
    try await waitWorkspaceAttachment { await gate.started }
    defer { Task { await gate.release() } }
    #expect(model.sidebar.rows.first(where: { $0.id == first.teammate.id.rawValue })?.activity == priorActivity)
    model.conversation.composerText = "Newer first-chat draft"
    try await select(second, in: model)
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed }
    model.conversation.composerText = "Other-chat draft"
    await gate.release()
    try await waitWorkspaceAttachment {
        (try? await service.loadMessages(conversationID: first.id, beforeSequence: nil, limit: 10))?.messages.count == 2
    }
    #expect(model.conversation.composerText == "Other-chat draft")
    #expect(await service.recordedTargets().isEmpty)
    #expect(await service.recordedLocalTargets().count == 1)
    try await select(first, in: model)
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed }
    #expect(model.conversation.composerText == "Newer first-chat draft")
    #expect(model.conversation.messages.map(\.id) == [oldGreeting.id.rawValue, messageID])
    #expect(model.conversation.messages.last?.author == .user)
    #expect(model.conversation.messages.allSatisfy { $0.streamState == .notStreaming })
    #expect(model.sidebar.rows.first(where: { $0.id == first.teammate.id.rawValue })?.activity == priorActivity)
}

@Test("Normal local attachment save consumes captured files and leaves no synthetic reply")
@MainActor
func durableWorkspaceLocalOnlyAttachmentPersistence() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "93", name: "Local Files", seed: 193)
    let asset = try workspaceDurableAttachment(chat.id, suffix: 91)
    let store = WorkspaceDurableAttachmentStore(assets: [asset])
    let service = DurableWorkspaceFakeService(chats: [chat],
        selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        attachmentStore: store)
    let model = DurableWorkspaceModel(service: service, hiringService: try durableHiringFixture().0,
        draftService: WorkspaceAttachmentTextDraftStore(), attachmentDraftFactory: workspaceDurableAttachmentFactory(store))
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.canSend }
    let messageID = UUID()
    model.conversation.sendCurrentText(messageID: messageID)
    try await waitWorkspaceAttachment {
        model.conversation.messageRows.last?.snapshot.delivery == .sent && model.attachmentDraft.rows.isEmpty
    }
    #expect(model.conversation.messages.count == 1)
    let saved = try #require(model.conversation.messages.first)
    #expect(saved.id == messageID && saved.author == .user)
    #expect(saved.streamState == .notStreaming)
    #expect(saved.parts.count == 1)
    let savedAttachmentIDs = saved.parts.compactMap { part -> UUID? in
        guard case .attachment(let attachment) = part.content else { return nil }
        return attachment.id
    }
    #expect(savedAttachmentIDs == [asset.id.rawValue])
    #expect(await service.recordedTargets().isEmpty)
    #expect(await service.recordedLocalTargets().first?.4 == [asset.id])
    #expect(await store.draft(chat.id).attachments.isEmpty)
}

@Test("Failed normal local saves preserve text and attachment drafts without automatic retry")
@MainActor
func durableWorkspaceLocalOnlyFailurePreservesDraft() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "94", name: "Local Recovery", seed: 194)
    let asset = try workspaceDurableAttachment(chat.id, suffix: 92)
    let store = WorkspaceDurableAttachmentStore(assets: [asset])
    let service = DurableWorkspaceFakeService(chats: [chat],
        selected: DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation),
        attachmentStore: store, attachmentSendOutcome: .failure)
    let model = DurableWorkspaceModel(service: service, hiringService: try durableHiringFixture().0,
        draftService: WorkspaceAttachmentTextDraftStore(), attachmentDraftFactory: workspaceDurableAttachmentFactory(store))
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.canSend }
    let exactDraft = "  Keep this draft exactly\n"
    model.conversation.composerText = exactDraft
    let messageID = UUID()
    model.conversation.sendCurrentText(messageID: messageID)
    try await waitWorkspaceAttachment {
        guard let row = model.conversation.messageRows.first(where: { $0.id == messageID }) else { return false }
        if case .failed = row.snapshot.delivery { return true }
        return false
    }
    #expect(model.conversation.composerText.utf8.elementsEqual(exactDraft.utf8))
    #expect(model.attachmentDraft.rows.map(\.id) == [asset.id.rawValue])
    #expect(await store.draft(chat.id).attachments == [asset])
    #expect(await service.recordedLocalTargets().count == 1)
    #expect(await service.recordedTargets().isEmpty)
    #expect(try await service.loadMessages(conversationID: chat.id, beforeSequence: nil, limit: 10).messages.isEmpty)
}

private actor WorkspaceAttachmentSendGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor WorkspaceDurableAttachmentStore {
    private var assets: [ConversationID: [AttachmentAsset]]
    private var revisions: [ConversationID: Int64] = [:]
    init(assets: [AttachmentAsset]) { self.assets = Dictionary(grouping: assets, by: \.conversationID) }
    func draft(_ conversationID: ConversationID) -> AttachmentDraftSnapshot {
        AttachmentDraftSnapshot(conversationID: conversationID, revision: revisions[conversationID] ?? 1,
                                attachments: assets[conversationID] ?? [])
    }
    func stage(_ url: URL, operationID: UUID, conversationID: ConversationID) throws -> AttachmentAsset {
        let asset = try AttachmentAsset(id: AttachmentID(operationID), conversationID: conversationID,
            displayName: url.lastPathComponent, typeIdentifier: "public.plain-text", byteCount: 6,
            sha256: String(repeating: "a", count: 64), createdAt: Date(timeIntervalSince1970: 9_300))
        assets[conversationID, default: []].append(asset)
        revisions[conversationID, default: 1] += 1
        return asset
    }
    func remove(_ id: AttachmentID, conversationID: ConversationID) -> AttachmentDraftSnapshot {
        assets[conversationID]?.removeAll { $0.id == id }
        revisions[conversationID, default: 1] += 1
        return draft(conversationID)
    }
    func consume(_ ids: [AttachmentID], in conversationID: ConversationID) throws {
        guard Set(ids).isSubset(of: Set((assets[conversationID] ?? []).map(\.id))) else {
            throw AttachmentRepositoryError.draftItemMissing
        }
        assets[conversationID]?.removeAll { ids.contains($0.id) }
        revisions[conversationID, default: 1] += 1
    }
}

private actor WorkspaceAttachmentTextDraftStore: ConversationDraftServing {
    private var drafts: [ConversationID: ConversationDraftSnapshot] = [:]
    func load(conversationID: ConversationID) -> ConversationDraftSnapshot? { drafts[conversationID] }
    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) throws -> ConversationDraftSnapshot {
        guard (drafts[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let next = try ConversationDraftSnapshot(conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: Date(timeIntervalSince1970: 9_300))
        drafts[conversationID] = next
        return next
    }
}

@MainActor
private func workspaceDurableAttachmentFactory(_ store: WorkspaceDurableAttachmentStore) -> WorkspaceAttachmentCoordinator.Factory {
    { conversationID in
        AttachmentDraftModel(conversationID: conversationID, load: { await store.draft(conversationID) },
            importFile: { url, operationID in try await store.stage(url, operationID: operationID, conversationID: conversationID) },
            remove: { await store.remove($0, conversationID: conversationID) })
    }
}

private func workspaceDurableAttachment(_ conversationID: ConversationID, suffix: UInt64) throws -> AttachmentAsset {
    try AttachmentAsset(id: AttachmentID(workspaceDurableAttachmentID(suffix)), conversationID: conversationID,
        displayName: "workspace-attachment-\(suffix).txt", typeIdentifier: "public.plain-text", byteCount: 12,
        sha256: String(repeating: "b", count: 64), createdAt: Date(timeIntervalSince1970: 9_300))
}

private func workspaceDurableAttachmentID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "AD300000-0000-0000-0000-%012llx", value))!
}

@MainActor
private func waitWorkspaceAttachment(_ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<500 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw WorkspaceAttachmentIntegrationTimeout()
}

private struct WorkspaceAttachmentIntegrationTimeout: Error {}

private actor WorkspaceRunRecoverySpy: RunRecoveryFixtureServing {
    private(set) var loaded: [ConversationID] = []
    private(set) var mutations = 0
    func reviews(conversationID: ConversationID) async throws -> [RunRecoveryReview] {
        loaded.append(conversationID)
        return []
    }
    func startDemo(conversationID: ConversationID) async throws -> RunRecoveryReview {
        mutations += 1; throw RunJournalError.unavailable
    }
    func acknowledgeDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        mutations += 1; throw RunJournalError.unavailable
    }
    func finishDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        mutations += 1; throw RunJournalError.unavailable
    }
    func interruptDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        mutations += 1; throw RunJournalError.unavailable
    }
    func recoverExpiredDemos(conversationID: ConversationID) async throws -> [RunRecoveryReview] {
        mutations += 1; throw RunJournalError.unavailable
    }
}

private actor WorkspaceProposalSpy: ActionProposalFixtureServing {
    private(set) var loaded: [ConversationID] = []
    private(set) var mutations = 0
    func proposals(conversationID: ConversationID) async throws -> [ActionProposalRecord] {
        loaded.append(conversationID); return []
    }
    func prepare(conversationID: ConversationID, action: ConsequentialActionKind) async throws -> ActionProposalRecord {
        mutations += 1; throw ActionProposalError.unavailable
    }
    func decide(_ review: ActionProposalRecord, decision: ActionProposalDecision) async throws -> ActionProposalRecord {
        mutations += 1; throw ActionProposalError.unavailable
    }
}

@MainActor
@Test("Run recovery follows verified conversation selection without changing drafts or starting work")
func durableWorkspaceRunRecoverySelection() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "61", name: "Run Ada", seed: 61)
    let (mira, greetingB) = try durableWorkspaceFixture(suffix: "62", name: "Run Mira", seed: 62)
    let service = DurableWorkspaceFakeService(chats: [ada, mira],
        selected: DurableChatSelectionSnapshot(teammate: ada.teammate, conversation: ada.conversation),
        messages: [ada.id: [greetingA], mira.id: [greetingB]])
    let recoveryService = WorkspaceRunRecoverySpy()
    let recovery = RunRecoveryWorkspaceModel(service: recoveryService)
    let proposalService = WorkspaceProposalSpy()
    let proposals = ActionProposalWorkspaceModel(service: proposalService)
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
                                      runRecoveryModel: recovery, actionProposalModel: proposals)
    try await model.loadInitialWorkspace()
    #expect(recovery.conversationID == ada.id.rawValue)
    #expect(proposals.conversationID == ada.id.rawValue)
    #expect(await proposalService.loaded.isEmpty)
    #expect(await proposalService.mutations == 0)
    #expect(await recoveryService.loaded.isEmpty)
    #expect(await recoveryService.mutations == 0)
    model.conversation.composerText = "Keep Ada draft"
    await recovery.load()
    await proposals.load()
    #expect(await proposalService.loaded == [ada.id])
    #expect(await recoveryService.loaded == [ada.id])
    #expect(model.conversation.inputAvailability == .ready)
    try await select(mira, in: model)
    #expect(recovery.conversationID == mira.id.rawValue)
    #expect(proposals.conversationID == mira.id.rawValue)
    model.conversation.composerText = "Keep Mira draft"
    await recovery.load()
    try await select(ada, in: model)
    #expect(recovery.conversationID == ada.id.rawValue)
    #expect(model.conversation.composerText == "Keep Ada draft")
    model.beginTeammateCreation()
    #expect(recovery.conversationID == nil)
    #expect(proposals.conversationID == nil)
    #expect(!proposals.canPrepare)
    #expect(await proposalService.mutations == 0)
    #expect(!recovery.canMutate)
    #expect(await recoveryService.mutations == 0)
    #expect(await service.recordedTargets().isEmpty)
}

private actor WorkspaceSavedOutcomeSpy: ConversationOutcomeHistoryServing {
    private(set) var requests: [ConversationOutcomeHistoryRequest] = []
    func history(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistorySummary {
        requests.append(request)
        return ConversationOutcomeHistorySummary(scope: .available, outcomes: [], hasMore: false,
            notice: "No saved outcomes were found for this conversation.")
    }
}

@MainActor
@Test("Queued navigation cannot dismiss newer hiring or restore its revoked saved-outcome scope")
func durableWorkspaceQueuedSelectionCannotReplaceHiring() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "73", name: "Queued Ada", seed: 73)
    let (mira, greetingB) = try durableWorkspaceFixture(suffix: "74", name: "Queued Mira", seed: 74)
    let service = DurableWorkspaceFakeService(chats: [ada, mira],
        selected: DurableChatSelectionSnapshot(teammate: ada.teammate, conversation: ada.conversation),
        messages: [ada.id: [greetingA], mira.id: [greetingB]])
    let reader = WorkspaceSavedOutcomeSpy()
    let history = SavedOutcomeHistoryModel(service: reader)
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
                                      savedOutcomeHistoryModel: history)
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "Keep the current draft"
    let messages = model.conversation.messages
    model.sidebar.selection = mira.teammate.id.rawValue
    let navigation = try #require(model.selectionTask)
    // Both actions occur in the same actor turn, before navigation can start.
    model.beginTeammateCreation()
    let hiring = try #require(model.hiringModel)
    await navigation.value

    #expect(model.hiringModel === hiring)
    #expect(model.sidebar.selection == nil)
    #expect(history.request == nil && history.summary == nil && !history.canLoad)
    #expect(model.conversation.conversationID == ada.id.rawValue)
    #expect(model.conversation.messages == messages)
    #expect(model.conversation.composerText == "Keep the current draft")
    #expect(await service.selectionWriteCount == 0)
    #expect(await reader.requests.isEmpty)
    await hiring.load()
    #expect(await hiring.cancel())
    model.completeHiringCancellation(from: hiring)
    #expect(model.hiringModel == nil)
    #expect(model.sidebar.selection == ada.teammate.id.rawValue)
    #expect(model.conversation.conversationID == ada.id.rawValue)
    #expect(model.conversation.messages == messages)
    #expect(model.conversation.composerText == "Keep the current draft")
    #expect(history.request?.conversationID == ada.id)
    #expect(history.request?.teammateID == ada.teammate.id)
    #expect(await service.selectionWriteCount == 0)
    model.beginShutdown()
    model.finishShutdown()
}

@MainActor
@Test("Saved outcomes follow resolved selection, clear for hiring and stop at shutdown without touching chat")
func durableWorkspaceSavedOutcomeHistorySelection() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "71", name: "History Ada", seed: 71)
    let (mira, greetingB) = try durableWorkspaceFixture(suffix: "72", name: "History Mira", seed: 72)
    let service = DurableWorkspaceFakeService(chats: [ada, mira],
        selected: DurableChatSelectionSnapshot(teammate: ada.teammate, conversation: ada.conversation),
        messages: [ada.id: [greetingA], mira.id: [greetingB]])
    let reader = WorkspaceSavedOutcomeSpy()
    let history = SavedOutcomeHistoryModel(service: reader)
    let model = DurableWorkspaceModel(mode: .reviewFixture, service: service, hiringService: try durableHiringFixture().0,
                                      savedOutcomeHistoryModel: history)
    try await model.loadInitialWorkspace()
    let adaScope = try ConversationOutcomeHistoryRequest(conversationID: ada.id, teammateID: ada.teammate.id)
    let miraScope = try ConversationOutcomeHistoryRequest(conversationID: mira.id, teammateID: mira.teammate.id)
    #expect(history.request == adaScope)
    #expect(await reader.requests.isEmpty, "Mounting a conversation must not silently read saved outcome records.")
    model.conversation.composerText = "Keep Ada's unsent draft"
    await history.load()
    #expect(history.summary?.scope == .available)
    #expect(await reader.requests == [adaScope])

    model.sidebar.selection = mira.teammate.id.rawValue
    #expect(history.request == nil && history.summary == nil && !history.canLoad,
            "Selection must revoke the old read synchronously, before navigation awaits.")
    try await select(mira, in: model)
    #expect(history.request == miraScope && history.summary == nil && !history.hasRequested)
    await history.load()
    try await select(ada, in: model)
    #expect(history.request == adaScope && history.summary == nil)
    #expect(model.conversation.composerText == "Keep Ada's unsent draft")
    model.beginTeammateCreation()
    #expect(history.request == nil && !history.canLoad && history.summary == nil)
    await history.load()
    #expect(await reader.requests == [adaScope, miraScope])
    #expect(await service.recordedTargets().isEmpty)

    try await select(ada, in: model)
    // Hiring kept Ada's prior transcript mounted; matching that old transcript
    // alone does not prove the queued return navigation has restored scope.
    let scopeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while history.request != adaScope, ContinuousClock.now < scopeDeadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(history.request == adaScope)
    model.beginShutdown()
    #expect(history.isClosing && !history.canLoad && history.summary == nil)
    await history.load()
    #expect(await reader.requests == [adaScope, miraScope])
    #expect(await service.recordedTargets().isEmpty)
}

private actor WorkspaceTextReplyTestService: ClaudeTextReplyServing {
    private let store: DurableWorkspaceFakeService
    private let rejection: ClaudeTextTurnProblem?
    private let statusOnlyReply: Bool
    private let pendingStatusReply: Bool
    private let pausesBeforeReply: Bool
    private var firstReplyGate: CheckedContinuation<Void, Never>?
    private var cleanupOutcome: ClaudeTextTurnOutcome?
    private var progressCallback: (@Sendable (ClaudeTextTurnProgress) async -> Void)?
    private var retainedProgress: [UUID: @Sendable (ClaudeTextTurnProgress) async -> Void] = [:]
    private let retainsProgress: Bool
    private var savedReplyForProgress: Message?
    private var completion: CheckedContinuation<ClaudeTextTurnOutcome, Never>?
    private var records: [TextTurnMessageProvenance] = []
    private var delayedProvenanceFailure: Bool?
    private var provenanceContinuation: CheckedContinuation<Void, Never>?
    private(set) var submissions: [ClaudeTextTurnSubmission] = []
    private(set) var waitingBeforeReply = false
    private(set) var waiting = false
    private(set) var provenanceWaiting = false
    private(set) var cancellationObserved = false
    /// How many turns saw their task cancelled, for a test that stops more than one.
    private(set) var cancellations = 0

    /// A card raised while the turn waits, the way a work turn asks before a move.
    private let cardWhileWaiting: Bool

    init(store: DurableWorkspaceFakeService, rejection: ClaudeTextTurnProblem? = nil,
         statusOnlyReply: Bool = false, pausesBeforeReply: Bool = false, cardWhileWaiting: Bool = false,
         retainsProgress: Bool = false, pendingStatusReply: Bool = false) {
        self.store = store
        self.rejection = rejection
        self.statusOnlyReply = statusOnlyReply
        self.pendingStatusReply = pendingStatusReply
        self.pausesBeforeReply = pausesBeforeReply
        self.cardWhileWaiting = cardWhileWaiting
        self.retainsProgress = retainsProgress
    }

    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        submissions.append(submission)
        if let rejection { return .init(outcome: .failed(rejection)) }
        do {
            let user = try await store.saveMessageLocally(
                conversationID: submission.conversationID, teammateID: submission.teammateID,
                userMessageID: submission.userMessageID, text: submission.text, attachmentIDs: []
            )
            await onProgress(.userMessageSaved(user))
            if pausesBeforeReply {
                await onProgress(.modelObserved(requested: "sonnet", observed: "claude-sonnet-5"))
            }
            await onProgress(.stage(.responding))
            if pausesBeforeReply {
                await withCheckedContinuation { continuation in
                    if cleanupOutcome != nil { continuation.resume() }
                    else { firstReplyGate = continuation; waitingBeforeReply = true }
                }
            }
            let reply = try Message(
                id: MessageID(UUID()), conversationID: submission.conversationID,
                sequence: user.sequence + 1, author: .teammate(submission.teammateID),
                deliveryState: pendingStatusReply ? .pending : statusOnlyReply ? .failed : .acknowledged,
                parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                    content: pendingStatusReply ? .status("Waiting for Claude's reply.")
                        : statusOnlyReply ? .status("Claude could not produce a reply.") : .text("Actual injected provider text"))],
                createdAt: Date(timeIntervalSince1970: 20_000), updatedAt: Date(timeIntervalSince1970: 20_000)
            )
            await store.storeActualReplyForTest(reply)
            let runID = RunID(UUID())
            records.append(.init(messageID: user.id, replyMessageID: reply.id, runID: runID,
                                 teammateID: submission.teammateID, state: .running, inputState: .acknowledged))
            progressCallback = onProgress
            if retainsProgress { retainedProgress[submission.userMessageID.rawValue] = onProgress }
            savedReplyForProgress = reply
            await onProgress(.assistantMessageSaved(reply))
            if cardWhileWaiting {
                await onProgress(.approvalRequired(ClaudeTextApproval(id: UUID(), runID: runID, requestID: "q1",
                    toolName: "Bash", title: "Move or rename files with a command", detail: "mv a b",
                    target: "Bots/Zed", expiresAt: Date().addingTimeInterval(600))))
            }
            let requested = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let cleanupOutcome { continuation.resume(returning: cleanupOutcome) }
                    else { completion = continuation; waiting = true }
                }
            } onCancel: {
                Task { await self.observeCancellation() }
            }
            let outcome: ClaudeTextTurnOutcome = Task.isCancelled ? .stopped : requested
            let state: WorkRunState
            // The saved outcome the real repository would record: a declined
            // turn is journalled failed, and only the outcome tells it apart.
            let durable: TextTurnOutcome
            switch outcome {
            case .completed: state = .succeeded; durable = .succeeded
            case .stopped: state = .interrupted; durable = .interrupted
            case .failed(let problem, _): state = .failed; durable = problem == .declined ? .declined : .failed
            }
            records.removeAll { $0.runID == runID }
            records.append(.init(messageID: user.id, replyMessageID: reply.id, runID: runID,
                                 teammateID: submission.teammateID, state: state, inputState: .acknowledged,
                                 outcome: durable))
            let finalReply = savedReplyForProgress ?? reply
            progressCallback = nil
            savedReplyForProgress = nil
            return .init(outcome: outcome, savedUserMessage: user, savedReplyMessage: finalReply)
        } catch {
            return .init(outcome: .failed(.persistenceFailed))
        }
    }

    func release(_ outcome: ClaudeTextTurnOutcome) {
        completion?.resume(returning: outcome)
        completion = nil
        waiting = false
    }

    func releaseFirstReply() {
        firstReplyGate?.resume()
        firstReplyGate = nil
        waitingBeforeReply = false
    }

    /// The settled bubbles of the reply in flight, as the real service publishes them.
    func publishBubbles(_ bubbles: [String]) async -> Bool {
        guard let progressCallback else { return false }
        await progressCallback(.bubbles(bubbles))
        return true
    }

    /// A deliberately delayed service event, including one from a finished
    /// reservation, so avatar presentation must establish its own ownership.
    func publishAvatarProgress(_ progress: ClaudeTextTurnProgress, messageID: UUID? = nil) async -> Bool {
        let callback = messageID.flatMap { retainedProgress[$0] } ?? (messageID == nil ? progressCallback : nil)
        guard let callback else { return false }
        await callback(progress)
        return true
    }

    func appendSavedReplyProgress() async throws -> Bool {
        guard let progressCallback, let previous = savedReplyForProgress,
              let part = previous.parts.first, case let .text(text) = part.content else { return false }
        let next = try Message(id: previous.id, conversationID: previous.conversationID,
            sequence: previous.sequence, author: previous.author, deliveryState: previous.deliveryState,
            parts: [try MessagePart(id: part.id, ordinal: part.ordinal, content: .text(text + " with another chunk"))],
            createdAt: previous.createdAt, updatedAt: previous.updatedAt.addingTimeInterval(1))
        await store.storeActualReplyForTest(next)
        savedReplyForProgress = next
        await progressCallback(.assistantMessageSaved(next))
        return true
    }

    func releaseForCleanup() {
        retainedProgress = [:]
        cleanupOutcome = .stopped
        releaseFirstReply()
        release(.stopped)
    }

    private func observeCancellation() { cancellationObserved = true; cancellations += 1 }

    func delayNextProvenance(fails: Bool) { delayedProvenanceFailure = fails }

    func releaseProvenance() {
        provenanceContinuation?.resume()
        provenanceContinuation = nil
        provenanceWaiting = false
    }

    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        let snapshot = records.filter { record in
            messageIDs.contains(record.messageID) || messageIDs.contains(record.replyMessageID)
        }
        if let fails = delayedProvenanceFailure {
            delayedProvenanceFailure = nil
            await withCheckedContinuation { continuation in
                provenanceContinuation = continuation
                provenanceWaiting = true
            }
            if fails { throw WorkspaceProvenanceTestError.unavailable }
            return snapshot.map { record in
                .init(messageID: record.messageID, replyMessageID: record.replyMessageID,
                      runID: record.runID, teammateID: record.teammateID, state: .running, inputState: .submitted)
            }
        }
        return snapshot
    }
}

@MainActor
@Test("Approval and question cards pause the real avatar and matching resolutions restore its current work state")
func durableWorkspaceCardsDriveAvatarActivity() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "f2", name: "Card Activity", seed: 442)
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, retainsProgress: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    model.conversation.composerText = "Check the notes"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waiting }
    let messageID = try #require(await live.submissions.first).userMessageID.rawValue
    func activity() -> TeammateActivityState? { model.sidebar.rows.first { $0.id == chat.teammate.id.rawValue }?.activity }
    #expect(await live.publishBubbles(["I’ll check the notes."]))
    #expect(activity() == .speaking)
    let approval = ClaudeTextApproval(id: UUID(), runID: RunID(UUID()), requestID: "approval",
        toolName: "Bash", title: "Move the notes", detail: "fixture move", target: "fixture", expiresAt: Date().addingTimeInterval(600))
    #expect(await live.publishAvatarProgress(.approvalRequired(approval)))
    #expect(model.conversation.textReplyApproval == approval && activity() == .waitingForUser)
    let question = ClaudeTextQuestion(id: UUID(), runID: approval.runID, requestID: "question", header: "Destination",
        prompt: "Which folder?", options: [], allowsMultiple: false, isSecret: false, position: 0, count: 1,
        expiresAt: approval.expiresAt)
    #expect(await live.publishAvatarProgress(.questionAsked(question)))
    #expect(model.conversation.textReplyQuestion == question && activity() == .waitingForUser)
    #expect(await live.publishBubbles(["The notes are ready for your choice."]))
    #expect(activity() == .waitingForUser, "A progress bubble must not restart motion while a card still waits")
    #expect(await live.publishAvatarProgress(.approvalResolved(id: UUID())))
    #expect(activity() == .waitingForUser)
    #expect(await live.publishAvatarProgress(.approvalResolved(id: approval.id)))
    #expect(activity() == .waitingForUser, "Resolving one card leaves the other pending")
    #expect(await live.publishAvatarProgress(.questionResolved(id: question.id)))
    #expect(activity() == .speaking, "Restore the latest still-busy state, not an invented idle state")
    #expect(await live.publishAvatarProgress(.stage(.saving)))
    #expect(activity() == .thinkingOrWorking)
    await live.release(.completed)
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
    #expect(activity() == .idle)
    #expect(await live.publishAvatarProgress(.questionResolved(id: question.id), messageID: messageID))
    #expect(activity() == .idle, "A finished reservation cannot revive its avatar")
}

@MainActor
@Test("Stopped and superseded card receipts cannot move the current avatar or clear a newer turn's waiting state")
func durableWorkspaceStaleCardsDoNotRestartAvatar() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "f3", name: "Current Activity", seed: 443)
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, retainsProgress: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    func activity() -> TeammateActivityState? { model.sidebar.rows.first { $0.id == chat.teammate.id.rawValue }?.activity }
    model.conversation.composerText = "First request"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waiting }
    let oldMessage = try #require(await live.submissions.first).userMessageID.rawValue
    let approval = ClaudeTextApproval(id: UUID(), runID: RunID(UUID()), requestID: "first-card",
        toolName: "Bash", title: "Move a note", detail: "fixture move", target: "fixture", expiresAt: Date().addingTimeInterval(600))
    #expect(await live.publishAvatarProgress(.approvalRequired(approval)))
    #expect(activity() == .waitingForUser)
    model.conversation.stopCurrentTextReply()
    #expect(model.conversation.textReplyPhase == .stopping)
    #expect(await live.publishAvatarProgress(.approvalResolved(id: approval.id)))
    #expect(activity() == .waitingForUser, "A resolution during Stop must not restart working motion")
    await live.release(.stopped)
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .stopped && !model.conversation.hasPendingSubmissions }
    #expect(activity() == .idle)
    model.conversation.composerText = "Second request"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment {
        let count = await live.submissions.count
        let waiting = await live.waiting
        return count == 2 && waiting
    }
    let question = ClaudeTextQuestion(id: UUID(), runID: RunID(UUID()), requestID: "current-card", header: "Choice",
        prompt: "Which note?", options: [], allowsMultiple: false, isSecret: false, position: 0, count: 1,
        expiresAt: approval.expiresAt)
    #expect(await live.publishAvatarProgress(.questionAsked(question)))
    #expect(activity() == .waitingForUser)
    #expect(await live.publishAvatarProgress(.questionResolved(id: question.id), messageID: oldMessage))
    #expect(await live.publishAvatarProgress(.bubbles(["Late old bubble"]), messageID: oldMessage))
    #expect(activity() == .waitingForUser && model.conversation.textReplyQuestion == question)
    #expect(await live.publishAvatarProgress(.questionResolved(id: question.id)))
    #expect(activity() == .thinkingOrWorking)
    await live.release(.completed)
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
    #expect(activity() == .idle)
}

private enum WorkspaceProvenanceTestError: Error { case unavailable }

@Test("A reply is never painted letter by letter: the creature works until the first line is settled, then speaks, then rests")
@MainActor
func durableWorkspaceTextReplyPaintsCommittedBubblesOnly() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "b1", name: "Activity Evidence", seed: 411)
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, pausesBeforeReply: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    let row = try #require(model.sidebar.rowModels.first)
    #expect(row.snapshot.activity == .idle)
    defer { Task { await live.releaseForCleanup() } }
    model.conversation.composerText = "Wait for actual public text"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waitingBeforeReply }

    #expect(model.conversation.textReplyPhase == .responding)
    #expect(row.snapshot.activity == .thinkingOrWorking,
            "Initialization and model metadata are not public reply text")
    #expect(model.conversation.messages.allSatisfy { $0.isFromUser })
    #expect(await live.submissions.count == 1)

    // A saved partial reply is a checkpoint, not something to show
    // (committed bubbles, never streamed text).
    await live.releaseFirstReply()
    try await waitWorkspaceAttachment { await live.waiting }
    #expect(row.snapshot.activity == .thinkingOrWorking)
    #expect(model.conversation.messages.allSatisfy { $0.isFromUser }, "partial text must not be painted")
    #expect(try await live.appendSavedReplyProgress())
    #expect(model.conversation.messages.allSatisfy { $0.isFromUser }, "a longer partial is still not painted")

    // The first settled bubble is the first thing the reader sees.
    #expect(await live.publishBubbles(["First line."]))
    try await waitWorkspaceAttachment { model.conversation.messages.last?.isFromUser == false }
    #expect(model.conversation.messages.last?.body == "First line.")
    #expect(model.conversation.messages.last?.streamState == .notStreaming)
    #expect(row.snapshot.activity == .speaking)
    var repeatedActivityPublications = 0
    let observation = row.$snapshot.dropFirst().sink { _ in repeatedActivityPublications += 1 }
    defer { observation.cancel() }
    #expect(await live.publishBubbles(["First line."]))
    #expect(model.conversation.messages.last?.body == "First line.")
    #expect(repeatedActivityPublications == 0, "An unchanged speaking state must not restart character motion")
    #expect(model.sidebar.rowModels.first === row)

    await live.release(.completed)
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
    #expect(row.snapshot.activity == .idle)
    #expect(model.sidebar.rowModels.first === row)
    #expect(await live.submissions.count == 1)
}

@Test("Real text adapter keeps frozen routing, committed input and newer drafts across navigation and failure")
@MainActor
func durableWorkspaceTextReplyRoutingAndReopenProvenance() async throws {
    let (first, oldLocal) = try durableWorkspaceFixture(suffix: "a1", name: "Text First", seed: 401)
    let (second, _) = try durableWorkspaceFixture(suffix: "a2", name: "Text Second", seed: 402)
    let store = DurableWorkspaceFakeService(chats: [first, second],
        selected: .init(teammate: first.teammate, conversation: first.conversation), messages: [first.id: [oldLocal]])
    let live = WorkspaceTextReplyTestService(store: store)
    let drafts = WorkspaceAttachmentTextDraftStore()
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0, draftService: drafts)
    try await model.loadInitialWorkspace()
    #expect(await live.submissions.isEmpty)
    #expect(model.conversation.messages.first?.deliveryNotice == "Saved locally · not sent to Claude")
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed }
    model.conversation.composerText = "Only this new text"
    let userID = UUID()
    model.conversation.sendCurrentText(messageID: userID)
    #expect(model.conversation.textReplyPhase == .sending)
    #expect(!model.conversation.canSend)
    try await waitWorkspaceAttachment { await live.waiting }
    defer { Task { await live.release(.stopped) } }
    // A saved partial is a checkpoint, never painted (committed bubbles only).
    #expect(model.conversation.messages.last?.isFromUser == true)
    #expect(model.conversation.messages.last?.body == "Only this new text")
    model.conversation.composerText = "Newer draft must survive"
    try await select(second, in: model)
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed }
    model.conversation.composerText = "Second bot draft"
    await live.release(.failed(.runtimeUnavailable))
    try await waitWorkspaceAttachment { !model.conversation.hasPendingSubmissions }
    #expect(model.conversation.conversationID == second.id.rawValue)
    #expect(model.conversation.composerText == "Second bot draft")
    #expect(!model.conversation.messages.contains { $0.id == userID })
    let submitted = try #require(await live.submissions.first)
    #expect(submitted.conversationID == first.id && submitted.teammateID == first.teammate.id)
    #expect(submitted.userMessageID == MessageID(userID) && submitted.text == "Only this new text")
    #expect(submitted.attachmentIDs.isEmpty)
    try await select(first, in: model)
    #expect(model.conversation.composerText == "Newer draft must survive")
    #expect(model.conversation.messages.filter { $0.id == userID }.count == 1)
    #expect(model.conversation.messages.first(where: { $0.id == oldLocal.id.rawValue })?.deliveryNotice == "Saved locally · not sent to Claude")
    #expect(model.conversation.messages.first(where: { $0.id == userID })?.deliveryNotice == "Accepted by Claude")
    #expect(model.conversation.messages.last?.deliveryNotice == "Claude turn failed · available reply text saved")
    #expect(model.conversation.textReplyPhase == .failed(.runtimeUnavailable))
    #expect(await live.submissions.count == 1)

    let reopened = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await reopened.loadInitialWorkspace()
    #expect(reopened.conversation.messages.first(where: { $0.id == oldLocal.id.rawValue })?.deliveryNotice == "Saved locally · not sent to Claude")
    #expect(reopened.conversation.messages.last?.deliveryNotice == "Claude turn failed · available reply text saved")
    #expect(await live.submissions.count == 1, "Reopening must never replay history")
}

@Test("Stop stays stopping until the owned text transport returns after cleanup")
@MainActor
func durableWorkspaceTextReplyStopWaitsForCleanup() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "a3", name: "Text Stop", seed: 403)
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "Stop this turn"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waiting }
    defer { Task { await live.release(.stopped) } }
    model.conversation.composerText = "Keep my next draft"
    model.conversation.stopCurrentTextReply()
    #expect(model.conversation.textReplyPhase == .stopping)
    #expect(model.conversation.hasPendingSubmissions)
    try await waitWorkspaceAttachment { await live.cancellationObserved }
    #expect(model.conversation.textReplyPhase == .stopping)
    await live.release(.completed)
    try await waitWorkspaceAttachment { !model.conversation.hasPendingSubmissions }
    #expect(model.conversation.textReplyPhase == .stopped)
    #expect(model.conversation.composerText == "Keep my next draft")
    #expect(model.conversation.messages.last?.body == "Actual injected provider text")
    #expect(model.conversation.messages.last?.deliveryNotice == "Claude turn stopped · available reply text saved")
    #expect(model.sidebar.rows.first?.activity == .idle)
    #expect(await live.submissions.count == 1)
}

@Test("Silent autosave retains an unsent text and attachment draft across reopening without a local-save action")
@MainActor
func durableWorkspaceTextReplySilentlyAutosavesAttachmentDraft() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "a9", name: "Silent Draft", seed: 409)
    let asset = try workspaceDurableAttachment(chat.id, suffix: 499)
    let attachments = WorkspaceDurableAttachmentStore(assets: [asset])
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation), attachmentStore: attachments)
    let drafts = WorkspaceAttachmentTextDraftStore()
    let live = WorkspaceTextReplyTestService(store: store)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0,
        draftService: drafts, attachmentDraftFactory: workspaceDurableAttachmentFactory(attachments))
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed && model.attachmentDraft.rows.count == 1 }
    let text = "  Unsent text and local attachment\n café  "
    model.conversation.composerText = text
    try await waitWorkspaceAttachment {
        guard await drafts.load(conversationID: chat.id)?.text == text else { return false }
        return model.draftCoordinator?.activeDraft?.status == .saved
    }
    #expect(model.draftCoordinator?.activeDraft?.status == .saved)
    #expect(!model.conversation.canSend)
    #expect(model.attachmentDraft.rows.count == 1)
    #expect(await live.submissions.isEmpty)
    #expect(await store.recordedLocalTargets().isEmpty)
    model.finishShutdown()

    let reopened = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0,
        draftService: drafts, attachmentDraftFactory: workspaceDurableAttachmentFactory(attachments))
    defer { reopened.finishShutdown() }
    try await reopened.loadInitialWorkspace()
    try await waitWorkspaceAttachment { reopened.draftCoordinator?.activeDraft?.status == .saved && reopened.attachmentDraft.rows.count == 1 }
    #expect(reopened.conversation.composerText == text)
    #expect(reopened.conversation.messages.isEmpty)
    #expect(!reopened.conversation.canSend)
    #expect(await live.submissions.isEmpty)
    #expect(await store.recordedLocalTargets().isEmpty)
}

@Test("The retained internal local persistence API can still save attachment messages without Claude")
@MainActor
func durableWorkspaceTextReplyAttachmentsRemainLocal() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "a4", name: "Text Files", seed: 404)
    let asset = try workspaceDurableAttachment(chat.id, suffix: 491)
    let attachments = WorkspaceDurableAttachmentStore(assets: [asset])
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation), attachmentStore: attachments)
    let live = WorkspaceTextReplyTestService(store: store)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0,
        draftService: WorkspaceAttachmentTextDraftStore(), attachmentDraftFactory: workspaceDurableAttachmentFactory(attachments))
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.canSaveLocally }
    model.conversation.composerText = "Text with local file"
    #expect(!model.conversation.canSend)
    model.conversation.sendCurrentText()
    #expect(model.conversation.composerText == "Text with local file")
    #expect(model.attachmentDraft.rows.count == 1)
    #expect(await live.submissions.isEmpty)
    model.conversation.saveCurrentTextLocally()
    try await waitWorkspaceAttachment { !model.conversation.hasPendingSubmissions && model.attachmentDraft.rows.isEmpty }
    #expect(await live.submissions.isEmpty)
    #expect(await store.recordedLocalTargets().first?.4 == [asset.id])
    #expect(model.conversation.messages.last?.deliveryNotice == "Saved locally · not sent to Claude")
}

@Test("Rejected text admission restores the captured draft without inventing an assistant reply")
@MainActor
func durableWorkspaceTextReplyRejectedBeforeSavePreservesDraft() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "a5", name: "Text Rejected", seed: 405)
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, rejection: .subscriptionNotVerified)
    let drafts = WorkspaceAttachmentTextDraftStore()
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0, draftService: drafts)
    try await model.loadInitialWorkspace()
    try await waitWorkspaceAttachment { model.conversation.draftSubmissionAllowed }
    model.conversation.composerText = "  Preserve exactly  "
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .failed(.subscriptionNotVerified) }
    #expect(model.conversation.composerText == "  Preserve exactly  ")
    #expect(model.conversation.messages.allSatisfy { $0.isFromUser })
    #expect(await live.submissions.count == 1)
    #expect(await store.recordedLocalTargets().isEmpty)
}

@Test("An older page provenance success or failure cannot replace a newer completed turn", arguments: [false, true])
@MainActor
func durableWorkspaceTextReplyFencesOldProvenanceLookup(oldLookupFails: Bool) async throws {
    let (chat, oldLocal) = try durableWorkspaceFixture(suffix: "a6", name: "Provenance Race", seed: 406)
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation), messages: [chat.id: [oldLocal]])
    let live = WorkspaceTextReplyTestService(store: store)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "Complete this exact new turn"
    let userID = UUID()
    model.conversation.sendCurrentText(messageID: userID)
    try await waitWorkspaceAttachment { await live.waiting }
    defer { Task { await live.release(.stopped); await live.releaseProvenance() } }
    await live.delayNextProvenance(fails: oldLookupFails)
    let oldPage = Task { try await model.loadInitialWorkspace() }
    try await waitWorkspaceAttachment { await live.provenanceWaiting }
    await live.release(.completed)
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
    #expect(model.conversation.messages.first(where: { $0.id == userID })?.deliveryNotice == "Accepted by Claude")
    #expect(model.conversation.messages.last?.deliveryNotice == "Claude reply saved")

    await live.releaseProvenance()
    try await oldPage.value
    #expect(model.conversation.messages.first(where: { $0.id == userID })?.deliveryNotice == "Accepted by Claude")
    #expect(model.conversation.messages.last?.deliveryNotice == "Claude reply saved")
    #expect(model.conversation.textReplyPhase == .completed)
    #expect(await live.submissions.count == 1)
}

@MainActor
@Test("Production projects a pending Claude status as OpenBots, and the root hides only its transport caption")
func durableWorkspaceProjectedPendingStatusUsesAvatarFeedback() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "f4", name: "Waiting Avatar", seed: 444)
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, pendingStatusReply: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    model.conversation.composerText = "Check the notes"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waiting }
    // This is the actual private presentedMessage result from the workspace's
    // live progress path, not a manually authored teammate UI snapshot.
    let projected = try #require(model.conversation.messages.last)
    #expect(projected.author == .system(label: "OpenBots"))
    #expect(projected.delivery == .pending && projected.streamState == .notStreaming)
    #expect(projected.body == "Waiting for Claude's reply.")
    #expect(NormalBusyFeedbackPolicy.hidesPlaceholder(projected))
    #expect(model.sidebar.rows.first?.activity == .thinkingOrWorking)
    #expect(model.conversation.textReplyPhase?.isBusy == true)
    #expect(model.conversation.messages.contains { $0.id == projected.id && $0.body == projected.body },
            "The work record is retained; only normal transcript feedback is hidden")
    await live.release(.stopped)
    try await waitWorkspaceAttachment { !model.conversation.hasPendingSubmissions }
}

@Test("A persisted status-only failure is OpenBots status, never a streamed Claude reply")
@MainActor
func durableWorkspaceTextReplyDoesNotStreamStatusOnlyFailure() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "a7", name: "No Provider Text", seed: 407)
    let store = DurableWorkspaceFakeService(chats: [chat], selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, statusOnlyReply: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "No fabricated reply"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waiting }
    defer { Task { await live.release(.stopped) } }
    let status = try #require(model.conversation.messages.last)
    #expect(status.author == .system(label: "OpenBots"))
    #expect(status.streamState == .notStreaming)
    #expect(status.deliveryNotice == "OpenBots status · no Claude reply received")
    #expect(status.body == "Claude could not produce a reply.")
    #expect(!NormalBusyFeedbackPolicy.hidesPlaceholder(status), "The production-projected failure stays visible")
    #expect(model.sidebar.rows.first?.activity == .thinkingOrWorking,
            "A status-only record must not make the character speak")
    await live.release(.failed(.runtimeUnavailable))
    try await waitWorkspaceAttachment { !model.conversation.hasPendingSubmissions }
    #expect(model.conversation.messages.last?.author == .system(label: "OpenBots"))
    #expect(model.conversation.messages.last?.streamState == .notStreaming)
    #expect(model.conversation.messages.last?.deliveryNotice == "OpenBots status · no Claude reply received")
    #expect(model.sidebar.rows.first?.activity == .errorOrAttention)
    let reopened = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await reopened.loadInitialWorkspace()
    #expect(reopened.conversation.messages.last?.author == .system(label: "OpenBots"))
    #expect(reopened.conversation.messages.last?.deliveryNotice == "OpenBots status · no Claude reply received")
    #expect(await live.submissions.count == 1)
}

// A correction used to read as though the person had pressed Stop ("Stopping
// and saving available text…"). Now it says
// the note was picked up and finished work is kept; in a team, that the other
// bots stop here. A real Stop still reads as a Stop.
@Test("A correction says it was picked up, not stopped; a team correction says the other bots stop here")
func aCorrectionSaysItWasPickedUpNotStopped() {
    #expect(ClaudeTextReplyPhase.correcting(team: false).description == "Got your note. Finished work is kept and the bot starts again with it.")
    #expect(ClaudeTextReplyPhase.correcting(team: true).description == "Got your note. The other bots stop here and their finished work is kept.")
    #expect(ClaudeTextReplyPhase.stopping.description == "Stopping and saving available text…")
    #expect(ClaudeTextReplyPhase.correcting(team: false).isBusy && ClaudeTextReplyPhase.correcting(team: true).isBusy)
    #expect(NormalBusyFeedbackPolicy.showsCaption(for: .correcting(team: false)))
    #expect(NormalBusyFeedbackPolicy.showsCaption(for: .correcting(team: true)))
}

/// A refused wire used to read "Claude's response could not be verified", which
/// once hid a Claude Code update behind a sentence about the
/// app. The person reads which version sent what the app refused.
@Test("A refused wire names the Claude Code version and the code; without a frame the old sentence stands")
func refusedWireReadsAsClaudeCodeSayingSomethingNew() {
    let frame = ClaudeTextRefusedFrame(code: .initializationPermissionMismatch, claudeCodeVersion: "2.1.272")
    #expect(ClaudeTextReplyPhase.failed(.invalidResponse, refusedFrame: frame).description ==
        "OpenBots stopped this reply: Claude Code 2.1.272 sent something OpenBots does not understand (initializationPermissionMismatch). Nothing was resent; your text is kept.")
    let unnamed = ClaudeTextRefusedFrame(code: .responseMismatch, claudeCodeVersion: nil)
    #expect(ClaudeTextReplyPhase.failed(.invalidResponse, refusedFrame: unnamed).description ==
        "OpenBots stopped this reply: Claude Code sent something OpenBots does not understand (responseMismatch). Nothing was resent; your text is kept.")
    #expect(ClaudeTextReplyPhase.failed(.invalidResponse).description ==
        "Claude’s response could not be verified. Saved text is kept; no retry will run automatically.")
    #expect(ClaudeTextReplyPhase.explanation(.sessionLost) ==
        "The bot’s saved session could not be continued, so this message was not answered. Send it again and the bot starts fresh.")
    // A frame on any other problem changes nothing: the code belongs to the wire.
    #expect(ClaudeTextReplyPhase.failed(.timedOut, refusedFrame: frame).description == ClaudeTextReplyPhase.explanation(.timedOut))
}

/// A turn the model had declined was once reported
/// to the person as "Claude's response could not be verified", which sent them
/// hunting a fault that was never there. Declining is the bot's own call about
/// one turn, and the two places the person reads say so.
@Test("A declined turn reads as the bot declining, and a decline over text already said leaves that text alone")
@MainActor
func declinedTurnReadsAsTheBotDeclining() async throws {
    #expect(ClaudeTextReplyPhase.explanation(.declined) ==
        "The bot decided not to answer this one. Nothing went wrong, your text is kept and nothing will be resent.")

    // It said nothing before deciding: the row carries a status alone, and the
    // notice over it names the decision instead of a missing reply.
    let (silent, _) = try durableWorkspaceFixture(suffix: "c1", name: "Declined Silent", seed: 471)
    let (elsewhere, _) = try durableWorkspaceFixture(suffix: "c3", name: "Somewhere Else", seed: 473)
    let silentStore = DurableWorkspaceFakeService(chats: [silent, elsewhere],
        selected: .init(teammate: silent.teammate, conversation: silent.conversation))
    let silentLive = WorkspaceTextReplyTestService(store: silentStore, statusOnlyReply: true)
    let silentModel = DurableWorkspaceModel(service: silentStore, textReplyService: silentLive,
                                            hiringService: try durableHiringFixture().0)
    try await silentModel.loadInitialWorkspace()
    silentModel.conversation.composerText = "Something it will not answer"
    silentModel.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await silentLive.waiting }
    await silentLive.release(.failed(.declined))
    try await waitWorkspaceAttachment { !silentModel.conversation.hasPendingSubmissions }
    #expect(silentModel.conversation.messages.last?.author == .system(label: "OpenBots"))
    #expect(silentModel.conversation.messages.last?.deliveryNotice == "OpenBots status · the bot declined this one")
    #expect(silentModel.conversation.textReplyPhase == .failed(.declined))

    // Navigating away and back reloads provenance over the same row. The
    // decision has to survive that pass, not only the first paint.
    try await select(elsewhere, in: silentModel)
    try await select(silent, in: silentModel)
    try await waitWorkspaceAttachment {
        silentModel.conversation.messages.last?.deliveryNotice == "OpenBots status · the bot declined this one"
    }

    // Reopened from the saved record, with no live turn and no phase behind it:
    // the decision has to come off disk, or the person reads a failure again.
    let reopened = DurableWorkspaceModel(service: silentStore, textReplyService: silentLive,
                                         hiringService: try durableHiringFixture().0)
    try await reopened.loadInitialWorkspace()
    try await waitWorkspaceAttachment {
        reopened.conversation.messages.last?.deliveryNotice == "OpenBots status · the bot declined this one"
    }
    #expect(reopened.conversation.messages.last?.author == .system(label: "OpenBots"))
    #expect(reopened.conversation.textReplyPhase == nil)

    // It had already said something. That text is the bot's own bubble, and a
    // decline leaves it exactly where a stop would: no relabel over it.
    let (spoken, _) = try durableWorkspaceFixture(suffix: "c2", name: "Declined Partial", seed: 472)
    let spokenStore = DurableWorkspaceFakeService(chats: [spoken],
        selected: .init(teammate: spoken.teammate, conversation: spoken.conversation))
    let spokenLive = WorkspaceTextReplyTestService(store: spokenStore)
    let spokenModel = DurableWorkspaceModel(service: spokenStore, textReplyService: spokenLive,
                                            hiringService: try durableHiringFixture().0)
    try await spokenModel.loadInitialWorkspace()
    spokenModel.conversation.composerText = "It starts and then stops"
    spokenModel.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await spokenLive.waiting }
    await spokenLive.release(.failed(.declined))
    try await waitWorkspaceAttachment { !spokenModel.conversation.hasPendingSubmissions }
    let kept = try #require(spokenModel.conversation.messages.last)
    #expect(kept.body == "Actual injected provider text")
    #expect(kept.author != .system(label: "OpenBots"))
    #expect(kept.deliveryNotice == "The bot declined this one · available reply text saved")
}

@Test("Bot-to-bot traffic is not a transcript row: a work-channel message is on the record, not in the room")
@MainActor
func durableWorkspaceHidesWorkChannelMessages() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "e2", name: "Record", seed: 432)
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let at = Date(timeIntervalSince1970: 30_000)
    let brief = try Message(id: MessageID(UUID()), conversationID: chat.conversation.id, sequence: 1,
        author: .teammate(chat.teammate.id), outputClass: .workAudit, deliveryState: .completed,
        parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Handoff from Record to Ada."))],
        createdAt: at, updatedAt: at)
    let answer = try Message(id: MessageID(UUID()), conversationID: chat.conversation.id, sequence: 2,
        author: .teammate(chat.teammate.id), deliveryState: .completed,
        parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Here is the answer."))],
        createdAt: at, updatedAt: at)
    await store.storeActualReplyForTest(brief)
    await store.storeActualReplyForTest(answer)
    let model = DurableWorkspaceModel(service: store, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    #expect(model.conversation.messages.map(\.body) == ["Here is the answer."])
    #expect(model.handoffCards.isEmpty && !model.canShowWorkRecord)
}

@Test("Send stays live while a card waits, with the draft store in the loop, and the correction goes out")
@MainActor
func durableWorkspaceSendStaysLiveWhileACardWaits() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "e3", name: "Card", seed: 433)
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, cardWhileWaiting: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0,
        draftService: WorkspaceAttachmentTextDraftStore())
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    func wait(_ step: String, _ predicate: @MainActor () async -> Bool) async {
        do { try await waitWorkspaceAttachment(predicate) } catch { Issue.record("timed out: \(step)") }
    }
    model.conversation.composerText = "Move a.txt into the archive"
    await wait("draft loaded") { model.conversation.canSend }
    model.conversation.sendCurrentText()
    await wait("first turn waiting") { await live.waiting }
    await wait("card shown") { model.conversation.textReplyApproval != nil }
    #expect(model.conversation.textReplyPhase?.isBusy == true)
    model.conversation.composerText = "Wait, call it ideas.txt instead"
    await wait("draft settled") { model.conversation.canSend }
    #expect(model.conversation.canSend, "a waiting card never locks Send: typing is the correction")
    model.conversation.sendCurrentText()
    #expect(model.conversation.textReplyPhase == .correcting(team: false), "a correction reads as a correction, not a Stop")
    await wait("first turn cancelled") { await live.cancellationObserved }
    await live.release(.stopped)
    await wait("correction submitted") { await live.submissions.count == 2 }
    await wait("correction waiting") { await live.waiting }
    let submissions = await live.submissions
    #expect(submissions.count == 2 && submissions.last?.text == "Wait, call it ideas.txt instead" && submissions.last?.correctsRunningTurn == true)
    await live.release(.completed)
    await wait("correction completed") { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
}

@Test("A second correction while the corrected turn's card waits goes out after that turn settles, Stop still reaches the last turn, and every finished reply is kept")
@MainActor
func durableWorkspaceSecondCorrectionWhileACardWaits() async throws {
    // A live bug: the second correction was refused as
    // busy and Stop disappeared while the corrected run lived on.
    let (chat, _) = try durableWorkspaceFixture(suffix: "e5", name: "Twice", seed: 435)
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store, cardWhileWaiting: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0,
        draftService: WorkspaceAttachmentTextDraftStore())
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    func wait(_ step: String, _ predicate: @MainActor () async -> Bool) async {
        do { try await waitWorkspaceAttachment(predicate) } catch { Issue.record("timed out: \(step)") }
    }
    func type(_ text: String) async {
        model.conversation.composerText = text
        await wait("draft settled for \(text)") { model.conversation.canSend }
        model.conversation.sendCurrentText()
    }
    await type("Text him hello")
    await wait("first card shown") {
        let waiting = await live.waiting
        return waiting && model.conversation.textReplyApproval != nil
    }
    await type("I said good night, not hello")
    await wait("first turn cancelled") { await live.cancellationObserved }
    await live.release(.stopped)
    await wait("corrected turn's card shown") {
        let count = await live.submissions.count, waiting = await live.waiting
        return count == 2 && waiting && model.conversation.textReplyApproval != nil
    }

    await type("And sign it from me")
    #expect(model.conversation.textReplyPhase == .correcting(team: false), "the second correction is taken, not refused")
    #expect(model.conversation.lastSubmissionRefusal == nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await live.submissions.count == 2, "it waits for the corrected turn instead of reaching a bot still running")
    #expect(model.conversation.textReplyPhase?.isBusy == true, "Stop stays offered while the corrected turn settles")

    await live.release(.stopped)
    await wait("second correction submitted") {
        let count = await live.submissions.count, waiting = await live.waiting
        return count == 3 && waiting
    }
    let submissions = await live.submissions
    #expect(submissions.map(\.correctsRunningTurn) == [false, true, true])
    #expect(submissions.last?.text == "And sign it from me")

    // What the user reached for when the card expired: Stop, on the latest turn.
    // The stopped turn's late end used to erase this turn's task, so Stop
    // cancelled nothing.
    model.conversation.stopCurrentTextReply()
    #expect(model.conversation.textReplyPhase == .stopping)
    await wait("Stop reaches the last turn") { await live.cancellations == 3 }
    await live.release(.stopped)
    await wait("the last turn stopped") {
        model.conversation.textReplyPhase == .stopped && !model.conversation.hasPendingSubmissions
    }
    #expect(model.conversation.messages.filter(\.isFromUser).map(\.body)
            == ["Text him hello", "I said good night, not hello", "And sign it from me"])
    #expect(model.conversation.messages.filter { !$0.isFromUser }.count == 3, "each turn's finished reply is kept")
}

@Test("Composed as the app is, with the attachment draft in the loop, Send stays live while a card waits and the correction goes out")
@MainActor
func durableWorkspaceSendStaysLiveWhileACardWaitsWithAttachmentDraft() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "e4", name: "Card Files", seed: 434)
    let attachments = WorkspaceDurableAttachmentStore(assets: [])
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation), attachmentStore: attachments)
    let live = WorkspaceTextReplyTestService(store: store, cardWhileWaiting: true)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0,
        draftService: WorkspaceAttachmentTextDraftStore(), attachmentDraftFactory: workspaceDurableAttachmentFactory(attachments))
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    func wait(_ step: String, _ predicate: @MainActor () async -> Bool) async {
        do { try await waitWorkspaceAttachment(predicate) } catch { Issue.record("timed out: \(step)") }
    }
    model.conversation.composerText = "Create notes.txt in your Outbox"
    await wait("drafts loaded") { model.conversation.canSend }
    model.conversation.sendCurrentText()
    await wait("first turn waiting") { await live.waiting }
    await wait("card shown") { model.conversation.textReplyApproval != nil }
    #expect(model.conversation.textReplyPhase?.isBusy == true)
    model.conversation.composerText = "Wait, make it a folder called Ideas instead"
    await wait("draft settled") { model.conversation.canSend }
    #expect(model.conversation.attachmentSubmissionAllowed,
            "an empty attachment draft must not hold Send for the whole turn once the message is saved")
    #expect(model.conversation.canSend, "a waiting card never locks Send: typing is the correction")
    model.conversation.sendCurrentText()
    #expect(model.conversation.textReplyPhase == .correcting(team: false), "the correction stops the running turn and says so as a correction")
    await wait("first turn cancelled") { await live.cancellationObserved }
    await live.release(.stopped)
    await wait("correction submitted") { await live.submissions.count == 2 }
    await wait("correction waiting") { await live.waiting }
    let submissions = await live.submissions
    #expect(submissions.count == 2 && submissions.last?.text == "Wait, make it a folder called Ideas instead"
            && submissions.last?.correctsRunningTurn == true)
    await live.release(.completed)
    await wait("correction completed") { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
    #expect(model.conversation.messages.filter(\.isFromUser).map(\.body)
            == ["Create notes.txt in your Outbox", "Wait, make it a folder called Ideas instead"])
}

@Test("Typing while the bot works stops the running turn and restarts with the correction; Send never locks")
@MainActor
func durableWorkspaceSendWhileBusySteers() async throws {
    let (chat, _) = try durableWorkspaceFixture(suffix: "d1", name: "Steering", seed: 431)
    let store = DurableWorkspaceFakeService(chats: [chat],
        selected: .init(teammate: chat.teammate, conversation: chat.conversation))
    let live = WorkspaceTextReplyTestService(store: store)
    let model = DurableWorkspaceModel(service: store, textReplyService: live, hiringService: try durableHiringFixture().0)
    try await model.loadInitialWorkspace()
    defer { Task { await live.releaseForCleanup() } }
    model.conversation.composerText = "Sort the invoices by month"
    model.conversation.sendCurrentText()
    try await waitWorkspaceAttachment { await live.waiting }
    #expect(model.conversation.textReplyPhase?.isBusy == true)
    #expect(model.conversation.canSend == false, "an empty composer has nothing to send")
    model.conversation.composerText = "Actually only the unpaid ones"
    #expect(model.conversation.canSend, "Send stays live while the bot works")
    model.conversation.sendCurrentText()
    #expect(model.conversation.textReplyPhase == .correcting(team: false), "a correction reads as a correction, not a Stop")
    try await waitWorkspaceAttachment { await live.cancellationObserved }
    await live.release(.stopped)
    try await waitWorkspaceAttachment { await live.submissions.count == 2 }
    try await waitWorkspaceAttachment { await live.waiting }
    let submissions = await live.submissions
    #expect(submissions[0].correctsRunningTurn == false)
    #expect(submissions[1].text == "Actually only the unpaid ones" && submissions[1].correctsRunningTurn)
    #expect(model.conversation.textReplyPhase == .responding)
    #expect(model.conversation.messages.filter(\.isFromUser).map(\.body) == ["Sort the invoices by month", "Actually only the unpaid ones"])
    await live.release(.completed)
    try await waitWorkspaceAttachment { model.conversation.textReplyPhase == .completed && !model.conversation.hasPendingSubmissions }
    #expect(await live.submissions.count == 2)
}

// MARK: - New Bot: a bot is born, asks what it is for, and sets itself up

@MainActor
@Test("New Bot makes exactly one bot at once, under a free placeholder name, selected and opened on its one question")
func durableWorkspaceNewBotAsksWhatItIsFor() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "81", name: "New Bot", seed: 81)
    let service = DurableWorkspaceFakeService(chats: [ada],
        selected: DurableChatSelectionSnapshot(teammate: ada.teammate, conversation: ada.conversation),
        messages: [ada.id: [greetingA]])
    let model = DurableWorkspaceModel(service: service, hiringService: try durableHiringFixture(mode: .localOnly).0)
    defer { model.finishShutdown() }
    try await model.loadInitialWorkspace()
    model.conversation.composerText = "The first bot's unsent draft"

    model.beginTeammateCreation()
    #expect(model.isCreatingTeammate, "claimed at the press")
    model.beginTeammateCreation()
    #expect(model.hiringModel == nil, "no questionnaire")
    try await waitWorkspaceAttachment { !model.isCreatingTeammate }

    #expect(await service.selfSettingCount == 1, "a second press while the first is being made makes nothing")
    #expect(await service.selfSettingNames == ["New Bot 2"], "the placeholder no other bot carries")
    #expect(await service.createdDraft == nil)
    #expect(model.creationError == nil)
    let created = try #require(await service.activeDirectChats().first(where: { $0.teammate.profile.displayName == "New Bot 2" }))
    #expect(model.sidebar.rows.map(\.id) == [created.teammate.id.rawValue, ada.teammate.id.rawValue])
    #expect(model.sidebar.selection == created.teammate.id.rawValue)
    #expect(model.conversation.conversationID == created.conversation.id.rawValue)
    #expect(model.conversation.title == "New Bot 2")
    #expect(model.conversation.messages.map(\.body) == [BotSelfSetup.firstQuestion])
    #expect(model.conversation.messages.first?.isFromUser == false)
    #expect(model.conversation.inputAvailability == .ready)

    // The next New Bot is the next free name.
    model.beginTeammateCreation()
    try await waitWorkspaceAttachment { !model.isCreatingTeammate }
    #expect(await service.selfSettingNames == ["New Bot 2", "New Bot 3"])
}

/// Hidden bots keep their names: the database refuses a
/// name a hidden bot holds, so the model must not offer it.
private struct HiddenNamesNavigation: TeammateNavigating {
    let hidden: [Teammate]
    func setPinned(id: TeammateID, pinned: Bool, expectedProfileRevision: UInt64) async throws -> Teammate {
        throw TeammateNavigationError.notFound
    }
    func setHidden(id: TeammateID, hidden: Bool, expectedProfileRevision: UInt64) async throws -> Teammate {
        throw TeammateNavigationError.notFound
    }
    func hiddenTeammates() async throws -> [Teammate] { hidden }
}

@MainActor
@Test("New Bot skips a name a hidden bot holds, so a hidden New Bot never makes every press fail")
func durableWorkspaceNewBotSkipsHiddenNames() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "83", name: "New Bot", seed: 83)
    let (shy, _) = try durableWorkspaceFixture(suffix: "84", name: "New Bot 2", seed: 84)
    var shyBot = shy.teammate
    shyBot.isHidden = true
    let service = DurableWorkspaceFakeService(chats: [ada],
        selected: DurableChatSelectionSnapshot(teammate: ada.teammate, conversation: ada.conversation),
        messages: [ada.id: [greetingA]])
    let model = DurableWorkspaceModel(service: service, hiringService: try durableHiringFixture(mode: .localOnly).0,
                                      navigationService: HiddenNamesNavigation(hidden: [shyBot]))
    defer { model.finishShutdown() }
    try await model.loadInitialWorkspace()
    model.beginTeammateCreation()
    try await waitWorkspaceAttachment { !model.isCreatingTeammate }
    #expect(await service.selfSettingNames == ["New Bot 3"])
    #expect(model.creationError == nil)
}

@MainActor
@Test("A placeholder name taken while New Bot waits on a navigation in flight is refused before anything is saved, and said")
func durableWorkspaceNewBotRefusesNameTakenAfterPress() async throws {
    let (ada, greetingA) = try durableWorkspaceFixture(suffix: "87", name: "Ada", seed: 87)
    let (rook, greetingB) = try durableWorkspaceFixture(suffix: "88", name: "Rook", seed: 88)
    let navigation = WorkspaceAttachmentSendGate()
    let service = DurableWorkspaceFakeService(chats: [ada, rook],
        selected: DurableChatSelectionSnapshot(teammate: ada.teammate, conversation: ada.conversation),
        messages: [ada.id: [greetingA], rook.id: [greetingB]], selectionGate: navigation)
    let model = DurableWorkspaceModel(service: service, hiringService: try durableHiringFixture(mode: .localOnly).0)
    defer { model.finishShutdown() }
    try await model.loadInitialWorkspace()

    // A click on Rook is still being saved when New Bot is pressed.
    model.sidebar.selection = rook.teammate.id.rawValue
    try await waitWorkspaceAttachment { await navigation.started }
    model.beginTeammateCreation()
    #expect(model.isCreatingTeammate)
    // Meanwhile Ada is renamed "New Bot" elsewhere and the workspace hears of it.
    var renamed = ada.teammate
    renamed.profile = try ada.teammate.profile.revised(displayName: "New Bot")
    model.profileDidSave(renamed)
    await navigation.release()
    try await waitWorkspaceAttachment { !model.isCreatingTeammate }

    #expect(await service.selfSettingCount == 0, "a name taken after the press creates nothing")
    #expect(model.creationError == "Couldn’t create the bot. Your current chat and drafts are unchanged.")
    #expect(model.sidebar.rows.map(\.name).sorted() == ["New Bot", "Rook"])
    // Pressed again, the next free name.
    model.beginTeammateCreation()
    try await waitWorkspaceAttachment { !model.isCreatingTeammate }
    #expect(await service.selfSettingNames == ["New Bot 2"])
}
