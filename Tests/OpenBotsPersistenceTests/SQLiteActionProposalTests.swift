import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Durable non-live universal proposals")
struct SQLiteActionProposalTests {
    @Test("Every consequential class persists and reopens without granting execution")
    func taxonomyAndReopen() async throws {
        let f = try ProposalFixture(); defer { f.remove() }
        var saved: [ActionProposalRecord] = []
        weak var old: SQLiteStore?
        do {
            let store = try f.open(); old = store; try await f.seed(store)
            for action in ConsequentialActionKind.allCases {
                let pending = try await store.insertProposal(f.proposal(action: action))
                saved.append(try await store.decideProposal(pending, decision: .approve, now: f.date.addingTimeInterval(1)))
            }
            for suffix in ["", "-wal", "-shm"] {
                let attrs = try FileManager.default.attributesOfItem(atPath: f.url.path + suffix)
                #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            #expect(try await store.query(sql: "SELECT COUNT(*) AS n FROM capability_grants;").first?.integer("n") == 0)
            #expect(try await store.query(sql: "SELECT COUNT(*) AS n FROM work_runs;").first?.integer("n") == 0)
        }
        #expect(old == nil)
        let reopened = try f.open()
        let actual = try await reopened.proposals(conversationID: f.conversationID, limit: 100)
        #expect(Set(actual.map(\.id)) == Set(saved.map(\.id)))
        #expect(actual.allSatisfy { $0.state == .approved && $0.proposal.origin == .localFixture })
        for item in saved { #expect(actual.contains(item)) }
    }

    @Test("Exact frozen bytes, state, revision, and fingerprint are required")
    func tamperingAndReplay() async throws {
        let f = try ProposalFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let record = try await store.insertProposal(f.proposal())
        let changed = try f.proposal(id: record.id, payload: "different instructions")
        let forged = ActionProposalRecord(proposal: changed, fingerprint: record.fingerprint,
            state: .pending, revision: 1, updatedAt: record.updatedAt)
        await #expect(throws: ActionProposalError.staleReview) { try await store.decideProposal(forged, decision: .approve, now: f.date) }
        let approved = try await store.decideProposal(record, decision: .approve, now: f.date)
        await #expect(throws: ActionProposalError.staleReview) { try await store.decideProposal(record, decision: .approve, now: f.date) }
        let cancelled = try await store.decideProposal(approved, decision: .cancel, now: f.date)
        #expect(cancelled.state == .cancelled && cancelled.revision == 3)
        await #expect(throws: ActionProposalError.invalidTransition) { try await store.decideProposal(cancelled, decision: .approve, now: f.date) }
        #expect(try await store.query(sql: "SELECT COUNT(*) AS n FROM action_proposal_events;").first?.integer("n") == 3)
    }

    @Test("Only one of two independent connections can resolve the same review")
    func competingDecisions() async throws {
        let f = try ProposalFixture(); defer { f.remove() }
        let first = try f.open(); try await f.seed(first); let second = try f.open()
        let review = try await first.insertProposal(f.proposal())
        func decide(_ store: SQLiteStore, _ decision: ActionProposalDecision) async -> Bool {
            do { _ = try await store.decideProposal(review, decision: decision, now: f.date); return true }
            catch { return false }
        }
        async let a = decide(first, .approve)
        async let b = decide(second, .deny)
        let outcomes = await [a, b]
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try await first.proposals(conversationID: f.conversationID, limit: 10).first?.revision == 2)
    }

    @Test("Expired or changed-context approval fails closed, but dismissal remains possible")
    func expiryAndContext() async throws {
        let f = try ProposalFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let pending = try await store.insertProposal(f.proposal())
        await #expect(throws: ActionProposalError.expired) {
            try await store.decideProposal(pending, decision: .approve, now: f.date.addingTimeInterval(60))
        }
        #expect(try await store.decideProposal(pending, decision: .expire, now: f.date.addingTimeInterval(60)).state == .expired)
        let next = try await store.insertProposal(f.proposal())
        _ = try await store.execute(sql: "UPDATE teammates SET profile_revision=2 WHERE id=?;", bindings: [.text(f.teammateID.persistedValue)])
        await #expect(throws: ActionProposalError.contextChanged) { try await store.decideProposal(next, decision: .approve, now: f.date) }
        #expect(try await store.decideProposal(next, decision: .deny, now: f.date).state == .denied)
    }

