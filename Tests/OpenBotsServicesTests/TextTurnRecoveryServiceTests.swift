import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsServices
import Testing

@Suite("Text-turn recovery without process or provider operations")
struct TextTurnRecoveryServiceTests {
    @Test("An expired lease, a different process owner and absent legacy session metadata prove nothing",
          arguments: [false, true])
    func defaultPreservesOrphan(hasSession: Bool) async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: hasSession, partial: "Preserved unassessed partial.")
        let before = try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements
        let probe = RecoveryRepositoryProbe(store)
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner, clock: { f.at(120) })

        let report = await service.recover()

        #expect(report.status == .completed && report.interruptedCount == 0)
        #expect(report.entries.map(\.disposition) == [.absenceUnproven])
        #expect(report.needsAttention && report.notice?.contains("nothing has been resent") == true)
        #expect(await probe.calls == ["pending"])
        #expect(try await f.open().pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [pending])
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements == before)
    }

    @Test("Actual scoped absence interrupts once, retaining submitted partial bytes across reopen")
    func provenAbsencePreservesPartial() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let partial = "Unassessed partial: e\u{301}\nline two."
        let pending = try await f.seedPending(store, hasSession: true, partial: partial)
        let probe = RecoveryRepositoryProbe(store)
        let proof = RecoveryAbsenceProbe(.matching)
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner,
            absenceProver: proof, clock: { f.at(120) })

        let report = await service.recover()

        #expect(report.status == .completed && report.interruptedCount == 1 && !report.needsAttention)
        #expect(await probe.calls == ["pending", "interrupt"])
        let candidate = try #require(await proof.candidates.first)
        #expect(candidate.sessionID == f.session && candidate.leaseOwnerID == f.processOwner)
        #expect(candidate.runID == pending.run.id && candidate.revision == pending.run.revision)
        #expect(candidate.appOwnerID == f.appOwner && candidate.teammateID == f.bot && candidate.conversationID == f.chat)
        let reopened = try f.open()
        let saved = try #require(try await reopened.run(id: pending.run.id))
        #expect(saved.state == .interrupted && saved.lease == nil)
        let rows = try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements
        #expect(rows.count == 2)
        #expect(rows[0].deliveryState == .failed && rows[1].deliveryState == .outcomeUnknown)
        #expect(try await reopened.runInputs(id: pending.run.id, limit: 10).first?.state == .outcomeUnknown)
        guard case let .text(savedPartial) = rows[1].parts[0].content else {
            Issue.record("Recovery replaced real partial text."); return
        }
        #expect(savedPartial.utf8.elementsEqual(partial.utf8))
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        let again = await service.recover()
        #expect(again.entries.isEmpty && again.interruptedCount == 0)
        #expect(await proof.candidates.count == 1)
        #expect(try await reopened.runs(conversationID: f.chat, limit: 10).count == 1)
    }

    @Test("An unpublished waiting turn becomes interrupted, never an invented reply or replay")
    func provenAbsenceOfUnpublishedTurn() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: true, partial: nil)
        let probe = RecoveryRepositoryProbe(store)
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner,
            absenceProver: RecoveryAbsenceProbe(.matching), clock: { f.at(120) })
        let report = await service.recover()
        #expect(report.interruptedCount == 1)
        let replyID = try #require(pending.run.request.textTurnIdentity).replyMessageID
        let reply = try #require(try await f.open().message(id: replyID))
        #expect(reply.parts.count == 1)
        guard case let .status(text) = reply.parts[0].content else {
            Issue.record("Recovery manufactured a reply."); return
        }
        #expect(!text.contains("Waiting") && !text.contains("Claude response"))
        #expect(await probe.calls == ["pending", "interrupt"])
    }

    @Test("A mismatched absence assertion never reaches the persistence operation",
          arguments: [false, true])
    func mismatchedProof(wrongRun: Bool) async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: true, partial: "Existing partial.")
        let probe = RecoveryRepositoryProbe(store)
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner,
            absenceProver: RecoveryAbsenceProbe(wrongRun ? .wrongRun : .wrongOwner), clock: { f.at(120) })
        let report = await service.recover()
        #expect(report.entries.map(\.disposition) == [.absenceUnproven])
        #expect(await probe.calls == ["pending"])
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [pending])
    }

    @Test("A live checkpoint racing absence checking wins its revision; recovery never retries")
    func staleRevisionPreservesNewerWork() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: true, partial: "Before.")
        let probe = RecoveryRepositoryProbe(store)
        let proof = RecoveryAbsenceProbe(.matching) { _ in
            _ = try await store.checkpointTextTurn(id: pending.run.id, expectedRevision: pending.run.revision,
                token: f.token, text: "Before. More saved text.", inputEvidence: .none, now: f.at(2))
        }
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner,
            absenceProver: proof, clock: { f.at(120) })
        let report = await service.recover()
        #expect(report.entries.map(\.disposition) == [.changed] && report.needsAttention)
        #expect(await probe.calls == ["pending", "interrupt"])
        let current = try #require(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).first)
        #expect(current.run.state == .running && current.run.revision > pending.run.revision)
        #expect(current.replyText == "Before. More saved text.")
    }

    @Test("Proof/read failures remain unresolved without touching saved rows")
    func failuresNeverGrantAbsence() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: false, partial: nil)
        let proof = RecoveryAbsenceProbe(.failure)
        let probe = RecoveryRepositoryProbe(store)
        let report = await TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner,
            absenceProver: proof, clock: { f.at(120) }).recover()
        #expect(report.entries.map(\.disposition) == [.unavailable] && report.needsAttention)
        #expect(await proof.candidates.first?.sessionID == nil)
        #expect(await probe.calls == ["pending"])
        let failedRead = RecoveryRepositoryProbe(store, failRead: true)
        let readReport = await TextTurnRecoveryService(repository: failedRead, appOwnerID: f.appOwner,
            absenceProver: proof).recover()
        #expect(readReport.status == .unavailable && readReport.needsAttention)
        #expect(await proof.candidates.count == 1)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [pending])
    }

    @Test("Only one bounded batch is checked; duplicate or foreign rows fail closed")
    func boundedBatchAndScope() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let rows = try (0..<3).map { _ in try f.syntheticPending() }
        let probe = RecoveryRepositoryProbe(store, returnedRows: rows)
        let proof = RecoveryAbsenceProbe(.unproven)
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner, absenceProver: proof)
        let report = await service.recover(limit: 2)
        #expect(report.entries.count == 2 && report.hasMore && report.needsAttention)
        #expect(await probe.limits == [3])
        #expect(await proof.candidates.count == 2)
        for malformed in [[rows[0], rows[0]], [try f.syntheticPending(appOwner: UUID())]] {
            let invalid = RecoveryRepositoryProbe(store, returnedRows: malformed)
            let rejected = await TextTurnRecoveryService(repository: invalid, appOwnerID: f.appOwner,
                absenceProver: proof).recover(limit: 2)
            #expect(rejected.status == .unavailable && rejected.entries.isEmpty)
        }
        let invalidLimit = await service.recover(limit: 26)
        #expect(invalidLimit.status == .unavailable)
        #expect(await probe.calls == ["pending"])
        #expect(await proof.candidates.count == 2)
    }

    @Test("Cancellation during proof and overlapping recovery cannot terminalize a waiting turn",
          .timeLimit(.minutes(1)))
    func cancellationAndOverlap() async throws {
        let f = try TextRecoveryFixture(); defer { f.remove() }
        let store = try f.open()
        let pending = try await f.seedPending(store, hasSession: true, partial: nil)
        let probe = RecoveryRepositoryProbe(store)
        let proof = RecoveryAbsenceProbe(.held)
        let service = TextTurnRecoveryService(repository: probe, appOwnerID: f.appOwner,
            absenceProver: proof, clock: { f.at(120) })
        let task = Task { await service.recover() }
        await proof.waitUntilHeld()
        let overlap = await service.recover()
        #expect(overlap.status == .inProgress && overlap.needsAttention)
        task.cancel()
        await proof.release()
        let report = await task.value
        #expect(report.status == .cancelled && report.interruptedCount == 0 && report.needsAttention)
        #expect(await probe.calls == ["pending"])
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [pending])
    }
}

