import CryptoKit
import Foundation
import SQLite3
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Bounded app-owned read context")
struct SQLiteReadContextRepositoryTests {
    @Test("Recent and keyword-relevant older own turns survive reopen without loading unknown local history")
    func recentAndOlderAcrossReopen() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        var old: ReadContextTestTurn!
        do {
            let store = try f.open()
            try await f.seed(store)
            old = try await f.complete(store, text: "The launch color is cobalt.", reply: "I recorded cobalt as the launch color.")
            for number in 0..<9 {
                _ = try await f.complete(store, text: "Unrelated weather item \(number)", reply: "Weather receipt \(number)")
            }
            _ = try await f.local(store, text: "Unknown project secret: launch color violet")
            _ = try await f.complete(store, text: "foreign launch color", reply: "foreign launch color", other: true)
        }
        let store = try f.open()
        let request = try await f.request(store, query: "What was the launch color?")
        #expect(request.searchTerms == ["launch", "color"])
        let snapshot = try await store.loadReadContextCandidates(request)
        #expect(snapshot.recentMessages.count <= 12 && snapshot.olderMessages.count <= 12)
        #expect(snapshot.omissions.recentWindowHasMore && snapshot.omissions.excludedMessageLowerBound >= 1)
        #expect(Set(snapshot.olderMessages.map(\.id)) == [old.userID, old.replyID])
        #expect((snapshot.recentMessages + snapshot.olderMessages).allSatisfy {
            !$0.text.contains("Unknown project secret") && !$0.text.contains("foreign")
        })
        #expect(snapshot.recentMessages.map(\.sequence) == snapshot.recentMessages.map(\.sequence).sorted())
        let selected = try snapshot.receipt.selecting(messageIDs: [old.replyID], memoryDocumentIDs: [])
        try await store.revalidateReadContext(selected)
        let encoded = try JSONEncoder().encode(selected)
        #expect(try JSONDecoder().decode(ReadContextReceipt.self, from: encoded) == selected)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("cobalt"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(f.directory.path))
        // A later admitted turn adds rows but cannot invalidate unchanged selected sources.
        _ = try await f.begin(store, text: "A later new request")
        try await store.revalidateReadContext(selected)
    }

    @Test("Failed, unjournaled, malformed and falsely correlated turns never become remembered facts",
          arguments: ReadContextInvalidTurn.allCases)
    func rejectUnprovenHistory(_ invalid: ReadContextInvalidTurn) async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let turn = try await f.complete(store, text: "secret candidate", reply: "secret candidate reply", succeeded: invalid != .failed)
        switch invalid {
        case .failed: break
        case .localFixture:
            _ = try await store.execute(sql: "UPDATE run_journal_metadata SET origin='localFixture' WHERE run_id=?;", bindings: [.text(turn.runID.persistedValue)])
        case .malformedJSON:
            _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json='{' WHERE run_id=?;", bindings: [.text(turn.runID.persistedValue)])
        case .falseReply:
            _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json=json_set(request_json,'$.textTurnIdentity.replyMessageID',?) WHERE run_id=?;",
                bindings: [.text(MessageID(UUID()).persistedValue), .text(turn.runID.persistedValue)])
        case .unacknowledged:
            _ = try await store.execute(sql: "UPDATE run_input_receipts SET state='submitted' WHERE run_id=?;", bindings: [.text(turn.runID.persistedValue)])
        case .changedFrozenUser:
            _ = try await store.execute(sql: "UPDATE message_parts SET text_value='replaced user text' WHERE message_id=?;", bindings: [.text(turn.userID.persistedValue)])
        case .extraPart:
            _ = try await store.execute(sql: "INSERT INTO message_parts(id,message_id,ordinal,kind,text_value) VALUES (?,?,1,'status','not provider text');",
                bindings: [.text(MessagePartID(UUID()).persistedValue), .text(turn.replyID.persistedValue)])
        }
        _ = try await f.local(store, text: "unjournaled secret candidate")
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(snapshot.recentMessages.isEmpty && snapshot.olderMessages.isEmpty)
        #expect(snapshot.omissions.excludedMessageLowerBound == 3)
    }

    @Test("A stopped turn is history, its reply marked as cut off, whether a correction stopped it or the user pressed Stop")
    func correctedTurnBecomesHistory() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        // Stopped by the user, nothing links it: history too, marked stopped.
        let stopped = try await f.interrupt(store, text: "Write me a poem about cobalt", partial: "Cobalt is")
        // Stopped by a correction whose run names it: its request and partial are history.
        let corrected = try await f.interrupt(store, text: "Now a haiku about cobalt", partial: "Deep cobalt evening")
        let correction = try await f.complete(store, text: "Make it about copper instead", reply: "Copper evening glows.",
            superseding: corrected.runID)
        // Stopped before it had written anything: its request is history, its status reply is not.
        let unwritten = try await f.interrupt(store, text: "One more, about tin", partial: "")
        let second = try await f.complete(store, text: "Zinc, not tin", reply: "Zinc it is.", superseding: unwritten.runID)
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(Set(snapshot.recentMessages.map(\.id)) == [stopped.userID, stopped.replyID, corrected.userID, corrected.replyID,
            correction.userID, correction.replyID, unwritten.userID, second.userID, second.replyID])
        #expect(snapshot.recentMessages.first { $0.id == stopped.replyID }?.text == "Cobalt is")
        #expect(snapshot.recentMessages.first { $0.id == corrected.replyID }?.text == "Deep cobalt evening")
        #expect(snapshot.recentMessages.first { $0.id == corrected.replyID }?.author == .teammate(f.bot))
        // The cut-off reply says so; the request it answered was whole, and so
        // is every message of a turn that finished.
        #expect(snapshot.recentMessages.first { $0.id == corrected.replyID }?.ending == .stopped)
        #expect(snapshot.recentMessages.first { $0.id == corrected.userID }?.ending == .finished)
        #expect(snapshot.recentMessages.first { $0.id == unwritten.userID }?.ending == .finished)
        #expect(snapshot.recentMessages.filter { $0.ending == .stopped }.map(\.id) == [stopped.replyID, corrected.replyID])
        // Only the status line of the turn stopped before it wrote is left out.
        #expect(snapshot.omissions.excludedMessageLowerBound == 1)
        // An admitted pair revalidates like any other, and a later correction
        // does not unseat it: what a correction put on record stays on record.
        let selected = try snapshot.receipt.selecting(messageIDs: [corrected.userID, corrected.replyID], memoryDocumentIDs: [])
        try await store.revalidateReadContext(selected)
        let again = try await f.interrupt(store, text: "And one about lead", partial: "Lead")
        _ = try await f.complete(store, text: "Gold, not lead", reply: "Gold then.", superseding: again.runID)
        try await store.revalidateReadContext(selected)
        let later = try await store.loadReadContextCandidates(f.request(store))
        #expect(Set(later.recentMessages.map(\.id)).isSuperset(of: [corrected.userID, corrected.replyID, again.userID, again.replyID]))
        // The first stopped pair has aged out of the recent window by now, as
        // any pair does; the newer one stopped by a correction is still there.
        #expect(later.recentMessages.contains { $0.id == again.replyID && $0.ending == .stopped })
    }

    @Test("History admits only nil-origin or the currently selected project; memory uses exact eligible scopes")
    func projectSelection() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let nilTurn = try await f.complete(store, text: "Personal fact", reply: "Personal answer")
        _ = try await f.select(store, project: f.projectA)
        let aTurn = try await f.complete(store, text: "Atlas fact", reply: "Atlas answer")
        _ = try await f.select(store, project: f.projectB)
        let bTurn = try await f.complete(store, text: "Borealis fact", reply: "Borealis answer")
        let user = try f.memory(scope: .user, title: "User memory")
        let own = try f.memory(scope: .teammate(f.bot), title: "Own memory")
        let other = try f.memory(scope: .teammate(f.otherBot), title: "Excluded bot sentinel")
        let atlas = try f.memory(scope: .project(f.projectA), title: "Excluded project sentinel")
        let borealis = try f.memory(scope: .project(f.projectB), title: "Borealis memory")
        for document in [user, own, other, atlas, borealis] { try await store.insert(document) }
        let b = try await store.loadReadContextCandidates(f.request(store))
        #expect(Set(b.recentMessages.map(\.id)) == [nilTurn.userID, nilTurn.replyID, bTurn.userID, bTurn.replyID])
        #expect(Set(b.memoryDocuments.map(\.id)) == [own.id, borealis.id])
        #expect(b.omissions.excludedMessageLowerBound == 2)
        _ = try await f.select(store, project: nil)
        let noProject = try await store.loadReadContextCandidates(f.request(store))
        #expect(Set(noProject.recentMessages.map(\.id)) == [nilTurn.userID, nilTurn.replyID])
        #expect(Set(noProject.memoryDocuments.map(\.id)) == [own.id])
        _ = try await f.select(store, project: f.projectA)
        let a = try await store.loadReadContextCandidates(f.request(store))
        #expect(Set(a.recentMessages.map(\.id)) == [nilTurn.userID, nilTurn.replyID, aTurn.userID, aTurn.replyID])
        #expect(Set(a.memoryDocuments.map(\.id)) == [own.id, atlas.id])
    }

    @Test("A fresh bot receives only its own memory; global user memory has no implicit grant")
    func freshBotExcludesGlobalMemory() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let global = try f.memory(scope: .user, title: "Private global sentinel")
        let own = try f.memory(scope: .teammate(f.bot), title: "Own approved memory")
        let other = try f.memory(scope: .teammate(f.otherBot), title: "Other bot sentinel")
        for document in [global, own, other] { try await store.insert(document) }
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(snapshot.receipt.selectedProjectID == nil)
        #expect(snapshot.memoryDocuments == [own])
        #expect(snapshot.receipt.memoryDocuments.map(\.documentID) == [own.id])
        #expect(snapshot.recentMessages.isEmpty && snapshot.olderMessages.isEmpty)
        try await store.revalidateReadContext(snapshot.receipt)
        #expect(try await store.document(id: global.id) == global)
        #expect(try await store.document(id: other.id) == other)
    }

    @Test("A well-formed old or forged global receipt is refused even with an explicit project", arguments: [false, true])
    func globalReceiptHasNoAuthority(selectedProject: Bool) async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        if selectedProject { _ = try await f.select(store, project: f.projectA) }
        let global = try f.memory(scope: .user, title: "Unapproved shared source")
        try await store.insert(global)
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        let oldReceipt = try f.receipt(basedOn: snapshot.receipt, documents: [global])
        // Correct document ID, metadata digest and current authority stamps do
        // not supply the absent user decision to enable global memory.
        await #expect(throws: ReadContextError.staleReferences) {
            try await store.revalidateReadContext(oldReceipt)
        }
        #expect(snapshot.memoryDocuments.isEmpty)
        #expect(try await store.document(id: global.id) == global)
    }

    @Test("Saved replies cannot carry global memory back through multiple historical context receipts")
    func globalHistoryAncestryIsExcluded() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let global = try f.memory(scope: .user, title: "Previously automatic global memory")
        try await store.insert(global)
        let first = try await f.complete(store, text: "First user text", reply: "GLOBAL-REPLY-SENTINEL")
        let second = try await f.complete(store, text: "Second user text", reply: "INHERITED-GLOBAL-SENTINEL")
        let third = try await f.complete(store, text: "Third user text", reply: "INDIRECT-GLOBAL-SENTINEL")
        let clean = try await store.loadReadContextCandidates(f.request(store))
        let firstReference = try #require(clean.receipt.messages.first { $0.messageID == first.replyID })
        let secondReference = try #require(clean.receipt.messages.first { $0.messageID == second.replyID })
        let stale = try clean.receipt.selecting(messageIDs: [third.replyID], memoryDocumentIDs: [])
        // Model records written under the previous policy, without invoking any
        // engine or asking the new admission gate to authorize global context.
        try await f.installHistoricalReceipt(f.receipt(basedOn: clean.receipt, documents: [global]), for: first, store: store)
        try await f.installHistoricalReceipt(f.receipt(basedOn: clean.receipt, messages: [firstReference]), for: second, store: store)
        try await f.installHistoricalReceipt(f.receipt(basedOn: clean.receipt, messages: [secondReference]), for: third, store: store)
        let independent = try await f.complete(store, text: "Independent local fact", reply: "Independent local answer")
        let snapshot = try await store.loadReadContextCandidates(f.request(store, query: "global"))
        #expect(Set(snapshot.recentMessages.map(\.id)) == [independent.userID, independent.replyID])
        #expect(snapshot.olderMessages.isEmpty)
        #expect(snapshot.omissions.excludedMessageLowerBound == 6)
        await #expect(throws: ReadContextError.staleReferences) { try await store.revalidateReadContext(stale) }
        let preserved = try await store.message(id: first.replyID)
        #expect(preserved?.parts.first?.content == .text("GLOBAL-REPLY-SENTINEL"))
        #expect(try await store.run(id: first.runID)?.state == .succeeded)
    }

    @Test("Own-bot and selected-project memory remain usable through valid receipt ancestry")
    func authorizedHistoryAncestrySurvives() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        _ = try await f.select(store, project: f.projectA)
        let own = try f.memory(scope: .teammate(f.bot), title: "Own memory")
        let project = try f.memory(scope: .project(f.projectA), title: "Selected project memory")
        for document in [own, project] { try await store.insert(document) }
        let first = try await f.complete(store, text: "Approved source", reply: "Approved answer")
        let second = try await f.complete(store, text: "Continue the same project", reply: "Approved continuity")
        let original = try await store.loadReadContextCandidates(f.request(store))
        let reference = try #require(original.receipt.messages.first { $0.messageID == first.replyID })
        try await f.installHistoricalReceipt(f.receipt(basedOn: original.receipt, documents: [own, project]), for: first, store: store)
        try await f.installHistoricalReceipt(f.receipt(basedOn: original.receipt, messages: [reference]), for: second, store: store)
        let admitted = try await store.loadReadContextCandidates(f.request(store))
        #expect(admitted.recentMessages.count == 4)
        #expect(Set(admitted.memoryDocuments.map(\.id)) == [own.id, project.id])
        try await store.revalidateReadContext(admitted.receipt)
        _ = try await f.select(store, project: f.projectB)
        let switched = try await store.loadReadContextCandidates(f.request(store))
        #expect(switched.recentMessages.isEmpty)
        #expect(switched.memoryDocuments == [own])
    }

    @Test("Unknown, oversized and cyclic historical receipts are omitted without altering saved turns",
          arguments: ["malformed", "oversized", "cycle", "foreign"])
    func invalidHistoryReceiptIsExcluded(_ kind: String) async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let independent = try await f.complete(store, text: "Independent source", reply: "Independent answer")
        let turn = try await f.complete(store, text: "Candidate source", reply: "Candidate answer")
        let original = try await store.loadReadContextCandidates(f.request(store))
        var receipt = try f.receipt(basedOn: original.receipt)
        if kind == "cycle" {
            let ownReference = try #require(original.receipt.messages.first { $0.messageID == turn.replyID })
            receipt = try f.receipt(basedOn: receipt, messages: [ownReference])
        } else if kind == "foreign" {
            let missing = ReadContextMessageReference(messageID: MessageID(UUID()), runID: RunID(UUID()),
                runRevision: 5, runUpdatedAt: f.date, sequence: 1, messageUpdatedAt: f.date,
                selectedProjectID: nil, contentDigest: String(repeating: "a", count: 64))
            receipt = try f.receipt(basedOn: receipt, messages: [missing])
        }
        try await f.installHistoricalReceipt(receipt, for: turn, store: store)
        if kind == "malformed" {
            _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json=json_set(request_json,'$.readContextReceipt',json('[]')) WHERE run_id=?;",
                bindings: [.text(turn.runID.persistedValue)])
        } else if kind == "oversized" {
            _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json=json_set(request_json,'$.readContextReceipt.unknown',?) WHERE run_id=?;",
                bindings: [.text(String(repeating: "x", count: 32_769)), .text(turn.runID.persistedValue)])
        }
        let preservationSQL = """
            SELECT r.state, j.request_json
            FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
            WHERE r.id=?;
            """
        let beforeRows = try await store.query(sql: preservationSQL, bindings: [.text(turn.runID.persistedValue)])
        let before = try #require(beforeRows.first)
        let beforeState = try before.text("state")
        let beforeRequest = try before.text("request_json")
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(Set(snapshot.recentMessages.map(\.id)) == [independent.userID, independent.replyID])
        #expect(snapshot.olderMessages.isEmpty)
        #expect(snapshot.omissions.excludedMessageLowerBound == 2)
        await #expect(throws: ReadContextError.staleReferences) { try await store.revalidateReadContext(original.receipt) }
        let afterRows = try await store.query(sql: preservationSQL, bindings: [.text(turn.runID.persistedValue)])
        let after = try #require(afterRows.first)
        let afterState = try after.text("state")
        let afterRequest = try after.text("request_json")
        #expect(beforeState == "succeeded")
        #expect(afterState == beforeState)
        #expect(afterRequest.utf8.elementsEqual(beforeRequest.utf8))
    }

    /// Seen live: a bot was told where something is stored and, one turn
    /// later, said nothing in the conversation mentioned it. Its conversation
    /// had a few dozen turns, each quoting up to the twelve messages before it,
    /// and walking that ancestry spent the 256 references a context read
    /// allowed, so the newest turns were left out of context while the oldest
    /// were kept. A longer conversation was given none of its recent twelve.
    @Test("A long conversation whose every turn quoted the messages before it keeps its latest exchange in context")
    func longQuotedHistoryKeepsTheLatestExchange() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let empty = try await store.loadReadContextCandidates(f.request(store))
        var quoted: [ReadContextMessageReference] = []
        for index in 0..<40 {
            let turn = try await f.complete(store, text: "Request \(index)", reply: "Answer \(index)")
            try await f.installHistoricalReceipt(try f.receipt(basedOn: empty.receipt, messages: Array(quoted.suffix(12))),
                for: turn, store: store)
            for (id, text) in [(turn.userID, "Request \(index)"), (turn.replyID, "Answer \(index)")] {
                let message = try #require(try await store.message(id: id))
                quoted.append(ReadContextMessageReference(messageID: id, runID: turn.runID,
                    runRevision: turn.snapshot.run.revision, runUpdatedAt: turn.snapshot.run.updatedAt,
                    sequence: message.sequence, messageUpdatedAt: message.updatedAt, selectedProjectID: nil,
                    contentDigest: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()))
            }
        }
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(snapshot.omissions.excludedMessageLowerBound == 0)
        #expect(snapshot.recentMessages.map(\.text).suffix(2) == ["Request 39", "Answer 39"], "\(snapshot.recentMessages.map(\.text))")
    }

    /// Proving every admitted turn before a read once had two costs: one old
    /// turn whose stored record could not be parsed, even a turn nothing quotes,
    /// failed every context read of the conversation, and every check that
    /// quotes no message walked the whole conversation first.
    @Test("An unreadable old turn that nothing quotes fails neither a check that quotes nothing nor a context read")
    func anUnreadableUnquotedTurnFailsNoRead() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let old = try await f.complete(store, text: "Old request", reply: "Old answer")
        for index in 0..<20 { _ = try await f.complete(store, text: "Request \(index)", reply: "Answer \(index)") }
        let quotesNothing = try await store.loadReadContextCandidates(f.request(store)).receipt
            .selecting(messageIDs: [], memoryDocumentIDs: [])
        // The old turn's run id becomes one no reader can parse, written past the store.
        var connection: OpaquePointer?
        #expect(sqlite3_open(f.directory.appendingPathComponent("control.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let unreadable = String(repeating: "z", count: 36), id = old.runID.persistedValue
        #expect(sqlite3_exec(connection, """
            PRAGMA foreign_keys=OFF; BEGIN;
            UPDATE work_runs SET id='\(unreadable)' WHERE id='\(id)';
            UPDATE run_journal_metadata SET run_id='\(unreadable)' WHERE run_id='\(id)';
            UPDATE run_input_receipts SET run_id='\(unreadable)' WHERE run_id='\(id)';
            COMMIT;
            """, nil, nil, nil) == SQLITE_OK)
        do { try await store.revalidateReadContext(quotesNothing) } catch {
            Issue.record("the check that quotes nothing failed: \(error)")
        }
        do {
            let snapshot = try await store.loadReadContextCandidates(f.request(store))
            #expect(snapshot.recentMessages.map(\.text).suffix(2) == ["Request 19", "Answer 19"])
        } catch { Issue.record("the context read failed: \(error)") }
    }

    /// One turn whose proof throws was once charged to the
    /// run budget again for every later turn that quotes it, so a conversation past
    /// about forty quoting turns lost its newest messages — including turns that
    /// quote nothing and rest on nothing.
    @Test("A turn whose history cannot be proven costs a long conversation nothing but its own")
    func anUnprovableTurnCostsOnlyItsOwnMessages() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let empty = try await store.loadReadContextCandidates(f.request(store))
        let document = try f.memory(scope: .teammate(f.bot), title: "Old memory")
        try await store.insert(document)
        let root = try await f.complete(store, text: "Root request", reply: "Root answer")
        try await f.installHistoricalReceipt(try f.receipt(basedOn: empty.receipt, documents: [document]), for: root, store: store)
        var quoted = try await f.reference(store, to: root, text: "Root answer")
        for index in 0..<60 {
            let turn = try await f.complete(store, text: "Chain request \(index)", reply: "Chain answer \(index)")
            try await f.installHistoricalReceipt(try f.receipt(basedOn: empty.receipt, messages: [quoted]), for: turn, store: store)
            quoted = try await f.reference(store, to: turn, text: "Chain answer \(index)")
        }
        // Six turns of their own, quoting nothing, resting on nothing.
        for index in 0..<6 { _ = try await f.complete(store, text: "Own request \(index)", reply: "Own answer \(index)") }
        // The memory the root turn rests on goes missing, past the store.
        var connection: OpaquePointer?
        #expect(sqlite3_open(f.directory.appendingPathComponent("control.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "PRAGMA foreign_keys=OFF; DELETE FROM memory_documents WHERE id='\(document.id.persistedValue)';",
            nil, nil, nil) == SQLITE_OK)
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(snapshot.recentMessages.map(\.text).suffix(2) == ["Own request 5", "Own answer 5"], "\(snapshot.recentMessages.map(\.text))")
        #expect(snapshot.omissions.excludedMessageLowerBound == 0)
    }

    /// Every read used to walk the bot's whole
    /// conversation within a ceiling of 1,024 turns, and past it the newest
    /// turns were the ones left out. Each turn's proof is now stored, so the
    /// length of a conversation costs a read nothing and drops nothing.
    @Test("A conversation past the old 1,024-turn ceiling keeps its newest turns")
    func aChainPastTheOldCeilingKeepsItsNewestTurns() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let empty = try await store.loadReadContextCandidates(f.request(store))
        var previous: ReadContextMessageReference?
        // Two turns past where the ceiling was, each quoting the one before it.
        for index in 0..<1_026 {
            let turn = try await f.complete(store, text: "Synthetic chain \(index)", reply: "Synthetic answer \(index)")
            let messageValue = try await store.message(id: turn.replyID)
            let message = try #require(messageValue)
            let reference = ReadContextMessageReference(messageID: message.id, runID: turn.runID,
                runRevision: turn.snapshot.run.revision, runUpdatedAt: turn.snapshot.run.updatedAt,
                sequence: message.sequence, messageUpdatedAt: message.updatedAt, selectedProjectID: nil,
                contentDigest: SHA256.hash(data: Data("Synthetic answer \(index)".utf8)).map { String(format: "%02x", $0) }.joined())
            let receipt = try f.receipt(basedOn: empty.receipt, messages: previous.map { [$0] } ?? [])
            try await f.installHistoricalReceipt(receipt, for: turn, store: store)
            previous = reference
        }
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(snapshot.omissions.excludedMessageLowerBound == 0)
        #expect(snapshot.recentMessages.count == ReadContextLimits.recentMessages)
        #expect(snapshot.recentMessages.map(\.text).suffix(2) == ["Synthetic chain 1025", "Synthetic answer 1025"],
                "\(snapshot.recentMessages.map(\.text))")
        // Nothing was edited to make the read fit.
        #expect(try await store.runs(conversationID: f.chat, limit: 100).count == 100)
    }

    @Test("A turn stores its proof when it is admitted: its own memory and the memory of every turn it quotes, all the way down")
    func anAdmittedTurnStoresItsProof() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let document = try f.memory(scope: .teammate(f.bot), title: "The kite is in the garage")
        try await store.insert(document)
        let first = try await f.complete(store, text: "Where is the kite?", reply: "In the garage.")
        // The next turns are admitted the way the app admits them: with the receipt of what they read.
        let firstRead = try await store.loadReadContextCandidates(f.request(store))
        let second = try await f.complete(store, text: "And the ball?", reply: "Beside it.",
            receipt: try firstRead.receipt.selecting(messageIDs: [first.userID, first.replyID], memoryDocumentIDs: [document.id]))
        let secondRead = try await store.loadReadContextCandidates(f.request(store))
        let third = try await f.complete(store, text: "Thanks.", reply: "Any time.",
            receipt: try secondRead.receipt.selecting(messageIDs: [second.userID, second.replyID], memoryDocumentIDs: []))
        func proof(_ turn: ReadContextTestTurn) async throws -> (proven: Int64, qualification: Int64, memory: [MemoryDocumentID]) {
            let row = try #require(try await store.query(sql: """
                SELECT proven,memory_qualification_required,memory_references_json FROM read_context_turn_proofs WHERE run_id=?;
                """, bindings: [.text(turn.runID.persistedValue)]).first)
            let references = try JSONDecoder().decode([ReadContextMemoryReference].self,
                from: Data(try row.text("memory_references_json").utf8))
            return (try row.integer("proven"), try row.integer("memory_qualification_required"), references.map(\.documentID))
        }
        let firstProof = try await proof(first), secondProof = try await proof(second), thirdProof = try await proof(third)
        #expect(firstProof.proven == 1 && firstProof.qualification == 0 && firstProof.memory.isEmpty)
        #expect(secondProof.proven == 1 && secondProof.qualification == 1 && secondProof.memory == [document.id])
        // The third turn quotes no memory itself; it rests on the second turn's.
        #expect(thirdProof.proven == 1 && thirdProof.qualification == 1 && thirdProof.memory == [document.id])
    }

    /// Every correction of a memory makes
    /// a new document, so a proof that carried every reference under it could
    /// grow with each correction. It cannot: a turn resting on the old
    /// revision is no longer quotable, so what a turn stores is only memory that
    /// was current when it was admitted, never more than the heads at that time.
    @Test("A corrected memory does not pile up in the proofs of later turns")
    func aCorrectedMemoryDoesNotPileUp() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let original = try f.memory(scope: .teammate(f.bot), title: "The kite is in the garage")
        try await store.insert(original)
        let firstRead = try await store.loadReadContextCandidates(f.request(store))
        let first = try await f.complete(store, text: "Where is the kite?", reply: "In the garage.",
            receipt: try firstRead.receipt.selecting(messageIDs: [], memoryDocumentIDs: [original.id]))
        let corrected = try f.memory(scope: .teammate(f.bot), title: "The kite is in the attic", offset: 10, predecessor: original)
        try await store.insert(corrected)
        let secondRead = try await store.loadReadContextCandidates(f.request(store))
        // The first turn rests on the old revision, so it is not offered again.
        #expect(!secondRead.recentMessages.contains { $0.id == first.replyID })
        let second = try await f.complete(store, text: "And now?", reply: "In the attic.",
            receipt: try secondRead.receipt.selecting(messageIDs: secondRead.recentMessages.map(\.id),
                memoryDocumentIDs: secondRead.memoryDocuments.map(\.id)))
        let row = try #require(try await store.query(sql: "SELECT memory_references_json FROM read_context_turn_proofs WHERE run_id=?;",
            bindings: [.text(second.runID.persistedValue)]).first)
        let stored = try JSONDecoder().decode([ReadContextMemoryReference].self, from: Data(try row.text("memory_references_json").utf8))
        #expect(stored.map(\.documentID) == [corrected.id])
    }

    @Test("Turns saved before proofs were stored are proved once, oldest first, and the stored proof is what later reads use")
    func turnsSavedBeforeProofsAreProvedOnceAndStored() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let empty = try await store.loadReadContextCandidates(f.request(store))
        var turns: [ReadContextTestTurn] = []
        for index in 0..<5 {
            let turn = try await f.complete(store, text: "Request \(index)", reply: "Answer \(index)")
            var quoted: [ReadContextMessageReference] = []
            if let previous = turns.last { quoted = [try await f.reference(store, to: previous, text: "Answer \(index - 1)")] }
            try await f.installHistoricalReceipt(try f.receipt(basedOn: empty.receipt, messages: quoted), for: turn, store: store)
            turns.append(turn)
        }
        // A store from before migration 30 holds no proof at all.
        _ = try await store.execute(sql: "DELETE FROM read_context_turn_proofs;")
        let first = try await store.loadReadContextCandidates(f.request(store))
        #expect(first.recentMessages.map(\.text).suffix(2) == ["Request 4", "Answer 4"])
        let stored = try await store.query(sql: "SELECT run_id FROM read_context_turn_proofs WHERE proven=1;")
        #expect(Set(try stored.map { try $0.text("run_id") }) == Set(turns.map(\.runID.persistedValue)))
        // Proved once: the next read takes the stored proof as it stands.
        _ = try await store.execute(sql: """
            UPDATE read_context_turn_proofs SET proven=0,memory_qualification_required=0,memory_references_json='[]' WHERE run_id=?;
            """, bindings: [.text(turns[4].runID.persistedValue)])
        let second = try await store.loadReadContextCandidates(f.request(store))
        #expect(second.recentMessages.map(\.text).suffix(2) == ["Request 3", "Answer 3"])
        #expect(second.omissions.excludedMessageLowerBound == 2)
    }

    @Test("Final receipt validation detects changed source, membership, selection, profile and head stamps",
          arguments: ReadContextStaleSource.allCases)
    func finalRevalidation(_ change: ReadContextStaleSource) async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open(), otherConnection = try f.open()
        try await f.seed(store)
        _ = try await f.select(store, project: f.projectA)
        let turn = try await f.complete(store, text: "Approved source", reply: "Approved reply")
        let document = try f.memory(scope: .project(f.projectA), title: "Project memory")
        try await store.insert(document)
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        let receipt = try snapshot.receipt.selecting(messageIDs: [turn.replyID], memoryDocumentIDs: [document.id])
        try await store.revalidateReadContext(receipt)
        switch change {
        case .message:
            _ = try await otherConnection.execute(sql: "UPDATE message_parts SET text_value='Changed reply' WHERE message_id=?;", bindings: [.text(turn.replyID.persistedValue)])
        case .profile:
            _ = try await otherConnection.execute(sql: "UPDATE teammates SET profile_revision=profile_revision+1 WHERE id=?;", bindings: [.text(f.bot.persistedValue)])
        case .selectionRoundTrip:
            _ = try await f.select(otherConnection, project: nil)
            _ = try await f.select(otherConnection, project: f.projectA)
        case .revoked:
            try await otherConnection.setMembership(ProjectMembership(projectID: f.projectA, teammateID: f.bot,
                joinedAt: f.date, revokedAt: f.date.addingTimeInterval(100)))
        case .regranted:
            try await otherConnection.setMembership(ProjectMembership(projectID: f.projectA, teammateID: f.bot,
                joinedAt: f.date, revokedAt: f.date.addingTimeInterval(100)))
            try await otherConnection.setMembership(ProjectMembership(projectID: f.projectA, teammateID: f.bot,
                joinedAt: f.date.addingTimeInterval(101)))
        case .newMemoryHead:
            let successor = try f.memory(scope: document.scope, title: "New revision", predecessor: document)
            try await otherConnection.insertRevision(successor, expectedPredecessorID: document.id)
        case .memoryMetadata:
            _ = try await otherConnection.execute(sql: "UPDATE memory_documents SET title='Different title' WHERE id=?;", bindings: [.text(document.id.persistedValue)])
        }
        await #expect(throws: ReadContextError.self) { try await store.revalidateReadContext(receipt) }
    }

    @Test("Storage ceilings omit oversized multibyte bodies and cap current heads without reading Markdown files")
    func boundedBodiesAndHeads() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        _ = try await f.complete(store, text: String(repeating: "🦊", count: 2_049), reply: String(repeating: "é", count: 4_097))
        _ = try await f.complete(store, text: String(repeating: "é", count: 4_096), reply: "Accepted bounded reply")
        for number in 0..<20 {
            try await store.insert(f.memory(scope: .teammate(f.bot), title: "Metadata \(number)", offset: TimeInterval(number)))
        }
        let before = try await store.query(sql: "SELECT total_changes() AS changes;").first?.integer("changes")
        let started = ContinuousClock.now
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        let duration = started.duration(to: .now)
        let after = try await store.query(sql: "SELECT total_changes() AS changes;").first?.integer("changes")
        #expect(before == after)
        #expect(snapshot.recentMessages.count == 2 && snapshot.omissions.excludedMessageLowerBound == 2)
        #expect(snapshot.recentMessages.allSatisfy { $0.text.utf8.count <= 8_192 })
        #expect(snapshot.memoryDocuments.count == 8 && snapshot.omissions.memoryWindowHasMore)
        #expect(snapshot.receipt.memoryDocuments.count == 8)
        let indexed = try await store.query(sql: "EXPLAIN QUERY PLAN SELECT id FROM messages WHERE conversation_id=? AND sequence<? ORDER BY sequence DESC LIMIT 13;",
            bindings: [.text(f.chat.persistedValue), .integer(Int64.max)])
        #expect(try indexed.contains { try $0.text("detail").contains("INDEX") })
        let fts = try await store.query(sql: "EXPLAIN QUERY PLAN SELECT rowid FROM conversation_message_search WHERE conversation_message_search MATCH ? LIMIT 13;",
            bindings: [.text("\"bounded\"")])
        #expect(try fts.contains { try $0.text("detail").contains("VIRTUAL TABLE INDEX") })
        let correlation = try await store.query(sql: "EXPLAIN QUERY PLAN SELECT id FROM work_runs WHERE teammate_id=? AND conversation_id=? AND initiating_message_id=? AND state='succeeded' LIMIT 2;",
            bindings: [.text(f.bot.persistedValue), .text(f.chat.persistedValue), .text(MessageID(UUID()).persistedValue)])
        let memory = try await store.query(sql: """
            EXPLAIN QUERY PLAN SELECT d.id FROM memory_documents d WHERE d.scope_kind='teammate' AND d.scope_id=?
            AND NOT EXISTS(SELECT 1 FROM memory_documents child WHERE child.supersedes_id=d.id)
            ORDER BY d.updated_at DESC,d.id LIMIT 9;
            """, bindings: [.text(f.bot.persistedValue)])
        #expect(try correlation.contains { try $0.text("detail").contains("run_journal_owner_active") })
        #expect(try memory.contains { try $0.text("detail").contains("memory_scope") })
        print("Read-context diagnostic: bounded synthetic read in \(duration); no latency threshold or constant-work claim.")
        print("Read-context correlation plan: \(try correlation.map { try $0.text("detail") }.joined(separator: " | "))")
        print("Read-context memory plan: \(try memory.map { try $0.text("detail") }.joined(separator: " | "))")
    }

    @Test("Only current memory heads are returned, and selected receipts cannot invent or duplicate sources")
    func headSelectionAndReceipts() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let first = try f.memory(scope: .teammate(f.bot), title: "First")
        let second = try f.memory(scope: first.scope, title: "Second", predecessor: first)
        try await store.insert(first)
        try await store.insertRevision(second, expectedPredecessorID: first.id)
        let turn = try await f.complete(store, text: "Source", reply: "Reply")
        let snapshot = try await store.loadReadContextCandidates(f.request(store))
        #expect(snapshot.memoryDocuments == [second])
        #expect(throws: ReadContextError.invalidRequest) {
            try snapshot.receipt.selecting(messageIDs: [turn.replyID, turn.replyID], memoryDocumentIDs: [])
        }
        #expect(throws: ReadContextError.invalidRequest) {
            try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [first.id])
        }
        let empty = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [])
        try await store.revalidateReadContext(empty)
        // A fabricated stamp is still data and must not become authority.
        let wrong = ReadContextReceipt(conversationID: f.otherChat, teammateID: f.bot, profileRevision: 1,
            contextRevision: 0, selectedProjectID: nil, selectedTeamID: nil, participantJoinedAt: f.date,
            projectMembershipJoinedAt: nil, teamMembershipJoinedAt: nil, messages: [], memoryDocuments: [])
        await #expect(throws: ReadContextError.self) { try await store.revalidateReadContext(wrong) }
    }

    @Test("Keyword extraction and literal FTS are bounded and cannot inject query operators")
    func literalKeywords() async throws {
        #expect(ReadContextRequest.literalSearchTerms(from: "What was my launch color?") == ["launch", "color"])
        #expect(ReadContextRequest.literalSearchTerms(from: "launch LAUNCH color").count == 2)
        #expect(ReadContextRequest.literalSearchTerms(from: (0..<40).map { "keyword\($0)" }.joined(separator: " ")).count == 8)
        #expect(ReadContextRequest.literalSearchTerms(from: String(repeating: " ", count: 4_096) + "invisible").isEmpty)
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let old = try await f.complete(store, text: "alpha beta literal", reply: "alpha beta")
        for number in 0..<8 { _ = try await f.complete(store, text: "ordinary \(number)", reply: "weather \(number)") }
        let base = try await f.request(store)
        let query = try ReadContextRequest(conversationID: f.chat, teammateID: f.bot, profileRevision: 1,
            selection: base.selection, beforeSequence: base.beforeSequence, searchTerms: ["alpha", "OR", "missing"])
        let result = try await store.loadReadContextCandidates(query)
        #expect(Set(result.olderMessages.map(\.id)) == [old.userID, old.replyID])
    }
}

enum ReadContextInvalidTurn: CaseIterable, Equatable, Sendable { case failed, localFixture, malformedJSON, falseReply, unacknowledged, changedFrozenUser, extraPart }
enum ReadContextStaleSource: CaseIterable, Sendable { case message, profile, selectionRoundTrip, revoked, regranted, newMemoryHead, memoryMetadata }

private struct ReadContextTestTurn {
    let runID: RunID
    let userID: MessageID
    let replyID: MessageID
    let token: UUID
    let snapshot: TextTurnSnapshot
}

private struct ReadContextFixture {
    let directory: URL
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), otherBot = TeammateID(UUID())
    let chat = ConversationID(UUID()), otherChat = ConversationID(UUID())
    let projectA = ProjectID(UUID()), projectB = ProjectID(UUID())
    let protection: ProtectionDecisionReceipt

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextReadContext-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore) async throws {
        for (id, conversation) in [(bot, chat), (otherBot, otherChat)] {
            // Two bots never share a name, and the store now refuses a second one.
            let teammate = try Teammate(id: id, profile: TeammateProfile(displayName: id == bot ? "Context Bot" : "Other Context Bot", role: "Research"),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                    paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
                createdAt: date, updatedAt: date)
            try await store.provisionDirectChat(teammate: teammate,
                conversation: Conversation(id: conversation, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                fixtureGreeting: nil, selectConversation: false)
        }
        for project in [projectA, projectB] {
            try await store.insert(Project(id: project, name: "Project", createdAt: date, updatedAt: date))
            try await store.setMembership(ProjectMembership(projectID: project, teammateID: bot, joinedAt: date))
        }
    }
    func select(_ store: SQLiteStore, project: ProjectID?) async throws -> ConversationContextSelection {
        let current = try await store.loadContext(conversationID: chat)
        return try await store.saveContext(ConversationContextSelection(conversationID: chat, teammateID: bot,
            projectID: project, revision: current.revision))
    }
    func request(_ store: SQLiteStore, query: String = "") async throws -> ReadContextRequest {
        let selection = try await store.loadContext(conversationID: chat)
        return try ReadContextRequest(conversationID: chat, teammateID: bot, profileRevision: 1,
            selection: selection, beforeSequence: Int64.max, searchTerms: ReadContextRequest.literalSearchTerms(from: query))
    }
    func local(_ store: SQLiteStore, text: String) async throws -> MessageID {
        let last = try await store.page(conversationID: chat, request: PageRequest(limit: 1)).elements.last?.sequence ?? 0
        let message = try Message(id: MessageID(UUID()), conversationID: chat, sequence: last + 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: date, updatedAt: date)
        try await store.append(message, expectedPreviousSequence: last)
        return message.id
    }
    func begin(_ store: SQLiteStore, text: String, other: Bool = false, superseding: RunID? = nil,
               receipt: ReadContextReceipt? = nil) async throws -> ReadContextTestTurn {
        let conversation = other ? otherChat : chat, teammate = other ? otherBot : bot
        let last = try await store.page(conversationID: conversation, request: PageRequest(limit: 1)).elements.last?.sequence ?? 0
        let selection = try await store.loadContext(conversationID: conversation)
        let token = UUID(), reply = MessageID(UUID())
        let message = try Message(id: MessageID(UUID()), conversationID: conversation, sequence: last + 1, author: .user,
            deliveryState: .pending, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: date, updatedAt: date)
        let request = try WorkRequest(runID: RunID(UUID()), teammateID: teammate, conversationID: conversation,
            initiatingMessageID: message.id, selectedProjectID: selection.projectID, profileRevision: 1,
            initialInput: WorkInput(messageID: message.id, sequence: 1, text: text), submittedAt: date,
            textTurnIdentity: TextTurnIdentity(appOwnerID: UUID(), replyMessageID: reply, replyPartID: MessagePartID(UUID())),
            readContextReceipt: receipt, supersededRunID: superseding)
        let snapshot = try await store.beginTextTurn(request: request, userMessage: message, expectedPreviousSequence: last,
            ownerID: UUID(), token: token, now: date, leaseDuration: 60)
        return ReadContextTestTurn(runID: request.runID, userID: message.id, replyID: reply, token: token, snapshot: snapshot)
    }
    /// A turn stopped mid-reply, as Stop or a correction stops it: the request
    /// acknowledged, whatever was written saved, the run settled interrupted.
    func interrupt(_ store: SQLiteStore, text: String, partial: String) async throws -> ReadContextTestTurn {
        let turn = try await begin(store, text: text)
        var saved = try await store.checkpointTextTurn(id: turn.runID, expectedRevision: turn.snapshot.run.revision,
            token: turn.token, text: "", inputEvidence: .submitted, now: date.addingTimeInterval(1))
        saved = try await store.checkpointTextTurn(id: turn.runID, expectedRevision: saved.run.revision,
            token: turn.token, text: partial, inputEvidence: .acknowledged, now: date.addingTimeInterval(2))
        saved = try await store.finishTextTurn(id: turn.runID, expectedRevision: saved.run.revision,
            token: turn.token, text: partial, outcome: .interrupted, now: date.addingTimeInterval(3))
        return ReadContextTestTurn(runID: turn.runID, userID: turn.userID, replyID: turn.replyID, token: turn.token, snapshot: saved)
    }
    func complete(_ store: SQLiteStore, text: String, reply: String, other: Bool = false, succeeded: Bool = true,
                  superseding: RunID? = nil, receipt: ReadContextReceipt? = nil) async throws -> ReadContextTestTurn {
        let turn = try await begin(store, text: text, other: other, superseding: superseding, receipt: receipt)
        var saved = try await store.checkpointTextTurn(id: turn.runID, expectedRevision: turn.snapshot.run.revision,
            token: turn.token, text: "", inputEvidence: .submitted, now: date.addingTimeInterval(1))
        saved = try await store.checkpointTextTurn(id: turn.runID, expectedRevision: saved.run.revision,
            token: turn.token, text: "", inputEvidence: .acknowledged, now: date.addingTimeInterval(2))
        saved = try await store.finishTextTurn(id: turn.runID, expectedRevision: saved.run.revision,
            token: turn.token, text: reply, outcome: succeeded ? .succeeded : .failed, now: date.addingTimeInterval(3))
        return ReadContextTestTurn(runID: turn.runID, userID: turn.userID, replyID: turn.replyID, token: turn.token, snapshot: saved)
    }
    func memory(scope: MemoryScope, title: String, offset: TimeInterval = 0, predecessor: MemoryDocument? = nil) throws -> MemoryDocument {
        let id = MemoryDocumentID(UUID())
        let time = date.addingTimeInterval(offset)
        return try MemoryDocument(id: id, scope: scope, author: .user, title: title,
            relativePath: "synthetic/\(id.persistedValue).md", revision: (predecessor?.revision ?? 0) + 1,
            contentDigest: String(repeating: "a", count: 64), supersedes: predecessor?.id,
            createdAt: predecessor?.createdAt ?? time, updatedAt: predecessor?.updatedAt.addingTimeInterval(1) ?? time)
    }

    func receipt(basedOn base: ReadContextReceipt, messages: [ReadContextMessageReference] = [],
                 documents: [MemoryDocument] = []) throws -> ReadContextReceipt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let references = try documents.map { document in
            ReadContextMemoryReference(documentID: document.id, scope: document.scope, revision: document.revision,
                contentDigest: document.contentDigest,
                metadataDigest: SHA256.hash(data: try encoder.encode(document)).map { String(format: "%02x", $0) }.joined())
        }
        return ReadContextReceipt(conversationID: base.conversationID, teammateID: base.teammateID,
            profileRevision: base.profileRevision, contextRevision: base.contextRevision,
            selectedProjectID: base.selectedProjectID, selectedTeamID: base.selectedTeamID,
            participantJoinedAt: base.participantJoinedAt, projectMembershipJoinedAt: base.projectMembershipJoinedAt,
            teamMembershipJoinedAt: base.teamMembershipJoinedAt, messages: messages, memoryDocuments: references)
    }

    /// The reference a later receipt quotes this turn's reply by.
    func reference(_ store: SQLiteStore, to turn: ReadContextTestTurn, text: String) async throws -> ReadContextMessageReference {
        let message = try #require(try await store.message(id: turn.replyID))
        return ReadContextMessageReference(messageID: turn.replyID, runID: turn.runID, runRevision: turn.snapshot.run.revision,
            runUpdatedAt: turn.snapshot.run.updatedAt, sequence: message.sequence, messageUpdatedAt: message.updatedAt,
            selectedProjectID: nil, contentDigest: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Historical test fixture only: production admission now rejects this old
    /// policy. Editing its frozen receipt models data already saved before it,
    /// and data saved before migration 30 carries no stored proof, so the one
    /// admission wrote from the unedited receipt goes with the edit.
    func installHistoricalReceipt(_ receipt: ReadContextReceipt, for turn: ReadContextTestTurn, store: SQLiteStore) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json=json_set(request_json,'$.readContextReceipt',json(?)) WHERE run_id=?;",
            bindings: [.text(encoded), .text(turn.runID.persistedValue)])
        _ = try await store.execute(sql: "DELETE FROM read_context_turn_proofs WHERE run_id=?;",
            bindings: [.text(turn.runID.persistedValue)])
    }
}

// MARK: - A team room's handoff traffic and a lead's window

struct SQLiteReadContextTeamWindowTests {
    /// One completed text turn in a team conversation: the initiating message with
    /// the given author, answered by `teammate`. A lead's turn is authored by the
    /// user; a handoff leg is authored by the lead and answered by the member,
    /// exactly as the reply service writes them.
    private func turn(_ store: SQLiteStore, conversation: ConversationID, teammate: TeammateID,
                      author: MessageAuthor, text: String, reply: String, at date: Date,
                      handoffLegID: HandoffLegID? = nil) async throws {
        let last = try await store.page(conversationID: conversation, request: PageRequest(limit: 1)).elements.last?.sequence ?? 0
        let message = try Message(id: MessageID(UUID()), conversationID: conversation, sequence: last + 1, author: author,
            outputClass: handoffLegID == nil ? .conversation : .workAudit, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: date, updatedAt: date)
        let request = try WorkRequest(runID: RunID(UUID()), teammateID: teammate, conversationID: conversation,
            initiatingMessageID: message.id, selectedProjectID: nil, profileRevision: 1,
            initialInput: WorkInput(messageID: message.id, sequence: 1, text: text), submittedAt: date,
            textTurnIdentity: TextTurnIdentity(appOwnerID: UUID(), replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID()),
                handoffLegID: handoffLegID))
        let token = UUID()
        let begun = try await store.beginTextTurn(request: request, userMessage: message, expectedPreviousSequence: last,
            ownerID: UUID(), token: token, now: date, leaseDuration: 60)
        var saved = try await store.checkpointTextTurn(id: request.runID, expectedRevision: begun.run.revision,
            token: token, text: "", inputEvidence: .submitted, now: date.addingTimeInterval(1))
        saved = try await store.checkpointTextTurn(id: request.runID, expectedRevision: saved.run.revision,
            token: token, text: "", inputEvidence: .acknowledged, now: date.addingTimeInterval(2))
        _ = try await store.finishTextTurn(id: request.runID, expectedRevision: saved.run.revision,
            token: token, text: reply, outcome: .succeeded, now: date.addingTimeInterval(3))
    }

    /// A handoff leg as the reply service writes it: an accepted record, then a
    /// turn whose input is the brief authored by the sender and whose reply is
    /// the receiver's. Persistence admits the sender-authored input only for
    /// an accepted leg, so the record is real.
    private func leg(_ store: SQLiteStore, conversation: ConversationID, sender: TeammateID, receiver: TeammateID,
                     goal: String, reply: String, at date: Date) async throws {
        let brief = try HandoffBrief(goal: goal, constraints: ["Answer briefly"], inputReferences: ["The name above"],
            requestedOutput: "A short list", exclusions: ["No speculation"], stopOrApprovalBoundary: "Report only")
        var record = HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()),
            legID: HandoffLegID(UUID()), originConversationID: conversation, senderID: sender, receiverID: receiver, createdAt: date),
            brief: brief), sourceMessageID: nil)
        try await store.insert(record)
        try record.apply(.accept(at: date))
        try await store.update(record, expectedState: .staged)
        try await turn(store, conversation: conversation, teammate: receiver, author: .teammate(sender),
            text: "Handoff from Mira to Ada. Goal: \(goal)", reply: reply, at: date, handoffLegID: record.legID)
    }

    private func request(conversation: ConversationID, teammate: TeammateID) throws -> ReadContextRequest {
        try ReadContextRequest(conversationID: conversation, teammateID: teammate, profileRevision: 1,
            selection: ConversationContextSelection(conversationID: conversation, teammateID: teammate),
            beforeSequence: Int64.max, searchTerms: [])
    }

    @Test("Handoff briefs and another member's replies do not spend the lead's recent window")
    func handoffTrafficDoesNotEvictTheUsersRequest() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)
        var clock = f.date.addingTimeInterval(60)
        func tick() -> Date { clock = clock.addingTimeInterval(10); return clock }

        try await turn(store, conversation: conversation.id, teammate: f.mira, author: .user,
            text: "The person's name is Alpha Beta; audit her presence.", reply: "Noted: Alpha Beta. Asking Ada.", at: tick())
        // Five delegation rounds: each adds a lead turn, then a leg whose brief is
        // written by the lead and whose reply is the member's. Twenty-two rows in
        // all; only the twelve user/lead rows are the lead's to see.
        for round in 1...5 {
            try await turn(store, conversation: conversation.id, teammate: f.mira, author: .user,
                text: "Try again \(round)", reply: "Sending it to Ada again \(round).", at: tick())
            try await leg(store, conversation: conversation.id, sender: f.mira, receiver: f.ada,
                goal: "audit round \(round)", reply: "Ada's result \(round): no search.", at: tick())
        }

        let lead = try await store.loadReadContextCandidates(try request(conversation: conversation.id, teammate: f.mira))
        #expect(lead.recentMessages.count == ReadContextLimits.recentMessages)
        #expect(lead.recentMessages.first?.text == "The person's name is Alpha Beta; audit her presence.",
                "the user's request is still the oldest message in the lead's window")
        #expect(lead.recentMessages.contains { $0.text == "Noted: Alpha Beta. Asking Ada." })
        #expect(lead.recentMessages.allSatisfy { !$0.text.hasPrefix("Handoff from") && !$0.text.hasPrefix("Ada's result") },
                "a brief and a member's reply are never the lead's context")
        #expect(lead.recentMessages.allSatisfy { $0.author == .user || $0.author == .teammate(f.mira) })
        #expect(!lead.omissions.recentWindowHasMore && lead.omissions.excludedMessageLowerBound == 0)
        #expect(lead.recentMessages.map(\.sequence) == lead.recentMessages.map(\.sequence).sorted())

        // A member's leg answers the brief and nothing else: the room's user
        // messages initiated the lead's runs, not the member's, so the member is
        // shown no prior message at all. Unchanged by the window rule.
        let member = try await store.loadReadContextCandidates(try request(conversation: conversation.id, teammate: f.ada))
        #expect(member.recentMessages.isEmpty && member.olderMessages.isEmpty)
    }

    @Test("The recent window's look-back is bounded even when nothing in it is the lead's")
    func lookBackIsBounded() async throws {
        let f = try TeamChatStoreFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seedBots(store)
        let team = try f.team(store: store, members: [f.ada, f.mira], lead: f.mira)
        let conversation = try f.teamConversation(team)
        try await store.provisionTeam(team, conversation: conversation, selectConversation: false)
        var clock = f.date.addingTimeInterval(60)
        func tick() -> Date { clock = clock.addingTimeInterval(10); return clock }
        try await turn(store, conversation: conversation.id, teammate: f.mira, author: .user,
            text: "The one request.", reply: "Understood.", at: tick())
        // More leg rows than the scan bound, all authored by the lead's brief and
        // the member's reply: the one request is beyond the bounded look-back.
        for round in 1...(ReadContextLimits.recentCandidateScan / 2 + 1) {
            try await leg(store, conversation: conversation.id, sender: f.mira, receiver: f.ada,
                goal: "round \(round)", reply: "Result \(round)", at: tick())
        }
        let lead = try await store.loadReadContextCandidates(try request(conversation: conversation.id, teammate: f.mira))
        #expect(lead.recentMessages.isEmpty, "the scan stopped before it reached the request")
        // The room holds more rows than the scan looks at, so what lies beyond
        // it is unknown and the window says so. An empty window with nothing
        // omitted would have the assembler vouch for a complete context.
        #expect(lead.omissions.recentWindowHasMore)
    }
}
