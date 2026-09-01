import AppKit
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Production-root native editing with the real draft coordinator/service and
/// an in-memory CAS repository. No installed app, global pasteboard, visible
/// window, global event posting, or physical keyboard/IME claim is involved.
@MainActor
final class ComposerUndoGroupingTests: XCTestCase {
    func testTypingUsesVariableGroupsAtExactInactivityThresholdBeforeAnyShift() async throws {
        for gap in [0.999, 1.0, 1.001] {
            let fixture = try UndoGroupingFixture()
            defer { fixture.close() }
            let editor = try await fixture.prepareEditor()
            let manager = try XCTUnwrap(editor.undoManager)
            let prefix = "alpha beta "
            let suffix = "gamma"

            try await fixture.type(prefix)
            fixture.clock.now += gap
            try await fixture.type(suffix)
            try await fixture.assertState(prefix + suffix, editor: editor)

            XCTAssertTrue(manager.canUndo)
            manager.undo()
            try await fixture.settle()
            if gap < 1 {
                try await fixture.assertState("", editor: editor)
            } else {
                try await fixture.assertState(prefix, editor: editor)
                XCTAssertTrue(manager.canUndo)
                manager.undo()
                try await fixture.settle()
                try await fixture.assertState("", editor: editor)
            }
            XCTAssertFalse(manager.canUndo, "Continuous words form variable chunks, not one group per character or word")
            XCTAssertTrue(manager.canRedo)
            manager.redo()
            try await fixture.settle()
            if gap < 1 {
                try await fixture.assertState(prefix + suffix, editor: editor)
            } else {
                try await fixture.assertState(prefix, editor: editor)
                XCTAssertTrue(manager.canRedo)
                manager.redo()
                try await fixture.settle()
                try await fixture.assertState(prefix + suffix, editor: editor)
            }
            XCTAssertFalse(manager.canRedo)
            try await fixture.assertNoSubmission()
        }
    }

