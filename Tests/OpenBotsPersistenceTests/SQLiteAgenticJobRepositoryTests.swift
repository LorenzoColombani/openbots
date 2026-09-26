import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("One durable agentic job across conversational restarts")
struct SQLiteAgenticJobRepositoryTests {
    @Test("Executor enqueue and initial job metadata commit atomically and retain one active run per bot")
    func atomicCreation() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let message = try await fixture.message(store)
        let request = try fixture.request(message)
        _ = try await store.execute(sql: "CREATE TRIGGER fail_agentic_insert BEFORE INSERT ON agentic_job_states BEGIN SELECT RAISE(ABORT,'fixture insert failure'); END;")
        await #expect(throws: SQLiteStoreError.self) { try await store.createAgenticJob(request: request) }
        for table in ["work_runs", "run_journal_metadata", "run_input_receipts", "run_journal_entries", "agentic_job_states"] {
            #expect(try await store.query(sql: "SELECT * FROM \(table);").isEmpty)
        }
        #expect(try await store.message(id: message.id) == message)
        _ = try await store.execute(sql: "DROP TRIGGER fail_agentic_insert;")
        let created = try await store.createAgenticJob(request: request)
        #expect(created.journal.origin == .executor && created.journal.state == .queued)
        #expect(created.journal.request == request && created.journal.revision == 1)
        #expect(created.revision == 1 && created.state == AgenticJobState(runID: request.runID))
        #expect(try await store.runInputs(id: request.runID, limit: 10).count == 1)
        await #expect(throws: RunJournalError.conflictingActiveRun) { try await store.createAgenticJob(request: fixture.request(message)) }
        await #expect(throws: RunJournalError.conflictingActiveRun) { try await store.enqueueRun(fixture.request(message), origin: .localFixture) }
        #expect(try await store.query(sql: "SELECT id FROM work_runs;").count == 1)
    }

    @Test("Corrections, preserved workers and ordered checkpoints reopen under the same terminal logical run")
    func oneRunReopenAndHistory() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        weak var closed: SQLiteStore?
        var saved: AgenticJobRecord!
        var history: [AgenticJobUpdate] = []
        let workerID = UUID(), workerSession = UUID(), firstSession = UUID(), secondSession = UUID()
        let checkpoint = AgenticJobCheckpoint(id: UUID(), workerID: workerID,
            reference: "validated-input:sample.csv", sha256: String(repeating: "a", count: 64))
        do {
            let store = try fixture.open()
            closed = store
            var current = try await fixture.running(store)
            let starting = AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: firstSession,
                workers: [.init(id: workerID, sessionID: workerSession)])
            current = try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token,
                state: starting, now: fixture.at(3))
            #expect(current.revision == 2 && current.journal.revision == 3)
            let correction = try await fixture.message(store, sequence: 2, text: "Actually, exclude test rows.")
            var journal = try await store.queueRunInput(id: current.id, expectedRevision: 3, token: fixture.token,
                input: SteeringInput(messageID: correction.id, sequence: 2, text: "Actually, exclude test rows.", submittedAt: fixture.at(4)),
                now: fixture.at(4))
            let redirected = AgenticJobState(runID: current.id, conversationGeneration: 2, sessionID: secondSession,
                workers: [.init(id: workerID, sessionID: workerSession, processID: 1234, processGroupID: 1234, lifecycle: .running)],
                checkpointReferences: [checkpoint])
            current = try await store.updateAgenticJob(runID: current.id, expectedRevision: 2, leaseToken: fixture.token,
                state: redirected, now: fixture.at(5))
            #expect(current.revision == 3 && current.journal.revision == journal.revision)
            #expect(current.journal.request.initialInput.text == "Original report request")
            journal = try await store.markRunInput(id: current.id, expectedRevision: journal.revision, token: fixture.token,
                messageID: correction.id, sequence: 2, state: .submitted, now: fixture.at(6))
            journal = try await store.markRunInput(id: current.id, expectedRevision: journal.revision, token: fixture.token,
                messageID: correction.id, sequence: 2, state: .acknowledged, now: fixture.at(7))
            let finished = AgenticJobState(runID: current.id, conversationGeneration: 2, sessionID: secondSession,
                workers: [.init(id: workerID, sessionID: workerSession, processID: 1234, processGroupID: 1234, lifecycle: .succeeded)],
                checkpointReferences: [checkpoint, .init(id: UUID(), workerID: workerID,
                    reference: "completed-report:report.txt", sha256: String(repeating: "b", count: 64))])
            _ = try await store.updateAgenticJob(runID: current.id, expectedRevision: 3, leaseToken: fixture.token,
                state: finished, now: fixture.at(8))
            _ = try await store.transitionRun(id: current.id, expectedRevision: journal.revision, token: fixture.token,
                event: .finish, now: fixture.at(9))
            saved = try #require(try await store.agenticJob(runID: current.id))
            history = try await store.agenticJobUpdates(runID: current.id, afterRevision: 0, limit: 100)
            #expect(history.map(\.revision) == [1, 2, 3, 4])
            #expect(history.map { $0.state.conversationGeneration } == [0, 1, 2, 2])
            #expect(try await store.query(sql: "SELECT id FROM work_runs;").count == 1)
        }
        #expect(closed == nil)
        let reopened = try fixture.open()
        #expect(try await reopened.agenticJob(runID: saved.id) == saved)
        #expect(saved.journal.state == .succeeded && saved.journal.lease == nil)
        #expect(try await reopened.agenticJobUpdates(runID: saved.id, afterRevision: 0, limit: 100) == history)
        #expect(try await reopened.agenticJobUpdates(runID: saved.id, afterRevision: 2, limit: 1) == [history[2]])
        #expect(try await reopened.agenticJobs(conversationID: fixture.conversationID, limit: 100) == [saved])
        #expect(try await reopened.agenticJobs(conversationID: ConversationID(UUID()), limit: 100).isEmpty)
        #expect(try await reopened.runInputs(id: saved.id, limit: 100).map(\.state) == [.queued, .acknowledged])
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await reopened.updateAgenticJob(runID: saved.id, expectedRevision: saved.revision,
                leaseToken: fixture.token, state: saved.state, now: fixture.at(10))
        }
    }

    @Test("Two connections cannot both win the same independent metadata revision")
    func concurrentMetadataCAS() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        let first = try fixture.open(), second = try fixture.open()
        let current = try await fixture.running(first)
        let stateA = AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: UUID())
        let stateB = AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: UUID())
        async let a = try? first.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token, state: stateA, now: fixture.at(3))
        async let b = try? second.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token, state: stateB, now: fixture.at(3))
        let results = await [a, b]
        #expect(results.compactMap { $0 }.count == 1)
        let winner = try #require(results.compactMap { $0 }.first)
        #expect(winner.revision == 2 && winner.journal.revision == current.journal.revision)
        #expect(try await first.agenticJob(runID: current.id) == winner)
        #expect(try await second.agenticJobUpdates(runID: current.id, afterRevision: 0, limit: 100).count == 2)
    }

    @Test("Lease, revision, generation, session reuse and run identity fence every metadata update")
    func updateFences() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        var current = try await fixture.running(store)
        let firstSession = UUID()
        let first = AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: firstSession)
        await #expect(throws: AgenticJobError.staleRevision) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 0, leaseToken: fixture.token, state: first, now: fixture.at(3))
        }
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: UUID(), state: first, now: fixture.at(3))
        }
        await #expect(throws: RunJournalError.leaseExpired) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token, state: first, now: fixture.at(31))
        }
        await #expect(throws: RunJournalError.clockMovedBackwards) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token, state: first, now: fixture.at(1))
        }
        await #expect(throws: AgenticJobError.invalidState) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token,
                state: AgenticJobState(runID: RunID(UUID()), conversationGeneration: 1, sessionID: UUID()), now: fixture.at(3))
        }
        current = try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token, state: first, now: fixture.at(3))
        for state in [AgenticJobState(runID: current.id),
                      AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: UUID()),
                      AgenticJobState(runID: current.id, conversationGeneration: 3, sessionID: UUID())] {
            await #expect(throws: AgenticJobError.staleGeneration) {
                try await store.updateAgenticJob(runID: current.id, expectedRevision: 2, leaseToken: fixture.token, state: state, now: fixture.at(4))
            }
        }
        current = try await store.updateAgenticJob(runID: current.id, expectedRevision: 2, leaseToken: fixture.token,
            state: AgenticJobState(runID: current.id, conversationGeneration: 2, sessionID: UUID()), now: fixture.at(5))
        await #expect(throws: AgenticJobError.staleGeneration) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 3, leaseToken: fixture.token,
                state: AgenticJobState(runID: current.id, conversationGeneration: 3, sessionID: firstSession), now: fixture.at(6))
        }
        await #expect(throws: RunJournalError.clockMovedBackwards) {
            try await store.updateAgenticJob(runID: current.id, expectedRevision: 3, leaseToken: fixture.token,
                state: current.state, now: fixture.at(4))
        }
        #expect(try await store.agenticJob(runID: current.id) == current)
    }

    @Test("Worker identity, lifecycle and checkpoint order survive redirects without allowing history rewrites")
    func retainedWorkerAndCheckpointFences() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        var current = try await fixture.running(store)
        let worker = AgenticJobWorker(id: UUID(), sessionID: UUID(), processID: 4321, processGroupID: 4321, lifecycle: .running)
        let checkpoint = AgenticJobCheckpoint(id: UUID(), workerID: worker.id, reference: "checkpoint:first", sha256: String(repeating: "a", count: 64))
        let sessionID = UUID()
        let state = AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
            workers: [worker], checkpointReferences: [checkpoint])
        current = try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token, state: state, now: fixture.at(3))
        let variants = [
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID),
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
                workers: [.init(id: worker.id, sessionID: worker.sessionID, processID: 9999, processGroupID: 9999, lifecycle: .running)], checkpointReferences: [checkpoint]),
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
                workers: [.init(id: worker.id, sessionID: worker.sessionID, processID: 4321, processGroupID: 4321, lifecycle: .starting)], checkpointReferences: [checkpoint]),
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
                workers: [worker], checkpointReferences: [.init(id: checkpoint.id, workerID: worker.id,
                    reference: "rewritten", sha256: checkpoint.sha256)])
        ]
        for changed in variants {
            await #expect(throws: AgenticJobError.invalidTransition) {
                try await store.updateAgenticJob(runID: current.id, expectedRevision: 2, leaseToken: fixture.token, state: changed, now: fixture.at(4))
            }
        }
        let malformed = [
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID, workers: [worker, worker]),
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
                workers: (0..<9).map { _ in .init(id: UUID(), sessionID: UUID()) }),
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
                workers: [worker], checkpointReferences: [.init(id: UUID(), workerID: UUID(), reference: "foreign", sha256: checkpoint.sha256)]),
            AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: sessionID,
                workers: [worker], checkpointReferences: [.init(id: UUID(), reference: "bad", sha256: "not-a-digest")])
        ]
        for malformedState in malformed {
            let decoded = try JSONDecoder().decode(AgenticJobState.self, from: JSONEncoder().encode(malformedState))
            await #expect(throws: AgenticJobError.invalidState) {
                try await store.updateAgenticJob(runID: current.id, expectedRevision: 2, leaseToken: fixture.token, state: decoded, now: fixture.at(4))
            }
        }
        #expect(try await store.agenticJob(runID: current.id) == current)
    }

    @Test("Malformed persisted envelopes and mismatched indexed session metadata fail closed", arguments: ["schema", "identity", "state", "session"])
    func persistedSnapshotRefusal(_ variant: String) async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        var current = try await fixture.running(store)
        current = try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token,
            state: AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: UUID()), now: fixture.at(3))
        let row = try #require(try await store.query(sql: "SELECT state_json FROM agentic_job_states WHERE revision=2;").first)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(try row.text("state_json").utf8)) as? [String: Any])
        if variant == "schema" { envelope["schemaVersion"] = 999 }
        else if variant == "identity" {
            envelope["teammateID"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TeammateID(UUID())), options: .fragmentsAllowed)
        } else if variant == "state" {
            envelope["state"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgenticJobState(runID: RunID(UUID()))))
        }
        if variant == "session" {
            _ = try await store.execute(sql: "UPDATE agentic_job_states SET session_id=? WHERE revision=2;", bindings: [.text(UUID().uuidString.lowercased())])
        } else {
            let json = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
            _ = try await store.execute(sql: "UPDATE agentic_job_states SET state_json=? WHERE revision=2;", bindings: [.text(String(decoding: json, as: UTF8.self))])
        }
        await #expect(throws: AgenticJobError.invalidState) { try await store.agenticJob(runID: current.id) }
        await #expect(throws: AgenticJobError.invalidState) { try await store.agenticJobUpdates(runID: current.id, afterRevision: 0, limit: 100) }
    }

    @Test("Migration twenty-one preserves prior checksums, messages, drafts and ordinary run behavior")
    func additiveMigrationAndNoRecoveryEffects() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        var checksums: [String] = []
        var ordinary: RunJournalRecord!
        let messageID: MessageID
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            let message = try await fixture.message(store)
            messageID = message.id
            ordinary = try await store.enqueueRun(fixture.request(message), origin: .executor)
            _ = try await store.saveDraft(conversationID: fixture.conversationID, text: "Retained draft", expectedRevision: 0, updatedAt: fixture.date)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=20 ORDER BY version;").map { try $0.text("checksum") }
            _ = try await store.execute(sql: "DROP TABLE agentic_job_states;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=21;")
        }
        let reopened = try fixture.open()
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=20 ORDER BY version;").map { try $0.text("checksum") } == checksums)
        #expect(try await reopened.message(id: messageID)?.id == messageID)
        #expect(try await reopened.loadDraft(conversationID: fixture.conversationID)?.text == "Retained draft")
        #expect(try await reopened.run(id: ordinary.id) == ordinary)
        #expect(try await reopened.agenticJob(runID: ordinary.id) == nil)
        #expect(try await reopened.agenticJobs(conversationID: fixture.conversationID, limit: 100).isEmpty)
        #expect(try await reopened.query(sql: "PRAGMA foreign_key_check;").isEmpty)
    }

    @Test("Reading an expired executor job preserves observations without claiming, resuming or fixture recovery")
    func expiredJobIsReadOnlyHistory() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        var saved: AgenticJobRecord!
        do {
            let store = try fixture.open()
            let current = try await fixture.running(store)
            saved = try await store.updateAgenticJob(runID: current.id, expectedRevision: 1, leaseToken: fixture.token,
                state: AgenticJobState(runID: current.id, conversationGeneration: 1, sessionID: UUID(),
                    workers: [.init(id: UUID(), sessionID: UUID(), processID: Int32.max, processGroupID: Int32.max, lifecycle: .running)]),
                now: fixture.at(3))
        }
        let reopened = try fixture.open()
        #expect(try await reopened.agenticJob(runID: saved.id) == saved)
        #expect(try await reopened.recoverExpiredLocalFixtures(conversationID: fixture.conversationID, now: fixture.at(1000), limit: 100).isEmpty)
        #expect(try await reopened.agenticJob(runID: saved.id) == saved)
        #expect(try await reopened.agenticJobUpdates(runID: saved.id, afterRevision: 0, limit: 100).count == 2)
        for limit in [0, 101] {
            await #expect(throws: AgenticJobError.invalidLimit) { try await reopened.agenticJobs(conversationID: fixture.conversationID, limit: limit) }
        }
    }
}

