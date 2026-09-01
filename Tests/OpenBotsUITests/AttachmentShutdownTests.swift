import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsUI

@Suite("Attachment shutdown admission and late-result fences")
@MainActor
struct AttachmentShutdownTests {
    @Test("Construction and shutdown before load never open a source or repository")
    func inertAndSynchronousAdmission() async throws {
        let storage = AttachmentShutdownStorage()
        let model = makeModel(storage)
        let originalState = model.loadState
        model.beginShutdown()
        #expect(model.isShuttingDown)
        #expect(!model.canSubmit)
        #expect(!model.selectFile(at: selectedURL))
        #expect(throws: AttachmentDraftSubmissionError.unresolvedDraft) { try model.freezeForSubmission() }
        await model.load()
        await model.reload()
        model.removePresentationRow(id: UUID())
        let calls = await storage.calls()
        #expect(calls.loads == 0 && calls.imports == 0 && calls.removes == 0)
        #expect(model.loadState == originalState && model.rows.isEmpty)
        model.finishShutdown()
        model.finishShutdown()
        #expect(await model.settleForShutdown() == false)
    }

    @Test("Already-started imports may settle during grace without new reads or removals")
    func importSettlesDuringGrace() async throws {
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(importGate: gate)
        let model = makeModel(storage)
        await model.load()
        let id = UUID()
        #expect(model.selectFile(at: selectedURL, operationID: id))
        try await waitForGate(gate)
        model.beginShutdown()
        #expect(!model.selectFile(at: selectedURL))
        model.removePresentationRow(id: id)
        let settling = Task { await model.settleForShutdown() }
        await gate.release()
        #expect(await settling.value)
        #expect(model.rows.map(\.id) == [id])
        #expect(model.hasDurableAttachments && !model.canSubmit)
        guard case .ready(let receipt) = model.rows.first?.state else {
            Issue.record("The completed durable receipt should settle before the terminal fence")
            return
        }
        #expect(receipt.asset?.id == AttachmentID(id))
        model.finishShutdown()
        let reopened = makeModel(storage)
        await reopened.load()
        #expect(try reopened.freezeForSubmission().map(\.id) == [AttachmentID(id)])
        let calls = await storage.calls()
        #expect(calls.imports == 1 && calls.removes == 0)
    }

    @Test("A selected import that has not started cannot begin after admission freezes")
    func scheduledImportNeverStarts() async throws {
        let storage = AttachmentShutdownStorage()
        let model = makeModel(storage)
        await model.load()
        #expect(model.selectFile(at: selectedURL))
        model.beginShutdown()
        #expect(await model.settleForShutdown() == false)
        let calls = await storage.calls()
        #expect(calls.imports == 0 && calls.removes == 0)
        model.finishShutdown()
    }

    @Test("Terminal shutdown releases a stalled wait and ignores a late durable success")
    func stalledImportLateSuccess() async throws {
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(importGate: gate)
        let model = makeModel(storage)
        await model.load()
        let id = UUID()
        #expect(model.selectFile(at: selectedURL, operationID: id))
        try await waitForGate(gate)
        model.beginShutdown()
        let settling = Task { await model.settleForShutdown() }
        await drain()
        let frozenRows = model.rows
        model.finishShutdown()
        #expect(await settling.value == false)
        #expect(await gate.isWaiting)
        await gate.release()
        try await waitForImportCompletion(storage)
        await drain()
        #expect(model.rows == frozenRows)
        #expect(!model.hasDurableAttachments)
        let calls = await storage.calls()
        #expect(calls.sawCancelledImport && calls.removes == 0)
        // Cancellation is not rollback: a non-cooperative adapter may already
        // have committed its exact durable link. Reopen reads that saved fact.
        let reopened = makeModel(storage)
        await reopened.load()
        #expect(try reopened.freezeForSubmission().map(\.id) == [AttachmentID(id)])
    }

