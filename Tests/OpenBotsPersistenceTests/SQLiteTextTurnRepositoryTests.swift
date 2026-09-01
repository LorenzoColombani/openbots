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
        #expect(try await store.recoverExpiredLocalFixtures(conversationID: f.conversationID, now: f.at(61), limit: 10).isEmpty)
        await #expect(throws: RunJournalError.leaseExpired) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "Preserved", outcome: .interrupted, now: f.at(61))
        }
        for (appOwner, processOwner) in [(UUID(), f.owner), (f.appOwner, UUID())] {
            await #expect(throws: TextTurnRepositoryError.processAbsenceMismatch) {
                try await store.interruptTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                    appOwnerID: appOwner, processAbsence: TextTurnProcessAbsence(runID: current.run.id, leaseOwnerID: processOwner), now: f.at(61))
            }
        }
        let recovered = try await store.interruptTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            appOwnerID: f.appOwner, processAbsence: TextTurnProcessAbsence(runID: current.run.id, leaseOwnerID: f.owner), now: f.at(61))
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
