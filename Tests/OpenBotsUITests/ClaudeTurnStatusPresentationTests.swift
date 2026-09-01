import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class ClaudeTurnStatusPresentationTests: XCTestCase {
    func testOnlyStatusOnlySystemMessagesUsePlainInformationalPresentation() {
        let status = ChatMessagePartSnapshot(
            id: UUID(), ordinal: 0, content: .status("Claude could not complete this reply")
        )
        XCTAssertTrue(message(parts: [status]).isInformationalSystemStatus)
        XCTAssertFalse(message(author: .user, parts: [status]).isInformationalSystemStatus)
        XCTAssertFalse(message(parts: []).isInformationalSystemStatus)

        let question = ChatQuestionCardSnapshot(
            id: UUID(), prompt: "Which source should I use?",
            choices: [ChatQuestionChoiceSnapshot(id: UUID(), title: "Saved notes")],
            allowsFreeText: true
        )
        let card = ChatMessagePartSnapshot(id: UUID(), ordinal: 1, content: .question(question))
        XCTAssertFalse(message(parts: [status, card]).isInformationalSystemStatus,
                       "A status beside an actionable card must retain the card presentation.")
        XCTAssertFalse(message(parts: [card]).isInformationalSystemStatus)
        let text = ChatMessagePartSnapshot(id: UUID(), ordinal: 1, content: .text("Saved detail"))
        XCTAssertFalse(message(parts: [status, text]).isInformationalSystemStatus)
    }

    func testSavedFailureRendersAsSelectableNativeTextWithoutAnAction() async throws {
        let failure = "Claude could not complete this reply"
        let snapshot = message(parts: [
            ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: .status(failure))
        ])
        let row = ChatMessageModel(snapshot: snapshot)
        for scheme in [ColorScheme.light, .dark] {
            let controller = NSHostingController(rootView: SystemMessageBubble(
                row: row, cardInteractions: nil
            ).environment(\.colorScheme, scheme))
            controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for width: CGFloat in [300, 620] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 180)
                for _ in 0..<3 {
                    controller.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                let views = descendants(controller.view).filter { !$0.isHiddenOrHasHiddenAncestor }
                let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
                    $0.stringValue == failure
                }, "The saved failure must materialize as readable text, not a blank render.")
                XCTAssertTrue(field.isSelectable)
                XCTAssertFalse(field.isEditable)
                XCTAssertFalse(field.isBezeled)
                XCTAssertFalse(field.isBordered)
                XCTAssertFalse(field.drawsBackground)
                XCTAssertNil(field.action)
                XCTAssertNil(field.target)
                XCTAssertFalse(views.contains { $0 is NSButton })
                let rect = field.convert(field.bounds, to: controller.view)
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThan(rect.height, 0)
                XCTAssertGreaterThanOrEqual(rect.minX, -1)
                XCTAssertLessThanOrEqual(rect.maxX, width + 1)
                XCTAssertGreaterThanOrEqual(rect.minY, -1)
                XCTAssertLessThanOrEqual(rect.maxY, 181)
                XCTAssertNil(controller.view.window)
            }
        }
        XCTAssertEqual(row.snapshot, snapshot)
        // Windowless rendering checks native text semantics and wrapping only.
        // The installed saved row still needs physical appearance verification.
    }

    private func message(
        author: ChatAuthorSnapshot = .system(label: "OpenBots"),
        parts: [ChatMessagePartSnapshot]
    ) -> ChatMessageSnapshot {
        ChatMessageSnapshot(
            id: UUID(), author: author, parts: parts, delivery: .sent,
            timestamp: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
