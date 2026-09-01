import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Durable run journal, lease fences and input receipts")
struct RunJournalRepositoryTests {
    @Test("Exact frozen requests and ordered journals survive true connection closure with protected files")
    func reopenAndPermissions() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        weak var closed: SQLiteStore?
        var saved: RunJournalRecord!
        var entries: [RunJournalEntry] = []
        do {
            let store = try f.open()
            closed = store
            try await f.seed(store)
            let message = try await f.message(store, text: " \tCafe\u{301}\0 exact bytes\n")
            let request = try f.request(message)
            let queued = try await store.enqueueRun(request, origin: .localFixture)
            #expect(queued.revision == 1 && queued.state == .queued && queued.lease == nil)
            let claimed = try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
            #expect(claimed.state == .starting && claimed.lease?.generation == 1)
            saved = try await store.transitionRun(id: queued.id, expectedRevision: 2, token: f.token, event: .started, now: f.at(2))
            #expect(saved.request.initialInput.text.utf8.elementsEqual(request.initialInput.text.utf8))
            entries = try await store.runEntries(id: queued.id, afterSequence: 0, limit: 100)
            #expect(entries.map(\.kind) == [.enqueued, .claimed, .stateChanged])
            #expect(entries.map(\.sequence) == [1, 2, 3])
            for suffix in ["", "-wal", "-shm"] {
                let attributes = try FileManager.default.attributesOfItem(atPath: f.databaseURL.path + suffix)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            let columns = try await store.query(sql: "PRAGMA table_info(run_journal_entries);")
            #expect(try columns.map { try $0.text("name") } == ["run_id", "sequence", "kind", "state", "input_message_id", "recorded_at"])
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.run(id: saved.id) == saved)
        #expect(try await reopened.runEntries(id: saved.id, afterSequence: 0, limit: 100) == entries)
        #expect(try await reopened.runInputs(id: saved.id, limit: 100).map(\.state) == [.queued])
        #expect(try await reopened.runs(conversationID: f.conversationID, limit: 100) == [saved])
    }

