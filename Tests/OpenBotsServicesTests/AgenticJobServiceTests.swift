import Foundation
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Native logical job service with real SQLite", .serialized, .timeLimit(.minutes(1)))
struct AgenticJobServiceTests {
    @Test("Only the exact saved same-conversation user text can start a job")
    func savedMessageValidation() async throws {
        let fixture = try JobServiceDatabase()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try await fixture.message(store, text: "Keep caf\u{00e9} rows.")
        let driver = MechanicalJobDriver(), service = fixture.service(store, driver: driver)
        await #expect(throws: AgenticJobError.invalidState) {
            try await service.submit(.init(teammateID: fixture.teammateID, message: message, text: "Keep cafe\u{0301} rows."), progress: { _ in })
        }
        var forged = message
        forged.parts = [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Different saved text"))]
        await #expect(throws: AgenticJobError.invalidState) {
            try await service.submit(.init(teammateID: fixture.teammateID, message: forged, text: "Different saved text"), progress: { _ in })
        }
        await #expect(throws: AgenticJobError.invalidState) {
            try await service.submit(.init(teammateID: TeammateID(UUID()), message: message, text: "Keep caf\u{00e9} rows."), progress: { _ in })
        }
        #expect(try await service.history(conversationID: fixture.conversationID).isEmpty)
        #expect(await driver.runCount == 0)
        await service.shutdown()
    }

    @Test("Correction keeps the logical run, worker and checkpoint; stale approval fails and final reply reopens")
    func preservedJobAndFinalReply() async throws {
        let fixture = try JobServiceDatabase()
        defer { fixture.remove() }
        weak var closed: SQLiteStore?
        var saved: AgenticJobRecord!
        var savedMessages: [Message] = []
        do {
            let store = try fixture.open()
            closed = store
            try await fixture.seed(store)
            let driver = MechanicalJobDriver(), progress = JobProgressLog()
            let service = fixture.service(store, driver: driver)
            let original = try await fixture.message(store, text: "Build the report.")
            let runID = try await service.submit(.init(teammateID: fixture.teammateID, message: original, text: "Build the report."),
                progress: { await progress.append($0) })
            await driver.ready.wait()
            let worker = await driver.worker
            let checkpoint = AgenticJobCheckpoint(id: UUID(), workerID: worker.id,
                reference: "validated-sample", sha256: String(repeating: "a", count: 64))
            try await driver.emit(.checkpoint(checkpoint))
            let oldApproval = AgenticJobApproval(id: UUID(), runID: runID, conversationGeneration: 1,
                title: "Deliver report", detail: "Create one completed fixture report", target: "fixture-output", expiresAt: Date().addingTimeInterval(60))
            try await driver.emit(.approval(oldApproval))
            let correction = try await fixture.message(store, text: "Exclude test rows.")
            let sameRun = try await service.submit(.init(teammateID: fixture.teammateID, message: correction, text: "Exclude test rows."),
                progress: { await progress.append($0) })
            #expect(sameRun == runID)
            #expect(await driver.runCount == 1)
            let current = try #require(try await store.agenticJob(runID: runID))
            #expect(current.state.conversationGeneration == 2)
            #expect(current.state.workers == [worker] && current.state.checkpointReferences == [checkpoint])
            await #expect(throws: AgenticJobError.staleGeneration) { try await service.decide(oldApproval, allow: true) }
            #expect(await driver.decisions.isEmpty)
            let currentApproval = AgenticJobApproval(id: UUID(), runID: runID, conversationGeneration: 2,
                title: "Deliver report", detail: "Exact current decision", target: "fixture-output", expiresAt: Date().addingTimeInterval(60))
            try await driver.emit(.approval(currentApproval))
            // decide emits approvalResolved before returning: the DB gate must be free.
            try await service.decide(currentApproval, allow: true)
            await #expect(throws: AgenticJobError.staleGeneration) { try await service.decide(currentApproval, allow: true) }
            #expect(await driver.decisions == [currentApproval.id])
            // A Task, not `async let`: built with Swift 6.1 on macOS 15, a throwing
            // `async let` that captured the store kept it alive for over ten seconds
            // after this block ended, with the service and driver already gone.
            let concurrentMessage = Task { try await fixture.message(store, text: "Saved while the final reply is finishing.") }
            try await driver.complete("Corrected report: production rows only.")
            _ = try await concurrentMessage.value
            await progress.terminal.wait()
            await service.shutdown()
            saved = try #require(try await store.agenticJob(runID: runID))
            #expect(saved.journal.state == .succeeded)
            #expect(try await store.runInputs(id: runID, limit: 100).map(\.state) == [.acknowledged, .acknowledged])
            #expect(try await store.runs(conversationID: fixture.conversationID, limit: 100).count == 1)
            savedMessages = try await store.page(conversationID: fixture.conversationID, request: PageRequest(limit: 100)).elements
            #expect(savedMessages.count == 4 && savedMessages.map(\.sequence) == [1, 2, 3, 4])
            let replies = savedMessages.filter { $0.author == .teammate(fixture.teammateID) }
            #expect(replies.count == 1)
            #expect(replies.first?.parts.first?.content == .text("Corrected report: production rows only."))
            #expect(await progress.last?.phase == .completed)
        }
        #expect(closed == nil)
        let reopened = try fixture.open()
        #expect(try await reopened.agenticJob(runID: saved.id) == saved)
        #expect(try await reopened.page(conversationID: fixture.conversationID, request: PageRequest(limit: 100)).elements == savedMessages)
    }

    @Test("Stop and shutdown during preparing progress prevent any later driver run", arguments: [false, true])
    func stopDuringPreparation(_ shutdown: Bool) async throws {
        let fixture = try JobServiceDatabase()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try await fixture.message(store, text: "Do this work.")
        let driver = MechanicalJobDriver(), progress = JobProgressLog()
        let service = fixture.service(store, driver: driver)
        await #expect(throws: CancellationError.self) {
            try await service.submit(.init(teammateID: fixture.teammateID, message: message, text: "Do this work."), progress: { update in
                await progress.append(update)
                if update.phase == .preparing {
                    if shutdown { await service.shutdown() }
                    else { await service.stop(conversationID: fixture.conversationID) }
                }
            })
        }
        #expect(await driver.runCount == 0)
        let record = try #require(try await service.history(conversationID: fixture.conversationID).first)
        #expect(record.journal.state == .interrupted && record.journal.lease == nil)
        #expect(record.state.conversationGeneration == 0)
        #expect(try await store.runInputs(id: record.id, limit: 10).map(\.state) == [.queued])
        #expect(await progress.last?.phase == .stopped)
        await service.shutdown()
    }

    @Test("Concurrent correction and worker callbacks preserve CAS state and ordered queued/submitted/acknowledged receipts")
    func reentrantSteeringAndEvents() async throws {
        let fixture = try JobServiceDatabase()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let driver = MechanicalJobDriver(), progress = JobProgressLog(), gate = JobTestSignal()
        let service = fixture.service(store, driver: driver)
        let first = try await fixture.message(store, text: "Initial task")
        let runID = try await service.submit(.init(teammateID: fixture.teammateID, message: first, text: "Initial task"), progress: { await progress.append($0) })
        await driver.ready.wait()
        await driver.pauseNextSteer(gate)
        let second = try await fixture.message(store, text: "Second instruction")
        let correction = Task { try await service.submit(.init(teammateID: fixture.teammateID, message: second, text: "Second instruction"), progress: { await progress.append($0) }) }
        await driver.steeringBegan.wait()
        let worker = await driver.worker
        let checkpoint = AgenticJobCheckpoint(id: UUID(), workerID: worker.id,
            reference: "work-completed-during-steer", sha256: String(repeating: "b", count: 64))
        try await driver.emit(.checkpoint(checkpoint))
        #expect(try await store.runInputs(id: runID, limit: 100).map(\.state) == [.acknowledged, .submitted])
        let third = try await fixture.message(store, text: "Third instruction")
        let thirdQueued = JobTestSignal()
        let another = Task { try await service.submit(.init(teammateID: fixture.teammateID, message: third, text: "Third instruction"), progress: { update in
            await progress.append(update)
            if update.phase == .changingDirection { await thirdQueued.signal() }
        }) }
        await thirdQueued.wait()
        #expect(try await store.runInputs(id: runID, limit: 100).map(\.state) == [.acknowledged, .submitted, .queued])
        await gate.signal()
        #expect(try await correction.value == runID)
        #expect(try await another.value == runID)
        let record = try #require(try await store.agenticJob(runID: runID))
        #expect(record.state.conversationGeneration == 3 && record.state.checkpointReferences == [checkpoint])
        #expect(record.state.workers == [worker])
        #expect(try await store.runInputs(id: runID, limit: 100).map(\.sequence) == [1, 2, 3])
        #expect(try await store.runInputs(id: runID, limit: 100).allSatisfy { $0.state == .acknowledged })
        try await driver.complete("Completed corrected task")
        await progress.terminal.wait()
        await service.shutdown()
    }

    @Test("Failed steer stops the job and never turns its unacknowledged correction into success")
    func failedSteer() async throws {
        let fixture = try JobServiceDatabase()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let driver = MechanicalJobDriver(), progress = JobProgressLog()
        let service = fixture.service(store, driver: driver)
        let first = try await fixture.message(store, text: "Initial task")
        let id = try await service.submit(.init(teammateID: fixture.teammateID, message: first, text: "Initial task"), progress: { await progress.append($0) })
        await driver.ready.wait()
        await driver.failNextSteer()
        let second = try await fixture.message(store, text: "Correction")
        await #expect(throws: MechanicalJobFailure.self) {
            try await service.submit(.init(teammateID: fixture.teammateID, message: second, text: "Correction"), progress: { await progress.append($0) })
        }
        await service.shutdown()
        let record = try #require(try await store.agenticJob(runID: id))
        #expect(record.journal.state == .failed)
        #expect(try await store.runInputs(id: id, limit: 10).map(\.state) == [.acknowledged, .outcomeUnknown])
        #expect(await driver.stopCount > 0)
        #expect(try await store.page(conversationID: fixture.conversationID, request: PageRequest(limit: 100)).elements.count == 2)
        guard case .some(.failed) = await progress.last?.phase else { Issue.record("Expected truthful failed progress"); return }
    }

    @Test("An acknowledgement before submission fails closed without a saved success reply")
    func acknowledgementOrder() async throws {
        let fixture = try JobServiceDatabase()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let driver = MechanicalJobDriver(acknowledgeBeforeSubmission: true), progress = JobProgressLog()
        let service = fixture.service(store, driver: driver)
        let message = try await fixture.message(store, text: "Initial task")
        let id = try await service.submit(.init(teammateID: fixture.teammateID, message: message, text: "Initial task"), progress: { await progress.append($0) })
        await progress.terminal.wait()
        await service.shutdown()
        #expect(try await store.agenticJob(runID: id)?.journal.state == .failed)
        #expect(try await store.runInputs(id: id, limit: 10).map(\.state) == [.queued])
        #expect(try await store.page(conversationID: fixture.conversationID, request: PageRequest(limit: 10)).elements.count == 1)
    }
}

