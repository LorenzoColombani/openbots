import Foundation
import OpenBotsDomain
import XCTest
@testable import OpenBotsUI

@MainActor
final class DurableAttachmentDraftTests: XCTestCase {
    func testInertConstructionAndExplicitLoadGateSubmission() async throws {
        let storage = DraftAttachmentFake()
        let model = durableAttachmentModel(storage)
        XCTAssertEqual(model.loadState, .notLoaded)
        XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.selectFile(at: draftAttachmentURL, operationID: draftAttachmentID(1)))
        XCTAssertThrowsError(try model.freezeForSubmission())
        let before = await storage.receipt()
        XCTAssertEqual(before.loads, 0)
        await model.load()
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(try model.freezeForSubmission().isEmpty)
        XCTAssertFalse(model.hasDurableAttachments)
    }

    func testReadyImportRestoresInFreshModelWithDurableDisclosure() async throws {
        let storage = DraftAttachmentFake()
        let first = durableAttachmentModel(storage)
        await first.load()
        let id = draftAttachmentID(2)
        XCTAssertTrue(first.selectFile(at: draftAttachmentURL, operationID: id))
        XCTAssertEqual(first.rows.first?.state, .pending)
        try await waitAttachment { first.canSubmit }
        let captured = try first.freezeForSubmission()
        XCTAssertEqual(captured.map(\.id), [AttachmentID(id)])
        let restarted = durableAttachmentModel(storage)
        await restarted.load()
        XCTAssertEqual(try restarted.freezeForSubmission(), captured)
        XCTAssertEqual(restarted.rows.first?.id, id)
        XCTAssertTrue(restarted.hasDurableAttachments)
        guard case .ready(let receipt) = restarted.rows.first?.state else { return XCTFail("Expected restored receipt") }
        XCTAssertTrue(receipt.isDurable)
        XCTAssertEqual(receipt.asset, captured.first)
        XCTAssertTrue(receipt.disclosure.contains("Saved with this conversation"))
        XCTAssertFalse(restarted.disclosure.contains("preview only"))
        let calls = await storage.receipt()
        XCTAssertEqual(calls.imports, [id])
        XCTAssertTrue(calls.removes.isEmpty)
    }

    func testCancelledLateCommittedImportRemovesExactLinkBeforeForgetting() async throws {
        let id = draftAttachmentID(3)
        let gate = DraftAttachmentGate()
        let storage = DraftAttachmentFake(importGates: [id: gate])
        let model = durableAttachmentModel(storage)
        await model.load()
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: id))
        await waitAttachmentGate(gate)
        model.removePresentationRow(id: id)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertTrue(model.rows[0].isRemoving)
        XCTAssertFalse(model.canSubmit)
        await gate.release()
        try await waitAttachment { model.rows.isEmpty }
        let calls = await storage.receipt()
        XCTAssertEqual(calls.imports, [id])
        XCTAssertEqual(calls.removes, [AttachmentID(id)])
        XCTAssertTrue(calls.sawCancelledImport)
        XCTAssertTrue(calls.assets.isEmpty)
    }

    func testCancelBeforeImporterStartsStillReconcilesKnownExactLink() async throws {
        let storage = DraftAttachmentFake()
        let model = durableAttachmentModel(storage)
        await model.load()
        let id = draftAttachmentID(4)
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: id))
        model.removePresentationRow(id: id)
        try await waitAttachment { model.rows.isEmpty }
        let calls = await storage.receipt()
        XCTAssertTrue(calls.imports.isEmpty)
        XCTAssertEqual(calls.removes, [AttachmentID(id)])
    }

    func testCancelledThrowAfterCommitDoesNotLeaveHiddenDraftLink() async throws {
        let id = draftAttachmentID(5)
        let gate = DraftAttachmentGate()
        let storage = DraftAttachmentFake(importGates: [id: gate], throwsAfterCommit: true)
        let model = durableAttachmentModel(storage)
        await model.load()
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: id))
        await waitAttachmentGate(gate)
        model.removePresentationRow(id: id)
        await gate.release()
        try await waitAttachment { model.rows.isEmpty }
        let calls = await storage.receipt()
        XCTAssertEqual(calls.removes, [AttachmentID(id)])
        XCTAssertTrue(calls.assets.isEmpty)
    }

    func testFailedRemovalStaysVisibleAndCanRetryWithoutDroppingAsset() async throws {
        let asset = try draftAttachmentAsset(6)
        let storage = DraftAttachmentFake(assets: [asset], failsRemove: true)
        let model = durableAttachmentModel(storage)
        await model.load()
        model.removePresentationRow(id: asset.id.rawValue)
        try await waitAttachment { model.rows.first?.state == .failed(AttachmentDraftModel.removalFailureMessage) }
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertFalse(model.rows[0].isRemoving)
        XCTAssertTrue(model.hasDurableAttachments)
        XCTAssertFalse(model.canSubmit)
        XCTAssertThrowsError(try model.freezeForSubmission())
        let failed = await storage.receipt()
        XCTAssertEqual(failed.assets, [asset])
        await storage.setRemovalFailure(false)
        model.removePresentationRow(id: asset.id.rawValue)
        try await waitAttachment { model.rows.isEmpty }
        let recovered = await storage.receipt()
        XCTAssertEqual(recovered.removes, [asset.id, asset.id])
        XCTAssertTrue(recovered.assets.isEmpty)
    }

    func testCancelledImportRemovalFailureRetainsRetryTargetEvenWithoutReceipt() async throws {
        let storage = DraftAttachmentFake(failsRemove: true)
        let model = durableAttachmentModel(storage)
        await model.load()
        let id = draftAttachmentID(7)
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: id))
        model.removePresentationRow(id: id)
        try await waitAttachment { model.rows.first?.state == .failed(AttachmentDraftModel.removalFailureMessage) }
        XCTAssertEqual(model.rows.first?.id, id)
        await storage.setRemovalFailure(false)
        model.removePresentationRow(id: id)
        try await waitAttachment { model.rows.isEmpty }
        let calls = await storage.receipt()
        XCTAssertEqual(calls.removes, [AttachmentID(id), AttachmentID(id)])
    }

    func testSendCaptureAndAcknowledgementPreserveNewerPendingAddition() async throws {
        let first = try draftAttachmentAsset(8)
        let newID = draftAttachmentID(9)
        let gate = DraftAttachmentGate()
        let storage = DraftAttachmentFake(assets: [first], importGates: [newID: gate])
        let model = durableAttachmentModel(storage)
        await model.load()
        let capture = try model.freezeForSubmission()
        XCTAssertEqual(model.rows.count, 1, "Capture is not permission to clear before the message commits")
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: newID))
        await waitAttachmentGate(gate)
        XCTAssertThrowsError(try model.freezeForSubmission())
        model.acknowledgeSubmitted(ids: Set(capture.map(\.id)))
        XCTAssertEqual(model.rows.map(\.id), [newID])
        XCTAssertEqual(model.rows.first?.state, .pending)
        await gate.release()
        try await waitAttachment { model.canSubmit }
        XCTAssertEqual(try model.freezeForSubmission().map(\.id), [AttachmentID(newID)])
        let calls = await storage.receipt()
        XCTAssertTrue(calls.removes.isEmpty, "Acknowledgement must not delete files or invoke draft removal")
    }

    func testStaleRemovalSnapshotDoesNotEraseLaterAddition() async throws {
        let old = try draftAttachmentAsset(10)
        let newID = draftAttachmentID(11)
        let gate = DraftAttachmentGate()
        let storage = DraftAttachmentFake(assets: [old], removeGate: gate)
        let model = durableAttachmentModel(storage)
        await model.load()
        model.removePresentationRow(id: old.id.rawValue)
        await waitAttachmentGate(gate)
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: newID))
        try await waitAttachment { model.rows.contains { if case .ready = $0.state { return $0.id == newID }; return false } }
        await gate.release()
        try await waitAttachment { model.rows.count == 1 && model.canSubmit }
        XCTAssertEqual(try model.freezeForSubmission().map(\.id), [AttachmentID(newID)])
    }

    func testWrongConversationLoadFailsClosedAndExplicitReloadRecovers() async throws {
        let storage = DraftAttachmentFake()
        let wrong = AttachmentDraftSnapshot(conversationID: ConversationID(draftAttachmentID(99)), revision: 1,
                                             attachments: [try draftAttachmentAsset(12)])
        await storage.setSnapshotOverride(wrong)
        let model = durableAttachmentModel(storage)
        await model.load()
        guard case .failed(let error) = model.loadState else { return XCTFail("Expected local load failure") }
        XCTAssertFalse(error.contains("/Users/"))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.canSubmit)
        await storage.setSnapshotOverride(nil)
        await model.reload()
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertTrue(model.canSubmit)
    }

    func testUntouchedRevisionCannotClaimAlreadySavedAssets() async throws {
        let storage = DraftAttachmentFake()
        await storage.setSnapshotOverride(AttachmentDraftSnapshot(
            conversationID: draftAttachmentConversation, revision: 0, attachments: [try draftAttachmentAsset(16)]
        ))
        let model = durableAttachmentModel(storage)
        await model.load()
        guard case .failed = model.loadState else { return XCTFail("A nonempty draft requires a committed revision") }
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.canSubmit)
    }

    func testIndependentConversationModelsNeverAdoptEachOthersImports() async throws {
        let ownerB = ConversationID(draftAttachmentID(101))
        let a = DraftAttachmentFake()
        let b = DraftAttachmentFake(conversationID: ownerB)
        let first = durableAttachmentModel(a)
        let second = durableAttachmentModel(b, conversationID: ownerB)
        await first.load(); await second.load()
        XCTAssertTrue(first.selectFile(at: draftAttachmentURL, operationID: draftAttachmentID(13)))
        XCTAssertTrue(second.selectFile(at: draftAttachmentURL, operationID: draftAttachmentID(14)))
        try await waitAttachment { first.canSubmit && second.canSubmit }
        XCTAssertEqual(try first.freezeForSubmission().map(\.conversationID), [draftAttachmentConversation])
        XCTAssertEqual(try second.freezeForSubmission().map(\.conversationID), [ownerB])
        first.removePresentationRow(id: draftAttachmentID(13))
        try await waitAttachment { first.rows.isEmpty }
        XCTAssertEqual(second.rows.map(\.id), [draftAttachmentID(14)])
        let untouched = await b.receipt()
        XCTAssertTrue(untouched.removes.isEmpty)
    }

    func testLegacyReceiptRemainsPreviewOnlyAndCannotBeSentAsDurable() async throws {
        let model = AttachmentDraftModel { _, _ in
            AttachmentDraftPresentationReceipt(displayName: "fixture.txt", byteCount: 5, shortHash: "abcd")
        }
        XCTAssertTrue(model.canSubmit, "An empty preview draft does not block text-only fixture sends")
        XCTAssertTrue(model.selectFile(at: draftAttachmentURL, operationID: draftAttachmentID(15)))
        try await waitAttachment { model.rows.first?.state != .pending }
        XCTAssertFalse(model.isDurable)
        XCTAssertFalse(model.hasDurableAttachments)
        XCTAssertFalse(model.canSubmit)
        XCTAssertThrowsError(try model.freezeForSubmission()) { error in
            XCTAssertEqual(error as? AttachmentDraftSubmissionError, .previewOnly)
        }
        XCTAssertTrue(model.rows[0].accessibilityDescription.contains("not yet attached"))
        model.removePresentationRow(id: draftAttachmentID(15))
        XCTAssertTrue(model.rows.isEmpty)
    }
}

