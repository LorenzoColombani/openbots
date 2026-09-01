import AppKit
import Combine
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Exercises the production regular composer in an owned, never-ordered
/// native window. Events go directly to that window; nothing is posted to the
/// application or the system. These tests do not prove physical AZERTY/IME
/// input, visible-window focus, or the installed Preview's behavior.
@MainActor
final class ComposerReturnKeyTests: XCTestCase {
    func testShiftReturnAndKeypadEnterInsertAtNativeCaretOrSelectionAndUndo() async throws {
        let cases: [(draft: String, selection: NSRange, expected: String)] = [
            ("", NSRange(location: 0, length: 0), "\n"),
            (
                "  Café 👩🏽‍💻 fin  ",
                NSRange(location: "  Café 👩🏽‍💻".utf16.count, length: 0),
                "  Café 👩🏽‍💻\n fin  "
            ),
            (
                "  e\u{301}👩🏽‍💻中\nlast  ",
                NSRange(location: 2, length: "e\u{301}👩🏽‍💻".utf16.count),
                "  \n中\nlast  "
            ),
            (
                "first\nsecond\nthird  ",
                NSRange(location: "first\nsec".utf16.count, length: 0),
                "first\nsec\nond\nthird  "
            )
        ]

        for key in [ComposerFixtureKey.returnKey, .keypadEnter] {
            for sample in cases {
                let fixture = ComposerNativeFixture(draft: sample.draft)
                defer { fixture.close() }
                let editor = try await fixture.focusEditor(selection: sample.selection)
                let undoManager = try XCTUnwrap(editor.undoManager, "The native composer needs its normal undo manager")
                XCTAssertTrue(editor.allowsUndo)
                editor.breakUndoCoalescing()
                undoManager.removeAllActions()

                try fixture.dispatch(key, modifiers: [.shift])
                try await fixture.settle()

                fixture.assertDraft(sample.expected, editor: editor)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: sample.selection.location + 1, length: 0))
                try await fixture.assertNoSubmission()
                XCTAssertTrue(undoManager.canUndo, "A line break must participate in native text undo")

                undoManager.undo()
                try await fixture.settle()
                fixture.assertDraft(sample.draft, editor: editor)
                try await fixture.assertNoSubmission()
                XCTAssertTrue(undoManager.canRedo, "The native undo stack must retain the line break for redo")

                undoManager.redo()
                try await fixture.settle()
                fixture.assertDraft(sample.expected, editor: editor)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: sample.selection.location + 1, length: 0))
                try await fixture.assertNoSubmission()
                XCTAssertTrue(undoManager.canUndo)

                undoManager.undo()
                try await fixture.settle()
                fixture.assertDraft(sample.draft, editor: editor)
                try await fixture.assertNoSubmission()
            }
        }
    }

    func testOrdinaryReturnAndCommandReturnKeepRegularComposerSubmissionRoutes() async throws {
        for modifiers: NSEvent.ModifierFlags in [[], [.command]] {
            let draft = "  Keep e\u{301} and 👩🏽‍💻\nsecond line  "
            let fixture = ComposerNativeFixture(draft: draft)
            defer { fixture.close() }
            let editor = try await fixture.focusEditor(selection: NSRange(location: 7, length: 0))

            try fixture.dispatch(.returnKey, modifiers: modifiers)
            try await fixture.settle()

            XCTAssertEqual(fixture.attempts.rawTexts, [draft], "The existing explicit submit receives the entire draft")
            XCTAssertEqual(fixture.conversation.messages.count, 1)
            XCTAssertEqual(fixture.conversation.messages.first?.body, draft.trimmingCharacters(in: .whitespacesAndNewlines))
            fixture.assertDraft("", editor: editor)
            let submissions = await fixture.submissions.values
            XCTAssertEqual(submissions.count, 1)
            XCTAssertEqual(submissions.first?.conversationID, fixture.conversationID)
            XCTAssertEqual(submissions.first?.text, draft.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func testRepeatedShiftReturnAndKeypadEnterInsertAnotherNativeNewlineWithoutSubmission() async throws {
        for key in [ComposerFixtureKey.returnKey, .keypadEnter] {
            let fixture = ComposerNativeFixture(draft: "left👩🏽‍💻右")
            defer { fixture.close() }
            let editor = try await fixture.focusEditor(selection: NSRange(location: 4, length: 0))

            try fixture.dispatch(key, modifiers: [.shift])
            try await fixture.settle()
            fixture.assertDraft("left\n👩🏽‍💻右", editor: editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
            try await fixture.assertNoSubmission()

            try fixture.dispatch(key, modifiers: [.shift], isARepeat: true)
            try await fixture.settle()
            fixture.assertDraft("left\n\n👩🏽‍💻右", editor: editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
            try await fixture.assertNoSubmission()
        }
    }

    func testOptionReturnAliasAndUnrelatedShiftedTextKeepNativeEditing() async throws {
        let fixture = ComposerNativeFixture(draft: "left右")
        defer { fixture.close() }
        let editor = try await fixture.focusEditor(selection: NSRange(location: 4, length: 0))

        try fixture.dispatch(.returnKey, modifiers: [.option])
        try await fixture.settle()
        fixture.assertDraft("left\n右", editor: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
        try await fixture.assertNoSubmission()

        try fixture.dispatch(.letterA, modifiers: [.shift])
        try await fixture.settle()
        fixture.assertDraft("left\nA右", editor: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
        try await fixture.assertNoSubmission()
    }

    func testShiftReturnUndoFollowedByNativeSubmitOrEndEditingKeepsOriginalDraft() async throws {
        for submits in [true, false] {
            let draft = "  e\u{301}👩🏽‍💻中\nlast  "
            let fixture = ComposerNativeFixture(draft: draft)
            defer { fixture.close() }
            let editor = try await fixture.focusEditor(
                selection: NSRange(location: 2, length: "e\u{301}👩🏽‍💻".utf16.count)
            )
            let undoManager = try XCTUnwrap(editor.undoManager)
            editor.breakUndoCoalescing()
            undoManager.removeAllActions()
            try fixture.dispatch(.returnKey, modifiers: [.shift])
            try await fixture.settle()
            fixture.assertDraft("  \n中\nlast  ", editor: editor)
            XCTAssertTrue(undoManager.canUndo)

            undoManager.undo()
            XCTAssertTrue(editor.string.utf8.elementsEqual(draft.utf8), "The native undo must restore the original text")
            XCTAssertTrue(fixture.window.firstResponder === editor)
            XCTAssertTrue(fixture.attempts.rawTexts.isEmpty)
            XCTAssertTrue(fixture.conversation.messages.isEmpty)

            // No run-loop or actor yield between undo and the commit action:
            // an asynchronously scheduled binding repair would lose this race.
            // No synthetic change notification or model/editor assignment.
            if submits {
                try fixture.dispatch(.returnKey, modifiers: [])
                try await fixture.settle()
                XCTAssertEqual(fixture.attempts.rawTexts, [draft],
                               "Native Return after undo must submit the restored draft, not the previously inserted newline")
                XCTAssertEqual(fixture.conversation.messages.count, 1)
                XCTAssertEqual(fixture.conversation.messages.first?.body, draft.trimmingCharacters(in: .whitespacesAndNewlines))
                fixture.assertDraft("", editor: editor)
                let submissions = await fixture.submissions.values
                XCTAssertEqual(submissions.count, 1)
                XCTAssertEqual(submissions.first?.conversationID, fixture.conversationID)
                XCTAssertEqual(submissions.first?.text, draft.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                XCTAssertTrue(fixture.window.makeFirstResponder(nil))
                try await fixture.settle()
                fixture.assertStoredDraft(draft)
                try await fixture.assertNoSubmission()
            }
        }
    }

    func testOtherFieldUndoAfterComposerResignsDoesNotReceiveExtraChangeNotifications() async throws {
        var notificationCounts: [Int] = []
        for armsComposerObserver in [false, true] {
            let fixture = ComposerNativeFixture(draft: "Owned composer")
            defer { fixture.close() }
            let composerEditor = try await fixture.focusEditor(selection: NSRange(location: 5, length: 0))
            let composerField = try XCTUnwrap(composerEditor.delegate as? NSTextField)
            if armsComposerObserver {
                try fixture.dispatch(.returnKey, modifiers: [.shift])
                try await fixture.settle()
            }
            let composerDraft = armsComposerObserver ? "Owned\n composer" : "Owned composer"
            fixture.assertDraft(composerDraft, editor: composerEditor)

            let otherField = fixture.addUnrelatedField(text: "Other field")
            XCTAssertTrue(fixture.window.makeFirstResponder(otherField))
            otherField.selectText(nil)
            try await fixture.settle()
            let otherEditor = try XCTUnwrap(otherField.currentEditor() as? NSTextView)
            XCTAssertTrue(fixture.window.firstResponder === otherEditor)
            // This hidden host did not reproduce shared-editor reuse between
            // SwiftUI and the added AppKit field. Verify actual ownership and
            // focus retirement without forcing a private editor-reuse path.
            XCTAssertTrue(otherField.window === fixture.window)
            XCTAssertTrue(otherEditor.window === fixture.window)
            XCTAssertTrue(otherField.currentEditor() === otherEditor)
            XCTAssertTrue(otherEditor.delegate === otherField)
            let undoManager = try XCTUnwrap(otherEditor.undoManager)
            otherEditor.setSelectedRange(NSRange(location: "Other field".utf16.count, length: 0))
            otherEditor.breakUndoCoalescing()
            undoManager.removeAllActions()

            let changes = ComposerFixtureChangeCounter()
            NotificationCenter.default.addObserver(
                changes, selector: #selector(ComposerFixtureChangeCounter.recordTextChange),
                name: NSText.didChangeNotification, object: otherEditor
            )
            defer { NotificationCenter.default.removeObserver(changes) }
            let publication = fixture.conversation.$composerText.dropFirst().sink { _ in
                changes.composerPublications += 1
            }
            defer { publication.cancel() }

            try fixture.dispatch(.letterA, modifiers: [.shift])
            try await fixture.settle()
            XCTAssertEqual(otherEditor.string, "Other fieldA")
            XCTAssertEqual(otherField.stringValue, "Other fieldA")
            XCTAssertTrue(undoManager.canUndo)
            changes.textChanges = 0

            undoManager.undo()
            try await fixture.settle()
            XCTAssertEqual(otherEditor.string, "Other field")
            XCTAssertEqual(otherField.stringValue, "Other field")
            XCTAssertTrue(fixture.window.firstResponder === otherEditor)
            XCTAssertEqual(composerField.stringValue, composerDraft)
            XCTAssertEqual(fixture.conversation.composerText, composerDraft)
            XCTAssertEqual(changes.composerPublications, 0, "Another field's edit/undo must not rebind the retired composer")
            notificationCounts.append(changes.textChanges)
            try await fixture.assertNoSubmission()
        }
        XCTAssertEqual(notificationCounts.count, 2)
        XCTAssertEqual(notificationCounts.first, notificationCounts.last,
                       "A prior composer Shift-Return must not add didChangeText calls to another field's native undo")
    }

    func testRetiredHandlerSessionDoesNotRebindOnLaterNativeUndo() async throws {
        var publicationCounts: [Int] = []
        var notificationCounts: [Int] = []
        var boundDrafts: [String] = []
        for retiresObservedSession in [false, true] {
            let fixture = ComposerNativeFixture(draft: "Retired session")
            defer { fixture.close() }
            let editor = try await fixture.focusEditor(selection: NSRange(location: 7, length: 0))
            let undoManager = try XCTUnwrap(editor.undoManager)
            editor.breakUndoCoalescing()
            undoManager.removeAllActions()
            let handler = ComposerReturnKeyHandler()
            handler.attach(editor)
            defer { handler.detach(editor) }
            // Both paths use the actual composer's native editor. Neither
            // dispatches a key to arm the root view's separate handler.
            if retiresObservedSession {
                XCTAssertEqual(handler.handleReturn(modifiers: [.shift]), .handled)
            } else {
                editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            try await fixture.settle()
            fixture.assertDraft("Retired\n session", editor: editor)
            let changes = ComposerFixtureChangeCounter()
            NotificationCenter.default.addObserver(
                changes, selector: #selector(ComposerFixtureChangeCounter.recordTextChange),
                name: NSText.didChangeNotification, object: editor
            )
            defer { NotificationCenter.default.removeObserver(changes) }
            let publication = fixture.conversation.$composerText.dropFirst().sink { _ in
                changes.composerPublications += 1
            }
            defer { publication.cancel() }

            if retiresObservedSession { handler.endEditingSession() }
            XCTAssertTrue(undoManager.canUndo)
            undoManager.undo()
            try await fixture.settle()
            XCTAssertEqual(editor.string, "Retired session", "Retiring observation must leave native undo intact")
            publicationCounts.append(changes.composerPublications)
            notificationCounts.append(changes.textChanges)
            boundDrafts.append(fixture.conversation.composerText)
            try await fixture.assertNoSubmission()
        }
        XCTAssertEqual(publicationCounts.count, 2)
        XCTAssertEqual(publicationCounts.first, publicationCounts.last,
                       "A retired handler must not add model publications to native undo")
        XCTAssertEqual(notificationCounts.first, notificationCounts.last,
                       "A retired handler must not add didChangeText calls to native undo")
        XCTAssertEqual(boundDrafts.first, boundDrafts.last,
                       "Retirement must preserve the unobserved native binding behavior, including future native fixes")
    }

    func testNativeMarkedTextAndUnrelatedModifiersAreNotConsumedByReturnHandler() async throws {
        let fixture = ComposerNativeFixture(draft: "before after")
        defer { fixture.close() }
        let editor = try await fixture.focusEditor(selection: NSRange(location: 7, length: 0))
        let handler = ComposerReturnKeyHandler()
        handler.attach(editor)
        defer { handler.detach(editor) }

        // This is a native marked range, not a fake hasMarkedText predicate.
        // Invoke the handler only: a synthetic Return cannot stand in for an
        // actual input method's decision to commit or continue composition.
        editor.setMarkedText(
            "に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try await fixture.settle()
        XCTAssertTrue(editor.hasMarkedText())
        let markedDraft = editor.string
        let boundDraft = fixture.conversation.composerText
        let markedRange = editor.markedRange()
        let selection = editor.selectedRange()

        XCTAssertEqual(handler.handleReturn(modifiers: [.shift]), .ignored)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(editor.string.utf8.elementsEqual(markedDraft.utf8))
        XCTAssertTrue(fixture.conversation.composerText.utf8.elementsEqual(boundDraft.utf8))
        try await fixture.assertNoSubmission()

        editor.unmarkText()
        try await fixture.settle()
        let unmarkedDraft = editor.string
        let unmarkedBoundDraft = fixture.conversation.composerText
        let unmarkedSelection = editor.selectedRange()
        for modifiers: EventModifiers in [[], [.option], [.command], [.control],
                                           [.shift, .command], [.shift, .option], [.shift, .control]] {
            XCTAssertEqual(handler.handleReturn(modifiers: modifiers), .ignored)
        }
        XCTAssertEqual(editor.selectedRange(), unmarkedSelection)
        XCTAssertTrue(editor.string.utf8.elementsEqual(unmarkedDraft.utf8))
        XCTAssertTrue(fixture.conversation.composerText.utf8.elementsEqual(unmarkedBoundDraft.utf8))
        XCTAssertTrue(fixture.window.firstResponder === editor)
        try await fixture.assertNoSubmission()
    }

    func testDetachedOrUnfocusedHandlerCannotChooseAnotherWindowEditor() async throws {
        let fixture = ComposerNativeFixture(draft: "Owned draft")
        defer { fixture.close() }
        let editor = try await fixture.focusEditor(selection: NSRange(location: 5, length: 0))
        let handler = ComposerReturnKeyHandler()
        let unattached = NSView()

        handler.attach(unattached)
        XCTAssertEqual(handler.handleReturn(modifiers: [.shift]), .ignored)
        fixture.assertDraft("Owned draft", editor: editor)

        handler.attach(editor)
        handler.detach(unattached)
        XCTAssertEqual(handler.handleReturn(modifiers: [.shift]), .handled,
                       "A stale detach must not discard the currently attached native editor")
        try await fixture.settle()
        fixture.assertDraft("Owned\n draft", editor: editor)
        handler.detach(editor)
        XCTAssertEqual(handler.handleReturn(modifiers: [.shift]), .ignored)
        fixture.assertDraft("Owned\n draft", editor: editor)

        handler.attach(editor)
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertEqual(handler.handleReturn(modifiers: [.shift]), .ignored)
        try await fixture.settle()
        // AppKit may clear its shared field editor when editing ends. The
        // owning control and model retain the draft, not that released buffer.
        fixture.assertStoredDraft("Owned\n draft")
        handler.detach(editor)
        try await fixture.assertNoSubmission()
    }
}

@MainActor
private final class ComposerNativeFixture {
    let conversationID = UUID()
    let conversation: ConversationModel
    let submissions = ComposerFixtureSubmissions()
    let attempts = ComposerFixtureSubmissionAttempts()
    let window: ComposerFixtureWindow
    private let controller: NSHostingController<AnyView>
    private var composerControl: NSView?

    init(draft: String) {
        _ = NSApplication.shared
        let submissions = self.submissions
        let attempts = self.attempts
        conversation = ConversationModel(
            conversationID: conversationID, title: "Native Composer Fixture", composerText: draft,
            readyDeliveryDescription: "In-memory local composer test; no runtime or storage.",
            isLocalOnly: true, inputAvailability: .ready,
            submit: { _, conversationID, text in
                await submissions.record(conversationID: conversationID, text: text)
            },
            beforeSubmission: { _, _, rawText in
                attempts.rawTexts.append(rawText)
                return true
            }
        )
        let teammate = TeammateRowSnapshot(
            id: UUID(), name: "Native Composer Fixture", role: "In-memory test", activity: .idle, identitySeed: 31
        )
        let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
        let root = OpenBotsRootView(
            sidebar: sidebar, conversation: conversation,
            createTeammate: { XCTFail("Composer input must not create a teammate") },
            openSettings: { XCTFail("Composer input must not open Settings") }
        )
        controller = NSHostingController(rootView: AnyView(root
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)))
        controller.sizingOptions = .minSize
        window = ComposerFixtureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame.size = NSSize(width: 940, height: 720)
    }

    func focusEditor(selection: NSRange) async throws -> NSTextView {
        try await settle()
        let draft = conversation.composerText
        let nativeControl = try XCTUnwrap(controller.view.composerDescendants.first { view in
            if let editor = view as? NSTextView { return editor.isEditable && editor.string.utf8.elementsEqual(draft.utf8) }
            if let field = view as? NSTextField { return field.isEditable && field.stringValue.utf8.elementsEqual(draft.utf8) }
            return false
        }, "The actual regular composer's native editor must mount")
        composerControl = nativeControl
        XCTAssertTrue(window.makeFirstResponder(nativeControl))
        if let field = nativeControl as? NSTextField { field.selectText(nil) }
        try await settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView,
                                  "Focus must resolve to the regular composer's native text editor")
        XCTAssertTrue(editor.window === window)
        XCTAssertTrue(editor.isEditable)
        XCTAssertFalse(editor.hasMarkedText())
        editor.setSelectedRange(selection)
        XCTAssertEqual(editor.selectedRange(), selection)
        assertDraft(draft, editor: editor)
        return editor
    }

    func dispatch(_ key: ComposerFixtureKey, modifiers: NSEvent.ModifierFlags, isARepeat: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: modifiers.union(key.additionalModifiers),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            isARepeat: isARepeat, keyCode: key.keyCode
        ))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        // NSApplication normally offers Command shortcuts before keyDown.
        // Keep both phases confined to this owned window, never NSApp.sendEvent.
        if modifiers.contains(.command), window.performKeyEquivalent(with: event) { return }
        window.sendEvent(event)
    }

    func addUnrelatedField(text: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = true
        field.isSelectable = true
        field.frame = NSRect(x: 20, y: 20, width: 200, height: 28)
        controller.view.addSubview(field)
        return field
    }

    func assertDraft(_ expected: String, editor: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(editor.string.utf8.elementsEqual(expected.utf8),
                      "Native draft mismatch: \(editor.string.debugDescription); expected \(expected.debugDescription)", file: file, line: line)
        XCTAssertTrue(conversation.composerText.utf8.elementsEqual(expected.utf8),
                      "Bound draft mismatch: \(conversation.composerText.debugDescription); expected \(expected.debugDescription). "
                        + "Native editor: \(editor.string.debugDescription); owning control: \(storedNativeValue?.debugDescription ?? "nil"). "
                        + "Bound UTF-8: \(Array(conversation.composerText.utf8)); expected UTF-8: \(Array(expected.utf8))",
                      file: file, line: line)
        XCTAssertTrue(window.firstResponder === editor, "Native editing must retain composer focus", file: file, line: line)
        XCTAssertFalse(window.isVisible, file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, file: file, line: line)
    }

    func assertStoredDraft(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(storedNativeValue?.utf8.elementsEqual(expected.utf8) == true,
                      "Owning native control mismatch after editing ended: \(storedNativeValue?.debugDescription ?? "nil"); "
                        + "expected \(expected.debugDescription)", file: file, line: line)
        XCTAssertTrue(conversation.composerText.utf8.elementsEqual(expected.utf8),
                      "Stored bound draft mismatch: \(conversation.composerText.debugDescription); expected \(expected.debugDescription)",
                      file: file, line: line)
        XCTAssertFalse(window.firstResponder is NSTextView, "The handler must remain unfocused", file: file, line: line)
        XCTAssertFalse(window.isVisible, file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, file: file, line: line)
    }

    private var storedNativeValue: String? {
        if let field = composerControl as? NSTextField { return field.stringValue }
        if let editor = composerControl as? NSTextView, !editor.isFieldEditor { return editor.string }
        return nil
    }

    func assertNoSubmission(file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(attempts.rawTexts.isEmpty, "A line break must not reach the submit hook", file: file, line: line)
        XCTAssertTrue(conversation.messages.isEmpty, "A line break must not create a pending message", file: file, line: line)
        let values = await submissions.values
        XCTAssertTrue(values.isEmpty, "A line break must not invoke the local delivery adapter", file: file, line: line)
    }

    func settle() async throws {
        for _ in 0..<6 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func close() {
        conversation.finishShutdown()
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.close()
    }
}

private enum ComposerFixtureKey {
    case returnKey, keypadEnter, letterA

    var keyCode: UInt16 {
        switch self {
        case .returnKey: 36
        case .keypadEnter: 76
        case .letterA: 0
        }
    }

    var characters: String {
        switch self {
        case .returnKey: "\r"
        case .keypadEnter: "\u{3}"
        case .letterA: "A"
        }
    }

    var charactersIgnoringModifiers: String { self == .letterA ? "a" : characters }
    var additionalModifiers: NSEvent.ModifierFlags { self == .keypadEnter ? [.numericPad] : [] }
}

@MainActor
private final class ComposerFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ComposerFixtureSubmissionAttempts {
    var rawTexts: [String] = []
}

@MainActor
private final class ComposerFixtureChangeCounter: NSObject {
    var textChanges = 0
    var composerPublications = 0

    @objc func recordTextChange(_ notification: Notification) {
        textChanges += 1
    }
}

private actor ComposerFixtureSubmissions {
    struct Submission: Sendable {
        let conversationID: UUID
        let text: String
    }
    private(set) var values: [Submission] = []

    func record(conversationID: UUID, text: String) {
        values.append(Submission(conversationID: conversationID, text: text))
    }
}

private extension NSView {
    var composerDescendants: [NSView] { [self] + subviews.flatMap(\.composerDescendants) }
}
