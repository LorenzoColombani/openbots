import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsPersistence
@testable import OpenBotsUI

@MainActor
final class BotSidebarOrderWorkspaceTests: XCTestCase {
    func testNewBotAppearsFirstImmediatelyAndAfterReopenWithoutReorderingExistingOrArchivedBots() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 3)
        await workspace.archiveSelectedBot()
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        let archivedBefore = try await store.archivedTeammates()
        let initial = workspace.sidebar.rows.map(\.id)
        let existingOrder = Array(initial.reversed())
        await workspace.sidebarOrderCoordinator?.reorder(existingOrder, fromSnapshot: initial)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), existingOrder)
        workspace.sidebar.selection = existingOrder[0]
        await workspace.selectionTask?.value
        try await draftReady(workspace)
        let oldChat = try XCTUnwrap(workspace.conversation.conversationID)
        let oldRows = workspace.sidebar.rowModels
        let draft = "  Preserve this draft while a new bot is created\n café  "
        workspace.conversation.composerText = draft

        await workspace.createTeammateImmediately()
        XCTAssertNil(workspace.creationError)
        let createdID = try XCTUnwrap(workspace.sidebar.selection)
        XCTAssertEqual(workspace.sidebar.creationRevealID, createdID)
        XCTAssertFalse(existingOrder.contains(createdID))
        let expected = [createdID] + existingOrder
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), expected)
        assertSameRows(oldRows, in: workspace.sidebar)
        let savedOrder = try await store.loadBotSidebarOrder()
        let archivedAfter = try await store.archivedTeammates()
        XCTAssertEqual(savedOrder.teammateIDs.map(\.rawValue), expected)
        XCTAssertEqual(archivedAfter, archivedBefore)

        workspace.sidebar.selection = existingOrder[0]
        await workspace.selectionTask?.value
        try await draftReady(workspace)
        XCTAssertEqual(workspace.conversation.conversationID, oldChat)
        XCTAssertEqual(workspace.conversation.composerText, draft)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), expected)
        let flushed = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(flushed, true)
        workspace.finishShutdown()

        let reopened = try fixture.open()
        let reloaded = makeWorkspace(fixture, store: reopened)
        defer { reloaded.finishShutdown() }
        try await reloaded.loadInitialWorkspace()
        try await draftReady(reloaded)
        XCTAssertNil(reloaded.sidebar.creationRevealID, "Reopening a saved roster is not a creation reveal.")
        XCTAssertEqual(reloaded.sidebar.rows.map(\.id), expected)
        XCTAssertEqual(reloaded.conversation.conversationID, oldChat)
        XCTAssertEqual(reloaded.conversation.composerText, draft)
        let archivedReopened = try await reopened.archivedTeammates()
        XCTAssertEqual(archivedReopened, archivedBefore)
    }

    func testDelayedOrderConfirmationKeepsNewBotAtTopAndRestoredBotAtBottom() async throws {
        for action in [MembershipAction.create, .restore] {
            try await exerciseMembershipChange(action, delay: .confirmationLoadResponse)
        }
    }

    func testShutdownSynchronouslyCancelsPendingCreationRevealWithoutChangingRowsOrSelection() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 1)
        let selected = try XCTUnwrap(workspace.sidebar.selection)
        let rows = workspace.sidebar.rowModels
        XCTAssertEqual(workspace.sidebar.creationRevealID, selected)

        workspace.beginShutdown()
        XCTAssertNil(workspace.sidebar.creationRevealID, "Cancel before the mounted List can resume its yielded scroll.")
        XCTAssertEqual(workspace.sidebar.selection, selected)
        assertSameRows(rows, in: workspace.sidebar)
        await workspace.createTeammateImmediately()
        XCTAssertNil(workspace.sidebar.creationRevealID)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), rows.map(\.id))
    }

    func testNativeModelMoveCallbackKeepsChatDraftEditorAndRowsThenReloadsSavedOrder() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 3)
        let original = workspace.sidebar.rows.map(\.id)
        let moved = [original[2], original[0], original[1]]
        let selected = workspace.sidebar.selection
        let chat = try XCTUnwrap(workspace.conversation.conversationID)
        let conversationModel = workspace.conversation
        let rowModels = workspace.sidebar.rowModels
        let teammates = try await store.listTeammates(includingArchived: true)
        let draft = "  Keep café 🦊 e\u{301}\nexact\0bytes\t  "
        workspace.conversation.composerText = draft
        workspace.editSelectedProfile()
        let editor = try XCTUnwrap(workspace.profileEditor)
        await editor.load()
        editor.displayName = "Unfinished name, not saved by a drag"

        XCTAssertTrue(workspace.sidebar.requestOrderMove(ids: moved, fromSnapshot: original))
        XCTAssertTrue(workspace.sidebar.isOrderSaving)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), original, "Do not show an unconfirmed order")
        try await referenceWaitUntil { !workspace.sidebar.isOrderSaving }

        XCTAssertNil(workspace.sidebar.orderError)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), moved)
        XCTAssertEqual(workspace.sidebar.selection, selected)
        XCTAssertTrue(workspace.conversation === conversationModel)
        XCTAssertEqual(workspace.conversation.conversationID, chat)
        XCTAssertEqual(workspace.conversation.composerText, draft)
        XCTAssertTrue(workspace.profileEditor === editor)
        XCTAssertEqual(editor.displayName, "Unfinished name, not saved by a drag")
        XCTAssertTrue(editor.hasUnsavedChanges)
        assertSameRows(rowModels, in: workspace.sidebar)
        let unchangedTeammates = try await store.listTeammates(includingArchived: true)
        XCTAssertEqual(unchangedTeammates, teammates)
        let flushed = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(flushed, true)
        workspace.finishShutdown()

        // New connection and new workspace exercise the actual roster loader,
        // rather than replaying an in-memory sorted array.
        let reopened = try fixture.open()
        let reloaded = makeWorkspace(fixture, store: reopened)
        defer { reloaded.finishShutdown() }
        try await reloaded.loadInitialWorkspace()
        try await draftReady(reloaded)
        XCTAssertEqual(reloaded.sidebar.rows.map(\.id), moved)
        XCTAssertEqual(reloaded.sidebar.selection, selected)
        XCTAssertEqual(reloaded.conversation.conversationID, chat)
        XCTAssertEqual(reloaded.conversation.composerText, draft)
        XCTAssertNil(reloaded.profileEditor, "The drag must not save unfinished profile edits")
    }

    func testDelayedSaveResponseCannotOverwriteNewerSelectionOrTyping() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let gate = SidebarOrderWorkspaceGate()
        defer { gate.release() }
        let service = ControlledSidebarOrderService(repository: store, gate: gate, delay: .saveResponse)
        let workspace = makeWorkspace(fixture, store: store, ordering: service)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 3)
        let original = workspace.sidebar.rows.map(\.id)
        workspace.sidebar.selection = original[0]
        await workspace.selectionTask?.value
        try await draftReady(workspace)
        let firstChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        workspace.conversation.composerText = "First chat's pending draft"
        let models = workspace.sidebar.rowModels
        XCTAssertTrue(workspace.sidebar.requestOrderMove(ids: Array(original.reversed()), fromSnapshot: original))
        try await referenceWaitUntil { gate.isWaiting }
        XCTAssertTrue(workspace.sidebar.isOrderSaving)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), original)

        workspace.sidebar.selection = original[2]
        await workspace.selectionTask?.value
        try await draftReady(workspace)
        let newerChat = ConversationID(try XCTUnwrap(workspace.conversation.conversationID))
        let newerDraft = "  Newer selection — still typing\n\0résumé  "
        workspace.conversation.composerText = newerDraft
        let conversationModel = workspace.conversation
        gate.release()
        try await referenceWaitUntil { !workspace.sidebar.isOrderSaving }

        XCTAssertNil(workspace.sidebar.orderError)
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), Array(original.reversed()))
        XCTAssertEqual(workspace.sidebar.selection, original[2])
        XCTAssertTrue(workspace.conversation === conversationModel)
        XCTAssertEqual(workspace.conversation.conversationID, newerChat.rawValue)
        XCTAssertEqual(workspace.conversation.composerText, newerDraft)
        assertSameRows(models, in: workspace.sidebar)
        let flushed = await workspace.draftCoordinator?.flushAll()
        XCTAssertEqual(flushed, true)
        let savedSelection = try await store.selectedConversationID()
        let firstDraft = try await store.loadDraft(conversationID: firstChat)
        let savedNewerDraft = try await store.loadDraft(conversationID: newerChat)
        XCTAssertEqual(savedSelection, newerChat)
        XCTAssertEqual(firstDraft?.text, "First chat's pending draft")
        XCTAssertEqual(savedNewerDraft?.text, newerDraft)
    }

    func testFailedSaveKeepsConfirmedRowsChatAndDraftAndExplainsFailure() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let service = ControlledSidebarOrderService(repository: store, failsSave: true)
        let workspace = makeWorkspace(fixture, store: store, ordering: service)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 2)
        let original = workspace.sidebar.rows.map(\.id)
        let confirmed = try await store.loadBotSidebarOrder()
        let selected = workspace.sidebar.selection
        let chat = workspace.conversation.conversationID
        let models = workspace.sidebar.rowModels
        workspace.conversation.composerText = "Keep this draft despite disk failure"

        XCTAssertTrue(workspace.sidebar.requestOrderMove(ids: Array(original.reversed()), fromSnapshot: original))
        try await referenceWaitUntil { !workspace.sidebar.isOrderSaving }

        XCTAssertEqual(workspace.sidebar.rows.map(\.id), original)
        XCTAssertEqual(workspace.sidebar.selection, selected)
        XCTAssertEqual(workspace.conversation.conversationID, chat)
        XCTAssertEqual(workspace.conversation.composerText, "Keep this draft despite disk failure")
        XCTAssertTrue(workspace.sidebar.orderError?.contains("Couldn’t save") == true)
        XCTAssertTrue(workspace.sidebar.canReorder)
        assertSameRows(models, in: workspace.sidebar)
        let unchanged = try await store.loadBotSidebarOrder()
        XCTAssertEqual(unchanged, confirmed)
    }

    func testConcurrentCreateArchiveAndRestoreWhileInitialOrderLoadIsDelayed() async throws {
        for action in MembershipAction.allCases {
            try await exerciseMembershipChange(action, delay: .firstLoadResponse)
        }
    }

    func testConcurrentCreateArchiveAndRestoreWhileSavedResponseIsDelayed() async throws {
        for action in MembershipAction.allCases {
            try await exerciseMembershipChange(action, delay: .saveResponse)
        }
    }

    func testHiringStartsBeforeQueuedReorderTaskDoesNotLeaveSavingStateStuck() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let workspace = makeWorkspace(fixture, store: store)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 2)
        let original = workspace.sidebar.rows.map(\.id)
        let before = try await store.loadBotSidebarOrder()
        XCTAssertTrue(workspace.sidebar.requestOrderMove(ids: Array(original.reversed()), fromSnapshot: original))
        // Both calls run on this MainActor turn; the reorder task has not yet
        // run when the workspace becomes temporarily unavailable for moves.
        workspace.beginHiringFixture()
        XCTAssertNotNil(workspace.hiringModel)
        try await referenceWaitUntil { !workspace.sidebar.isOrderSaving }
        XCTAssertEqual(workspace.sidebar.rows.map(\.id), original)
        let unchanged = try await store.loadBotSidebarOrder()
        XCTAssertEqual(unchanged, before)
    }

    private func exerciseMembershipChange(_ action: MembershipAction, delay: ControlledSidebarOrderService.Delay) async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let gate = SidebarOrderWorkspaceGate()
        defer { gate.release() }
        let service = ControlledSidebarOrderService(repository: store, gate: gate, delay: delay)
        let workspace = makeWorkspace(fixture, store: store, ordering: service)
        defer { workspace.finishShutdown() }
        try await seed(workspace, count: 3)
        var archivedForRestore: Teammate?
        if action == .restore {
            await workspace.archiveSelectedBot()
            archivedForRestore = try XCTUnwrap(workspace.archiveModel?.archivedBots.first)
            workspace.sidebar.selection = workspace.sidebar.rows.first?.id
            await workspace.selectionTask?.value
            try await draftReady(workspace)
        }
        let original = workspace.sidebar.rows.map(\.id)
        let models = workspace.sidebar.rowModels
        workspace.conversation.composerText = "Pending draft during \(action)"
        XCTAssertTrue(workspace.sidebar.requestOrderMove(ids: Array(original.reversed()), fromSnapshot: original))
        try await referenceWaitUntil { gate.isWaiting }

        switch action {
        case .create: await workspace.createTeammateImmediately()
        case .archive: await workspace.archiveSelectedBot()
        case .restore: await workspace.restoreBot(try XCTUnwrap(archivedForRestore))
        }
        XCTAssertNil(workspace.creationError)
        XCTAssertNil(workspace.archiveModel?.errorMessage)
        if workspace.conversation.conversationID != nil {
            try await draftReady(workspace)
            workspace.conversation.composerText = "Newer draft after \(action)"
        }
        let afterMembershipIDs = Set(workspace.sidebar.rows.map(\.id))
        let newerSelection = workspace.sidebar.selection
        let newerChat = workspace.conversation.conversationID
        let newerDraft = workspace.conversation.composerText
        gate.release()
        try await referenceWaitUntil { !workspace.sidebar.isOrderSaving }

        let confirmed = try await store.loadBotSidebarOrder()
        let finalIDs = workspace.sidebar.rows.map(\.id)
        XCTAssertEqual(finalIDs, confirmed.teammateIDs.map(\.rawValue), "\(action) / \(delay)")
        XCTAssertEqual(Set(finalIDs), afterMembershipIDs)
        XCTAssertEqual(finalIDs.count, Set(finalIDs).count)
        XCTAssertEqual(workspace.sidebar.selection, newerSelection)
        XCTAssertEqual(workspace.conversation.conversationID, newerChat)
        XCTAssertEqual(workspace.conversation.composerText, newerDraft)
        for prior in models where finalIDs.contains(prior.id) {
            XCTAssertTrue(workspace.sidebar.rowModels.first(where: { $0.id == prior.id }) === prior)
        }
        let saveCalls = await service.saveCalls
        if delay == .firstLoadResponse {
            XCTAssertEqual(saveCalls, 0)
            XCTAssertTrue(workspace.sidebar.orderError?.contains("bot list changed") == true)
        } else {
            XCTAssertEqual(saveCalls, 1)
            XCTAssertNil(workspace.sidebar.orderError)
        }
    }

    private func makeWorkspace(_ fixture: ReferenceLocalWorkspaceFixture, store: SQLiteStore,
                               ordering: (any BotSidebarOrdering)? = nil) -> DurableWorkspaceModel {
        DurableWorkspaceModel(service: fixture.chatService(store: store), hiringService: ReferenceUnusedHiringService(),
            profileService: TeammateProfileService(repository: store),
            archiveService: TeammateArchiveService(repository: store),
            sidebarOrderService: ordering ?? BotSidebarOrderService(repository: store),
            draftService: ConversationDraftService(repository: store))
    }

    private func seed(_ workspace: DurableWorkspaceModel, count: Int) async throws {
        try await workspace.loadInitialWorkspace()
        for _ in 0..<count {
            await workspace.createTeammateImmediately()
            XCTAssertNil(workspace.creationError)
            try await draftReady(workspace)
        }
    }

    private func draftReady(_ workspace: DurableWorkspaceModel) async throws {
        try await referenceWaitUntil { workspace.draftCoordinator?.activeDraft?.status == .saved }
    }

    private func assertSameRows(_ originals: [TeammateRowModel], in sidebar: SidebarModel,
                                file: StaticString = #filePath, line: UInt = #line) {
        for row in originals {
            XCTAssertTrue(sidebar.rowModels.first(where: { $0.id == row.id }) === row, file: file, line: line)
        }
    }
}

