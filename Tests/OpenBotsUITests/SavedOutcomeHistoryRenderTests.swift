import AppKit
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Windowless synthetic render evidence only. These tests never create an
/// NSWindow, activate an app, inspect desktop accessibility or open a database.
@MainActor
final class SavedOutcomeHistoryRenderTests: XCTestCase {
    func testLoadedHistoryFitsNarrowAndWideLightAndDark() async throws {
        let request = try renderHistoryRequest()
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [238, 600] {
                // Disappearing clears results by design. Each independent
                // windowless host therefore gets its own freshly loaded model.
                let fixture = RenderOutcomeHistoryService(.success(loadedHistorySummary()))
                let model = SavedOutcomeHistoryModel(service: fixture)
                model.activateScope(request)
                await model.load()
                XCTAssertNotNil(model.summary)
                XCTAssertNil(model.errorMessage)
                let surface = SavedOutcomeHistoryView(model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(.background)
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                try await render(surface, width: width, scheme: scheme,
                    filename: "saved-history-loaded-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png")
                let requests = await fixture.requests
                XCTAssertEqual(requests, [request], "Rendering must not start another history read.")
            }
        }
    }

    func testInitialEmptyUnavailableAndErrorSurfacesFitWithoutTechnicalData() async throws {
        let request = try renderHistoryRequest()
        for (width, scheme) in [(CGFloat(238), ColorScheme.light), (CGFloat(600), ColorScheme.dark)] {
            let initialFixture = RenderOutcomeHistoryService(.success(loadedHistorySummary()))
            let initial = SavedOutcomeHistoryModel(service: initialFixture)
            initial.activateScope(request)
            let empty = SavedOutcomeHistoryModel(service: RenderOutcomeHistoryService(.success(
                ConversationOutcomeHistorySummary(scope: .available, outcomes: [], hasMore: false,
                    notice: "No saved outcomes were found for this conversation."))))
            let unavailable = SavedOutcomeHistoryModel(service: RenderOutcomeHistoryService(.success(
                ConversationOutcomeHistorySummary(scope: .unavailable, outcomes: [], hasMore: false,
                    notice: "Saved outcomes are unavailable for this conversation."))))
            let failed = SavedOutcomeHistoryModel(service: RenderOutcomeHistoryService(.failure(.privateDiagnostic(RenderOutcomeHistoryError.sentinel))))
            for model in [empty, unavailable, failed] {
                model.activateScope(request)
                await model.load()
            }
            XCTAssertNil(initial.summary)
            XCTAssertEqual(empty.summary?.scope, .available)
            XCTAssertEqual(unavailable.summary?.scope, .unavailable)
            XCTAssertNotNil(failed.errorMessage)
            XCTAssertFalse(failed.errorMessage?.contains(RenderOutcomeHistoryError.sentinel) ?? true)
            let surface = VStack(alignment: .leading, spacing: 20) {
                labelledFixture("Initial, before reading", model: initial)
                Divider()
                labelledFixture("Available, no saved outcomes", model: empty)
                Divider()
                labelledFixture("Unavailable conversation scope", model: unavailable)
                Divider()
                labelledFixture("Read failure", model: failed)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            try await render(surface, width: width, scheme: scheme,
                filename: "saved-history-states-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png")
            let reads = await initialFixture.requests
            XCTAssertTrue(reads.isEmpty, "An initial view remains an explicit read action, not a render side effect.")
        }
    }

    func testViewSourceDoesNotRenderRawIdentityOrOfferAnExecutionSurface() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/OpenBotsUI/SavedOutcomeHistoryView.swift"), encoding: .utf8)
        for forbidden in [".uuidString", ".persistedValue", "String(reflecting:", "String(describing:",
                          "request.conversationID", "request.teammateID", "TextField(", "TextEditor(",
                          "SecureField(", "WebView", "NSWorkspace", ".sheet("] {
            XCTAssertFalse(source.contains(forbidden), "The read-only outcome view exposes \(forbidden)")
        }
        // SwiftUI Text is not necessarily an NSTextField in a windowless host.
        // This narrow source assertion complements (not replaces) the renders;
        // neither is a live VoiceOver, keyboard or packaged-app inspection pass.
    }

