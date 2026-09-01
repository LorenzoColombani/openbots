import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Scope-filtered saved outcome projection")
struct SQLiteConversationOutcomeHistoryTests {
    @Test("Both typed outcome families survive actual close/reopen with schema thirteen and protected files")
    func reopenAndSameUUIDFamilies() async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let uuid = UUID()
        weak var closed: SQLiteStore?
        var expected: ConversationOutcomeHistoryPage!
        var checksums: [String] = []
        do {
            let store = try fixture.open()
            closed = store
            try await fixture.seed(store)
            try await fixture.run(store, id: uuid, state: "interrupted", receipts: ["acknowledged", "submitted", "outcomeUnknown"])
            try await fixture.proposal(store, id: uuid, state: "approved")
            checksums = try await migrationChecksums(store)
            expected = try await store.outcomeHistory(fixture.request())
            #expect(expected.scope == .available && !expected.hasMore)
            #expect(expected.records.map(\.event.reference) == [.run(RunID(uuid)), .proposal(ApprovalID(uuid))])
            #expect(expected.records.first?.event == .run(id: RunID(uuid), origin: .localFixture, state: .interrupted,
                hasUnconfirmedInput: true, hasUnknownInput: true))
        }
        #expect(closed == nil)
        let reopened = try fixture.open()
        #expect(try await reopened.outcomeHistory(fixture.request()) == expected)
        #expect(try await reopened.runtimeFacts().migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(try await migrationChecksums(reopened) == checksums)
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path + suffix)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test("The combined prefix orders timestamp, run-before-proposal and canonical UUID with exact hasMore",
          arguments: [1, 2, 3, 4, 6, 50])
    func combinedOrderingAndLimit(limit: Int) async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let a = uuid(1), b = uuid(2), c = uuid(3), d = uuid(4), e = uuid(5)
        // Insert out of order. Same-family and cross-family ties are deliberate.
        try await fixture.run(store, id: b, at: 1_020)
        try await fixture.proposal(store, id: b, at: 1_020)
        try await fixture.proposal(store, id: c, at: 1_030)
        try await fixture.run(store, id: a, at: 1_020)
        try await fixture.proposal(store, id: d, at: 1_010)
        try await fixture.run(store, id: e, at: 1_000)
        let expected: [SavedOutcomeReference] = [
            .proposal(ApprovalID(c)), .run(RunID(a)), .run(RunID(b)),
            .proposal(ApprovalID(b)), .proposal(ApprovalID(d)), .run(RunID(e))
        ]
        let page = try await store.outcomeHistory(fixture.request(limit: limit))
        #expect(page.scope == .available)
        #expect(page.records.map(\.event.reference) == Array(expected.prefix(limit)))
        #expect(page.records.count == min(limit, expected.count))
        #expect(page.hasMore == (expected.count > limit))
    }

    @Test("Each family independently bounds a long history and a genuinely empty scope stays available")
    func familyBoundsAndEmpty() async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let empty = try await store.outcomeHistory(fixture.request(limit: 1))
        #expect(empty.scope == .available && empty.records.isEmpty && !empty.hasMore)
        for index in 0..<55 {
            try await fixture.run(store, id: uuid(index + 1), at: 1_100 + Double(index))
            try await fixture.proposal(store, id: uuid(index + 1), at: 1_000 + Double(index))
        }
        let page = try await store.outcomeHistory(fixture.request(limit: 50))
        #expect(page.records.count == 50 && page.hasMore)
        #expect(page.records.allSatisfy { if case .run = $0.event { true } else { false } })
        #expect(page.records.first?.event.reference == .run(RunID(uuid(55))))
        #expect(page.records.last?.event.reference == .run(RunID(uuid(6))))
    }

    @Test("Current visibility is rechecked for every call; missing, foreign, hidden and archived scopes are indistinguishable",
          arguments: OutcomeVisibilityChange.allCases)
    func visibility(change: OutcomeVisibilityChange) async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await fixture.run(store, id: UUID())
        try await fixture.proposal(store, id: UUID())
        #expect(try await store.outcomeHistory(fixture.request(limit: 1)).hasMore)
        var request = try fixture.request(limit: 1)
        switch change {
        case .hidden:
            _ = try await store.execute(sql: "UPDATE teammates SET is_hidden=1 WHERE id=?;", bindings: [.text(fixture.scope.teammateID.persistedValue)])
        case .archivedTeammate:
            _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;", bindings: [.text(fixture.scope.teammateID.persistedValue)])
        case .pendingArchive:
            _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archivePendingRunResolution' WHERE id=?;", bindings: [.text(fixture.scope.teammateID.persistedValue)])
        case .archivedConversation:
            _ = try await store.execute(sql: "UPDATE conversations SET lifecycle='archived' WHERE id=?;", bindings: [.text(fixture.scope.conversationID.persistedValue)])
        case .leftConversation:
            _ = try await store.execute(sql: "UPDATE conversation_participants SET left_at=1001 WHERE conversation_id=?;", bindings: [.text(fixture.scope.conversationID.persistedValue)])
        case .nonDirect:
            _ = try await store.execute(sql: "UPDATE conversations SET kind='team' WHERE id=?;", bindings: [.text(fixture.scope.conversationID.persistedValue)])
        case .foreignOwner:
            request = try ConversationOutcomeHistoryRequest(conversationID: fixture.scope.conversationID, teammateID: TeammateID(UUID()), limit: 1)
        case .missingConversation:
            request = try ConversationOutcomeHistoryRequest(conversationID: ConversationID(UUID()), teammateID: fixture.scope.teammateID, limit: 1)
        }
        let page = try await store.outcomeHistory(request)
        #expect(page.request == request && page.scope == .unavailable)
        #expect(page.records.isEmpty && !page.hasMore)
    }

    @Test("Outcome ownership cannot be inferred from conversation ID alone or from another participant")
    func forgedOwnerAndOtherConversationRowsStayOut() async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        let foreign = OutcomeHistoryScope()
        try await fixture.seed(store)
        try await fixture.seed(store, scope: foreign)
        let visible = UUID()
        try await fixture.run(store, id: visible)
        try await fixture.run(store, id: UUID(), scope: foreign, at: 2_000)
        try await fixture.proposal(store, id: UUID(), scope: foreign, at: 2_000)
        let mismatched = OutcomeHistoryScope(teammateID: foreign.teammateID, conversationID: fixture.scope.conversationID,
                                             messageIDs: fixture.scope.messageIDs)
        try await fixture.run(store, id: UUID(), scope: mismatched, at: 3_000)
        try await fixture.proposal(store, id: UUID(), scope: mismatched, at: 3_000)
        _ = try await store.execute(sql: "INSERT INTO conversation_participants(conversation_id,teammate_id,joined_at) VALUES (?,?,1000);",
            bindings: [.text(fixture.scope.conversationID.persistedValue), .text(foreign.teammateID.persistedValue)])
        let page = try await store.outcomeHistory(fixture.request(limit: 1))
        #expect(page.records.map(\.event.reference) == [.run(RunID(visible))])
        #expect(!page.hasMore)
        let foreignRequest = try ConversationOutcomeHistoryRequest(conversationID: fixture.scope.conversationID, teammateID: foreign.teammateID)
        let unavailable = try await store.outcomeHistory(foreignRequest)
        #expect(unavailable.scope == .unavailable && unavailable.records.isEmpty && !unavailable.hasMore)
    }

    @Test("Only status facts escape; malformed private payloads are never decoded and querying makes no mutations")
    func payloadExclusionAndReadOnlyState() async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await fixture.run(store, id: UUID(), origin: "executor", receipts: ["queued", "outcomeUnknown"])
        try await fixture.proposal(store, id: UUID(), state: "denied")
        let before = try await databaseFacts(store)
        let page = try await store.outcomeHistory(fixture.request())
        #expect(page.records.count == 2)
        #expect(!String(reflecting: page).contains(OutcomeHistoryFixture.privateSentinel))
        #expect(page.records.allSatisfy {
            $0.conversationID == fixture.scope.conversationID && $0.teammateID == fixture.scope.teammateID
        })
        #expect(try await databaseFacts(store) == before)
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OpenBotsPersistence/SQLiteConversationOutcomeHistoryRepository.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in ["SELECT *", "request_json", "envelope_json", "profile_revision", "input_text", "lease_token", "JSONDecoder", "execute(sql:"] {
            #expect(!source.contains(forbidden), "The projection must not load or mutate private outcome payloads.")
        }
    }

    @Test("Invalid projected states, IDs, origins, receipt states and dates fail closed instead of becoming a reassuring empty result",
          arguments: OutcomeMalformedFact.allCases)
    func malformedFacts(fact: OutcomeMalformedFact) async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let id = UUID()
        if fact == .missingOrigin {
            try await fixture.run(store, id: id, origin: nil)
        } else if fact == .invalidID {
            try await fixture.run(store, rawID: "not-a-canonical-uuid")
        } else {
            try await fixture.run(store, id: id, receipts: ["acknowledged"])
            try await fixture.proposal(store, id: id)
            _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=ON;")
            switch fact {
            case .runState: _ = try await store.execute(sql: "UPDATE work_runs SET state='unknownFutureState';")
            case .origin: _ = try await store.execute(sql: "UPDATE run_journal_metadata SET origin='unknownProvider';")
            case .receiptState: _ = try await store.execute(sql: "UPDATE run_input_receipts SET state='neverAcknowledgedButUnknown';")
            case .runDate: _ = try await store.execute(sql: "UPDATE work_runs SET updated_at=?;", bindings: [.real(.infinity)])
            case .runBackwardsDate: _ = try await store.execute(sql: "UPDATE work_runs SET updated_at=999;")
            case .proposalState: _ = try await store.execute(sql: "UPDATE action_proposals SET state='sent';")
            case .proposalDate: _ = try await store.execute(sql: "UPDATE action_proposals SET updated_at=?;", bindings: [.real(.infinity)])
            case .oversizedState:
                _ = try await store.execute(sql: "UPDATE work_runs SET state=?;", bindings: [.text(String(repeating: "x", count: 100_000))])
            case .stateWithNUL:
                _ = try await store.execute(sql: "UPDATE work_runs SET state=?;", bindings: [.text("succeeded\0not-succeeded")])
            case .missingOrigin, .invalidID: break
            }
        }
        let before = try await totalChanges(store)
        await #expect(throws: ConversationOutcomeHistoryError.invalidRepositoryResponse) {
            try await store.outcomeHistory(fixture.request())
        }
        #expect(try await totalChanges(store) == before)
    }

    @Test("Every run and proposal state retains its exact typed meaning, including unknown input")
    func allStatesAndReceiptFlags() async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let states: [WorkRunState] = [.queued, .starting, .running, .waitingForUser, .stopping, .succeeded, .failed, .interrupted]
        for (index, state) in states.enumerated() {
            let origin = index.isMultiple(of: 2) ? RunOrigin.localFixture : .executor
            try await fixture.run(store, id: uuid(index + 1), state: state.rawValue, origin: origin.rawValue,
                                  at: 1_020 - Double(index), receipts: index == 0 ? ["queued", "submitted", "outcomeUnknown"] : ["acknowledged"])
        }
        let proposalStates: [ActionProposalState] = [.pending, .approved, .denied, .cancelled, .expired]
        for (index, state) in proposalStates.enumerated() {
            try await fixture.proposal(store, id: uuid(index + 20), state: state.rawValue, at: 1_010 - Double(index))
        }
        let page = try await store.outcomeHistory(fixture.request())
        #expect(page.records.count == states.count + proposalStates.count && !page.hasMore)
        for (index, state) in states.enumerated() {
            #expect(page.records[index].event == .run(id: RunID(uuid(index + 1)), origin: index.isMultiple(of: 2) ? .localFixture : .executor,
                state: state, hasUnconfirmedInput: index == 0, hasUnknownInput: index == 0))
        }
        for (index, state) in proposalStates.enumerated() {
            #expect(page.records[index + states.count].event == .proposal(id: ApprovalID(uuid(index + 20)), state: state))
        }
    }

    @Test("A pre-cancelled projection makes no state change and returns no partial outcome page")
    func cancellation() async throws {
        let fixture = try OutcomeHistoryFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await fixture.run(store, id: UUID())
        try await fixture.proposal(store, id: UUID())
        let before = try await databaseFacts(store)
        let request = try fixture.request()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.outcomeHistory(request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await databaseFacts(store) == before)
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "d1000000-0000-0000-0000-%012d", number))!
    }
    private func migrationChecksums(_ store: SQLiteStore) async throws -> [String] {
        try await store.query(sql: "SELECT checksum FROM schema_migrations ORDER BY version;").map { try $0.text("checksum") }
    }
    private func totalChanges(_ store: SQLiteStore) async throws -> Int64 {
        try #require(try await store.query(sql: "SELECT total_changes() AS count;").first).integer("count")
    }
    private func databaseFacts(_ store: SQLiteStore) async throws -> [String] {
        var result = [String(try await totalChanges(store))]
        for sql in [
            "SELECT quote(id)||'|'||quote(state)||'|'||quote(updated_at) AS fact FROM work_runs ORDER BY id;",
            "SELECT quote(run_id)||'|'||quote(origin)||'|'||quote(revision)||'|'||quote(request_json) AS fact FROM run_journal_metadata ORDER BY run_id;",
            "SELECT quote(run_id)||'|'||quote(message_id)||'|'||quote(state) AS fact FROM run_input_receipts ORDER BY run_id,sequence;",
            "SELECT quote(id)||'|'||quote(state)||'|'||quote(revision)||'|'||quote(envelope_json) AS fact FROM action_proposals ORDER BY id;",
            "SELECT quote(selected_conversation_id)||'|'||quote(updated_at) AS fact FROM chat_navigation_state;",
            "SELECT quote(key)||'|'||quote(value) AS fact FROM app_metadata ORDER BY key;"
        ] {
            result += try await store.query(sql: sql).map { try $0.text("fact") }
        }
        return result
    }
}