@Suite("Abandoned executor runs")
struct SQLiteAgenticJobRecoveryTests {
    @Test("An open executor run with a lapsed lease can be marked interrupted; live leases, fixtures and terminal runs cannot")
    func abandonedExecutorRecovery() async throws {
        let fixture = try AgenticPersistenceFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let current = try await fixture.running(store)
        // Lease still valid (30 s from at(1)).
        await #expect(throws: RunJournalError.leaseUnavailable) { try await store.recoverAbandonedExecutorRun(id: current.id, now: fixture.at(10)) }
        let recovered = try await store.recoverAbandonedExecutorRun(id: current.id, now: fixture.at(100))
        #expect(recovered.state == .interrupted && recovered.lease == nil)
        let entries = try await store.runEntries(id: current.id, afterSequence: 0, limit: 100)
        #expect(entries.last?.kind == .recovered)
        #expect(try await store.runInputs(id: current.id, limit: 10).allSatisfy { $0.state != .submitted })
        // Terminal now: a second recovery is refused, and the bot can take new work.
        await #expect(throws: RunJournalError.invalidTransition) { try await store.recoverAbandonedExecutorRun(id: current.id, now: fixture.at(101)) }
        // A local fixture run is never touched by executor recovery.
        let demo = try await store.enqueueRun(fixture.request(try await fixture.message(store, sequence: 2, text: "Demo")), origin: .localFixture)
        await #expect(throws: RunJournalError.invalidTransition) { try await store.recoverAbandonedExecutorRun(id: demo.id, now: fixture.at(200)) }
        _ = try await store.failUnclaimedLocalFixture(id: demo.id, expectedRevision: demo.revision, now: fixture.at(201))
        let next = try await store.createAgenticJob(request: fixture.request(try await fixture.message(store, sequence: 3, text: "Again")))
        #expect(next.journal.state == .queued)
    }
}

