import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class BotSidebarDragDropTests: XCTestCase {
    func testFullRowInsetHoverPreservesMenuAndInteractionGeometry() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let source = fixture.source
        source.reduceMotion = true
        let parent = NSView(frame: NSRect(x: 0, y: 110, width: 300, height: 100))
        try XCTUnwrap(fixture.window.contentView).addSubview(parent)
        parent.addSubview(source)
        source.frame = NSRect(x: 24, y: 20, width: 250, height: 60)
        let originalInteraction = source.convert(source.interactionBounds, to: nil)
        let originalRows = fixture.sidebar.rows
        let selection = fixture.sidebar.selection
        let editorSelection = fixture.editor.selectedRange()
        let firstResponder = fixture.window.firstResponder
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        let originalHover = try captureMenuTarget(parent, name: "hover-full-row-original")
        var originalMenu: SidebarMenuTargetRender?
        source.duringContextMenu = { _, _ in
            do { originalMenu = try self.captureMenuTarget(parent, name: "hover-full-row-menu-original") }
            catch { XCTFail("Could not render original menu bounds: \(error)") }
        }
        source.rightMouseDown(with: try fixture.event(.rightMouseDown))

        source.horizontalVisualOutset = 12
        source.frame = NSRect(x: 12, y: 20, width: 274, height: 60)
        source.updateTrackingAreas()
        XCTAssertEqual(source.convert(source.interactionBounds, to: nil), originalInteraction)
        XCTAssertEqual(source.trackingAreas.count, 1)
        XCTAssertEqual(source.trackingAreas[0].rect, source.interactionBounds.intersection(source.visibleRect))
        XCTAssertNil(source.hitTest(NSPoint(x: 14, y: 40)), "Added left paint margin must not capture input")
        XCTAssertNil(source.hitTest(NSPoint(x: 284, y: 40)), "Added right paint margin must not capture input")
        XCTAssertTrue(source.hitTest(NSPoint(x: 26, y: 40)) === source)
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        let widenedHover = try captureMenuTarget(parent, name: "hover-full-row-widened")
        let oldExtent = try XCTUnwrap(originalHover.visiblePixelBounds)
        let newExtent = try XCTUnwrap(widenedHover.visiblePixelBounds)
        let pixelScale = widenedHover.pixelScale
        XCTAssertEqual(newExtent.minX, oldExtent.minX - 12 * pixelScale.width, accuracy: 0.5)
        XCTAssertEqual(newExtent.maxX, oldExtent.maxX + 12 * pixelScale.width, accuracy: 0.5)
        XCTAssertEqual(newExtent.minY, oldExtent.minY)
        XCTAssertEqual(newExtent.maxY, oldExtent.maxY)
        XCTAssertEqual(widenedHover.maximumAlpha, originalHover.maximumAlpha)
        var widenedMenu: SidebarMenuTargetRender?
        source.duringContextMenu = { _, _ in
            XCTAssertEqual(source.convert(source.interactionBounds, to: nil), originalInteraction)
            do { widenedMenu = try self.captureMenuTarget(parent, name: "hover-full-row-menu-widened") }
            catch { XCTFail("Could not render unchanged menu bounds: \(error)") }
        }
        source.rightMouseDown(with: try fixture.event(.rightMouseDown))
        let menu = try XCTUnwrap(widenedMenu)
        XCTAssertEqual(menu.pixels, try XCTUnwrap(originalMenu).pixels)
        let menuExtent = try XCTUnwrap(menu.visiblePixelBounds)
        XCTAssertGreaterThan(menuExtent.minX, newExtent.minX,
                             "The temporary menu target must remain narrower than the broad hover wash")
        XCTAssertLessThan(menuExtent.maxX, newExtent.maxX)
        XCTAssertNil(source.contextMenuTargetID, "The temporary menu treatment clears on return")

        source.mouseDown(with: try fixture.event(.leftMouseDown))
        source.mouseUp(with: try fixture.event(.leftMouseUp, x: 2))
        XCTAssertEqual(fixture.sidebar.selection, selection, "Release in visual margin is not a row click")
        source.mouseDown(with: try fixture.event(.leftMouseDown, x: 2))
        source.mouseUp(with: try fixture.event(.leftMouseUp))
        XCTAssertEqual(fixture.sidebar.selection, selection, "Press in visual margin is not a row click")
        source.mouseDown(with: try fixture.event(.leftMouseDown))
        source.mouseDragged(with: try fixture.event(.leftMouseDragged, x: 35))
        let dragFrame = try XCTUnwrap(source.recordedDragFrames.last)
        XCTAssertEqual(source.convert(dragFrame, to: nil), originalInteraction)
        source.finishNativeDrag()
        let dragSource = fixture.base.view(at: 0)
        let info = try fixture.base.drag(source: dragSource, destination: source, before: true)
        XCTAssertTrue(source.prepareForDragOperation(info))
        info.draggingLocation = source.convert(NSPoint(x: 2, y: 20), to: nil)
        XCTAssertFalse(source.prepareForDragOperation(info), "Paint margin must not widen the drop target")
        info.draggingLocation = source.convert(NSPoint(x: 272, y: 20), to: nil)
        XCTAssertFalse(source.prepareForDragOperation(info))
        dragSource.finishNativeDrag()
        XCTAssertEqual(fixture.sidebar.selection, selection)
        XCTAssertEqual(fixture.sidebar.rows, originalRows)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty && fixture.base.requests.isEmpty)
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertEqual(fixture.editor.selectedRange(), editorSelection)
        XCTAssertTrue(fixture.window.firstResponder === firstResponder)
        XCTAssertFalse(source.isAccessibilityElement(), "Native List accessibility owns the row, not the paint/input overlay")
        XCTAssertFalse(source.acceptsFirstResponder)
        source.duringContextMenu = nil
    }

    func testMenuCancellationRestoresOnlyFreshPointerHoverOnOriginalTarget() throws {
        for scenario in ["inside", "outside", "reused"] {
            let fixture = SidebarContextMenuFixture()
            defer { fixture.close() }
            let source = fixture.source
            let targetID = source.rowID
            let selection = fixture.sidebar.selection
            let before = try captureMenuTarget(source, name: "hover-popup-\(scenario)-before")
            source.pointerInsideHoverRegion = scenario != "outside"
            source.duringContextMenu = { _, _ in
                XCTAssertNil(source.hoveredRowID)
                XCTAssertNil(source.layer?.animation(forKey: BotSidebarDragSourceView.hoverOpacityAnimationKey))
                if scenario == "reused" { source.rowID = fixture.base.ids[2] }
            }
            // No mouseEntered event is fabricated: native menu return itself
            // must notice an unchanged pointer still over its original row.
            source.rightMouseDown(with: try fixture.event(.rightMouseDown))
            let after = try captureMenuTarget(source, name: "hover-popup-\(scenario)-after")
            if scenario == "inside" {
                XCTAssertEqual(source.hoveredRowID, targetID)
                XCTAssertGreaterThan(after.visiblePixelCount, 0)
                XCTAssertNotEqual(after.pixels, before.pixels)
            } else {
                XCTAssertNil(source.hoveredRowID)
                XCTAssertEqual(after.pixels, before.pixels)
            }
            XCTAssertNil(source.contextMenuTargetID)
            XCTAssertNil(source.layer?.animation(forKey: BotSidebarDragSourceView.hoverOpacityAnimationKey))
            XCTAssertEqual(fixture.sidebar.selection, selection)
            XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
            XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
            XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty && fixture.base.requests.isEmpty)
            source.duringContextMenu = nil
        }
    }

    func testFiniteHoverOpacityPreservesEndpointsAndCancelsWithoutWaiting() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let source = fixture.source
        let key = BotSidebarDragSourceView.hoverOpacityAnimationKey
        let selection = fixture.sidebar.selection
        let before = try captureMenuTarget(source, name: "hover-finite-before")
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        let animation = try XCTUnwrap(source.layer?.animation(forKey: key) as? CABasicAnimation)
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual((animation.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((animation.toValue as? NSNumber)?.doubleValue, 1)
        XCTAssertGreaterThan(animation.duration, 0)
        XCTAssertLessThanOrEqual(animation.duration, 0.15)
        XCTAssertEqual(animation.repeatCount, 0)
        XCTAssertFalse(animation.autoreverses)
        XCTAssertTrue(animation.isRemovedOnCompletion)
        XCTAssertEqual(source.layer?.opacity, 1, "Animation must not alter the final layer state")
        let endpoint = try captureMenuTarget(source, name: "hover-finite-endpoint")

        source.reduceMotion = true
        XCTAssertNil(source.layer?.animation(forKey: key))
        XCTAssertEqual(try captureMenuTarget(source, name: "hover-finite-reduced").pixels, endpoint.pixels)
        source.mouseExited(with: try fixture.hoverEvent(.mouseExited))
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        XCTAssertNil(source.layer?.animation(forKey: key), "Reduce Motion must not install an animation")
        XCTAssertEqual(try captureMenuTarget(source, name: "hover-finite-reduced-enter").pixels, endpoint.pixels)
        source.mouseExited(with: try fixture.hoverEvent(.mouseExited))
        XCTAssertEqual(try captureMenuTarget(source, name: "hover-finite-exited").pixels, before.pixels)

        source.reduceMotion = false
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        source.rowID = fixture.base.ids[2]
        XCTAssertNil(source.layer?.animation(forKey: key))
        XCTAssertNil(source.hoveredRowID)
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        source.isEnabled = false
        XCTAssertNil(source.layer?.animation(forKey: key))
        source.isEnabled = true
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        fixture.sidebar.selection = source.rowID
        source.refreshHoverAvailability()
        XCTAssertNil(source.layer?.animation(forKey: key))
        XCTAssertNil(source.hoveredRowID)
        fixture.sidebar.selection = selection
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        source.duringContextMenu = { _, _ in
            XCTAssertNil(source.layer?.animation(forKey: key), "Menu target must appear immediately at full opacity")
            XCTAssertNil(source.hoveredRowID)
            XCTAssertEqual(source.layer?.opacity, 1)
        }
        source.rightMouseDown(with: try fixture.event(.rightMouseDown))
        XCTAssertNil(source.layer?.animation(forKey: key))
        XCTAssertNil(source.hoveredRowID)
        XCTAssertEqual(fixture.sidebar.selection, selection)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty && fixture.base.requests.isEmpty)
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        source.duringContextMenu = nil
    }

    func testHoverEnterExitReuseAndLifecycleNeverSelectOrTakeEditorFocus() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let source = fixture.source
        let rows = fixture.sidebar.rowModels
        let selection = fixture.sidebar.selection
        let range = fixture.editor.selectedRange()
        source.updateTrackingAreas()
        source.updateTrackingAreas()
        XCTAssertEqual(source.trackingAreas.count, 1)
        XCTAssertTrue(source.trackingAreas[0].options.contains(.inVisibleRect))
        XCTAssertTrue(source.trackingAreas[0].options.contains(.activeInKeyWindow))

        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        XCTAssertEqual(source.hoveredRowID, source.rowID)
        source.mouseExited(with: try fixture.hoverEvent(.mouseExited))
        XCTAssertNil(source.hoveredRowID)
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        source.rowID = fixture.base.ids[2]
        XCTAssertNil(source.hoveredRowID, "A reused view must not transfer another bot's hover")
        XCTAssertEqual(source.trackingAreas.count, 1)
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        XCTAssertEqual(source.hoveredRowID, fixture.base.ids[2])
        source.isEnabled = false
        XCTAssertNil(source.hoveredRowID)
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        XCTAssertNil(source.hoveredRowID)
        source.isEnabled = true
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        XCTAssertNil(source.hoveredRowID)
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        source.isHidden = true
        XCTAssertNil(source.hoveredRowID)
        source.isHidden = false
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        source.removeFromSuperview()
        XCTAssertNil(source.hoveredRowID)

        XCTAssertEqual(fixture.sidebar.selection, selection)
        XCTAssertTrue(zip(rows, fixture.sidebar.rowModels).allSatisfy { $0 === $1 })
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertEqual(fixture.editor.selectedRange(), range)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty && fixture.base.requests.isEmpty)
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertNil(fixture.sidebar.sidebarInsertion)
    }

    func testRenderedHoverIsNeutralBelowMenuTargetAndNeverCoversSelection() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let source = fixture.source
        let selection = fixture.sidebar.selection
        let before = try captureMenuTarget(source, name: "hover-before")
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        let hover = try captureMenuTarget(source, name: "hover-entered")
        XCTAssertGreaterThan(hover.visiblePixelCount, 0)
        XCTAssertNotEqual(hover.pixels, before.pixels)
        XCTAssertLessThanOrEqual(hover.maximumColorSpread, 0.06)
        source.increasedContrast = true
        let increased = try captureMenuTarget(source, name: "hover-increased-contrast")
        XCTAssertGreaterThan(increased.maximumAlpha, hover.maximumAlpha)
        source.increasedContrast = false
        var target: SidebarMenuTargetRender?
        source.duringContextMenu = { _, _ in
            do { target = try self.captureMenuTarget(source, name: "hover-menu-target") }
            catch { XCTFail("Could not render menu target over hover: \(error)") }
        }
        source.rightMouseDown(with: try fixture.event(.rightMouseDown))
        let menuTarget = try XCTUnwrap(target)
        XCTAssertGreaterThan(menuTarget.maximumAlpha, increased.maximumAlpha)
        XCTAssertNotEqual(menuTarget.pixels, hover.pixels)
        XCTAssertEqual(try captureMenuTarget(source, name: "hover-after-menu").pixels, before.pixels,
                       "Menu cancellation must not leave hover or animation artifacts")
        XCTAssertEqual(fixture.sidebar.selection, selection)

        // A genuinely selected row keeps the List's native selection pixels;
        // the hover overlay itself contributes nothing over that selection.
        fixture.sidebar.selection = source.rowID
        source.mouseEntered(with: try fixture.hoverEvent(.mouseEntered))
        XCTAssertEqual(try captureMenuTarget(source, name: "hover-selected").pixels, before.pixels)
        fixture.sidebar.selection = selection
        source.mouseExited(with: try fixture.hoverEvent(.mouseExited))
        XCTAssertEqual(try captureMenuTarget(source, name: "hover-exited").pixels, before.pixels)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty && fixture.base.requests.isEmpty)
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertFalse(fixture.window.isVisible)
        source.duringContextMenu = nil
    }

    func testRegisteredNativeDestinationRequestsMoveWithoutSelectingOrChangingConfirmedRows() throws {
        let fixture = SidebarDragFixture()
        let originalModels = fixture.sidebar.rowModels
        let source = fixture.view(at: 2)
        let destination = fixture.view(at: 0)
        let info = try fixture.drag(source: source, destination: destination, before: true)

        XCTAssertEqual(source.registeredDraggedTypes, [BotSidebarDragSourceView.pasteboardType])
        XCTAssertFalse(source.acceptsFirstResponder)
        XCTAssertEqual(destination.draggingEntered(info), .move)
        XCTAssertEqual(fixture.sidebar.sidebarInsertion, BotSidebarInsertion(rowID: fixture.ids[0], before: true))
        XCTAssertTrue(destination.prepareForDragOperation(info))
        XCTAssertTrue(destination.performDragOperation(info))

        XCTAssertEqual(fixture.requests, [[fixture.ids[2], fixture.ids[0], fixture.ids[1]]])
        XCTAssertEqual(fixture.sourceSnapshots, [fixture.ids])
        XCTAssertEqual(fixture.sidebar.rows.map(\.id), fixture.ids)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
        XCTAssertTrue(zip(originalModels, fixture.sidebar.rowModels).allSatisfy { $0 === $1 })
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertNil(fixture.sidebar.sidebarInsertion)
        XCTAssertTrue(fixture.sidebar.isOrderSaving)
        XCTAssertFalse(destination.performDragOperation(info), "A consumed drop cannot save twice")
    }

    func testNativeBottomDropAndSelfDropHaveBoundaryAndNoOpBehavior() throws {
        let fixture = SidebarDragFixture()
        let destination = fixture.view(at: 2)
        let info = try fixture.drag(source: fixture.view(at: 0), destination: destination, before: false)
        XCTAssertEqual(destination.draggingUpdated(info), .move)
        XCTAssertEqual(fixture.sidebar.sidebarInsertion, BotSidebarInsertion(rowID: fixture.ids[2], before: false))
        XCTAssertTrue(destination.performDragOperation(info))
        XCTAssertEqual(fixture.requests, [[fixture.ids[1], fixture.ids[2], fixture.ids[0]]])

        let noop = SidebarDragFixture()
        let sameRow = noop.view(at: 1)
        let sameInfo = try noop.drag(source: sameRow, destination: sameRow, before: false)
        XCTAssertTrue(sameRow.performDragOperation(sameInfo))
        XCTAssertTrue(noop.requests.isEmpty)
        XCTAssertFalse(noop.sidebar.isOrderSaving)
        XCTAssertEqual(noop.sidebar.selection, noop.ids[0])
    }

    func testNativeDragExitAndCancelledSourceDoNotSaveOrChangeSelection() throws {
        let fixture = SidebarDragFixture()
        let source = fixture.view(at: 1)
        let destination = fixture.view(at: 2)
        let info = try fixture.drag(source: source, destination: destination, before: false)
        XCTAssertEqual(destination.draggingEntered(info), .move)
        destination.draggingExited(info)
        XCTAssertNil(fixture.sidebar.sidebarInsertion)
        XCTAssertNotNil(fixture.sidebar.sidebarDrag, "Leaving a row still allows a later valid destination")
        source.finishNativeDrag()
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertFalse(destination.performDragOperation(info))
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(fixture.sidebar.rows.map(\.id), fixture.ids)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
    }

    func testNativeDropRejectsExternalSourceTamperedTokenDisabledSubsetAndOutOfBounds() throws {
        let fixture = SidebarDragFixture()
        let source = fixture.view(at: 1)
        let destination = fixture.view(at: 0)
        let info = try fixture.drag(source: source, destination: destination, before: true)
        info.draggingSource = NSObject()
        XCTAssertEqual(destination.draggingEntered(info), [])
        XCTAssertFalse(destination.performDragOperation(info))
        info.draggingSource = source
        info.draggingPasteboard.clearContents()
        info.draggingPasteboard.setString(UUID().uuidString, forType: BotSidebarDragSourceView.pasteboardType)
        XCTAssertFalse(destination.prepareForDragOperation(info))

        let valid = try fixture.drag(source: source, destination: destination, before: true)
        destination.isReorderingEnabled = false
        XCTAssertFalse(destination.performDragOperation(valid), "Search/subset surfaces cannot reorder")
        destination.isReorderingEnabled = true
        valid.draggingLocation = destination.convert(NSPoint(x: -10, y: 5), to: nil)
        XCTAssertEqual(destination.draggingUpdated(valid), [])
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
    }

    func testNativeDropRejectsOtherWorkspaceAndConcurrentRosterChanges() throws {
        let fixture = SidebarDragFixture()
        let source = fixture.view(at: 1)
        let destination = fixture.view(at: 0)
        let info = try fixture.drag(source: source, destination: destination, before: true)
        let other = SidebarDragFixture()
        XCTAssertFalse(other.view(at: 0).performDragOperation(info))

        fixture.sidebar.update(SidebarDragFixture.row(id: UUID(), name: "New bot"))
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertFalse(destination.performDragOperation(info))
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(Array(fixture.sidebar.rows.map(\.id).prefix(3)), fixture.ids)

        let reversedFixture = SidebarDragFixture()
        let reverseDestination = reversedFixture.view(at: 0)
        let old = try reversedFixture.drag(source: reversedFixture.view(at: 2), destination: reverseDestination, before: true)
        reversedFixture.sidebar.replace(rows: Array(reversedFixture.sidebar.rows.reversed()))
        XCTAssertFalse(reverseDestination.performDragOperation(old))
        XCTAssertTrue(reversedFixture.requests.isEmpty)
    }

    func testStatusRefreshDoesNotCancelValidDragOrReplaceRowIdentity() throws {
        let fixture = SidebarDragFixture()
        let source = fixture.view(at: 2)
        let destination = fixture.view(at: 0)
        let original = fixture.sidebar.rowModels[2]
        let info = try fixture.drag(source: source, destination: destination, before: true)
        fixture.sidebar.update(SidebarDragFixture.row(id: fixture.ids[2], name: "Updated name"))
        XCTAssertTrue(original === fixture.sidebar.rowModels[2])
        XCTAssertTrue(destination.performDragOperation(info))
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMouseClickSelectsOnlyOnReleaseAndDragPreparationLeavesEditorFocusAlone() throws {
        let fixture = SidebarDragFixture()
        let source = RecordingBotDragSourceView(sidebar: fixture.sidebar, rowID: fixture.ids[1])
        source.frame = NSRect(x: 0, y: 0, width: 250, height: 60)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let editor = NSTextView(frame: NSRect(x: 280, y: 0, width: 200, height: 100))
        editor.string = "Unsent draft\n  unchanged"
        content.addSubview(editor)
        content.addSubview(source)
        window.contentView = content
        XCTAssertTrue(window.makeFirstResponder(editor))
        let location = source.convert(NSPoint(x: 20, y: 20), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        let dragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: location.x + 8, y: location.y),
            modifierFlags: [], timestamp: 1.5, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 0.5
        ))
        source.mouseDown(with: down)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
        XCTAssertTrue(window.firstResponder === editor)
        source.mouseDragged(with: dragged)
        XCTAssertEqual(source.recordedDragEvents.count, 1)
        XCTAssertEqual(source.recordedDragEvents.first?.type, .leftMouseDragged)
        XCTAssertNotNil(fixture.sidebar.sidebarDrag)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
        XCTAssertTrue(window.firstResponder === editor)
        source.mouseUp(with: up)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0], "A dragged row must not become a click on release")
        source.finishNativeDrag()
        XCTAssertEqual(editor.string, "Unsent draft\n  unchanged")

        source.mouseDown(with: down)
        source.mouseUp(with: up)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[1])
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSavingFailureAndAccessibilityMovesRetainConfirmedOrder() {
        let fixture = SidebarDragFixture()
        XCTAssertFalse(fixture.sidebar.requestRelativeOrderMove(id: fixture.ids[0], offset: -1))
        XCTAssertFalse(fixture.sidebar.requestRelativeOrderMove(id: fixture.ids[2], offset: 1))
        XCTAssertTrue(fixture.sidebar.requestRelativeOrderMove(id: fixture.ids[1], offset: -1))
        XCTAssertFalse(fixture.sidebar.requestRelativeOrderMove(id: fixture.ids[2], offset: -1))
        XCTAssertNil(fixture.view(at: 1).prepareNativeDrag())
        fixture.sidebar.selection = fixture.ids[2]
        fixture.sidebar.setOrderSaveState(isSaving: false, error: "Could not save bot order.")
        XCTAssertEqual(fixture.sidebar.rows.map(\.id), fixture.ids)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[2])
        XCTAssertEqual(fixture.sidebar.orderError, "Could not save bot order.")
        XCTAssertTrue(fixture.sidebar.canReorder)
    }

    func testModelRejectsDuplicatesPartialAndStaleSnapshots() {
        let fixture = SidebarDragFixture()
        XCTAssertFalse(fixture.sidebar.requestOrderMove(ids: [fixture.ids[0], fixture.ids[0], fixture.ids[2]], fromSnapshot: fixture.ids))
        XCTAssertFalse(fixture.sidebar.requestOrderMove(ids: Array(fixture.ids.reversed().prefix(2)), fromSnapshot: Array(fixture.ids.prefix(2))))
        XCTAssertFalse(fixture.sidebar.requestOrderMove(ids: Array(fixture.ids.reversed()), fromSnapshot: Array(fixture.ids.reversed())))
        XCTAssertFalse(fixture.sidebar.requestOrderMove(ids: fixture.ids, fromSnapshot: fixture.ids))
        fixture.sidebar.configureOrderMoves(handler: nil)
        XCTAssertNil(fixture.view(at: 0).prepareNativeDrag())
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testRealRootRendersRegisteredNativeDragSourcesForCompleteActiveRows() async throws {
        _ = NSApplication.shared
        let fixture = SidebarDragFixture()
        let controller = NSHostingController(rootView: OpenBotsRootView(
            sidebar: fixture.sidebar, conversation: ConversationModel(),
            createTeammate: {}, openSettings: {}
        ))
        let window = SidebarDragRenderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        let host = controller.view
        host.frame.size = NSSize(width: 1_100, height: 720)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let nativeSources = dragViews(in: host)
        XCTAssertEqual(Set(nativeSources.map(\.rowID)), Set(fixture.ids))
        XCTAssertTrue(nativeSources.allSatisfy { $0.registeredDraggedTypes.contains(BotSidebarDragSourceView.pasteboardType) })
        XCTAssertTrue(nativeSources.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
        XCTAssertFalse(window.isVisible, "This rendering fixture must never open a physical window")
    }

    func testContextMenuConstructionAndCancelledRightOrControlClickPreserveEditorAndSelection() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let originalRows = fixture.sidebar.rowModels
        let originalSelection = fixture.sidebar.selection
        let originalDraft = fixture.editor.string
        let originalRange = fixture.editor.selectedRange()
        let rightDown = try fixture.event(.rightMouseDown)
        let menu = try XCTUnwrap(fixture.source.menu(for: rightDown))
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["Bot 1"])
        XCTAssertTrue(menu.items.first?.isSectionHeader == true)
        let actions = menu.items.filter { !$0.isSectionHeader }
        XCTAssertEqual(actions.map(\.title), ["Open Settings", "Archive Bot"])
        XCTAssertTrue(actions.allSatisfy(\.isEnabled))
        XCTAssertNil(fixture.source.contextMenuTargetID, "Constructing a menu must not leave a row effect")
        menu.cancelTracking()

        fixture.source.rightMouseDown(with: rightDown)
        XCTAssertNil(fixture.source.contextMenuTargetID, "Returning from popup presentation clears the temporary effect")
        fixture.source.rightMouseUp(with: try fixture.event(.rightMouseUp))
        fixture.source.mouseDown(with: try fixture.event(.leftMouseDown, flags: .control))
        XCTAssertNil(fixture.source.contextMenuTargetID)
        fixture.source.mouseDragged(with: try fixture.event(.leftMouseDragged, x: 35))
        // Releasing Control before the mouse button must not turn menu dismissal
        // into an ordinary row click or a prepared drag.
        fixture.source.mouseUp(with: try fixture.event(.leftMouseUp))
        fixture.source.shownMenus.forEach { $0.cancelTracking() }

        XCTAssertEqual(fixture.source.menuEventTypes, [.rightMouseDown, .leftMouseDown])
        XCTAssertEqual(fixture.source.presentationTargetIDs, [fixture.source.rowID, fixture.source.rowID])
        XCTAssertEqual(fixture.sidebar.selection, originalSelection)
        XCTAssertTrue(zip(originalRows, fixture.sidebar.rowModels).allSatisfy { $0 === $1 })
        XCTAssertEqual(fixture.editor.string, originalDraft)
        XCTAssertEqual(fixture.editor.selectedRange(), originalRange)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertTrue(fixture.source.recordedDragEvents.isEmpty)
        XCTAssertNil(fixture.source.sourceToken)
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertNil(fixture.sidebar.sidebarInsertion)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty)
        XCTAssertTrue(fixture.base.requests.isEmpty)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testContextMenuTargetEffectStaysWithCapturedBotDuringPopupAndClearsAfterAction() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let selectedID = fixture.sidebar.selection
        let targetID = fixture.source.rowID
        let draft = fixture.editor.string
        let selectedRange = fixture.editor.selectedRange()
        let before = try captureMenuTarget(fixture.source, name: "before")
        var during: SidebarMenuTargetRender?
        var reused: SidebarMenuTargetRender?
        var observedPresentation = false
        fixture.source.duringContextMenu = { menu, _ in
            observedPresentation = true
            XCTAssertEqual(fixture.source.contextMenuTargetID, targetID)
            XCTAssertEqual(fixture.sidebar.selection, selectedID)
            XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
            do { during = try self.captureMenuTarget(fixture.source, name: "during") }
            catch { XCTFail("Could not capture the active menu target: \(error)") }
            fixture.source.rowID = fixture.base.ids[2]
            XCTAssertEqual(fixture.source.contextMenuTargetID, targetID,
                           "View reuse must not transfer the temporary effect to a different bot")
            XCTAssertNotEqual(fixture.source.contextMenuTargetID, fixture.source.rowID)
            do { reused = try self.captureMenuTarget(fixture.source, name: "reused") }
            catch { XCTFail("Could not capture the reused row: \(error)") }
            // Restore the original row while the popup is still active: the
            // final capture must prove dismissal cleared the effect itself.
            fixture.source.rowID = targetID
            do { try self.performMenuAction("Open Settings", in: menu) }
            catch { XCTFail("Could not invoke the captured action: \(error)") }
            XCTAssertEqual(fixture.source.contextMenuTargetID, targetID)
        }

        fixture.source.rightMouseDown(with: try fixture.event(.rightMouseDown))

        let after = try captureMenuTarget(fixture.source, name: "after")
        let activeImage = try XCTUnwrap(during)
        let reusedImage = try XCTUnwrap(reused)
        XCTAssertNotEqual(activeImage.pixels, before.pixels, "The active target needs an actual visible row effect")
        XCTAssertGreaterThan(activeImage.visiblePixelCount, 0)
        XCTAssertLessThanOrEqual(activeImage.maximumColorSpread, 0.06,
                                 "The temporary effect must remain neutral, rather than imply blue conversation selection")
        XCTAssertEqual(reusedImage.pixels, before.pixels, "The reused row must not inherit another bot's menu effect")
        XCTAssertEqual(after.pixels, before.pixels, "Closing the menu must restore the original row pixels")
        XCTAssertTrue(observedPresentation)
        XCTAssertEqual(fixture.source.presentationTargetIDs, [targetID])
        XCTAssertNil(fixture.source.contextMenuTargetID, "Action completion must clear the temporary effect")
        XCTAssertEqual(fixture.settings, [targetID])
        XCTAssertTrue(fixture.archives.isEmpty)
        XCTAssertEqual(fixture.sidebar.selection, selectedID)
        XCTAssertEqual(fixture.editor.string, draft)
        XCTAssertEqual(fixture.editor.selectedRange(), selectedRange)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertNil(fixture.sidebar.sidebarInsertion)
        XCTAssertTrue(fixture.base.requests.isEmpty)
        XCTAssertFalse(fixture.window.isVisible)
        fixture.source.duringContextMenu = nil
    }

    func testContextMenuActionsKeepCapturedBotAndCallbacksAfterNativeViewReuse() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let capturedID = fixture.source.rowID
        let menu = try XCTUnwrap(fixture.source.menu(for: fixture.event(.rightMouseDown)))
        fixture.source.rowID = fixture.base.ids[2]
        var replacementCallbacks: [UUID] = []
        fixture.source.openBotSettings = { replacementCallbacks.append($0) }
        fixture.source.archiveBot = { replacementCallbacks.append($0) }

        try performMenuAction("Open Settings", in: menu)
        try performMenuAction("Archive Bot", in: menu)

        XCTAssertEqual(fixture.settings, [capturedID])
        XCTAssertEqual(fixture.archives, [capturedID])
        XCTAssertTrue(replacementCallbacks.isEmpty, "An existing menu must not adopt a reused view's actions")
        XCTAssertEqual(fixture.sidebar.selection, fixture.base.ids[0])
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertTrue(fixture.base.requests.isEmpty)
    }

    func testContextMenuHeaderNamesCurrentTargetAndKeepsOriginalIdentityAfterRenameAndReuse() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let selectedID = fixture.base.ids[0]
        let targetID = fixture.source.rowID
        fixture.sidebar.update(SidebarDragFixture.row(id: selectedID, name: "Selected conversation"))
        fixture.sidebar.update(SidebarDragFixture.row(id: targetID, name: "Target at menu opening"))
        fixture.source.rowName = "Stale cached row title"
        let menu = try XCTUnwrap(fixture.source.menu(for: fixture.event(.rightMouseDown)))
        let header = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(header.isSectionHeader)
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).count, 1)
        XCTAssertEqual(header.title, "Target at menu opening")
        XCTAssertNotEqual(header.title, "Selected conversation")
        XCTAssertNotEqual(header.title, fixture.source.rowName)
        XCTAssertNil(header.action, "A target label must not be an action")
        XCTAssertNil(header.target)
        XCTAssertEqual(fixture.sidebar.selection, selectedID)

        fixture.sidebar.update(SidebarDragFixture.row(id: targetID, name: "Original bot renamed"))
        let reusedID = fixture.base.ids[2]
        fixture.sidebar.update(SidebarDragFixture.row(id: reusedID, name: "Reused view target"))
        fixture.source.rowID = reusedID
        fixture.source.rowName = "Reused view target"
        var replacementCallbacks: [UUID] = []
        fixture.source.openBotSettings = { replacementCallbacks.append($0) }
        fixture.source.archiveBot = { replacementCallbacks.append($0) }
        let replacementMenu = try XCTUnwrap(fixture.source.menu(for: fixture.event(.rightMouseDown)))
        XCTAssertEqual(replacementMenu.items.first?.title, "Reused view target")
        XCTAssertEqual(header.title, "Target at menu opening", "An open menu keeps its original target label")
        try performMenuAction("Open Settings", in: menu)
        try performMenuAction("Archive Bot", in: menu)
        XCTAssertEqual(fixture.settings, [targetID])
        XCTAssertEqual(fixture.archives, [targetID])
        XCTAssertTrue(replacementCallbacks.isEmpty)

        fixture.source.openBotSettings = nil
        fixture.source.archiveBot = nil
        XCTAssertNil(fixture.source.menu(for: try fixture.event(.rightMouseDown)),
                     "A header alone must not create a menu when no actions are available")
        menu.cancelTracking()
        XCTAssertEqual(fixture.sidebar.selection, selectedID)
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertNil(fixture.sidebar.sidebarDrag)
        XCTAssertNil(fixture.sidebar.sidebarInsertion)
        XCTAssertTrue(fixture.base.requests.isEmpty)
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testContextMenuAndOrdinaryClickRemainAvailableWhenRowsCannotReorder() throws {
        for condition in ["single row", "no order handler", "saving order"] {
            let fixture = SidebarContextMenuFixture()
            defer { fixture.close() }
            let rowID = fixture.source.rowID
            fixture.source.isReorderingEnabled = false
            switch condition {
            case "single row":
                fixture.sidebar.replace(rows: [SidebarDragFixture.row(id: rowID, name: "Only bot")])
                fixture.sidebar.selection = nil
            case "no order handler":
                fixture.sidebar.configureOrderMoves(handler: nil)
            default:
                fixture.sidebar.setOrderSaveState(isSaving: true)
            }
            XCTAssertFalse(fixture.sidebar.canReorder, condition)
            let selection = fixture.sidebar.selection
            XCTAssertTrue(fixture.source.hitTest(NSPoint(x: 20, y: 20)) === fixture.source, condition)
            let menu = try XCTUnwrap(fixture.source.menu(for: fixture.event(.rightMouseDown)), condition)
            let targetName = try XCTUnwrap(fixture.sidebar.rows.first { $0.id == rowID }).name
            XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), [targetName], condition)
            XCTAssertTrue(menu.items.first?.isSectionHeader == true, condition)
            let actions = menu.items.filter { !$0.isSectionHeader }
            XCTAssertEqual(actions.map(\.title), ["Open Settings", "Archive Bot"], condition)
            XCTAssertTrue(actions.allSatisfy(\.isEnabled), condition)
            try performMenuAction("Open Settings", in: menu)
            XCTAssertEqual(fixture.settings, [rowID], condition)
            XCTAssertEqual(fixture.sidebar.selection, selection, condition)
            XCTAssertNil(fixture.source.prepareNativeDrag(), condition)

            fixture.source.mouseDown(with: try fixture.event(.leftMouseDown))
            XCTAssertEqual(fixture.sidebar.selection, selection, condition)
            fixture.source.mouseUp(with: try fixture.event(.leftMouseUp))
            XCTAssertEqual(fixture.sidebar.selection, rowID, condition)
            XCTAssertNil(fixture.sidebar.sidebarDrag, condition)
            XCTAssertTrue(fixture.base.requests.isEmpty, condition)
        }
    }

    func testContextMenuRefusesMissingCallbacksDisabledViewAndRemovedCapturedBot() throws {
        let fixture = SidebarContextMenuFixture()
        defer { fixture.close() }
        let menu = try XCTUnwrap(fixture.source.menu(for: fixture.event(.rightMouseDown)))
        let bare = BotSidebarDragSourceView(sidebar: fixture.sidebar, rowID: fixture.source.rowID)
        XCTAssertNil(bare.menu(for: try fixture.event(.rightMouseDown)))

        fixture.source.isEnabled = false
        XCTAssertNil(fixture.source.menu(for: try fixture.event(.rightMouseDown)))
        XCTAssertNil(fixture.source.hitTest(NSPoint(x: 20, y: 20)))
        fixture.source.rightMouseDown(with: try fixture.event(.rightMouseDown))
        fixture.source.mouseDown(with: try fixture.event(.leftMouseDown, flags: .control))
        fixture.source.mouseUp(with: try fixture.event(.leftMouseUp))
        try performMenuAction("Open Settings", in: menu)
        try performMenuAction("Archive Bot", in: menu)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty)
        XCTAssertTrue(fixture.source.shownMenus.isEmpty)
        XCTAssertTrue(fixture.source.presentationTargetIDs.isEmpty)
        XCTAssertNil(fixture.source.contextMenuTargetID)
        XCTAssertEqual(fixture.sidebar.selection, fixture.base.ids[0])

        fixture.source.isEnabled = true
        let capturedID = fixture.source.rowID
        fixture.sidebar.replace(rows: fixture.sidebar.rows.filter { $0.id != capturedID })
        fixture.source.rowID = fixture.base.ids[2]
        try performMenuAction("Open Settings", in: menu)
        try performMenuAction("Archive Bot", in: menu)
        XCTAssertTrue(fixture.settings.isEmpty && fixture.archives.isEmpty,
                      "Removing the captured bot must not retarget an already-built menu")
        XCTAssertEqual(fixture.sidebar.selection, fixture.base.ids[0])
        XCTAssertEqual(fixture.editor.string, SidebarContextMenuFixture.draft)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertNil(fixture.sidebar.sidebarDrag)
    }

    func testDisabledSwiftUIEnvironmentDisablesNativeContextMenuBridge() async throws {
        _ = NSApplication.shared
        let fixture = SidebarDragFixture()
        var actions: [UUID] = []
        let controller = NSHostingController(rootView: BotSidebarDragDropOverlay(
            sidebar: fixture.sidebar, rowID: fixture.ids[1], rowName: "Disabled bot",
            isEnabled: true, openBotSettings: { actions.append($0) }, archiveBot: { actions.append($0) }
        ).frame(width: 250, height: 60).disabled(true))
        let window = SidebarDragRenderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        let host = controller.view
        host.frame.size = NSSize(width: 250, height: 60)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let sources = dragViews(in: host)
        XCTAssertEqual(sources.count, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertFalse(source.isEnabled)
        XCTAssertFalse(source.isReorderingEnabled)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: source.convert(NSPoint(x: 20, y: 20), to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5
        ))
        XCTAssertNil(source.menu(for: event))
        XCTAssertNil(source.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(fixture.sidebar.selection, fixture.ids[0])
        XCTAssertFalse(window.isVisible, "The environment fixture must not activate or display a window")
    }

    private func performMenuAction(_ title: String, in menu: NSMenu) throws {
        let item = try XCTUnwrap(menu.items.first { !$0.isSectionHeader && $0.title == title })
        let action = try XCTUnwrap(item.action)
        XCTAssertNotNil(item.target, "Context actions need the menu's captured target")
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
    }

    private func captureMenuTarget(_ source: NSView, name: String) throws -> SidebarMenuTargetRender {
        source.layoutSubtreeIfNeeded()
        source.needsDisplay = true
        let bitmap = try XCTUnwrap(source.bitmapImageRepForCachingDisplay(in: source.bounds))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        let byteCount = bitmap.bytesPerRow * bitmap.pixelsHigh
        XCTAssertGreaterThan(byteCount, 0)
        // The overlay is transparent. Clear its owned bitmap first so unused
        // transparent bytes cannot create a false image difference.
        pixels.initialize(repeating: 0, count: byteCount)
        source.cacheDisplay(in: source.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/sidebar-menu-target-20260831/rendered", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("menu-target-\(name).png")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var visiblePixelCount = 0
        var maximumColorSpread: CGFloat = 0
        var maximumAlpha: CGFloat = 0
        var visiblePixelBounds: NSRect?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.01 else { continue }
                visiblePixelCount += 1
                maximumAlpha = max(maximumAlpha, color.alphaComponent)
                let pixelRect = NSRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
                visiblePixelBounds = visiblePixelBounds.map { $0.union(pixelRect) } ?? pixelRect
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                maximumColorSpread = max(maximumColorSpread, (channels.max() ?? 0) - (channels.min() ?? 0))
            }
        }
        return SidebarMenuTargetRender(pixels: Data(bytes: pixels, count: byteCount),
                                       visiblePixelCount: visiblePixelCount, maximumColorSpread: maximumColorSpread,
                                       maximumAlpha: maximumAlpha, visiblePixelBounds: visiblePixelBounds,
                                       pixelScale: NSSize(width: CGFloat(bitmap.pixelsWide) / source.bounds.width,
                                                          height: CGFloat(bitmap.pixelsHigh) / source.bounds.height))
    }

    private func dragViews(in view: NSView) -> [BotSidebarDragSourceView] {
        (view as? BotSidebarDragSourceView).map { [$0] } ?? view.subviews.flatMap { dragViews(in: $0) }
    }
}

