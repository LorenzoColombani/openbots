import AppKit
import QuartzCore
import SwiftUI

struct BotSidebarDragSession: Equatable {
    let token: UUID
    let sourceID: UUID
    let sourceIDs: [UUID]
}

struct BotSidebarInsertion: Equatable {
    let rowID: UUID
    let before: Bool

    func reorderedIDs(for session: BotSidebarDragSession) -> [UUID]? {
        guard session.sourceIDs.contains(rowID),
              session.sourceIDs.contains(session.sourceID) else { return nil }
        // Dropping on either half of the source row is a successful no-op.
        if rowID == session.sourceID { return session.sourceIDs }
        var ids = session.sourceIDs.filter { $0 != session.sourceID }
        guard let targetIndex = ids.firstIndex(of: rowID) else { return nil }
        ids.insert(session.sourceID, at: targetIndex + (before ? 0 : 1))
        return ids
    }
}

/// Only the complete active sidebar installs this bridge. The List still owns
/// keyboard selection and accessibility. Mouse selection waits for mouse-up so
/// dragging an unselected row never opens its conversation or takes editor focus.
struct BotSidebarDragDropOverlay: NSViewRepresentable {
    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var sidebar: SidebarModel
    let rowID: UUID
    let rowName: String
    let isEnabled: Bool
    var horizontalVisualOutset: CGFloat = 0
    var openBotSettings: (@MainActor (UUID) -> Void)? = nil
    var archiveBot: (@MainActor (UUID) -> Void)? = nil

    func makeNSView(context: Context) -> BotSidebarDragSourceView {
        let view = BotSidebarDragSourceView(sidebar: sidebar, rowID: rowID)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BotSidebarDragSourceView, context: Context) {
        view.rowID = rowID
        view.rowName = rowName
        view.horizontalVisualOutset = horizontalVisualOutset
        view.isEnabled = isEnabled && environmentEnabled
        view.isReorderingEnabled = isEnabled && environmentEnabled
        view.openBotSettings = openBotSettings
        view.archiveBot = archiveBot
        view.increasedContrast = contrast == .increased
        view.reduceMotion = reduceMotion
        view.refreshHoverAvailability()
        view.needsDisplay = true
    }
}

struct BotSidebarReorderAccessibility: ViewModifier {
    @Environment(\.isEnabled) private var environmentEnabled
    @ObservedObject var sidebar: SidebarModel
    let rowID: UUID
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, environmentEnabled, sidebar.canReorder,
           let index = sidebar.rowModels.firstIndex(where: { $0.id == rowID }) {
            if index == 0 {
                content.accessibilityAction(named: Text("Move Down")) {
                    sidebar.requestRelativeOrderMove(id: rowID, offset: 1)
                }
            } else if index == sidebar.rowModels.count - 1 {
                content.accessibilityAction(named: Text("Move Up")) {
                    sidebar.requestRelativeOrderMove(id: rowID, offset: -1)
                }
            } else {
                content
                    .accessibilityAction(named: Text("Move Up")) {
                        sidebar.requestRelativeOrderMove(id: rowID, offset: -1)
                    }
                    .accessibilityAction(named: Text("Move Down")) {
                        sidebar.requestRelativeOrderMove(id: rowID, offset: 1)
                    }
            }
        } else {
            content
        }
    }
}

@MainActor
class BotSidebarDragSourceView: NSView, NSDraggingSource {
    static let hoverOpacityAnimationKey = "bot-hover-opacity"
    static let pasteboardType = NSPasteboard.PasteboardType(
        "com.lorenzocolombani.openbotsnext.preview.local-bot-order"
    )

