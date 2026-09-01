import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class BotSidebarCreationRevealTests: XCTestCase {
    func testExplicitCreationRevealsSelectedNewFirstRowInScrolledNativeList() async throws {
        let host = SidebarCreationRevealHost()
        defer { host.close() }
        let table = try await host.scrolledTable()
        let oldRows = host.sidebar.rowModels
        let created = host.newRow()
        host.sidebar.replace(rows: [created] + host.sidebar.rows)
        host.sidebar.selection = created.id
        host.sidebar.requestCreationReveal(created.id)
        try await host.settle()

        XCTAssertEqual(table.numberOfRows, 41)
        XCTAssertEqual(table.selectedRow, 0)
        let firstRow = table.rect(ofRow: 0)
        XCTAssertGreaterThan(firstRow.height, 0)
        XCTAssertGreaterThanOrEqual(firstRow.minY, table.visibleRect.minY - 1)
        XCTAssertLessThanOrEqual(firstRow.maxY, table.visibleRect.maxY + 1,
                                "Correct ordering and selection are insufficient if the created row remains offscreen.")
        XCTAssertNil(host.sidebar.creationRevealID)
        XCTAssertEqual(host.sidebar.rows.first?.id, created.id)
        for row in oldRows {
            XCTAssertTrue(host.sidebar.rowModels.first(where: { $0.id == row.id }) === row)
        }

        // The one-shot request must not pull the list back up on later updates.
        table.scrollRowToVisible(table.numberOfRows - 1)
        try await host.settle()
        let scrolledY = table.visibleRect.minY
        XCTAssertGreaterThan(scrolledY, firstRow.maxY)
        host.sidebar.update(host.sidebar.rows.last!)
        host.sidebar.replace(rows: host.sidebar.rows)
        try await host.settle()
        XCTAssertEqual(table.visibleRect.minY, scrolledY, accuracy: 1)
        XCTAssertNil(host.sidebar.creationRevealID)
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)
    }

    func testNewerNavigationDiscardsCreationRevealWithoutScrollingToOldTarget() async throws {
        let host = SidebarCreationRevealHost()
        defer { host.close() }
        let table = try await host.scrolledTable()
        let newerSelection = try XCTUnwrap(host.sidebar.rows.last?.id)
        let created = host.newRow()
        host.sidebar.replace(rows: [created] + host.sidebar.rows)
        host.sidebar.selection = created.id
        host.sidebar.requestCreationReveal(created.id)
        host.sidebar.selection = newerSelection
        try await host.settle()

        XCTAssertEqual(host.sidebar.selection, newerSelection)
        XCTAssertEqual(table.selectedRow, table.numberOfRows - 1)
        XCTAssertFalse(table.visibleRect.intersects(table.rect(ofRow: 0)))
        XCTAssertNil(host.sidebar.creationRevealID)
        XCTAssertFalse(host.window.isVisible)
    }

    func testOrdinarySelectionAndRosterUpdatesNeverRequestCreationReveal() {
        let first = TeammateRowSnapshot(id: UUID(), name: "First", role: "Local fixture", activity: .idle, identitySeed: 1)
        let second = TeammateRowSnapshot(id: UUID(), name: "Second", role: "Local fixture", activity: .idle, identitySeed: 2)
        let sidebar = SidebarModel(rows: [first], selection: first.id)
        sidebar.update(second) // Restore-style insertion still appends.
        sidebar.selection = second.id
        sidebar.requestCreationReveal(second.id)
        XCTAssertNil(sidebar.creationRevealID, "Only the new selected first row can be requested.")
        sidebar.replace(rows: [second, first])
        XCTAssertNil(sidebar.creationRevealID, "A manual reorder alone is not a reveal request.")
        sidebar.requestCreationReveal(second.id)
        XCTAssertEqual(sidebar.creationRevealID, second.id)
        sidebar.completeCreationReveal(first.id)
        XCTAssertEqual(sidebar.creationRevealID, second.id, "A stale completion cannot consume a newer request.")
        sidebar.completeCreationReveal(second.id)
        XCTAssertNil(sidebar.creationRevealID)
    }

    func testNavigationAwayAndBackCannotReviveAnEarlierCreationReveal() {
        let created = TeammateRowSnapshot(id: UUID(), name: "New Bot", role: "Local fixture", activity: .idle, identitySeed: 1)
        let other = TeammateRowSnapshot(id: UUID(), name: "Saved Bot", role: "Local fixture", activity: .idle, identitySeed: 2)
        let sidebar = SidebarModel(rows: [created, other], selection: created.id)
        sidebar.requestCreationReveal(created.id)
        XCTAssertEqual(sidebar.creationRevealID, created.id)
        // Both changes can occur before the List's yielded reveal resumes.
        sidebar.selection = other.id
        XCTAssertNil(sidebar.creationRevealID)
        sidebar.selection = created.id
        XCTAssertNil(sidebar.creationRevealID)
    }
}

/// Synthetic native List only. The owned window never becomes visible or key;
/// no app data, provider, browser or physical user input is accessed.
@MainActor
private final class SidebarCreationRevealHost {
    let sidebar: SidebarModel
    let controller: NSHostingController<AnyView>
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        let rows = (0..<40).map { index in
            TeammateRowSnapshot(id: UUID(), name: "Saved bot \(index)", role: "Local fixture",
                                activity: .idle, identitySeed: UInt64(index + 1))
        }
        let sidebar = SidebarModel(rows: rows, selection: rows.last?.id)
        self.sidebar = sidebar
        let conversation = ConversationModel(
            conversationID: UUID(), title: "Saved bot", messages: [], composerText: "Unsent local draft",
            readyDeliveryDescription: "Synthetic rendering only", isLocalOnly: true, inputAvailability: .ready,
            submit: { _, _, _ in XCTFail("Scrolling must not submit a message") }
        )
        let controller = NSHostingController(rootView: AnyView(OpenBotsRootView(
            sidebar: sidebar, conversation: conversation,
            createTeammate: { XCTFail("The test inserts an in-memory row only") },
            openSettings: { XCTFail("Scrolling must not open Settings") }
        )))
        self.controller = controller
        controller.sizingOptions = []
        let size = CGSize(width: 720, height: 600)
        let window = SidebarCreationRevealWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        controller.view.frame = CGRect(origin: .zero, size: size)
    }

    func newRow() -> TeammateRowSnapshot {
        TeammateRowSnapshot(id: UUID(), name: "New Bot", role: "Not configured", activity: .idle, identitySeed: 99)
    }

    func scrolledTable() async throws -> NSTableView {
        try await settle()
        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 40)
        table.scrollRowToVisible(table.numberOfRows - 1)
        try await settle()
        XCTAssertFalse(table.visibleRect.intersects(table.rect(ofRow: 0)), "The regression must begin with the top row offscreen.")
        return table
    }

    func settle() async throws {
        for _ in 0..<6 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor
private final class SidebarCreationRevealWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
