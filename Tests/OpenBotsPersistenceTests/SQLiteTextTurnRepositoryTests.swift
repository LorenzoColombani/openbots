import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing

@Suite("Atomic text replies and bounded recovery")
struct SQLiteTextTurnRepositoryTests {
    @Test("Frozen text, stable partial reply and terminal outcome survive actual connection closure")
    func durableSnapshots() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let turn = try f.turn(text: " \tCafe\u{301}\0 exact input\n")
        var saved: TextTurnSnapshot!
        weak var closed: SQLiteStore?
        do {
            let store = try f.open()
            closed = store
            try await f.seed(store)
            var current = try await f.begin(store, turn)
            #expect(current.run.origin == .executor && current.run.state == .starting && current.run.revision == 2)
            #expect(current.replyText.isEmpty && current.inputState == .queued)
            current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "", inputEvidence: .submitted, now: f.at(1))
            saved = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Partial", inputEvidence: .acknowledged, now: f.at(2))
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [saved])
        let user = try #require(try await reopened.message(id: turn.message.id))
        #expect(user.parts[0].content == turn.message.parts[0].content)
        #expect(user.deliveryState == .acknowledged)
        let replyID = try #require(turn.request.textTurnIdentity).replyMessageID
        #expect(try await reopened.message(id: replyID)?.parts[0].content == .text("Partial"))
        let done = try await reopened.finishTextTurn(id: saved.run.id, expectedRevision: saved.run.revision,
            token: f.token, text: "Partial reply completed.", outcome: .succeeded, now: f.at(3))
        #expect(done.run.state == .succeeded && done.run.lease == nil && done.replyText == "Partial reply completed.")
        #expect(try await reopened.message(id: replyID)?.deliveryState == .completed)
        #expect(try await reopened.message(id: user.id)?.deliveryState == .completed)
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        let indexed = try await reopened.query(sql: "SELECT body FROM conversation_message_search WHERE message_id=?;",
            bindings: [.text(replyID.persistedValue)])
        #expect(try indexed.first?.text("body") == "Partial reply completed.")
        let outcomes = try await reopened.outcomeHistory(ConversationOutcomeHistoryRequest(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(outcomes.records.first?.event == .run(id: done.run.id, origin: .executor, state: .succeeded,
            hasUnconfirmedInput: false, hasUnknownInput: false))
    }

    @Test("Every checkpoint carries the lease forward, so a long reply outlives the lease it began with")
    func checkpointsRenewTheLease() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        // Begun with a sixty-second lease.
        var current = try await f.begin(store, turn)
        #expect(current.run.lease?.expiresAt == f.at(60))
        // A checkpoint inside it moves the expiry to its own time plus the
        // text-turn span, keeping the lease's identity.
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(50))
        #expect(current.run.lease?.expiresAt == f.at(230))
        #expect(current.run.lease?.generation == 1 && current.run.lease?.token == f.token && current.run.lease?.ownerID == f.owner)
        // A checkpoint after the original lease would have lapsed still lands,
        // and renews again.
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Still writing", inputEvidence: .acknowledged, now: f.at(200))
        #expect(current.run.lease?.expiresAt == f.at(380))
        // A write that arrives after the renewed lease has run out is refused,
        // as it always was: the lease is proof of a live process, not a favour.
        await #expect(throws: RunJournalError.leaseExpired) {
            _ = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Still writing more", inputEvidence: .none, now: f.at(381))
        }
        // The finish inside the renewed lease succeeds.
        let done = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Still writing, done.", outcome: .succeeded, now: f.at(379))
        #expect(done.run.state == .succeeded && done.run.lease == nil && done.replyText == "Still writing, done.")
    }

    @Test("Claim failure rolls back user, assistant, receipt and run as one aggregate")
    func atomicBegin() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        _ = try await store.execute(sql: "CREATE TRIGGER reject_text_claim BEFORE INSERT ON run_journal_entries WHEN NEW.sequence=2 BEGIN SELECT RAISE(ABORT,'claim failure'); END;")
        await #expect(throws: SQLiteStoreError.self) { try await f.begin(store, turn) }
        #expect(try await store.message(id: turn.message.id) == nil)
        #expect(try await store.message(id: #require(turn.request.textTurnIdentity).replyMessageID) == nil)
        #expect(try await store.query(sql: "SELECT id FROM work_runs;").isEmpty)
        #expect(try await store.query(sql: "SELECT run_id FROM run_input_receipts;").isEmpty)
        _ = try await store.execute(sql: "DROP TRIGGER reject_text_claim;")
        let current = try await f.begin(store, turn)
        let second = try f.turn(sequence: 3)
        await #expect(throws: RunJournalError.conflictingActiveRun) { try await f.begin(store, second) }
        #expect(try await store.message(id: second.message.id) == nil)
        #expect(try await store.run(id: current.run.id) == current.run)
    }

    @Test("Only explicit input evidence advances delivery and success requires a saved acknowledged reply")
    func inputEvidenceAndFailure() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        var current = try await f.begin(store, turn)
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "", inputEvidence: .acknowledged, now: f.at(1))
        }
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "invented completion", outcome: .succeeded, now: f.at(1))
        }
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Partial", inputEvidence: .submitted, now: f.at(1))
        let failed = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Partial", outcome: .failed, now: f.at(2))
        #expect(failed.run.state == .failed && failed.inputState == .outcomeUnknown && failed.replyText == "Partial")
        #expect(try await store.message(id: turn.message.id)?.deliveryState == .failed)
        #expect(try await store.message(id: #require(turn.request.textTurnIdentity).replyMessageID)?.deliveryState == .failed)
    }

    @Test("Stale revisions, foreign tokens, lost prefixes and terminal callbacks cannot alter saved text")
    func callbackFences() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        var current = try await f.begin(store, f.turn())
        let initialRevision = current.run.revision
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Saved", inputEvidence: .submitted, now: f.at(1))
        await #expect(throws: RunJournalError.staleRevision) {
            try await store.checkpointTextTurn(id: current.run.id, expectedRevision: initialRevision,
                token: f.token, text: "Saved stale", inputEvidence: .none, now: f.at(2))
        }
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: UUID(), text: "Saved foreign", inputEvidence: .none, now: f.at(2))
        }
        await #expect(throws: TextTurnRepositoryError.invalidReply) {
            try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "replacement", inputEvidence: .none, now: f.at(2))
        }
        let ended = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Saved", outcome: .interrupted, now: f.at(2))
        await #expect(throws: RunJournalError.leaseUnavailable) {
            try await store.checkpointTextTurn(id: ended.run.id, expectedRevision: ended.run.revision,
                token: f.token, text: "Saved late", inputEvidence: .none, now: f.at(3))
        }
        #expect(try await store.run(id: ended.run.id) == ended.run)
    }

    @Test("A terminal journal failure rolls back the final text and both delivery states")
    func atomicFinish() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        var current = try await f.begin(store, turn)
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Saved", inputEvidence: .submitted, now: f.at(1))
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Saved", inputEvidence: .acknowledged, now: f.at(2))
        _ = try await store.execute(sql: "CREATE TRIGGER reject_text_terminal BEFORE INSERT ON run_journal_entries WHEN NEW.state='succeeded' BEGIN SELECT RAISE(ABORT,'terminal failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Saved final", outcome: .succeeded, now: f.at(3))
        }
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [current])
        #expect(try await store.message(id: turn.message.id)?.deliveryState == .acknowledged)
        #expect(try await store.message(id: #require(turn.request.textTurnIdentity).replyMessageID)?.parts[0].content == .text("Saved"))
    }

    @Test("Recovery requires matching app and process owners and never adopts ordinary executor rows")
    func recoveryBoundary() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        var current = try await f.begin(store, turn)
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Preserved", inputEvidence: .submitted, now: f.at(1))
        #expect(try await store.pendingTextTurns(appOwnerID: UUID(), limit: 10).isEmpty)
        #expect(try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(182), limit: 10).isEmpty)
        // The checkpoint at second one carried the lease to second 181, so the
        // process's own writes are refused only once that has lapsed.
        await #expect(throws: RunJournalError.leaseExpired) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Preserved", outcome: .interrupted, now: f.at(182))
        }
        for (appOwner, processOwner) in [(UUID(), f.owner), (f.appOwner, UUID())] {
            await #expect(throws: TextTurnRepositoryError.processAbsenceMismatch) {
                try await store.interruptTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    appOwnerID: appOwner, processAbsence: TextTurnProcessAbsence(runID: current.run.id, leaseOwnerID: processOwner), now: f.at(182))
            }
        }
        let recovered = try await store.interruptTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            appOwnerID: f.appOwner, processAbsence: TextTurnProcessAbsence(runID: current.run.id, leaseOwnerID: f.owner), now: f.at(182))
        #expect(recovered.run.state == .interrupted && recovered.replyText == "Preserved" && recovered.inputState == .outcomeUnknown)
        let ordinary = try WorkRequest(runID: RunID(UUID()), teammateID: f.teammateID, conversationID: f.conversationID,
            initiatingMessageID: turn.message.id, profileRevision: 1, initialInput: turn.request.initialInput, submittedAt: f.at(62))
        let queued = try await store.enqueueRun(ordinary, origin: .executor)
        _ = try await store.claimRun(id: queued.id, expectedRevision: queued.revision, ownerID: f.owner,
            token: f.token, now: f.at(63), leaseDuration: 30)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            try await store.interruptTextTurn(id: queued.id, expectedRevision: 2, appOwnerID: f.appOwner,
                processAbsence: TextTurnProcessAbsence(runID: queued.id, leaseOwnerID: f.owner), now: f.at(100))
        }
    }

    /// A quit leaves an open card's row `pending`, and the record then showed
    /// it as "Waiting" for good. The turn's
    /// end closes it; an answered card keeps its answer.
    @Test("A card the turn left unanswered is closed as expired when the turn ends, even after a quit")
    func unansweredCardClosesWithTheTurn() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let current = try await f.begin(store, try f.turn())
        func card() throws -> ApprovalRequest {
            try ApprovalRequest(id: ApprovalID(UUID()), teammateID: f.teammateID, conversationID: f.conversationID,
                action: .send, exactTargetSummary: "Synthetic target", consequenceSummary: "No external action",
                fingerprint: ApprovalFingerprint("fixture"), requestedAt: f.at(1))
        }
        let open = try card(), answered = try card()
        try await store.insert(open)
        try await store.insert(answered)
        var approved = answered
        try approved.apply(.resolve(.approve), at: f.at(2))
        try await store.update(approved, expectedState: .pending)

        _ = try await store.interruptTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            appOwnerID: f.appOwner, processAbsence: TextTurnProcessAbsence(runID: current.run.id, leaseOwnerID: f.owner), now: f.at(182))

        let rows = try await store.approvals(conversationID: f.conversationID, limit: 10)
        #expect(rows.first { $0.id == open.id }?.state == .expired)
        #expect(rows.first { $0.id == open.id }?.resolvedAt == f.at(182))
        #expect(rows.first { $0.id == answered.id } == approved)
    }

    @Test("Provenance accepts either message side once while preserving local-only and conversation scope")
    func provenance() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let old = try f.turn().message
        var local = old
        local.deliveryState = .completed
        try await store.append(local, expectedPreviousSequence: 0)
        #expect(try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: [old.id]).isEmpty)
        let turn = try f.turn(sequence: 2)
        var current = try await f.begin(store, turn)
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(1))
        let rows = try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: [old.id, turn.message.id])
        #expect(rows.count == 1 && rows.first?.messageID == turn.message.id && rows.first?.inputState == .submitted)
        #expect(rows.first?.replyMessageID == turn.request.textTurnIdentity?.replyMessageID)
        let replyID = try #require(turn.request.textTurnIdentity).replyMessageID
        // A paged or search-result transcript can contain the reply without its user.
        #expect(try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: [replyID]) == rows)
        #expect(try await store.textTurnProvenance(conversationID: f.conversationID,
            messageIDs: [replyID, old.id, turn.message.id]) == rows)
        for requested in [[replyID], [turn.message.id, replyID]] {
            #expect(try await store.textTurnProvenance(conversationID: ConversationID(UUID()), messageIDs: requested).isEmpty)
        }
        #expect(try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: []).isEmpty)
        await #expect(throws: RunJournalError.invalidLimit) {
            try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: [turn.message.id, turn.message.id])
        }
        await #expect(throws: RunJournalError.invalidLimit) {
            try await store.textTurnProvenance(conversationID: f.conversationID,
                messageIDs: [replyID] + (0..<100).map { _ in MessageID(UUID()) })
        }
    }

    @Test("Precancelled writes cannot publish a partial checkpoint")
    func cancelledWrite() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let current = try await f.begin(store, f.turn())
        let write = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "not saved", inputEvidence: .submitted, now: f.at(1))
        }
        await #expect(throws: CancellationError.self) { try await write.value }
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [current])
    }

    @Test("A static failed-turn diagnostic and exact partial survive close, reopen and provenance lookup",
          arguments: [false, true])
    func durableDiagnostic(hasPartial: Bool) async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let turn = try f.turn()
        let identity = try #require(turn.request.textTurnIdentity)
        let partial = hasPartial ? "Cafe\u{301}\0 exact partial\n" : ""
        var frozenJSON = ""
        var savedReply: Message!
        weak var closed: SQLiteStore?
        do {
            let store = try f.open()
            closed = store
            try await f.seed(store)
            var current = try await f.begin(store, turn)
            let metadata = try await store.query(sql: "SELECT request_json FROM run_journal_metadata WHERE run_id=?;",
                bindings: [.text(current.run.id.persistedValue)])
            frozenJSON = try #require(metadata.first).text("request_json")
            if hasPartial {
                current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    token: f.token, text: partial, inputEvidence: .submitted, now: f.at(1))
            }
            let ended = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: partial, outcome: .failed, diagnosticCode: .replayMessageMismatch, now: f.at(2))
            #expect(ended.run.state == .failed && ended.replyText.utf8.elementsEqual(partial.utf8))
            savedReply = try #require(try await store.message(id: identity.replyMessageID))
        }
        #expect(closed == nil)
        let reopened = try f.open()
        let reply = try #require(try await reopened.message(id: identity.replyMessageID))
        #expect(reply == savedReply && reply.deliveryState == .failed && reply.parts.count == 2)
        let primary = try #require(reply.parts.first)
        #expect(primary.id == identity.replyPartID && primary.ordinal == 0)
        if hasPartial {
            guard case let .text(text) = primary.content else {
                Issue.record("Actual partial text was replaced by a status")
                return
            }
            #expect(text.utf8.elementsEqual(partial.utf8))
        } else {
            #expect(primary.content == .status("Claude could not complete this reply."))
        }
        let diagnostic = try #require(reply.parts.last)
        #expect(diagnostic.id != primary.id && diagnostic.ordinal == 1)
        #expect(diagnostic.content == .status("OpenBots diagnostic: replayMessageMismatch"))
        let provenance = try await reopened.textTurnProvenance(conversationID: f.conversationID,
            messageIDs: [turn.message.id, identity.replyMessageID])
        #expect(provenance.count == 1 && provenance.first?.runID == turn.request.runID && provenance.first?.state == .failed)
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
        let metadata = try await reopened.query(sql: "SELECT request_json FROM run_journal_metadata WHERE run_id=?;",
            bindings: [.text(turn.request.runID.persistedValue)])
        #expect(try #require(metadata.first).text("request_json").utf8.elementsEqual(frozenJSON.utf8))
        // Diagnostics are status parts, never provider text in the search index.
        let indexed = try await reopened.query(sql: "SELECT body FROM conversation_message_search WHERE message_id=?;",
            bindings: [.text(identity.replyMessageID.persistedValue)])
        if hasPartial {
            #expect(try #require(indexed.first).text("body").utf8.elementsEqual(partial.utf8))
        } else {
            #expect(indexed.isEmpty)
        }
    }

    @Test("Only one allowlisted terminal diagnostic may accompany the frozen primary part",
          arguments: ["active", "unknown", "text", "ordinal", "extra", "succeeded"])
    func invalidDiagnosticParts(variant: String) async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        let identity = try #require(turn.request.textTurnIdentity)
        var current = try await f.begin(store, turn)
        if variant == "succeeded" {
            current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Reply", inputEvidence: .submitted, now: f.at(1))
            current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Reply", inputEvidence: .acknowledged, now: f.at(2))
            current = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Reply", outcome: .succeeded, now: f.at(3))
        } else if variant != "active" {
            current = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "", outcome: .failed, now: f.at(1))
        }
        _ = try await store.execute(sql: """
            INSERT INTO message_parts(id,message_id,ordinal,kind,text_value,referenced_id)
            VALUES (?,?,?,?,?,NULL);
            """, bindings: [.text(MessagePartID(UUID()).persistedValue), .text(identity.replyMessageID.persistedValue),
                .integer(variant == "ordinal" ? 2 : 1), .text(variant == "text" ? "text" : "status"),
                .text(variant == "unknown" ? "OpenBots diagnostic: arbitrary provider detail" : "OpenBots diagnostic: invalidEnvelope")])
        if variant == "extra" {
            _ = try await store.execute(sql: """
                INSERT INTO message_parts(id,message_id,ordinal,kind,text_value,referenced_id)
                VALUES (?,?,2,'status','OpenBots diagnostic: invalidJSON',NULL);
                """, bindings: [.text(MessagePartID(UUID()).persistedValue), .text(identity.replyMessageID.persistedValue)])
        }
        await #expect(throws: TextTurnRepositoryError.invalidReply) {
            try await store.textTurnProvenance(conversationID: f.conversationID, messageIDs: [identity.replyMessageID])
        }
        if variant == "active" {
            await #expect(throws: TextTurnRepositoryError.invalidReply) {
                try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10)
            }
            await #expect(throws: TextTurnRepositoryError.invalidReply) {
                try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    token: f.token, text: "", outcome: .failed, diagnosticCode: .invalidJSON, now: f.at(1))
            }
            #expect(try await store.run(id: current.run.id) == current.run)
        }
    }

    @Test("Diagnostic finalization remains fenced and rolls back with a rejected terminal journal entry")
    func atomicDiagnosticFinish() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        let identity = try #require(turn.request.textTurnIdentity)
        var current = try await f.begin(store, turn)
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Saved", inputEvidence: .submitted, now: f.at(1))
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Saved", inputEvidence: .acknowledged, now: f.at(2))
        await #expect(throws: TextTurnRepositoryError.invalidEvidence) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Saved", outcome: .succeeded, diagnosticCode: .processFailed, now: f.at(3))
        }
        await #expect(throws: RunJournalError.staleRevision) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision - 1,
                token: f.token, text: "Saved", outcome: .failed, diagnosticCode: .processFailed, now: f.at(3))
        }
        _ = try await store.execute(sql: "CREATE TRIGGER reject_diagnostic_terminal BEFORE INSERT ON run_journal_entries WHEN NEW.state='failed' BEGIN SELECT RAISE(ABORT,'terminal failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Saved final", outcome: .failed, diagnosticCode: .processFailed, now: f.at(3))
        }
        let reply = try #require(try await store.message(id: identity.replyMessageID))
        #expect(reply.parts.count == 1 && reply.parts.first?.content == .text("Saved") && reply.deliveryState == .pending)
        #expect(try await store.message(id: turn.message.id)?.deliveryState == .acknowledged)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [current])
    }

    @Test("The original protocol call forwards nil and leaves the legacy single-part shape intact")
    func diagnosticFreeProtocolCompatibility() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try f.turn()
        let current = try await f.begin(store, turn)
        let repository: any TextTurnRepository = store
        let ended = try await repository.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "", outcome: .failed, now: f.at(1))
        let identity = try #require(turn.request.textTurnIdentity)
        let savedReply = try await store.message(id: identity.replyMessageID)
        let reply = try #require(savedReply)
        #expect(ended.run.state == .failed && reply.parts.count == 1)
        #expect(reply.parts.first?.content == .status("Claude could not complete this reply."))
    }

    /// A turn the bot declined must still read as declined after the app is
    /// closed and reopened. The run state beneath it is the ordinary `failed`,
    /// so the saved reply status is the whole durable record of the decision:
    /// if the writer and the reader ever stop agreeing on that one sentence,
    /// the person reads a failure again.
    @Test("A declined turn saves the bot's own wording and still reads as declined after a reopen")
    func declinedTurnSurvivesAReopen() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let turn = try f.turn()
        let identity = try #require(turn.request.textTurnIdentity)
        do {
            let store = try f.open()
            try await f.seed(store)
            let current = try await f.begin(store, turn)
            let ended = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "", outcome: .declined, now: f.at(1))
            #expect(ended.run.state == .failed)
            #expect(ended.outcome == .declined)
        }
        let reopened = try f.open()
        let reply = try #require(try await reopened.message(id: identity.replyMessageID))
        // One part: a decline records no diagnostic, because nothing broke.
        #expect(reply.parts.count == 1)
        #expect(reply.parts.first?.content == .status(TextTurnOutcome.declinedReplyStatus))
        #expect(reply.parts.first?.content != .status("Claude could not complete this reply."))
        let provenance = try await reopened.textTurnProvenance(conversationID: f.conversationID,
            messageIDs: [turn.message.id, identity.replyMessageID])
        #expect(provenance.count == 1)
        #expect(provenance.first?.state == .failed)
        #expect(provenance.first?.outcome == .declined)

        // A turn that actually broke is still read as broken, not as a decline.
        let other = try f.turn(sequence: 3)
        let otherIdentity = try #require(other.request.textTurnIdentity)
        let running = try await f.begin(reopened, other)
        _ = try await reopened.finishTextTurn(id: running.run.id, expectedRevision: running.run.revision,
            token: f.token, text: "", outcome: .failed, now: f.at(2))
        let brokenProvenance = try await reopened.textTurnProvenance(conversationID: f.conversationID,
            messageIDs: [otherIdentity.replyMessageID])
        #expect(brokenProvenance.first?.outcome == .failed)
    }

    @Test("A bot's latest turn in a conversation follows the conversation's order, not the clock, and says how it ended")
    func latestTextTurnFollowsTheConversation() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        #expect(try await store.latestTextTurn(conversationID: f.conversationID, teammateID: f.teammateID) == nil)
        // The first turn is stopped mid-reply, as a correction stops it: the
        // request was acknowledged and a partial reply is on record.
        let stopped = try f.turn(sequence: 1, text: "Write me a poem about cobalt")
        var current = try await f.begin(store, stopped)
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(1))
        current = try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Cobalt is", inputEvidence: .acknowledged, now: f.at(2))
        // Settled last on the clock, after the turn below has already finished.
        _ = try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: f.token, text: "Cobalt is", outcome: .interrupted, now: f.at(9))
        let latest = try #require(try await store.latestTextTurn(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(latest.run.id == stopped.request.runID)
        #expect(latest.outcome == .interrupted)
        #expect(latest.run.request.initialInput.text == "Write me a poem about cobalt")
        #expect(latest.replyText == "Cobalt is")
        // A later turn in the conversation is the latest even when its row was
        // written earlier on the clock.
        let next = try f.turn(sequence: 3, text: "And one about copper")
        var running = try await f.begin(store, next)
        running = try await store.checkpointTextTurn(id: running.run.id, expectedRevision: running.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(3))
        running = try await store.checkpointTextTurn(id: running.run.id, expectedRevision: running.run.revision,
            token: f.token, text: "", inputEvidence: .acknowledged, now: f.at(4))
        _ = try await store.finishTextTurn(id: running.run.id, expectedRevision: running.run.revision,
            token: f.token, text: "Copper glows.", outcome: .succeeded, now: f.at(5))
        let after = try #require(try await store.latestTextTurn(conversationID: f.conversationID, teammateID: f.teammateID))
        #expect(after.run.id == next.request.runID)
        #expect(after.outcome == .succeeded)
        // Another bot, or another conversation, has no turn here.
        #expect(try await store.latestTextTurn(conversationID: f.conversationID, teammateID: TeammateID(UUID())) == nil)
        #expect(try await store.latestTextTurn(conversationID: ConversationID(UUID()), teammateID: f.teammateID) == nil)
    }

    @Test("A bot's latest turn is the one it ran for the user, never a team leg or the report it compiles from a member's words")
    func latestTextTurnSkipsTeamLegs() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)
        let room = conversation.id
        var clock = f.date.addingTimeInterval(60)
        func tick() -> Date { clock = clock.addingTimeInterval(10); return clock }
        // The user asks the lead, and the lead answers by sending Ada a brief.
        let asked = try await teamTurn(store, conversation: room, teammate: f.mira, author: .user,
            text: "Audit Alpha Beta's presence.", reply: "Noted. Asking Ada.", at: tick())
        // Ada's leg: the brief the lead wrote is its initiating message, and
        // Ada's reply ends the leg, exactly as the reply service writes them.
        let brief = try HandoffBrief(goal: "audit her presence", constraints: ["Answer briefly"], inputReferences: ["The name above"],
            requestedOutput: "A short list", exclusions: ["No speculation"], stopOrApprovalBoundary: "Report only")
        var record = HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()),
            legID: HandoffLegID(UUID()), originConversationID: room, senderID: f.mira, receiverID: f.ada, createdAt: tick()),
            brief: brief), sourceMessageID: nil)
        try await store.insert(record)
        try record.apply(.accept(at: tick()))
        try await store.update(record, expectedState: .staged)
        let leg = try await teamTurn(store, conversation: room, teammate: f.ada, author: .teammate(f.mira), outputClass: .workAudit,
            text: "Handoff from Mira to Ada. Goal: audit her presence", reply: "Ada's result: no search finds her.",
            at: tick(), handoffLegID: record.legID)
        try record.apply(.beginWork(at: tick()))
        try record.apply(.succeed(summary: "Ada's result: no search finds her.", at: tick()))
        record.replyMessageID = leg.replyID
        record.runID = leg.runID
        try await store.update(record, expectedState: .accepted)
        // The lead compiles Ada's result: Ada's words are the initiating
        // message, and the compile is stopped mid-way, as a correction typed
        // at that moment stops it.
        let report = try await teamTurn(store, conversation: room, teammate: f.mira, author: .teammate(f.ada), outputClass: .workAudit,
            text: "Ada's result: no search finds her.", reply: "Compiling: Ada found", outcome: .interrupted,
            at: tick(), handoffReportLegID: record.legID)
        // The correction quotes the turn the lead ran for the user, not the
        // report whose "request" is a member's returned text.
        let latest = try #require(try await store.latestTextTurn(conversationID: room, teammateID: f.mira))
        #expect(latest.run.id == asked.runID)
        #expect(latest.run.id != report.runID)
        #expect(latest.run.request.initialInput.text == "Audit Alpha Beta's presence.")
        #expect(latest.outcome == .succeeded)
        // Ada's only turn here is a leg: there is nothing of hers for a
        // correction to quote.
        #expect(try await store.latestTextTurn(conversationID: room, teammateID: f.ada) == nil)
    }

    /// A hidden bot keeps its seat and shows in its teams. Hide tidies the sidebar, so it
    /// shuts the bot's own chat and nothing else.
    @Test("A hidden bot is still read and answers in its team; its own chat stays shut")
    func hiddenBotKeepsItsTeamSeat() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)
        // Raw SQL: `setHidden` would move the profile revision the turns below name.
        _ = try await store.execute(sql: "UPDATE teammates SET is_hidden=1 WHERE id=?;", bindings: [.text(f.ada.persistedValue)])
        func context(_ room: ConversationID) async throws {
            _ = try await store.loadReadContextCandidates(ReadContextRequest(
                conversationID: room, teammateID: f.ada, profileRevision: 1,
                selection: ConversationContextSelection(conversationID: room, teammateID: f.ada), beforeSequence: 1))
        }

        try await context(conversation.id)
        let turn = try await teamTurn(store, conversation: conversation.id, teammate: f.ada, author: .user,
            text: "@Ada check the sources", reply: "Checked.", at: f.date.addingTimeInterval(60))
        #expect(try await store.message(id: turn.replyID)?.author == .teammate(f.ada))

        await #expect(throws: ReadContextError.unavailable) { try await context(f.adaChat) }
        await #expect(throws: RunJournalError.invalidRequest) {
            _ = try await self.teamTurn(store, conversation: f.adaChat, teammate: f.ada, author: .user,
                text: "Hello", reply: "Hi.", at: f.date.addingTimeInterval(120))
        }
    }

    @Test("A worker's result wakes its bot as an app-written work note; the bot's answer is a conversation message, and the note survives a reopen")
    func workerResultTurn() async throws {
        let f = try TextTurnFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let workerID = UUID()
        func turn(author: MessageAuthor, outputClass: OutputClass, legID: HandoffLegID? = nil) throws -> (request: WorkRequest, message: Message) {
            let text = "```worker\n[Background worker finished]\nThe three summaries.\n```"
            let message = try Message(id: MessageID(UUID()), conversationID: f.conversationID, sequence: 1, author: author,
                outputClass: outputClass, deliveryState: .pending,
                parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))], createdAt: f.date, updatedAt: f.date)
            let request = try WorkRequest(runID: RunID(UUID()), teammateID: f.teammateID, conversationID: f.conversationID,
                initiatingMessageID: message.id, profileRevision: 1,
                initialInput: WorkInput(messageID: message.id, sequence: 1, text: text), submittedAt: f.date,
                textTurnIdentity: TextTurnIdentity(appOwnerID: f.appOwner, replyMessageID: MessageID(UUID()),
                    replyPartID: MessagePartID(UUID()), handoffLegID: legID, workerResultID: workerID))
            return (request, message)
        }
        // Only the app writes a worker's result: never the user, never as a transcript message, never beside a leg.
        for (author, outputClass, legID) in [(MessageAuthor.user, OutputClass.conversation, nil as HandoffLegID?),
                                             (.system, .conversation, nil), (.system, .workAudit, HandoffLegID(UUID()))] {
            await #expect(throws: (any Error).self) { _ = try await f.begin(store, try turn(author: author, outputClass: outputClass, legID: legID)) }
        }
        let woken = try turn(author: .system, outputClass: .workAudit)
        let begun = try await f.begin(store, woken)
        let submitted = try await store.checkpointTextTurn(id: begun.run.id, expectedRevision: begun.run.revision,
            token: f.token, text: "", inputEvidence: .submitted, now: f.at(1))
        let saved = try await store.checkpointTextTurn(id: submitted.run.id, expectedRevision: submitted.run.revision,
            token: f.token, text: "", inputEvidence: .acknowledged, now: f.at(1))
        // A reopen reads the note back as the app's own.
        let reopened = try f.open()
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [saved])
        let done = try await reopened.finishTextTurn(id: saved.run.id, expectedRevision: saved.run.revision,
            token: f.token, text: "Here are the three summaries.", outcome: .succeeded, now: f.at(2))
        #expect(done.run.state == .succeeded)
        let note = try #require(try await reopened.message(id: woken.message.id))
        #expect(note.author == .system && note.outputClass == .workAudit)
        let replyID = try #require(woken.request.textTurnIdentity).replyMessageID
        let reply = try #require(try await reopened.message(id: replyID))
        #expect(reply.author == .teammate(f.teammateID) && reply.outputClass == .conversation && reply.deliveryState == .completed)
    }

    /// One finished text turn in a team room, as the reply service writes it:
    /// the initiating message with the given author and class, answered by
    /// `teammate`, ending as `outcome` with `reply` on record.
    private func teamTurn(_ store: SQLiteStore, conversation: ConversationID, teammate: TeammateID,
                          author: MessageAuthor, outputClass: OutputClass = .conversation, text: String, reply: String,
                          outcome: TextTurnOutcome = .succeeded, at date: Date,
                          handoffLegID: HandoffLegID? = nil, handoffReportLegID: HandoffLegID? = nil) async throws -> (runID: RunID, replyID: MessageID) {
        let last = try await store.page(conversationID: conversation, request: PageRequest(limit: 1)).elements.last?.sequence ?? 0
        let message = try Message(id: MessageID(UUID()), conversationID: conversation, sequence: last + 1, author: author,
            outputClass: outputClass, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: date, updatedAt: date)
        let replyID = MessageID(UUID())
        let request = try WorkRequest(runID: RunID(UUID()), teammateID: teammate, conversationID: conversation,
            initiatingMessageID: message.id, selectedProjectID: nil, profileRevision: 1,
            initialInput: WorkInput(messageID: message.id, sequence: 1, text: text), submittedAt: date,
            textTurnIdentity: TextTurnIdentity(appOwnerID: UUID(), replyMessageID: replyID, replyPartID: MessagePartID(UUID()),
                handoffLegID: handoffLegID, handoffReportLegID: handoffReportLegID))
        let token = UUID()
        let begun = try await store.beginTextTurn(request: request, userMessage: message, expectedPreviousSequence: last,
            ownerID: UUID(), token: token, now: date, leaseDuration: 60)
        var saved = try await store.checkpointTextTurn(id: request.runID, expectedRevision: begun.run.revision,
            token: token, text: "", inputEvidence: .submitted, now: date.addingTimeInterval(1))
        saved = try await store.checkpointTextTurn(id: request.runID, expectedRevision: saved.run.revision,
            token: token, text: outcome == .succeeded ? "" : reply, inputEvidence: .acknowledged, now: date.addingTimeInterval(2))
        _ = try await store.finishTextTurn(id: request.runID, expectedRevision: saved.run.revision,
            token: token, text: reply, outcome: outcome, now: date.addingTimeInterval(3))
        return (request.runID, replyID)
    }
}

