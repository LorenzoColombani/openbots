import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@MainActor
@Suite("Frozen draft shutdown")
struct DraftShutdownTests {
    @Test("Shutdown freezes exact available text and permits only one save pass")
    func frozenTextAndDuplicateCalls() async throws {
        let id = ConversationID(UUID())
        let service = ShutdownDraftService()
        let model = draft(id, service)
        await model.load()
        let raw = " \tCafe\u{301}\0saved at close\n"
        model.setText(raw)
        model.beginShutdown()
        model.setText("Rejected after close")
        model.beginShutdown()
        #expect(model.isShuttingDown && !model.canBeginSubmission)
        #expect(model.beginSubmission(messageID: UUID(), rawText: raw) == nil)
        #expect(!(await model.flush()))
        let first = Task { await model.flushForShutdown() }
        let duplicate = Task { await model.flushForShutdown() }
        #expect(await first.value)
        #expect(await duplicate.value)
        #expect(await model.flushForShutdown())
        let receipt = await service.receipt()
        #expect(receipt.writes.count == 1)
        #expect(receipt.saved[id]?.text.utf8.elementsEqual(raw.utf8) == true)
        #expect(model.text.utf8.elementsEqual(raw.utf8))
        #expect(model.status == .saved && !model.hasUnsavedChanges)
        model.finishShutdown()
        model.finishShutdown()
        #expect(!(await model.flushForShutdown()))
    }

    @Test("Unavailable initial state never causes a new load or an empty overwrite")
    func noNewLoadForUnavailableState() async {
        let service = ShutdownDraftService()
        let model = draft(ConversationID(UUID()), service)
        model.setText("Known unsaved text, unknown saved revision")
        model.beginShutdown()
        await model.load()
        #expect(!(await model.flushForShutdown()))
        #expect(model.text == "Known unsaved text, unknown saved revision")
        let receipt = await service.receipt()
        #expect(receipt.loads == 0 && receipt.writes.isEmpty)
        model.finishShutdown()
    }

    @Test("An already-started load cannot turn its empty placeholder into a tombstone")
    func loadedPlaceholderIsNotEmptyAuthority() async throws {
        let id = ConversationID(UUID())
        let gate = ShutdownDraftGate()
        let service = ShutdownDraftService(saved: [try snapshot(id, "Existing saved text", 4)], loadGate: gate)
        let model = draft(id, service)
        let loading = Task { await model.load() }
        await gate.waitUntilEntered()
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        await gate.release()
        await loading.value
        #expect(!(await closing.value))
        #expect(model.text == "Existing saved text")
        let receipt = await service.receipt()
        #expect(receipt.writes.isEmpty && receipt.saved[id]?.revision == 4)
        model.finishShutdown()
    }

    @Test("Late noncooperative load completion cannot publish after terminal shutdown")
    func terminalFencesLateLoad() async throws {
        let id = ConversationID(UUID())
        let gate = ShutdownDraftGate()
        let service = ShutdownDraftService(saved: [try snapshot(id, "Late old text", 2)], loadGate: gate)
        let model = draft(id, service)
        let loading = Task { await model.load() }
        await gate.waitUntilEntered()
        model.beginShutdown()
        model.finishShutdown()
        let status = model.status
        await gate.release()
        await loading.value
        #expect(model.text.isEmpty && !model.isLoaded && model.status == status)
        await model.load()
        #expect(!(await model.flushForShutdown()))
        let receipt = await service.receipt()
        #expect(receipt.loads == 1 && receipt.writes.isEmpty)
    }

    @Test("Late save may atomically commit but cannot publish success or start a successor after finish")
    func terminalFencesLateSave() async {
        let id = ConversationID(UUID())
        let gate = ShutdownDraftGate()
        let service = ShutdownDraftService(saveGate: gate)
        let model = draft(id, service)
        await model.load()
        model.setText("Older issued write")
        let ordinary = Task { await model.flush() }
        await gate.waitUntilEntered()
        model.setText("Newer frozen text")
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        model.finishShutdown()
        let status = model.status
        await gate.release()
        #expect(!(await ordinary.value))
        #expect(!(await closing.value))
        #expect(model.status == status && model.text == "Newer frozen text")
        #expect(model.hasUnsavedChanges)
        let receipt = await service.receipt()
        #expect(receipt.writes.map(\.text) == ["Older issued write"])
        #expect(receipt.saved[id]?.text == "Older issued write", "Cancellation is not proof an already-issued atomic save did not commit.")
    }