private let draftAttachmentConversation = ConversationID(draftAttachmentID(100))
private let draftAttachmentURL = URL(fileURLWithPath: "/private/tmp/OpenBots-synthetic-attachment.txt")

private actor DraftAttachmentFake {
    let conversationID: ConversationID
    private var assets: [AttachmentAsset]
    private var revision: Int64
    private let importGates: [UUID: DraftAttachmentGate]
    private let removeGate: DraftAttachmentGate?
    private let throwsAfterCommit: Bool
    private var failsRemove: Bool
    private var loads = 0
    private var imports: [UUID] = []
    private var removes: [AttachmentID] = []
    private var sawCancelledImport = false
    private var snapshotOverride: AttachmentDraftSnapshot?

    init(conversationID: ConversationID = draftAttachmentConversation, assets: [AttachmentAsset] = [],
         importGates: [UUID: DraftAttachmentGate] = [:], removeGate: DraftAttachmentGate? = nil,
         throwsAfterCommit: Bool = false, failsRemove: Bool = false) {
        self.conversationID = conversationID
        self.assets = assets
        revision = assets.isEmpty ? 0 : 1
        self.importGates = importGates
        self.removeGate = removeGate
        self.throwsAfterCommit = throwsAfterCommit
        self.failsRemove = failsRemove
    }

    func load() -> AttachmentDraftSnapshot {
        loads += 1
        return snapshotOverride ?? snapshot()
    }
    func importFile(_ url: URL, _ operationID: UUID) async throws -> AttachmentAsset {
        imports.append(operationID)
        if let gate = importGates[operationID] { await gate.wait() }
        sawCancelledImport = sawCancelledImport || Task.isCancelled
        let asset = try AttachmentAsset(id: AttachmentID(operationID), conversationID: conversationID,
                                        displayName: url.lastPathComponent, typeIdentifier: "public.plain-text",
                                        byteCount: 12, sha256: String(repeating: "a", count: 64),
                                        createdAt: Date(timeIntervalSince1970: 1_788_000_000))
        assets.append(asset)
        revision += 1
        if throwsAfterCommit { throw DraftAttachmentFailure() }
        return asset
    }
    func remove(_ id: AttachmentID) async throws -> AttachmentDraftSnapshot {
        removes.append(id)
        if failsRemove { throw DraftAttachmentFailure() }
        assets.removeAll { $0.id == id }
        revision += 1
        let result = snapshot()
        if let removeGate { await removeGate.wait() }
        return result
    }
    func setRemovalFailure(_ value: Bool) { failsRemove = value }
    func setSnapshotOverride(_ value: AttachmentDraftSnapshot?) { snapshotOverride = value }
    func receipt() -> (loads: Int, imports: [UUID], removes: [AttachmentID], assets: [AttachmentAsset], sawCancelledImport: Bool) {
        (loads, imports, removes, assets, sawCancelledImport)
    }
    private func snapshot() -> AttachmentDraftSnapshot {
        AttachmentDraftSnapshot(conversationID: conversationID, revision: revision, attachments: assets)
    }
}

