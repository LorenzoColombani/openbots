import Foundation
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Journal-only recovery fixture service")
struct RunRecoveryFixtureServiceTests {
    @Test("Construction and review loading cannot start or recover work")
    func inertConstructionAndReadOnlyReview() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        #expect(await fixture.repository.calls.isEmpty)
        #expect(fixture.clock.calls == 0 && fixture.uuids.calls == 0)
        #expect(try await service.reviews(conversationID: fixture.conversation.id).isEmpty)
        #expect(await fixture.repository.mutations.isEmpty)
        #expect(fixture.clock.calls == 0 && fixture.uuids.calls == 0)
        #expect(await fixture.repository.calls == ["runs:10"])
    }

    @Test("Start uses latest saved user text and ordered attachments, never a generated chat message")
    func startSavedInput() async throws {
        let fixture = try RecoveryServiceFixture()
        let attachment = AttachmentID(UUID())
        let latest = try fixture.message(sequence: 8, author: .user, parts: [
            try MessagePart(id: MessagePartID(UUID()), ordinal: 2, content: .text("\0second")),
            try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(" e\u{301}")),
            try MessagePart(id: MessagePartID(UUID()), ordinal: 1, content: .attachment(attachment))
        ])
        let reply = try fixture.message(sequence: 9, author: .teammate(fixture.teammate.id))
        let audit = try fixture.message(sequence: 10, author: .user, output: .workAudit)
        await fixture.repository.setMessages([reply, fixture.user, audit, latest])
        let service = fixture.service()
        let review = try await service.startDemo(conversationID: fixture.conversation.id)
        #expect(review.record.origin == .localFixture && review.record.state == .running)
        #expect(review.record.revision == 4)
        #expect(review.record.request.teammateID == fixture.teammate.id)
        #expect(review.record.request.selectedProjectID == fixture.context.projectID)
        #expect(review.record.request.profileRevision == fixture.teammate.profile.revision)
        #expect(review.record.request.initiatingMessageID == latest.id)
        #expect(review.record.request.initialInput.sequence == 1)
        #expect(Array(review.record.request.initialInput.text.utf8) == Array(" e\u{301}\0second".utf8))
        #expect(review.record.request.initialInput.attachmentIDs == [attachment])
        #expect(review.inputs.map(\.state) == [.submitted])
        #expect(review.record.lease?.ownerID == fixture.owner)
        #expect(review.record.lease?.expiresAt == fixture.clock.now().addingTimeInterval(30))
        #expect(review.entries.map(\.kind) == [.enqueued, .claimed, .stateChanged, .inputSubmitted])
        #expect(await fixture.repository.mutations == ["enqueue", "claim", "transition:started", "mark:submitted"])
        #expect(await fixture.repository.messageValues == [reply, fixture.user, audit, latest])
        #expect(await fixture.repository.calls.contains("page:50"))
    }

    @Test("A missing saved user message is a typed local requirement, not an invented turn")
    func missingUserMessage() async throws {
        let fixture = try RecoveryServiceFixture()
        await fixture.repository.setMessages([try fixture.message(sequence: 1, author: .system)])
        await #expect(throws: RunRecoveryFixtureError.needUserMessage) {
            try await fixture.service().startDemo(conversationID: fixture.conversation.id)
        }
        #expect(await fixture.repository.mutations.isEmpty)
        #expect(fixture.uuids.calls == 0)
    }

    @Test("Inactive or mismatched conversation, teammate and context fail before enqueue")
    func invalidContext() async throws {
        for variant in ["conversation", "teammate", "context"] {
            let fixture = try RecoveryServiceFixture()
            await fixture.repository.invalidate(variant)
            await #expect(throws: (any Error).self) {
                try await fixture.service().startDemo(conversationID: fixture.conversation.id)
            }
            #expect(await fixture.repository.mutations.isEmpty)
            #expect(fixture.uuids.calls == 0)
        }
    }

    @Test("A partial start remains durable and is never retried or described as rolled back")
    func partialStart() async throws {
        for failure in ["claim", "transition:started", "mark:submitted"] {
            let fixture = try RecoveryServiceFixture()
            await fixture.repository.fail(at: failure)
            var partialID: RunID?
            do { _ = try await fixture.service().startDemo(conversationID: fixture.conversation.id); Issue.record("Expected partial start") }
            catch let RunRecoveryFixtureError.partialStart(runID) { partialID = runID }
            let id = try #require(partialID)
            let persisted = try #require(await fixture.repository.run(id: id))
            #expect(persisted.state == (failure == "claim" ? .queued : failure == "transition:started" ? .starting : .running))
            #expect(try await fixture.repository.runInputs(id: id, limit: 50).first?.state == .queued)
            #expect(await fixture.repository.mutations.filter { $0 == "enqueue" }.count == 1)
            #expect(await fixture.repository.messageValues == [fixture.user])
        }
    }

    @Test("Acknowledgement is explicit and finish requires the initial acknowledged receipt")
    func acknowledgeAndFinish() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        let started = try await service.startDemo(conversationID: fixture.conversation.id)
        let before = await fixture.repository.mutations
        await #expect(throws: RunJournalError.invalidInputTransition) {
            try await service.finishDemo(runID: started.id, expectedRevision: started.record.revision)
        }
        #expect(await fixture.repository.mutations == before)
        let acknowledged = try await service.acknowledgeDemo(runID: started.id, expectedRevision: started.record.revision)
        #expect(acknowledged.inputs.map(\.state) == [.acknowledged])
        #expect(acknowledged.record.state == .running)
        await #expect(throws: RunJournalError.staleRevision) {
            try await service.acknowledgeDemo(runID: started.id, expectedRevision: started.record.revision)
        }
        let finished = try await service.finishDemo(runID: started.id, expectedRevision: acknowledged.record.revision)
        #expect(finished.record.state == .succeeded && finished.record.lease == nil)
        #expect(finished.inputs.map(\.state) == [.acknowledged])
        #expect(await fixture.repository.messageValues == [fixture.user])
    }

    @Test("Interruption makes only submitted input uncertain; proven acknowledgement survives")
    func interruptMeaning() async throws {
        for acknowledge in [false, true] {
            let fixture = try RecoveryServiceFixture()
            let service = fixture.service()
            var current = try await service.startDemo(conversationID: fixture.conversation.id)
            if acknowledge { current = try await service.acknowledgeDemo(runID: current.id, expectedRevision: current.record.revision) }
            let interrupted = try await service.interruptDemo(runID: current.id, expectedRevision: current.record.revision)
            #expect(interrupted.record.state == .interrupted && interrupted.record.lease == nil)
            #expect(interrupted.inputs.map(\.state) == [acknowledge ? .acknowledged : .outcomeUnknown])
        }
    }

    @Test("Stopping retains the lease until explicit local stopped confirmation")
    func stoppingAndFailure() async throws {
        for failure in [false, true] {
            let fixture = try RecoveryServiceFixture()
            let service = fixture.service()
            let started = try await service.startDemo(conversationID: fixture.conversation.id)
            let stopping = try await service.requestStopDemo(runID: started.id, expectedRevision: started.record.revision)
            #expect(stopping.record.state == .stopping)
            #expect(stopping.record.lease == started.record.lease)
            #expect(stopping.inputs.map(\.state) == [.submitted])
            let terminal = failure
                ? try await service.failDemo(runID: stopping.id, expectedRevision: stopping.record.revision)
                : try await service.interruptDemo(runID: stopping.id, expectedRevision: stopping.record.revision)
            #expect(terminal.record.state == (failure ? .failed : .interrupted))
            #expect(terminal.record.lease == nil)
            #expect(terminal.inputs.map(\.state) == [.outcomeUnknown])
            #expect(await fixture.repository.messageValues == [fixture.user])
        }
    }

    @Test("An unclaimed partial demo can be explicitly ended without claiming or replaying it")
    func endUnclaimedPartial() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        await fixture.repository.fail(at: "claim")
        await #expect(throws: RunRecoveryFixtureError.self) { try await service.startDemo(conversationID: fixture.conversation.id) }
        let queued = try #require(try await service.reviews(conversationID: fixture.conversation.id).first)
        #expect(queued.record.state == .queued && queued.record.lease == nil)
        #expect(try await service.recoverExpiredDemos(conversationID: fixture.conversation.id).isEmpty)
        let before = await fixture.repository.mutations
        // A new process-owner may explicitly end this exact unclaimed demo;
        // no live process or lease ever existed for it.
        let failed = try await fixture.service(owner: UUID()).failDemo(runID: queued.id, expectedRevision: queued.record.revision)
        #expect(failed.record.state == .failed && failed.record.lease == nil)
        #expect(failed.inputs.map(\.state) == [.queued])
        #expect(await fixture.repository.mutations == before + ["failUnclaimed"])
        await #expect(throws: RunJournalError.staleRevision) {
            try await service.failDemo(runID: queued.id, expectedRevision: queued.record.revision)
        }
    }

    @Test("Wrong owner, executor origin, stale revision and expired lease cannot mutate a run")
    func fences() async throws {
        for variant in ["owner", "origin", "revision", "expiry"] {
            let fixture = try RecoveryServiceFixture()
            let service = fixture.service()
            let started = try await service.startDemo(conversationID: fixture.conversation.id)
            if variant == "origin" { await fixture.repository.replaceOrigin(started.id, .executor) }
            if variant == "expiry" { fixture.clock.advance(30) }
            let before = await fixture.repository.mutations
            let target = variant == "owner" ? fixture.service(owner: UUID()) : service
            let revision = variant == "revision" ? started.record.revision - 1 : started.record.revision
            for action in 0..<5 {
                await #expect(throws: (any Error).self) {
                    switch action {
                    case 0: try await target.acknowledgeDemo(runID: started.id, expectedRevision: revision)
                    case 1: try await target.finishDemo(runID: started.id, expectedRevision: revision)
                    case 2: try await target.interruptDemo(runID: started.id, expectedRevision: revision)
                    case 3: try await target.requestStopDemo(runID: started.id, expectedRevision: revision)
                    default: try await target.failDemo(runID: started.id, expectedRevision: revision)
                    }
                }
            }
            #expect(await fixture.repository.mutations == before)
        }
    }

    @Test("Load does not recover; explicit recovery returns only changed local fixture runs")
    func explicitRecovery() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        let started = try await service.startDemo(conversationID: fixture.conversation.id)
        fixture.clock.advance(31)
        #expect(try await service.reviews(conversationID: fixture.conversation.id).first?.record.state == .running)
        #expect(await fixture.repository.mutations.last == "mark:submitted")
        let changed = try await fixture.service(owner: UUID()).recoverExpiredDemos(conversationID: fixture.conversation.id)
        #expect(changed.map(\.id) == [started.id])
        #expect(changed.first?.record.state == .interrupted)
        #expect(changed.first?.inputs.map(\.state) == [.outcomeUnknown])
        #expect(changed.first?.entries.last?.kind == .recovered)
        #expect(try await service.recoverExpiredDemos(conversationID: fixture.conversation.id).isEmpty)
        #expect(await fixture.repository.calls.contains("recover:10"))
        #expect(await fixture.repository.messageValues == [fixture.user])
    }

    @Test("Executor records are never presented as demos or recovered by this service")
    func excludesExecutor() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        let started = try await service.startDemo(conversationID: fixture.conversation.id)
        await fixture.repository.replaceOrigin(started.id, .executor)
        fixture.clock.advance(31)
        #expect(try await service.reviews(conversationID: fixture.conversation.id).isEmpty)
        #expect(try await service.recoverExpiredDemos(conversationID: fixture.conversation.id).isEmpty)
        #expect(await fixture.repository.run(id: started.id)?.state == .running)
    }

    @Test("Unrelated, duplicated or unbounded review receipts fail closed")
    func invalidReviewReceipts() async throws {
        for variant in ["duplicateRuns", "manyRuns", "wrongInput", "wrongEntry", "manyInputs", "manyEntries", "emptyEntries", "gappedEntries", "gappedInputs"] {
            let fixture = try RecoveryServiceFixture()
            let service = fixture.service()
            _ = try await service.startDemo(conversationID: fixture.conversation.id)
            await fixture.repository.corruptReviews(variant)
            let before = await fixture.repository.mutations
            await #expect(throws: RunRecoveryFixtureError.invalidRepositoryResponse) {
                try await service.reviews(conversationID: fixture.conversation.id)
            }
            #expect(await fixture.repository.mutations == before)
        }
    }

    @Test("A revision change between bounded reads is stale, not a corrupt receipt")
    func concurrentReviewChange() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        _ = try await service.startDemo(conversationID: fixture.conversation.id)
        await fixture.repository.corruptReviews("concurrentRevision")
        await #expect(throws: RunJournalError.staleRevision) {
            try await service.reviews(conversationID: fixture.conversation.id)
        }
    }

    @Test("Cancellation before start is inert; cancellation after enqueue reports the durable partial run")
    func cancellation() async throws {
        let fixture = try RecoveryServiceFixture()
        let service = fixture.service()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await service.startDemo(conversationID: fixture.conversation.id) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.repository.mutations.isEmpty)
        await fixture.repository.cancelAfterEnqueue()
        let partial = Task { try await service.startDemo(conversationID: fixture.conversation.id) }
        await #expect(throws: RunRecoveryFixtureError.self) { try await partial.value }
        #expect(await fixture.repository.mutations == ["enqueue"])
        #expect(try await service.reviews(conversationID: fixture.conversation.id).first?.record.state == .queued)
    }

    @Test("Invalid clocks or oversize source input fail before any durable run is created")
    func clockAndInputBounds() async throws {
        let fixture = try RecoveryServiceFixture()
        fixture.clock.set(Date(timeIntervalSince1970: .infinity))
        await #expect(throws: RunJournalError.invalidRequest) {
            try await fixture.service().startDemo(conversationID: fixture.conversation.id)
        }
        #expect(await fixture.repository.mutations.isEmpty)
        fixture.clock.set(Date(timeIntervalSince1970: 1_000))
        let oversized = try fixture.message(sequence: 2, author: .user, parts: [
            .init(id: MessagePartID(UUID()), ordinal: 0, content: .text(String(repeating: "x", count: ConversationDraftSnapshot.maximumUTF8ByteCount + 1)))
        ])
        await fixture.repository.setMessages([oversized])
        await #expect(throws: RunJournalError.invalidRequest) {
            try await fixture.service().startDemo(conversationID: fixture.conversation.id)
        }
        #expect(await fixture.repository.mutations.isEmpty)
    }

    @Test("A non-integer timestamp and journal receipt survive true SQLite close/reopen without replay")
    func sqliteReopenAndExplicitRecovery() async throws {
        for acknowledge in [false, true] {
            let fixture = try RecoverySQLiteFixture()
            defer { fixture.remove() }
            let saved = try await createSavedDemo(fixture, acknowledge: acknowledge)
            #expect(saved.store.value == nil, "The first SQLite connection must really close.")
            let reopened = try fixture.open()
            let service = fixture.service(reopened, owner: UUID())
            let before = try #require(try await service.reviews(conversationID: fixture.base.conversation.id).first)
            #expect(before.record == saved.review.record)
            #expect(before.inputs == saved.review.inputs)
            #expect(before.entries == saved.review.entries)
            await #expect(throws: RunRecoveryFixtureError.wrongOwner) {
                try await service.interruptDemo(runID: before.id, expectedRevision: before.record.revision)
            }
            fixture.base.clock.advance(31)
            #expect(try await service.reviews(conversationID: fixture.base.conversation.id).first?.record.state == .running)
            let recovered = try #require(try await service.recoverExpiredDemos(conversationID: fixture.base.conversation.id).first)
            #expect(recovered.record.state == .interrupted && recovered.record.lease == nil)
            #expect(recovered.inputs.map(\.state) == [acknowledge ? .acknowledged : .outcomeUnknown])
            #expect(recovered.entries.last?.kind == .recovered)
            #expect(try await reopened.page(conversationID: fixture.base.conversation.id, request: PageRequest(limit: 50)).elements == [fixture.base.user])
            #expect(try await service.recoverExpiredDemos(conversationID: fixture.base.conversation.id).isEmpty)
            // A second explicit demo is allowed after the previous one ended;
            // it gets a new RunID while preserving the same saved user message.
            let second = try await service.startDemo(conversationID: fixture.base.conversation.id)
            #expect(second.id != recovered.id)
            #expect(second.record.request.initiatingMessageID == recovered.record.request.initiatingMessageID)
            let accepted = try await service.acknowledgeDemo(runID: second.id, expectedRevision: second.record.revision)
            let finished = try await service.finishDemo(runID: accepted.id, expectedRevision: accepted.record.revision)
            #expect(finished.record.state == .succeeded)
            #expect(try await reopened.page(conversationID: fixture.base.conversation.id, request: PageRequest(limit: 50)).elements == [fixture.base.user])
        }
    }

    @Test("SQLite unclaimed local demo can be ended after reopen without an invented lease")
    func sqliteUnclaimedRecovery() async throws {
        let fixture = try RecoverySQLiteFixture()
        defer { fixture.remove() }
        let saved: (RunJournalRecord, WeakRecoverySQLiteStore) = try await {
            let store = try fixture.open()
            try await fixture.seed(store)
            let request = try WorkRequest(runID: RunID(UUID()), teammateID: fixture.base.teammate.id,
                conversationID: fixture.base.conversation.id, initiatingMessageID: fixture.base.user.id,
                profileRevision: fixture.base.teammate.profile.revision,
                initialInput: .init(messageID: fixture.base.user.id, sequence: 1, text: "Saved user request"),
                submittedAt: Date(timeIntervalSince1970: fixture.base.clock.now().timeIntervalSince1970))
            return (try await store.enqueueRun(request, origin: .localFixture), WeakRecoverySQLiteStore(store))
        }()
        #expect(saved.1.value == nil)
        let reopened = try fixture.open()
        let service = fixture.service(reopened, owner: UUID())
        let failed = try await service.failDemo(runID: saved.0.id, expectedRevision: saved.0.revision)
        #expect(failed.record.state == .failed && failed.record.lease == nil)
        #expect(failed.inputs.map(\.state) == [.queued])
        #expect(failed.entries.map(\.kind) == [.enqueued, .stateChanged])
        #expect(try await reopened.message(id: fixture.base.user.id) == fixture.base.user)
    }

    private func createSavedDemo(_ fixture: RecoverySQLiteFixture, acknowledge: Bool) async throws -> (review: RunRecoveryReview, store: WeakRecoverySQLiteStore) {
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        var review = try await service.startDemo(conversationID: fixture.base.conversation.id)
        if acknowledge { review = try await service.acknowledgeDemo(runID: review.id, expectedRevision: review.record.revision) }
        return (review, WeakRecoverySQLiteStore(store))
    }
}