private enum MechanicalJobFailure: Error { case steerFailed, unavailable }

private actor JobTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor JobProgressLog {
    private(set) var values: [AgenticJobProgress] = []
    let terminal = JobTestSignal()
    var last: AgenticJobProgress? { values.last }
    func append(_ value: AgenticJobProgress) async {
        values.append(value)
        if !value.phase.isActive { await terminal.signal() }
    }
}

/// Mechanical driver only: no provider, filesystem, broker or process effects.
private actor MechanicalJobDriver: AgenticJobDriving {
    let ready = JobTestSignal(), steeringBegan = JobTestSignal()
    let worker = AgenticJobWorker(id: UUID(), sessionID: UUID(), processID: 4321, processGroupID: 4321, lifecycle: .running)
    private(set) var runCount = 0, stopCount = 0
    private(set) var decisions: [UUID] = []
    private var sink: (@Sendable (AgenticJobDriverEvent) async throws -> Void)?
    private var result: CheckedContinuation<AgenticJobDriverOutcome, Never>?
    private var pendingResult: AgenticJobDriverOutcome?
    private var generation: UInt64 = 1
    private var pause: JobTestSignal?
    private var failSteer = false
    private let acknowledgeBeforeSubmission: Bool

    init(acknowledgeBeforeSubmission: Bool = false) { self.acknowledgeBeforeSubmission = acknowledgeBeforeSubmission }

    func run(_ request: WorkRequest, event: @escaping @Sendable (AgenticJobDriverEvent) async throws -> Void) async -> AgenticJobDriverOutcome {
        runCount += 1; sink = event
        do {
            try await event(.conversation(generation: 1, sessionID: UUID()))
            if !acknowledgeBeforeSubmission { try await event(.inputSubmitted(request.initialInput.messageID, sequence: 1)) }
            try await event(.inputAcknowledged(request.initialInput.messageID, sequence: 1))
            try await event(.worker(worker))
        } catch { await ready.signal(); return .failed("Mechanical input failed") }
        await ready.signal()
        return await withCheckedContinuation { continuation in
            if let pendingResult { continuation.resume(returning: pendingResult); self.pendingResult = nil }
            else { result = continuation }
        }
    }
    func emit(_ event: AgenticJobDriverEvent) async throws {
        guard let sink else { throw MechanicalJobFailure.unavailable }
        try await sink(event)
    }
    func pauseNextSteer(_ signal: JobTestSignal) { pause = signal }
    func failNextSteer() { failSteer = true }
    func steer(_ input: SteeringInput, runID: RunID) async throws {
        generation += 1
        try await emit(.conversation(generation: generation, sessionID: UUID()))
        try await emit(.inputSubmitted(input.messageID, sequence: input.sequence))
        await steeringBegan.signal()
        let gate = pause; pause = nil
        await gate?.wait()
        if failSteer { failSteer = false; throw MechanicalJobFailure.steerFailed }
        try await emit(.inputAcknowledged(input.messageID, sequence: input.sequence))
    }
    func decide(approvalID: UUID, allow: Bool, runID: RunID, conversationGeneration: UInt64) async throws {
        decisions.append(approvalID)
        try await emit(.approvalResolved(approvalID))
    }
    func stop(runID: RunID) async {
        stopCount += 1
        resolve(.stopped)
    }
    func complete(_ text: String) async throws {
        try await emit(.worker(.init(id: worker.id, sessionID: worker.sessionID, processID: worker.processID,
            processGroupID: worker.processGroupID, lifecycle: .succeeded)))
        resolve(.completed(text))
    }
    private func resolve(_ value: AgenticJobDriverOutcome) {
        if let result { self.result = nil; result.resume(returning: value) }
        else { pendingResult = value }
    }
}

private struct JobServiceDatabase: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID()), conversationID = ConversationID(UUID())
    let date = Date(timeIntervalSinceReferenceDate: 1_000.1234567)
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsJobService-\(UUID()).noindex")
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: .init(fileURL: directory.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(id: teammateID, profile: TeammateProfile(displayName: "Job Partner", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: teammateID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }
    func message(_ store: SQLiteStore, text: String) async throws -> Message {
        for attempt in 0..<8 {
            let previous = try await store.page(conversationID: conversationID, request: PageRequest(limit: 1)).elements.first?.sequence ?? 0
            let message = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: previous + 1,
                author: .user, deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
                createdAt: date, updatedAt: date)
            do { try await store.append(message, expectedPreviousSequence: previous); return message }
            catch RepositoryError.sequenceConflict where attempt < 7 { continue }
        }
        throw MechanicalJobFailure.unavailable
    }
    func service(_ store: SQLiteStore, driver: MechanicalJobDriver) -> AgenticJobService {
        AgenticJobService(repository: store, teammates: store, conversations: store, messages: store, driver: driver)
    }
}
