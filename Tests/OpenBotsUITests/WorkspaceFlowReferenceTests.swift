import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsPersistence
@testable import OpenBotsUI

@MainActor
final class ReferenceWorkspaceFlowTests: XCTestCase {
    func testNewerSidebarSelectionWinsCreationScheduledBeforeOrDuringPendingNavigation() async throws {
        for holdEarlierNavigation in [true, false] {
            let scenario = try await ReferenceCreationScenario(failsCreation: false, seedCount: 3)
            defer { scenario.close() }
            let workspace = scenario.workspace
            let a = scenario.chats[0]
            let b = scenario.chats[1]
            let c = scenario.chats[2]
            workspace.sidebar.selection = a.teammate.id.rawValue
            await workspace.selectionTask?.value
            try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
            workspace.conversation.composerText = "A's unfinished note"
            let loadGate = ReferenceCreationGate()
            defer { loadGate.release() }
            if holdEarlierNavigation {
                await scenario.service.holdNextLoad(conversationID: b.id, gate: loadGate)
                workspace.sidebar.selection = b.teammate.id.rawValue
                try await referenceWaitUntil { loadGate.arrivals == 1 }
                workspace.beginTeammateCreation()
                try await referenceWaitUntil { workspace.isCreatingTeammate }
                // Creation is now waiting for B. C is a later user intent.
                workspace.sidebar.selection = c.teammate.id.rawValue
                await workspace.selectionTask?.value
                loadGate.release()
            } else {
                // No suspension between these calls: capture must happen at
                // the button entry, before its unstarted Task can observe C.
                workspace.beginTeammateCreation()
                workspace.sidebar.selection = c.teammate.id.rawValue
                await workspace.selectionTask?.value
            }
            try await referenceWaitUntil { scenario.gate.arrivals == 1 }
            XCTAssertEqual(workspace.sidebar.selection, c.teammate.id.rawValue)
            XCTAssertEqual(workspace.conversation.conversationID, c.id.rawValue)
            try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
            workspace.conversation.composerText = "C remains the current draft"
            scenario.gate.release()
            try await referenceWaitUntil { !workspace.isCreatingTeammate }
            XCTAssertEqual(workspace.sidebar.rows.count, 4)
            XCTAssertEqual(workspace.sidebar.selection, c.teammate.id.rawValue)
            XCTAssertEqual(workspace.conversation.conversationID, c.id.rawValue)
            XCTAssertEqual(workspace.conversation.composerText, "C remains the current draft")
            XCTAssertNil(workspace.creationError)
            let savedSelection = try await scenario.service.selectedDirectChat()
            XCTAssertEqual(savedSelection?.teammate.id, c.teammate.id)
            XCTAssertEqual(savedSelection?.conversation.id, c.id)
            let attempts = await scenario.service.attempts
            XCTAssertEqual(attempts, 1)
        }
    }

    func testDelayedCreationPreservesExactHistoricalSearchPageFocusAndDraft() async throws {
        for waitUntilCreationServiceIsHeld in [true, false] {
            try await verifyHistoricalSearchDuringCreation(waitUntilCreationServiceIsHeld: waitUntilCreationServiceIsHeld)
        }
    }

