import AppKit
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class ConversationSearchTests: XCTestCase {
    func testConstructionAndBlankQueryAreInert() async {
        let service = SearchPresentationFake()
        let model = ConversationSearchModel(service: service)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.query, "")
        model.setQuery(" \n\t")
        await model.searchNow()
        let receipt = await service.receipt()
        XCTAssertTrue(receipt.queries.isEmpty)
        XCTAssertEqual(receipt.resolveCalls, 0)
        XCTAssertNil(model.page)
        XCTAssertNil(model.errorMessage)
    }

    func testDebounceCoalescesQueriesAndDoesNotShowOldRows() async throws {
        let page = try searchPage(name: "Ada", snippet: "Newest research")
        let service = SearchPresentationFake(pages: ["Newest": page])
        let model = ConversationSearchModel(service: service, debounce: .milliseconds(20))
        model.setQuery("N")
        model.setQuery("New")
        model.setQuery("Newest")
        XCTAssertEqual(model.query, "Newest")
        XCTAssertEqual(model.state, .waiting)
        XCTAssertNil(model.page)
        let before = await service.receipt()
        XCTAssertTrue(before.queries.isEmpty)
        await waitForSearchState(model, .results)
        let receipt = await service.receipt()
        XCTAssertEqual(receipt.queries, ["Newest"])
        XCTAssertEqual(model.page, page)
        model.setQuery("Different")
        XCTAssertNil(model.page)
        XCTAssertEqual(model.state, .waiting)
        model.cancelPendingSearch()
    }

    func testLateOldResultCannotReplaceNewerQuery() async throws {
        let first = try searchPage(name: "Old", snippet: "Old result")
        let second = try searchPage(name: "New", snippet: "Current result")
        let gate = SearchPresentationGate()
        let service = SearchPresentationFake(pages: ["old": first, "new": second], gates: ["old": gate])
        let model = ConversationSearchModel(service: service, debounce: .seconds(60))
        model.setQuery("old")
        let old = Task { await model.searchNow() }
        await waitForSearchGate(gate)
        model.setQuery("new")
        await model.searchNow()
        XCTAssertEqual(model.page, second)
        await gate.release()
        await old.value
        XCTAssertEqual(model.query, "new")
        XCTAssertEqual(model.page, second)
        XCTAssertEqual(model.state, .results)
    }

    func testClearAndCloseFenceUncooperativePendingService() async throws {
        for shouldClear in [true, false] {
            let page = try searchPage(name: "Ada", snippet: "Late result")
            let gate = SearchPresentationGate()
            let service = SearchPresentationFake(pages: ["query": page], gates: ["query": gate])
            let model = ConversationSearchModel(service: service, debounce: .seconds(60))
            model.setQuery("query")
            let searching = Task { await model.searchNow() }
            await waitForSearchGate(gate)
            if shouldClear { model.clear() } else { model.cancelPendingSearch() }
            XCTAssertEqual(model.state, .idle)
            XCTAssertNil(model.page)
            await gate.release()
            await searching.value
            XCTAssertEqual(model.state, .idle)
            XCTAssertNil(model.page)
            XCTAssertEqual(model.query, shouldClear ? "" : "query")
            let receipt = await service.receipt()
            XCTAssertEqual(receipt.resolveCalls, 0)
        }
    }

    func testValidationStopsOversizeTooManyTermsAndNullBeforeService() async {
        let service = SearchPresentationFake()
        let model = ConversationSearchModel(service: service)
        for value in [String(repeating: "a", count: 201), "one two three four five six seven eight nine", "bad\0query"] {
            model.setQuery(value)
            await model.searchNow()
            XCTAssertEqual(model.state, .failed)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.query, value)
        }
        let receipt = await service.receipt()
        XCTAssertTrue(receipt.queries.isEmpty)
        model.clear()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.state, .idle)
    }

    func testFailureIsLocalSanitizedAndExplicitRetryCanSucceed() async throws {
        let expected = try searchPage(name: "Ada", snippet: "Saved research")
        let service = SearchPresentationFake(pages: ["research": expected], fails: true)
        let model = ConversationSearchModel(service: service, debounce: .seconds(60))
        model.setQuery("research")
        await model.searchNow()
        XCTAssertEqual(model.state, .failed)
        XCTAssertNil(model.page)
        XCTAssertEqual(model.query, "research")
        XCTAssertFalse(model.errorMessage?.contains("/Users/") ?? true)
        await service.setFailure(false)
        await model.searchNow()
        XCTAssertEqual(model.state, .results)
        XCTAssertEqual(model.page, expected)
        XCTAssertNil(model.errorMessage)
    }

    func testNoMatchesAndBoundedMoreResultsRemainDistinct() async throws {
        let page = try searchPage(name: "Ada", snippet: "Bounded result", hasMore: true)
        let service = SearchPresentationFake(pages: ["matches": page])
        let model = ConversationSearchModel(service: service, debounce: .seconds(60))
        model.setQuery("none")
        await model.searchNow()
        XCTAssertEqual(model.state, .noResults)
        XCTAssertFalse(model.hasMoreResults)
        model.setQuery("matches")
        await model.searchNow()
        XCTAssertEqual(model.state, .results)
        XCTAssertTrue(model.hasMoreResults)
        XCTAssertEqual(model.page?.messages.count, 1)
    }

    func testNativeSearchFieldAndResultPanelFitNarrowAndWideWithoutExecutingCallbacks() async throws {
        let page = try searchPage(
            name: String(repeating: "A", count: 80),
            snippet: String(repeating: "Bounded saved message content. ", count: 25), hasMore: true
        )
        let service = SearchPresentationFake(pages: ["research": page])
        let model = ConversationSearchModel(service: service, debounce: .seconds(60))
        model.setQuery("research")
        await model.searchNow()
        var selections = 0
        var closes = 0
        let controller = NSHostingController(rootView: ConversationSearchView(
            model: model,
            onSelectTeammate: { _ in selections += 1 },
            onSelectMessage: { _ in selections += 1 },
            onClose: { closes += 1 }
        ))
        let host = controller.view
        for width: CGFloat in [400, 700] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            let measured = controller.sizeThatFits(in: CGSize(width: width, height: 720))
            XCTAssertTrue(measured.width.isFinite && measured.height.isFinite)
            XCTAssertGreaterThan(measured.width, 0)
            XCTAssertGreaterThan(measured.height, 0)
            XCTAssertLessThanOrEqual(measured.width, width + 0.5)
            XCTAssertLessThanOrEqual(measured.height, 720.5)
            let fields = host.searchDescendants.compactMap { $0 as? NSTextField }.filter(\.isEditable)
            XCTAssertEqual(fields.count, 1)
            let field = try XCTUnwrap(fields.first)
            XCTAssertEqual(field.stringValue, "research")
            XCTAssertEqual(field.placeholderString, "Search teammates and saved messages")
            let frame = field.convert(field.bounds, to: host)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
        }
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(model.page, page)
        let receipt = await service.receipt()
        XCTAssertEqual(receipt.resolveCalls, 0)
        // Windowless layout/input materialization only. No native activation,
        // key events, AX helper, result navigation, or VoiceOver claim.
    }

    func testSourceStatesScopeAndKeepsInlineExplicitKeyboardActions() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/ConversationSearchView.swift"), encoding: .utf8)
        XCTAssertTrue(ConversationSearchModel.scopeDisclosure.contains("active teammates"))
        XCTAssertTrue(ConversationSearchModel.scopeDisclosure.contains("saved messages"))
        XCTAssertTrue(ConversationSearchModel.scopeDisclosure.contains("Unsent drafts and secret-card input are not searched"))
        XCTAssertTrue(source.contains(".onExitCommand { close() }"))
        XCTAssertTrue(source.contains(".onSubmit { Task { await model.searchNow() } }"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Clear search\")"))
        XCTAssertFalse(source.contains(".sheet("))
        XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertFalse(source.contains("SecureField("))
    }
}