    @Test("Grace joins an older issued write then saves the frozen successor once")
    func frozenSuccessorAfterOlderSave() async {
        let id = ConversationID(UUID())
        let gate = ShutdownDraftGate()
        let service = ShutdownDraftService(saveGate: gate)
        let model = draft(id, service)
        await model.load()
        model.setText("Older")
        let ordinary = Task { await model.flush() }
        await gate.waitUntilEntered()
        model.setText("Frozen successor")
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        await gate.release()
        #expect(!(await ordinary.value))
        #expect(await closing.value)
        #expect(await model.flushForShutdown())
        let receipt = await service.receipt()
        #expect(receipt.writes.map(\.text) == ["Older", "Frozen successor"])
        #expect(receipt.writes.map(\.expectedRevision) == [0, 1])
        #expect(model.status == .saved)
        model.finishShutdown()
    }

    @Test("Already-persisted submission may settle during grace and preserve newer frozen typing")
    func submittedMessageSettlesDuringGrace() async throws {
        let id = ConversationID(UUID())
        let service = ShutdownDraftService()
        let model = draft(id, service)
        await model.load()
        model.setText("Captured message")
        let token = try #require(model.beginSubmission(messageID: UUID(), rawText: model.text))
        #expect(await model.persistSubmission(token))
        model.setText("Next unsent draft")
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        #expect(await model.completeSubmission(token))
        #expect(await closing.value)
        let receipt = await service.receipt()
        #expect(receipt.writes.map(\.text) == ["Captured message", "Next unsent draft"])
        #expect(model.text == "Next unsent draft" && !model.isSubmissionInFlight)
        model.finishShutdown()
    }

    @Test("An already-issued submission safety save may settle during grace before its completion")
    func submissionSaveSettlesDuringGrace() async throws {
        let id = ConversationID(UUID())
        let gate = ShutdownDraftGate()
        let service = ShutdownDraftService(saveGate: gate)
        let model = draft(id, service)
        await model.load()
        model.setText("Captured message")
        let token = try #require(model.beginSubmission(messageID: UUID(), rawText: model.text))
        let persisting = Task { await model.persistSubmission(token) }
        await gate.waitUntilEntered()
        model.setText("Frozen next draft")
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        await gate.release()
        #expect(await persisting.value)
        #expect(await model.completeSubmission(token))
        #expect(await closing.value)
        let receipt = await service.receipt()
        #expect(receipt.writes.map(\.text) == ["Captured message", "Frozen next draft"])
        #expect(model.status == .saved && !model.isSubmissionInFlight)
        model.finishShutdown()
    }

    @Test("An unresolved captured message keeps its safety copy and never reports a completed shutdown save")
    func unresolvedSubmissionRemainsHonest() async throws {
        let id = ConversationID(UUID())
        let service = ShutdownDraftService()
        let model = draft(id, service)
        await model.load()
        model.setText("Captured but not submitted")
        let token = try #require(model.beginSubmission(messageID: UUID(), rawText: model.text))
        model.beginShutdown()
        let closing = Task { await model.flushForShutdown() }
        await service.waitForWriteCount(1)
        model.finishShutdown()
        #expect(!(await closing.value))
        let status = model.status
        model.failSubmission(token)
        #expect(!(await model.completeSubmission(token)))
        #expect(model.isSubmissionInFlight && model.status == status)
        let receipt = await service.receipt()
        #expect(receipt.writes.map(\.text) == ["Captured but not submitted"])
        #expect(receipt.saved[id]?.text == "Captured but not submitted")
    }

    @Test("Conflict and an in-flight explicit reload cannot overwrite frozen text during grace")
    func conflictRecoveryAdmissionFence() async throws {
        let id = ConversationID(UUID())
        let service = ShutdownDraftService(saved: [try snapshot(id, "Old", 1)])
        let model = draft(id, service)
        await model.load()
        await service.replace(try snapshot(id, "Competing", 2))
        model.setText("Local frozen draft")
        #expect(!(await model.flush()))
        #expect(model.hasConflict)
        let gate = ShutdownDraftGate()
        await service.setLoadGate(gate)
        let reload = Task { await model.reloadSavedDraft() }
        await gate.waitUntilEntered()
        model.beginShutdown()
        #expect(!(await model.keepThisDraft()))
        #expect(!(await model.flushForShutdown()))
        await gate.release()
        #expect(!(await reload.value))
        #expect(model.text == "Local frozen draft" && model.hasConflict)
        let receipt = await service.receipt()
        #expect(receipt.writes.count == 1 && receipt.saved[id]?.text == "Competing")
        model.finishShutdown()
    }

    @Test("Failed-send recovery and newer typing remain distinct without automatic conflict resolution")
    func failedSubmissionRecoveryStaysFrozen() async throws {
        let id = ConversationID(UUID())
        let service = ShutdownDraftService()
        let model = draft(id, service)
        await model.load()
        model.setText("Earlier")
        let token = try #require(model.beginSubmission(messageID: UUID(), rawText: model.text))
        #expect(await model.persistSubmission(token))
        model.setText("Newer")
        model.failSubmission(token)
        model.beginShutdown()
        model.acknowledgeFailedTextRecovery()
        #expect(!model.restoreFailedText())
        #expect(!(await model.flushForShutdown()))
        #expect(model.recoverableFailedText == "Earlier" && model.text == "Newer")
        let receipt = await service.receipt()
        #expect(receipt.writes.map(\.text) == ["Earlier"])
        model.finishShutdown()
    }

