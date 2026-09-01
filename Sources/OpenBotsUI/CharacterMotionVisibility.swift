import AppKit
import SwiftUI

private struct CharacterMotionAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Semantic visibility, including retained SwiftUI content covered by another pane.
    /// AppKit's visibleRect cannot establish whether a SwiftUI opacity layer is visible.
    var characterMotionAllowed: Bool {
        get { self[CharacterMotionAllowedKey.self] }
        set { self[CharacterMotionAllowedKey.self] = newValue }
    }
}

struct CharacterMotionVisibilitySnapshot: Equatable {
    var isAttached: Bool
    var windowIsVisible: Bool
    var windowIsUnoccluded: Bool
    var windowIsMiniaturized: Bool
    var windowIsKey: Bool
    var applicationIsActive: Bool
    var hasHiddenAncestor: Bool
    var visibleRect: CGRect

    var permitsMotion: Bool {
        isAttached && windowIsVisible && windowIsUnoccluded
            && !windowIsMiniaturized && windowIsKey && applicationIsActive
            && !hasHiddenAncestor && !visibleRect.isEmpty
            && visibleRect.origin.x.isFinite && visibleRect.origin.y.isFinite
            && visibleRect.width.isFinite && visibleRect.height.isFinite
    }
}

/// A noninteractive, non-accessible probe matching the artwork's bounds. It supplies
/// native visibility only; Reduce Motion, scene state, photos and semantic hiding are
/// additional renderer gates. No timer, display clock or frame publisher is created.
struct CharacterMotionVisibilityObserver: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> CharacterMotionVisibilityView {
        let view = CharacterMotionVisibilityView(frame: .zero)
        view.onVisibilityChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ nsView: CharacterMotionVisibilityView, context: Context) {
        nsView.onVisibilityChange = { isVisible = $0 }
        nsView.requestVisibilityAssessment()
    }

    static func dismantleNSView(_ nsView: CharacterMotionVisibilityView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
class CharacterMotionVisibilityView: NSView {
    var onVisibilityChange: ((Bool) -> Void)?

    private var lastPublishedVisibility = false
    private var pendingAssessment: Task<Void, Never>?
    private var observedWindowID: ObjectIdentifier?
    private var observedAncestorIDs: [ObjectIdentifier] = []
    private var windowIsClosing = false
    private var isStopped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        pendingAssessment?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshObservationHierarchy()
        requestVisibilityAssessment()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshObservationHierarchy()
        requestVisibilityAssessment()
    }

    override func viewDidHide() {
        super.viewDidHide()
        requestVisibilityAssessment()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        requestVisibilityAssessment()
    }

    override func layout() {
        super.layout()
        refreshObservationHierarchy()
        requestVisibilityAssessment()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        requestVisibilityAssessment()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestVisibilityAssessment()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        requestVisibilityAssessment()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        requestVisibilityAssessment()
    }

    func currentVisibilitySnapshot() -> CharacterMotionVisibilitySnapshot {
        let owner = window
        return CharacterMotionVisibilitySnapshot(
            isAttached: owner != nil && superview != nil,
            windowIsVisible: owner?.isVisible == true && !windowIsClosing,
            windowIsUnoccluded: owner?.occlusionState.contains(.visible) == true,
            windowIsMiniaturized: owner?.isMiniaturized == true,
            windowIsKey: owner?.isKeyWindow == true,
            applicationIsActive: NSApplication.shared.isActive,
            hasHiddenAncestor: isHiddenOrHasHiddenAncestor,
            // On macOS 14+, a nonclipping view's visibleRect can extend beyond its
            // own bounds. Only the portion overlapping this artwork is eligible.
            visibleRect: visibleRect.intersection(bounds)
        )
    }

    /// Layout and notification bursts share one deferred read of the latest native
    /// state. Changed-only publication prevents a binding/layout feedback loop.
    func requestVisibilityAssessment() {
        guard !isStopped, pendingAssessment == nil else { return }
        pendingAssessment = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.pendingAssessment = nil
            self.refreshObservationHierarchy()
            let visible = self.currentVisibilitySnapshot().permitsMotion
            guard visible != self.lastPublishedVisibility else { return }
            self.lastPublishedVisibility = visible
            self.onVisibilityChange?(visible)
        }
    }

    func stopObserving() {
        isStopped = true
        pendingAssessment?.cancel()
        pendingAssessment = nil
        NotificationCenter.default.removeObserver(self)
        observedWindowID = nil
        observedAncestorIDs = []
        onVisibilityChange = nil
        lastPublishedVisibility = false
    }

    private func refreshObservationHierarchy() {
        guard !isStopped else { return }
        var ancestors: [NSView] = []
        var ancestor: NSView? = self
        while let current = ancestor {
            ancestors.append(current)
            ancestor = current.superview
        }
        let windowID = window.map(ObjectIdentifier.init)
        let ancestorIDs = ancestors.map(ObjectIdentifier.init)
        guard windowID != observedWindowID || ancestorIDs != observedAncestorIDs else { return }

        NotificationCenter.default.removeObserver(self)
        if windowID != observedWindowID { windowIsClosing = false }
        observedWindowID = windowID
        observedAncestorIDs = ancestorIDs
        guard let window else { return }

        let windowEvents: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didExposeNotification,
            NSWindow.didResizeNotification, NSWindow.didMoveNotification,
            NSWindow.willCloseNotification
        ]
        for name in windowEvents { observe(name, object: window) }
        observe(NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        observe(NSApplication.didResignActiveNotification, object: NSApplication.shared)
        for view in ancestors {
            // These standard notifications also serve scrolling/clipping consumers.
            // Do not disable them on teardown: another avatar or native control may
            // share the ancestor. Only this probe's subscriptions are removed.
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            observe(NSView.frameDidChangeNotification, object: view)
            observe(NSView.boundsDidChangeNotification, object: view)
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(nativeVisibilityChanged(_:)), name: name, object: object
        )
    }

    @objc private func nativeVisibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification { windowIsClosing = true }
        requestVisibilityAssessment()
    }
}