    func testEachShiftNewlineSeparatesTheTypingBeforeAndAfterItThroughUndoRedo() async throws {
        let seed = "Élan "
        let fixture = try UndoGroupingFixture(initialDraft: seed)
        defer { fixture.close() }
        let editor = try await fixture.prepareEditor()
        let manager = try XCTUnwrap(editor.undoManager)
        try await fixture.type("red green")
        try fixture.key("\r", keyCode: 36, modifiers: [.shift])
        try await fixture.settle()
        try await fixture.type("blue")
        try fixture.key("\u{3}", keyCode: 76, modifiers: [.shift, .numericPad])
        try await fixture.settle()
        try await fixture.type("gold")
        let completed = "Élan red green\nblue\ngold"
        try await fixture.assertState(completed, editor: editor)

        let undoStates = ["Élan red green\nblue\n", "Élan red green\nblue", "Élan red green\n", "Élan red green", seed]
        for expected in undoStates {
            XCTAssertTrue(manager.canUndo)
            manager.undo()
            try await fixture.settle()
            try await fixture.assertState(expected, editor: editor)
        }
        XCTAssertFalse(manager.canUndo)
        for expected in Array(undoStates.dropLast().reversed()) + [completed] {
            XCTAssertTrue(manager.canRedo)
            manager.redo()
            try await fixture.settle()
            try await fixture.assertState(expected, editor: editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: expected.utf16.count, length: 0))
        }
        XCTAssertFalse(manager.canRedo)
        try await fixture.assertNoSubmission()
    }

    func testUnicodeSelectionReplacementAndNativeCaretMoveRemainSeparateEdits() async throws {
        let seed = "  e\u{301}👩🏽‍💻 middle"
        let fixture = try UndoGroupingFixture(initialDraft: seed)
        defer { fixture.close() }
        let editor = try await fixture.prepareEditor()
        let manager = try XCTUnwrap(editor.undoManager)
        try await fixture.type("!")
        let selection = NSRange(location: 2, length: "e\u{301}👩🏽‍💻".utf16.count)
        editor.setSelectedRange(selection)
        XCTAssertEqual(editor.selectedRange(), selection)
        try await fixture.type("R")
        try await fixture.assertState("  R middle!", editor: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))

        manager.undo()
        try await fixture.settle()
        try await fixture.assertState(seed + "!", editor: editor)
        manager.redo()
        try await fixture.settle()
        try await fixture.assertState("  R middle!", editor: editor)

        // A public native movement command changes the caret without writing
        // the draft or introducing an artificial undo-group boundary.
        editor.moveToEndOfDocument(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: "  R middle!".utf16.count, length: 0))
        try await fixture.type("?")
        try await fixture.assertState("  R middle!?", editor: editor)
        manager.undo()
        try await fixture.settle()
        try await fixture.assertState("  R middle!", editor: editor)
        manager.undo()
        try await fixture.settle()
        try await fixture.assertState(seed + "!", editor: editor)
        manager.undo()
        try await fixture.settle()
        try await fixture.assertState(seed, editor: editor)
        for expected in [seed + "!", "  R middle!", "  R middle!?"] {
            XCTAssertTrue(manager.canRedo)
            manager.redo()
            try await fixture.settle()
            try await fixture.assertState(expected, editor: editor)
        }
        XCTAssertFalse(manager.canRedo)
        try await fixture.assertNoSubmission()
    }

    func testPrivateNativePasteIsOneUnicodeEditIncludingBeforeAnyTyping() async throws {
        for prefix in ["", "lead "] {
            let fixture = try UndoGroupingFixture()
            defer { fixture.close() }
            let editor = try await fixture.prepareEditor()
            let manager = try XCTUnwrap(editor.undoManager)
            if !prefix.isEmpty { try await fixture.type(prefix) }
            let pasted = "e\u{301}👩🏽‍💻\n中"
            // Use only this unique native pasteboard, never .general. A
            // sandbox without the pasteboard service cannot pass this check.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenBotsUndoTest-\(UUID())"))
            defer { pasteboard.clearContents() }
            pasteboard.clearContents()
            guard pasteboard.setString(pasted, forType: .string) else {
                throw XCTSkip("The named native pasteboard service is unavailable in this host; paste grouping remains unverified.")
            }
            guard editor.readSelection(from: pasteboard, type: .string) else {
                throw XCTSkip("Native readSelection could not read the owned named pasteboard; paste grouping remains unverified.")
            }
            try await fixture.settle()
            try await fixture.assertState(prefix + pasted, editor: editor)
            try await fixture.type(" tail")
            try await fixture.assertState(prefix + pasted + " tail", editor: editor)

            manager.undo()
            try await fixture.settle()
            try await fixture.assertState(prefix + pasted, editor: editor)
            manager.undo()
            try await fixture.settle()
            try await fixture.assertState(prefix, editor: editor)
            if !prefix.isEmpty {
                manager.undo()
                try await fixture.settle()
                try await fixture.assertState("", editor: editor)
                manager.redo()
                try await fixture.settle()
                try await fixture.assertState(prefix, editor: editor)
            }
            manager.redo()
            try await fixture.settle()
            try await fixture.assertState(prefix + pasted, editor: editor)
            manager.redo()
            try await fixture.settle()
            try await fixture.assertState(prefix + pasted + " tail", editor: editor)
            try await fixture.assertNoSubmission()
        }
    }

    func testNativeMarkedCompositionIsNotSplitByElapsedTime() async throws {
        let fixture = try UndoGroupingFixture()
        defer { fixture.close() }
        let editor = try await fixture.prepareEditor()
        let manager = try XCTUnwrap(editor.undoManager)
        // The real editor is focused, but no key has primed the handler. A
        // first composition (like a first menu paste) must acquire undo/binding
        // observation from native editing, not depend on an earlier keystroke.
        XCTAssertTrue(fixture.window.firstResponder === editor)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        fixture.clock.now += 2
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        fixture.clock.now += 2
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        try await fixture.settle()
        try await fixture.assertState("日本", editor: editor)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        try await fixture.settle()
        try await fixture.assertState("", editor: editor)
        XCTAssertFalse(manager.canUndo, "One composition must not become a group per provisional marked string")
        manager.redo()
        try await fixture.settle()
        try await fixture.assertState("日本", editor: editor)
        try await fixture.assertNoSubmission()
    }

    func testFocusAndConversationChangesPreserveSeparateDraftsAndNewTypingGroups() async throws {
        let fixture = try UndoGroupingFixture()
        defer { fixture.close() }
        let firstID = fixture.initialConversationID
        var editor = try await fixture.prepareEditor()
        try await fixture.type("alpha")
        try await fixture.assertState("alpha", editor: editor)
        let otherField = fixture.addOtherField()
        XCTAssertTrue(fixture.window.makeFirstResponder(otherField))
        otherField.selectText(nil)
        try await fixture.settle()
        XCTAssertTrue(otherField.currentEditor() === fixture.window.firstResponder)
        editor = try await fixture.focusEditor()
        try await fixture.type("beta")
        let manager = try XCTUnwrap(editor.undoManager)
        manager.undo()
        try await fixture.settle()
        try await fixture.assertState("alpha", editor: editor)

        let secondID = UUID()
        try await fixture.activate(secondID)
        editor = try await fixture.focusEditor()
        try await fixture.type("bravo")
        try await fixture.assertState("bravo", editor: editor)
        let secondManager = try XCTUnwrap(editor.undoManager)
        secondManager.undo()
        try await fixture.settle()
        try await fixture.assertState("", editor: editor)
        let firstSaved = try await fixture.service.load(conversationID: ConversationID(firstID))
        XCTAssertEqual(firstSaved?.text, "alpha")
        secondManager.redo()
        try await fixture.settle()
        try await fixture.assertState("bravo", editor: editor)

        try await fixture.activate(firstID)
        editor = try await fixture.focusEditor()
        try await fixture.assertState("alpha", editor: editor)
        try await fixture.type("gamma")
        try XCTUnwrap(editor.undoManager).undo()
        try await fixture.settle()
        try await fixture.assertState("alpha", editor: editor)
        let secondSaved = try await fixture.service.load(conversationID: ConversationID(secondID))
        XCTAssertEqual(secondSaved?.text, "bravo")
        try await fixture.assertNoSubmission()
    }

    func testImmediateReturnAfterPlainTypingUndoSavesOnlyRestoredDurableBody() async throws {
        let fixture = try UndoGroupingFixture()
        defer { fixture.close() }
        let editor = try await fixture.prepareEditor()
        try await fixture.type("first")
        fixture.clock.now += 1.0
        try await fixture.type(" second")
        try await fixture.assertState("first second", editor: editor)
        let manager = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        // No actor/run-loop yield between undo and the actual Return route.
        try fixture.key("\r", keyCode: 36)
        try await fixture.waitForSubmission()
        try await fixture.settle()
        XCTAssertEqual(fixture.relay.rawAttempts, ["first"])
        XCTAssertEqual(fixture.conversation.messages.count, 1)
        XCTAssertEqual(fixture.conversation.messages.first?.body, "first")
        let savedMessages = await fixture.repository.messages
        XCTAssertEqual(savedMessages.count, 1)
        XCTAssertEqual(savedMessages.first?.conversationID, fixture.initialConversationID)
        XCTAssertEqual(savedMessages.first?.body, "first")
        XCTAssertEqual(savedMessages.first?.draftSafetyCopy, "first")
        try await fixture.assertState("", editor: editor)
    }

    func testNativeFieldRestartRearmsOnlyOwnedSessionUntilRetirementOrDetach() async throws {
        var receipts: [String: (undo: Int, redo: Int)] = [:]
        for mode in ["baseline", "restart", "retired", "detached", "other-field"] {
            _ = NSApplication.shared
            let window = UndoGroupingWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                            styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
            let field = NSTextField(string: "Seed")
            let otherField = NSTextField(string: "SeedI")
            field.frame = NSRect(x: 12, y: 70, width: 300, height: 24)
            otherField.frame = NSRect(x: 12, y: 30, width: 300, height: 24)
            let attachment = NSView(frame: .zero)
            content.addSubview(field)
            content.addSubview(otherField)
            content.addSubview(attachment)
            window.contentView = content
            let changes = UndoGroupingLifecycleDelegate()
            field.delegate = changes
            otherField.delegate = changes
            let handler = ComposerReturnKeyHandler()
            defer {
                handler.detach(attachment)
                window.makeFirstResponder(nil)
                window.contentView = nil
                window.close()
            }
            XCTAssertTrue(window.makeFirstResponder(field))
            field.selectText(nil)
            let firstEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            firstEditor.allowsUndo = true // This plain fixture tests observation, not SwiftUI editor configuration.
            firstEditor.setSelectedRange(NSRange(location: 4, length: 0))
            if mode != "baseline" {
                handler.attach(attachment)
                handler.updateFocus(true, clock: { 100 })
            }
            firstEditor.insertText("I", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settleUndoGroupingLifecycle(window)
            XCTAssertTrue(window.makeFirstResponder(nil))
            XCTAssertGreaterThanOrEqual(changes.ends, 1, "The fixture must deliver a real native end-edit notification")
            if mode == "retired" { handler.endEditingSession() }
            if mode == "detached" { handler.detach(attachment) }

            // Keep the handler's SwiftUI-style focus request unchanged while
            // AppKit begins another native session. No key handler is invoked.
            let target = mode == "other-field" ? otherField : field
            XCTAssertTrue(window.makeFirstResponder(target))
            target.selectText(nil)
            let editor = try XCTUnwrap(target.currentEditor() as? NSTextView)
            XCTAssertTrue(editor.window === window && window.firstResponder === editor)
            XCTAssertTrue(editor.delegate === target)
            editor.allowsUndo = true
            editor.setSelectedRange(NSRange(location: 5, length: 0))
            let manager = try XCTUnwrap(editor.undoManager)
            manager.removeAllActions()
            editor.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settleUndoGroupingLifecycle(window)
            XCTAssertGreaterThanOrEqual(changes.begins, 2, "The same-field restart must enter actual native editing again")
            XCTAssertEqual(editor.string, "SeedIZ")
            XCTAssertTrue(manager.canUndo)
            let beforeUndo = changes.changes
            manager.undo()
            try await settleUndoGroupingLifecycle(window)
            XCTAssertEqual(editor.string, "SeedI")
            XCTAssertEqual(target.stringValue, "SeedI")
            let undoChanges = changes.changes - beforeUndo
            XCTAssertTrue(manager.canRedo)
            let beforeRedo = changes.changes
            manager.redo()
            try await settleUndoGroupingLifecycle(window)
            XCTAssertEqual(editor.string, "SeedIZ")
            XCTAssertEqual(target.stringValue, "SeedIZ")
            receipts[mode] = (undoChanges, changes.changes - beforeRedo)
        }
        let baseline = try XCTUnwrap(receipts["baseline"])
        let restarted = try XCTUnwrap(receipts["restart"])
        XCTAssertGreaterThan(restarted.undo, baseline.undo, "The same-field native restart must reacquire undo publication without a key")
        XCTAssertGreaterThan(restarted.redo, baseline.redo, "The same-field native restart must reacquire redo publication without a key")
        for mode in ["retired", "detached", "other-field"] {
            let receipt = try XCTUnwrap(receipts[mode])
            XCTAssertEqual(receipt.undo, baseline.undo, "\(mode) must not add undo synchronization to ordinary native behavior")
            XCTAssertEqual(receipt.redo, baseline.redo, "\(mode) must not add redo synchronization to ordinary native behavior")
        }
    }
}

