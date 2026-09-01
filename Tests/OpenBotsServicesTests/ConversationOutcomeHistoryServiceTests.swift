import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("Bounded plain-English saved outcome history")
struct ConversationOutcomeHistoryServiceTests {
    @Test("Construction is inert; each query resolves current visibility without a cache or follow-up action")
    func inertAndFreshScope() async throws {
        let request = try historyRequest()
        let repository = OutcomeHistoryRepositoryDouble()
        let service = ConversationOutcomeHistoryService(repository: repository)
        #expect(await repository.requests.isEmpty)
        let empty = try await service.history(request)
        #expect(empty.scope == .available && empty.outcomes.isEmpty && !empty.hasMore)
        #expect(empty.notice == "No saved outcomes were found for this conversation.")
        await repository.setPage(.init(request: request, scope: .unavailable, records: [], hasMore: false))
        let unavailable = try await service.history(request)
        #expect(unavailable.scope == .unavailable && unavailable.outcomes.isEmpty && !unavailable.hasMore)
        #expect(unavailable.notice == "Saved outcomes are unavailable for this conversation.")
        #expect(empty.notice != unavailable.notice)
        #expect(await repository.requests == [request, request])
    }

    @Test("Bounded recent windows preserve structured provenance but expose no IDs in summary text")
    func recentWindowAndProvenance() async throws {
        let request = try historyRequest(limit: 2)
        let records = [
            historyRecord(.run(id: RunID(historyID(1)), origin: .localFixture, state: .interrupted,
                               hasUnconfirmedInput: true, hasUnknownInput: true), at: 2_000.25),
            historyRecord(.proposal(id: ApprovalID(historyID(2)), state: .approved), at: 1_000)
        ]
        let repository = OutcomeHistoryRepositoryDouble(page: .init(request: request, scope: .available, records: records, hasMore: true))
        let result = try await ConversationOutcomeHistoryService(repository: repository).history(request)
        #expect(result.scope == .available && result.hasMore)
        #expect(result.notice == "Showing only the most recent 2 saved outcomes. Earlier records are not included.")
        #expect(result.outcomes.map(\.reference) == records.map { $0.event.reference })
        #expect(result.outcomes.map(\.recordedAt) == records.map(\.updatedAt))
        #expect(result.outcomes[0].text.contains("outcome of some input is unknown"))
        #expect(result.outcomes[0].text.contains("Nothing will be replayed automatically."))
        for outcome in result.outcomes {
            for forbidden in [historyID(1).uuidString.lowercased(), historyID(2).uuidString.lowercased(),
                              historyConversation.persistedValue, historyTeammate.persistedValue,
                              "localFixture", "waitingForUser", "executor", "SELECT", "/Users/", "lease", "fingerprint"] {
                #expect(!outcome.text.contains(forbidden))
                #expect(!result.notice.contains(forbidden))
            }
        }
        #expect(await repository.requests == [request])
    }