    private func labelledFixture(_ title: String, model: SavedOutcomeHistoryModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            SavedOutcomeHistoryView(model: model)
        }
    }

    private func render<Content: View>(_ surface: Content, width: CGFloat, scheme: ColorScheme, filename: String) async throws {
        let maximumHeight: CGFloat = 2_400
        let host = NSHostingController(rootView: surface)
        host.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: maximumHeight)
        for _ in 0..<3 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let fit = host.sizeThatFits(in: CGSize(width: width, height: maximumHeight))
        XCTAssertTrue(fit.width.isFinite && fit.height.isFinite)
        XCTAssertGreaterThan(fit.height, 0)
        XCTAssertLessThanOrEqual(fit.width, width + 0.5)
        XCTAssertLessThanOrEqual(fit.height, maximumHeight)
        let captureHeight = min(maximumHeight, max(80, ceil(fit.height) + 12))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: captureHeight)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertNil(host.view.window)

        let visible = descendants(of: host.view).filter { !$0.isHiddenOrHasHiddenAncestor }
        for view in visible {
            let rect = view.convert(view.bounds, to: host.view)
            XCTAssertTrue(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite)
            XCTAssertGreaterThanOrEqual(rect.width, 0)
            XCTAssertGreaterThanOrEqual(rect.height, 0)
        }
        let materializedText = visible.compactMap { view -> String? in
            if let field = view as? NSTextField { return field.stringValue }
            if let text = view as? NSTextView { return text.string }
            if let button = view as? NSButton { return button.title }
            return nil
        }.joined(separator: "\n")
        for sentinel in renderHistoryIdentityStrings + [RenderOutcomeHistoryError.sentinel, "request_json", "envelope_json", "outcomeUnknown", "lease_token"] {
            XCTAssertFalse(materializedText.contains(sentinel))
        }

        let directory = repositoryRoot.appendingPathComponent(".build.noindex/outcome-history-ui-tests/rendered", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 100)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

private let renderHistoryConversation = UUID(uuidString: "ad000000-0000-0000-0000-000000000001")!
private let renderHistoryTeammate = UUID(uuidString: "ad000000-0000-0000-0000-000000000002")!
private let renderHistoryRun = UUID(uuidString: "ad000000-0000-0000-0000-000000000003")!
private let renderHistoryDemo = UUID(uuidString: "ad000000-0000-0000-0000-000000000004")!
private let renderHistoryProposal = UUID(uuidString: "ad000000-0000-0000-0000-000000000005")!
private let renderHistoryIdentityStrings = [renderHistoryConversation, renderHistoryTeammate, renderHistoryRun, renderHistoryDemo, renderHistoryProposal]
    .flatMap { [$0.uuidString, $0.uuidString.lowercased()] }

private func renderHistoryRequest() throws -> ConversationOutcomeHistoryRequest {
    try ConversationOutcomeHistoryRequest(conversationID: ConversationID(renderHistoryConversation), teammateID: TeammateID(renderHistoryTeammate), limit: 3)
}

private func loadedHistorySummary() -> ConversationOutcomeHistorySummary {
    let date = Date(timeIntervalSince1970: 1_783_000_000)
    return ConversationOutcomeHistorySummary(scope: .available, outcomes: [
        SavedOutcomeSummary(reference: .run(RunID(renderHistoryRun)), recordedAt: date,
            text: "Work was recorded as interrupted. This saved status is not an independent check of the result. Some input has no confirmed acknowledgment; its receipt is not proven. The outcome of some input is unknown. Nothing will be replayed automatically."),
        SavedOutcomeSummary(reference: .run(RunID(renderHistoryDemo)), recordedAt: date.addingTimeInterval(-60),
            text: "A local demo was marked complete. This was a demonstration, not real teammate work."),
        SavedOutcomeSummary(reference: .proposal(ApprovalID(renderHistoryProposal)), recordedAt: date.addingTimeInterval(-120),
            text: "Your approval was recorded for a demo action. This recorded review did not grant access or execute the action.")
    ], hasMore: true, notice: "Showing only the most recent 3 saved outcomes. Earlier records are not included.")
}

private enum RenderOutcomeHistoryError: Error, LocalizedError {
    static let sentinel = "PRIVATE_RENDER_ERROR_DO_NOT_DISPLAY"
    case privateDiagnostic(String)
    var errorDescription: String? {
        switch self { case .privateDiagnostic(let text): text }
    }
}

private actor RenderOutcomeHistoryService: ConversationOutcomeHistoryServing {
    let result: Result<ConversationOutcomeHistorySummary, RenderOutcomeHistoryError>
    private(set) var requests: [ConversationOutcomeHistoryRequest] = []
    init(_ result: Result<ConversationOutcomeHistorySummary, RenderOutcomeHistoryError>) { self.result = result }
    func history(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistorySummary {
        requests.append(request)
        return try result.get()
    }
}