private enum RecoveryFixtureError: Error { case unavailable, forbiddenCall }

private actor RecoveryAbsenceProbe: TextTurnProcessAbsenceProving {
    enum Mode: Equatable, Sendable { case matching, unproven, wrongRun, wrongOwner, failure, held }
    let mode: Mode
    let beforeProof: @Sendable (TextTurnRecoveryCandidate) async throws -> Void
    private(set) var candidates: [TextTurnRecoveryCandidate] = []
    private var held = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(_ mode: Mode, beforeProof: @escaping @Sendable (TextTurnRecoveryCandidate) async throws -> Void = { _ in }) {
        self.mode = mode; self.beforeProof = beforeProof
    }
    func withVerifiedAbsence(for candidate: TextTurnRecoveryCandidate,
        operation: @escaping @Sendable (TextTurnProcessAbsence) async throws -> TextTurnSnapshot)
        async throws -> TextTurnSnapshot? {
        candidates.append(candidate)
        if case .held = mode {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation; held = true
                entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            }
        }
        if case .failure = mode { throw RecoveryFixtureError.unavailable }
        if case .unproven = mode { return nil }
        try await beforeProof(candidate)
        return try await operation(TextTurnProcessAbsence(
            runID: mode == .wrongRun ? RunID(UUID()) : candidate.runID,
            leaseOwnerID: mode == .wrongOwner ? UUID() : candidate.leaseOwnerID))
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

/// Any replay/live-write method fails the test; recovery gets only read/interrupt.
private actor RecoveryRepositoryProbe: TextTurnRepository {
    let store: SQLiteStore
    let returnedRows: [TextTurnSnapshot]?
    let failRead: Bool
    private(set) var calls: [String] = []
    private(set) var limits: [Int] = []
    init(_ store: SQLiteStore, returnedRows: [TextTurnSnapshot]? = nil, failRead: Bool = false) {
        self.store = store; self.returnedRows = returnedRows; self.failRead = failRead
    }
    func pendingTextTurns(appOwnerID: UUID, limit: Int) async throws -> [TextTurnSnapshot] {
        calls.append("pending"); limits.append(limit)
        if failRead { throw RecoveryFixtureError.unavailable }
        if let returnedRows { return returnedRows }
        return try await store.pendingTextTurns(appOwnerID: appOwnerID, limit: limit)
    }
    func interruptTextTurn(id: RunID, expectedRevision: Int64, appOwnerID: UUID,
        processAbsence: TextTurnProcessAbsence, now: Date) async throws -> TextTurnSnapshot {
        calls.append("interrupt")
        return try await store.interruptTextTurn(id: id, expectedRevision: expectedRevision,
            appOwnerID: appOwnerID, processAbsence: processAbsence, now: now)
    }
    func beginTextTurn(request: WorkRequest, userMessage: Message, expectedPreviousSequence: Int64,
        ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval) async throws -> TextTurnSnapshot {
        calls.append("forbidden begin"); throw RecoveryFixtureError.forbiddenCall
    }
    func checkpointTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
        inputEvidence: TextTurnInputEvidence, now: Date) async throws -> TextTurnSnapshot {
        calls.append("forbidden checkpoint"); throw RecoveryFixtureError.forbiddenCall
    }
    func finishTextTurn(id: RunID, expectedRevision: Int64, token: UUID, text: String,
        outcome: TextTurnOutcome, diagnosticCode: TextTurnDiagnosticCode?, now: Date) async throws -> TextTurnSnapshot {
        calls.append("forbidden finish"); throw RecoveryFixtureError.forbiddenCall
    }
    func textTurnProvenance(conversationID: ConversationID,
        messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        calls.append("forbidden provenance"); throw RecoveryFixtureError.forbiddenCall
    }
}

