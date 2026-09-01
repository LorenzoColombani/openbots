import AppKit
import Darwin
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class WorkspaceSearchPresentationTests: XCTestCase {
    private static let childFlag = "OPENBOTS_SEARCH_PRESENTATION_CHILD"
    private static let completed = "OPENBOTS_SEARCH_PRESENTATION_COMPLETED"

    func testWholeRootSearchEntryAndReturnPreserveConversationAtBothWidths() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try await exerciseSearchPresentation()
            searchPresentationPhase(Self.completed)
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest", "-XCTest",
            "OpenBotsUITests.WorkspaceSearchPresentationTests/testWholeRootSearchEntryAndReturnPreserveConversationAtBothWidths",
            Bundle(for: Self.self).bundleURL.path
        ]
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment[Self.childFlag] = "1"
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        try output.fileHandleForWriting.close()
        let log = SearchPresentationChildLog(reader: output.fileHandleForReading)
        log.start()
        let deadline = Date(timeIntervalSinceNow: 15)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let timedOut = child.isRunning
        if timedOut {
            child.terminate()
            let grace = Date(timeIntervalSinceNow: 1)
            while child.isRunning, Date() < grace { try await Task.sleep(for: .milliseconds(10)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let receipt = log.finish()
        let receiptURL = try saveSearchPresentationReceipt(receipt)
        searchPresentationPhase("receipt: \(receiptURL.path)")
        XCTAssertFalse(timedOut, "Search presentation exceeded its 15-second child deadline. \(receipt)")
        XCTAssertEqual(child.terminationStatus, 0, receipt)
        XCTAssertTrue(receipt.contains(Self.completed), "Missing completed whole-root exercise. \(receipt)")
    }

    func testWrapperKeepsInlineOverrideAndNativeSearchToolbarShortcut() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/WorkspaceSearchCoordinator.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("content(coordinator.isPresented ? AnyView(WorkspaceSearchView(coordinator: coordinator)) : nil)"))
        XCTAssertTrue(source.contains("Button(action: coordinator.present)"))
        XCTAssertTrue(source.contains("Label(\"Search\", systemImage: \"magnifyingglass\")"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".help(\"Search teammates and saved messages\")"))
        XCTAssertFalse(source.contains(".sheet("))
        XCTAssertFalse(source.contains("NSWindow("))
        // Toolbar declarations are source evidence. The child below proves
        // the full inline presentation, not live Cmd-F or VoiceOver behavior.
    }
}

