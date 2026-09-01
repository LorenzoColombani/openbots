import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsPersistence
@testable import OpenBotsUI

@MainActor
final class BotArchiveWorkspaceTests: XCTestCase {
    func testContextSettingsOpensExactUnselectedBotAndPreservesOtherBot() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        let bots = try await prepareContextMenuBots(workspace)
        XCTAssertEqual(workspace.sidebar.selection, bots.other.id.rawValue)

        await workspace.openBotSettings(id: bots.first.id.rawValue)
        let editor = try XCTUnwrap(workspace.profileEditor)
        await editor.load()
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(workspace.sidebar.selection, bots.first.id.rawValue)
        XCTAssertEqual(workspace.conversation.conversationID, bots.firstChat.rawValue)
        XCTAssertEqual(editor.originalTeammate?.id, bots.first.id)
        XCTAssertEqual(editor.originalTeammate?.appearance, bots.first.appearance)
        XCTAssertEqual(workspace.conversation.messages, bots.firstMessages)
        XCTAssertEqual(workspace.conversation.composerText, ContextMenuBots.firstDraft)
        let saved = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(saved, true)
        let first = try await store.teammate(id: bots.first.id)
        let other = try await store.teammate(id: bots.other.id)
        let otherDraft = try await store.loadDraft(conversationID: bots.otherChat)
        XCTAssertEqual(first, bots.first)
        XCTAssertEqual(other, bots.other)
        XCTAssertEqual(otherDraft?.text, ContextMenuBots.otherDraft)
        workspace.closeBotDetails()
        workspace.sidebar.selection = bots.other.id.rawValue
        await workspace.selectionTask?.value
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(workspace.conversation.messages, bots.otherMessages)
        XCTAssertEqual(workspace.conversation.composerText, ContextMenuBots.otherDraft)
        XCTAssertEqual(workspace.selectedTeammate?.appearance, bots.other.appearance)
    }

    func testContextArchiveTargetsUnselectedBotWithoutArchivingCurrentBot() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        let bots = try await prepareContextMenuBots(workspace)
        XCTAssertEqual(workspace.sidebar.selection, bots.other.id.rawValue)

        await workspace.archiveBot(id: bots.first.id.rawValue)
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        XCTAssertEqual(workspace.archiveModel?.archivedBots.map(\.id), [bots.first.id])
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), [bots.other.id.rawValue])
        let archived = try await store.teammate(id: bots.first.id)
        let other = try await store.teammate(id: bots.other.id)
        XCTAssertEqual(archived?.lifecycle, .archived)
        XCTAssertEqual(archived?.appearance, bots.first.appearance)
        XCTAssertEqual(archived?.profile.displayName, bots.first.profile.displayName)
        XCTAssertEqual(archived?.profile.title, bots.first.profile.title)
        XCTAssertEqual(archived?.profile.role, bots.first.profile.role)
        XCTAssertEqual(archived?.profile.detailedInstructions, bots.first.profile.detailedInstructions)
        XCTAssertEqual(archived?.profile.revision, bots.first.profile.revision + 1)
        XCTAssertEqual(other, bots.other)
        let firstDraft = try await store.loadDraft(conversationID: bots.firstChat)
        let otherDraft = try await store.loadDraft(conversationID: bots.otherChat)
        XCTAssertEqual(firstDraft?.text, ContextMenuBots.firstDraft)
        XCTAssertEqual(otherDraft?.text, ContextMenuBots.otherDraft)
        workspace.sidebar.selection = bots.other.id.rawValue
        await workspace.selectionTask?.value
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(workspace.conversation.conversationID, bots.otherChat.rawValue)
        XCTAssertEqual(workspace.conversation.messages, bots.otherMessages)
        XCTAssertEqual(workspace.conversation.composerText, ContextMenuBots.otherDraft)
    }

    func testSupersededContextActionCannotOpenOrArchiveNewerSelection() async throws {
        for archiveAction in [false, true] {
            let fixture = try ReferenceLocalWorkspaceFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let store = try fixture.open()
            let gate = ArchiveWorkspaceGate()
            let service = DelayedContextMenuSelectionService(backing: fixture.chatService(store: store), gate: gate)
            let workspace = makeWorkspace(fixture, store: store, chatService: service)
            defer { workspace.finishShutdown(); gate.release() }
            let bots = try await prepareContextMenuBots(workspace)
            await service.delayNextSelection(of: bots.first.id)
            let action = Task { @MainActor in
                if archiveAction { await workspace.archiveBot(id: bots.first.id.rawValue) }
                else { await workspace.openBotSettings(id: bots.first.id.rawValue) }
            }
            try await referenceWaitUntil { gate.isWaiting }
            XCTAssertEqual(workspace.sidebar.selection, bots.first.id.rawValue)
            workspace.sidebar.selection = bots.other.id.rawValue
            await workspace.selectionTask?.value
            try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
            workspace.conversation.composerText = "Newer selection draft"
            gate.release()
            await action.value

            XCTAssertEqual(workspace.sidebar.selection, bots.other.id.rawValue)
            XCTAssertEqual(workspace.conversation.conversationID, bots.otherChat.rawValue)
            XCTAssertEqual(workspace.conversation.composerText, "Newer selection draft")
            XCTAssertEqual(workspace.conversation.messages, bots.otherMessages)
            XCTAssertNil(workspace.profileEditor)
            XCTAssertTrue(workspace.archiveModel?.archivedBots.isEmpty == true)
            XCTAssertEqual(Set(workspace.sidebar.rows.map(\.id)), Set([bots.first.id.rawValue, bots.other.id.rawValue]))
            let first = try await store.teammate(id: bots.first.id)
            let other = try await store.teammate(id: bots.other.id)
            let selected = try await store.selectedConversationID()
            XCTAssertEqual(first, bots.first)
            XCTAssertEqual(other, bots.other)
            XCTAssertEqual(selected, bots.otherChat)
        }
    }

    func testQueuedContextRequestCannotOverrideImmediateNewerNavigation() async throws {
        for archiveAction in [false, true] {
            let fixture = try ReferenceLocalWorkspaceFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let store = try fixture.open()
            let workspace = makeWorkspace(fixture, store: store)
            defer { workspace.finishShutdown() }
            let bots = try await prepareContextMenuBots(workspace)
            await workspace.createTeammateImmediately()
            let newer = try XCTUnwrap(workspace.selectedTeammate)
            let newerChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
            try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
            let newerDraft = "Keep the newer destination's draft"
            workspace.conversation.composerText = newerDraft
            let draftSaved = await workspace.draftCoordinator?.flushAll()
            XCTAssertEqual(draftSaved, true)
            workspace.sidebar.selection = bots.other.id.rawValue
            await workspace.selectionTask?.value
            try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
            XCTAssertEqual(workspace.conversation.conversationID, bots.otherChat.rawValue)

            // Deliberately no suspension between item invocation and the newer
            // click: the queued action cannot start until after navigation.
            if archiveAction { workspace.requestBotArchive(id: bots.first.id.rawValue) }
            else { workspace.requestBotSettings(id: bots.first.id.rawValue) }
            workspace.sidebar.selection = newer.id.rawValue
            await workspace.selectionTask?.value
            await Task.yield()
            try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }

            XCTAssertEqual(workspace.sidebar.selection, newer.id.rawValue)
            XCTAssertEqual(workspace.conversation.conversationID, newerChat.rawValue)
            XCTAssertEqual(workspace.conversation.composerText, newerDraft)
            XCTAssertNil(workspace.profileEditor)
            XCTAssertTrue(workspace.archiveModel?.archivedBots.isEmpty == true)
            XCTAssertEqual(Set(workspace.sidebar.rows.map(\.id)),
                Set([bots.first.id.rawValue, bots.other.id.rawValue, newer.id.rawValue]))
            let firstSaved = try await store.teammate(id: bots.first.id)
            let otherSaved = try await store.teammate(id: bots.other.id)
            let newerSaved = try await store.teammate(id: newer.id)
            let selected = try await store.selectedConversationID()
            let preservedDraft = try await store.loadDraft(conversationID: newerChat)
            XCTAssertEqual(firstSaved, bots.first)
            XCTAssertEqual(otherSaved, bots.other)
            XCTAssertEqual(newerSaved, newer)
            XCTAssertEqual(selected, newerChat)
            XCTAssertEqual(preservedDraft?.text, newerDraft)
        }
    }

    func testArchiveAndRestoreKeepConversationDraftAppearanceAndOtherSelection() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let first = try XCTUnwrap(workspace.selectedTeammate)
        let chatID = try XCTUnwrap(workspace.conversation.conversationID)
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        workspace.conversation.composerText = "Saved message"
        workspace.conversation.sendCurrentText()
        try await referenceWaitUntil { !workspace.conversation.hasPendingSubmissions && workspace.conversation.messages.count == 1 }
        let messages = workspace.conversation.messages
        let draft = "  Keep this unsent — e\u{301}\nexactly.  "
        workspace.conversation.composerText = draft
        await workspace.archiveSelectedBot()
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        XCTAssertTrue(workspace.sidebar.rows.isEmpty)
        XCTAssertNil(workspace.sidebar.selection)
        XCTAssertNil(workspace.conversation.conversationID)
        let savedDraft = try await store.loadDraft(conversationID: ConversationID(chatID))
        XCTAssertEqual(savedDraft?.text, draft)
        let archived = try XCTUnwrap(workspace.archiveModel?.archivedBots.first)
        XCTAssertEqual(archived.id, first.id)
        XCTAssertEqual(archived.appearance, first.appearance)
        XCTAssertEqual(archived.lifecycle, .archived)
        let selectedAfterArchive = try await fixture.chatService(store: store).selectedDirectChat()
        XCTAssertNil(selectedAfterArchive)

        await workspace.createTeammateImmediately()
        let other = try XCTUnwrap(workspace.selectedTeammate)
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        workspace.conversation.composerText = "Other bot draft"
        await workspace.restoreBot(archived)
        XCTAssertEqual(workspace.sidebar.selection, other.id.rawValue)
        XCTAssertEqual(workspace.conversation.composerText, "Other bot draft")
        XCTAssertTrue(workspace.archiveModel?.archivedBots.isEmpty == true)
        XCTAssertEqual(Set(workspace.sidebar.rows.map(\.id)), Set([first.id.rawValue, other.id.rawValue]))
        workspace.sidebar.selection = first.id.rawValue
        await workspace.selectionTask?.value
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(workspace.conversation.conversationID, chatID)
        XCTAssertEqual(workspace.conversation.composerText, draft)
        XCTAssertEqual(workspace.conversation.messages, messages)
        XCTAssertEqual(workspace.selectedTeammate?.appearance, first.appearance)
    }

    func testConflictingDraftSaveRefusesArchiveAndKeepsVisibleText() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try XCTUnwrap(workspace.selectedTeammate)
        let chat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        let oldDraft = try await store.loadDraft(conversationID: chat)
        _ = try await ConversationDraftService(repository: store).save(
            conversationID: chat, text: "Other editor's saved draft", expectedRevision: oldDraft?.revision ?? 0
        )
        workspace.conversation.composerText = "My unsaved draft"
        await workspace.archiveSelectedBot()
        XCTAssertEqual(workspace.sidebar.selection, teammate.id.rawValue)
        XCTAssertEqual(workspace.conversation.composerText, "My unsaved draft")
        XCTAssertTrue(workspace.archiveModel?.errorMessage?.contains("draft could not be saved") == true)
        let unchanged = try await store.teammate(id: teammate.id)
        XCTAssertEqual(unchanged, teammate)
        let saved = try await store.loadDraft(conversationID: chat)
        XCTAssertEqual(saved?.text, "Other editor's saved draft")
    }

    func testUnfinishedProfileEditsPreventArchiveWithoutDiscardingEditor() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try XCTUnwrap(workspace.selectedTeammate)
        workspace.editSelectedProfile()
        let editor = try XCTUnwrap(workspace.profileEditor)
        await editor.load()
        editor.displayName = "Unfinished edit"
        await workspace.archiveSelectedBot()
        XCTAssertTrue(workspace.profileEditor === editor)
        XCTAssertEqual(editor.displayName, "Unfinished edit")
        XCTAssertTrue(workspace.archiveModel?.errorMessage?.contains("unfinished profile") == true)
        let unchanged = try await store.teammate(id: teammate.id)
        XCTAssertEqual(unchanged, teammate)
    }

    func testUnresolvedWorkErrorIsVisibleAndLeavesSidebarAndDraftIntact() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store, archive: RefusingArchiveService())
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try XCTUnwrap(workspace.selectedTeammate)
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        workspace.conversation.composerText = "Preserved draft"
        await workspace.archiveSelectedBot()
        XCTAssertEqual(workspace.sidebar.selection, teammate.id.rawValue)
        XCTAssertEqual(workspace.conversation.composerText, "Preserved draft")
        XCTAssertTrue(workspace.archiveModel?.errorMessage?.contains("Nothing was cancelled") == true)
    }

    func testPendingPhotoImportInClosedDetailsRefusesArchiveAndRetainsCompletedChoice() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let gate = ArchiveWorkspaceGate()
        let imported = try ProfilePhotoAsset(id: ProfileAssetID(UUID()), width: 2, height: 2,
            byteCount: 90, sha256: String(repeating: "a", count: 64))
        let workspace = makeWorkspace(fixture, store: store, photoImporter: { _ in
            await gate.wait()
            return imported // Metadata only: no selected source or user file is opened.
        })
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try XCTUnwrap(workspace.selectedTeammate)
        workspace.editSelectedProfile()
        let editor = try XCTUnwrap(workspace.profileEditor)
        await editor.load()
        XCTAssertFalse(editor.hasUnsavedChanges)
        let importTask = Task { await editor.importPhoto(from: fixture.directory.appendingPathComponent("synthetic-photo.png")) }
        defer { gate.release() }
        try await referenceWaitUntil { gate.isWaiting }
        XCTAssertTrue(editor.isImportingPhoto)
        XCTAssertFalse(editor.hasUnsavedChanges, "An in-flight import has no returned choice yet")
        workspace.closeBotDetails()
        XCTAssertNil(workspace.profileEditor)
        await workspace.archiveSelectedBot()

        XCTAssertEqual(workspace.sidebar.selection, teammate.id.rawValue)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), [teammate.id.rawValue])
        XCTAssertTrue(workspace.archiveModel?.errorMessage?.contains("photo import") == true)
        let unchanged = try await store.teammate(id: teammate.id)
        XCTAssertEqual(unchanged, teammate)
        gate.release()
        await importTask.value
        workspace.editSelectedProfile()
        XCTAssertTrue(workspace.profileEditor === editor)
        XCTAssertFalse(editor.isImportingPhoto)
        XCTAssertEqual(editor.pendingPhotoAsset, imported)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.appearancePreviewIdentity?.appearance.profileAssetID, imported.id.rawValue)
        XCTAssertEqual(editor.originalTeammate?.appearance, teammate.appearance)
    }

    func testDelayedArchiveCompletionCannotClearNewerBotSelectionOrDraft() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let gate = ArchiveWorkspaceGate()
        let archive = DelayedArchiveCompletionService(backing: TeammateArchiveService(repository: store), gate: gate)
        let workspace = makeWorkspace(fixture, store: store, archive: archive)
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let first = try XCTUnwrap(workspace.selectedTeammate)
        let firstChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        await workspace.createTeammateImmediately()
        let other = try XCTUnwrap(workspace.selectedTeammate)
        let otherChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        workspace.sidebar.selection = first.id.rawValue
        await workspace.selectionTask?.value
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        workspace.conversation.composerText = "First bot's unsent draft"
        let archiveTask = Task { await workspace.archiveSelectedBot() }
        defer { gate.release() }
        try await referenceWaitUntil { gate.isWaiting }

        workspace.sidebar.selection = other.id.rawValue
        await workspace.selectionTask?.value
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        let newerDraft = "Newer bot draft written while A's completion is delayed"
        workspace.conversation.composerText = newerDraft
        let newerDraftSaved = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(newerDraftSaved, true)
        gate.release()
        await archiveTask.value

        XCTAssertNil(workspace.archiveModel?.errorMessage)
        XCTAssertEqual(workspace.sidebar.selection, other.id.rawValue)
        XCTAssertEqual(workspace.conversation.conversationID, otherChat.rawValue)
        XCTAssertEqual(workspace.conversation.composerText, newerDraft)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), [other.id.rawValue])
        XCTAssertEqual(workspace.archiveModel?.archivedBots.map(\.id), [first.id])
        let savedSelection = try await store.selectedConversationID()
        let savedOtherDraft = try await store.loadDraft(conversationID: otherChat)
        let savedFirstDraft = try await store.loadDraft(conversationID: firstChat)
        let savedOther = try await store.teammate(id: other.id)
        XCTAssertEqual(savedSelection, otherChat)
        XCTAssertEqual(savedOtherDraft?.text, newerDraft)
        XCTAssertEqual(savedFirstDraft?.text, "First bot's unsent draft")
        XCTAssertEqual(savedOther, other)
    }

    func testPendingAttachmentStagingRefusesArchiveWithoutCancellingImportOrLosingDraft() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let gate = ArchiveWorkspaceGate()
        let workspace = makeWorkspace(fixture, store: store, attachmentFactory: { conversationID in
            AttachmentDraftModel(conversationID: conversationID,
                load: { try await store.draft(conversationID: conversationID) },
                importFile: { _, operationID in
                    await gate.wait()
                    let asset = try AttachmentAsset(id: AttachmentID(operationID), conversationID: conversationID,
                        displayName: "synthetic-attachment.txt", typeIdentifier: "public.plain-text", byteCount: 7,
                        sha256: String(repeating: "b", count: 64), createdAt: Date())
                    _ = try await store.stage(asset)
                    return asset // This test stages synthetic metadata, never reads a file.
                },
                remove: { try await store.removeDraftAttachment(id: $0, conversationID: conversationID) })
        })
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try XCTUnwrap(workspace.selectedTeammate)
        let chat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        try await referenceWaitUntil {
            workspace.draftCoordinator?.activeDraft?.status == .saved && workspace.attachmentDraft.loadState == .ready
        }
        let draft = "Keep this text while the attachment stages"
        workspace.conversation.composerText = draft
        let attachmentID = UUID()
        XCTAssertTrue(workspace.attachmentDraft.selectFile(
            at: fixture.directory.appendingPathComponent("synthetic-attachment.txt"), operationID: attachmentID))
        defer { gate.release() }
        try await referenceWaitUntil { gate.isWaiting }
        await workspace.archiveSelectedBot()

        XCTAssertTrue(workspace.archiveModel?.errorMessage?.contains("attachment to finish saving") == true)
        XCTAssertEqual(workspace.sidebar.selection, teammate.id.rawValue)
        XCTAssertEqual(workspace.conversation.composerText, draft)
        XCTAssertEqual(workspace.attachmentDraft.rows.map(\.id), [attachmentID])
        XCTAssertEqual(workspace.attachmentDraft.rows.first?.state, .pending)
        let unchanged = try await store.teammate(id: teammate.id)
        XCTAssertEqual(unchanged, teammate)
        gate.release()
        try await referenceWaitUntil { workspace.attachmentDraft.canSubmit }
        XCTAssertEqual(workspace.attachmentDraft.rows.map(\.id), [attachmentID])
        XCTAssertEqual(workspace.conversation.composerText, draft)
        let savedAttachments = try await store.draft(conversationID: chat)
        XCTAssertEqual(savedAttachments.attachments.map(\.id), [AttachmentID(attachmentID)])
        let savedSelection = try await store.selectedConversationID()
        XCTAssertEqual(savedSelection, chat)
    }

    private func prepareContextMenuBots(_ workspace: DurableWorkspaceModel) async throws -> ContextMenuBots {
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let first = try XCTUnwrap(workspace.selectedTeammate)
        let firstChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        workspace.conversation.composerText = "First bot's saved local record"
        workspace.conversation.sendCurrentText()
        try await referenceWaitUntil { !workspace.conversation.hasPendingSubmissions && workspace.conversation.messages.count == 1 }
        let firstMessages = workspace.conversation.messages
        workspace.conversation.composerText = ContextMenuBots.firstDraft
        let firstSaved = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(firstSaved, true)
        await workspace.createTeammateImmediately()
        let other = try XCTUnwrap(workspace.selectedTeammate)
        let otherChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        workspace.conversation.composerText = "Other bot's saved local record"
        workspace.conversation.sendCurrentText()
        try await referenceWaitUntil { !workspace.conversation.hasPendingSubmissions && workspace.conversation.messages.count == 1 }
        let otherMessages = workspace.conversation.messages
        workspace.conversation.composerText = ContextMenuBots.otherDraft
        return ContextMenuBots(first: first, firstChat: firstChat, firstMessages: firstMessages,
            other: other, otherChat: otherChat, otherMessages: otherMessages)
    }

    private func makeWorkspace(_ fixture: ReferenceLocalWorkspaceFixture, store: SQLiteStore,
                               archive: (any TeammateArchiving)? = nil,
                               photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)? = nil,
                               attachmentFactory: WorkspaceAttachmentCoordinator.Factory? = nil,
                               chatService: (any DurableTeammateChatServing)? = nil) -> DurableWorkspaceModel {
        DurableWorkspaceModel(service: chatService ?? fixture.chatService(store: store), hiringService: ReferenceUnusedHiringService(),
            profileService: TeammateProfileService(repository: store),
            archiveService: archive ?? TeammateArchiveService(repository: store),
            draftService: ConversationDraftService(repository: store),
            photoImporter: photoImporter, attachmentDraftFactory: attachmentFactory)
    }
}