private struct SidebarMenuTargetRender {
    let pixels: Data
    let visiblePixelCount: Int
    let maximumColorSpread: CGFloat
    let maximumAlpha: CGFloat
    let visiblePixelBounds: NSRect?
    let pixelScale: NSSize
}

@MainActor
private final class SidebarDragRenderWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingBotDragSourceView: BotSidebarDragSourceView {
    var recordedDragEvents: [NSEvent] = []

    override func startNativeSession(with item: NSDraggingItem, event: NSEvent) {
        recordedDragEvents.append(event)
    }
}

@MainActor
private final class RecordingBotContextSourceView: BotSidebarDragSourceView {
    var recordedDragEvents: [NSEvent] = []
    var recordedDragFrames: [NSRect] = []
    var shownMenus: [NSMenu] = []
    var menuEventTypes: [NSEvent.EventType] = []
    var presentationTargetIDs: [UUID?] = []
    var duringContextMenu: (@MainActor (NSMenu, NSEvent) -> Void)?
    var pointerInsideHoverRegion = false

    override func isPointerInsideHoverRegion() -> Bool { pointerInsideHoverRegion }

    override func startNativeSession(with item: NSDraggingItem, event: NSEvent) {
        recordedDragEvents.append(event)
        recordedDragFrames.append(item.draggingFrame)
    }

