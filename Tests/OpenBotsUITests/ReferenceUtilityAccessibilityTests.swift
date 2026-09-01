import AppKit
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// In-process native fixture tests only. No external AX tree, system focus,
/// provider, helper or installed-app window is used.
@MainActor
final class ReferenceUtilityAccessibilityTests: XCTestCase {
    func testUnattachedSettingsCloseCannotChooseAnAmbientWindow() {
        _ = NSApplication.shared
        let unrelated = UtilityCloseFixtureWindow()
        let target = UtilityOwningWindowClose()
        defer { unrelated.close() }
        XCTAssertFalse(target.isAttached)
        XCTAssertNil(target.window)
        target.close()
        XCTAssertEqual(unrelated.closeRequests, 0)
        XCTAssertFalse(unrelated.isVisible)
    }

    func testSettingsCloseKeepsRetainedContentAttachedToItsExactWindow() {
        _ = NSApplication.shared
        let owned = UtilityCloseFixtureWindow()
        let foreign = UtilityCloseFixtureWindow()
        let target = UtilityOwningWindowClose()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let reporter = UtilitySettingsWindowAttachment.Reporter(closeTarget: target)
        owned.contentView = content
        content.addSubview(reporter)
        defer {
            reporter.removeFromSuperview()
            owned.close()
            foreign.close()
        }
        XCTAssertTrue(target.isAttached)
        XCTAssertTrue(reporter.window === owned)
        foreign.close()
        XCTAssertTrue(target.window === owned)
        XCTAssertEqual(owned.closeRequests, 0)

        target.close()
        XCTAssertEqual(owned.closeRequests, 1)
        XCTAssertTrue(owned.contentView === content)
        XCTAssertTrue(reporter.window === owned, "Closing a retained window does not detach its content")
        XCTAssertTrue(target.isAttached)
        XCTAssertTrue(target.window === owned)
        target.close()
        XCTAssertEqual(owned.closeRequests, 2, "Retained content must still target the same window on its next close request")
        XCTAssertEqual(foreign.closeRequests, 0)

        reporter.removeFromSuperview()
        XCTAssertFalse(target.isAttached)
        XCTAssertNil(target.window)
        target.close()
        XCTAssertEqual(owned.closeRequests, 2, "Only an actual detach removes the close target")
        XCTAssertEqual(foreign.closeRequests, 0)
        XCTAssertFalse(owned.isVisible)
        XCTAssertFalse(foreign.isVisible)
    }

    func testSettingsAttachmentRebindIgnoresStaleDetachAndOldWindowClose() {
        _ = NSApplication.shared
        let first = UtilityCloseFixtureWindow()
        let current = UtilityCloseFixtureWindow()
        let firstReporter = NSObject()
        let currentReporter = NSObject()
        let target = UtilityOwningWindowClose()
        defer {
            target.detach(from: currentReporter)
            first.close()
            current.close()
        }
        target.attach(first, from: firstReporter)
        target.attach(current, from: currentReporter)
        target.detach(from: firstReporter)
        first.close()
        XCTAssertTrue(target.window === current)
        XCTAssertTrue(target.isAttached)

        current.close()
        XCTAssertTrue(target.window === current)
        XCTAssertTrue(target.isAttached)
        target.detach(from: firstReporter)
        target.close()
        XCTAssertEqual(first.closeRequests, 0)
        XCTAssertEqual(current.closeRequests, 1)

        target.detach(from: currentReporter)
        XCTAssertFalse(target.isAttached)
        XCTAssertNil(target.window)
        target.close()
        XCTAssertEqual(first.closeRequests, 0)
        XCTAssertEqual(current.closeRequests, 1)
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(current.isVisible)
    }

    func testNativeSearchQueryAndResultActionsPreserveExactInputs() async throws {
        let page = try utilitySearchPage()
        let service = UtilitySearchService(page: page)
        let model = ConversationSearchModel(service: service, debounce: .seconds(60))
        let exactQuery = "Cafe\u{301}  evidence"
        model.setQuery(exactQuery)
        await model.searchNow()
        var selectedBots: [TeammateSearchHit] = []
        var selectedMessages: [MessageSearchHit] = []
        var closeCalls = 0
        let view = ConversationSearchView(model: model,
            onSelectTeammate: { selectedBots.append($0) },
            onSelectMessage: { selectedMessages.append($0) }, onClose: { closeCalls += 1 })
        let host = UtilitySearchNativeHost(view: view)
        defer { host.close() }
        try await host.settle()
        let field = try XCTUnwrap(host.fields.first { $0.placeholderString == "Search teammates and saved messages" })
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.stringValue.utf8.elementsEqual(exactQuery.utf8))
        XCTAssertTrue(model.query.utf8.elementsEqual(exactQuery.utf8))
        XCTAssertEqual(model.page, page)
        XCTAssertTrue(selectedBots.isEmpty && selectedMessages.isEmpty)