private struct AgenticPersistenceFixture: Sendable {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_000)
    let teammateID = TeammateID(UUID()), conversationID = ConversationID(UUID())
    let owner = UUID(), token = UUID()

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsAgenticJob-\(UUID()).noindex")
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func at(_ offset: TimeInterval) -> Date { date.addingTimeInterval(offset) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: receipt)))
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
    func message(_ store: SQLiteStore, sequence: Int64 = 1, text: String = "Original report request") async throws -> Message {
        let message = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: sequence,
            author: .user, deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: date, updatedAt: date)
        try await store.append(message, expectedPreviousSequence: sequence - 1)
        return message
    }
    func request(_ message: Message) throws -> WorkRequest {
        try WorkRequest(runID: RunID(UUID()), teammateID: teammateID, conversationID: conversationID,
            initiatingMessageID: message.id, profileRevision: 1,
            initialInput: WorkInput(messageID: message.id, sequence: 1,
                text: message.parts.compactMap { if case let .text(text) = $0.content { text } else { nil } }.joined()), submittedAt: date)
    }
    func running(_ store: SQLiteStore) async throws -> AgenticJobRecord {
        try await seed(store)
        let job = try await store.createAgenticJob(request: request(try await message(store)))
        _ = try await store.claimRun(id: job.id, expectedRevision: 1, ownerID: owner, token: token, now: at(1), leaseDuration: 30)
        _ = try await store.transitionRun(id: job.id, expectedRevision: 2, token: token, event: .started, now: at(2))
        return try #require(try await store.agenticJob(runID: job.id))
    }
}