    let sidebar: SidebarModel
    var horizontalVisualOutset: CGFloat = 0 {
        didSet {
            guard horizontalVisualOutset != oldValue else { return }
            updateTrackingAreas()
            observeClipChanges()
            needsDisplay = true
        }
    }
    var interactionBounds: NSRect {
        bounds.insetBy(dx: min(max(0, horizontalVisualOutset), bounds.width / 2), dy: 0)
    }
    var rowID: UUID {
        didSet {
            guard oldValue != rowID else { return }
            clearHover()
            updateTrackingAreas()
        }
    }
    var rowName = ""
    var isEnabled = true {
        didSet { if !isEnabled { clearHover() } }
    }
    var increasedContrast = false
    var reduceMotion = false {
        didSet { if reduceMotion { removeHoverAnimation() } }
    }
    var isReorderingEnabled = true
    var openBotSettings: (@MainActor (UUID) -> Void)?
    var archiveBot: (@MainActor (UUID) -> Void)?
    private(set) var sourceToken: UUID?
    private(set) var contextMenuTargetID: UUID?
    private(set) var hoveredRowID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    private weak var observedClipView: NSClipView?
    private var mouseDownLocation: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(sidebar: SidebarModel, rowID: UUID) {
        self.sidebar = sidebar
        self.rowID = rowID
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityElement(false)
        setAccessibilityIdentifier("bot-reorder-drag-source-\(rowID.uuidString)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if horizontalVisualOutset == 0 { options.insert(.inVisibleRect) }
        let visibleInteraction = interactionBounds.intersection(visibleRect)
        let area = NSTrackingArea(
            rect: horizontalVisualOutset == 0 || visibleInteraction.isEmpty ? .zero : visibleInteraction,
            options: options,
            owner: self, userInfo: nil
        )
        hoverTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        if horizontalVisualOutset > 0 { updateTrackingAreas() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipChanges()
        updateTrackingAreas()
    }

    private func observeClipChanges() {
        let clip = horizontalVisualOutset > 0 ? enclosingScrollView?.contentView : nil
        guard observedClipView !== clip else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func clipBoundsChanged() {
        updateTrackingAreas()
        if hoveredRowID != nil, !isPointerInsideHoverRegion() { clearHover() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearHover()
        observeClipChanges()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(clearHover),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        clearHover()
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea == nil || event.trackingArea === hoverTrackingArea,
              acceptsMouseInteraction, window != nil, !isHiddenOrHasHiddenAncestor,
              contextMenuTargetID == nil, sidebar.sidebarDrag == nil,
              interactionBounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)),
              sidebar.rowModels.contains(where: { $0.id == rowID }) else { return }
        let wasHovered = hoveredRowID == rowID
        hoveredRowID = rowID
        needsDisplay = true
        if !wasHovered, !reduceMotion, sidebar.selection != rowID,
           contextMenuTargetID == nil, sidebar.sidebarDrag == nil {
            // The final model-layer opacity stays at one. Core Animation
            // owns and removes this finite presentation-only entrance fade.
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = 0.12
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(animation, forKey: Self.hoverOpacityAnimationKey)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea == nil || event.trackingArea === hoverTrackingArea else { return }
        clearHover()
    }

    @objc private func clearHover() {
        removeHoverAnimation()
        guard hoveredRowID != nil else { return }
        hoveredRowID = nil
        needsDisplay = true
    }

    func refreshHoverAvailability() {
        if !isEnabled || sidebar.selection == rowID || sidebar.sidebarDrag != nil
            || !sidebar.rowModels.contains(where: { $0.id == rowID }) {
            clearHover()
        }
    }

    private func removeHoverAnimation() {
        layer?.removeAnimation(forKey: Self.hoverOpacityAnimationKey)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsMouseInteraction,
              interactionBounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = nil
        guard isEnabled, event.type == .leftMouseDown else { return }
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { presentContextMenu(menu, with: event) }
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard acceptsMouseInteraction, interactionBounds.contains(location) else { return }
        mouseDownLocation = location
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseDownLocation = nil
        guard let menu = menu(for: event) else { return }
        presentContextMenu(menu, with: event)
    }

    override func rightMouseUp(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, openBotSettings != nil || archiveBot != nil,
              let target = sidebar.rowModels.first(where: { $0.id == rowID }) else { return nil }
        let id = rowID
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: target.snapshot.name))
        if let openBotSettings {
            menu.addItem(BotSidebarMenuItem(title: "Open Settings") { [weak self] in
                guard let self, self.isEnabled,
                      self.sidebar.rowModels.contains(where: { $0.id == id }) else { return }
                openBotSettings(id)
            })
        }
        if let archiveBot {
            menu.addItem(BotSidebarMenuItem(title: "Archive Bot") { [weak self] in
                guard let self, self.isEnabled,
                      self.sidebar.rowModels.contains(where: { $0.id == id }) else { return }
                archiveBot(id)
            })
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Tests override presentation, not the real row/target-action menu wiring.
    func showContextMenu(_ menu: NSMenu, with event: NSEvent) {
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func presentContextMenu(_ menu: NSMenu, with event: NSEvent) {
        let targetID = rowID
        clearHover()
        contextMenuTargetID = rowID
        needsDisplay = true
        displayIfNeeded()
        defer {
            clearHover()
            contextMenuTargetID = nil
            // Popup tracking may consume the mouse-enter event. Restore only
            // a fresh, actual hover on the same target, never a fading remnant.
            if rowID == targetID, acceptsMouseInteraction, sidebar.selection != rowID,
               sidebar.sidebarDrag == nil, sidebar.rowModels.contains(where: { $0.id == rowID }),
               isPointerInsideHoverRegion() {
                hoveredRowID = rowID
            }
            needsDisplay = true
            displayIfNeeded()
        }
        showContextMenu(menu, with: event)
    }

    /// Native pointer read is isolated so offline fixtures need no real cursor.
    func isPointerInsideHoverRegion() -> Bool {
        guard let window, window.isVisible, window.isKeyWindow,
              !isHiddenOrHasHiddenAncestor else { return false }
        return interactionBounds.intersection(visibleRect).contains(
            convert(window.mouseLocationOutsideOfEventStream, from: nil)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isReorderingEnabled, sidebar.canReorder,
              event.type == .leftMouseDragged, !event.modifierFlags.contains(.control),
              let origin = mouseDownLocation, window != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - origin.x, location.y - origin.y) >= 4 else { return }
        mouseDownLocation = nil
        guard let item = prepareNativeDrag() else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(interactionBounds, contents: dragImage())
        startNativeSession(with: draggingItem, event: event)
    }

    /// Isolated from gesture policy so offline tests can record the native
    /// mouse event path without starting a physical system drag session.
    func startNativeSession(with item: NSDraggingItem, event: NSEvent) {
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        guard acceptsMouseInteraction, event.type == .leftMouseUp, !event.modifierFlags.contains(.control),
              interactionBounds.contains(convert(event.locationInWindow, from: nil)),
              sidebar.rowModels.contains(where: { $0.id == rowID }) else { return }
        clearHover()
        sidebar.selection = rowID
        // Clicks retain ordinary List keyboard navigation. A drag never calls
        // makeFirstResponder, including on cancellation or a failed save.
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                window?.makeFirstResponder(table)
                break
            }
            ancestor = view.superview
        }
    }

    /// The real source event and offline native-destination tests share this
    /// entry point. Its pasteboard contains only an ephemeral local drag token.
    func prepareNativeDrag() -> NSPasteboardItem? {
        guard isEnabled, isReorderingEnabled, let session = sidebar.beginSidebarDrag(id: rowID) else { return nil }
        clearHover()
        sourceToken = session.token
        let item = NSPasteboardItem()
        item.setString(session.token.uuidString, forType: Self.pasteboardType)
        return item
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finishNativeDrag()
    }

    func finishNativeDrag() {
        if sidebar.sidebarDrag?.token == sourceToken { sidebar.cancelSidebarDrag() }
        sourceToken = nil
        mouseDownLocation = nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateNativeInsertion(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptedInsertion(sender) != nil else { return updateNativeInsertion(sender) }
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: sender.draggingLocation,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ) { _ = autoscroll(with: event) }
        return updateNativeInsertion(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if sidebar.sidebarInsertion?.rowID == rowID { sidebar.updateSidebarInsertion(nil) }
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptedInsertion(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let insertion = acceptedInsertion(sender), let session = sidebar.sidebarDrag,
              let ids = insertion.reorderedIDs(for: session) else {
            sidebar.updateSidebarInsertion(nil)
            return false
        }
        sidebar.cancelSidebarDrag()
        needsDisplay = true
        if ids == session.sourceIDs { return true }
        return sidebar.requestOrderMove(ids: ids, fromSnapshot: session.sourceIDs)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        sidebar.updateSidebarInsertion(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if contextMenuTargetID == rowID,
           sidebar.rowModels.contains(where: { $0.id == rowID }) {
            let outline = NSBezierPath(roundedRect: interactionBounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            outline.fill()
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
        } else if hoveredRowID == rowID, isEnabled, sidebar.selection != rowID,
                  sidebar.sidebarDrag == nil,
                  sidebar.rowModels.contains(where: { $0.id == rowID }) {
            // A flat neutral wash, not selection or a menu-target outline.
            // Only its native layer entrance opacity changes; drawing endpoints,
            // material, focus and native selection remain unchanged.
            NSColor.labelColor.withAlphaComponent(increasedContrast ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard let insertion = sidebar.sidebarInsertion, insertion.rowID == rowID else { return }
        NSColor.controlAccentColor.setFill()
        let y = insertion.before ? interactionBounds.minY : max(interactionBounds.minY, interactionBounds.maxY - 2)
        NSBezierPath(roundedRect: NSRect(x: interactionBounds.minX, y: y, width: interactionBounds.width, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    private func updateNativeInsertion(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let insertion = acceptedInsertion(sender) else {
            if sidebar.sidebarInsertion?.rowID == rowID { sidebar.updateSidebarInsertion(nil) }
            needsDisplay = true
            return []
        }
        sidebar.updateSidebarInsertion(insertion)
        sender.numberOfValidItemsForDrop = 1
        needsDisplay = true
        return .move
    }

    private func acceptedInsertion(_ sender: any NSDraggingInfo) -> BotSidebarInsertion? {
        guard isEnabled, isReorderingEnabled, sidebar.canReorder,
              sender.draggingSourceOperationMask.contains(.move),
              let source = sender.draggingSource as? BotSidebarDragSourceView,
              source.sidebar === sidebar, let session = sidebar.sidebarDrag,
              source.sourceToken == session.token,
              sender.draggingPasteboard.pasteboardItems?.count == 1,
              sender.draggingPasteboard.string(forType: Self.pasteboardType) == session.token.uuidString,
              session.sourceIDs == sidebar.rowModels.map(\.id),
              session.sourceIDs.contains(rowID) else { return nil }
        let location = convert(sender.draggingLocation, from: nil)
        guard interactionBounds.contains(location) else { return nil }
        return BotSidebarInsertion(rowID: rowID, before: location.y < interactionBounds.midY)
    }

    private func dragImage() -> NSImage {
        if let parent = superview {
            let rect = convert(interactionBounds, to: parent)
            if let bitmap = parent.bitmapImageRepForCachingDisplay(in: rect) {
                parent.cacheDisplay(in: rect, to: bitmap)
                let image = NSImage(size: interactionBounds.size)
                image.addRepresentation(bitmap)
                return image
            }
        }
        return NSImage(size: interactionBounds.size, flipped: true) { [rowName] rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (rowName as NSString).draw(at: NSPoint(x: 10, y: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
            ])
            return true
        }
    }

    private var acceptsMouseInteraction: Bool {
        isEnabled && ((isReorderingEnabled && sidebar.canReorder)
            || openBotSettings != nil || archiveBot != nil)
    }
}

/// The menu owns each action, including its captured row UUID. Reusing the
/// overlay for another row cannot redirect an already constructed menu item.
@MainActor
private final class BotSidebarMenuItem: NSMenuItem {
    private let selectedAction: @MainActor () -> Void

    init(title: String, selectedAction: @escaping @MainActor () -> Void) {
        self.selectedAction = selectedAction
        super.init(title: title, action: #selector(performSelectedAction(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func performSelectedAction(_ sender: Any?) { selectedAction() }
}