    @Test("Only one of two independent connections can claim a queued run")
    func simultaneousClaim() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let first = try f.open(), second = try f.open()
        try await f.seed(first)
        let request = try f.request(try await f.message(first))
        _ = try await first.enqueueRun(request, origin: .localFixture)
        async let a = try? first.claimRun(id: request.runID, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
        async let b = try? second.claimRun(id: request.runID, expectedRevision: 1, ownerID: UUID(), token: UUID(), now: f.at(1), leaseDuration: 30)
        let results = await [a, b]
        #expect(results.compactMap { $0 }.count == 1)
        let winner = try #require(results.compactMap { $0 }.first)
        #expect(try await first.run(id: request.runID) == winner)
        #expect(try await second.runEntries(id: request.runID, afterSequence: 0, limit: 100).count == 2)
        await #expect(throws: RunJournalError.staleRevision) {
            try await second.claimRun(id: request.runID, expectedRevision: 1, ownerID: UUID(), token: UUID(), now: f.at(2), leaseDuration: 30)
        }
    }

    @Test("One active run per teammate; explicit new fixture after terminal may reuse the saved message")
    func activeRunAndExplicitNewAttempt() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let message = try await f.message(store)
        let request = try f.request(message)
        _ = try await store.enqueueRun(request, origin: .localFixture)
        await #expect(throws: RunJournalError.conflictingActiveRun) { try await store.enqueueRun(f.request(message), origin: .executor) }
        _ = try await store.failUnclaimedLocalFixture(id: request.runID, expectedRevision: 1, now: f.at(1))
        let second = try await store.enqueueRun(f.request(message, submittedAt: f.at(2)), origin: .localFixture)
        #expect(second.id != request.runID && second.state == .queued)
        await #expect(throws: RunJournalError.conflictingActiveRun) { try await store.enqueueRun(second.request, origin: .localFixture) }
        _ = try await store.failUnclaimedLocalFixture(id: second.id, expectedRevision: 1, now: f.at(3))
        await #expect(throws: RunJournalError.invalidRequest) { try await store.enqueueRun(request, origin: .localFixture) }
        #expect(try await store.runs(conversationID: f.conversationID, limit: 1).map(\.id) == [second.id])
    }

    @Test("Foreign tokens, stale revisions, expired leases and clock rollback cannot mutate runs")
    func leaseAndClockFences() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        let running = try await f.running(store)
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await store.renewRunLease(id: running.id, expectedRevision: 3, token: UUID(), now: f.at(3), leaseDuration: 30)
        }
        await #expect(throws: RunJournalError.staleRevision) {
            try await store.transitionRun(id: running.id, expectedRevision: 2, token: f.token, event: .finish, now: f.at(3))
        }
        await #expect(throws: RunJournalError.clockMovedBackwards) {
            try await store.transitionRun(id: running.id, expectedRevision: 3, token: f.token, event: .finish, now: f.at(1))
        }
        await #expect(throws: RunJournalError.leaseExpired) {
            try await store.renewRunLease(id: running.id, expectedRevision: 3, token: f.token, now: f.at(31), leaseDuration: 30)
        }
        await #expect(throws: RunJournalError.invalidRequest) {
            try await store.renewRunLease(id: running.id, expectedRevision: 3, token: f.token, now: Date(timeIntervalSince1970: .infinity), leaseDuration: 30)
        }
        for duration in [0, 0.5, 301, Double.infinity, Double.nan] {
            await #expect(throws: RunJournalError.invalidLeaseDuration) {
                try await store.renewRunLease(id: running.id, expectedRevision: 3, token: f.token, now: f.at(3), leaseDuration: duration)
            }
        }
        #expect(try await store.run(id: running.id) == running)
        let renewed = try await store.renewRunLease(id: running.id, expectedRevision: 3, token: f.token, now: f.at(3), leaseDuration: 300)
        #expect(renewed.revision == 4 && renewed.lease?.generation == 1 && renewed.lease?.expiresAt == f.at(303))
        await #expect(throws: RunJournalError.staleRevision) {
            try await store.renewRunLease(id: running.id, expectedRevision: 3, token: f.token, now: f.at(4), leaseDuration: 300)
        }
    }

    @Test("State transitions and input receipts do not conflate queued, submitted and acknowledged")
    func orderedInputTransitions() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        var current = try await f.running(store)
        let firstID = current.request.initiatingMessageID
        await #expect(throws: RunJournalError.invalidInputTransition) {
            try await store.markRunInput(id: current.id, expectedRevision: current.revision, token: f.token, messageID: firstID, sequence: 1, state: .acknowledged, now: f.at(3))
        }
        await #expect(throws: RunJournalError.invalidTransition) {
            try await store.transitionRun(id: current.id, expectedRevision: current.revision, token: f.token, event: .started, now: f.at(3))
        }
        current = try await store.markRunInput(id: current.id, expectedRevision: current.revision, token: f.token, messageID: firstID, sequence: 1, state: .submitted, now: f.at(3))
        current = try await store.markRunInput(id: current.id, expectedRevision: current.revision, token: f.token, messageID: firstID, sequence: 1, state: .acknowledged, now: f.at(4))
        await #expect(throws: RunJournalError.invalidInputTransition) {
            try await store.markRunInput(id: current.id, expectedRevision: current.revision, token: f.token, messageID: firstID, sequence: 1, state: .acknowledged, now: f.at(5))
        }
        current = try await store.transitionRun(id: current.id, expectedRevision: current.revision, token: f.token, event: .waitForUser, now: f.at(5))
        let second = try await f.message(store, sequence: 2, text: "second exact input")
        let input = try f.steering(second, sequence: 2, submittedAt: f.at(6))
        current = try await store.queueRunInput(id: current.id, expectedRevision: current.revision, token: f.token, input: input, now: f.at(6))
        await #expect(throws: RunJournalError.inputMismatch) {
            try await store.queueRunInput(id: current.id, expectedRevision: current.revision, token: f.token, input: input, now: f.at(7))
        }
        await #expect(throws: RunJournalError.inputUnavailable) {
            try await store.markRunInput(id: current.id, expectedRevision: current.revision, token: f.token, messageID: second.id, sequence: 1, state: .submitted, now: f.at(7))
        }
        current = try await store.markRunInput(id: current.id, expectedRevision: current.revision, token: f.token, messageID: second.id, sequence: 2, state: .submitted, now: f.at(7))
        #expect(try await store.runInputs(id: current.id, limit: 100).map(\.state) == [.acknowledged, .submitted])
        let entries = try await store.runEntries(id: current.id, afterSequence: 3, limit: 100)
        #expect(entries.map(\.sequence) == [4, 5, 6, 7, 8])
        #expect(entries.map(\.kind) == [.inputSubmitted, .inputAcknowledged, .stateChanged, .inputQueued, .inputSubmitted])
        #expect(entries.last?.inputMessageID == second.id)
        current = try await store.transitionRun(id: current.id, expectedRevision: current.revision, token: f.token, event: .interrupt, now: f.at(8))
        #expect(current.state == .interrupted && current.lease == nil)
        #expect(try await store.runInputs(id: current.id, limit: 100).map(\.state) == [.acknowledged, .outcomeUnknown])
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await store.transitionRun(id: current.id, expectedRevision: current.revision, token: f.token, event: .resume, now: f.at(9))
        }
    }

    @Test("Stopping refuses new submission but can record acknowledgement of already-submitted input")
    func stoppingSubmissionFence() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        var current = try await f.running(store)
        let firstID = current.request.initiatingMessageID
        current = try await store.markRunInput(id: current.id, expectedRevision: 3, token: f.token,
            messageID: firstID, sequence: 1, state: .submitted, now: f.at(3))
        let second = try await f.message(store, sequence: 2)
        current = try await store.queueRunInput(id: current.id, expectedRevision: 4, token: f.token,
            input: f.steering(second, sequence: 2, submittedAt: f.at(4)), now: f.at(4))
        current = try await store.transitionRun(id: current.id, expectedRevision: 5, token: f.token, event: .requestStop, now: f.at(5))
        await #expect(throws: RunJournalError.invalidTransition) {
            try await store.markRunInput(id: current.id, expectedRevision: 6, token: f.token,
                messageID: second.id, sequence: 2, state: .submitted, now: f.at(6))
        }
        #expect(try await store.runInputs(id: current.id, limit: 100).map(\.state) == [.submitted, .queued])
        current = try await store.markRunInput(id: current.id, expectedRevision: 6, token: f.token,
            messageID: firstID, sequence: 1, state: .acknowledged, now: f.at(6))
        #expect(current.state == .stopping && current.revision == 7)
        #expect(try await store.runInputs(id: current.id, limit: 100).map(\.state) == [.acknowledged, .queued])
    }

    @Test("New input must match a saved same-conversation user message and cannot reuse an earlier input")
    func exactInputAndScope() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        let current = try await f.running(store)
        let second = try await f.message(store, sequence: 2, text: "exact next")
        let foreignOwner = TeammateID(UUID()), foreignConversation = ConversationID(UUID())
        try await f.seed(store, teammateID: foreignOwner, conversationID: foreignConversation)
        let foreign = try await f.message(store, conversationID: foreignConversation, text: "exact next")
        for input in [
            try SteeringInput(messageID: second.id, sequence: 2, text: "wrong text", submittedAt: f.at(3)),
            try f.steering(foreign, sequence: 2, submittedAt: f.at(3)),
            try SteeringInput(messageID: current.request.initiatingMessageID, sequence: 2, text: current.request.initialInput.text, submittedAt: f.at(3)),
            try f.steering(second, sequence: 3, submittedAt: f.at(3)),
        ] {
            await #expect(throws: RunJournalError.inputMismatch) {
                try await store.queueRunInput(id: current.id, expectedRevision: current.revision, token: f.token, input: input, now: f.at(3))
            }
        }
        #expect(try await store.run(id: current.id) == current)
        #expect(try await store.runInputs(id: current.id, limit: 100).count == 1)
    }

    @Test("Initial input validates exact text parts and attachment order, user authorship and current profile")
    func enqueueValidation() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let a = try f.asset(), b = try f.asset()
        _ = try await store.stage(a)
        _ = try await store.stage(b)
        let message = try await f.message(store, contents: [.text("hello"), .text("\0world"), .attachment(a.id), .attachment(b.id)])
        let valid = try f.request(message)
        for input in [
            try WorkInput(messageID: message.id, sequence: 1, text: "hello world", attachmentIDs: [a.id, b.id]),
            try WorkInput(messageID: message.id, sequence: 1, text: "hello\0world", attachmentIDs: [b.id, a.id]),
            try WorkInput(messageID: message.id, sequence: 1, text: "hello\0world", attachmentIDs: [a.id, a.id]),
        ] {
            let request = try WorkRequest(runID: RunID(UUID()), teammateID: f.teammateID, conversationID: f.conversationID,
                initiatingMessageID: message.id, profileRevision: 1, initialInput: input, submittedAt: f.date)
            await #expect(throws: RunJournalError.inputMismatch) { try await store.enqueueRun(request, origin: .localFixture) }
        }
        let wrongProfile = try f.request(message, profileRevision: 2)
        await #expect(throws: RunJournalError.invalidRequest) { try await store.enqueueRun(wrongProfile, origin: .localFixture) }
        let assistant = try await f.message(store, sequence: 2, author: .teammate(f.teammateID))
        await #expect(throws: RunJournalError.inputMismatch) { try await store.enqueueRun(f.request(assistant), origin: .localFixture) }
        let queued = try await store.enqueueRun(valid, origin: .localFixture)
        #expect(queued.request.initialInput.text.utf8.elementsEqual("hello\0world".utf8))
        #expect(queued.request.initialInput.attachmentIDs == [a.id, b.id])
    }

    @Test("Saved context and active memberships are checked at enqueue, claim and new input")
    func contextFences() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let message = try await f.message(store)
        let projectID = ProjectID(UUID())
        try await store.insert(Project(id: projectID, name: "Scoped project", createdAt: f.date, updatedAt: f.date))
        try await store.setMembership(ProjectMembership(projectID: projectID, teammateID: f.teammateID, joinedAt: f.date))
        await #expect(throws: RunJournalError.invalidRequest) { try await store.enqueueRun(f.request(message, projectID: projectID), origin: .localFixture) }
        _ = try await store.saveContext(ConversationContextSelection(conversationID: f.conversationID, teammateID: f.teammateID, projectID: projectID))
        await #expect(throws: RunJournalError.invalidRequest) { try await store.enqueueRun(f.request(message), origin: .localFixture) }
        let queued = try await store.enqueueRun(f.request(message, projectID: projectID), origin: .localFixture)
        _ = try await store.execute(sql: "UPDATE project_memberships SET revoked_at=1001;")
        await #expect(throws: RunJournalError.invalidRequest) {
            try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
        }
        _ = try await store.execute(sql: "UPDATE project_memberships SET revoked_at=NULL;")
        _ = try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
        let current = try await store.transitionRun(id: queued.id, expectedRevision: 2, token: f.token, event: .started, now: f.at(2))
        let second = try await f.message(store, sequence: 2)
        _ = try await store.execute(sql: "UPDATE projects SET lifecycle='archived';")
        await #expect(throws: RunJournalError.invalidRequest) {
            try await store.queueRunInput(id: current.id, expectedRevision: 3, token: f.token, input: f.steering(second, sequence: 2, submittedAt: f.at(3)), now: f.at(3))
        }
        #expect(try await store.transitionRun(id: current.id, expectedRevision: 3, token: f.token, event: .fail, now: f.at(3)).state == .failed)
    }

    @Test("Archived or detached ownership blocks claim but does not prevent explicit terminal repair", arguments: ["teammate", "conversation", "participant", "profile"])
    func ownerFences(kind: String) async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let request = try f.request(try await f.message(store))
        let queued = try await store.enqueueRun(request, origin: .localFixture)
        let sql: String
        switch kind {
        case "teammate": sql = "UPDATE teammates SET lifecycle='archived';"
        case "conversation": sql = "UPDATE conversations SET lifecycle='archived';"
        case "participant": sql = "UPDATE conversation_participants SET left_at=1001;"
        default: sql = "UPDATE teammates SET profile_revision=2;"
        }
        _ = try await store.execute(sql: sql)
        await #expect(throws: RunJournalError.invalidRequest) {
            try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
        }
        let failed = try await store.failUnclaimedLocalFixture(id: queued.id, expectedRevision: 1, now: f.at(2))
        #expect(failed.state == .failed && failed.lease == nil)
        #expect(try await store.runInputs(id: queued.id, limit: 100).map(\.state) == [.queued])
    }

    @Test("Only expired leased local fixtures are recovered, never executor, queued, unexpired or another conversation")
    func recoveryScopeAndReceipts() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        var current = try await f.running(store)
        current = try await store.markRunInput(id: current.id, expectedRevision: 3, token: f.token, messageID: current.request.initiatingMessageID, sequence: 1, state: .submitted, now: f.at(3))
        current = try await store.markRunInput(id: current.id, expectedRevision: 4, token: f.token, messageID: current.request.initiatingMessageID, sequence: 1, state: .acknowledged, now: f.at(4))
        let second = try await f.message(store, sequence: 2)
        current = try await store.queueRunInput(id: current.id, expectedRevision: 5, token: f.token, input: f.steering(second, sequence: 2, submittedAt: f.at(5)), now: f.at(5))
        current = try await store.markRunInput(id: current.id, expectedRevision: 6, token: f.token, messageID: second.id, sequence: 2, state: .submitted, now: f.at(6))
        let third = try await f.message(store, sequence: 3)
        current = try await store.queueRunInput(id: current.id, expectedRevision: 7, token: f.token, input: f.steering(third, sequence: 3, submittedAt: f.at(7)), now: f.at(7))
        #expect(try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(30), limit: 100).isEmpty)
        #expect(try await store.recoverExpiredLocalFixtures(conversationID: ConversationID(UUID()), now: f.at(40), limit: 100).isEmpty)
        _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived';")
        let recovered = try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(31), limit: 1)
        #expect(recovered.count == 1 && recovered[0].state == .interrupted && recovered[0].lease == nil && recovered[0].revision == 9)
        #expect(try await store.runInputs(id: current.id, limit: 100).map(\.state) == [.acknowledged, .outcomeUnknown, .queued])
        #expect(try await store.runEntries(id: current.id, afterSequence: 8, limit: 100).map(\.kind) == [.recovered])
        #expect(try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(40), limit: 100).isEmpty)

        for origin in [RunOrigin.localFixture, .executor] {
            let owner = TeammateID(UUID()), conversation = ConversationID(UUID())
            try await f.seed(store, teammateID: owner, conversationID: conversation)
            let message = try await f.message(store, conversationID: conversation)
            let queued = try await store.enqueueRun(f.request(message, teammateID: owner), origin: origin)
            #expect(try await store.recoverExpiredLocalFixtures(conversationID: conversation, now: f.at(40), limit: 100).isEmpty)
            if origin == .executor {
                await #expect(throws: RunJournalError.invalidTransition) {
                    try await store.failUnclaimedLocalFixture(id: queued.id, expectedRevision: 1, now: f.at(1))
                }
                let claimed = try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: UUID(), now: f.at(1), leaseDuration: 1)
                #expect(try await store.recoverExpiredLocalFixtures(conversationID: conversation, now: f.at(40), limit: 100).isEmpty)
                #expect(try await store.run(id: queued.id) == claimed)
                await #expect(throws: RunJournalError.invalidTransition) { try await store.failUnclaimedLocalFixture(id: queued.id, expectedRevision: 2, now: f.at(40)) }
            }
        }
    }

    @Test("Claim, receipt and terminal changes roll back when journal append fails")
    func atomicRollback() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let queued = try await store.enqueueRun(f.request(try await f.message(store)), origin: .localFixture)
        _ = try await store.execute(sql: "CREATE TRIGGER reject_run_entry BEFORE INSERT ON run_journal_entries WHEN NEW.sequence>1 BEGIN SELECT RAISE(ABORT,'injected journal failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
        }
        #expect(try await store.run(id: queued.id) == queued)
        _ = try await store.execute(sql: "DROP TRIGGER reject_run_entry;")
        let claimed = try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 30)
        let running = try await store.transitionRun(id: claimed.id, expectedRevision: 2, token: f.token, event: .started, now: f.at(2))
        _ = try await store.execute(sql: "CREATE TRIGGER reject_run_entry BEFORE INSERT ON run_journal_entries BEGIN SELECT RAISE(ABORT,'injected journal failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.markRunInput(id: claimed.id, expectedRevision: 3, token: f.token, messageID: queued.request.initiatingMessageID, sequence: 1, state: .submitted, now: f.at(3))
        }
        #expect(try await store.run(id: queued.id) == running)
        #expect(try await store.runInputs(id: queued.id, limit: 100).map(\.state) == [.queued])
    }

    @Test("Malformed snapshots, enums, journal gaps and raw work runs are not silently accepted")
    func malformedAndUnadoptedRows() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let queued = try await store.enqueueRun(f.request(try await f.message(store)), origin: .localFixture)
        let row = try #require(try await store.query(sql: "SELECT request_json FROM run_journal_metadata;").first)
        let original = try row.text("request_json")
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json='{}';")
        await #expect(throws: RunJournalError.invalidRequest) { try await store.run(id: queued.id) }
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json=?;", bindings: [.text(original)])
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=ON;")
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET origin='pretend';")
        await #expect(throws: RunJournalError.invalidRequest) { try await store.run(id: queued.id) }
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET origin='localFixture';")
        _ = try await store.execute(sql: "UPDATE run_input_receipts SET state='pretend';")
        await #expect(throws: RunJournalError.invalidRequest) { try await store.runInputs(id: queued.id, limit: 100) }
        _ = try await store.execute(sql: "UPDATE run_input_receipts SET state='queued';")
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET revision=2;")
        await #expect(throws: RunJournalError.invalidRequest) { try await store.run(id: queued.id) }
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET revision=1;")
        _ = try await store.execute(sql: "DELETE FROM run_journal_metadata;")
        await #expect(throws: RunJournalError.unavailable) { try await store.run(id: queued.id) }
        #expect(try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(40), limit: 100).isEmpty)
    }

    @Test("Limits, oversized inputs and revision overflow fail without partial state")
    func boundsAndOverflow() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        let store = try f.open()
        let current = try await f.running(store)
        for limit in [0, -1, 101, Int.max] {
            await #expect(throws: RunJournalError.invalidLimit) { try await store.runs(conversationID: f.conversationID, limit: limit) }
            await #expect(throws: RunJournalError.invalidLimit) { try await store.runInputs(id: current.id, limit: limit) }
            await #expect(throws: RunJournalError.invalidLimit) { try await store.runEntries(id: current.id, afterSequence: 0, limit: limit) }
            await #expect(throws: RunJournalError.invalidLimit) { try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(40), limit: limit) }
        }
        await #expect(throws: RunJournalError.invalidLimit) { try await store.runEntries(id: current.id, afterSequence: Int64.max, limit: 1) }
        let huge = try SteeringInput(messageID: MessageID(UUID()), sequence: 2, text: String(repeating: "x", count: 1_024 * 1_024 + 1), submittedAt: f.at(3))
        await #expect(throws: RunJournalError.inputMismatch) { try await store.queueRunInput(id: current.id, expectedRevision: 3, token: f.token, input: huge, now: f.at(3)) }
        let second = try await f.message(store, sequence: 2)
        _ = try await store.queueRunInput(id: current.id, expectedRevision: 3, token: f.token, input: f.steering(second, sequence: 2, submittedAt: f.at(3)), now: f.at(3))
        _ = try await store.execute(sql: "UPDATE run_input_receipts SET sequence=? WHERE sequence=2;", bindings: [.integer(Int64.max)])
        let third = try await f.message(store, sequence: 3)
        await #expect(throws: RunJournalError.revisionExhausted) {
            try await store.queueRunInput(id: current.id, expectedRevision: 4, token: f.token,
                input: f.steering(third, sequence: Int64.max, submittedAt: f.at(4)), now: f.at(4))
        }
        _ = try await store.execute(sql: "UPDATE run_input_receipts SET sequence=2 WHERE sequence=?;", bindings: [.integer(Int64.max)])
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET revision=?;", bindings: [.integer(Int64.max)])
        _ = try await store.execute(sql: "UPDATE run_journal_entries SET sequence=? WHERE sequence=4;", bindings: [.integer(Int64.max)])
        await #expect(throws: RunJournalError.revisionExhausted) {
            try await store.transitionRun(id: current.id, expectedRevision: Int64.max, token: f.token, event: .fail, now: f.at(4))
        }
        #expect(try await store.run(id: current.id)?.revision == Int64.max)
    }

    @Test("Migration eleven preserves migration ten rows and checksums without adopting raw runs")
    func migrationTenPreserved() async throws {
        let f = try RunJournalFixture()
        defer { f.remove() }
        var checksums: [String] = []
        let messageID: MessageID
        do {
            let store = try f.open()
            try await f.seed(store)
            messageID = try await f.message(store).id
            _ = try await store.saveDraft(conversationID: f.conversationID, text: "saved draft", expectedRevision: 0, updatedAt: f.date)
            let asset = try f.asset()
            _ = try await store.stage(asset)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=10 ORDER BY version;").map { try $0.text("checksum") }
            for table in ["run_journal_entries", "run_input_receipts", "run_journal_metadata"] {
                _ = try await store.execute(sql: "DROP TABLE \(table);")
            }
            _ = try await store.execute(sql: "DROP INDEX run_journal_owner_active;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=11;")
        }
        let reopened = try f.open()
        #expect(try await reopened.message(id: messageID)?.id == messageID)
        #expect(try await reopened.loadDraft(conversationID: f.conversationID)?.text == "saved draft")
        #expect(try await reopened.draft(conversationID: f.conversationID).attachments.count == 1)
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=10 ORDER BY version;").map { try $0.text("checksum") } == checksums)
        #expect(try await reopened.query(sql: "SELECT version FROM schema_migrations WHERE version=11;").count == 1)
        #expect(try await reopened.runs(conversationID: f.conversationID, limit: 100).isEmpty)
    }
}