private struct DraftAttachmentFailure: LocalizedError {
    var errorDescription: String? { "private failure /Users/example/source.txt" }
}

private actor DraftAttachmentGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private func durableAttachmentModel(_ fake: DraftAttachmentFake,
                                    conversationID: ConversationID = draftAttachmentConversation) -> AttachmentDraftModel {
    AttachmentDraftModel(conversationID: conversationID, load: { await fake.load() },
                         importFile: { try await fake.importFile($0, $1) }, remove: { try await fake.remove($0) })
}

private func draftAttachmentAsset(_ suffix: UInt64) throws -> AttachmentAsset {
    try AttachmentAsset(id: AttachmentID(draftAttachmentID(suffix)), conversationID: draftAttachmentConversation,
                        displayName: "attachment-\(suffix).txt", typeIdentifier: "public.plain-text", byteCount: 8,
                        sha256: String(repeating: "b", count: 64), createdAt: Date(timeIntervalSince1970: 1_788_000_000))
}

private func draftAttachmentID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "AD100000-0000-0000-0000-%012llx", value))!
}

@MainActor
private func waitAttachment(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Attachment presentation did not settle within one second")
}

private func waitAttachmentGate(_ gate: DraftAttachmentGate) async {
    for _ in 0..<500 {
        if await gate.started { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Attachment import/removal did not reach its bounded gate")
}