    @Test("Workspace shutdown freezes every visited draft and refuses activation or another send")
    func coordinatorAdmissionAndAllVisitedDrafts() async throws {
        let a = UUID(), b = UUID(), rejected = UUID()
        let service = ShutdownDraftService()
        let conversation = ConversationModel(conversationID: a, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: a)
        let first = try #require(coordinator.activeDraft)
        await first.load()
        conversation.composerText = "First frozen"
        conversation.show(conversationID: b, title: "B", messages: [])
        coordinator.activate(conversationID: b)
        let second = try #require(coordinator.activeDraft)
        await second.load()
        conversation.composerText = "Second frozen"
        coordinator.beginShutdown()
        coordinator.beginShutdown()
        first.setText("Rejected first edit")
        second.setText("Rejected second edit")
        coordinator.activate(conversationID: rejected)
        #expect(coordinator.activeDraft === second)
        #expect(first.isShuttingDown && second.isShuttingDown && coordinator.isShuttingDown)
        #expect(!coordinator.beginSubmission(messageID: UUID(), conversationID: b, rawText: "Rejected send"))
        #expect(!(await coordinator.flushAll()))
        #expect(await coordinator.flushForShutdown())
        let receipt = await service.receipt()
        #expect(receipt.saved[ConversationID(a)]?.text == "First frozen")
        #expect(receipt.saved[ConversationID(b)]?.text == "Second frozen")
        #expect(receipt.saved[ConversationID(rejected)] == nil && receipt.loads == 2)
        coordinator.finishShutdown()
        coordinator.finishShutdown()
        #expect(!(await coordinator.flushForShutdown()))
    }

    @Test("A stalled draft does not prevent another visited conversation saving before the deadline")
    func coordinatorIndependentShutdownPasses() async throws {
        let a = UUID(), b = UUID()
        let gate = ShutdownDraftGate()
        let service = ShutdownDraftService(saveGate: gate, gatedConversationID: ConversationID(a))
        let conversation = ConversationModel(conversationID: a, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        for (id, text) in [(a, "Stalled draft"), (b, "Independent draft")] {
            conversation.show(conversationID: id, title: "Draft", messages: [])
            coordinator.activate(conversationID: id)
            await coordinator.activeDraft?.load()
            conversation.composerText = text
        }
        coordinator.beginShutdown()
        let closing = Task { await coordinator.flushForShutdown() }
        await gate.waitUntilEntered()
        await service.waitForWriteCount(2)
        let beforeFinish = await service.receipt()
        #expect(beforeFinish.saved[ConversationID(b)]?.text == "Independent draft")
        coordinator.finishShutdown()
        await gate.release()
        #expect(!(await closing.value))
        let afterFinish = await service.receipt()
        #expect(afterFinish.writes.count == 2)
    }

    @Test("A pending captured submission cannot hold back another conversation's frozen draft")
    func coordinatorPendingSubmissionDoesNotBlockOtherDraft() async throws {
        let a = UUID(), b = UUID(), message = UUID()
        let service = ShutdownDraftService()
        let conversation = ConversationModel(conversationID: a, submit: { _, _, _ in })
        let coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        coordinator.activate(conversationID: a)
        await coordinator.activeDraft?.load()
        conversation.composerText = "Pending message safety copy"
        #expect(coordinator.beginSubmission(messageID: message, conversationID: a, rawText: conversation.composerText))
        #expect(await coordinator.persistSubmission(messageID: message))
        conversation.show(conversationID: b, title: "B", messages: [])
        coordinator.activate(conversationID: b)
        await coordinator.activeDraft?.load()
        conversation.composerText = "Independent unsent draft"
        coordinator.beginShutdown()
        let closing = Task { await coordinator.flushForShutdown() }
        await service.waitForWriteCount(2)
        let receipt = await service.receipt()
        #expect(receipt.saved[ConversationID(a)]?.text == "Pending message safety copy")
        #expect(receipt.saved[ConversationID(b)]?.text == "Independent unsent draft")
        coordinator.finishShutdown()
        #expect(!(await closing.value))
    }

    private func draft(_ id: ConversationID, _ service: ShutdownDraftService) -> ConversationComposerDraftModel {
        ConversationComposerDraftModel(conversationID: id, service: service, debounce: .seconds(60))
    }
}

private struct ShutdownDraftWrite: Sendable {
    let conversationID: ConversationID
    let text: String
    let expectedRevision: UInt64
}

/// Test-harness liveness only, not the app's separately tested three-second
/// close budget. Expiry records a failure and releases the event waiter.
private let shutdownTestEventTimeout: Duration = .seconds(5)

private struct ShutdownDraftWriteWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
    let deadline: Task<Void, Never>
}