private struct RunJournalFixture: Sendable {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_000)
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let owner = UUID(), token = UUID()
    var databaseURL: URL { directory.appendingPathComponent("control.sqlite") }

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextRunJournal-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: databaseURL, protection: .ordinarySQLite(decision: receipt)))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func at(_ offset: TimeInterval) -> Date { date.addingTimeInterval(offset) }

    func seed(_ store: SQLiteStore, teammateID: TeammateID? = nil, conversationID: ConversationID? = nil) async throws {
        let id = teammateID ?? self.teammateID
        let teammate = try Teammate(id: id, profile: TeammateProfile(displayName: "Journal Partner", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID ?? self.conversationID, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }

    func message(_ store: SQLiteStore, conversationID: ConversationID? = nil, sequence: Int64 = 1,
                 text: String = "Saved user request", author: MessageAuthor = .user,
                 contents: [MessagePartContent]? = nil) async throws -> Message {
        let message = try Message(id: MessageID(UUID()), conversationID: conversationID ?? self.conversationID,
            sequence: sequence, author: author, deliveryState: .completed,
            parts: (contents ?? [.text(text)]).enumerated().map { try MessagePart(id: MessagePartID(UUID()), ordinal: $0.offset, content: $0.element) },
            createdAt: date, updatedAt: date)
        try await store.append(message, expectedPreviousSequence: sequence - 1)
        return message
    }

    func request(_ message: Message, teammateID: TeammateID? = nil, projectID: ProjectID? = nil,
                 profileRevision: UInt64 = 1, submittedAt: Date? = nil) throws -> WorkRequest {
        try WorkRequest(runID: RunID(UUID()), teammateID: teammateID ?? self.teammateID, conversationID: message.conversationID,
            initiatingMessageID: message.id, selectedProjectID: projectID, profileRevision: profileRevision,
            initialInput: WorkInput(messageID: message.id, sequence: 1,
                text: message.parts.compactMap { if case let .text(text) = $0.content { text } else { nil } }.joined(),
                attachmentIDs: message.parts.compactMap { if case let .attachment(id) = $0.content { id } else { nil } }), submittedAt: submittedAt ?? date)
    }

    func steering(_ message: Message, sequence: Int64, submittedAt: Date) throws -> SteeringInput {
        try SteeringInput(messageID: message.id, sequence: sequence,
            text: message.parts.compactMap { if case let .text(text) = $0.content { text } else { nil } }.joined(),
            attachmentIDs: message.parts.compactMap { if case let .attachment(id) = $0.content { id } else { nil } }, submittedAt: submittedAt)
    }

    func running(_ store: SQLiteStore) async throws -> RunJournalRecord {
        try await seed(store)
        let queued = try await store.enqueueRun(request(try await message(store)), origin: .localFixture)
        _ = try await store.claimRun(id: queued.id, expectedRevision: 1, ownerID: owner, token: token, now: at(1), leaseDuration: 30)
        return try await store.transitionRun(id: queued.id, expectedRevision: 2, token: token, event: .started, now: at(2))
    }

    func asset() throws -> AttachmentAsset {
        try AttachmentAsset(id: AttachmentID(UUID()), conversationID: conversationID, displayName: "notes.txt", typeIdentifier: "public.data",
                            byteCount: 12, sha256: String(repeating: "a", count: 64), createdAt: date)
    }
}