    @Test("Late importer failure cannot publish an error or trigger cleanup after terminal shutdown")
    func stalledImportLateFailure() async throws {
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(importGate: gate, failImportAfterCommit: true)
        let model = makeModel(storage)
        await model.load()
        let id = UUID()
        #expect(model.selectFile(at: selectedURL, operationID: id))
        try await waitForGate(gate)
        model.removePresentationRow(id: id)
        model.beginShutdown()
        let frozenRows = model.rows
        model.finishShutdown()
        await gate.release()
        try await waitForImportCompletion(storage)
        await drain()
        #expect(model.rows == frozenRows)
        #expect(!model.hasDurableAttachments)
        let calls = await storage.calls()
        #expect(calls.removes == 0)
        #expect(await storage.savedIDs() == [AttachmentID(id)])
    }

    @Test("An earlier cancelled import cannot start compensating removal during shutdown")
    func cancelledImportDoesNotStartRemoval() async throws {
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(importGate: gate)
        let model = makeModel(storage)
        await model.load()
        let id = UUID()
        #expect(model.selectFile(at: selectedURL, operationID: id))
        try await waitForGate(gate)
        model.removePresentationRow(id: id)
        #expect(model.rows.first?.isRemoving == true)
        model.beginShutdown()
        let settling = Task { await model.settleForShutdown() }
        await gate.release()
        #expect(await settling.value == false, "The removal intention did not complete; never claim fully settled")
        #expect(await storage.savedIDs() == [AttachmentID(id)])
        let calls = await storage.calls()
        #expect(calls.removes == 0)
        model.finishShutdown()
    }

    @Test("An already-running exact removal may settle, but a scheduled removal may not start")
    func removalAdmissionAndGrace() async throws {
        let asset = try makeAsset()
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(assets: [asset], removalGate: gate)
        let model = makeModel(storage)
        await model.load()
        model.removePresentationRow(id: asset.id.rawValue)
        try await waitForGate(gate)
        model.beginShutdown()
        let settling = Task { await model.settleForShutdown() }
        await gate.release()
        #expect(await settling.value)
        #expect(model.rows.isEmpty && !model.hasDurableAttachments)
        model.finishShutdown()

        let scheduledStorage = AttachmentShutdownStorage(assets: [asset])
        let scheduled = makeModel(scheduledStorage)
        await scheduled.load()
        scheduled.removePresentationRow(id: asset.id.rawValue)
        scheduled.beginShutdown()
        #expect(await scheduled.settleForShutdown() == false)
        #expect(await scheduledStorage.savedIDs() == [asset.id])
        let calls = await scheduledStorage.calls()
        #expect(calls.removes == 0)
        scheduled.finishShutdown()
    }

    @Test("An exact removal already underway may commit late but cannot change frozen presentation")
    func lateRemovalCompletionIsFenced() async throws {
        let asset = try makeAsset()
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(assets: [asset], removalGate: gate)
        let model = makeModel(storage)
        await model.load()
        model.removePresentationRow(id: asset.id.rawValue)
        try await waitForGate(gate)
        model.beginShutdown()
        let settling = Task { await model.settleForShutdown() }
        await drain()
        let frozenRows = model.rows
        model.finishShutdown()
        #expect(await settling.value == false)
        await gate.release()
        try await eventually { await storage.calls().completedRemoves == 1 }
        await drain()
        #expect(model.rows == frozenRows && model.hasDurableAttachments)
        #expect(await storage.savedIDs().isEmpty)
        let calls = await storage.calls()
        #expect(calls.removes == 1)
    }

    @Test("Late read-only load cannot publish a draft or trigger a reload after admission freezes")
    func lateLoadIsFenced() async throws {
        let asset = try makeAsset()
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(assets: [asset], loadGate: gate)
        let model = makeModel(storage)
        let loading = Task { await model.load() }
        try await waitForGate(gate)
        model.beginShutdown()
        let stateAtFreeze = model.loadState
        model.finishShutdown()
        await gate.release()
        await loading.value
        await model.reload()
        #expect(model.rows.isEmpty && !model.hasDurableAttachments)
        #expect(model.loadState == stateAtFreeze)
        let calls = await storage.calls()
        #expect(calls.loads == 1)
    }