    private func verifyHistoricalSearchDuringCreation(waitUntilCreationServiceIsHeld: Bool) async throws {
        let scenario = try await ReferenceCreationScenario(failsCreation: false)
        defer { scenario.close() }
        let chat = scenario.chats[0]
        let backing = scenario.fixture.chatService(store: scenario.store)
        var messageIDs: [UUID] = []
        for index in 1...20 {
            let id = UUID()
            messageIDs.append(id)
            _ = try await backing.saveMessageLocally(
                conversationID: chat.id, teammateID: chat.teammate.id, userMessageID: MessageID(id),
                text: index == 5 ? "historicneedle source to revisit" : "Saved local record \(index)", attachmentIDs: []
            )
        }
        let workspace = scenario.workspace
        try await workspace.loadInitialWorkspace(messageLimit: 3)
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(workspace.conversation.messages.map(\.id), Array(messageIDs.suffix(3)))
        let draft = "  Unsent while revisiting a historical source — e\u{301}.  "
        workspace.conversation.composerText = draft
        let search = try XCTUnwrap(workspace.searchCoordinator)
        search.present()
        search.model.setQuery("historicneedle")
        await search.model.searchNow()
        let hit = try XCTUnwrap(search.model.page?.messages.first)
        XCTAssertEqual(hit.id.rawValue, messageIDs[4])
        search.close()
        workspace.beginTeammateCreation()
        if waitUntilCreationServiceIsHeld {
            try await referenceWaitUntil { scenario.gate.arrivals == 1 }
        }
        // In the second variant these are the same actor turn as New Bot:
        // its queued worker must not dismiss this newer navigation intent.
        search.present()
        search.openMessage(hit)
        try await referenceWaitUntil {
            !search.isPresented && !search.isOpening && workspace.conversation.searchFocus?.messageID == messageIDs[4]
        }
        let historicalRows = workspace.conversation.messages
        let historicalObjects = workspace.conversation.messageRows.map(ObjectIdentifier.init)
        let focus = try XCTUnwrap(workspace.conversation.searchFocus)
        let hasEarlier = workspace.conversation.hasEarlierMessages
        let draftModel = workspace.draftCoordinator?.activeDraft
        XCTAssertEqual(historicalRows.map(\.id), Array(messageIDs[2...4]))
        XCTAssertTrue(workspace.conversation.isViewingSearchResult)
        XCTAssertTrue(workspace.conversation.composerText.utf8.elementsEqual(draft.utf8))
        try await referenceWaitUntil { scenario.gate.arrivals == 1 }
        let loadCountBeforeCommit = await scenario.service.messageLoadCount
        scenario.gate.release()
        try await referenceWaitUntil { !workspace.isCreatingTeammate }
        XCTAssertEqual(workspace.sidebar.rows.count, 2)
        XCTAssertEqual(workspace.sidebar.selection, chat.teammate.id.rawValue)
        XCTAssertEqual(workspace.conversation.conversationID, chat.id.rawValue)
        XCTAssertEqual(workspace.conversation.messages, historicalRows)
        XCTAssertEqual(workspace.conversation.messageRows.map(ObjectIdentifier.init), historicalObjects)
        XCTAssertEqual(workspace.conversation.searchFocus, focus)
        XCTAssertEqual(workspace.conversation.hasEarlierMessages, hasEarlier)
        XCTAssertTrue(workspace.conversation.isViewingSearchResult)
        XCTAssertTrue(workspace.conversation.composerText.utf8.elementsEqual(draft.utf8))
        XCTAssertTrue(workspace.draftCoordinator?.activeDraft === draftModel)
        let loadCountAfterCommit = await scenario.service.messageLoadCount
        XCTAssertEqual(loadCountAfterCommit, loadCountBeforeCommit, "Repair saved selection without reloading the historical page")
        let savedSelection = try await scenario.service.selectedDirectChat()
        XCTAssertEqual(savedSelection?.conversation.id, chat.id)
        XCTAssertNil(workspace.creationError)
    }

