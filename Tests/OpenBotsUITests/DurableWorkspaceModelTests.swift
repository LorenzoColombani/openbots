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
        attachmentSendOutcome: WorkspaceAttachmentSendOutcome = .success
    ) {
        self.chats = chats
        self.selected = selected
        self.messages = messages
        self.sendDelaysByText = sendDelaysByText
        self.pageDelaysByBeforeSequence = pageDelaysByBeforeSequence
        self.attachmentStore = attachmentStore
        self.attachmentSendGate = attachmentSendGate
        self.attachmentSendOutcome = attachmentSendOutcome
    }

    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { chats }

    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? { selected }

    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
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
    private let pausesBeforeReply: Bool
    private var firstReplyGate: CheckedContinuation<Void, Never>?
    private var cleanupOutcome: ClaudeTextTurnOutcome?
    private var progressCallback: (@Sendable (ClaudeTextTurnProgress) async -> Void)?
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

    init(store: DurableWorkspaceFakeService, rejection: ClaudeTextTurnProblem? = nil,
         statusOnlyReply: Bool = false, pausesBeforeReply: Bool = false) {
        self.store = store
        self.rejection = rejection
        self.statusOnlyReply = statusOnlyReply
        self.pausesBeforeReply = pausesBeforeReply
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
                sequence: user.sequence + 1, author: .teammate(submission.teammateID), deliveryState: statusOnlyReply ? .failed : .acknowledged,
                parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                    content: statusOnlyReply ? .status("Claude could not produce a reply.") : .text("Actual injected provider text"))],
                createdAt: Date(timeIntervalSince1970: 20_000), updatedAt: Date(timeIntervalSince1970: 20_000)
            )
            await store.storeActualReplyForTest(reply)
            let runID = RunID(UUID())
            records.append(.init(messageID: user.id, replyMessageID: reply.id, runID: runID, state: .running, inputState: .acknowledged))
            progressCallback = onProgress
            savedReplyForProgress = reply
            await onProgress(.assistantMessageSaved(reply))
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
            switch outcome {
            case .completed: state = .succeeded
            case .stopped: state = .interrupted
            case .failed: state = .failed
            }
            records.removeAll { $0.runID == runID }
            records.append(.init(messageID: user.id, replyMessageID: reply.id, runID: runID, state: state, inputState: .acknowledged))
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
        cleanupOutcome = .stopped
        releaseFirstReply()
        release(.stopped)
    }

    private func observeCancellation() { cancellationObserved = true }

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
                      runID: record.runID, state: .running, inputState: .submitted)
            }
        }
        return snapshot
    }
}

private enum WorkspaceProvenanceTestError: Error { case unavailable }

@Test("Real text activity stays working until public text, ignores repeated chunks and becomes idle after completion")
@MainActor
func durableWorkspaceTextReplyActivityRequiresPublicStreamingText() async throws {
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

    await live.releaseFirstReply()
    try await waitWorkspaceAttachment { await live.waiting }
    #expect(row.snapshot.activity == .speaking)
    #expect(model.conversation.messages.last?.body == "Actual injected provider text")
    #expect(model.conversation.messages.last?.streamState == .streaming)
    var repeatedActivityPublications = 0
    let observation = row.$snapshot.dropFirst().sink { _ in repeatedActivityPublications += 1 }
    defer { observation.cancel() }
    #expect(try await live.appendSavedReplyProgress())
    #expect(model.conversation.messages.last?.body == "Actual injected provider text with another chunk")
    #expect(row.snapshot.activity == .speaking)
    #expect(repeatedActivityPublications == 0, "An unchanged streaming state must not restart character motion")
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
    #expect(model.conversation.messages.last?.body == "Actual injected provider text")
    #expect(model.conversation.messages.last?.streamState == .streaming)
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