    @Test("Cancelling a settlement waiter neither retries nor waits for a stuck importer")
    func cancelledWaiterReturnsWithoutCleanup() async throws {
        let gate = AttachmentShutdownGate()
        let storage = AttachmentShutdownStorage(importGate: gate)
        let model = makeModel(storage)
        await model.load()
        #expect(model.selectFile(at: selectedURL))
        try await waitForGate(gate)
        model.beginShutdown()
        let settling = Task { await model.settleForShutdown() }
        await drain()
        settling.cancel()
        #expect(await settling.value == false)
        #expect(await gate.isWaiting)
        model.finishShutdown()
        await gate.release()
        try await waitForImportCompletion(storage)
        let calls = await storage.calls()
        #expect(calls.imports == 1 && calls.removes == 0)
    }

    @Test("Coordinator blocks stale picker, activation and new sends synchronously")
    func coordinatorAdmission() async throws {
        let asset = try makeAsset()
        let storage = AttachmentShutdownStorage(assets: [asset])
        let model = makeModel(storage)
        let conversation = ConversationModel(conversationID: conversationID.rawValue,
                                             composerText: "Unsent caption", submit: { _, _, _ in })
        var factoryCalls = 0
        let coordinator = WorkspaceAttachmentCoordinator(conversation: conversation) { _ in
            factoryCalls += 1
            return model
        }
        _ = coordinator.activate(conversationID.rawValue)
        await model.load()
        await drain()
        #expect(conversation.canSend)
        let picker = AttachmentPickerRequest(draft: model)
        coordinator.beginShutdown()
        #expect(coordinator.isShuttingDown && model.isShuttingDown)
        #expect(!conversation.canSend)
        #expect(!picker.consume(selectedURL))
        #expect(!picker.consume(selectedURL))
        #expect(coordinator.activate(UUID()) == nil)
        #expect(coordinator.activate(conversationID.rawValue) == nil)
        #expect(coordinator.begin(messageID: UUID(), conversationID: conversationID.rawValue) == nil)
        #expect(factoryCalls == 1)
        #expect(await coordinator.settleForShutdown())
        coordinator.finishShutdown()
        await drain()
        #expect(!conversation.canSend)
        #expect(model.rows.count == 1 && model.hasDurableAttachments)
        let calls = await storage.calls()
        #expect(calls.imports == 0 && calls.removes == 0)
    }

    @Test("A pre-existing submission may settle during grace without starting a remover")
    func coordinatorExistingSubmissionSettles() async throws {
        let asset = try makeAsset()
        let storage = AttachmentShutdownStorage(assets: [asset])
        let model = makeModel(storage)
        let conversation = ConversationModel(conversationID: conversationID.rawValue, submit: { _, _, _ in })
        let coordinator = WorkspaceAttachmentCoordinator(conversation: conversation, factory: { _ in model })
        _ = coordinator.activate(conversationID.rawValue)
        await model.load()
        let messageID = UUID()
        #expect(coordinator.begin(messageID: messageID, conversationID: conversationID.rawValue) == [asset])
        coordinator.beginShutdown()
        let settling = Task { await coordinator.settleForShutdown() }
        await drain()
        #expect(coordinator.assets(messageID: messageID) == [asset])
        coordinator.finish(messageID: messageID, committed: true)
        #expect(await settling.value)
        #expect(model.rows.isEmpty)
        coordinator.finishShutdown()
        let calls = await storage.calls()
        #expect(calls.removes == 0)
    }

    @Test("Terminal coordinator fence ignores late submission acknowledgments and releases waiters")
    func coordinatorLateSubmissionIsFenced() async throws {
        let asset = try makeAsset()
        let storage = AttachmentShutdownStorage(assets: [asset])
        let model = makeModel(storage)
        let conversation = ConversationModel(conversationID: conversationID.rawValue, submit: { _, _, _ in })
        let coordinator = WorkspaceAttachmentCoordinator(conversation: conversation, factory: { _ in model })
        _ = coordinator.activate(conversationID.rawValue)
        await model.load()
        let messageID = UUID()
        #expect(coordinator.begin(messageID: messageID, conversationID: conversationID.rawValue) == [asset])
        coordinator.beginShutdown()
        let settling = Task { await coordinator.settleForShutdown() }
        await drain()
        let frozenRows = model.rows
        coordinator.finishShutdown()
        #expect(await settling.value == false)
        coordinator.finish(messageID: messageID, committed: true)
        model.acknowledgeSubmitted(ids: [asset.id])
        #expect(coordinator.assets(messageID: messageID).isEmpty)
        #expect(model.rows == frozenRows && model.hasDurableAttachments)
        #expect(!conversation.canSend)
        let calls = await storage.calls()
        #expect(calls.removes == 0)
    }