    @Test("Cross-chat identity, invalid limits and clock rollback are refused")
    func scopeAndClock() async throws {
        let f = try ProposalFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        await #expect(throws: ActionProposalError.contextChanged) {
            try await store.insertProposal(f.proposal(conversationID: ConversationID(UUID())))
        }
        await #expect(throws: ActionProposalError.invalidLimit) { try await store.proposals(conversationID: f.conversationID, limit: 101) }
        let record = try await store.insertProposal(f.proposal())
        await #expect(throws: ActionProposalError.clockMovedBackwards) { try await store.decideProposal(record, decision: .approve, now: f.date.addingTimeInterval(-1)) }
        #expect(try await store.proposals(conversationID: ConversationID(UUID()), limit: 10).isEmpty)
    }

    @Test("Journal failure rolls back a decision and altered persisted envelopes fail closed")
    func rollbackAndCorruption() async throws {
        let f = try ProposalFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let record = try await store.insertProposal(f.proposal())
        _ = try await store.execute(sql: "CREATE TRIGGER reject_proposal_event BEFORE INSERT ON action_proposal_events BEGIN SELECT RAISE(ABORT,'injected'); END;")
        await #expect(throws: SQLiteStoreError.self) { try await store.decideProposal(record, decision: .approve, now: f.date) }
        #expect(try await store.proposals(conversationID: f.conversationID, limit: 10) == [record])
        _ = try await store.execute(sql: "UPDATE action_proposals SET fingerprint='forged';")
        await #expect(throws: ActionProposalError.invalid) { try await store.proposals(conversationID: f.conversationID, limit: 10) }
    }

    @Test("Canonical bytes distinguish meaningful changes and reject unsafe shapes")
    func envelopeValidation() throws {
        let f = try ProposalFixture(); defer { f.remove() }
        let first = try f.proposal(payload: "é")
        let second = try f.proposal(id: first.id, payload: "e\u{301}")
        #expect(try first.fingerprint() != second.fingerprint())
        #expect(throws: ActionProposalError.invalid) { try f.proposal(payload: String(repeating: "x", count: 16_385)) }
        #expect(throws: ActionProposalError.invalid) { try f.proposal(payload: "\0") }
    }
}

private struct ProposalFixture: Sendable {
    let root: URL
    let protectionReceipt: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let date = Date(timeIntervalSince1970: 1_000)
    var url: URL { root.appendingPathComponent("control.sqlite") }
    init() throws {
        protectionReceipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(timeIntervalSince1970: 1_000), rationaleVersion: 2)
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsProposalTests-\(UUID()).noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: url, protection: .ordinarySQLite(decision: protectionReceipt)))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(id: teammateID, profile: TeammateProfile(displayName: "Proposal Demo", role: "Local review"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"), createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: teammateID), createdAt: date, updatedAt: date), fixtureGreeting: nil, selectConversation: false)
    }
    func proposal(id: ApprovalID = ApprovalID(UUID()), conversationID: ConversationID? = nil,
                  action: ConsequentialActionKind = .send, payload: String = "Synthetic payload") throws -> ActionProposal {
        try ActionProposal(id: id, teammateID: teammateID, conversationID: conversationID ?? self.conversationID,
            profileRevision: 1, contextRevision: 0, action: action, target: "Synthetic target", payload: payload,
            consequence: "Only a local record changes. Nothing executes.", createdAt: date, expiresAt: date.addingTimeInterval(60))
    }
}