private struct TextRecoveryFixture: Sendable {
    let root: URL
    let protection: ProtectionDecisionReceipt
    let appOwner = UUID(), processOwner = UUID(), token = UUID(), session = UUID()
    let bot = TeammateID(UUID()), chat = ConversationID(UUID())
    let now = Date(timeIntervalSince1970: 7_000)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextTextRecovery-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func syntheticPending(appOwner: UUID? = nil, hasSession: Bool = true) throws -> TextTurnSnapshot {
        let userID = MessageID(UUID())
        let selection = ClaudeExecutionSelection(model: "sonnet", effort: "default", contextWindow: "default")
        let execution = hasSession ? ClaudeExecutionRequest(sessionID: session,
            selection: selection, launchModel: selection.launchModel) : nil
        let request = try WorkRequest(runID: RunID(UUID()), teammateID: bot, conversationID: chat,
            initiatingMessageID: userID, profileRevision: 1,
            initialInput: WorkInput(messageID: userID, sequence: 1, text: "Synthetic pending question."), submittedAt: now,
            textTurnIdentity: .init(appOwnerID: appOwner ?? self.appOwner,
                replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID()), executionRequest: execution))
        return .init(run: RunJournalRecord(request: request, origin: .executor, state: .starting,
            revision: 2, lease: RunLease(ownerID: processOwner, token: token, generation: 1, expiresAt: at(60)),
            updatedAt: now), replyText: "", inputState: .queued)
    }
    func seedPending(_ store: SQLiteStore, hasSession: Bool, partial: String?) async throws -> TextTurnSnapshot {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Recovery Fixture", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature with a crest"), createdAt: now, updatedAt: now)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: now, updatedAt: now),
            fixtureGreeting: nil, selectConversation: false)
        let request = try syntheticPending(hasSession: hasSession).run.request
        let user = try Message(id: request.initiatingMessageID, conversationID: chat, sequence: 1,
            author: .user, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(request.initialInput.text))],
            createdAt: now, updatedAt: now)
        let begun = try await store.beginTextTurn(request: request, userMessage: user, expectedPreviousSequence: 0,
            ownerID: processOwner, token: token, now: now, leaseDuration: 60)
        guard let partial else { return begun }
        return try await store.checkpointTextTurn(id: begun.run.id, expectedRevision: begun.run.revision,
            token: token, text: partial, inputEvidence: .submitted, now: at(1))
    }
}