private struct RecoveryServiceFixture: Sendable {
    let teammate: Teammate
    let conversation: Conversation
    let context: ConversationContextSelection
    let user: Message
    let repository: RecoveryRepositoryDouble
    let clock = RecoveryClock()
    let uuids = RecoveryUUIDs()
    let owner = UUID()

    init() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        teammate = try Teammate(id: TeammateID(UUID()), profile: .init(displayName: "Aster", role: "Research", revision: 3),
            appearance: .init(mode: .creature, grammarVersion: 1, deterministicSeed: 4, silhouette: "round",
                paletteToken: "mint", eyeDialect: "round", nonColorIdentityCue: "antenna", accessibleIdentityDescription: "Antenna creature"),
            createdAt: date, updatedAt: date)
        conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id), createdAt: date, updatedAt: date)
        context = ConversationContextSelection(conversationID: conversation.id, teammateID: teammate.id, projectID: ProjectID(UUID()), revision: 1)
        user = try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1, author: .user, deliveryState: .completed,
            parts: [.init(id: MessagePartID(UUID()), ordinal: 0, content: .text("Saved user request"))], createdAt: date, updatedAt: date)
        repository = RecoveryRepositoryDouble(teammate: teammate, conversation: conversation, context: context, user: user)
    }
    func service(owner: UUID? = nil) -> RunRecoveryFixtureService {
        .init(journalRepository: repository, teammateRepository: repository, conversationRepository: repository,
            messageRepository: repository, contextRepository: repository, ownerID: owner ?? self.owner, clock: clock, uuidGenerator: uuids)
    }
    func message(sequence: Int64, author: MessageAuthor, output: OutputClass = .conversation, parts: [MessagePart]? = nil) throws -> Message {
        try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: sequence, author: author, outputClass: output, deliveryState: .completed,
            parts: parts ?? [.init(id: MessagePartID(UUID()), ordinal: 0, content: .text("Other saved message"))],
            createdAt: clock.now(), updatedAt: clock.now())
    }
}