    override func showContextMenu(_ menu: NSMenu, with event: NSEvent) {
        shownMenus.append(menu)
        menuEventTypes.append(event.type)
        presentationTargetIDs.append(contextMenuTargetID)
        duringContextMenu?(menu, event)
    }
}

@MainActor
private final class SidebarContextMenuFixture {
    static let draft = "Unsent context-menu draft\n  keep exactly"
    let base = SidebarDragFixture()
    let source: RecordingBotContextSourceView
    let window: NSWindow
    let editor: NSTextView
    var settings: [UUID] = []
    var archives: [UUID] = []
    var sidebar: SidebarModel { base.sidebar }

    init() {
        source = RecordingBotContextSourceView(sidebar: base.sidebar, rowID: base.ids[1])
        source.frame = NSRect(x: 0, y: 0, width: 250, height: 60)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        editor = NSTextView(frame: NSRect(x: 280, y: 0, width: 200, height: 100))
        editor.string = Self.draft
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        content.addSubview(editor)
        content.addSubview(source)
        window.contentView = content
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 7))
        source.openBotSettings = { [weak self] in self?.settings.append($0) }
        source.archiveBot = { [weak self] in self?.archives.append($0) }
    }

    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], x: CGFloat = 20) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: source.convert(NSPoint(x: x, y: 20), to: nil),
            modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5
        ))
    }

    func hoverEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type, location: source.convert(NSPoint(x: 20, y: 20), to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil
        ))
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class SidebarDragFixture {
    let ids = [UUID(), UUID(), UUID()]
    let sidebar: SidebarModel
    var requests: [[UUID]] = []
    var sourceSnapshots: [[UUID]] = []
    private var views: [UUID: BotSidebarDragSourceView] = [:]

    init() {
        sidebar = SidebarModel(rows: ids.enumerated().map { Self.row(id: $0.element, name: "Bot \($0.offset)") }, selection: ids[0])
        sidebar.configureOrderMoves { [weak self] ids, source in
            guard let self else { return }
            requests.append(ids)
            sourceSnapshots.append(source)
            sidebar.setOrderSaveState(isSaving: true)
        }
    }

    static func row(id: UUID, name: String) -> TeammateRowSnapshot {
        TeammateRowSnapshot(id: id, name: name, role: "Test", activity: .idle, identitySeed: 4)
    }

    func view(at index: Int) -> BotSidebarDragSourceView {
        if let existing = views[ids[index]] { return existing }
        let view = BotSidebarDragSourceView(sidebar: sidebar, rowID: ids[index])
        view.frame = NSRect(x: 0, y: 0, width: 250, height: 60)
        views[ids[index]] = view
        return view
    }

    func drag(source: BotSidebarDragSourceView, destination: BotSidebarDragSourceView, before: Bool) throws -> NativeBotDragInfo {
        let item = try XCTUnwrap(source.prepareNativeDrag())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenBotsSidebarDragTest-\(UUID())"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]), "The owned named native pasteboard must accept the source item")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1, "The native pasteboard must expose exactly one item")
        XCTAssertEqual(pasteboard.string(forType: BotSidebarDragSourceView.pasteboardType), source.sourceToken?.uuidString)
        XCTAssertEqual(sidebar.sidebarDrag?.token, source.sourceToken)
        let location = destination.convert(NSPoint(x: 20, y: before ? 10 : 50), to: nil)
        XCTAssertTrue(destination.bounds.contains(destination.convert(location, from: nil)))
        return NativeBotDragInfo(
            source: source, pasteboard: pasteboard,
            location: location
        )
    }
}

@MainActor
private final class NativeBotDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(source: Any, pasteboard: NSPasteboard, location: NSPoint) {
        draggingSource = source
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
