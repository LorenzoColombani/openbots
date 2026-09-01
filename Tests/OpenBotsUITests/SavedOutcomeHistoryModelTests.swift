import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsUI

@MainActor
final class SavedOutcomeHistoryModelTests: XCTestCase {
    func testConstructionScopeActivationAndNoScopeLoadAreInert() async throws {
        let service = SavedHistoryTestService()
        let model = SavedOutcomeHistoryModel(service: service)
        XCTAssertNil(model.request)
        XCTAssertNil(model.summary)
        XCTAssertFalse(model.canLoad)
        await model.load()
        let request = try savedHistoryRequest(1)
        model.activateScope(request)
        model.activateScope(request)
        XCTAssertEqual(model.request, request)
        XCTAssertTrue(model.canLoad)
        XCTAssertFalse(model.hasRequested)
        XCTAssertFalse(model.isLoading)
        let calls = await service.requests
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(request.limit, 20)
    }

    func testExplicitLoadPreservesEmptyAndUnavailableAsDifferentReadResults() async throws {
        for scope in [SavedOutcomeScopeStatus.available, .unavailable] {
            let notice = scope == .available ? "No saved outcomes were found." : "Saved outcomes are unavailable."
            let summary = ConversationOutcomeHistorySummary(scope: scope, outcomes: [], hasMore: false, notice: notice)
            let service = SavedHistoryTestService(replies: [.init(summary: summary)])
            let model = SavedOutcomeHistoryModel(service: service)
            let request = try savedHistoryRequest(1)
            model.activateScope(request)
            await model.load()
            XCTAssertEqual(model.summary, summary)
            XCTAssertEqual(model.summary?.scope, scope)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.hasRequested)
            XCTAssertFalse(model.isLoading)
            let calls = await service.requests
            XCTAssertEqual(calls, [request])
        }
    }

    func testLoadedReadCanBeHiddenAndOnlyExplicitReloadQueriesAgain() async throws {
        let first = savedHistorySummary("First saved outcome")
        let second = savedHistorySummary("New saved outcome")
        let service = SavedHistoryTestService(replies: [.init(summary: first), .init(summary: second)])
        let model = SavedOutcomeHistoryModel(service: service)
        let request = try savedHistoryRequest(1)
        model.activateScope(request)
        await model.load()
        XCTAssertEqual(model.summary, first)
        model.dismiss()
        XCTAssertEqual(model.request, request)
        XCTAssertNil(model.summary)
        XCTAssertFalse(model.hasRequested)
        XCTAssertTrue(model.canLoad)
        let before = await service.requests
        XCTAssertEqual(before, [request])
        await model.load()
        XCTAssertEqual(model.summary, second)
        let after = await service.requests
        XCTAssertEqual(after, [request, request])
    }

    func testFailureIsSanitizedAndRetryIsExplicit() async throws {
        let result = savedHistorySummary("Recovered read")
        let service = SavedHistoryTestService(replies: [.init(summary: result, failure: true), .init(summary: result)])
        let model = SavedOutcomeHistoryModel(service: service)
        let request = try savedHistoryRequest(1)
        model.activateScope(request)
        await model.load()
        XCTAssertNil(model.summary)
        XCTAssertTrue(model.errorMessage?.contains("Retry Saved Outcomes") ?? false)
        XCTAssertFalse(model.errorMessage?.contains("PRIVATE-SENTINEL") ?? true)
        XCTAssertFalse(model.errorMessage?.contains("/Users/") ?? true)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.canLoad)
        let before = await service.requests
        XCTAssertEqual(before, [request])
        await model.load()
        XCTAssertEqual(model.summary, result)
        XCTAssertNil(model.errorMessage)
        let after = await service.requests
        XCTAssertEqual(after, [request, request])
    }

    func testLoadingAppearsImmediatelyAndSecondActionDoesNotStartAnotherRead() async throws {
        let gate = SavedHistoryGate()
        let result = savedHistorySummary("Saved result")
        let service = SavedHistoryTestService(replies: [.init(summary: result, gate: gate)])
        let model = SavedOutcomeHistoryModel(service: service)
        let request = try savedHistoryRequest(1)
        model.activateScope(request)
        try await whileReadIsPaused(model, gate: gate) { _ in
            XCTAssertTrue(model.isLoading)
            XCTAssertTrue(model.hasRequested)
            XCTAssertFalse(model.canLoad)
            XCTAssertNil(model.summary)
            await model.load()
            let calls = await service.requests
            XCTAssertEqual(calls, [request])
        }
        XCTAssertEqual(model.summary, result)
        XCTAssertFalse(model.isLoading)
    }

    func testLateDifferentScopeResultCannotReplaceCurrentRead() async throws {
        let gate = SavedHistoryGate()
        let current = savedHistorySummary("Current conversation result")
        let service = SavedHistoryTestService(replies: [.init(summary: savedHistorySummary("Old conversation result"), gate: gate), .init(summary: current)])
        let model = SavedOutcomeHistoryModel(service: service)
        let first = try savedHistoryRequest(1), second = try savedHistoryRequest(2)
        model.activateScope(first)
        try await whileReadIsPaused(model, gate: gate) { _ in
            model.activateScope(second)
            XCTAssertFalse(model.hasRequested)
            XCTAssertFalse(model.isLoading)
            await model.load()
            XCTAssertEqual(model.summary, current)
        }
        XCTAssertEqual(model.request, second)
        XCTAssertEqual(model.summary, current)
        XCTAssertNil(model.errorMessage)
        let calls = await service.requests
        let cancelled = await service.cancelledResponses
        XCTAssertEqual(calls, [first, second])
        XCTAssertEqual(cancelled, 1)
    }

    func testDismissThenSameScopeReloadRejectsOlderGeneration() async throws {
        let gate = SavedHistoryGate()
        let new = savedHistorySummary("New same-scope result")
        let service = SavedHistoryTestService(replies: [.init(summary: savedHistorySummary("Old same-scope result"), gate: gate), .init(summary: new)])
        let model = SavedOutcomeHistoryModel(service: service)
        let request = try savedHistoryRequest(1)
        model.activateScope(request)
        try await whileReadIsPaused(model, gate: gate) { _ in
            model.dismiss()
            model.activateScope(request)
            XCTAssertNil(model.summary)
            XCTAssertFalse(model.hasRequested)
            await model.load()
            XCTAssertEqual(model.summary, new)
        }
        XCTAssertEqual(model.summary, new)
        XCTAssertFalse(model.isLoading)
        let calls = await service.requests
        XCTAssertEqual(calls, [request, request])
    }

    func testLateErrorAfterScopeSwitchCannotPolluteCurrentConversation() async throws {
        let gate = SavedHistoryGate()
        let current = savedHistorySummary("Current result")
        let service = SavedHistoryTestService(replies: [.init(summary: current, gate: gate, failure: true), .init(summary: current)])
        let model = SavedOutcomeHistoryModel(service: service)
        model.activateScope(try savedHistoryRequest(1))
        let second = try savedHistoryRequest(2)
        try await whileReadIsPaused(model, gate: gate) { _ in
            model.activateScope(second)
            await model.load()
        }
        XCTAssertEqual(model.summary, current)
        XCTAssertNil(model.errorMessage)
    }

    func testCancellingCallerRejectsNoncooperativeCompletionAndAllowsLaterExplicitRead() async throws {
        let gate = SavedHistoryGate()
        let service = SavedHistoryTestService(replies: [.init(summary: savedHistorySummary("Late result"), gate: gate)])
        let model = SavedOutcomeHistoryModel(service: service)
        model.activateScope(try savedHistoryRequest(1))
        try await whileReadIsPaused(model, gate: gate) { task in task.cancel() }
        XCTAssertNil(model.summary)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasRequested)
        XCTAssertTrue(model.canLoad)
        let cancelled = await service.cancelledResponses
        XCTAssertEqual(cancelled, 1)
    }

    func testAlreadyCancelledLoadDoesNotReachService() async throws {
        let service = SavedHistoryTestService()
        let model = SavedOutcomeHistoryModel(service: service)
        model.activateScope(try savedHistoryRequest(1))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load()
        }
        await task.value
        XCTAssertFalse(model.hasRequested)
        XCTAssertFalse(model.isLoading)
        let calls = await service.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testShutdownPermanentlyBlocksReactivationAndDropsLateRead() async throws {
        let gate = SavedHistoryGate()
        let service = SavedHistoryTestService(replies: [.init(summary: savedHistorySummary("Late result"), gate: gate)])
        let model = SavedOutcomeHistoryModel(service: service)
        let first = try savedHistoryRequest(1), second = try savedHistoryRequest(2)
        model.activateScope(first)
        try await whileReadIsPaused(model, gate: gate) { _ in
            model.beginShutdown()
            model.beginShutdown()
            model.dismiss()
            model.activateScope(second)
            await model.load()
            XCTAssertTrue(model.isClosing)
            XCTAssertNil(model.request)
            XCTAssertFalse(model.canLoad)
        }
        XCTAssertNil(model.summary)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.hasRequested)
        let calls = await service.requests
        XCTAssertEqual(calls, [first])
    }

    func testExactScopeIncludesLimitAndChangingItDoesNotReadAutomatically() async throws {
        let service = SavedHistoryTestService()
        let model = SavedOutcomeHistoryModel(service: service)
        let first = try savedHistoryRequest(1)
        model.activateScope(first)
        await model.load()
        let smaller = try ConversationOutcomeHistoryRequest(conversationID: first.conversationID, teammateID: first.teammateID, limit: 1)
        model.activateScope(smaller)
        XCTAssertEqual(model.request, smaller)
        XCTAssertNil(model.summary)
        XCTAssertFalse(model.hasRequested)
        let calls = await service.requests
        XCTAssertEqual(calls, [first])
    }

    func testViewBoundRejectsOversizedSummaryWithoutTruncatingOrShowingIt() async throws {
        let item = SavedOutcomeSummary(reference: .run(RunID(UUID())), recordedAt: Date(), text: "Saved fact")
        let summary = ConversationOutcomeHistorySummary(scope: .available, outcomes: [item, item], hasMore: false, notice: "Too many results")
        let service = SavedHistoryTestService(replies: [.init(summary: summary)])
        let model = SavedOutcomeHistoryModel(service: service)
        let request = try savedHistoryRequest(1, limit: 1)
        model.activateScope(request)
        await model.load()
        XCTAssertNil(model.summary)
        XCTAssertNotNil(model.errorMessage)
        let calls = await service.requests
        XCTAssertEqual(calls, [request])
    }

    func testViewOnlyLoadsFromExplicitActionsAndNeverPrintsTechnicalReferences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/SavedOutcomeHistoryView.swift"), encoding: .utf8)
        for label in ["Saved outcomes", "Show Saved Outcomes", "Retry Saved Outcomes", "Refresh", "Hide"] {
            XCTAssertTrue(source.contains("\"\(label)\""))
        }
        XCTAssertTrue(source.contains(".onDisappear { model.dismiss() }"))
        XCTAssertTrue(source.contains("Text(outcome.text)"))
        XCTAssertTrue(source.contains("Text(outcome.recordedAt, style: .date)"))
        for forbidden in [".task", ".onAppear", "Timer", "ProgressView", ".uuidString", ".rawValue", "TextEditor", "TextField", "Button(\"Start", "Button(\"Recover", "Button(\"Approve"] {
            XCTAssertFalse(source.contains(forbidden))
        }
    }

    private func whileReadIsPaused(_ model: SavedOutcomeHistoryModel, gate: SavedHistoryGate,
                                  body: @MainActor (Task<Void, Never>) async throws -> Void) async throws {
        let task = Task { await model.load() }
        do {
            try await waitForArrival(gate)
            try await body(task)
            await gate.release()
            await task.value
        } catch {
            task.cancel()
            await gate.release()
            await task.value
            throw error
        }
    }

    private func waitForArrival(_ gate: SavedHistoryGate) async throws {
        let arrival = await gate.arrival
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in arrival { return }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw SavedHistoryTestTimeout()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private struct SavedHistoryReply: Sendable {
    let summary: ConversationOutcomeHistorySummary
    var gate: SavedHistoryGate? = nil
    var failure = false
}

private actor SavedHistoryTestService: ConversationOutcomeHistoryServing {
    private var replies: [SavedHistoryReply]
    private(set) var requests: [ConversationOutcomeHistoryRequest] = []
    private(set) var cancelledResponses = 0
    init(replies: [SavedHistoryReply] = []) { self.replies = replies }

    func history(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistorySummary {
        requests.append(request)
        let reply = replies.isEmpty ? SavedHistoryReply(summary: savedHistorySummary("Saved result")) : replies.removeFirst()
        await reply.gate?.pause()
        if Task.isCancelled { cancelledResponses += 1 }
        // Intentionally noncooperative: model fencing must reject late results
        // and private failures even when the dependency ignores cancellation.
        if reply.failure { throw SavedHistoryPrivateFailure() }
        return reply.summary
    }
}

private actor SavedHistoryGate {
    let arrival: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        arrival = stream.stream
        signal = stream.continuation
    }
    func pause() async {
        signal.yield(())
        signal.finish()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private struct SavedHistoryTestTimeout: Error {}
private struct SavedHistoryPrivateFailure: LocalizedError {
    var errorDescription: String? { "PRIVATE-SENTINEL /Users/private/control.sqlite SELECT secret" }
}
private func savedHistoryRequest(_ value: Int, limit: Int = 20) throws -> ConversationOutcomeHistoryRequest {
    let conversation = UUID(uuidString: String(format: "BC000000-0000-0000-0000-%012d", value))!
    let teammate = UUID(uuidString: String(format: "BC000001-0000-0000-0000-%012d", value))!
    return try .init(conversationID: ConversationID(conversation), teammateID: TeammateID(teammate), limit: limit)
}
private func savedHistorySummary(_ text: String) -> ConversationOutcomeHistorySummary {
    .init(scope: .available, outcomes: [.init(reference: .run(RunID(UUID())), recordedAt: Date(timeIntervalSince1970: 1_000), text: text)],
          hasMore: false, notice: "These are saved records, not a live check of completed work.")
}