private enum MembershipAction: CaseIterable { case create, archive, restore }

@MainActor
private final class SidebarOrderWorkspaceGate {
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

private actor ControlledSidebarOrderService: BotSidebarOrdering {
    enum Delay { case firstLoadResponse, saveResponse, confirmationLoadResponse }
    let repository: any BotSidebarOrderRepository
    let gate: SidebarOrderWorkspaceGate?
    let delay: Delay?
    let failsSave: Bool
    private var loadCalls = 0
    private(set) var saveCalls = 0

    init(repository: any BotSidebarOrderRepository, gate: SidebarOrderWorkspaceGate? = nil,
         delay: Delay? = nil, failsSave: Bool = false) {
        self.repository = repository
        self.gate = gate
        self.delay = delay
        self.failsSave = failsSave
    }

    func loadOrder() async throws -> BotSidebarOrder {
        loadCalls += 1
        let number = loadCalls
        let snapshot = try await repository.loadBotSidebarOrder()
        if delay == .firstLoadResponse, number == 1 { await gate?.wait() }
        if delay == .confirmationLoadResponse, number == 2 { await gate?.wait() }
        return snapshot
    }

    func saveOrder(_ ids: [TeammateID], expectedRevision: UInt64) async throws -> BotSidebarOrder {
        saveCalls += 1
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        let saved = try await repository.saveBotSidebarOrder(ids, expectedRevision: expectedRevision)
        if delay == .saveResponse { await gate?.wait() }
        return saved
    }
}
