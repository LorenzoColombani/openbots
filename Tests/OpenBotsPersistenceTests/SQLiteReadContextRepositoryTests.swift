import CryptoKit
import Foundation
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

    @Test("History ancestry work is bounded even when every source is in the same allowed scope")
    func oversizedHistoryGraphIsOmitted() async throws {
        let f = try ReadContextFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let empty = try await store.loadReadContextCandidates(f.request(store))
        var previous: ReadContextMessageReference?
        // Exceeds the 64 distinct-run ceiling without loading any memory file.
        for index in 0..<66 {
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
        #expect(snapshot.recentMessages.isEmpty && snapshot.olderMessages.isEmpty)
        #expect(snapshot.omissions.excludedMessageLowerBound == ReadContextLimits.recentMessages)
        #expect(try await store.runs(conversationID: f.chat, limit: 100).count == 66)
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
            let teammate = try Teammate(id: id, profile: TeammateProfile(displayName: "Context Bot", role: "Research"),
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
    func begin(_ store: SQLiteStore, text: String, other: Bool = false) async throws -> ReadContextTestTurn {
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
            textTurnIdentity: TextTurnIdentity(appOwnerID: UUID(), replyMessageID: reply, replyPartID: MessagePartID(UUID())))
        let snapshot = try await store.beginTextTurn(request: request, userMessage: message, expectedPreviousSequence: last,
            ownerID: UUID(), token: token, now: date, leaseDuration: 60)
        return ReadContextTestTurn(runID: request.runID, userID: message.id, replyID: reply, token: token, snapshot: snapshot)
    }
    func complete(_ store: SQLiteStore, text: String, reply: String, other: Bool = false, succeeded: Bool = true) async throws -> ReadContextTestTurn {
        let turn = try await begin(store, text: text, other: other)
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

    /// Historical test fixture only: production admission now rejects this old
    /// policy. Editing its frozen receipt models data already saved before it.
    func installHistoricalReceipt(_ receipt: ReadContextReceipt, for turn: ReadContextTestTurn, store: SQLiteStore) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        _ = try await store.execute(sql: "UPDATE run_journal_metadata SET request_json=json_set(request_json,'$.readContextReceipt',json(?)) WHERE run_id=?;",
            bindings: [.text(encoded), .text(turn.runID.persistedValue)])
    }
}