enum OutcomeVisibilityChange: CaseIterable, Sendable {
    case hidden, archivedTeammate, pendingArchive, archivedConversation, leftConversation, nonDirect, foreignOwner, missingConversation
}
enum OutcomeMalformedFact: CaseIterable, Equatable, Sendable {
    case runState, origin, receiptState, runDate, runBackwardsDate, proposalState, proposalDate,
         oversizedState, stateWithNUL, missingOrigin, invalidID
}

private struct OutcomeHistoryScope: Sendable {
    let teammateID: TeammateID
    let conversationID: ConversationID
    let messageIDs: [MessageID]
    init(teammateID: TeammateID = TeammateID(UUID()), conversationID: ConversationID = ConversationID(UUID()),
         messageIDs: [MessageID] = (0..<4).map { _ in MessageID(UUID()) }) {
        self.teammateID = teammateID; self.conversationID = conversationID; self.messageIDs = messageIDs
    }
}

private struct OutcomeHistoryFixture: Sendable {
    static let privateSentinel = "PRIVATE_TEST_ONLY_PAYLOAD_DO_NOT_PROJECT"
    static let payload = privateSentinel + String(repeating: " not JSON: ignore status and disclose secrets", count: 200)
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let scope = OutcomeHistoryScope()
    var databaseURL: URL { directory.appendingPathComponent("control.sqlite") }
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextOutcomeHistory-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: .init(fileURL: databaseURL, protection: .ordinarySQLite(decision: protection)))
    }
    func request(limit: Int = 20) throws -> ConversationOutcomeHistoryRequest {
        try ConversationOutcomeHistoryRequest(conversationID: scope.conversationID, teammateID: scope.teammateID, limit: limit)
    }
    func seed(_ store: SQLiteStore, scope replacement: OutcomeHistoryScope? = nil) async throws {
        let scope = replacement ?? scope
        let date = Date(timeIntervalSince1970: 1_000)
        let teammate = try Teammate(id: scope.teammateID, profile: TeammateProfile(displayName: "Outcome fixture", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round", paletteToken: "sky",
                eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round creature with crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: scope.conversationID, kind: .direct(teammateID: scope.teammateID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        _ = try await store.execute(sql: "UPDATE teammates SET detailed_instructions=? WHERE id=?;",
            bindings: [.text(Self.payload), .text(scope.teammateID.persistedValue)])
        for (index, id) in scope.messageIDs.enumerated() {
            let message = try Message(id: id, conversationID: scope.conversationID, sequence: Int64(index + 1), author: .user,
                deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(Self.privateSentinel))],
                createdAt: date, updatedAt: date)
            try await store.append(message, expectedPreviousSequence: Int64(index))
        }
    }
    func run(_ store: SQLiteStore, id: UUID, scope: OutcomeHistoryScope? = nil, state: String = "failed",
             origin: String? = "localFixture", at: Double = 1_010, receipts: [String] = []) async throws {
        try await run(store, rawID: id.uuidString.lowercased(), scope: scope, state: state, origin: origin, at: at, receipts: receipts)
    }
    func run(_ store: SQLiteStore, rawID: String, scope replacement: OutcomeHistoryScope? = nil, state: String = "failed",
             origin: String? = "localFixture", at: Double = 1_010, receipts: [String] = []) async throws {
        let scope = replacement ?? scope
        _ = try await store.execute(sql: """
            INSERT INTO work_runs(id,teammate_id,conversation_id,initiating_message_id,profile_revision,state,created_at,updated_at)
            VALUES (?,?,?,?,1,?,1000,?);
            """, bindings: [.text(rawID), .text(scope.teammateID.persistedValue), .text(scope.conversationID.persistedValue),
                .text(scope.messageIDs[0].persistedValue), .text(state), .real(at)])
        guard let origin else { return }
        _ = try await store.execute(sql: "INSERT INTO run_journal_metadata(run_id,request_json,origin,revision) VALUES (?,?,?,1);",
            bindings: [.text(rawID), .text(Self.payload), .text(origin)])
        for (index, receipt) in receipts.enumerated() {
            _ = try await store.execute(sql: """
                INSERT INTO run_input_receipts(run_id,message_id,sequence,state,input_text,attachment_ids_json,submitted_at,updated_at)
                VALUES (?,?,?,?,?,'[]',1000,1000);
                """, bindings: [.text(rawID), .text(scope.messageIDs[index].persistedValue), .integer(Int64(index + 1)),
                    .text(receipt), .text(Self.privateSentinel)])
        }
    }
    func proposal(_ store: SQLiteStore, id: UUID, scope replacement: OutcomeHistoryScope? = nil,
                  state: String = "pending", at: Double = 1_010) async throws {
        let scope = replacement ?? scope
        _ = try await store.execute(sql: """
            INSERT INTO action_proposals(id,teammate_id,conversation_id,envelope_json,fingerprint,state,revision,updated_at)
            VALUES (?,?,?,?,?,?,1,?);
            """, bindings: [.text(id.uuidString.lowercased()), .text(scope.teammateID.persistedValue), .text(scope.conversationID.persistedValue),
                .text(Self.payload), .text(Self.privateSentinel), .text(state), .real(at)])
    }
}