private struct TextTurnFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 2_000)
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let appOwner = UUID(), owner = UUID(), token = UUID()

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextTextTurn-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func at(_ offset: TimeInterval) -> Date { date.addingTimeInterval(offset) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }

    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(id: teammateID, profile: TeammateProfile(displayName: "Text Partner", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: teammateID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }

    func turn(sequence: Int64 = 1, text: String = "An exact text question") throws -> (request: WorkRequest, message: Message) {
        let message = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: sequence, author: .user,
            deliveryState: .pending, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: date, updatedAt: date)
        let request = try WorkRequest(runID: RunID(UUID()), teammateID: teammateID, conversationID: conversationID,
            initiatingMessageID: message.id, profileRevision: 1,
            initialInput: WorkInput(messageID: message.id, sequence: 1, text: text), submittedAt: date,
            textTurnIdentity: TextTurnIdentity(appOwnerID: appOwner, replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID())))
        return (request, message)
    }

    func begin(_ store: SQLiteStore, _ turn: (request: WorkRequest, message: Message)) async throws -> TextTurnSnapshot {
        try await store.beginTextTurn(request: turn.request, userMessage: turn.message,
            expectedPreviousSequence: turn.message.sequence - 1, ownerID: owner, token: token, now: date, leaseDuration: 60)
    }
}