@MainActor
private final class UndoGroupingFixture {
    let initialConversationID: UUID
    let clock = UndoGroupingClock()
    let repository: UndoGroupingRepository
    let service: ConversationDraftService
    let relay: UndoGroupingSubmissionRelay
    let conversation: ConversationModel
    let coordinator: WorkspaceDraftCoordinator
    let window: UndoGroupingWindow
    private let controller: NSHostingController<AnyView>

    init(initialDraft: String = "") throws {
        _ = NSApplication.shared
        let id = UUID()
        initialConversationID = id
        let seed = try ConversationDraftSnapshot(conversationID: ConversationID(id), text: initialDraft,
                                                  revision: 1, updatedAt: Date(timeIntervalSince1970: 1_000))
        repository = UndoGroupingRepository(seed: seed)
        service = ConversationDraftService(repository: repository)
        let relay = UndoGroupingSubmissionRelay(repository: repository)
        self.relay = relay
        conversation = ConversationModel(
            conversationID: id, title: "Undo Grouping Fixture",
            readyDeliveryDescription: "Owned in-memory draft persistence fixture; no runtime.",
            isLocalOnly: true, inputAvailability: .ready,
            submit: { messageID, conversationID, text in
                await relay.persist(messageID: messageID, conversationID: conversationID, body: text)
            },
            beforeSubmission: { messageID, conversationID, rawText in
                relay.begin(messageID: messageID, conversationID: conversationID, rawText: rawText)
            }
        )
        coordinator = WorkspaceDraftCoordinator(conversation: conversation, service: service)
        relay.coordinator = coordinator
        let teammate = TeammateRowSnapshot(id: UUID(), name: "Undo Grouping Fixture", role: "Native test",
                                           activity: .idle, identitySeed: 47)
        let clock = self.clock
        let root = OpenBotsRootView(
            sidebar: SidebarModel(rows: [teammate], selection: teammate.id), conversation: conversation,
            draftCoordinator: coordinator,
            createTeammate: { XCTFail("Undo must not create a teammate") },
            openSettings: { XCTFail("Undo must not open Settings") }
        )
        .environment(\.composerEditingClock, { clock.now })
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = .minSize
        window = UndoGroupingWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame.size = NSSize(width: 940, height: 720)
    }

