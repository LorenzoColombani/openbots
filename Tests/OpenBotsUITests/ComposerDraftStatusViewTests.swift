import AppKit
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class ComposerDraftStatusViewTests: XCTestCase {
    func testOrdinaryDraftStatesAreSilentWithoutStoppingAutosave() async throws {
        let model = statusDraft(service: StatusDraftService())
        XCTAssertEqual(model.status, .loading)
        try await assertHiddenStatus(model)
        await model.load()
        XCTAssertEqual(model.status, .saved)
        try await assertHiddenStatus(model)
        model.setText("An ordinary unsent draft")
        XCTAssertEqual(model.status, .unsaved)
        try await assertHiddenStatus(model)
        let saved = await model.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.status, .saved)
        try await assertHiddenStatus(model)
        _ = try XCTUnwrap(model.beginSubmission(messageID: UUID(), rawText: model.text))
        XCTAssertEqual(model.status, .waitingForMessage)
        try await assertHiddenStatus(model)
        for status in [ConversationComposerDraftStatus.loading, .unsaved, .saving, .saved, .waitingForMessage] {
            XCTAssertFalse(ComposerDraftStatusView.needsAttention(status))
        }
        model.finishShutdown()
    }

    func testSavingFailureKeepsAnActionableNoticeAndExactDraft() async throws {
        let model = statusDraft(service: StatusDraftService(failsSave: true))
        await model.load()
        let draft = "  Keep my unsaved draft\n café  "
        model.setText(draft)
        let saved = await model.flush()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.status, .failed)
        try await assertRenderedStatus(model, expectedActions: ["Retry Saving Draft"], expectedDisabledActions: 0)
        XCTAssertEqual(model.text, draft)
        model.finishShutdown()
    }

    func testConflictRendersBothExplicitChoicesWithoutChangingEitherDraft() async throws {
        let id = statusConversationID()
        let saved = try ConversationDraftSnapshot(
            conversationID: id, text: "Previously saved draft", revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let service = StatusDraftService(saved: saved)
        let model = statusDraft(service: service)
        model.setText("New local draft")
        await model.load()
        XCTAssertEqual(model.status, .conflict)
        try await assertRenderedStatus(
            model, expectedActions: ["Reload Saved Draft", "Keep This Draft"], expectedDisabledActions: 0
        )
        XCTAssertEqual(model.text, "New local draft")
        XCTAssertEqual(model.conflictingSavedText, "Previously saved draft")
        let writes = await service.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testRecoveryRendersDistinctRestoreAndClipboardChoicesWithoutInvokingThem() async throws {
        let service = StatusDraftService()
        let model = statusDraft(service: service)
        await model.load()
        model.setText("Earlier failed message")
        let token = try XCTUnwrap(model.beginSubmission(messageID: UUID(), rawText: model.text))
        let stored = await model.persistSubmission(token)
        XCTAssertTrue(stored)
        model.setText("Newer draft remains here")
        model.failSubmission(token)
        XCTAssertEqual(model.status, .recovery)
        try await assertRenderedStatus(
            model,
            expectedActions: ["Restore Earlier Message", "Copy Earlier Message and Keep New Draft"],
            expectedDisabledActions: 1
        )
        XCTAssertEqual(model.text, "Newer draft remains here")
        XCTAssertEqual(model.recoverableFailedText, "Earlier failed message")
        let writes = await service.writeCount
        XCTAssertEqual(writes, 1, "Rendering must not activate recovery or clipboard actions")
    }

    func testSourceKeepsVisibleStatusLabelsAndSeparateExplicitRecoveryActions() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/ComposerDraftStatusView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("Text(model.statusText)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Local draft."))
        for action in ["Reload Saved Draft", "Keep This Draft", "Restore Earlier Message", "Copy Earlier Message and Keep New Draft"] {
            XCTAssertTrue(source.contains("Button(\"\(action)\")"))
        }
        XCTAssertTrue(source.contains(".disabled(!model.text.isEmpty)"))
        XCTAssertTrue(source.contains("Copy places the earlier text on your Mac’s clipboard"))
        XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"))
        let rootURL = sourceURL.deletingLastPathComponent().appendingPathComponent("OpenBotsRootView.swift")
        let root = try String(contentsOf: rootURL, encoding: .utf8)
        XCTAssertFalse(root.contains("Save Locally"))
        XCTAssertFalse(root.contains("conversation.saveCurrentTextLocally"))
        XCTAssertTrue(root.contains("ComposerDraftStatusContainer(coordinator: draftCoordinator)"))
        XCTAssertTrue(root.contains("AttachmentDraftTray(model: attachmentDraft)"))
        XCTAssertTrue(root.contains("conversation.sendCurrentText()"))
    }

    private func assertRenderedStatus(
        _ model: ConversationComposerDraftModel,
        expectedActions: [String], expectedDisabledActions: Int
    ) async throws {
        XCTAssertTrue(ComposerDraftStatusView.needsAttention(model.status))
        let controller = NSHostingController(rootView: ComposerDraftStatusView(model: model))
        let host = controller.view
        for width: CGFloat in [320, 600] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            let measured = controller.sizeThatFits(in: CGSize(width: width, height: 700))
            XCTAssertTrue(measured.width.isFinite && measured.height.isFinite)
            XCTAssertGreaterThan(measured.width, 0)
            XCTAssertGreaterThan(measured.height, 0)
            XCTAssertLessThanOrEqual(measured.width, width + 0.5)
            XCTAssertLessThanOrEqual(measured.height, 700)

            let controls = host.statusDescendants.compactMap { $0 as? NSControl }
            for control in controls {
                // Alignment rect, not the bezel frame: macOS 15's hosted NSButton carries a ~6pt
                // bezel shadow inset outside its alignment rect.
                let rect = control.alignmentRect(forFrame: control.convert(control.bounds, to: host))
                XCTAssertTrue(rect.width.isFinite && rect.height.isFinite)
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
                XCTAssertLessThanOrEqual(rect.maxX, width + 0.5)
            }

            let buttons = controls.compactMap { $0 as? NSButton }
            let labels = buttons.flatMap { [$0.title, $0.accessibilityLabel() ?? ""] }.filter { !$0.isEmpty }
            if !labels.isEmpty {
                for label in expectedActions { XCTAssertTrue(labels.contains(label), "Observed native labels: \(labels)") }
            }
            if !buttons.isEmpty {
                XCTAssertEqual(buttons.count, expectedActions.count)
                XCTAssertEqual(buttons.filter { !$0.isEnabled }.count, expectedDisabledActions)
                // In-process `accessibilityRole()` is AXUnknown for every NSButton on every macOS
                // (see Scripts/ci-ax-probe.swift); only an external AX client gets AXButton.
                XCTAssertTrue(buttons.allSatisfy { $0.cell is NSButtonCell })
            }
            print("Draft status \(model.statusText), viewport \(width): measured \(measured), native buttons \(buttons.count), observable labels \(labels)")
        }
        // Source labels and finite rendered layout are verified above. Native
        // labels are asserted only when AppKit exposes them: SwiftUI may own
        // composed labels without a raw NSButton title. This is not a physical
        // VoiceOver/keyboard sign-off and never invokes a button or clipboard.
    }

    private func assertHiddenStatus(_ model: ConversationComposerDraftModel) async throws {
        let controller = NSHostingController(rootView: ComposerDraftStatusView(model: model))
        for width: CGFloat in [320, 600] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 100)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 100))
            XCTAssertLessThanOrEqual(size.height, 1, "Normal draft state must not reserve a status row.")
            let controls = controller.view.statusDescendants.compactMap { $0 as? NSControl }
            XCTAssertTrue(controls.isEmpty)
        }
    }
}

private actor StatusDraftService: ConversationDraftServing {
    private var saved: ConversationDraftSnapshot?
    private let failsSave: Bool
    var writeCount = 0
    init(saved: ConversationDraftSnapshot? = nil, failsSave: Bool = false) {
        self.saved = saved
        self.failsSave = failsSave
    }
    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? { saved }
    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) async throws -> ConversationDraftSnapshot {
        writeCount += 1
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        guard (saved?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let next = try ConversationDraftSnapshot(
            conversationID: conversationID, text: text, revision: expectedRevision + 1,
            updatedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        saved = next
        return next
    }
}

@MainActor
private func statusDraft(service: StatusDraftService) -> ConversationComposerDraftModel {
    ConversationComposerDraftModel(conversationID: statusConversationID(), service: service, debounce: .seconds(60))
}

private func statusConversationID() -> ConversationID {
    ConversationID(UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!)
}

private extension NSView {
    var statusDescendants: [NSView] { subviews + subviews.flatMap(\.statusDescendants) }
}