    private var conversationID: ConversationID { attachmentShutdownConversation }
    private var selectedURL: URL { URL(fileURLWithPath: "/private/tmp/OpenBots-shutdown-synthetic.txt") }

    private func makeModel(_ storage: AttachmentShutdownStorage) -> AttachmentDraftModel {
        AttachmentDraftModel(conversationID: conversationID,
                             load: { await storage.load() },
                             importFile: { _, id in try await storage.importFile(id) },
                             remove: { id in await storage.remove(id) })
    }

    private func makeAsset() throws -> AttachmentAsset { try shutdownAsset(UUID()) }
    private func drain() async { for _ in 0..<50 { await Task.yield() } }
    private func waitForGate(_ gate: AttachmentShutdownGate) async throws {
        try await eventually { await gate.isWaiting }
    }
    private func waitForImportCompletion(_ storage: AttachmentShutdownStorage) async throws {
        try await eventually { await storage.calls().completedImports == 1 }
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            await Task.yield()
        }
        throw AttachmentShutdownTestError.operationDidNotReachGate
    }
}

private let attachmentShutdownConversation = ConversationID(
    UUID(uuidString: "BA000000-0000-0000-0000-000000000001")!
)

private func shutdownAsset(_ id: UUID) throws -> AttachmentAsset {
    try AttachmentAsset(id: AttachmentID(id), conversationID: attachmentShutdownConversation,
                        displayName: "saved.txt", typeIdentifier: "public.plain-text", byteCount: 1,
                        sha256: String(repeating: "a", count: 64), createdAt: Date(timeIntervalSince1970: 123))
}

private enum AttachmentShutdownTestError: Error { case operationDidNotReachGate, importFailed }

/// Deliberately ignores task cancellation so tests do not mistake Task.cancel
/// for undoing a durable commit or stopping arbitrary injected adapter code.
private actor AttachmentShutdownGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AttachmentShutdownStorage {
    struct Calls: Sendable {
        let loads: Int, imports: Int, removes: Int, completedImports: Int, completedRemoves: Int
        let sawCancelledImport: Bool
    }
    private var assets: [AttachmentAsset]
    private let importGate: AttachmentShutdownGate?
    private let removalGate: AttachmentShutdownGate?
    private let loadGate: AttachmentShutdownGate?
    private let failImportAfterCommit: Bool
    private var loads = 0, imports = 0, removes = 0, completedImports = 0, completedRemoves = 0
    private var sawCancelledImport = false

    init(assets: [AttachmentAsset] = [], importGate: AttachmentShutdownGate? = nil,
         removalGate: AttachmentShutdownGate? = nil, loadGate: AttachmentShutdownGate? = nil,
         failImportAfterCommit: Bool = false) {
        self.assets = assets
        self.importGate = importGate
        self.removalGate = removalGate
        self.loadGate = loadGate
        self.failImportAfterCommit = failImportAfterCommit
    }

    func load() async -> AttachmentDraftSnapshot {
        loads += 1
        await loadGate?.wait()
        return snapshot()
    }
    func importFile(_ id: UUID) async throws -> AttachmentAsset {
        imports += 1
        await importGate?.wait()
        sawCancelledImport = Task.isCancelled
        let asset = try shutdownAsset(id)
        assets.append(asset)
        completedImports += 1
        if failImportAfterCommit { throw AttachmentShutdownTestError.importFailed }
        return asset
    }
    func remove(_ id: AttachmentID) async -> AttachmentDraftSnapshot {
        removes += 1
        await removalGate?.wait()
        assets.removeAll { $0.id == id }
        completedRemoves += 1
        return snapshot()
    }
    func savedIDs() -> [AttachmentID] { assets.map(\.id) }
    func calls() -> Calls {
        Calls(loads: loads, imports: imports, removes: removes, completedImports: completedImports,
              completedRemoves: completedRemoves, sawCancelledImport: sawCancelledImport)
    }
    private func snapshot() -> AttachmentDraftSnapshot {
        AttachmentDraftSnapshot(conversationID: attachmentShutdownConversation, revision: 1, attachments: assets)
    }
}
