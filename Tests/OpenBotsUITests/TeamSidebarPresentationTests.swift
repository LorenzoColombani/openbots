import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// The sidebar's section order is a view arrangement, so it is asserted
/// against the real native list the SwiftUI `List` installs: its row count,
/// the row each bot's own drag source lands in, and where those rows sit on
/// screen. No app data, provider, window visibility or user input is involved.
@MainActor
final class TeamSidebarPresentationTests: XCTestCase {
    func testTeamsSectionAndItsHeaderRenderAboveTheLabelledBotsSection() async throws {
        let host = TeamSidebarPresentationHost(teamCount: 1, selection: .team)
        defer { host.close() }
        try await host.settle()

        let table = try host.list()
        // One Teams header, the team, one Bots header, then the two bots.
        XCTAssertEqual(table.numberOfRows, 5)
        let rows = host.rowRects(of: table)
        let botRows = try host.botRowIndices(in: table)
        XCTAssertEqual(botRows, [3, 4], "The bots must follow the team section, not lead it.")

        let teamRow = rows[1]
        XCTAssertEqual(teamRow.height, rows[3].height, accuracy: 1,
                       "Row 1 must be the team's own row, the same height as a bot row.")
        XCTAssertLessThan(rows[0].height, teamRow.height, "Row 0 must be the Teams header.")
        XCTAssertLessThan(rows[2].height, teamRow.height, "Row 2 must be the Bots header.")

        // Window coordinates grow upward, so a larger minY is higher on screen.
        XCTAssertGreaterThan(rows[0].minY, teamRow.maxY - 1, "The Teams header must sit above its team.")
        XCTAssertGreaterThan(teamRow.minY, rows[2].maxY - 1, "The team must sit above the Bots header.")
        for index in botRows {
            XCTAssertGreaterThan(teamRow.minY, rows[index].maxY - 1,
                                 "The team must sit above bot row \(index).")
            XCTAssertGreaterThan(rows[2].minY, rows[index].maxY - 1,
                                 "The Bots header must sit above bot row \(index).")
        }

        XCTAssertEqual(host.configureTeamCalls, 0, "Rendering must never open the team editor by itself.")
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)
    }

    func testATeamWhoseBotsAreAllArchivedGetsNoEmptyBotsHeader() async throws {
        let host = TeamSidebarPresentationHost(teamCount: 1, botCount: 0, selection: .team)
        defer { host.close() }
        try await host.settle()

        let table = try host.list()
        // The Teams header and its team, and nothing after them: a "Bots"
        // header with no bot under it names an empty list.
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(try host.botRowIndices(in: table), [])
        let rows = host.rowRects(of: table)
        XCTAssertLessThan(rows[0].height, rows[1].height, "Row 0 must be the Teams header and row 1 its team.")
        XCTAssertGreaterThan(rows[0].minY, rows[1].maxY - 1, "The Teams header must sit above its team.")
        // The invitation to start a first bot is drawn over the whole list, so
        // the rule that gates it must not call this list empty.
        XCTAssertFalse(host.sidebar.isEmpty, "A team the user can still click must not sit under the empty state.")

        XCTAssertEqual(host.configureTeamCalls, 0)
        XCTAssertFalse(host.window.isVisible)
    }

    func testBotsKeepOneUnlabelledSectionWhileNoTeamExists() async throws {
        let host = TeamSidebarPresentationHost(teamCount: 0, selection: .firstBot)
        defer { host.close() }
        try await host.settle()

        let table = try host.list()
        // No team means no section to tell apart, so the bots gain no header
        // row: the list stays exactly as many rows as there are bots.
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(try host.botRowIndices(in: table), [0, 1])
        XCTAssertEqual(host.configureTeamCalls, 0)
        XCTAssertFalse(host.window.isVisible)
    }
}

@MainActor
private final class TeamSidebarPresentationHost {
    enum Selection { case team, firstBot }

    let sidebar: SidebarModel
    let bots: [TeammateRowSnapshot]
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    private(set) var configureTeamCalls = 0

    init(teamCount: Int, botCount: Int = 2, selection: Selection) {
        _ = NSApplication.shared
        let bots = (0..<botCount).map { index in
            TeammateRowSnapshot(id: UUID(), name: "Bot \(index)", role: "Local fixture",
                                activity: .idle, identitySeed: UInt64(index + 1))
        }
        self.bots = bots
        let teams = (0..<teamCount).map { index in
            TeamRowSnapshot(id: UUID(), conversationID: UUID(), name: "QA Team \(index)", leadName: "Mira",
                            members: [.init(id: UUID(), name: "Mira"), .init(id: UUID(), name: "Ada")],
                            lastActivityAt: nil)
        }
        let selected: UUID? = switch selection {
        case .team: teams.first?.id ?? bots.first?.id
        case .firstBot: bots.first?.id
        }
        let sidebar = SidebarModel(rows: bots, selection: selected)
        sidebar.replaceTeams(teams)
        self.sidebar = sidebar

        let conversation = ConversationModel(
            conversationID: UUID(), title: teams.first?.name ?? "Bot 0", messages: [], composerText: "",
            readyDeliveryDescription: "Synthetic rendering only", isLocalOnly: true,
            inputAvailability: .ready, submit: { _, _, _ in XCTFail("Rendering must not submit a message") }
        )
        var calls = 0
        let controller = NSHostingController(rootView: AnyView(OpenBotsRootView(
            sidebar: sidebar, conversation: conversation,
            createTeammate: { XCTFail("Rendering must not create a bot") },
            configureTeam: { _ in calls += 1 },
            openSettings: { XCTFail("Rendering must not open Settings") }
        )))
        self.controller = controller
        controller.sizingOptions = []
        let size = CGSize(width: 900, height: 640)
        let window = TeamSidebarPresentationWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        controller.view.frame = CGRect(origin: .zero, size: size)
        self.readCalls = { calls }
    }

    private var readCalls: () -> Int = { 0 }

    func settle() async throws {
        for _ in 0..<8 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(12))
        }
        configureTeamCalls = readCalls()
    }

    func list() throws -> NSTableView {
        try XCTUnwrap(visibleViews.compactMap { $0 as? NSTableView }.first,
                      "The native sidebar list must materialize; an empty root cannot pass.")
    }

    /// Row rectangles in window coordinates, which grow upward on screen.
    func rowRects(of table: NSTableView) -> [CGRect] {
        (0..<table.numberOfRows).map { table.convert(table.rect(ofRow: $0), to: nil) }
    }

    /// Each bot's own reorder drag source names its row, so the bots are found
    /// by identity rather than by counting or by a private view class name.
    func botRowIndices(in table: NSTableView) throws -> [Int] {
        let rows = rowRects(of: table)
        return try bots.map { bot in
            let identifier = "bot-reorder-drag-source-\(bot.id.uuidString)"
            let source = try XCTUnwrap(visibleViews.first { $0.accessibilityIdentifier() == identifier },
                                       "Bot \(bot.name) lost its sidebar row.")
            let frame = source.convert(source.bounds, to: nil)
            return try XCTUnwrap(rows.firstIndex { $0.insetBy(dx: 0, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY)) },
                                 "Bot \(bot.name) sits in no list row.")
        }.sorted()
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    private var visibleViews: [NSView] {
        descendants(controller.view).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor
private final class TeamSidebarPresentationWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
