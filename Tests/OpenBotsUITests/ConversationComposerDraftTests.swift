import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsUI

@MainActor
final class ConversationComposerDraftTests: XCTestCase {
    func testConstructionIsInertAndLoadsExactBytesOnce() async throws {
        let id = draftConversation(1)
        let raw = " \nCafe\u{301}\t "
        let service = ComposerDraftFake(saved: [try draftSnapshot(id, raw, 3)])
        let model = makeDraft(id, service)
        let before = await service.receipt()
        XCTAssertEqual(before.loads, 0)
        XCTAssertFalse(model.canBeginSubmission)
        await model.load()
        await model.load()
        XCTAssertTrue(model.text.utf8.elementsEqual(raw.utf8))
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.status, .saved)
        XCTAssertFalse(model.hasUnsavedChanges)
        let after = await service.receipt()
        XCTAssertEqual(after.loads, 1)
        XCTAssertTrue(after.writes.isEmpty)
    }

    func testTypingDuringLoadCannotOverwriteEitherUnknownSavedOrNewLocalDraft() async throws {
        let id = draftConversation(1)
        let gate = ComposerDraftGate()
        let service = ComposerDraftFake(saved: [try draftSnapshot(id, "Previously saved", 3)], loadGate: gate)
        let model = makeDraft(id, service)
        let loading = Task { await model.load() }
        await waitForDraftGate(gate)
        model.setText("New typing")
        XCTAssertEqual(model.text, "New typing")
        XCTAssertFalse(model.canBeginSubmission)
        await gate.release()
        await loading.value
        XCTAssertEqual(model.text, "New typing")
        XCTAssertEqual(model.conflictingSavedText, "Previously saved")
        XCTAssertTrue(model.hasConflict)
        let flushed = await model.flush()
        XCTAssertFalse(flushed)
        let beforeDecision = await service.receipt()
        XCTAssertTrue(beforeDecision.writes.isEmpty)
        XCTAssertEqual(beforeDecision.saved[id]?.text, "Previously saved")

        let kept = await model.keepThisDraft()
        XCTAssertTrue(kept)
        XCTAssertFalse(model.hasConflict)
        XCTAssertNil(model.conflictingSavedText)
        let afterDecision = await service.receipt()
        XCTAssertEqual(afterDecision.saved[id]?.text, "New typing")
        XCTAssertEqual(afterDecision.writes.map(\.expectedRevision), [3])
    }

    func testTextTypedBeforeFirstLoadPersistsOnlyWhenThereIsNoCompetingSavedText() async throws {
        let id = draftConversation(1)
        for stored in [nil, try draftSnapshot(id, "", 4)] {
            let service = ComposerDraftFake(saved: stored.map { [$0] } ?? [])
            let model = makeDraft(id, service)
            model.setText("Typed before loading")
            await model.load()
            XCTAssertEqual(model.text, "Typed before loading")
            XCTAssertFalse(model.hasConflict)
            let flushed = await model.flush()
            XCTAssertTrue(flushed)
            let receipt = await service.receipt()
            XCTAssertEqual(receipt.saved[id]?.text, "Typed before loading")
            XCTAssertEqual(receipt.writes.first?.expectedRevision, stored?.revision ?? 0)
        }
    }

    func testDebounceCoalescesImmediateTypingAndReportsUnsavedUntilReceipt() async {
        let id = draftConversation(1)
        let service = ComposerDraftFake()
        let model = ConversationComposerDraftModel(conversationID: id, service: service, debounce: .milliseconds(20))
        await model.load()
        model.setText("A")
        model.setText("AB")
        model.setText("ABC")
        XCTAssertEqual(model.text, "ABC")
        XCTAssertEqual(model.status, .unsaved)
        let immediate = await service.receipt()
        XCTAssertTrue(immediate.writes.isEmpty)
        await waitForDraftStatus(model, .saved)
        let receipt = await service.receipt()
        XCTAssertEqual(receipt.writes.map(\.text), ["ABC"])
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testWritesSerializeAndCoalesceNewTextWhileOlderWriteIsPending() async {
        let id = draftConversation(1)
        let gate = ComposerDraftGate()
        let service = ComposerDraftFake(saveGate: gate)
        let model = makeDraft(id, service)
        await model.load()
        model.setText("First")
        let firstFlush = Task { await model.flush() }
        await waitForDraftGate(gate)
        XCTAssertEqual(model.status, .saving)
        model.setText("Second")
        model.setText("Latest")
        let secondFlush = Task { await model.flush() }
        await gate.release()
        let first = await firstFlush.value
        let second = await secondFlush.value
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let receipt = await service.receipt()
        XCTAssertEqual(receipt.writes.map(\.text), ["First", "Latest"])
        XCTAssertEqual(receipt.writes.map(\.expectedRevision), [0, 1])
        XCTAssertEqual(receipt.maximumConcurrentWrites, 1)
        XCTAssertEqual(model.text, "Latest")
        XCTAssertEqual(model.status, .saved)
    }

    func testConversationsAndCanonicalEquivalentStringsRemainByteIsolated() async throws {
        let firstID = draftConversation(1)
        let secondID = draftConversation(2)
        let service = ComposerDraftFake()
        let first = makeDraft(firstID, service)
        let second = makeDraft(secondID, service)
        await first.load(); await second.load()
        first.setText("\u{00e9}")
        second.setText("Second conversation")
        _ = await first.flush(); _ = await second.flush()
        first.setText("e\u{0301}")
        XCTAssertTrue(first.hasUnsavedChanges)
        _ = await first.flush()
        let receipt = await service.receipt()
        XCTAssertTrue(receipt.saved[firstID]!.text.utf8.elementsEqual("e\u{0301}".utf8))
        XCTAssertEqual(receipt.saved[secondID]?.text, "Second conversation")
        XCTAssertEqual(receipt.writes.filter { $0.conversationID == firstID }.count, 2)
        XCTAssertEqual(receipt.writes.filter { $0.conversationID == secondID }.count, 1)
    }

    func testCASConflictNeverRetriesAndExplicitReloadCanChooseStoredVersion() async throws {
        let id = draftConversation(1)
        let service = ComposerDraftFake(saved: [try draftSnapshot(id, "Original", 1)])
        let model = makeDraft(id, service)
        await model.load()
        await service.replace(try draftSnapshot(id, "Other editor", 2))
        model.setText("Local edit")
        let first = await model.flush()
        let second = await model.flush()
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertEqual(model.text, "Local edit")
        XCTAssertEqual(model.status, .conflict)
        XCTAssertFalse(model.canBeginSubmission)
        let conflicted = await service.receipt()
        XCTAssertEqual(conflicted.writes.count, 1)
        let reloaded = await model.reloadSavedDraft()
        XCTAssertTrue(reloaded)
        XCTAssertEqual(model.text, "Other editor")
        XCTAssertFalse(model.hasUnsavedChanges)
        let after = await service.receipt()
        XCTAssertEqual(after.writes.count, 1)
    }

    func testTypingDuringExplicitReloadKeepsConflictAndNewText() async throws {
        let id = draftConversation(1)
        let service = ComposerDraftFake(saved: [try draftSnapshot(id, "Original", 1)])
        let model = makeDraft(id, service)
        await model.load()
        await service.replace(try draftSnapshot(id, "Competing", 2))
        model.setText("Local")
        _ = await model.flush()
        let gate = ComposerDraftGate()
        await service.setNextLoadGate(gate)
        let reload = Task { await model.reloadSavedDraft() }
        await waitForDraftGate(gate)
        model.setText("Newest typing")
        await gate.release()
        let result = await reload.value
        XCTAssertFalse(result)
        XCTAssertEqual(model.text, "Newest typing")
        XCTAssertTrue(model.hasConflict)
    }

    func testSendClearWaitsForRawDraftReceiptAndCannotEraseNewerTyping() async throws {
        let id = draftConversation(1)
        let service = ComposerDraftFake()
        let model = makeDraft(id, service)
        await model.load()
        let raw = "  Captured exact text\n"
        model.setText(raw)
        let token = try XCTUnwrap(model.beginSubmission(messageID: UUID(), rawText: raw))
        XCTAssertEqual(model.text, "")
        model.setText("") // mirrored UI clear is not a mutation to the safety copy
        XCTAssertFalse(model.canBeginSubmission)
        let premature = await model.completeSubmission(token)
        XCTAssertFalse(premature)
        model.setText("Newer unsent typing")
        let stored = await model.persistSubmission(token)
        XCTAssertTrue(stored)
        let whileSending = await service.receipt()
        XCTAssertEqual(whileSending.writes.map(\.text), [raw])
        let pendingFlush = await model.flush()
        XCTAssertFalse(pendingFlush)
        let finished = await model.completeSubmission(token)
        XCTAssertTrue(finished)
        XCTAssertEqual(model.text, "Newer unsent typing")
        let final = await service.receipt()
        XCTAssertEqual(final.writes.map(\.text), [raw, "Newer unsent typing"])
        let stale = await model.completeSubmission(token)
        XCTAssertFalse(stale)
    }

    func testSuccessfulSendWithoutNewTypingCreatesEmptySuccessorTombstone() async throws {
        let id = draftConversation(1)
        let service = ComposerDraftFake()
        let model = makeDraft(id, service)
        await model.load()
        model.setText("Message")
        let token = try XCTUnwrap(model.beginSubmission(messageID: UUID(), rawText: "Message"))
        let stored = await model.persistSubmission(token)
        XCTAssertTrue(stored)
        let finished = await model.completeSubmission(token)
        XCTAssertTrue(finished)
        let receipt = await service.receipt()
        XCTAssertEqual(receipt.writes.map(\.text), ["Message", ""])
        XCTAssertEqual(receipt.saved[id]?.revision, 2)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testFailedSendRestoresOnlyWhenNoNewerEditAndOtherwiseKeepsSeparateRecovery() async throws {
        let id = draftConversation(1)
        let service = ComposerDraftFake()
        let model = makeDraft(id, service)
        await model.load()
        model.setText("Earlier message")
        let first = try XCTUnwrap(model.beginSubmission(messageID: UUID(), rawText: model.text))
        _ = await model.persistSubmission(first)
        model.failSubmission(first)
        XCTAssertEqual(model.text, "Earlier message")
        XCTAssertNil(model.recoverableFailedText)

        let second = try XCTUnwrap(model.beginSubmission(messageID: UUID(), rawText: model.text))
        _ = await model.persistSubmission(second)
        model.setText("Newer draft")
        model.failSubmission(second)
        XCTAssertEqual(model.text, "Newer draft")
        XCTAssertEqual(model.recoverableFailedText, "Earlier message")
        XCTAssertFalse(model.restoreFailedText())
        let held = await model.flush()
        XCTAssertFalse(held)
        let heldReceipt = await service.receipt()
        XCTAssertEqual(heldReceipt.saved[id]?.text, "Earlier message")
        model.acknowledgeFailedTextRecovery()
        let resolved = await model.flush()
        XCTAssertTrue(resolved)
        let resolvedReceipt = await service.receipt()
        XCTAssertEqual(resolvedReceipt.saved[id]?.text, "Newer draft")
    }

    func testSaveFailureAndWrongReceiptNeverClaimSavedOrExposePrivateError() async {
        for failure in [ComposerDraftFailure.unavailable, .wrongIdentity, .wrongBytes] {
            let id = draftConversation(1)
            let service = ComposerDraftFake(failure: failure)
            let model = makeDraft(id, service)
            await model.load()
            model.setText("\u{00e9}")
            let stored = await model.flush()
            XCTAssertFalse(stored)
            XCTAssertEqual(model.text, "\u{00e9}")
            XCTAssertEqual(model.status, .failed)
            XCTAssertFalse(model.canBeginSubmission)
            XCTAssertTrue(model.hasUnsavedChanges)
            XCTAssertFalse(model.notice?.contains("/Users/") ?? true)
        }
    }

    func testOversizeTextStaysVisibleWithoutCallingPersistence() async {
        let id = draftConversation(1)
        let service = ComposerDraftFake()
        let model = makeDraft(id, service)
        await model.load()
        let text = String(repeating: "🙂", count: ConversationDraftSnapshot.maximumUTF8ByteCount / 4 + 1)
        model.setText(text)
        let stored = await model.flush()
        XCTAssertFalse(stored)
        XCTAssertTrue(model.text.utf8.elementsEqual(text.utf8))
        let receipt = await service.receipt()
        XCTAssertTrue(receipt.writes.isEmpty)
        XCTAssertFalse(model.canBeginSubmission)
    }

    func testBeforeSubmissionSeamCapturesRawTextBeforeClearAndCanRejectWithoutMutation() {
        let id = draftConversation(1).rawValue
        var captured: String?
        let model = ConversationModel(conversationID: id, composerText: "  Text\n", submit: { _, _, _ in }, beforeSubmission: { _, target, raw in
            XCTAssertEqual(target, id)
            captured = raw
            return false
        })
        model.sendCurrentText()
        XCTAssertEqual(captured, "  Text\n")
        XCTAssertEqual(model.composerText, "  Text\n")
        XCTAssertTrue(model.messages.isEmpty)
        model.setDraftSubmissionAllowed(false)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.inputAvailability, .ready)
        model.composerText = "Typing is still allowed"
        XCTAssertEqual(model.composerText, "Typing is still allowed")
        model.sendCurrentText()
        XCTAssertTrue(model.messages.isEmpty)
    }
}

