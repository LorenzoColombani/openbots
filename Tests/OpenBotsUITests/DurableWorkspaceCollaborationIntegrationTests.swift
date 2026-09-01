import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

private enum S3AIntegrationStubError: Error {
    case unavailable
}

private actor S3ADurableChatFake: DurableTeammateChatServing {
    private let chats: [DurableDirectChatSnapshot]
    private var selected: DurableChatSelectionSnapshot?
    private let messages: [ConversationID: [Message]]

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
        }) else { throw S3AIntegrationStubError.unavailable }
        selected = DurableChatSelectionSnapshot(
            teammate: chat.teammate,
            conversation: chat.conversation
        )
    }

    func clearSelection() async throws { selected = nil }

    func createTeammateAndDirectChat(
        _ draft: DurableTeammateDraft
    ) async throws -> DurableTeammateChatCreationSnapshot {
        throw S3AIntegrationStubError.unavailable
    }

    func loadMessages(
        conversationID: ConversationID,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> DurableMessagePageSnapshot {
        let filtered = (messages[conversationID] ?? []).filter { message in
            beforeSequence.map { message.sequence < $0 } ?? true
        }
        let page = Array(filtered.suffix(limit))
        return DurableMessagePageSnapshot(
            conversationID: conversationID,
            messages: page,
            hasMore: filtered.count > page.count,
            nextBeforeSequence: filtered.count > page.count ? page.first?.sequence : nil
        )
    }

    func sendMessageToLocalFixture(
        conversationID: ConversationID,
        teammateID: TeammateID,
        userMessageID: MessageID,
        text: String
    ) async throws -> DurableLocalFixtureExchangeSnapshot {
        throw S3AIntegrationStubError.unavailable
    }
}

