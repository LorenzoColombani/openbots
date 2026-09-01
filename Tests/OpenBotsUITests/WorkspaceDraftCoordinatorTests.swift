import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@MainActor
@Suite("WorkspaceDraftCoordinatorTests")
struct WorkspaceDraftCoordinatorTests {
    @Test("Quit rechecks earlier and newly opened drafts after a delayed later flush", arguments: [false, true])
    func quitRechecksNewEdits(openNewConversation: Bool) async throws {
        let ids = [UUID(), UUID()]
        let service = DelayedWorkspaceDraftService()
        let conversation = ConversationModel(conversationID: ids[0], submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        for id in ids {
            conversation.show(conversationID: id, title: "Draft", messages: [])
            coordinator.activate(conversationID: id)
            await coordinator.activeDraft?.load()
            conversation.composerText = "Initial text for \(id)"
        }
        let quitting = Task { await coordinator.flushAll() }
        let firstFlushedID = await service.waitForSecondSave()
        let changedID = openNewConversation ? UUID() : firstFlushedID.rawValue
        conversation.show(conversationID: changedID, title: "Changed", messages: [])
        coordinator.activate(conversationID: changedID)
        await coordinator.activeDraft?.load()
        conversation.composerText = "Typed while another draft was saving"
        await service.releaseSecondSave()
        #expect(!(await quitting.value), "An earlier success cannot certify later/new text.")
        #expect(await coordinator.flushAll())
        #expect(try await service.load(conversationID: ConversationID(changedID))?.text == "Typed while another draft was saving")
    }

    @Test("Conversation switching and fresh presentation restore separate exact draft text")
    func draftIsolationAndReopen() async throws {
        let a = UUID(), b = UUID()
        let service = WorkspaceDraftTestService()
        let conversation = ConversationModel(conversationID: a, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: a)
        await coordinator.activeDraft?.load()
        conversation.composerText = "  Ada\0draft 🐙\n"
        #expect(await coordinator.flushAll())
        conversation.show(conversationID: b, title: "B", messages: [])
        coordinator.activate(conversationID: b)
        await coordinator.activeDraft?.load()
        #expect(conversation.composerText.isEmpty)
        conversation.composerText = "Mira draft"
        #expect(await coordinator.flushAll())
        conversation.show(conversationID: a, title: "A", messages: [])
        coordinator.activate(conversationID: a)
        #expect(conversation.composerText == "  Ada\0draft 🐙\n")

        let restoredConversation = ConversationModel(conversationID: b, submit: { _, _, _ in })
        let restored = WorkspaceDraftCoordinator(conversation: restoredConversation, service: service)
        restored.activate(conversationID: b)
        await restored.activeDraft?.load()
        #expect(restoredConversation.composerText == "Mira draft")
    }

    @Test("Older local send completion saves newer draft without clearing another conversation")
    func newerDraftSurvivesSendCompletion() async throws {
        let a = UUID(), b = UUID(), message = UUID()
        let service = WorkspaceDraftTestService()
        let conversation = ConversationModel(conversationID: a, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: a)
        await coordinator.activeDraft?.load()
        conversation.composerText = "first message"
        #expect(coordinator.beginSubmission(messageID: message, conversationID: a, rawText: conversation.composerText))
        #expect(conversation.composerText.isEmpty)
        #expect(await coordinator.persistSubmission(messageID: message))
        conversation.composerText = "next message"
        #expect(try await service.load(conversationID: ConversationID(a))?.text == "first message")
        #expect(!(await coordinator.flushAll()), "Captured text is not yet a durably stored message.")

        conversation.show(conversationID: b, title: "B", messages: [])
        coordinator.activate(conversationID: b)
        await coordinator.activeDraft?.load()
        conversation.composerText = "other conversation"
        await coordinator.completeSubmission(messageID: message)
        #expect(conversation.composerText == "other conversation")
        #expect(try await service.load(conversationID: ConversationID(a))?.text == "next message")
        #expect(await coordinator.flushAll())
    }

    @Test("Failed send with newer typing keeps the safety copy until explicit recovery")
    func failureRecoveryNeverSilentlyOverwrites() async throws {
        let id = UUID(), message = UUID()
        let service = WorkspaceDraftTestService()
        let conversation = ConversationModel(conversationID: id, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: id)
        let model = try #require(coordinator.activeDraft)
        await model.load()
        conversation.composerText = "earlier"
        #expect(coordinator.beginSubmission(messageID: message, conversationID: id, rawText: "earlier"))
        #expect(await coordinator.persistSubmission(messageID: message))
        conversation.composerText = "newer"
        coordinator.failSubmission(messageID: message)
        #expect(conversation.composerText == "newer")
        #expect(model.recoverableFailedText == "earlier")
        #expect(!(await coordinator.flushAll()))
        #expect(try await service.load(conversationID: ConversationID(id))?.text == "earlier")
        // Simulates the explicit UI acknowledgement after copying the earlier
        // text; the coordinator itself has no clipboard/file capability.
        model.acknowledgeFailedTextRecovery()
        #expect(await coordinator.flushAll())
        #expect(try await service.load(conversationID: ConversationID(id))?.text == "newer")
    }
}

private actor DelayedWorkspaceDraftService: ConversationDraftServing {
    private var values: [ConversationID: ConversationDraftSnapshot] = [:]
    private var firstSavedID: ConversationID?
    private var saveCount = 0
    private var secondSave: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<ConversationID, Never>?
    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? { values[conversationID] }
    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) async throws -> ConversationDraftSnapshot {
        saveCount += 1
        if saveCount == 2 {
            await withCheckedContinuation { secondSave = $0
                if let firstSavedID { waiting?.resume(returning: firstSavedID); waiting = nil }
            }
        }
        guard (values[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let saved = try ConversationDraftSnapshot(conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: Date(timeIntervalSince1970: 1_000))
        values[conversationID] = saved
        if firstSavedID == nil { firstSavedID = conversationID }
        return saved
    }
    func waitForSecondSave() async -> ConversationID {
        if secondSave != nil, let firstSavedID { return firstSavedID }
        return await withCheckedContinuation { waiting = $0 }
    }
    func releaseSecondSave() { secondSave?.resume(); secondSave = nil }
}

private actor WorkspaceDraftTestService: ConversationDraftServing {
    var values: [ConversationID: ConversationDraftSnapshot] = [:]
    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? { values[conversationID] }
    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) async throws -> ConversationDraftSnapshot {
        guard (values[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let saved = try ConversationDraftSnapshot(conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: Date(timeIntervalSince1970: 1_000))
        values[conversationID] = saved
        return saved
    }
}
