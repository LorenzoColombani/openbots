import Foundation
import Testing
@testable import OpenBotsUI

private struct SensitiveAttachmentImportFailure: LocalizedError, Sendable {
    var errorDescription: String? {
        "Failed while copying /Users/lorenzo/private/source.mov into provider staging"
    }
}

private actor AttachmentImporterRecorder {
    private(set) var calls: [(URL, UUID)] = []

    func record(url: URL, operationID: UUID) {
        calls.append((url, operationID))
    }

    func count() -> Int { calls.count }
}

private actor AttachmentReceiptGate {
    private var queuedReceipt: AttachmentDraftPresentationReceipt?
    private var continuation: CheckedContinuation<AttachmentDraftPresentationReceipt, Never>?

    func wait() async -> AttachmentDraftPresentationReceipt {
        if let queuedReceipt {
            self.queuedReceipt = nil
            return queuedReceipt
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ receipt: AttachmentDraftPresentationReceipt) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: receipt)
        } else {
            queuedReceipt = receipt
        }
    }
}

@MainActor
private func waitForAttachmentTransition(
    _ model: AttachmentDraftModel,
    operationID: UUID
) async {
    for _ in 0..<500 {
        guard let row = model.rows.first(where: { $0.id == operationID }) else {
            return
        }
        if row.state != .pending {
            return
        }
        await Task.yield()
    }
}

@Test("Selecting a file inserts pending state immediately and keeps one row identity on success")
@MainActor
func attachmentDraftPendingThenReadyKeepsIdentity() async throws {
    let exactURL = URL(fileURLWithPath: "/private/tmp/OpenBots attachment source.txt")
    let operationID = UUID(uuidString: "A8000000-0000-0000-0000-000000000001")!
    let recorder = AttachmentImporterRecorder()
    let gate = AttachmentReceiptGate()
    let model = AttachmentDraftModel { url, receivedOperationID in
        await recorder.record(url: url, operationID: receivedOperationID)
        return await gate.wait()
    }

    #expect(model.selectFile(at: exactURL, operationID: operationID))
    #expect(model.rows.count == 1)
    #expect(model.rows[0].id == operationID)
    #expect(model.rows[0].selectedDisplayName == "OpenBots attachment source.txt")
    #expect(model.rows[0].state == .pending)

    await gate.release(
        AttachmentDraftPresentationReceipt(
            displayName: "/Users/lorenzo/private/verified-source.txt",
            byteCount: 42,
            shortHash: "ABCDEF1234567890-sensitive-suffix"
        )
    )
    await waitForAttachmentTransition(model, operationID: operationID)

    #expect(await recorder.count() == 1)
    #expect(await recorder.calls.first?.0 == exactURL)
    #expect(await recorder.calls.first?.1 == operationID)
    #expect(model.rows.count == 1)
    #expect(model.rows[0].id == operationID)
    #expect(
        model.rows[0].state == .ready(
            AttachmentDraftPresentationReceipt(
                displayName: "verified-source.txt",
                byteCount: 42,
                shortHash: "abcdef1234567890"
            )
        )
    )
}

@Test("Importer diagnostics become one generic path-free failure on the same row")
@MainActor
func attachmentDraftFailureIsSanitized() async {
    let operationID = UUID(uuidString: "A8000000-0000-0000-0000-000000000002")!
    let model = AttachmentDraftModel { _, _ in
        throw SensitiveAttachmentImportFailure()
    }

    #expect(
        model.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/private-source.mov"),
            operationID: operationID
        )
    )
    #expect(model.rows.first?.state == .pending)
    await waitForAttachmentTransition(model, operationID: operationID)

    #expect(model.rows.first?.id == operationID)
    #expect(model.rows.first?.state == .failed(AttachmentDraftModel.importFailureMessage))
    #expect(AttachmentDraftModel.importFailureMessage.contains("/Users/") == false)
    #expect(AttachmentDraftModel.importFailureMessage.contains("provider") == false)
}

@Test("Invalid URLs and duplicate operation IDs never invoke a second import")
@MainActor
func attachmentDraftRejectsInvalidAndDuplicateRequests() async {
    let recorder = AttachmentImporterRecorder()
    let operationID = UUID(uuidString: "A8000000-0000-0000-0000-000000000003")!
    let model = AttachmentDraftModel { url, receivedOperationID in
        await recorder.record(url: url, operationID: receivedOperationID)
        return AttachmentDraftPresentationReceipt(
            displayName: url.lastPathComponent,
            byteCount: 1,
            shortHash: "01"
        )
    }

    #expect(
        model.selectFile(
            at: URL(string: "https://example.invalid/private.txt")!,
            operationID: UUID()
        ) == false
    )
    #expect(model.rows.isEmpty)
    #expect(await recorder.count() == 0)

    #expect(
        model.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/first.txt"),
            operationID: operationID
        )
    )
    #expect(
        model.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/second.txt"),
            operationID: operationID
        ) == false
    )

    await waitForAttachmentTransition(model, operationID: operationID)
    #expect(await recorder.count() == 1)
    #expect(model.rows.map(\.id) == [operationID])
}

@Test("Draft receipts and row removal stay explicitly presentation-only")
@MainActor
func attachmentDraftDoesNotClaimDurabilityOrCleanup() async {
    let operationID = UUID(uuidString: "A8000000-0000-0000-0000-000000000004")!
    let model = AttachmentDraftModel { _, _ in
        AttachmentDraftPresentationReceipt(
            displayName: "notes.md",
            byteCount: 17,
            shortHash: "1234abcd"
        )
    }

    #expect(
        model.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/notes.md"),
            operationID: operationID
        )
    )
    await waitForAttachmentTransition(model, operationID: operationID)

    guard let row = model.rows.first else {
        Issue.record("Expected the ready presentation row to remain visible")
        return
    }
    #expect(row.accessibilityDescription.contains("not yet attached"))
    #expect(row.accessibilityDescription.contains("published"))
    #expect(row.accessibilityDescription.contains("saved to the conversation"))
    #expect(row.accessibilityDescription.contains("/private/tmp") == false)

    model.removePresentationRow(id: operationID)
    #expect(model.rows.isEmpty)
}

@Test("Pending attachment work is bounded")
@MainActor
func attachmentDraftBoundsPendingRows() {
    // These operations cannot begin until this synchronous main-actor test
    // yields, so all accepted rows remain pending while the fifth request is
    // evaluated. The importer itself completes promptly once scheduled.
    let model = AttachmentDraftModel { url, _ in
        AttachmentDraftPresentationReceipt(
            displayName: url.lastPathComponent,
            byteCount: 1,
            shortHash: "01"
        )
    }

    for offset in 0..<AttachmentDraftModel.maximumPendingRows {
        let operationID = UUID(
            uuidString: String(
                format: "A8000000-0000-0000-0000-%012d",
                100 + offset
            )
        )!
        #expect(
            model.selectFile(
                at: URL(fileURLWithPath: "/private/tmp/pending-\(offset).txt"),
                operationID: operationID
            )
        )
    }

    #expect(
        model.selectFile(
            at: URL(fileURLWithPath: "/private/tmp/too-many.txt"),
            operationID: UUID()
        ) == false
    )
    #expect(model.rows.count == AttachmentDraftModel.maximumPendingRows)
    #expect(model.rows.allSatisfy { $0.state == .pending })
}