    @Test("Every local/demo and executor state is described without claiming independently verified work",
          arguments: [RunOrigin.localFixture, .executor], historyRunStates)
    func runStateDescriptions(origin: RunOrigin, state: WorkRunState) async throws {
        let request = try historyRequest()
        let record = historyRecord(.run(id: RunID(historyID(1)), origin: origin, state: state,
                                       hasUnconfirmedInput: false, hasUnknownInput: false))
        let result = try await summary(request: request, records: [record])
        let text = try #require(result.outcomes.first?.text)
        if origin == .localFixture {
            #expect(text.contains("local demo"))
            #expect(text.contains("demonstration, not real teammate work"))
        } else {
            #expect(text.contains("Work was recorded as"))
            #expect(text.contains("not an independent check of the result"))
            #expect(!text.contains("demo"))
        }
        if state == .succeeded { #expect(text.contains("complete")) }
        else { #expect(!text.contains("complete"), "Input absence or acknowledgment cannot imply completed work.") }
        #expect(!text.contains("acknowledged"))
        #expect(!text.contains(historyID(1).uuidString.lowercased()))
    }

    @Test("Unconfirmed and unknown input remain independent and never authorize replay")
    func uncertaintyDoesNotBecomeCompletion() async throws {
        let request = try historyRequest()
        for unconfirmed in [false, true] {
            for unknown in [false, true] {
                let record = historyRecord(.run(id: RunID(historyID(1)), origin: .executor, state: .running,
                                               hasUnconfirmedInput: unconfirmed, hasUnknownInput: unknown))
                let result = try await summary(request: request, records: [record])
                let text = try #require(result.outcomes.first?.text)
                #expect(text.contains("no confirmed acknowledgment") == unconfirmed)
                #expect(text.contains("outcome of some input is unknown") == unknown)
                #expect(text.contains("Nothing will be replayed automatically.") == (unconfirmed || unknown))
                #expect(!text.contains("complete") && !text.contains("success"))
            }
        }
    }

    @Test("Every proposal decision is a recorded demo review, not a capability or execution receipt",
          arguments: [ActionProposalState.pending, .approved, .denied, .cancelled, .expired])
    func proposalDoesNotAuthorizeExecution(state: ActionProposalState) async throws {
        let request = try historyRequest()
        let result = try await summary(request: request, records: [
            historyRecord(.proposal(id: ApprovalID(historyID(1)), state: state))
        ])
        let text = try #require(result.outcomes.first?.text)
        #expect(text.contains("demo action"))
        #expect(text.contains("recorded review did not grant access or execute the action"))
        if state == .approved { #expect(text.contains("approval was recorded")) }
        #expect(!text.contains(historyID(1).uuidString.lowercased()))
    }

    @Test("Wrong request identity or limit and cross-conversation or teammate records fail closed")
    func exactRequestAndScope() async throws {
        let request = try historyRequest(limit: 2)
        let event = SavedOutcomeEvent.proposal(id: ApprovalID(historyID(1)), state: .pending)
        let mismatches = [
            try ConversationOutcomeHistoryRequest(conversationID: ConversationID(UUID()), teammateID: request.teammateID, limit: request.limit),
            try ConversationOutcomeHistoryRequest(conversationID: request.conversationID, teammateID: TeammateID(UUID()), limit: request.limit),
            try historyRequest(limit: 3)
        ]
        for other in mismatches {
            try await assertInvalid(request, .init(request: other, scope: .available, records: [], hasMore: false))
        }
        for record in [
            SavedOutcomeRecord(conversationID: ConversationID(UUID()), teammateID: request.teammateID,
                               updatedAt: Date(timeIntervalSince1970: 1_000), event: event),
            SavedOutcomeRecord(conversationID: request.conversationID, teammateID: TeammateID(UUID()),
                               updatedAt: Date(timeIntervalSince1970: 1_000), event: event)
        ] {
            try await assertInvalid(request, .init(request: request, scope: .available, records: [record], hasMore: false))
        }
    }

    @Test("Oversized, contradictory has-more and unavailable pages cannot publish even valid-looking rows")
    func pageShapeBounds() async throws {
        let request = try historyRequest(limit: 2)
        let first = historyRecord(.proposal(id: ApprovalID(historyID(1)), state: .pending), at: 3_000)
        let second = historyRecord(.proposal(id: ApprovalID(historyID(2)), state: .denied), at: 2_000)
        let third = historyRecord(.proposal(id: ApprovalID(historyID(3)), state: .expired), at: 1_000)
        for page in [
            ConversationOutcomeHistoryPage(request: request, scope: .available, records: [first, second, third], hasMore: false),
            .init(request: request, scope: .available, records: [first], hasMore: true),
            .init(request: request, scope: .available, records: [], hasMore: true),
            .init(request: request, scope: .unavailable, records: [first], hasMore: false),
            .init(request: request, scope: .unavailable, records: [first, second], hasMore: true),
            .init(request: request, scope: .unavailable, records: [], hasMore: true)
        ] { try await assertInvalid(request, page) }
    }

    @Test("Duplicate references are rejected, while run and proposal UUID namespaces stay separate")
    func referenceNamespaces() async throws {
        let request = try historyRequest(limit: 2)
        let run = historyRecord(.run(id: RunID(historyID(1)), origin: .localFixture, state: .running,
                                    hasUnconfirmedInput: false, hasUnknownInput: false))
        let proposal = historyRecord(.proposal(id: ApprovalID(historyID(1)), state: .approved))
        for record in [run, proposal] {
            try await assertInvalid(request, .init(request: request, scope: .available, records: [record, record], hasMore: false))
        }
        let result = try await summary(request: request, records: [run, proposal])
        #expect(result.outcomes.map(\.reference) == [.run(RunID(historyID(1))), .proposal(ApprovalID(historyID(1)))])
    }

    @Test("Repository ordering is validated by descending time, kind and lexical identity without resorting")
    func deterministicOrdering() async throws {
        let request = try historyRequest(limit: 5)
        let firstRun = historyRecord(.run(id: RunID(historyID(1)), origin: .localFixture, state: .queued,
                                         hasUnconfirmedInput: false, hasUnknownInput: false))
        let secondRun = historyRecord(.run(id: RunID(historyID(2)), origin: .localFixture, state: .queued,
                                          hasUnconfirmedInput: false, hasUnknownInput: false))
        let firstProposal = historyRecord(.proposal(id: ApprovalID(historyID(1)), state: .pending))
        let secondProposal = historyRecord(.proposal(id: ApprovalID(historyID(2)), state: .pending))
        let newest = historyRecord(.proposal(id: ApprovalID(historyID(3)), state: .pending), at: 2_000)
        let expected = [newest, firstRun, secondRun, firstProposal, secondProposal]
        #expect(try await summary(request: request, records: expected).outcomes.map(\.reference) == expected.map { $0.event.reference })
        for reversed in [[firstRun, newest], [firstProposal, firstRun], [secondRun, firstRun], [secondProposal, firstProposal]] {
            try await assertInvalid(request, .init(request: request, scope: .available, records: reversed, hasMore: false))
        }
    }

    @Test("Nonfinite timestamps cannot enter structured provenance", arguments: [Double.nan, .infinity, -.infinity])
    func invalidTimestamp(value: Double) async throws {
        let request = try historyRequest()
        let record = historyRecord(.proposal(id: ApprovalID(historyID(1)), state: .pending), at: value)
        try await assertInvalid(request, .init(request: request, scope: .available, records: [record], hasMore: false))
    }

    @Test("Private repository diagnostics become only a sanitized unavailable error; repository cancellation is preserved")
    func privateErrorsAreNotPublished() async throws {
        let request = try historyRequest()
        let repository = OutcomeHistoryRepositoryDouble(failure: .privateDiagnostic)
        let service = ConversationOutcomeHistoryService(repository: repository)
        await #expect(throws: ConversationOutcomeHistoryError.unavailable) { try await service.history(request) }
        #expect(await repository.requests == [request])
        let cancelled = ConversationOutcomeHistoryService(repository: OutcomeHistoryRepositoryDouble(failure: .cancelled))
        await #expect(throws: CancellationError.self) { try await cancelled.history(request) }
    }

    @Test("Cancellation before query prevents repository access")
    func cancelledBeforeRead() async throws {
        let request = try historyRequest()
        let repository = OutcomeHistoryRepositoryDouble()
        let service = ConversationOutcomeHistoryService(repository: repository)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.history(request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await repository.requests.isEmpty)
    }

    @Test("Noncooperative late results and errors never become a summary after cancellation", arguments: [false, true])
    func cancelledLateRead(privateFailure: Bool) async throws {
        let request = try historyRequest()
        let gate = OutcomeHistoryGate()
        let page = ConversationOutcomeHistoryPage(request: request, scope: .available, records: [
            historyRecord(.run(id: RunID(historyID(1)), origin: .executor, state: .succeeded,
                               hasUnconfirmedInput: false, hasUnknownInput: false))
        ], hasMore: false)
        let repository = OutcomeHistoryRepositoryDouble(page: page, gate: gate,
                                                        failure: privateFailure ? .privateDiagnostic : nil)
        let service = ConversationOutcomeHistoryService(repository: repository)
        let task = Task { try await service.history(request) }
        try await waitForGate(gate, task: task)
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await repository.requests == [request])
    }

    @Test("A missing arrival times out and cancels, releases and joins the child without leaving a waiter")
    func arrivalTimeoutAlwaysCleansUp() async throws {
        let gate = OutcomeHistoryGate()
        // The child deliberately omits its arrival signal. It still suspends
        // on the same releasable gate, making timeout cleanup deterministic.
        let child = Task {
            await gate.wait(signalArrival: false)
            try Task.checkCancellation()
            return ConversationOutcomeHistorySummary(scope: .available, outcomes: [], hasMore: false, notice: "Unused")
        }
        await #expect(throws: OutcomeHistoryTestError.gateNotReached) {
            try await waitForGate(gate, task: child, timeout: .zero)
        }
        #expect(await gate.isReleased)
        #expect(await gate.arrivalWaiterCount == 0)
        #expect(await gate.isWaiting == false)
        await #expect(throws: CancellationError.self) { try await child.value }
    }

    private func summary(request: ConversationOutcomeHistoryRequest, records: [SavedOutcomeRecord]) async throws -> ConversationOutcomeHistorySummary {
        let repository = OutcomeHistoryRepositoryDouble(page: .init(request: request, scope: .available, records: records, hasMore: false))
        return try await ConversationOutcomeHistoryService(repository: repository).history(request)
    }
    private func assertInvalid(_ request: ConversationOutcomeHistoryRequest, _ page: ConversationOutcomeHistoryPage) async throws {
        let repository = OutcomeHistoryRepositoryDouble(page: page)
        let service = ConversationOutcomeHistoryService(repository: repository)
        await #expect(throws: ConversationOutcomeHistoryError.invalidRepositoryResponse) { try await service.history(request) }
        #expect(await repository.requests == [request], "Malformed data must not trigger a second query or recovery attempt.")
    }
    private func waitForGate(_ gate: OutcomeHistoryGate,
                             task: Task<ConversationOutcomeHistorySummary, Error>,
                             timeout: Duration = .seconds(5)) async throws {
        do {
            try await gate.waitForArrival(timeout: timeout)
        } catch {
            // Cleanup runs even when the test never reaches its assertions.
            // This child only awaits the controlled gate/read-only fake, so
            // release makes joining safe without a noncooperative task group.
            task.cancel()
            await gate.release()
            _ = await task.result
            throw error
        }
    }
}

private let historyRunStates: [WorkRunState] = [.queued, .starting, .running, .waitingForUser, .stopping, .succeeded, .failed, .interrupted]
private let historyConversation = ConversationID(historyID(80))
private let historyTeammate = TeammateID(historyID(81))
private func historyID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "BC000000-0000-0000-0000-%012d", suffix))!
}
private func historyRequest(limit: Int = 20) throws -> ConversationOutcomeHistoryRequest {
    try ConversationOutcomeHistoryRequest(conversationID: historyConversation, teammateID: historyTeammate, limit: limit)
}
private func historyRecord(_ event: SavedOutcomeEvent, at seconds: TimeInterval = 1_000) -> SavedOutcomeRecord {
    SavedOutcomeRecord(conversationID: historyConversation, teammateID: historyTeammate,
                       updatedAt: Date(timeIntervalSince1970: seconds), event: event)
}

