import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsUI

@Suite("Workspace attachment send coordination")
@MainActor
struct WorkspaceAttachmentCoordinatorTests {
    @Test("Picker completion keeps its original conversation and consumes cancellation once")
    func pickerIsFrozen() {
        let a = AttachmentDraftModel { _, _ in throw AttachmentDraftSubmissionError.unresolvedDraft }
        let b = AttachmentDraftModel { _, _ in throw AttachmentDraftSubmissionError.unresolvedDraft }
        var visible = a
        let request = AttachmentPickerRequest(draft: visible)
        visible = b
        let selected = URL(fileURLWithPath: "/private/tmp/picker-fixture.txt")
        #expect(request.consume(selected))
        #expect(a.rows.count == 1 && visible.rows.isEmpty)
        #expect(!request.consume(selected))
        let cancelled = AttachmentPickerRequest(draft: b)
        #expect(!cancelled.consume(nil))
        #expect(!cancelled.consume(selected))
        #expect(b.rows.isEmpty)
    }

    @Test("Attachment-only send admits an immediate pending row but empty drafts do not")
    func attachmentOnlyAdmission() async throws {
        let conversationID = UUID()
        let asset = try makeAsset(conversationID: conversationID)
        let draft = draftModel(conversationID: conversationID, assets: [asset])
        let recorder = AttachmentSubmissionRecorder()
        let conversation = ConversationModel(conversationID: conversationID,
            submit: { id, owner, text in await recorder.record(id, owner, text) })
        let coordinator = WorkspaceAttachmentCoordinator(conversation: conversation, factory: { _ in draft })
        _ = coordinator.activate(conversationID)
        await draft.load()
        await settle()
        #expect(conversation.canSend)
        conversation.sendCurrentText()
        #expect(conversation.messages.last?.body == "Saving attachment…")
        #expect(conversation.messages.last?.delivery == .pending)
        await settle()
        #expect(await recorder.texts == [""])
        let empty = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        #expect(!empty.canSend)
    }

    @Test("Frozen sends keep later additions, and switching conversations cannot redirect acknowledgment")
    func captureAndSwitch() async throws {
        let a = UUID(), b = UUID()
        let first = try makeAsset(conversationID: a)
        let second = try makeAsset(conversationID: b)
        let newID = UUID()
        let later = try makeAsset(conversationID: a, id: newID)
        let draftA = draftModel(conversationID: a, assets: [first], imported: later)
        let draftB = draftModel(conversationID: b, assets: [second])
        let conversation = ConversationModel(conversationID: a, submit: { _, _, _ in })
        let coordinator = WorkspaceAttachmentCoordinator(conversation: conversation, factory: { $0.rawValue == a ? draftA : draftB })
        _ = coordinator.activate(a)
        await draftA.load(); await settle()
        let messageID = UUID()
        #expect(coordinator.begin(messageID: messageID, conversationID: a) == [first])
        #expect(!conversation.canSend)
        #expect(!coordinator.isSafeToQuit)
        #expect(draftA.selectFile(at: URL(fileURLWithPath: "/private/tmp/fixture.txt"), operationID: newID))
        await settle()
        _ = coordinator.activate(b)
        await draftB.load(); await settle()
        coordinator.finish(messageID: messageID, committed: true)
        #expect(try draftA.freezeForSubmission() == [later])
        #expect(try draftB.freezeForSubmission() == [second])
        #expect(coordinator.isSafeToQuit)
    }

    @Test("Failed send retains every captured attachment; loading prevents admission")
    func failureRetains() async throws {
        let id = UUID()
        let asset = try makeAsset(conversationID: id)
        let model = draftModel(conversationID: id, assets: [asset])
        let conversation = ConversationModel(conversationID: id, composerText: "Keep this caption", submit: { _, _, _ in })
        let coordinator = WorkspaceAttachmentCoordinator(conversation: conversation, factory: { _ in model })
        _ = coordinator.activate(id)
        #expect(!conversation.canSend)
        await model.load(); await settle()
        let messageID = UUID()
        #expect(coordinator.begin(messageID: messageID, conversationID: id) == [asset])
        coordinator.finish(messageID: messageID, committed: false)
        #expect(try model.freezeForSubmission() == [asset])
        #expect(conversation.composerText == "Keep this caption")
        #expect(conversation.canSend)
    }

    private func draftModel(conversationID: UUID, assets: [AttachmentAsset], imported: AttachmentAsset? = nil) -> AttachmentDraftModel {
        let id = ConversationID(conversationID)
        return AttachmentDraftModel(conversationID: id,
            load: { AttachmentDraftSnapshot(conversationID: id, revision: 1, attachments: assets) },
            importFile: { _, _ in guard let imported else { throw AttachmentDraftSubmissionError.unresolvedDraft }; return imported },
            remove: { _ in AttachmentDraftSnapshot(conversationID: id, revision: 2, attachments: []) })
    }

    private func makeAsset(conversationID: UUID, id: UUID = UUID()) throws -> AttachmentAsset {
        try AttachmentAsset(id: AttachmentID(id), conversationID: ConversationID(conversationID),
            displayName: "fixture.txt", typeIdentifier: "public.plain-text", byteCount: 1,
            sha256: String(repeating: "a", count: 64), createdAt: Date(timeIntervalSince1970: 123))
    }

    private func settle() async { for _ in 0..<100 { await Task.yield() } }
}

private actor AttachmentSubmissionRecorder {
    private(set) var texts: [String] = []
    func record(_ message: UUID, _ owner: UUID, _ text: String) { texts.append(text) }
}