@MainActor
private func exerciseSearchPresentation() async throws {
    _ = NSApplication.shared
    let teammate = TeammateRowSnapshot(
        id: searchPresentationID(1), name: "Ada Search Fixture", role: "Local research", activity: .idle, identitySeed: 14
    )
    let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
    let messages = (1...4).map { index in
        ChatMessageSnapshot(
            id: searchPresentationID(UInt64(index + 10)), author: .user,
            body: "Saved local transcript marker \(index)", delivery: .sent,
            timestamp: Date(timeIntervalSince1970: 1_788_000_000 + Double(index))
        )
    }
    let draft = "Unsent draft stays with Ada — exact Unicode e\u{301}."
    let submissions = WorkspaceSearchSubmissionCounter()
    var navigations = 0
    var unrelatedActions = 0
    let conversation = ConversationModel(
        conversationID: searchPresentationID(2), title: teammate.name, messages: messages,
        composerText: draft, readyDeliveryDescription: "Synthetic local test. No runtime or storage.",
        inputAvailability: .ready, submit: { _, _, _ in await submissions.record() }
    )
    let service = WorkspaceSearchPresentationService()
    let coordinator = WorkspaceSearchCoordinator(service: service) { _, _ in navigations += 1 }
    let rowIdentities = conversation.messageRows.map(ObjectIdentifier.init)
    let root = WorkspaceSearchPresentation(coordinator: coordinator) { detail in
        OpenBotsRootView(
            sidebar: sidebar, conversation: conversation,
            createTeammate: { unrelatedActions += 1 }, openSettings: { unrelatedActions += 1 },
            searchOverlay: detail
        )
    }
    let controller = NSHostingController(rootView: root)
    controller.sizingOptions = []
    let window = WorkspaceSearchTestWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 720),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    let owner = NSWindowController(window: window)
    defer {
        window.contentViewController = nil
        owner.close()
    }
    // The owned child window is never ordered, made key, or activated. This
    // exercises rendered root replacement without desktop-control or input.
    for width: CGFloat in [1_080, 840] {
        window.setContentSize(CGSize(width: width, height: 720))
        controller.view.frame.size = CGSize(width: width, height: 720)
        try await settleSearchPresentation(controller.view, phase: "closed at \(width)")
        let content = try XCTUnwrap(window.contentView)
        let composer = try XCTUnwrap(searchPresentationEditor(in: content, value: draft))
        assertSearchPresentationEditing(composer, enabled: true)
        assertSearchPresentationBounds(composer, in: content, width: width)
        XCTAssertNil(searchPresentationField(in: content))
        XCTAssertTrue(content.workspaceSearchDescendants.compactMap { $0 as? NSTextField }.contains {
            !$0.isEditable && $0.stringValue == messages.last?.body
        }, "The underlying transcript must materialize; an empty host cannot pass")
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))

        coordinator.present()
        try await settleSearchPresentation(controller.view, phase: "search open at \(width)")
        let search = try XCTUnwrap(searchPresentationField(in: content), "The full-root detail override must mount search")
        XCTAssertTrue(search.window === window)
        XCTAssertFalse(search.isHiddenOrHasHiddenAncestor)
        assertSearchPresentationBounds(search, in: content, width: width)
        XCTAssertTrue(searchPresentationEditor(in: content, value: draft) === composer,
                      "Search must retain the original composer and transcript beneath its overlay")
        assertSearchPresentationEditing(composer, enabled: false)
        assertSearchPresentationEditing(search, enabled: true)
        coordinator.model.setQuery("saved")
        await coordinator.model.searchNow()
        try await settleSearchPresentation(controller.view, phase: "search result state at \(width)")
        XCTAssertEqual(coordinator.model.state, .noResults)
        XCTAssertEqual(searchPresentationField(in: content)?.stringValue, "saved")

        coordinator.close()
        try await settleSearchPresentation(controller.view, phase: "returned to chat at \(width)")
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(searchPresentationField(in: content))
        let restored = try XCTUnwrap(searchPresentationEditor(in: content, value: draft))
        XCTAssertTrue(restored.window === window)
        XCTAssertTrue(restored === composer, "Returning from search must preserve the original native composer")
        assertSearchPresentationEditing(restored, enabled: true)
        assertSearchPresentationBounds(restored, in: content, width: width)
        XCTAssertTrue(conversation.composerText.utf8.elementsEqual(draft.utf8))
        XCTAssertEqual(conversation.messages, messages)
        XCTAssertEqual(conversation.messageRows.map(ObjectIdentifier.init), rowIdentities)
        XCTAssertEqual(sidebar.selection, teammate.id)
        XCTAssertEqual(conversation.conversationID, searchPresentationID(2))
        XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), existingWindows,
                       "Opening inline search must not create another window")
        XCTAssertTrue(window.sheets.isEmpty)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.view.bounds.width.isFinite && controller.view.bounds.height.isFinite)
        XCTAssertEqual(controller.view.bounds.width, width, accuracy: 1)
        XCTAssertEqual(controller.view.bounds.height, 720, accuracy: 1)
        searchPresentationPhase("verified open/search/return: width \(width), rows \(conversation.messageRows.count), same window")
    }
    let submitCount = await submissions.count
    XCTAssertEqual(submitCount, 0)
    XCTAssertEqual(navigations, 0)
    XCTAssertEqual(unrelatedActions, 0)
    let receipt = await service.receipt()
    XCTAssertEqual(receipt.resolves, 0)
    XCTAssertFalse(receipt.queries.isEmpty)
    XCTAssertTrue(receipt.queries.allSatisfy { $0 == "saved" })
}

