import AppKit
import SwiftUI

private struct ComposerEditingClockKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
}

extension EnvironmentValues {
    var composerEditingClock: @MainActor @Sendable () -> TimeInterval {
        get { self[ComposerEditingClockKey.self] }
        set { self[ComposerEditingClockKey.self] = newValue }
    }
}

/// Keeps the existing SwiftUI field and its normal submit route. Only the
/// focused regular composer's Shift-Return/Enter is consumed. Other edits use
/// native routing, with explicit coalescing boundaries and draft synchronization.
struct ComposerReturnKeyHandling: ViewModifier {
    let conversationID: UUID?
    var isFocused = false
    @Environment(\.composerEditingClock) private var clock
    @StateObject private var handler = ComposerReturnKeyHandler()

    func body(content: Content) -> some View {
        content
            .background {
                ComposerEditorAttachment(handler: handler, isFocused: isFocused, clock: clock)
                    .accessibilityHidden(true)
            }
            .onKeyPress(phases: [.down, .repeat]) { press in
                handler.handleKeyPress(key: press.key, characters: press.characters, modifiers: press.modifiers)
            }
            .onChange(of: conversationID) { _, _ in
                handler.changeConversation()
            }
    }
}

@MainActor
final class ComposerReturnKeyHandler: NSObject, ObservableObject {
    private weak var attachment: NSView?
    private weak var undoEditor: NSTextView?
    private weak var undoField: NSTextField?
    private weak var observedManager: UndoManager?
    private var clock: @MainActor @Sendable () -> TimeInterval = ComposerEditingClockKey.defaultValue
    private var lastEditTime: TimeInterval?
    private var isolateNextEdit = false
    private var publishingUndo = false
    private var wasComposing = false
    private var focusRequested = false

    func attach(_ view: NSView) {
        if attachment !== view {
            stopObservingUndo()
            focusRequested = false
        }
        attachment = view
    }

    func endEditingSession() {
        if let editor = ownedEditor(), !editor.hasMarkedText() { editor.breakUndoCoalescing() }
        stopObservingUndo()
    }

    func updateFocus(_ focused: Bool, clock: @escaping @MainActor @Sendable () -> TimeInterval) {
        self.clock = clock
        let beginsFocus = focused && !focusRequested
        focusRequested = focused
        if beginsFocus {
            _ = acquireEditor()
        } else if !focused {
            endEditingSession()
        }
    }

    func changeConversation() {
        // Re-arm only the same proven owner if SwiftUI keeps it focused.
        // A delayed view update must not capture a different field in its place.
        let editor = ownedEditor()
        endEditingSession()
        if focusRequested, let editor { observeUndo(in: editor) }
    }

    func detach(_ view: NSView) {
        guard attachment === view else { return }
        stopObservingUndo()
        focusRequested = false
        attachment = nil
    }

    func handleReturn(modifiers: EventModifiers) -> KeyPress.Result {
        guard modifiers.contains(.shift),
              modifiers.intersection([.command, .option, .control]).isEmpty,
              let editor = acquireEditor(),
              !editor.hasMarkedText()
        else { return .ignored }

        // The key handler belongs to the focused TextField. Resolve only its
        // attached window, never NSApp.keyWindow/mainWindow. Native insertion
        // replaces the current selection and preserves undo/delegate updates;
        // it does not invoke the field's Return/onSubmit command.
        editor.breakUndoCoalescing()
        editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        return .handled
    }