    func testRepeatedNewBotFailureKeepsCurrentChatAndRetryCreatesOnlyOneBot() async throws {
        let scenario = try await ReferenceCreationScenario(failsCreation: true)
        defer { scenario.close() }
        let workspace = scenario.workspace
        let selection = workspace.sidebar.selection
        let conversationID = workspace.conversation.conversationID
        let rows = workspace.sidebar.rows
        workspace.conversation.composerText = "Keep my draft through a failed creation"
        workspace.beginTeammateCreation()
        workspace.beginTeammateCreation() // Same actor turn, before the first task starts.
        try await referenceWaitUntil { scenario.gate.arrivals == 1 }
        XCTAssertTrue(workspace.isCreatingTeammate)
        await workspace.createTeammateImmediately() // Direct reentry is guarded too.
        XCTAssertEqual(workspace.sidebar.selection, selection)
        XCTAssertEqual(workspace.conversation.conversationID, conversationID)
        XCTAssertNil(workspace.hiringModel)
        scenario.gate.release()
        try await referenceWaitUntil { !workspace.isCreatingTeammate }
        XCTAssertNotNil(workspace.creationError)
        XCTAssertEqual(workspace.sidebar.rows, rows)
        XCTAssertEqual(workspace.sidebar.selection, selection)
        XCTAssertEqual(workspace.conversation.conversationID, conversationID)
        XCTAssertEqual(workspace.conversation.composerText, "Keep my draft through a failed creation")
        let attempts = await scenario.service.attempts
        XCTAssertEqual(attempts, 1)
        let unchanged = try await scenario.service.activeDirectChats()
        XCTAssertEqual(unchanged.count, 1, "Failed provisioning must not leave a phantom roster entry")

        await scenario.service.setFailure(false)
        await workspace.createTeammateImmediately()
        XCTAssertNil(workspace.creationError)
        XCTAssertFalse(workspace.isCreatingTeammate)
        XCTAssertEqual(workspace.sidebar.rows.count, 2)
        XCTAssertNotEqual(workspace.sidebar.selection, selection)
        XCTAssertTrue(workspace.conversation.messages.isEmpty)
        workspace.sidebar.selection = selection
        await workspace.selectionTask?.value
        XCTAssertEqual(workspace.conversation.composerText, "Keep my draft through a failed creation")
        let retryAttempts = await scenario.service.attempts
        XCTAssertEqual(retryAttempts, 2)
    }

    func testCreationCommittedAfterShutdownCannotReopenOrMutateFrozenPresentation() async throws {
        let scenario = try await ReferenceCreationScenario(failsCreation: false)
        defer { scenario.close() }
        let workspace = scenario.workspace
        workspace.conversation.composerText = "Frozen draft"
        let selection = workspace.sidebar.selection
        let conversationID = workspace.conversation.conversationID
        let rows = workspace.sidebar.rows
        workspace.beginTeammateCreation()
        try await referenceWaitUntil { scenario.gate.arrivals == 1 }
        workspace.beginShutdown()
        workspace.finishShutdown()
        scenario.gate.release()
        try await referenceWaitUntil { !workspace.isCreatingTeammate }
        XCTAssertEqual(workspace.sidebar.rows, rows)
        XCTAssertEqual(workspace.sidebar.selection, selection)
        XCTAssertEqual(workspace.conversation.conversationID, conversationID)
        XCTAssertEqual(workspace.conversation.composerText, "Frozen draft")
        XCTAssertTrue(workspace.conversation.messages.isEmpty)
        XCTAssertNil(workspace.creationError)
        XCTAssertNil(workspace.hiringModel)
        workspace.beginTeammateCreation()
        await workspace.createTeammateImmediately()
        let attempts = await scenario.service.attempts
        XCTAssertEqual(attempts, 1, "Shutdown must reject new creation admission")
        let committed = try await scenario.service.activeDirectChats()
        XCTAssertEqual(committed.count, 2, "An already-admitted atomic commit is not falsely reported as rolled back")
        let fresh = scenario.fixture.workspace(store: try scenario.fixture.open())
        defer { fresh.finishShutdown() }
        try await fresh.loadInitialWorkspace()
        XCTAssertEqual(fresh.sidebar.rows.count, 2)
        XCTAssertNotEqual(fresh.sidebar.selection, selection)
        XCTAssertTrue(fresh.conversation.messages.isEmpty)
    }

    func testImmediateLocalCreationPreservesChatsDraftsAndProfileRoutesAcrossReopen() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let hiring = ReferenceUnusedHiringService()
        let workspace = fixture.workspace(store: store, hiring: hiring)
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        XCTAssertTrue(workspace.sidebar.rows.isEmpty)