    func prepareEditor() async throws -> NSTextView {
        coordinator.activate(conversationID: initialConversationID)
        await coordinator.activeDraft?.load()
        let editor = try await focusEditor()
        // Only establish a clean starting stack; no test inserts a coalescing
        // break or clears history between the editing operations under test.
        try XCTUnwrap(editor.undoManager).removeAllActions()
        return editor
    }

    func focusEditor() async throws -> NSTextView {
        try await settle()
        let draft = conversation.composerText
        let control = try XCTUnwrap(controller.view.undoGroupingDescendants.first { view in
            if let field = view as? NSTextField { return field.isEditable && field.stringValue.utf8.elementsEqual(draft.utf8) }
            if let editor = view as? NSTextView { return editor.isEditable && editor.string.utf8.elementsEqual(draft.utf8) }
            return false
        })
        XCTAssertTrue(window.makeFirstResponder(control))
        if let field = control as? NSTextField { field.selectText(nil) }
        try await settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.window === window)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.allowsUndo)
        editor.setSelectedRange(NSRange(location: draft.utf16.count, length: 0))
        return editor
    }

    func activate(_ conversationID: UUID) async throws {
        let flushed = await coordinator.flushAll()
        XCTAssertTrue(flushed)
        conversation.show(conversationID: conversationID, title: "Undo Grouping Fixture", messages: [])
        coordinator.activate(conversationID: conversationID)
        await coordinator.activeDraft?.load()
        try await settle()
    }

    func type(_ text: String) async throws {
        for (index, character) in text.enumerated() {
            if index > 0 { clock.now += 0.125 }
            try key(String(character), keyCode: 0)
            try await settle(turns: 1)
        }
    }

    func key(_ text: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: keyCode
        ))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        window.sendEvent(event)
    }

    func assertState(_ expected: String, editor: NSTextView, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(editor.string.utf8.elementsEqual(expected.utf8),
                      "Native \(editor.string.debugDescription), expected \(expected.debugDescription)", file: file, line: line)
        XCTAssertTrue(conversation.composerText.utf8.elementsEqual(expected.utf8),
                      "Bound \(conversation.composerText.debugDescription), expected \(expected.debugDescription)", file: file, line: line)
        XCTAssertTrue(coordinator.activeDraft?.text.utf8.elementsEqual(expected.utf8) == true,
                      "The real coordinator must forward every native Undo/Redo result", file: file, line: line)
        XCTAssertTrue(window.firstResponder === editor, file: file, line: line)
        let saved = await coordinator.flushAll()
        XCTAssertTrue(saved, "The draft must reach its repository checkpoint", file: file, line: line)
        let id = try XCTUnwrap(conversation.conversationID, file: file, line: line)
        let stored = try await service.load(conversationID: ConversationID(id))
        XCTAssertTrue(stored?.text.utf8.elementsEqual(expected.utf8) == true,
                      "Persisted \(stored?.text.debugDescription ?? "nil"), expected \(expected.debugDescription)", file: file, line: line)
        XCTAssertFalse(window.isVisible, file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, file: file, line: line)
    }

    func assertNoSubmission(file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(relay.rawAttempts.isEmpty, file: file, line: line)
        XCTAssertTrue(conversation.messages.isEmpty, file: file, line: line)
        let savedMessages = await repository.messages
        XCTAssertTrue(savedMessages.isEmpty, "Editing and Undo/Redo must not persist a message", file: file, line: line)
    }

    func addOtherField() -> NSTextField {
        let field = NSTextField(string: "Other native input")
        field.isEditable = true
        field.isSelectable = true
        field.frame = NSRect(x: 20, y: 20, width: 180, height: 28)
        controller.view.addSubview(field)
        return field
    }

    func waitForSubmission() async throws {
        for _ in 0..<100 {
            if relay.completedSubmissions == 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The injected durable submission did not complete")
    }

    func settle(turns: Int = 4) async throws {
        for _ in 0..<turns {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
    }

    func close() {
        conversation.finishShutdown()
        coordinator.finishShutdown()
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.close()
    }
}

@MainActor
private final class UndoGroupingClock { var now: TimeInterval = 100 }

@MainActor
private final class UndoGroupingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class UndoGroupingLifecycleDelegate: NSObject, NSTextFieldDelegate {
    var begins = 0
    var ends = 0
    var changes = 0
    func controlTextDidBeginEditing(_ notification: Notification) { begins += 1 }
    func controlTextDidEndEditing(_ notification: Notification) { ends += 1 }
    func controlTextDidChange(_ notification: Notification) { changes += 1 }
}

@MainActor
private func settleUndoGroupingLifecycle(_ window: NSWindow) async throws {
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertFalse(window.isMainWindow)
}

private actor UndoGroupingRepository: ConversationDraftRepository {
    struct SavedMessage: Sendable {
        let conversationID: UUID
        let body: String
        let draftSafetyCopy: String
    }
    private var drafts: [ConversationID: ConversationDraftSnapshot]
    private(set) var messages: [SavedMessage] = []

    init(seed: ConversationDraftSnapshot) { drafts = [seed.conversationID: seed] }

    func loadDraft(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? { drafts[conversationID] }

    func saveDraft(conversationID: ConversationID, text: String,
                   expectedRevision: UInt64, updatedAt: Date) async throws -> ConversationDraftSnapshot {
        guard (drafts[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let snapshot = try ConversationDraftSnapshot(conversationID: conversationID, text: text,
                                                      revision: expectedRevision + 1, updatedAt: updatedAt)
        drafts[conversationID] = snapshot
        return snapshot
    }

    func saveMessage(conversationID: UUID, body: String) throws {
        let snapshot = try XCTUnwrap(drafts[ConversationID(conversationID)], "Submission must persist its raw safety copy first")
        messages.append(SavedMessage(conversationID: conversationID, body: body, draftSafetyCopy: snapshot.text))
    }
}

@MainActor
private final class UndoGroupingSubmissionRelay {
    weak var coordinator: WorkspaceDraftCoordinator?
    private let repository: UndoGroupingRepository
    private(set) var rawAttempts: [String] = []
    private(set) var completedSubmissions = 0

    init(repository: UndoGroupingRepository) { self.repository = repository }

    func begin(messageID: UUID, conversationID: UUID, rawText: String) -> Bool {
        rawAttempts.append(rawText)
        return coordinator?.beginSubmission(messageID: messageID, conversationID: conversationID, rawText: rawText) ?? false
    }

    func persist(messageID: UUID, conversationID: UUID, body: String) async {
        guard let coordinator, await coordinator.persistSubmission(messageID: messageID) else {
            XCTFail("Submission was not preceded by its draft persistence receipt")
            return
        }
        do { try await repository.saveMessage(conversationID: conversationID, body: body) }
        catch { XCTFail("In-memory message persistence failed: \(error)"); return }
        await coordinator.completeSubmission(messageID: messageID)
        completedSubmissions += 1
    }
}

private extension NSView {
    var undoGroupingDescendants: [NSView] { [self] + subviews.flatMap(\.undoGroupingDescendants) }
}