    func handleKeyPress(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> KeyPress.Result {
        guard let editor = acquireEditor(), !editor.hasMarkedText() else { return .ignored }
        if key == .return || key == KeyEquivalent("\u{3}") {
            if modifiers.contains(.shift) { return handleReturn(modifiers: modifiers) }
            // Preserve the native Option alias, including its normal command
            // route, while separating that newline from surrounding typing.
            if modifiers.intersection([.command, .control, .option]) == [.option] {
                editor.breakUndoCoalescing()
                isolateNextEdit = true
            }
            return .ignored
        }
        let navigationKeys: [KeyEquivalent] = [.upArrow, .downArrow, .leftArrow, .rightArrow,
                                              .home, .end, .pageUp, .pageDown, .tab, .escape]
        if navigationKeys.contains(key) {
            isolateNextEdit = false
            return .ignored
        }
        guard !characters.isEmpty, modifiers.intersection([.command, .control]).isEmpty else { return .ignored }
        if let lastEditTime, clock() - lastEditTime >= 1 {
            editor.breakUndoCoalescing()
        }
        if editor.selectedRange().length > 0 {
            editor.breakUndoCoalescing()
            isolateNextEdit = true
        }
        return .ignored
    }

    private func acquireEditor() -> NSTextView? {
        guard let window = attachment?.window,
              let editor = window.firstResponder as? NSTextView,
              editor.window === window, editor.isEditable,
              let manager = editor.undoManager
        else { return nil }
        let field = editor.delegate as? NSTextField
        guard !editor.isFieldEditor || field?.currentEditor() === editor else { return nil }
        if undoEditor !== editor || undoField !== field || observedManager !== manager {
            observeUndo(in: editor)
        }
        return editor
    }

    private func ownedEditor() -> NSTextView? {
        guard let editor = undoEditor,
              let window = attachment?.window,
              editor.window === window, window.firstResponder === editor,
              editor.isEditable, editor.undoManager === observedManager,
              !editor.isFieldEditor || (undoField?.currentEditor() === editor && editor.delegate === undoField)
        else { return nil }
        return editor
    }

    private func observeUndo(in editor: NSTextView) {
        stopObservingUndo()
        guard let manager = editor.undoManager else { return }
        undoEditor = editor
        undoField = editor.delegate as? NSTextField
        observedManager = manager
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(didCompleteUndoOrRedo), name: name, object: manager
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange), name: NSText.didChangeNotification, object: editor
        )
        if let undoField {
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldDidEndEditing),
                name: NSControl.textDidEndEditingNotification, object: undoField
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldDidBeginEditing),
                name: NSControl.textDidBeginEditingNotification, object: undoField
            )
        }
    }

    @objc private func fieldDidEndEditing() {
        // AppKit may restart editing in this same field without a SwiftUI
        // focus change. Retire the editor/manager, retaining only the exact
        // proven field's lifecycle observers until focus loss or detachment.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.removeObserver(self, name: name, object: observedManager)
        }
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: undoEditor)
        undoEditor = nil
        observedManager = nil
        lastEditTime = nil
        isolateNextEdit = false
        wasComposing = false
    }

    @objc private func fieldDidBeginEditing() {
        guard focusRequested, let field = undoField,
              let editor = field.currentEditor() as? NSTextView,
              let window = attachment?.window,
              field.window === window, editor.window === window, window.firstResponder === editor,
              editor.delegate === field, editor.isEditable else { return }
        observeUndo(in: editor)
    }

    @objc private func textDidChange() {
        guard !publishingUndo, let editor = ownedEditor(),
              let manager = observedManager, !manager.isUndoing, !manager.isRedoing else { return }
        lastEditTime = clock()
        if editor.hasMarkedText() {
            wasComposing = true
            return
        }
        if isolateNextEdit || wasComposing {
            editor.breakUndoCoalescing()
            isolateNextEdit = false
            wasComposing = false
        }
    }

    @objc private func didCompleteUndoOrRedo() {
        guard let editor = ownedEditor(), !editor.hasMarkedText()
        else { return }

        // SwiftUI's multiline field can restore its native text on undo while
        // leaving its binding stale. Publish the completed native edit through
        // AppKit's normal delegate/notification route, without replacing text,
        // selection, the field delegate, or the native undo stack.
        publishingUndo = true
        defer { publishingUndo = false }
        editor.didChangeText()
        lastEditTime = nil
        isolateNextEdit = false
    }

    @objc private func stopObservingUndo() {
        NotificationCenter.default.removeObserver(self)
        undoEditor = nil
        undoField = nil
        observedManager = nil
        lastEditTime = nil
        isolateNextEdit = false
        wasComposing = false
    }
}

private struct ComposerEditorAttachment: NSViewRepresentable {
    let handler: ComposerReturnKeyHandler
    let isFocused: Bool
    let clock: @MainActor @Sendable () -> TimeInterval

    func makeNSView(context: Context) -> AttachmentView {
        AttachmentView(handler: handler)
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        if nsView.handler !== handler {
            nsView.handler?.detach(nsView)
            nsView.handler = handler
        }
        handler.attach(nsView)
        handler.updateFocus(isFocused, clock: clock)
    }

    static func dismantleNSView(_ nsView: AttachmentView, coordinator: ()) {
        nsView.handler?.detach(nsView)
    }

    final class AttachmentView: NSView {
        weak var handler: ComposerReturnKeyHandler?

        init(handler: ComposerReturnKeyHandler) {
            self.handler = handler
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                handler?.detach(self)
            } else {
                handler?.attach(self)
            }
        }
    }
}