        await workspace.createTeammateImmediately()
        let first = try XCTUnwrap(workspace.selectedTeammate)
        XCTAssertEqual(first.appearance.builtInAvatarID,
            BuiltInAvatar.allocatedForNewIdentity(seed: first.appearance.deterministicSeed)?.rawValue)
        let firstChatID = try XCTUnwrap(workspace.conversation.conversationID)
        XCTAssertNil(workspace.creationError)
        XCTAssertFalse(workspace.isCreatingTeammate)
        XCTAssertNil(workspace.hiringModel, "New Bot must not mount the old questionnaire")
        XCTAssertEqual(workspace.sidebar.selection, first.id.rawValue)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), [first.id.rawValue])
        XCTAssertTrue(workspace.conversation.messages.isEmpty, "Creation must not invent a greeting")
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }

        let messageID = UUID()
        let messageText = "Please review these sources — café e\u{301}."
        workspace.conversation.composerText = messageText
        try await referenceWaitUntil { workspace.conversation.canSend }
        workspace.conversation.sendCurrentText(messageID: messageID)
        try await referenceWaitUntil {
            workspace.conversation.messages.count == 1 && workspace.conversation.messages.first?.delivery == .sent
                && workspace.draftCoordinator?.activeDraft?.status == .saved
        }
        XCTAssertEqual(workspace.conversation.messages.first?.id, messageID)
        XCTAssertEqual(workspace.conversation.messages.first?.author, .user)
        XCTAssertEqual(workspace.conversation.messages.first?.body, messageText)
        XCTAssertEqual(workspace.conversation.composerText, "")
        let firstDraft = "  Keep these unsent notes\nwith this bot only — e\u{301}.  "
        workspace.conversation.composerText = firstDraft
        let attachmentModel = workspace.attachmentDraft
        let attachmentID = UUID()
        XCTAssertTrue(attachmentModel.selectFile(
            at: fixture.directory.appendingPathComponent("synthetic-note.txt"), operationID: attachmentID
        ))
        try await referenceWaitUntil {
            if case .ready = attachmentModel.rows.first?.state { return true }
            return false
        }
        let attachmentRows = attachmentModel.rows

        workspace.showBotDetails()
        XCTAssertTrue(workspace.isBotDetailsPresented)
        workspace.editSelectedProfile()
        let editor = try XCTUnwrap(workspace.profileEditor)
        await editor.load()
        editor.displayName = "Ada Local Review"
        editor.title = "Optional label"
        editor.detailedInstructions = "Keep the original sources and report uncertainty."
        workspace.closeBotDetails()
        XCTAssertFalse(workspace.isBotDetailsPresented)
        workspace.showBotDetails()
        workspace.editSelectedProfile()
        XCTAssertTrue(workspace.profileEditor === editor, "Closing details must not cancel unfinished profile edits")
        XCTAssertEqual(editor.displayName, "Ada Local Review")
        let savedProfileResult = await editor.save()
        let savedProfile = try XCTUnwrap(savedProfileResult)
        workspace.profileDidSave(savedProfile)
        XCTAssertEqual(savedProfile.id, first.id)
        XCTAssertEqual(savedProfile.appearance, first.appearance, "Text edits must preserve the existing avatar")
        XCTAssertEqual(workspace.conversation.conversationID, firstChatID)
        XCTAssertTrue(workspace.attachmentDraft === attachmentModel)
        XCTAssertEqual(workspace.attachmentDraft.rows, attachmentRows)
        XCTAssertEqual(workspace.conversation.composerText, firstDraft)

        let search = try XCTUnwrap(workspace.searchCoordinator)
        search.present()
        search.close()
        XCTAssertEqual(workspace.conversation.conversationID, firstChatID)
        XCTAssertEqual(workspace.conversation.composerText, firstDraft)
        XCTAssertTrue(workspace.attachmentDraft === attachmentModel)
        let flushedFirst = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(flushedFirst, true)

        await workspace.createTeammateImmediately()
        let second = try XCTUnwrap(workspace.selectedTeammate)
        let secondChatID = try XCTUnwrap(workspace.conversation.conversationID)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNotEqual(secondChatID, firstChatID)
        XCTAssertEqual(workspace.sidebar.rows.count, 2)
        XCTAssertTrue(workspace.conversation.messages.isEmpty)
        XCTAssertTrue(workspace.attachmentDraft.rows.isEmpty)
        XCTAssertNil(workspace.profileEditor)
        XCTAssertFalse(workspace.isBotDetailsPresented)
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
        let secondDraft = "Second bot's separate draft"
        workspace.conversation.composerText = secondDraft

        workspace.sidebar.selection = first.id.rawValue
        await workspace.selectionTask?.value
        XCTAssertEqual(workspace.conversation.conversationID, firstChatID)
        XCTAssertTrue(workspace.conversation.composerText.utf8.elementsEqual(firstDraft.utf8))
        XCTAssertTrue(workspace.attachmentDraft === attachmentModel)
        XCTAssertEqual(workspace.attachmentDraft.rows, attachmentRows)
        XCTAssertEqual(workspace.conversation.messages.map(\.id), [messageID])
        let flushed = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(flushed, true)
        workspace.finishShutdown()

        // A fresh repository connection and model must restore committed state,
        // not merely the old view's caches. The attachment above is deliberately
        // a presentation-only fixture; this assertion makes no disk-asset claim.
        let reopenedStore = try fixture.open()
        let reopened = fixture.workspace(store: reopenedStore, hiring: hiring)
        defer { reopened.finishShutdown() }
        try await reopened.loadInitialWorkspace()
        try await referenceWaitUntil { reopened.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(reopened.sidebar.selection, first.id.rawValue)
        XCTAssertEqual(reopened.conversation.conversationID, firstChatID)
        XCTAssertTrue(reopened.conversation.composerText.utf8.elementsEqual(firstDraft.utf8))
        XCTAssertEqual(reopened.conversation.messages.map(\.id), [messageID])
        XCTAssertEqual(reopened.conversation.messages.map(\.author), [.user])
        XCTAssertEqual(reopened.selectedTeammate, savedProfile)
        reopened.sidebar.selection = second.id.rawValue
        await reopened.selectionTask?.value
        try await referenceWaitUntil { reopened.draftCoordinator?.activeDraft?.status == .saved }
        XCTAssertEqual(reopened.conversation.composerText, secondDraft)
        XCTAssertTrue(reopened.conversation.messages.isEmpty)
        let interviewCalls = await hiring.calls
        XCTAssertEqual(interviewCalls, 0)
        for table in ["capability_grants", "approvals", "work_runs", "hiring_drafts", "projects", "teams"] {
            let rows = try await reopenedStore.query(sql: "SELECT COUNT(*) AS count FROM \(table)")
            XCTAssertEqual(try rows.first?.integer("count"), 0, "Local creation/profile/save must not create \(table)")
        }
    }
}