private enum OutcomeHistoryTestError: Error, Equatable { case gateNotReached }
private enum OutcomeHistoryFailure: Sendable { case privateDiagnostic, cancelled }
private struct PrivateOutcomeHistoryFailure: LocalizedError {
    var errorDescription: String? {
        "PRIVATE-SENTINEL /Users/lorenzo/secret.sqlite SELECT payload FROM action_proposals; credential=do-not-publish"
    }
}

/// Only the read projection protocol is provided; there is no mutation,
/// recovery, replay, authorization, filesystem or executor dependency to call.
private actor OutcomeHistoryRepositoryDouble: ConversationOutcomeHistoryRepository {
    private var page: ConversationOutcomeHistoryPage?
    private let gate: OutcomeHistoryGate?
    private let failure: OutcomeHistoryFailure?
    private(set) var requests: [ConversationOutcomeHistoryRequest] = []
    init(page: ConversationOutcomeHistoryPage? = nil, gate: OutcomeHistoryGate? = nil, failure: OutcomeHistoryFailure? = nil) {
        self.page = page; self.gate = gate; self.failure = failure
    }
    func setPage(_ page: ConversationOutcomeHistoryPage) { self.page = page }
    func outcomeHistory(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistoryPage {
        requests.append(request)
        await gate?.wait()
        switch failure {
        case .privateDiagnostic: throw PrivateOutcomeHistoryFailure()
        case .cancelled: throw CancellationError()
        case nil: return page ?? .init(request: request, scope: .available, records: [], hasMore: false)
        }
    }
}

private actor OutcomeHistoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var arrived = false
    private var arrivalWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var isWaiting: Bool { continuation != nil }
    var isReleased: Bool { released }
    var arrivalWaiterCount: Int { arrivalWaiters.count }

    func wait(signalArrival: Bool = true) async {
        guard !released else { return }
        if signalArrival {
            arrived = true
            let waiters = arrivalWaiters.values
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForArrival(timeout: Duration = .seconds(5)) async throws {
        try Task.checkCancellation()
        if arrived { return }
        guard !released else { throw CancellationError() }
        let id = UUID()
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            await self?.failArrival(id, error: OutcomeHistoryTestError.gateNotReached)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                arrivalWaiters[id] = waiter
            }
        } onCancel: {
            Task { await self.failArrival(id, error: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
        let waiters = arrivalWaiters.values
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    private func failArrival(_ id: UUID, error: any Error) {
        arrivalWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }
}