private actor SearchPresentationFake: ConversationSearchServing {
    private let pages: [String: ConversationSearchPage]
    private let gates: [String: SearchPresentationGate]
    private var fails: Bool
    private var queries: [String] = []
    private var resolveCalls = 0
    init(pages: [String: ConversationSearchPage] = [:], gates: [String: SearchPresentationGate] = [:], fails: Bool = false) {
        self.pages = pages; self.gates = gates; self.fails = fails
    }
    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        queries.append(request.query)
        if let gate = gates[request.query] { await gate.wait() }
        if fails { throw SearchPresentationFailure() }
        // Deliberately ignore task cancellation: the model must fence results.
        return pages[request.query] ?? ConversationSearchPage(teammates: [], messages: [], hasMoreTeammates: false, hasMoreMessages: false)
    }
    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? { resolveCalls += 1; return nil }
    func setFailure(_ value: Bool) { fails = value }
    func receipt() -> (queries: [String], resolveCalls: Int) { (queries, resolveCalls) }
}

private struct SearchPresentationFailure: LocalizedError {
    var errorDescription: String? { "Private search failure /Users/example/private.sqlite" }
}

private actor SearchPresentationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private func waitForSearchGate(_ gate: SearchPresentationGate) async {
    for _ in 0..<200 {
        if await gate.started { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Search operation did not reach its bounded gate")
}

@MainActor
private func waitForSearchState(_ model: ConversationSearchModel, _ state: ConversationSearchState) async {
    for _ in 0..<200 {
        if model.state == state { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Search did not settle")
}

private func searchPage(name: String, snippet: String, hasMore: Bool = false) throws -> ConversationSearchPage {
    let teammateID = TeammateID(UUID(uuidString: "AB000000-0000-0000-0000-000000000001")!)
    let conversationID = ConversationID(UUID(uuidString: "AB000000-0000-0000-0000-000000000002")!)
    let date = Date(timeIntervalSince1970: 1_788_000_000)
    let teammate = try Teammate(
        id: teammateID,
        profile: TeammateProfile(displayName: name, role: "Research and synthesis with traceable evidence"),
        appearance: AgentAppearance(
            mode: .creature, grammarVersion: 1, deterministicSeed: 17,
            silhouette: "round", paletteToken: "sky", eyeDialect: "calm",
            nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a single crest"
        ),
        createdAt: date, updatedAt: date
    )
    return ConversationSearchPage(
        teammates: [TeammateSearchHit(teammate: teammate, conversationID: conversationID)],
        messages: [MessageSearchHit(
            id: MessageID(UUID(uuidString: "AB000000-0000-0000-0000-000000000003")!),
            conversationID: conversationID, teammateID: teammateID, teammateName: name,
            author: .user, authorName: "You", snippet: snippet, sequence: 1, createdAt: date
        )],
        hasMoreTeammates: hasMore, hasMoreMessages: hasMore
    )
}

private extension NSView {
    var searchDescendants: [NSView] { subviews + subviews.flatMap(\.searchDescendants) }
}