/// Disposable local-only backing shared by the flow and hidden native tests.
struct ReferenceLocalWorkspaceFixture {
    let directory: URL
    let protection: ProtectionDecisionReceipt

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextReferenceTests-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)
        ))
    }

    @MainActor
    func workspace(store: SQLiteStore, hiring: ReferenceUnusedHiringService = ReferenceUnusedHiringService(),
                   serviceOverride: (any DurableTeammateChatServing)? = nil) -> DurableWorkspaceModel {
        DurableWorkspaceModel(
            mode: .localOnly,
            service: serviceOverride ?? chatService(store: store),
            hiringService: hiring,
            profileService: TeammateProfileService(repository: store, clock: ReferenceWorkspaceClock()),
            draftService: ConversationDraftService(repository: store, clock: ReferenceWorkspaceClock()),
            searchService: ConversationSearchService(repository: store),
            attachmentImporter: { _, _ in
                // No source read or persistent attachment is performed by this fixture.
                AttachmentDraftPresentationReceipt(displayName: "synthetic-note.txt", byteCount: 42, shortHash: "a1b2c3d4")
            }
        )
    }

    func chatService(store: SQLiteStore) -> DurableTeammateChatService {
        DurableTeammateChatService(
            mode: .localOnly, teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store,
            clock: ReferenceWorkspaceClock()
        )
    }
}

@MainActor
private struct ReferenceCreationScenario {
    let fixture: ReferenceLocalWorkspaceFixture
    let store: SQLiteStore
    let chats: [DurableDirectChatSnapshot]
    let gate: ReferenceCreationGate
    let service: ReferenceHeldCreationService
    let workspace: DurableWorkspaceModel