private struct ComposerDraftWrite: Sendable {
    let conversationID: ConversationID
    let text: String
    let expectedRevision: UInt64
}

private enum ComposerDraftFailure: Sendable { case unavailable, wrongIdentity, wrongBytes }

private actor ComposerDraftFake: ConversationDraftServing {
    private var saved: [ConversationID: ConversationDraftSnapshot]
    private var loadGate: ComposerDraftGate?
    private var saveGate: ComposerDraftGate?
    private let failure: ComposerDraftFailure?
    private var loads = 0
    private var writes: [ComposerDraftWrite] = []
    private var concurrentWrites = 0
    private var maximumConcurrentWrites = 0

    init(saved: [ConversationDraftSnapshot] = [], loadGate: ComposerDraftGate? = nil, saveGate: ComposerDraftGate? = nil, failure: ComposerDraftFailure? = nil) {
        self.saved = Dictionary(uniqueKeysWithValues: saved.map { ($0.conversationID, $0) })
        self.loadGate = loadGate; self.saveGate = saveGate; self.failure = failure
    }

    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? {
        loads += 1
        let value = saved[conversationID]
        let gate = loadGate; loadGate = nil
        if let gate { await gate.wait() }
        return value
    }

    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) async throws -> ConversationDraftSnapshot {
        writes.append(ComposerDraftWrite(conversationID: conversationID, text: text, expectedRevision: expectedRevision))
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        let gate = saveGate; saveGate = nil
        if let gate { await gate.wait() }
        if failure == .unavailable { throw ComposerDraftPrivateError() }
        guard saved[conversationID]?.revision ?? 0 == expectedRevision else { throw ConversationDraftError.staleRevision }
        if failure == .wrongIdentity { return try draftSnapshot(draftConversation(99), text, expectedRevision + 1) }
        if failure == .wrongBytes { return try draftSnapshot(conversationID, "e\u{0301}", expectedRevision + 1) }
        let value = try draftSnapshot(conversationID, text, expectedRevision + 1)
        saved[conversationID] = value
        return value
    }

    func replace(_ value: ConversationDraftSnapshot) { saved[value.conversationID] = value }
    func setNextLoadGate(_ value: ComposerDraftGate) { loadGate = value }
    func receipt() -> (loads: Int, writes: [ComposerDraftWrite], saved: [ConversationID: ConversationDraftSnapshot], maximumConcurrentWrites: Int) {
        (loads, writes, saved, maximumConcurrentWrites)
    }
}

private struct ComposerDraftPrivateError: LocalizedError {
    var errorDescription: String? { "Private database error at /Users/example/private.sqlite" }
}

private actor ComposerDraftGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private func waitForDraftGate(_ gate: ComposerDraftGate) async {
    for _ in 0..<200 {
        if await gate.started { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Draft operation did not reach its bounded gate")
}

@MainActor
private func waitForDraftStatus(_ model: ConversationComposerDraftModel, _ status: ConversationComposerDraftStatus) async {
    for _ in 0..<200 {
        if model.status == status { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Draft status did not settle")
}

@MainActor
private func makeDraft(_ id: ConversationID, _ service: ComposerDraftFake) -> ConversationComposerDraftModel {
    ConversationComposerDraftModel(conversationID: id, service: service, debounce: .seconds(60))
}

private func draftConversation(_ value: Int) -> ConversationID {
    ConversationID(UUID(uuidString: String(format: "A9000000-0000-0000-0000-%012x", value))!)
}

private func draftSnapshot(_ id: ConversationID, _ text: String, _ revision: UInt64) throws -> ConversationDraftSnapshot {
    try ConversationDraftSnapshot(conversationID: id, text: text, revision: revision, updatedAt: Date(timeIntervalSince1970: 1_788_000_000))
}
