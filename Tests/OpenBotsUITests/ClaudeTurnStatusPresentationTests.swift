import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI
import OpenBotsDomain

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

    // A failed turn ended its bubble with the chip
    // "OpenBots diagnostic: responseMismatch", drawn like a chip that opens,
    // and a click did nothing. Opening it says what the code means in words
    // and leads to the conversation's "What happened" record.
    func testADiagnosticStatusOpensToAPlainExplanation() throws {
        let explanation = try XCTUnwrap(TranscriptDiagnostic(status: "OpenBots diagnostic: responseMismatch"))
        XCTAssertEqual(explanation.code, .responseMismatch)
        XCTAssertTrue(explanation.sentence.contains("sent something OpenBots does not understand"), explanation.sentence)
        XCTAssertTrue(explanation.sentence.contains("your text is kept"), explanation.sentence)
        for code in TextTurnDiagnosticCode.allCases {
            let sentence = try XCTUnwrap(TranscriptDiagnostic(status: "OpenBots diagnostic: \(code.rawValue)")).sentence
            XCTAssertFalse(sentence.isEmpty, "\(code)")
            XCTAssertFalse(sentence.contains(code.rawValue), "\(code): the sentence is words, the code is shown apart")
        }
        XCTAssertNil(TranscriptDiagnostic(status: "Claude could not complete this reply"))
        XCTAssertNil(TranscriptDiagnostic(status: "OpenBots diagnostic: arbitrary provider detail"))
        XCTAssertNil(TranscriptDiagnostic(status: "OpenBots diagnostic: responseMismatch and more"))
    }

    // A work turn ended "deadlineExceeded", and
    // nothing said which of the two limits it was. The one code covers both,
    // on replies saved before and after card time stopped counting, so the
    // words name both limits and neither number.
    func testTheDeadlineDiagnosticNamesBothLimits() throws {
        let sentence = try XCTUnwrap(TranscriptDiagnostic(status: "OpenBots diagnostic: deadlineExceeded")).sentence
        XCTAssertTrue(sentence.contains("went quiet"), sentence)
        XCTAssertTrue(sentence.contains("time limit"), sentence)
        XCTAssertTrue(sentence.contains("your text is kept"), sentence)
    }

    func testTheDiagnosticChipOnABotsReplyIsTheOpenableChip() throws {
        // Offscreen SwiftUI has no accessibility tree and draws a plain-style
        // button as no NSButton, so the choice the view makes is what is
        // tested here; the popover itself is proved on the installed app.
        let bot = ChatAuthorSnapshot.teammate(TeammateIdentitySnapshot(
            id: UUID(), name: "Designer", role: "Designer", appearance: .fixture(seed: 3)))
        let reply = message(author: bot, parts: [
            ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: .text("Building both files now.")),
            ChatMessagePartSnapshot(id: UUID(), ordinal: 1, content: .status("OpenBots diagnostic: responseMismatch")),
        ])
        guard case .openableDiagnostic(let diagnostic) = TranscriptStatusPresentation(
            status: "OpenBots diagnostic: responseMismatch", in: reply) else {
            return XCTFail("A diagnostic under a bot's reply must be the chip that opens.")
        }
        XCTAssertEqual(diagnostic.code, .responseMismatch)
        XCTAssertEqual(TranscriptStatusPresentation(status: "Waiting for the card", in: reply), .chip)
        let systemOnly = message(parts: [
            ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: .status("Claude could not complete this reply")),
        ])
        XCTAssertEqual(TranscriptStatusPresentation(status: "Claude could not complete this reply", in: systemOnly),
                       .informational, "App-authored status alone keeps its plain, action-free text.")
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