@MainActor
private final class WorkspaceSearchTestWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private actor WorkspaceSearchPresentationService: ConversationSearchServing {
    private var queries: [String] = []
    private var resolves = 0
    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        queries.append(request.query)
        return ConversationSearchPage(teammates: [], messages: [], hasMoreTeammates: false, hasMoreMessages: false)
    }
    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? { resolves += 1; return nil }
    func receipt() -> (queries: [String], resolves: Int) { (queries, resolves) }
}

private actor WorkspaceSearchSubmissionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
private func settleSearchPresentation(_ host: NSView, phase: String) async throws {
    searchPresentationPhase(phase)
    var sentinel = false
    DispatchQueue.main.async { sentinel = true }
    for _ in 0..<4 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(sentinel, "Main queue did not settle during \(phase)")
}

@MainActor
private func searchPresentationField(in root: NSView) -> NSTextField? {
    root.workspaceSearchDescendants.compactMap { $0 as? NSTextField }.first {
        $0.isEditable && $0.placeholderString == "Search teammates and saved messages"
    }
}

@MainActor
private func searchPresentationEditor(in root: NSView, value: String) -> NSView? {
    root.workspaceSearchDescendants.first {
        // Locate the same editor even while its native enabled/editable flag
        // is off. Its exact fixture text does not appear in any static label.
        if let field = $0 as? NSTextField { return field.stringValue == value }
        if let text = $0 as? NSTextView { return text.string == value }
        return false
    }
}

@MainActor
private func assertSearchPresentationEditing(_ view: NSView, enabled: Bool) {
    if let field = view as? NSTextField {
        XCTAssertEqual(field.isEnabled, enabled, "Covered native fields must be disabled, not only transparent")
        if enabled { XCTAssertTrue(field.isEditable) }
        searchPresentationPhase("native field editing: enabled=\(field.isEnabled), editable=\(field.isEditable)")
    } else if let text = view as? NSTextView {
        XCTAssertEqual(text.isEditable, enabled, "Covered native text must stop accepting edits")
        searchPresentationPhase("native text editing: editable=\(text.isEditable)")
    } else {
        XCTFail("Expected an observable native text editor")
    }
}

@MainActor
private func assertSearchPresentationBounds(_ view: NSView, in root: NSView, width: CGFloat) {
    let rect = view.convert(view.bounds, to: root)
    XCTAssertTrue(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite)
    XCTAssertGreaterThan(rect.width, 0)
    XCTAssertGreaterThan(rect.height, 0)
    XCTAssertGreaterThanOrEqual(rect.minX, -1)
    XCTAssertLessThanOrEqual(rect.maxX, width + 1)
    XCTAssertGreaterThanOrEqual(rect.minY, -1)
    XCTAssertLessThanOrEqual(rect.maxY, root.bounds.height + 1)
}

private extension NSView {
    var workspaceSearchDescendants: [NSView] { subviews + subviews.flatMap(\.workspaceSearchDescendants) }
}

private func searchPresentationID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "AA500000-0000-0000-0000-%012llx", value))!
}

private func searchPresentationPhase(_ text: String) {
    FileHandle.standardError.write(Data(("[workspace-search-test] \(text)\n").utf8))
}

private func saveSearchPresentationReceipt(_ text: String) throws -> URL {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build.noindex/shutdown-ui-tests/search", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("workspace-search-" + UUID().uuidString + ".log")
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

private final class SearchPresentationChildLog: @unchecked Sendable {
    private let reader: FileHandle
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var tail = Data()
    init(reader: FileHandle) { self.reader = reader }
    func start() {
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            while let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                lock.withLock {
                    tail.append(bytes)
                    if tail.count > 131_072 { tail.removeFirst(tail.count - 131_072) }
                }
            }
        }
    }
    func finish() -> String {
        _ = done.wait(timeout: .now() + 1)
        return lock.withLock { String(decoding: tail, as: UTF8.self) }
    }
}
