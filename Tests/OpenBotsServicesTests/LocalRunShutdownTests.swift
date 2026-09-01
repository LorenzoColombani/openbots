import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Exact local run shutdown and durable reopen")
struct LocalRunShutdownTests {
    @Test("Shutdown records both issued conversations, preserves receipt meaning and leaves unissued work alone")
    func issuedConversationsSurviveReopen() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 3)
        defer { fixture.remove() }
        weak var closed: SQLiteStore?
        var saved: [RunJournalRecord] = []
        var savedInputs: [[RunInputReceipt]] = []
        var savedEntries: [[RunJournalEntry]] = []
        var unissued: RunJournalRecord!
        do {
            let store = try fixture.open()
            closed = store
            try await fixture.seed(store)
            let service = fixture.service(store)
            let first = try await service.startDemo(conversationID: fixture.chats[0].conversation.id)
            let second = try await service.startDemo(conversationID: fixture.chats[1].conversation.id)
            _ = try await service.acknowledgeDemo(runID: second.id, expectedRevision: second.record.revision)
            // Same owner is insufficient: only IDs issued by this exact service
            // instance may enter its automatic local shutdown batch.
            unissued = try await fixture.running(store, chat: 2)
            fixture.clock.advance(31)
            service.beginShutdown()
            #expect(await service.flushForShutdown())
            service.finishShutdown()
            for id in [first.id, second.id] {
                saved.append(try #require(try await store.run(id: id)))
                savedInputs.append(try await store.runInputs(id: id, limit: 50))
                savedEntries.append(try await store.runEntries(id: id, afterSequence: 0, limit: 100))
            }
            #expect(saved.allSatisfy { $0.state == .interrupted && $0.lease == nil })
            #expect(savedInputs.map { $0.map(\.state) } == [[.outcomeUnknown], [.acknowledged]])
            #expect(savedEntries.allSatisfy { $0.last?.kind == .stateChanged && $0.last?.state == .interrupted })
            #expect(try await store.run(id: unissued.id) == unissued)
        }
        #expect(closed == nil, "The original SQLite connection really closes before reopen")
        let reopened = try fixture.open()
        for (index, record) in saved.enumerated() {
            #expect(try await reopened.run(id: record.id) == record)
            #expect(try await reopened.runInputs(id: record.id, limit: 50) == savedInputs[index])
            #expect(try await reopened.runEntries(id: record.id, afterSequence: 0, limit: 100) == savedEntries[index])
        }
        for chat in fixture.chats {
            #expect(try await reopened.page(conversationID: chat.conversation.id, request: PageRequest(limit: 50)).elements == [chat.user])
        }
        // Reopen does not inherit a process-issued list, even with the same
        // owner UUID supplied by this test. It must not sweep an expired row.
        let freshService = fixture.service(reopened)
        freshService.beginShutdown()
        #expect(await freshService.flushForShutdown())
        freshService.finishShutdown()
        #expect(try await reopened.run(id: unissued.id) == unissued)
    }

    @Test("An exact batch closes queued, expired running and stopping fixtures without claiming a lease")
    func queuedExpiredAndStoppingBatch() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 3)
        defer { fixture.remove() }
        weak var closed: SQLiteStore?
        var saved: [RunJournalRecord] = []
        do {
            let store = try fixture.open()
            closed = store
            try await fixture.seed(store)
            let queued = try await store.enqueueRun(fixture.request(chat: 0), origin: .localFixture)
            let running = try await fixture.running(store, chat: 1)
            let third = try await fixture.running(store, chat: 2)
            let stopping = try await store.transitionRun(id: third.id, expectedRevision: third.revision,
                token: try #require(third.lease).token, event: .requestStop, now: fixture.clock.now())
            fixture.clock.advance(31)
            saved = try await store.interruptOwnedLocalFixtures(ids: [queued.id, running.id, stopping.id],
                ownerID: fixture.owner, now: fixture.clock.now())
            #expect(saved.map(\.id) == [queued.id, running.id, stopping.id])
            #expect(saved.map(\.revision) == [queued.revision + 1, running.revision + 1, stopping.revision + 1])
            #expect(saved.allSatisfy { $0.state == .interrupted && $0.lease == nil })
            #expect(try await store.runInputs(id: queued.id, limit: 50).map(\.state) == [.queued])
            #expect(try await store.runInputs(id: running.id, limit: 50).map(\.state) == [.outcomeUnknown])
            #expect(try await store.runInputs(id: stopping.id, limit: 50).map(\.state) == [.outcomeUnknown])
            #expect(try await store.runEntries(id: queued.id, afterSequence: 0, limit: 100).map(\.kind) == [.enqueued, .stateChanged])
        }
        #expect(closed == nil)
        let reopened = try fixture.open()
        for record in saved { #expect(try await reopened.run(id: record.id) == record) }
        #expect(try await reopened.interruptOwnedLocalFixtures(ids: saved.map(\.id),
            ownerID: fixture.owner, now: fixture.clock.now()).isEmpty)
    }

    @Test("A foreign owner or executor origin rolls back the entire exact batch", arguments: [false, true])
    func foreignBatchRollsBack(executorOrigin: Bool) async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 2)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let first = try await fixture.running(store, chat: 0)
        let foreign = try await fixture.running(store, chat: 1,
            origin: executorOrigin ? .executor : .localFixture,
            owner: executorOrigin ? fixture.owner : UUID())
        let firstInputs = try await store.runInputs(id: first.id, limit: 50)
        let firstEntries = try await store.runEntries(id: first.id, afterSequence: 0, limit: 100)
        let foreignInputs = try await store.runInputs(id: foreign.id, limit: 50)
        let foreignEntries = try await store.runEntries(id: foreign.id, afterSequence: 0, limit: 100)
        let expected: RunJournalError = executorOrigin ? .invalidRequest : .leaseUnavailable
        await #expect(throws: expected) {
            try await store.interruptOwnedLocalFixtures(ids: [first.id, foreign.id],
                ownerID: fixture.owner, now: fixture.clock.now().addingTimeInterval(1))
        }
        // The first row was eligible and visited first. Its input-state and
        // event update must roll back along with its main run record.
        #expect(try await store.run(id: first.id) == first)
        #expect(try await store.runInputs(id: first.id, limit: 50) == firstInputs)
        #expect(try await store.runEntries(id: first.id, afterSequence: 0, limit: 100) == firstEntries)
        #expect(try await store.run(id: foreign.id) == foreign)
        #expect(try await store.runInputs(id: foreign.id, limit: 50) == foreignInputs)
        #expect(try await store.runEntries(id: foreign.id, afterSequence: 0, limit: 100) == foreignEntries)
    }

    @Test("Terminal local records remain byte-for-byte unchanged and no extra event is appended")
    func terminalRecordsUnchanged() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 2)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let started = try await service.startDemo(conversationID: fixture.chats[0].conversation.id)
        let acknowledged = try await service.acknowledgeDemo(runID: started.id, expectedRevision: started.record.revision)
        let finished = try await service.finishDemo(runID: started.id, expectedRevision: acknowledged.record.revision)
        let active = try await service.startDemo(conversationID: fixture.chats[1].conversation.id)
        service.beginShutdown()
        #expect(await service.flushForShutdown())
        service.finishShutdown()
        #expect(try await store.run(id: finished.id) == finished.record)
        #expect(try await store.runInputs(id: finished.id, limit: 50) == finished.inputs)
        #expect(try await store.runEntries(id: finished.id, afterSequence: 0, limit: 100) == finished.entries)
        let closed = try #require(try await store.run(id: active.id))
        #expect(closed.state == .interrupted)
        #expect(try await store.interruptOwnedLocalFixtures(ids: [finished.id, closed.id],
            ownerID: UUID(), now: fixture.clock.now().addingTimeInterval(1)).isEmpty)
        #expect(try await store.run(id: finished.id) == finished.record)
        #expect(try await store.run(id: closed.id) == closed)
    }

    @Test("Cancellation and invalid exact scopes cause no shutdown mutation")
    func cancellationAndScopeBounds() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 1)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let record = try await fixture.running(store, chat: 0)
        let inputs = try await store.runInputs(id: record.id, limit: 50)
        let entries = try await store.runEntries(id: record.id, afterSequence: 0, limit: 100)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.interruptOwnedLocalFixtures(ids: [record.id], ownerID: fixture.owner, now: fixture.clock.now())
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await cancelled.value)
        await #expect(throws: RunJournalError.invalidLimit) {
            try await store.interruptOwnedLocalFixtures(ids: [record.id, record.id], ownerID: fixture.owner, now: fixture.clock.now())
        }
        await #expect(throws: RunJournalError.invalidLimit) {
            try await store.interruptOwnedLocalFixtures(ids: (0..<257).map { _ in RunID(UUID()) },
                ownerID: fixture.owner, now: fixture.clock.now())
        }
        #expect(try await store.run(id: record.id) == record)
        #expect(try await store.runInputs(id: record.id, limit: 50) == inputs)
        #expect(try await store.runEntries(id: record.id, afterSequence: 0, limit: 100) == entries)
    }

    @Test("The synchronous service fence refuses every new local demo action before a repository mutation")
    func serviceAdmissionFreeze() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 1)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let current = try await service.startDemo(conversationID: fixture.chats[0].conversation.id)
        service.beginShutdown()
        await #expect(throws: CancellationError.self) { try await service.startDemo(conversationID: fixture.chats[0].conversation.id) }
        await #expect(throws: CancellationError.self) { try await service.acknowledgeDemo(runID: current.id, expectedRevision: current.record.revision) }
        await #expect(throws: CancellationError.self) { try await service.finishDemo(runID: current.id, expectedRevision: current.record.revision) }
        await #expect(throws: CancellationError.self) { try await service.requestStopDemo(runID: current.id, expectedRevision: current.record.revision) }
        await #expect(throws: CancellationError.self) { try await service.interruptDemo(runID: current.id, expectedRevision: current.record.revision) }
        await #expect(throws: CancellationError.self) { try await service.failDemo(runID: current.id, expectedRevision: current.record.revision) }
        await #expect(throws: CancellationError.self) { try await service.recoverExpiredDemos(conversationID: fixture.chats[0].conversation.id) }
        #expect(try await store.run(id: current.id) == current.record)
        #expect(try await store.runInputs(id: current.id, limit: 50) == current.inputs)
        #expect(try await store.runEntries(id: current.id, afterSequence: 0, limit: 100) == current.entries)
        service.finishShutdown()
        #expect(await service.flushForShutdown() == false)
        #expect(try await store.run(id: current.id) == current.record)
    }

    @Test("A queued partial start issued by the service can be interrupted without claim or replay")
    func queuedPartialStartIsTracked() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 1)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let adapter = LocalRunShutdownJournal(store, rejectClaim: true)
        let service = fixture.service(store, journal: adapter)
        do {
            _ = try await service.startDemo(conversationID: fixture.chats[0].conversation.id)
            Issue.record("Injected claim failure must leave a typed partial start")
        } catch let error as RunRecoveryFixtureError {
            guard case .partialStart = error else { throw error }
        }
        let queued = try #require(try await store.runs(conversationID: fixture.chats[0].conversation.id, limit: 10).first)
        #expect(queued.state == .queued && queued.lease == nil)
        service.beginShutdown()
        #expect(await service.flushForShutdown())
        service.finishShutdown()
        let interrupted = try #require(try await store.run(id: queued.id))
        #expect(interrupted.state == .interrupted && interrupted.lease == nil)
        #expect(try await store.runInputs(id: queued.id, limit: 50).map(\.state) == [.queued])
        #expect(try await store.runEntries(id: queued.id, afterSequence: 0, limit: 100).map(\.kind) == [.enqueued, .stateChanged])
        #expect(await adapter.claimCalls == 1)
        #expect(await adapter.shutdownCalls == 1)
    }

    @Test("Grace drains an already admitted enqueue without starting its later claim or submission")
    func graceDrainsAdmittedStart() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 1)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let gate = LocalRunShutdownGate()
        let adapter = LocalRunShutdownJournal(store, enqueueGate: gate)
        let service = fixture.service(store, journal: adapter)
        let starting = Task { () -> Result<RunRecoveryReview, Error> in
            do { return .success(try await service.startDemo(conversationID: fixture.chats[0].conversation.id)) }
            catch { return .failure(error) }
        }
        try await waitForGate(gate)
        let queued = try #require(try await store.runs(conversationID: fixture.chats[0].conversation.id, limit: 10).first)
        service.beginShutdown()
        let flushing = Task { await service.flushForShutdown() }
        await gate.release()
        switch await starting.value {
        case .success: Issue.record("Admission closed before claim: the durable start must stay partial")
        case .failure(let error):
            #expect(error as? RunRecoveryFixtureError == .partialStart(runID: queued.id))
        }
        #expect(await flushing.value)
        service.finishShutdown()
        #expect(try await store.run(id: queued.id)?.state == .interrupted)
        #expect(try await store.runInputs(id: queued.id, limit: 50).map(\.state) == [.queued])
        #expect(await adapter.claimCalls == 0)
        #expect(await adapter.shutdownCalls == 1)
    }

    @Test("Terminal shutdown during suspended enqueue forbids late claim, submission or automatic recovery")
    func terminalFenceStopsLateStartFollowups() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 1)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let gate = LocalRunShutdownGate()
        let adapter = LocalRunShutdownJournal(store, enqueueGate: gate)
        let service = fixture.service(store, journal: adapter)
        let starting = Task { () -> Result<RunRecoveryReview, Error> in
            do { return .success(try await service.startDemo(conversationID: fixture.chats[0].conversation.id)) }
            catch { return .failure(error) }
        }
        try await waitForGate(gate)
        let queued = try #require(try await store.runs(conversationID: fixture.chats[0].conversation.id, limit: 10).first)
        service.beginShutdown()
        let flushing = Task { await service.flushForShutdown() }
        service.finishShutdown()
        #expect(await flushing.value == false)
        await gate.release()
        switch await starting.value {
        case .success: Issue.record("A completed terminal fence must not allow the suspended start to continue")
        case .failure(let error):
            #expect(error as? RunRecoveryFixtureError == .partialStart(runID: queued.id))
        }
        #expect(await adapter.claimCalls == 0)
        #expect(await adapter.shutdownCalls == 0)
        #expect(try await store.run(id: queued.id) == queued)
        #expect(try await store.runInputs(id: queued.id, limit: 50).map(\.state) == [.queued])
        #expect(try await store.runEntries(id: queued.id, afterSequence: 0, limit: 100).map(\.kind) == [.enqueued])
    }

    @Test("A rejected generated-ID collision never gives shutdown ownership of another queued run")
    func rejectedCollisionDoesNotAdoptQueuedRun() async throws {
        let fixture = try LocalRunShutdownFixture(chatCount: 2)
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let preexisting = try await store.enqueueRun(fixture.request(chat: 0), origin: .localFixture)
        let entries = try await store.runEntries(id: preexisting.id, afterSequence: 0, limit: 100)
        let inputs = try await store.runInputs(id: preexisting.id, limit: 50)
        let service = fixture.service(store, uuidGenerator: LocalRunFixedUUID(value: preexisting.id.rawValue))
        await #expect(throws: RunJournalError.invalidRequest) {
            try await service.startDemo(conversationID: fixture.chats[1].conversation.id)
        }
        service.beginShutdown()
        #expect(await service.flushForShutdown())
        service.finishShutdown()
        #expect(try await store.run(id: preexisting.id) == preexisting)
        #expect(try await store.runInputs(id: preexisting.id, limit: 50) == inputs)
        #expect(try await store.runEntries(id: preexisting.id, afterSequence: 0, limit: 100) == entries)
        #expect(try await store.runs(conversationID: fixture.chats[1].conversation.id, limit: 10).isEmpty)
    }

    private func waitForGate(_ gate: LocalRunShutdownGate) async throws {
        for _ in 0..<2_000 {
            if await gate.isWaiting { return }
            await Task.yield()
        }
        throw LocalRunShutdownTestError.gateNotReached
    }
}

