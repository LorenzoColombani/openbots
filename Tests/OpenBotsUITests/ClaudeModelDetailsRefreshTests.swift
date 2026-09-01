import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsUI

/// Source-level observation regression through the normal synthetic send path.
/// This checks the parent publication that invalidates its Details snapshot.
/// Mounted/rendered verification is deferred; no window, Claude or user data is used.
@MainActor
final class ClaudeModelDetailsRefreshTests: XCTestCase {
    func testModelProgressPublishesWorkspaceWithoutOtherParentMutation() async throws {
        let chat = try modelDetailsChat()
        let reply = ModelDetailsControlledReplyService()
        let model = DurableWorkspaceModel(
            service: ModelDetailsChatService(chat: chat),
            textReplyService: reply,
            hiringService: ModelDetailsUnusedHiringService()
        )
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        model.showBotDetails()
        model.conversation.composerText = "Synthetic parent-publication check"
        model.conversation.sendCurrentText()

        for _ in 0..<150 {
            if await reply.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isWaiting = await reply.isWaiting
        XCTAssertTrue(isWaiting, "The injected service must receive the normal submission.")
        guard isWaiting else { return }

        // Let initial reservation, composer, row and activity work finish before
        // observing the parent. The service remains suspended for BOTH events,
        // so final-result cleanup cannot supply the missing notification.
        await Task.yield()
        let selection = model.sidebar.selection
        let conversationID = model.conversation.conversationID
        let rowIDs = model.conversation.messageRows.map(\.id)
        let draft = model.conversation.composerText
        let selectedProfile = model.selectedTeammate?.profile
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        let beforeObserved = publications
        await reply.emit(.modelObserved(requested: "sonnet", observed: "claude-sonnet-5"))
        XCTAssertGreaterThan(publications, beforeObserved,
                             "Startup model metadata must invalidate the workspace's Details snapshot.")
        assertUnchangedParentState(model, selection: selection, conversationID: conversationID,
                                   rowIDs: rowIDs, draft: draft)
        XCTAssertEqual(model.selectedTeammate?.profile, selectedProfile)

        let beforeConfirmed = publications
        await reply.emit(.modelConfirmed(requested: "sonnet", observed: "claude-opus-5"))
        XCTAssertGreaterThan(publications, beforeConfirmed,
                             "Saved result model metadata must independently invalidate the parent.")
        assertUnchangedParentState(model, selection: selection, conversationID: conversationID,
                                   rowIDs: rowIDs, draft: draft)
        XCTAssertEqual(model.selectedTeammate?.profile, selectedProfile)
        let stillWaiting = await reply.isWaiting
        XCTAssertTrue(stillWaiting, "No completion event may mask the missing model-progress publication.")

        observation.cancel()
        await reply.complete()
        for _ in 0..<150 {
            if !model.conversation.hasPendingSubmissions { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The completed synthetic submission did not settle within the bounded cleanup.")
    }

    private func assertUnchangedParentState(
        _ model: DurableWorkspaceModel, selection: UUID?, conversationID: UUID?,
        rowIDs: [UUID], draft: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(model.isBotDetailsPresented, file: file, line: line)
        XCTAssertNil(model.profileEditor, file: file, line: line)
        XCTAssertEqual(model.sidebar.selection, selection, file: file, line: line)
        XCTAssertEqual(model.conversation.conversationID, conversationID, file: file, line: line)
        XCTAssertEqual(model.conversation.messageRows.map(\.id), rowIDs, file: file, line: line)
        XCTAssertEqual(model.conversation.composerText, draft, file: file, line: line)
    }
}

private enum ModelDetailsHarnessError: Error {
    case unusedServiceMethod
}

private actor ModelDetailsControlledReplyService: ClaudeTextReplyServing {
    private var progress: (@Sendable (ClaudeTextTurnProgress) async -> Void)?
    private var completion: CheckedContinuation<ClaudeTextTurnResult, Never>?
    var isWaiting: Bool { progress != nil && completion != nil }

    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        progress = onProgress
        return await withCheckedContinuation { completion = $0 }
    }

    func emit(_ event: ClaudeTextTurnProgress) async { await progress?(event) }

    func complete() {
        progress = nil
        let pending = completion
        completion = nil
        pending?.resume(returning: ClaudeTextTurnResult(outcome: .stopped))
    }

    func messageProvenance(conversationID: ConversationID,
                           messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}

private struct ModelDetailsChatService: DurableTeammateChatServing {
    let chat: DurableDirectChatSnapshot
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { [chat] }
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? {
        .init(teammate: chat.teammate, conversation: chat.conversation)
    }
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        throw ModelDetailsHarnessError.unusedServiceMethod
    }
    func clearSelection() async throws { throw ModelDetailsHarnessError.unusedServiceMethod }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft) async throws -> DurableTeammateChatCreationSnapshot {
        throw ModelDetailsHarnessError.unusedServiceMethod
    }
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        .init(conversationID: conversationID, messages: [], hasMore: false, nextBeforeSequence: nil)
    }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        throw ModelDetailsHarnessError.unusedServiceMethod
    }
}

private struct ModelDetailsUnusedHiringService: HiringConversationServing {
    func loadOrStart() async throws -> HiringConversationSnapshot { throw ModelDetailsHarnessError.unusedServiceMethod }
    func submit(text: String) async throws -> HiringConversationSnapshot { throw ModelDetailsHarnessError.unusedServiceMethod }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot {
        throw ModelDetailsHarnessError.unusedServiceMethod
    }
    func cancel() async throws { throw ModelDetailsHarnessError.unusedServiceMethod }
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot {
        throw ModelDetailsHarnessError.unusedServiceMethod
    }
}

private func modelDetailsChat() throws -> DurableDirectChatSnapshot {
    let date = Date(timeIntervalSince1970: 100)
    let teammate = try Teammate(
        id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Mounted Details QA", role: "Synthetic testing"),
        appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1,
            silhouette: "round", paletteToken: "sky", eyeDialect: "round", nonColorIdentityCue: "single crest",
            accessibleIdentityDescription: "Synthetic creature"),
        createdAt: date, updatedAt: date
    )
    let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id),
        title: teammate.profile.displayName, createdAt: date, updatedAt: date)
    return .init(teammate: teammate, conversation: conversation)
}