private actor RecoveryRepositoryDouble: RunJournalRepository, TeammateRepository, ConversationRepository, MessageRepository, ConversationContextRepository {
    private var person: Teammate
    private var chat: Conversation
    private var context: ConversationContextSelection
    private(set) var messageValues: [Message]
    private var records: [RunID: RunJournalRecord] = [:]
    private var inputs: [RunID: [RunInputReceipt]] = [:]
    private var entries: [RunID: [RunJournalEntry]] = [:]
    private(set) var calls: [String] = []
    private(set) var mutations: [String] = []
    private var failure: String?
    private var corruption: String?
    private var cancelEnqueue = false

    init(teammate: Teammate, conversation: Conversation, context: ConversationContextSelection, user: Message) {
        person = teammate; chat = conversation; self.context = context; messageValues = [user]
    }
    func setMessages(_ values: [Message]) { messageValues = values }
    func fail(at value: String) { failure = value }
    func corruptReviews(_ value: String) { corruption = value }
    func cancelAfterEnqueue() { cancelEnqueue = true }
    func invalidate(_ value: String) {
        if value == "conversation" { chat.lifecycle = .archived }
        if value == "teammate" { person.isHidden = true }
        if value == "context" { context = .init(conversationID: ConversationID(UUID()), teammateID: person.id) }
    }
    func replaceOrigin(_ id: RunID, _ origin: RunOrigin) {
        guard let value = records[id] else { return }
        records[id] = .init(request: value.request, origin: origin, state: value.state, revision: value.revision, lease: value.lease, updatedAt: value.updatedAt)
    }

    func enqueueRun(_ request: WorkRequest, origin: RunOrigin) throws -> RunJournalRecord {
        try write("enqueue")
        guard !records.values.contains(where: { $0.request.conversationID == request.conversationID && $0.lease != nil }) else { throw RunJournalError.conflictingActiveRun }
        let record = RunJournalRecord(request: request, origin: origin, state: .queued, revision: 1, lease: nil, updatedAt: request.submittedAt)
        records[record.id] = record
        inputs[record.id] = [.init(runID: record.id, messageID: request.initiatingMessageID, sequence: 1, state: .queued, updatedAt: request.submittedAt)]
        append(record, kind: .enqueued)
        if cancelEnqueue { withUnsafeCurrentTask { $0?.cancel() } }
        return record
    }
    func run(id: RunID) -> RunJournalRecord? { calls.append("run"); return records[id] }
    func runs(conversationID: ConversationID, limit: Int) -> [RunJournalRecord] {
        calls.append("runs:\(limit)")
        let result = records.values.filter { $0.request.conversationID == conversationID }.sorted { $0.updatedAt > $1.updatedAt }
        if corruption == "duplicateRuns", let first = result.first { return [first, first] }
        if corruption == "manyRuns", let first = result.first { return Array(repeating: first, count: 11) }
        return Array(result.prefix(limit))
    }
    func claimRun(id: RunID, expectedRevision: Int64, ownerID: UUID, token: UUID, now: Date, leaseDuration: TimeInterval) throws -> RunJournalRecord {
        try write("claim")
        let current = try record(id, revision: expectedRevision)
        let lease = RunLease(ownerID: ownerID, token: token, generation: 1, expiresAt: now.addingTimeInterval(leaseDuration))
        let changed = next(current, state: try current.state.applying(.begin), lease: lease, now: now)
        append(changed, kind: .claimed)
        return changed
    }
    func renewRunLease(id: RunID, expectedRevision: Int64, token: UUID, now: Date, leaseDuration: TimeInterval) throws -> RunJournalRecord { throw RunJournalError.unavailable }
    func transitionRun(id: RunID, expectedRevision: Int64, token: UUID, event: WorkRunEvent, now: Date) throws -> RunJournalRecord {
        try write("transition:\(event.rawValue)")
        let current = try leased(id, revision: expectedRevision, token: token, now: now)
        let state = try current.state.applying(event)
        let terminal = [.succeeded, .failed, .interrupted].contains(state)
        let changed = next(current, state: state, lease: terminal ? nil : current.lease, now: now)
        if state == .failed || state == .interrupted { uncertain(id, now: now) }
        append(changed, kind: .stateChanged)
        return changed
    }
    func queueRunInput(id: RunID, expectedRevision: Int64, token: UUID, input: SteeringInput, now: Date) throws -> RunJournalRecord { throw RunJournalError.unavailable }
    func markRunInput(id: RunID, expectedRevision: Int64, token: UUID, messageID: MessageID, sequence: Int64, state: RunInputState, now: Date) throws -> RunJournalRecord {
        try write("mark:\(state.rawValue)")
        let current = try leased(id, revision: expectedRevision, token: token, now: now)
        guard let index = inputs[id]?.firstIndex(where: { $0.messageID == messageID && $0.sequence == sequence }), let before = inputs[id]?[index] else { throw RunJournalError.inputUnavailable }
        guard (before.state == .queued && state == .submitted) || (before.state == .submitted && state == .acknowledged) else { throw RunJournalError.invalidInputTransition }
        inputs[id]?[index] = .init(runID: id, messageID: messageID, sequence: sequence, state: state, updatedAt: now)
        let changed = next(current, state: current.state, lease: current.lease, now: now)
        append(changed, kind: state == .submitted ? .inputSubmitted : .inputAcknowledged, message: messageID)
        return changed
    }
    func runInputs(id: RunID, limit: Int) -> [RunInputReceipt] {
        calls.append("inputs:\(limit)")
        let result = inputs[id] ?? []
        if corruption == "wrongInput", let first = result.first { return [.init(runID: RunID(UUID()), messageID: first.messageID, sequence: 1, state: first.state, updatedAt: first.updatedAt)] }
        if corruption == "manyInputs", let first = result.first { return Array(repeating: first, count: 51) }
        if corruption == "gappedInputs", let first = result.first { return [.init(runID: id, messageID: first.messageID, sequence: 2, state: first.state, updatedAt: first.updatedAt)] }
        return Array(result.prefix(limit))
    }
    func runEntries(id: RunID, afterSequence: Int64, limit: Int) -> [RunJournalEntry] {
        calls.append("entries:\(afterSequence):\(limit)")
        let result = entries[id] ?? []
        if corruption == "wrongEntry", let first = result.first { return [.init(runID: RunID(UUID()), sequence: 1, kind: first.kind, state: first.state, inputMessageID: nil, recordedAt: first.recordedAt)] }
        if corruption == "manyEntries", let first = result.first { return Array(repeating: first, count: 101) }
        if corruption == "emptyEntries" { return [] }
        if corruption == "gappedEntries" { return result.filter { $0.sequence != 2 } }
        if corruption == "concurrentRevision", let current = records[id] {
            corruption = nil
            let updated = next(current, state: current.state, lease: current.lease, now: current.updatedAt)
            append(updated, kind: .leaseRenewed)
        }
        return Array(result.filter { $0.sequence > afterSequence }.prefix(limit))
    }
    func recoverExpiredLocalFixtures(conversationID: ConversationID, now: Date, limit: Int) throws -> [RunJournalRecord] {
        calls.append("recover:\(limit)"); try write("recover")
        let expired = Array(records.values.filter { $0.origin == .localFixture && $0.request.conversationID == conversationID && ($0.lease?.expiresAt ?? .distantFuture) <= now }.prefix(limit))
        return expired.map { current in
            let changed = next(current, state: .interrupted, lease: nil, now: now)
            uncertain(current.id, now: now); append(changed, kind: .recovered)
            return changed
        }
    }
    func failUnclaimedLocalFixture(id: RunID, expectedRevision: Int64, now: Date) throws -> RunJournalRecord {
        try write("failUnclaimed")
        let current = try record(id, revision: expectedRevision)
        guard current.origin == .localFixture, current.state == .queued, current.lease == nil else { throw RunJournalError.invalidTransition }
        let changed = next(current, state: .failed, lease: nil, now: now)
        append(changed, kind: .stateChanged)
        return changed
    }
    private func write(_ name: String) throws { mutations.append(name); if failure == name { throw RunJournalError.unavailable } }
    private func record(_ id: RunID, revision: Int64) throws -> RunJournalRecord {
        guard let result = records[id] else { throw RunJournalError.unavailable }
        guard result.revision == revision else { throw RunJournalError.staleRevision }
        return result
    }
    private func leased(_ id: RunID, revision: Int64, token: UUID, now: Date) throws -> RunJournalRecord {
        let result = try record(id, revision: revision)
        guard let lease = result.lease, lease.token == token else { throw RunJournalError.leaseUnavailable }
        guard lease.expiresAt > now else { throw RunJournalError.leaseExpired }
        return result
    }
    private func next(_ record: RunJournalRecord, state: WorkRunState, lease: RunLease?, now: Date) -> RunJournalRecord {
        let result = RunJournalRecord(request: record.request, origin: record.origin, state: state, revision: record.revision + 1, lease: lease, updatedAt: now)
        records[result.id] = result
        return result
    }
    private func append(_ record: RunJournalRecord, kind: RunJournalEntryKind, message: MessageID? = nil) {
        let sequence = Int64(entries[record.id, default: []].count + 1)
        entries[record.id, default: []].append(.init(runID: record.id, sequence: sequence, kind: kind, state: record.state, inputMessageID: message, recordedAt: record.updatedAt))
    }
    private func uncertain(_ id: RunID, now: Date) {
        inputs[id] = inputs[id]?.map { .init(runID: id, messageID: $0.messageID, sequence: $0.sequence, state: $0.state == .submitted ? .outcomeUnknown : $0.state, updatedAt: now) }
    }
    func teammate(id: TeammateID) -> Teammate? { calls.append("teammate"); return id == person.id ? person : nil }
    func listTeammates(includingArchived: Bool) -> [Teammate] { [person] }
    func insert(_ teammate: Teammate) throws { throw RunJournalError.unavailable }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) throws { throw RunJournalError.unavailable }
    func conversation(id: ConversationID) -> Conversation? { calls.append("conversation"); return id == chat.id ? chat : nil }
    func conversations(for teammateID: TeammateID, includingArchived: Bool) -> [Conversation] { [chat] }
    func insert(_ conversation: Conversation, participantIDs: Set<TeammateID>) throws { throw RunJournalError.unavailable }
    func update(_ conversation: Conversation) throws { throw RunJournalError.unavailable }
    func append(_ message: Message, expectedPreviousSequence: Int64) throws { mutations.append("FORBIDDEN appendMessage"); throw RunJournalError.unavailable }
    func message(id: MessageID) -> Message? { messageValues.first { $0.id == id } }
    func page(conversationID: ConversationID, request: PageRequest) -> Page<Message> { calls.append("page:\(request.limit)"); return .init(elements: messageValues, hasMore: false) }
    func updateDeliveryState(messageID: MessageID, from expectedState: MessageDeliveryState, to newState: MessageDeliveryState, updatedAt: Date) throws { mutations.append("FORBIDDEN deliveryState"); throw RunJournalError.unavailable }
    func loadContext(conversationID: ConversationID) -> ConversationContextSelection { calls.append("context"); return context }
    func saveContext(_ selection: ConversationContextSelection) throws -> ConversationContextSelection { throw RunJournalError.unavailable }
}