    init(failsCreation: Bool, seedCount: Int = 1) async throws {
        fixture = try ReferenceLocalWorkspaceFixture()
        store = try fixture.open()
        let seed = fixture.workspace(store: store)
        try await seed.loadInitialWorkspace()
        var seeded: [DurableDirectChatSnapshot] = []
        for _ in 0..<seedCount {
            await seed.createTeammateImmediately()
            let savedSelection = try await fixture.chatService(store: store).selectedDirectChat()
            let selected = try XCTUnwrap(savedSelection)
            seeded.append(DurableDirectChatSnapshot(teammate: selected.teammate, conversation: selected.conversation))
        }
        chats = seeded
        seed.finishShutdown()
        gate = ReferenceCreationGate()
        service = ReferenceHeldCreationService(backing: fixture.chatService(store: store), gate: gate,
                                         failsCreation: failsCreation)
        workspace = fixture.workspace(store: store, serviceOverride: service)
        try await workspace.loadInitialWorkspace()
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
    }

    func close() {
        gate.release()
        workspace.finishShutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }
}

@MainActor
private final class ReferenceCreationGate {
    private(set) var arrivals = 0
    private var released = false
    func wait() async throws {
        arrivals += 1
        let deadline = Date(timeIntervalSinceNow: 3)
        while !released, Date() < deadline {
            // Deliberately ignore cancellation: a repository may already have
            // admitted its commit when the presentation begins shutdown.
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard released else { throw ReferenceWorkspaceTestError.didNotSettle }
    }
    func release() { released = true }
}

private actor ReferenceHeldCreationService: DurableTeammateChatServing {
    private let backing: DurableTeammateChatService
    private let gate: ReferenceCreationGate
    private var failsCreation: Bool
    private var heldLoad: (ConversationID, ReferenceCreationGate)?
    private(set) var attempts = 0
    private(set) var messageLoadCount = 0
    init(backing: DurableTeammateChatService, gate: ReferenceCreationGate, failsCreation: Bool) {
        self.backing = backing; self.gate = gate; self.failsCreation = failsCreation
    }
    func setFailure(_ value: Bool) { failsCreation = value }
    func holdNextLoad(conversationID: ConversationID, gate: ReferenceCreationGate) {
        heldLoad = (conversationID, gate)
    }
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { try await backing.activeDirectChats() }
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? { try await backing.selectedDirectChat() }
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        try await backing.select(teammateID: teammateID, conversationID: conversationID)
    }
    func clearSelection() async throws { try await backing.clearSelection() }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft) async throws -> DurableTeammateChatCreationSnapshot {
        attempts += 1
        try await gate.wait()
        if failsCreation { throw CocoaError(.fileWriteUnknown) }
        return try await backing.createTeammateAndDirectChat(draft)
    }
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        messageLoadCount += 1
        if let heldLoad, heldLoad.0 == conversationID {
            self.heldLoad = nil
            try await heldLoad.1.wait()
        }
        return try await backing.loadMessages(conversationID: conversationID, beforeSequence: beforeSequence, limit: limit)
    }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

private struct ReferenceWorkspaceClock: OpenBotsClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_788_000_000) }
}

actor ReferenceUnusedHiringService: HiringConversationServing {
    private(set) var calls = 0
    func loadOrStart() async throws -> HiringConversationSnapshot { calls += 1; throw CocoaError(.featureUnsupported) }
    func submit(text: String) async throws -> HiringConversationSnapshot { calls += 1; throw CocoaError(.featureUnsupported) }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot {
        calls += 1; throw CocoaError(.featureUnsupported)
    }
    func cancel() async throws { calls += 1; throw CocoaError(.featureUnsupported) }
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot {
        calls += 1; throw CocoaError(.featureUnsupported)
    }
}

@MainActor
func referenceWaitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard predicate() else { throw ReferenceWorkspaceTestError.didNotSettle }
}

enum ReferenceWorkspaceTestError: Error { case didNotSettle }