private actor S3AHiringUnavailable: HiringConversationServing {
    private let initialSnapshot: HiringConversationSnapshot?

    init(initialSnapshot: HiringConversationSnapshot? = nil) {
        self.initialSnapshot = initialSnapshot
    }

    func loadOrStart() async throws -> HiringConversationSnapshot {
        if let initialSnapshot { return initialSnapshot }
        throw S3AIntegrationStubError.unavailable
    }
    func submit(text: String) async throws -> HiringConversationSnapshot {
        throw S3AIntegrationStubError.unavailable
    }
    func revise(
        field: HiringCandidateField,
        value: String
    ) async throws -> HiringConversationSnapshot {
        throw S3AIntegrationStubError.unavailable
    }
    func cancel() async throws {}
    func confirm(
        appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot {
        throw S3AIntegrationStubError.unavailable
    }
}

private actor S3BKnowledgeContextRecorder {
    private var values: [KnowledgeWorkspaceContext] = []

    func record(_ context: KnowledgeWorkspaceContext) {
        values.append(context)
    }

    func contexts() -> [KnowledgeWorkspaceContext] {
        values
    }
}

@MainActor
private func s3BKnowledgeModel(
    recorder: S3BKnowledgeContextRecorder
) -> KnowledgeWorkspaceModel {
    KnowledgeWorkspaceModel(
        loader: { context in
            await recorder.record(context)
            return KnowledgeWorkspaceSnapshot(
                id: UUID(),
                context: context,
                documents: []
            )
        },
        revealer: { _, _ in },
        chooseSnapshotDestination: { _ in nil },
        createSnapshot: { _, _ in
            KnowledgeSnapshotReceipt(
                exactDisplayPath: "/private/tmp/unreachable-s3b-snapshot.md",
                documentCount: 0,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        },
        releaseSnapshotDestination: { _ in }
    )
}

private func s3AChat(
    _ number: UInt8,
    teammate: Teammate,
    messageID: UUID = UUID()
) throws -> (DurableDirectChatSnapshot, Message) {
    let conversationUUID = UUID(
        uuidString: String(format: "a3300000-0000-0000-0000-%012d", number)
    )!
    let timestamp = Date(timeIntervalSince1970: 1_781_500_000 + Double(number))
    let conversation = try Conversation(
        id: ConversationID(conversationUUID),
        kind: .direct(teammateID: teammate.id),
        title: teammate.profile.displayName,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let message = try Message(
        id: MessageID(messageID),
        conversationID: conversation.id,
        sequence: 1,
        author: .teammate(teammate.id),
        deliveryState: .completed,
        parts: [
            try MessagePart(
                id: MessagePartID(UUID()),
                ordinal: 0,
                content: .text("Saved local greeting")
            )
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )
    return (DurableDirectChatSnapshot(teammate: teammate, conversation: conversation), message)
}

private func handoffTrail(
    in messages: [ChatMessageSnapshot]
) -> ChatHandoffTrailSnapshot? {
    for message in messages {
        for part in message.parts {
            if case .handoff(let trail) = part.content { return trail }
        }
    }
    return nil
}

@Test("Trust fixture follows the repository-resolved teammate and is unavailable while hiring")
@MainActor
func durableWorkspaceScopesTrustReviewAndClearsCandidateAuthority() async throws {
    let mira = try s3ATeammate(11, name: "Mira", role: "Research")
    let ada = try s3ATeammate(12, name: "Ada", role: "Review")
    let (miraChat, miraGreeting) = try s3AChat(11, teammate: mira)
    let (adaChat, adaGreeting) = try s3AChat(12, teammate: ada)
    let service = S3ADurableChatFake(
        chats: [miraChat, adaChat],
        selected: DurableChatSelectionSnapshot(teammate: mira, conversation: miraChat.conversation),
        messages: [miraChat.conversation.id: [miraGreeting], adaChat.conversation.id: [adaGreeting]]
    )
    var constructedContexts: [TrustFixtureContext] = []
    let trust = TrustAuthorizationWorkspaceModel(serviceFactory: { context in
        constructedContexts.append(context)
        return TrustAuthorizationFixtureService(context: context)
    })
    let draftDate = Date(timeIntervalSince1970: 1_780_000_000)
    let hiringDraft = try HiringDraft(
        id: HiringDraftID(UUID()), createdAt: draftDate, updatedAt: draftDate
    )
    let workspace = DurableWorkspaceModel(mode: .reviewFixture,
        service: service, hiringService: S3AHiringUnavailable(initialSnapshot: .init(
            persisted: try HiringDraftSnapshot(draft: hiringDraft, turns: []),
            focusedField: .displayName
        )),
        trustAuthorizationModel: trust
    )
    #expect(trust.context == nil)
    #expect(constructedContexts.isEmpty)
    try await workspace.loadInitialWorkspace()
    #expect(trust.context == TrustFixtureContext(
        teammateID: mira.id, conversationID: miraChat.conversation.id
    ))
    await trust.load()

    workspace.sidebar.selection = ada.id.rawValue
    for _ in 0..<200 where trust.context?.teammateID != ada.id {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(trust.context == TrustFixtureContext(
        teammateID: ada.id, conversationID: adaChat.conversation.id
    ))
    await trust.load()

    workspace.beginTeammateCreation()
    #expect(workspace.sidebar.selection == nil)
    #expect(trust.context == nil)
    let hiring = try #require(workspace.hiringModel)
    await hiring.load()
    #expect(await hiring.cancel())
    workspace.completeHiringCancellation(from: hiring)
    #expect(trust.context?.teammateID == ada.id)
    await trust.load()
    #expect(Set(constructedContexts) == [
        TrustFixtureContext(teammateID: mira.id, conversationID: miraChat.conversation.id),
        TrustFixtureContext(teammateID: ada.id, conversationID: adaChat.conversation.id)
    ])
    #expect(constructedContexts.count == 2)

    workspace.sidebar.selection = nil
    for _ in 0..<200 where trust.context != nil {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(trust.context == nil)
}

@Test("Durable workspace presents one scoped handoff row without persisting it")
@MainActor
func durableWorkspaceIntegratesCollaborationFixtureByConversation() async throws {
    let mira = try s3ATeammate(5, name: "Mira", role: "Research lead")
    let ada = try s3ATeammate(6, name: "Ada", role: "Source verifier")
    let (miraChat, miraGreeting) = try s3AChat(1, teammate: mira)
    let (adaChat, adaGreeting) = try s3AChat(2, teammate: ada)
    let chatService = S3ADurableChatFake(
        chats: [miraChat, adaChat],
        selected: DurableChatSelectionSnapshot(
            teammate: mira,
            conversation: miraChat.conversation
        ),
        messages: [
            miraChat.conversation.id: [miraGreeting],
            adaChat.conversation.id: [adaGreeting]
        ]
    )
    let directory = S3AProjectTeamDirectoryFake(
        teammates: [mira, ada],
        projects: [try s3AProject(3, name: "Atlas", members: [mira, ada])],
        teams: [try s3ATeam(2, name: "Research Studio", members: [mira, ada], lead: mira)]
    )
    let collaboration = CollaborationWorkspaceModel(
        directoryService: directory,
        reviewFixtureService: try CollaborationReviewFixtureService()
    )
    let workspace = DurableWorkspaceModel(mode: .reviewFixture,
        service: chatService,
        hiringService: S3AHiringUnavailable(),
        collaborationModel: collaboration
    )

    try await workspace.loadInitialWorkspace()

    #expect(collaboration.availableTeammates.map(\.id) == [ada.id.rawValue, mira.id.rawValue])
    #expect(collaboration.selectedProject?.name == "Atlas")
    #expect(collaboration.selectedTeam?.name == "Research Studio")
    #expect(workspace.conversation.messages.count == 2)
    #expect(handoffTrail(in: workspace.conversation.messages)?.state == .returnedToOrigin)
    let fixtureRow = try #require(
        workspace.conversation.messageRows.first(where: { row in
            row.snapshot.parts.contains(where: {
                if case .handoff = $0.content { return true }
                return false
            })
        })
    )

    collaboration.selectReviewVariant(.needsRecovery)

    #expect(workspace.conversation.messageRows.last === fixtureRow)
    #expect(handoffTrail(in: workspace.conversation.messages)?.state == .needsRecovery)
    #expect(workspace.conversation.messages.count == 2)

    workspace.sidebar.selection = ada.id.rawValue
    // Selection publishes the target identity and its fixture before the
    // asynchronous saved-message page arrives. An identity match alone is
    // therefore still the opening state, not a completed conversation load.
    for _ in 0..<200 where
        workspace.conversation.conversationID != adaChat.conversation.id.rawValue
            || workspace.conversation.inputAvailability != .ready
    {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(workspace.conversation.conversationID == adaChat.conversation.id.rawValue)
    try #require(workspace.conversation.inputAvailability == .ready)
    #expect(workspace.conversation.messages.contains { $0.id == adaGreeting.id.rawValue })
    #expect(workspace.conversation.messages.count == 2)
    #expect(handoffTrail(in: workspace.conversation.messages)?.state == .returnedToOrigin)

    workspace.sidebar.selection = mira.id.rawValue
    for _ in 0..<200 where
        workspace.conversation.conversationID != miraChat.conversation.id.rawValue
            || workspace.conversation.inputAvailability != .ready
    {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(workspace.conversation.conversationID == miraChat.conversation.id.rawValue)
    try #require(workspace.conversation.inputAvailability == .ready)
    #expect(workspace.conversation.messages.contains { $0.id == miraGreeting.id.rawValue })
    #expect(handoffTrail(in: workspace.conversation.messages)?.state == .needsRecovery)
    #expect(workspace.conversation.messages.count == 2)
}

@Test("Durable workspace keeps knowledge scope aligned with the exact teammate and project context")
@MainActor
func durableWorkspaceIntegratesKnowledgeContextByConversationAndProject() async throws {
    let mira = try s3ATeammate(8, name: "Mira", role: "Research lead")
    let ada = try s3ATeammate(9, name: "Ada", role: "Source verifier")
    let (miraChat, miraGreeting) = try s3AChat(4, teammate: mira)
    let (adaChat, adaGreeting) = try s3AChat(5, teammate: ada)
    let project = try s3AProject(4, name: "Atlas", members: [mira, ada])
    let chatService = S3ADurableChatFake(
        chats: [miraChat, adaChat],
        selected: DurableChatSelectionSnapshot(
            teammate: mira,
            conversation: miraChat.conversation
        ),
        messages: [
            miraChat.conversation.id: [miraGreeting],
            adaChat.conversation.id: [adaGreeting]
        ]
    )
    let collaboration = CollaborationWorkspaceModel(
        directoryService: S3AProjectTeamDirectoryFake(
            teammates: [mira, ada],
            projects: [project]
        ),
        reviewFixtureService: try CollaborationReviewFixtureService()
    )
    let recorder = S3BKnowledgeContextRecorder()
    let knowledge = s3BKnowledgeModel(recorder: recorder)
    let workspace = DurableWorkspaceModel(mode: .reviewFixture,
        service: chatService,
        hiringService: S3AHiringUnavailable(),
        collaborationModel: collaboration,
        knowledgeModel: knowledge
    )

    try await workspace.loadInitialWorkspace()
    for _ in 0..<200 where await recorder.contexts().isEmpty {
        try await Task.sleep(for: .milliseconds(2))
    }
    var context = try #require(await recorder.contexts().last)
    #expect(context.conversationID == miraChat.conversation.id.rawValue)
    #expect(context.teammateID == mira.id.rawValue)
    #expect(context.selectedProjectID == project.project.id.rawValue)
    #expect(context.activeProjectMembershipIDs == [project.project.id.rawValue])

    workspace.sidebar.selection = ada.id.rawValue
    for _ in 0..<200 where knowledge.context?.teammateID != ada.id.rawValue {
        try await Task.sleep(for: .milliseconds(2))
    }
    context = try #require(knowledge.context)
    #expect(context.conversationID == adaChat.conversation.id.rawValue)
    #expect(context.teammateID == ada.id.rawValue)
    #expect(context.activeProjectMembershipIDs == [project.project.id.rawValue])

    collaboration.selectProject(nil)
    for _ in 0..<200 where knowledge.context?.selectedProjectID != nil {
        try await Task.sleep(for: .milliseconds(2))
    }
    context = try #require(knowledge.context)
    #expect(context.teammateID == ada.id.rawValue)
    #expect(context.selectedProjectID == nil)
    #expect(context.activeProjectMembershipIDs.isEmpty)
}

@Test("Durable-message ID collision fails closed and variant changes do not append")
@MainActor
func durableWorkspaceRejectsCollaborationFixtureIDCollision() async throws {
    let teammate = try s3ATeammate(7, name: "Sol", role: "Operations")
    let conversationUUID = UUID(
        uuidString: "a3300000-0000-0000-0000-000000000003"
    )!
    let directory = S3AProjectTeamDirectoryFake(teammates: [teammate])
    let collaboration = CollaborationWorkspaceModel(
        directoryService: directory,
        reviewFixtureService: try CollaborationReviewFixtureService()
    )
    let collisionMessage = try #require(
        collaboration.conversationFixtureMessage(for: conversationUUID)
    )
    let (chat, durableCollision) = try s3AChat(
        3,
        teammate: teammate,
        messageID: collisionMessage.id
    )
    let chatService = S3ADurableChatFake(
        chats: [chat],
        selected: DurableChatSelectionSnapshot(
            teammate: teammate,
            conversation: chat.conversation
        ),
        messages: [chat.conversation.id: [durableCollision]]
    )
    let workspace = DurableWorkspaceModel(mode: .reviewFixture,
        service: chatService,
        hiringService: S3AHiringUnavailable(),
        collaborationModel: collaboration
    )

    try await workspace.loadInitialWorkspace()
    #expect(workspace.conversation.messages.count == 1)
    #expect(handoffTrail(in: workspace.conversation.messages) == nil)

    collaboration.selectReviewVariant(.needsRecovery)
    #expect(workspace.conversation.messages.count == 1)
    #expect(handoffTrail(in: workspace.conversation.messages) == nil)
}