private final class RecoveryClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func now() -> Date { lock.withLock { count += 1; return date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date = date.addingTimeInterval(interval) } }
    func set(_ value: Date) { lock.withLock { date = value } }
}
private final class RecoveryUUIDs: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func next() -> UUID { lock.withLock { count += 1; return UUID() } }
}

private final class WeakRecoverySQLiteStore: @unchecked Sendable {
    weak var value: SQLiteStore?
    init(_ value: SQLiteStore) { self.value = value }
}

private struct RecoverySQLiteFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let base: RecoveryServiceFixture
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextRunService-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        base = try RecoveryServiceFixture()
        // Deliberately exercises Date's two epoch representations rather than
        // relying only on integer-valued test timestamps.
        base.clock.set(Date(timeIntervalSinceReferenceDate: 809_712_345.1234567))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: .init(fileURL: directory.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore) async throws {
        try await store.provisionDirectChat(teammate: base.teammate, conversation: base.conversation, fixtureGreeting: nil, selectConversation: false)
        try await store.append(base.user, expectedPreviousSequence: 0)
    }
    func service(_ store: SQLiteStore, owner: UUID? = nil) -> RunRecoveryFixtureService {
        .init(journalRepository: store, teammateRepository: store, conversationRepository: store,
            messageRepository: store, contextRepository: store, ownerID: owner ?? base.owner,
            clock: base.clock, uuidGenerator: base.uuids)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