        // Same view actions used by native result buttons, without claiming
        // hidden-window mouse or VoiceOver dispatch coverage.
        view.selectTeammate(try XCTUnwrap(page.teammates.first))
        view.selectMessage(try XCTUnwrap(page.messages.first))
        XCTAssertEqual(selectedBots, page.teammates)
        XCTAssertEqual(selectedMessages, page.messages)
        XCTAssertEqual(closeCalls, 0)
        view.close()
        XCTAssertEqual(closeCalls, 1)
        XCTAssertTrue(model.query.utf8.elementsEqual(exactQuery.utf8))
        XCTAssertEqual(model.page, page)
        let receipt = await service.receipt()
        XCTAssertEqual(receipt.queries, [exactQuery])
        XCTAssertEqual(receipt.resolutions, 0, "The view forwards the exact hit; only the coordinator may resolve history")
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)
    }

    func testSearchCloseCancelsPendingQueryWithoutClearingOrNavigating() async throws {
        let service = UtilitySearchService(page: try utilitySearchPage(), delays: true)
        let model = ConversationSearchModel(service: service, debounce: .seconds(60))
        model.setQuery("pending local query")
        let operation = Task { await model.searchNow() }
        for _ in 0..<100 {
            if await service.hasPendingReply { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await service.hasPendingReply
        XCTAssertTrue(pending)
        var closeCalls = 0
        var navigationCalls = 0
        let view = ConversationSearchView(model: model,
            onSelectTeammate: { _ in navigationCalls += 1 },
            onSelectMessage: { _ in navigationCalls += 1 }, onClose: { closeCalls += 1 })
        view.close()
        await service.release()
        await operation.value
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(navigationCalls, 0)
        XCTAssertEqual(model.query, "pending local query")
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.page, "A late result cannot remount after Search closes")
    }

}

@MainActor
private final class UtilityCloseFixtureWindow: NSWindow {
    private(set) var closeRequests = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func performClose(_ sender: Any?) {
        closeRequests += 1
        super.performClose(sender)
    }
}

@MainActor
private final class UtilitySearchNativeHost {
    let window: NSWindow
    private let controller: NSHostingController<AnyView>
    private let container: NSViewController
    var fields: [NSTextField] { descendants(controller.view).compactMap { $0 as? NSTextField } }

    init<V: View>(view: V) {
        _ = NSApplication.shared
        let size = CGSize(width: 500, height: 620)
        controller = NSHostingController(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        controller.sizingOptions = []
        container = NSViewController()
        container.view = NSView(frame: CGRect(origin: .zero, size: size))
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.view.frame = container.view.bounds
        controller.view.autoresizingMask = [.width, .height]
        window = UtilityCloseFixtureWindow()
        window.contentViewController = container
        window.setContentSize(size)
    }

    func settle() async throws {
        for _ in 0..<6 {
            container.view.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() { window.contentViewController = nil; window.close() }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private actor UtilitySearchService: ConversationSearchServing {
    let page: ConversationSearchPage
    let delays: Bool
    private var queries: [String] = []
    private var resolutions = 0
    private var isReleased = false
    private var pending: CheckedContinuation<ConversationSearchPage, Never>?
    var hasPendingReply: Bool { pending != nil }

    init(page: ConversationSearchPage, delays: Bool = false) { self.page = page; self.delays = delays }
    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        queries.append(request.query)
        if delays, !isReleased { return await withCheckedContinuation { pending = $0 } }
        return page
    }
    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? { resolutions += 1; return nil }
    func release() { isReleased = true; pending?.resume(returning: page); pending = nil }
    func receipt() -> (queries: [String], resolutions: Int) { (queries, resolutions) }
}

private func utilitySearchPage() throws -> ConversationSearchPage {
    let teammate = try s3ATeammate(71, name: "Search Fixture", role: "Local evidence reviewer")
    let conversationID = ConversationID(UUID())
    return ConversationSearchPage(
        teammates: [.init(teammate: teammate, conversationID: conversationID)],
        messages: [.init(id: MessageID(UUID()), conversationID: conversationID, teammateID: teammate.id,
                         teammateName: teammate.profile.displayName, author: .user, authorName: "You",
                         snippet: "A saved local fixture with no provider actions.", sequence: 4,
                         createdAt: Date(timeIntervalSince1970: 1_788_000_000))],
        hasMoreTeammates: false, hasMoreMessages: false
    )
}