private struct ContextMenuBots {
    static let firstDraft = "  First draft — e\u{301}\nkeep exactly.  "
    static let otherDraft = "Other bot's unsent draft"
    let first: Teammate
    let firstChat: ConversationID
    let firstMessages: [ChatMessageSnapshot]
    let other: Teammate
    let otherChat: ConversationID
    let otherMessages: [ChatMessageSnapshot]
}

/// Delays completion after the real selection is saved. A newer selection can
/// finish while this old callback deliberately ignores cancellation.
private actor DelayedContextMenuSelectionService: DurableTeammateChatServing {
    let backing: any DurableTeammateChatServing
    let gate: ArchiveWorkspaceGate
    private var delayedID: TeammateID?

    init(backing: any DurableTeammateChatServing, gate: ArchiveWorkspaceGate) { self.backing = backing; self.gate = gate }
    func delayNextSelection(of id: TeammateID) { delayedID = id }
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { try await backing.activeDirectChats() }
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? { try await backing.selectedDirectChat() }
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        let delay = delayedID == teammateID
        if delay { delayedID = nil }
        try await backing.select(teammateID: teammateID, conversationID: conversationID)
        if delay { await gate.wait() }
    }
    func clearSelection() async throws { try await backing.clearSelection() }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft) async throws -> DurableTeammateChatCreationSnapshot {
        try await backing.createTeammateAndDirectChat(draft)
    }
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        try await backing.loadMessages(conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
    }
    func saveMessageLocally(conversationID: ConversationID, teammateID: TeammateID, userMessageID: MessageID,
                           text: String, attachmentIDs: [AttachmentID]) async throws -> Message {
        try await backing.saveMessageLocally(conversationID: conversationID, teammateID: teammateID,
            userMessageID: userMessageID, text: text, attachmentIDs: attachmentIDs)
    }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        try await backing.sendMessageToLocalFixture(conversationID: conversationID, teammateID: teammateID,
            userMessageID: userMessageID, text: text)
    }
}

private actor RefusingArchiveService: TeammateArchiving {
    func archivedTeammates() async throws -> [Teammate] { [] }
    func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        throw TeammateArchiveError.unresolvedWork
    }
    func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        throw TeammateArchiveError.unresolvedWork
    }
}

@MainActor
private final class ArchiveWorkspaceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false

    func wait() async {
        guard !isReleased else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DelayedArchiveCompletionService: TeammateArchiving {
    let backing: any TeammateArchiving
    let gate: ArchiveWorkspaceGate

    init(backing: any TeammateArchiving, gate: ArchiveWorkspaceGate) {
        self.backing = backing
        self.gate = gate
    }

    func archivedTeammates() async throws -> [Teammate] { try await backing.archivedTeammates() }
    func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        let saved = try await backing.archiveTeammate(id: id, expectedProfileRevision: expectedProfileRevision)
        await gate.wait()
        return saved
    }
    func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        try await backing.restoreTeammate(id: id, expectedProfileRevision: expectedProfileRevision)
    }
}
