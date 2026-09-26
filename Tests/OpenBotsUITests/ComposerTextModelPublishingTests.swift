import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsUI

/// Typing must publish the composer and nothing else.
///
/// The composer's text used to be `@Published` on `ConversationModel`, which
/// the root view observes, so every character invalidated the whole window: the
/// sidebar, the header and each visible transcript row, and each of those rows
/// then re-measured its native label with a full AppKit text layout. These
/// tests pin the publish to the composer's own object and pin the passthrough
/// that keeps draft persistence, the send path and the quit guard unchanged.
@MainActor
final class ComposerTextModelPublishingTests: XCTestCase {
    func testTypingPublishesTheComposerAndNeverTheConversation() {
        let conversation = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        var conversationPublications = 0
        var composerPublications = 0
        var subscriptions: Set<AnyCancellable> = []
        conversation.objectWillChange
            .sink { _ in conversationPublications += 1 }
            .store(in: &subscriptions)
        conversation.composer.objectWillChange
            .sink { _ in composerPublications += 1 }
            .store(in: &subscriptions)

        // Exactly what the bound field does: one whole-string write per character.
        var typed = ""
        for character in "Twenty characters ok" {
            typed.append(character)
            conversation.composer.text = typed
        }
        XCTAssertEqual(typed.count, 20)

        XCTAssertEqual(composerPublications, 20, "Each keystroke must publish the composer's own object")
        XCTAssertEqual(
            conversationPublications, 0,
            "A keystroke must not publish the conversation: the root view observes it, so the sidebar, "
                + "the header and every visible transcript row would re-evaluate and re-measure per character"
        )
        XCTAssertEqual(conversation.composer.text, typed, "The writes must still land")
        XCTAssertEqual(conversation.composerText, typed, "The passthrough must report the typed text")
        subscriptions.removeAll()
    }

    func testComposerTextPassthroughCarriesExactBytesBothWays() {
        let conversation = ConversationModel(
            conversationID: UUID(), composerText: "Opening draft", submit: { _, _, _ in }
        )
        XCTAssertEqual(conversation.composer.text, "Opening draft", "The init argument must reach the composer object")
        XCTAssertEqual(conversation.composerText, "Opening draft")

        conversation.composerText = "Written through the conversation"
        XCTAssertEqual(conversation.composer.text, "Written through the conversation")

        conversation.composer.text = "Written through the composer"
        XCTAssertEqual(conversation.composerText, "Written through the composer")

        // Drafts are compared and stored by exact bytes, never a normalized copy.
        let raw = " \nCafe\u{301}\t "
        conversation.composer.text = raw
        XCTAssertTrue(conversation.composerText.utf8.elementsEqual(raw.utf8))
        conversation.composerText = raw + "!"
        XCTAssertTrue(conversation.composer.text.utf8.elementsEqual((raw + "!").utf8))
    }

    func testSendEnablementStillFollowsTheComposerText() {
        let conversation = ConversationModel(
            conversationID: UUID(), inputAvailability: .ready, submit: { _, _, _ in }
        )
        XCTAssertFalse(conversation.canSend)
        conversation.composer.text = "Ready"
        XCTAssertTrue(
            conversation.canSend,
            "The send button reads canSend from inside the composer subtree, which observes the composer object"
        )
        conversation.composer.text = "   "
        XCTAssertFalse(conversation.canSend, "Whitespace-only text must not enable Send")
    }

    func testSendingClearsBothViewsOfTheComposerText() {
        let conversation = ConversationModel(
            conversationID: UUID(), composerText: "Ship it", inputAvailability: .ready, submit: { _, _, _ in }
        )
        conversation.sendCurrentText()
        XCTAssertEqual(conversation.composerText, "")
        XCTAssertEqual(conversation.composer.text, "")
        XCTAssertEqual(conversation.messageRows.last?.snapshot.body, "Ship it")
    }

    func testDraftPersistenceStillSeesTextTypedThroughEitherRoute() async throws {
        let id = UUID()
        let service = ComposerPassthroughDraftService()
        let conversation = ConversationModel(conversationID: id, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: id)
        await coordinator.activeDraft?.load()

        // The field writes the composer object directly.
        conversation.composer.text = "Typed into the field"
        var flushed = await coordinator.flushAll()
        XCTAssertTrue(flushed)
        var stored = try await service.load(conversationID: ConversationID(id))
        XCTAssertEqual(stored?.text, "Typed into the field", "The draft coordinator must still observe the composer")

        // Restoring a saved draft writes through the conversation's passthrough.
        conversation.composerText = "Restored through the passthrough"
        flushed = await coordinator.flushAll()
        XCTAssertTrue(flushed)
        stored = try await service.load(conversationID: ConversationID(id))
        XCTAssertEqual(stored?.text, "Restored through the passthrough")
        coordinator.finishShutdown()
    }

    /// The bare-model test proves the write itself no longer publishes. The app
    /// never runs bare: a live `WorkspaceDraftCoordinator` turns every keystroke
    /// into `ConversationComposerDraftModel.setText`, whose `objectWillChange`
    /// hops through a `Task` back into `conversation.setDraftSubmissionAllowed`.
    /// That setter guards on equality and `canBeginSubmission` does not move
    /// while ordinary typing is loaded, unfailed and unconflicted — so the
    /// round trip must publish the conversation zero times, not once per
    /// character. Assert it with the hops drained, or the count means nothing.
    func testTypingWithALiveDraftCoordinatorStillNeverPublishesTheConversation() async throws {
        let id = UUID()
        let service = ComposerPassthroughDraftService()
        let conversation = ConversationModel(conversationID: id, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: id)
        await coordinator.activeDraft?.load()
        for _ in 0..<10 { await Task.yield() }

        var conversationPublications = 0
        var subscriptions: Set<AnyCancellable> = []
        conversation.objectWillChange
            .sink { _ in conversationPublications += 1 }
            .store(in: &subscriptions)

        var typed = ""
        for character in "Twenty characters ok" {
            typed.append(character)
            conversation.composer.text = typed
            await Task.yield()
        }
        // Drain the coordinator's Task hops and let the debounced save land,
        // so a deferred publish cannot hide behind the end of the test.
        for _ in 0..<10 { await Task.yield() }
        let flushed = await coordinator.flushAll()
        XCTAssertTrue(flushed)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(
            conversationPublications, 0,
            "Typing with a live draft coordinator must not publish the conversation: the admission recompute "
                + "is equality-guarded, so the transcript must not re-lay out on the autosave cadence either"
        )
        let stored = try await service.load(conversationID: ConversationID(id))
        XCTAssertEqual(stored?.text, typed, "The draft must still hold everything that was typed")
        subscriptions.removeAll()
        coordinator.finishShutdown()
    }
}

private actor ComposerPassthroughDraftService: ConversationDraftServing {
    private var values: [ConversationID: ConversationDraftSnapshot] = [:]

    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? {
        values[conversationID]
    }

    func save(
        conversationID: ConversationID,
        text: String,
        expectedRevision: UInt64
    ) async throws -> ConversationDraftSnapshot {
        guard (values[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let saved = try ConversationDraftSnapshot(
            conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        values[conversationID] = saved
        return saved
    }
}