private struct ShutdownDraftEntryWaiter {
    let continuation: CheckedContinuation<Void, Never>
    let deadline: Task<Void, Never>
}

/// Deliberately ignores cancellation while gated, exposing the distinction
/// between UI fencing and an already-issued atomic persistence operation.
private actor ShutdownDraftService: ConversationDraftServing {
    private var saved: [ConversationID: ConversationDraftSnapshot]
    private var loads = 0
    private var writes: [ShutdownDraftWrite] = []
    private var loadGate: ShutdownDraftGate?
    private var saveGate: ShutdownDraftGate?
    private let gatedConversationID: ConversationID?
    private var writeWaiters: [UUID: ShutdownDraftWriteWaiter] = [:]

    init(saved: [ConversationDraftSnapshot] = [], loadGate: ShutdownDraftGate? = nil,
         saveGate: ShutdownDraftGate? = nil, gatedConversationID: ConversationID? = nil) {
        self.saved = Dictionary(uniqueKeysWithValues: saved.map { ($0.conversationID, $0) })
        self.loadGate = loadGate
        self.saveGate = saveGate
        self.gatedConversationID = gatedConversationID
    }

    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? {
        loads += 1
        let value = saved[conversationID]
        let gate = loadGate
        loadGate = nil
        if let gate { await gate.wait() }
        return value
    }

    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) async throws -> ConversationDraftSnapshot {
        writes.append(ShutdownDraftWrite(conversationID: conversationID, text: text, expectedRevision: expectedRevision))
        let ready = writeWaiters.filter { writes.count >= $0.value.count }
        for (id, waiter) in ready {
            writeWaiters.removeValue(forKey: id)
            waiter.deadline.cancel()
            waiter.continuation.resume()
        }
        if gatedConversationID == nil || gatedConversationID == conversationID, let gate = saveGate {
            saveGate = nil
            await gate.wait()
        }
        guard (saved[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let value = try snapshot(conversationID, text, expectedRevision + 1)
        saved[conversationID] = value
        return value
    }

    func replace(_ value: ConversationDraftSnapshot) { saved[value.conversationID] = value }
    func setLoadGate(_ gate: ShutdownDraftGate) { loadGate = gate }
    func receipt() -> (loads: Int, writes: [ShutdownDraftWrite], saved: [ConversationID: ConversationDraftSnapshot]) {
        (loads, writes, saved)
    }
    func waitForWriteCount(_ count: Int) async {
        guard writes.count < count else { return }
        // Synchronize on the actual service event, not an arbitrary number of
        // scheduler turns while other MainActor tests are running concurrently.
        await withCheckedContinuation { continuation in
            let id = UUID()
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: shutdownTestEventTimeout) }
                catch { return }
                await self?.expireWriteWaiter(id)
            }
            writeWaiters[id] = ShutdownDraftWriteWaiter(count: count, continuation: continuation, deadline: deadline)
        }
    }

    private func expireWriteWaiter(_ id: UUID) {
        guard let waiter = writeWaiters.removeValue(forKey: id) else { return }
        Issue.record("Expected shutdown save was not issued before the test-harness deadline")
        waiter.continuation.resume()
    }
}

private actor ShutdownDraftGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [UUID: ShutdownDraftEntryWaiter] = [:]

    func wait() async {
        entered = true
        let arrivals = enteredWaiters
        enteredWaiters.removeAll()
        arrivals.values.forEach { waiter in
            waiter.deadline.cancel()
            waiter.continuation.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        // Releasing the gate does not satisfy this barrier: the draft operation
        // must really enter before the test may finish or cancel shutdown.
        await withCheckedContinuation { continuation in
            let id = UUID()
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: shutdownTestEventTimeout) }
                catch { return }
                await self?.expireEntryWaiter(id)
            }
            enteredWaiters[id] = ShutdownDraftEntryWaiter(continuation: continuation, deadline: deadline)
        }
    }

    private func expireEntryWaiter(_ id: UUID) {
        guard let waiter = enteredWaiters.removeValue(forKey: id) else { return }
        Issue.record("Expected draft operation did not reach its gate before the test-harness deadline")
        waiter.continuation.resume()
    }
}

private func snapshot(_ id: ConversationID, _ text: String, _ revision: UInt64) throws -> ConversationDraftSnapshot {
    try ConversationDraftSnapshot(conversationID: id, text: text, revision: revision,
                                  updatedAt: Date(timeIntervalSince1970: 1_000))
}