private enum LocalRunShutdownTestError: Error { case gateNotReached }

private struct LocalRunShutdownChat: Sendable {
    let teammate: Teammate
    let conversation: Conversation
    let user: Message
    init(index: Int) throws {
        let date = Date(timeIntervalSince1970: 1_000)
        teammate = try Teammate(id: TeammateID(UUID()), profile: .init(displayName: "Local \(index)", role: "Research", revision: 1),
            appearance: .init(mode: .creature, grammarVersion: 1, deterministicSeed: UInt64(index + 1), silhouette: "round",
                paletteToken: "mint", eyeDialect: "round", nonColorIdentityCue: "antenna", accessibleIdentityDescription: "Antenna creature"),
            createdAt: date, updatedAt: date)
        conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id), createdAt: date, updatedAt: date)
        user = try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1, author: .user,
            deliveryState: .completed, parts: [.init(id: MessagePartID(UUID()), ordinal: 0, content: .text("Saved request \(index)"))],
            createdAt: date, updatedAt: date)
    }
}

private struct LocalRunShutdownFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let chats: [LocalRunShutdownChat]
    let owner = UUID()
    let clock = LocalRunShutdownClock()
    init(chatCount: Int) throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextLocalShutdown-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        chats = try (0..<chatCount).map(LocalRunShutdownChat.init)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: .init(fileURL: directory.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore) async throws {
        for chat in chats {
            try await store.provisionDirectChat(teammate: chat.teammate, conversation: chat.conversation, fixtureGreeting: nil, selectConversation: false)
            try await store.append(chat.user, expectedPreviousSequence: 0)
        }
    }
    func service(_ store: SQLiteStore, journal: (any RunJournalRepository)? = nil,
                 uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()) -> RunRecoveryFixtureService {
        .init(journalRepository: journal ?? store, teammateRepository: store, conversationRepository: store,
              messageRepository: store, contextRepository: store, ownerID: owner, clock: clock, uuidGenerator: uuidGenerator)
    }
    func request(chat index: Int) throws -> WorkRequest {
        let chat = chats[index]
        return try WorkRequest(runID: RunID(UUID()), teammateID: chat.teammate.id, conversationID: chat.conversation.id,
            initiatingMessageID: chat.user.id, profileRevision: chat.teammate.profile.revision,
            initialInput: .init(messageID: chat.user.id, sequence: 1, text: "Saved request \(index)"), submittedAt: clock.now())
    }
    func running(_ store: SQLiteStore, chat: Int, origin: RunOrigin = .localFixture, owner: UUID? = nil) async throws -> RunJournalRecord {
        let queued = try await store.enqueueRun(request(chat: chat), origin: origin)
        let token = UUID()
        let claimed = try await store.claimRun(id: queued.id, expectedRevision: queued.revision, ownerID: owner ?? self.owner,
            token: token, now: clock.now(), leaseDuration: 30)
        let started = try await store.transitionRun(id: queued.id, expectedRevision: claimed.revision, token: token, event: .started, now: clock.now())
        return try await store.markRunInput(id: queued.id, expectedRevision: started.revision, token: token,
            messageID: queued.request.initiatingMessageID, sequence: 1, state: .submitted, now: clock.now())
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class LocalRunShutdownClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

private struct LocalRunFixedUUID: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private actor LocalRunShutdownGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Only the single enqueue receipt is delayed. All durable writes and shutdown
/// transactions use the real SQLite repository; no fake state-machine verdict.
private actor LocalRunShutdownJournal: RunJournalRepository {
    let store: SQLiteStore
    let enqueueGate: LocalRunShutdownGate?
    let rejectClaim: Bool
    private(set) var claimCalls = 0
    private(set) var shutdownCalls = 0
    init(_ store: SQLiteStore, enqueueGate: LocalRunShutdownGate? = nil, rejectClaim: Bool = false) {
        self.store = store; self.enqueueGate = enqueueGate; self.rejectClaim = rejectClaim
    }
    func enqueueRun(_ request: WorkRequest, origin: RunOrigin) async throws -> RunJournalRecord {
        let record = try await store.enqueueRun(request, origin: origin)
        await enqueueGate?.wait()
        return record
    }
    func interruptOwnedLocalFixtures(ids: [RunID], ownerID: UUID, now: Date) async throws -> [RunJournalRecord] {
        shutdownCalls += 1
        return try await store.interruptOwnedLocalFixtures(ids: ids, ownerID: ownerID, now: now)
    }
    func claimRun(id: RunID, expectedRevision: Int64, ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval) async throws -> RunJournalRecord {
        claimCalls += 1
        if rejectClaim { throw RunJournalError.unavailable }
        return try await store.claimRun(id: id, expectedRevision: expectedRevision, ownerID: ownerID, token: token, now: now, leaseDuration: leaseDuration)
    }
    func run(id: RunID) async throws -> RunJournalRecord? { try await store.run(id: id) }
    func runs(conversationID: ConversationID, limit: Int) async throws -> [RunJournalRecord] { try await store.runs(conversationID: conversationID, limit: limit) }
    func renewRunLease(id: RunID, expectedRevision: Int64, token: UUID, now: Date, leaseDuration: TimeInterval) async throws -> RunJournalRecord {
        try await store.renewRunLease(id: id, expectedRevision: expectedRevision, token: token, now: now, leaseDuration: leaseDuration)
    }
    func transitionRun(id: RunID, expectedRevision: Int64, token: UUID, event: WorkRunEvent, now: Date) async throws -> RunJournalRecord {
        try await store.transitionRun(id: id, expectedRevision: expectedRevision, token: token, event: event, now: now)
    }
    func failUnclaimedLocalFixture(id: RunID, expectedRevision: Int64, now: Date) async throws -> RunJournalRecord {
        try await store.failUnclaimedLocalFixture(id: id, expectedRevision: expectedRevision, now: now)
    }
    func queueRunInput(id: RunID, expectedRevision: Int64, token: UUID, input: SteeringInput, now: Date) async throws -> RunJournalRecord {
        try await store.queueRunInput(id: id, expectedRevision: expectedRevision, token: token, input: input, now: now)
    }
    func markRunInput(id: RunID, expectedRevision: Int64, token: UUID, messageID: MessageID, sequence: Int64, state: RunInputState, now: Date) async throws -> RunJournalRecord {
        try await store.markRunInput(id: id, expectedRevision: expectedRevision, token: token, messageID: messageID, sequence: sequence, state: state, now: now)
    }
    func runInputs(id: RunID, limit: Int) async throws -> [RunInputReceipt] { try await store.runInputs(id: id, limit: limit) }
    func runEntries(id: RunID, afterSequence: Int64, limit: Int) async throws -> [RunJournalEntry] {
        try await store.runEntries(id: id, afterSequence: afterSequence, limit: limit)
    }
    func recoverExpiredLocalFixtures(conversationID: ConversationID, now: Date, limit: Int) async throws -> [RunJournalRecord] {
        try await store.recoverExpiredLocalFixtures(conversationID: conversationID, now: now, limit: limit)
    }
}
