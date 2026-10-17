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
        await reply.emit(.modelConfirmed(requested: "sonnet", observed: "claude-opus-5", claudeCodeVersion: "2.1.300"))
        XCTAssertGreaterThan(publications, beforeConfirmed,
                             "Saved result model metadata must independently invalidate the parent.")
        assertUnchangedParentState(model, selection: selection, conversationID: conversationID,
                                   rowIDs: rowIDs, draft: draft)
        XCTAssertEqual(model.selectedTeammate?.profile, selectedProfile)
        XCTAssertEqual(model.modelStatus(for: conversationID)?.claudeCodeVersion, "2.1.300")
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

extension ClaudeModelDetailsRefreshTests {
    /// After a relaunch the coordinator has no session observation; Details must
    /// still name the model the last saved reply reported, read back from the turn record.
    func testSavedResultIsReadBackIntoDetailsWhenTheConversationShows() async throws {
        let chat = try modelDetailsChat()
        let request = ClaudeExecutionRequest(sessionID: UUID(),
            selection: .init(model: "claude-opus-5", effort: "low", contextWindow: "standard"), launchModel: "claude-opus-5")
        let evidence = ClaudeExecutionEvidence(request: request, initializedModel: "claude-opus-5",
                                               resultModel: "claude-opus-5", claudeCodeVersion: "2.1.296")
        let reply = ModelDetailsSavedRecordReplyService(evidence: evidence)
        let model = DurableWorkspaceModel(
            service: ModelDetailsChatService(chat: chat),
            textReplyService: reply,
            hiringService: ModelDetailsUnusedHiringService()
        )
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        let conversationID = try XCTUnwrap(model.conversation.conversationID)
        var status: ClaudeModelRunPresentation?
        for _ in 0..<200 {
            status = model.modelStatus(for: conversationID)
            if status?.confirmedModel != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let read = try XCTUnwrap(status, "the saved record must reach Details")
        XCTAssertEqual(read.confirmedModel, "claude-opus-5")
        XCTAssertEqual(read.confirmedRequest, "claude-opus-5")
        XCTAssertEqual(read.confirmedEffort, "low")
        XCTAssertEqual(read.confirmedContextWindow, "standard")
        XCTAssertEqual(read.observedAtStart, "claude-opus-5")
        XCTAssertEqual(read.claudeCodeVersion, "2.1.296")
        XCTAssertTrue(read.isFromSavedRecord)
        let asked = await reply.conversationsAsked
        XCTAssertEqual(asked, [ConversationID(conversationID)])
    }

    func testSuccessfulReplyReplacesSavedCLIRevisionWithItsOwn() async throws {
        try await assertConfirmedVersionReplacesSavedVersion("2.1.300")
    }

    func testSuccessfulReplyWithoutCLIRevisionClearsSavedRevision() async throws {
        try await assertConfirmedVersionReplacesSavedVersion(nil)
    }

    private func assertConfirmedVersionReplacesSavedVersion(_ version: String?) async throws {
        let reply = ModelDetailsSavedRecordReplyService(evidence: modelDetailsSavedVersionEvidence())
        let coordinator = ClaudeTextReplyCoordinator(service: reply, changed: {})
        let submission = modelDetailsVersionSubmission(conversationID: UUID())
        let conversationID = submission.conversationID.rawValue
        await coordinator.loadSavedModelStatus(conversationID: conversationID)
        XCTAssertEqual(coordinator.modelPresentation(for: conversationID)?.claudeCodeVersion, "2.1.296")
        XCTAssertTrue(coordinator.reserve(conversationID: conversationID, messageID: submission.userMessageID.rawValue))
        _ = await coordinator.send(submission) { _ in }

        // A new startup observation cannot relabel the previous saved success.
        await reply.emit(.modelObserved(requested: "sonnet", observed: "claude-sonnet-5"), for: submission.userMessageID)
        let before = try XCTUnwrap(coordinator.modelPresentation(for: conversationID))
        XCTAssertEqual(before.confirmedModel, "claude-opus-5")
        XCTAssertEqual(before.claudeCodeVersion, "2.1.296")
        XCTAssertTrue(before.isFromSavedRecord)

        await reply.emit(.modelConfirmed(requested: "sonnet", observed: "claude-sonnet-5", claudeCodeVersion: version),
                         for: submission.userMessageID)
        let after = try XCTUnwrap(coordinator.modelPresentation(for: conversationID))
        XCTAssertEqual(after.confirmedModel, "claude-sonnet-5")
        XCTAssertEqual(after.claudeCodeVersion, version)
        XCTAssertFalse(after.isFromSavedRecord)
        coordinator.finish(conversationID: conversationID, messageID: submission.userMessageID.rawValue, outcome: .completed)
    }

    func testSupersededModelConfirmationCannotReplaceCurrentModelOrVersion() async throws {
        let reply = ModelDetailsSavedRecordReplyService(evidence: modelDetailsSavedVersionEvidence())
        let coordinator = ClaudeTextReplyCoordinator(service: reply, changed: {})
        let conversationID = UUID()
        await coordinator.loadSavedModelStatus(conversationID: conversationID)
        let previous = modelDetailsVersionSubmission(conversationID: conversationID)
        let current = modelDetailsVersionSubmission(conversationID: conversationID)
        XCTAssertTrue(coordinator.reserve(conversationID: conversationID, messageID: previous.userMessageID.rawValue))
        _ = await coordinator.send(previous) { _ in }
        XCTAssertTrue(coordinator.reserve(conversationID: conversationID, messageID: current.userMessageID.rawValue))
        XCTAssertTrue(coordinator.supersedesRunningTurn(conversationID: conversationID, messageID: current.userMessageID.rawValue))
        _ = await coordinator.send(current) { _ in }
        await reply.emit(.modelConfirmed(requested: "sonnet", observed: "claude-sonnet-5", claudeCodeVersion: "2.1.300"),
                         for: current.userMessageID)
        let confirmed = try XCTUnwrap(coordinator.modelPresentation(for: conversationID))
        XCTAssertEqual(confirmed.confirmedModel, "claude-sonnet-5")
        XCTAssertEqual(confirmed.claudeCodeVersion, "2.1.300")

        await reply.emit(.modelConfirmed(requested: "opus", observed: "claude-opus-5", claudeCodeVersion: "2.1.296"),
                         for: previous.userMessageID)
        XCTAssertEqual(coordinator.modelPresentation(for: conversationID), confirmed)
        coordinator.finish(conversationID: conversationID, messageID: current.userMessageID.rawValue, outcome: .completed)
    }
}

/// Saved evidence plus retained callbacks for deterministic late-progress checks.
private actor ModelDetailsSavedRecordReplyService: ClaudeTextReplyServing {
    let evidence: ClaudeExecutionEvidence
    private(set) var conversationsAsked: [ConversationID] = []
    private var progress: [MessageID: @Sendable (ClaudeTextTurnProgress) async -> Void] = [:]
    init(evidence: ClaudeExecutionEvidence) { self.evidence = evidence }
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        progress[submission.userMessageID] = onProgress
        return .init(outcome: .completed)
    }
    func emit(_ event: ClaudeTextTurnProgress, for messageID: MessageID) async { await progress[messageID]?(event) }
    func messageProvenance(conversationID: ConversationID,
                           messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
    func latestExecutionEvidence(conversationID: ConversationID) async throws -> ClaudeExecutionEvidence? {
        conversationsAsked.append(conversationID)
        return evidence
    }
}

private func modelDetailsSavedVersionEvidence() -> ClaudeExecutionEvidence {
    .init(request: .init(sessionID: UUID(), selection: .init(model: "claude-opus-5", effort: "low", contextWindow: "standard"),
                        launchModel: "claude-opus-5"),
          initializedModel: "claude-opus-5", resultModel: "claude-opus-5", claudeCodeVersion: "2.1.296")
}

private func modelDetailsVersionSubmission(conversationID: UUID) -> ClaudeTextTurnSubmission {
    .init(conversationID: ConversationID(conversationID), teammateID: TeammateID(UUID()),
          userMessageID: MessageID(UUID()), text: "Synthetic CLI version check")
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
