import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Durable universal action proposal fixture")
struct ActionProposalFixtureServiceTests {
    @Test("Construction and list loading are inert and bounded")
    func inertConstruction() async throws {
        let data = try ProposalTestIdentity()
        let repository = ProposalRepositoryDouble(identity: data)
        let clock = ProposalServiceClock()
        let ids = ProposalServiceIDs()
        let service = ActionProposalFixtureService(repository: repository, teammateRepository: repository,
            contextRepository: repository, clock: clock, ids: ids)
        #expect(await repository.reads == 0)
        #expect(await repository.writes == 0)
        #expect(clock.calls == 0 && ids.calls == 0)
        #expect(try await service.proposals(conversationID: data.conversation.id).isEmpty)
        #expect(await repository.reads == 1)
        #expect(await repository.writes == 0)
        #expect(await repository.lastLimit == 10)
        #expect(clock.calls == 0 && ids.calls == 0)
    }

    @Test("Every consequential action uses the same persisted non-executable envelope", arguments: ConsequentialActionKind.allCases)
    func allActionKinds(_ action: ConsequentialActionKind) async throws {
        let fixture = try ProposalSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let proposed = try await service.prepare(conversationID: fixture.identity.conversation.id, action: action)
        #expect(ConsequentialActionKind.allCases.count == 14)
        #expect(proposed.proposal.action == action && proposed.proposal.origin == .localFixture)
        #expect(proposed.proposal.runID == nil)
        #expect(proposed.proposal.target.contains("Synthetic"))
        #expect(proposed.proposal.payload.contains("demonstration only"))
        #expect(proposed.proposal.consequence.contains("nothing can execute"))
        #expect(proposed.state == .pending && proposed.revision == 1)
        #expect(proposed.fingerprint == (try proposed.proposal.fingerprint()))
        let approved = try await service.decide(proposed, decision: .approve)
        #expect(approved.state == .approved && approved.revision == 2)
        #expect(try approved.proposal.canonicalData() == proposed.proposal.canonicalData())
        #expect(try await store.activeGrants(teammateID: fixture.identity.teammate.id).isEmpty)
        #expect(try await store.page(conversationID: fixture.identity.conversation.id, request: PageRequest(limit: 10)).elements.isEmpty)
        #expect(try await store.runs(conversationID: fixture.identity.conversation.id, limit: 10).isEmpty)
    }

    @Test("Approve, deny and cancel history survives a real SQLite connection close and reopen")
    func decisionsSurviveReopen() async throws {
        let fixture = try ProposalSQLiteFixture()
        defer { fixture.remove() }
        let saved = try await persistDecisions(fixture)
        #expect(saved.weak.value == nil)
        let store = try fixture.open()
        let service = fixture.service(store)
        let reloaded = try await service.proposals(conversationID: fixture.identity.conversation.id)
        #expect(Set(reloaded.map(\.id)) == Set(saved.records.map(\.id)))
        for expected in saved.records { #expect(reloaded.first(where: { $0.id == expected.id }) == expected) }
        #expect(try await store.query(sql: "SELECT count(*) AS count FROM action_proposal_events;").first?.integer("count") == 7)
        #expect(try await store.activeGrants(teammateID: fixture.identity.teammate.id).isEmpty)
    }

    @Test("Changed bytes, fingerprint or route cannot consume the originally reviewed proposal")
    func tamperedReview() async throws {
        let fixture = try ProposalSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let envelope = try fixture.proposal(payload: "e\u{301}")
        let original = try await store.insertProposal(envelope)
        let changed = try replacing(envelope, payload: "é")
        #expect(changed.payload == envelope.payload)
        #expect(try changed.canonicalData() != envelope.canonicalData())
        for proposal in [changed, try replacing(envelope, target: envelope.target + " "),
                         try replacing(envelope, conversationID: ConversationID(UUID())),
                         try replacing(envelope, teammateID: TeammateID(UUID()))] {
            let tampered = ActionProposalRecord(proposal: proposal, fingerprint: try proposal.fingerprint(),
                state: original.state, revision: original.revision, updatedAt: original.updatedAt)
            await #expect(throws: ActionProposalError.staleReview) { try await service.decide(tampered, decision: .approve) }
            #expect(try await service.proposals(conversationID: fixture.identity.conversation.id) == [original])
        }
        let wrongFingerprint = ActionProposalRecord(proposal: original.proposal, fingerprint: String(repeating: "0", count: 64),
            state: original.state, revision: original.revision, updatedAt: original.updatedAt)
        await #expect(throws: ActionProposalError.invalid) { try await service.decide(wrongFingerprint, decision: .approve) }
        #expect(try await service.decide(original, decision: .approve).state == .approved)
        await #expect(throws: ActionProposalError.staleReview) { try await service.decide(original, decision: .deny) }
    }

    @Test("Changed profile or context blocks approval but never silently drops the frozen proposal")
    func contextChanges() async throws {
        for changeProfile in [false, true] {
            let fixture = try ProposalSQLiteFixture()
            defer { fixture.remove() }
            let store = try fixture.open()
            try await fixture.seed(store)
            let service = fixture.service(store)
            let original = try await service.prepare(conversationID: fixture.identity.conversation.id, action: .permissionChange)
            if changeProfile {
                var teammate = fixture.identity.teammate
                teammate.profile = try teammate.profile.revised(role: "Changed responsibilities")
                try await store.update(teammate, expectedProfileRevision: fixture.identity.teammate.profile.revision)
            } else {
                _ = try await store.saveContext(.init(conversationID: fixture.identity.conversation.id, teammateID: fixture.identity.teammate.id))
            }
            await #expect(throws: ActionProposalError.contextChanged) { try await service.decide(original, decision: .approve) }
            #expect(try await service.proposals(conversationID: fixture.identity.conversation.id) == [original])
            #expect(try await service.decide(original, decision: .cancel).state == .cancelled)
        }
    }

    @Test("Expiry is exact and explicit; list does not mutate an expired pending proposal")
    func expiry() async throws {
        let fixture = try ProposalSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let original = try await service.prepare(conversationID: fixture.identity.conversation.id, action: .send)
        fixture.clock.set(original.proposal.expiresAt)
        #expect(try await service.proposals(conversationID: fixture.identity.conversation.id) == [original])
        await #expect(throws: ActionProposalError.expired) { try await service.decide(original, decision: .approve) }
        let expired = try await service.decide(original, decision: .expire)
        #expect(expired.state == .expired && expired.revision == 2)
        #expect(try await store.activeGrants(teammateID: fixture.identity.teammate.id).isEmpty)
    }

    @Test("Concurrent decisions have one durable winner and no ambient action")
    func concurrentDecisions() async throws {
        let fixture = try ProposalSQLiteFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let original = try await service.prepare(conversationID: fixture.identity.conversation.id, action: .packageInstall)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                group.addTask {
                    do { _ = try await service.decide(original, decision: index % 2 == 0 ? .approve : .deny); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(try await service.proposals(conversationID: fixture.identity.conversation.id).first?.revision == 2)
        #expect(try await store.query(sql: "SELECT count(*) AS count FROM action_proposal_events;").first?.integer("count") == 2)
    }

    @Test("Malformed repository receipts fail locally without another write or hidden retry")
    func invalidRepositoryResponses() async throws {
        for mutation in ["fingerprint", "conversation", "revision", "state"] {
            let identity = try ProposalTestIdentity()
            let repository = ProposalRepositoryDouble(identity: identity, mutation: mutation)
            let service = ActionProposalFixtureService(repository: repository, teammateRepository: repository,
                contextRepository: repository, clock: ProposalServiceClock())
            await #expect(throws: ActionProposalError.invalid) {
                try await service.prepare(conversationID: identity.conversation.id, action: .send)
            }
            #expect(await repository.writes == 1)
        }
    }

    @Test("A backdated decision receipt cannot be accepted as the newly saved decision")
    func backdatedDecisionReceipt() async throws {
        let identity = try ProposalTestIdentity()
        let repository = ProposalRepositoryDouble(identity: identity, mutation: "backdatedDecision")
        let clock = ProposalServiceClock()
        let service = ActionProposalFixtureService(repository: repository, teammateRepository: repository,
            contextRepository: repository, clock: clock)
        let proposal = try await service.prepare(conversationID: identity.conversation.id, action: .send)
        let approved = ActionProposalRecord(proposal: proposal.proposal, fingerprint: proposal.fingerprint,
            state: .approved, revision: 2, updatedAt: proposal.updatedAt.addingTimeInterval(50))
        clock.set(proposal.updatedAt.addingTimeInterval(100))
        await #expect(throws: ActionProposalError.invalid) { try await service.decide(approved, decision: .cancel) }
        #expect(await repository.writes == 2)
    }

    private func persistDecisions(_ fixture: ProposalSQLiteFixture) async throws -> (records: [ActionProposalRecord], weak: WeakProposalStore) {
        let store = try fixture.open()
        try await fixture.seed(store)
        let service = fixture.service(store)
        let first = try await service.prepare(conversationID: fixture.identity.conversation.id, action: .publish)
        let approved = try await service.decide(first, decision: .approve)
        let cancelledApproval = try await service.decide(approved, decision: .cancel)
        let second = try await service.prepare(conversationID: fixture.identity.conversation.id, action: .delete)
        let denied = try await service.decide(second, decision: .deny)
        let third = try await service.prepare(conversationID: fixture.identity.conversation.id, action: .purchase)
        let cancelled = try await service.decide(third, decision: .cancel)
        return ([cancelledApproval, denied, cancelled], WeakProposalStore(store))
    }
}

private func replacing(_ proposal: ActionProposal, teammateID: TeammateID? = nil,
                       conversationID: ConversationID? = nil, target: String? = nil, payload: String? = nil) throws -> ActionProposal {
    try ActionProposal(id: proposal.id, teammateID: teammateID ?? proposal.teammateID,
        conversationID: conversationID ?? proposal.conversationID, runID: proposal.runID,
        profileRevision: proposal.profileRevision, contextRevision: proposal.contextRevision, action: proposal.action,
        target: target ?? proposal.target, payload: payload ?? proposal.payload, consequence: proposal.consequence,
        createdAt: proposal.createdAt, expiresAt: proposal.expiresAt)
}

private struct ProposalTestIdentity: Sendable {
    let teammate: Teammate
    let conversation: Conversation
    var context: ConversationContextSelection { .init(conversationID: conversation.id, teammateID: teammate.id) }
    init() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        teammate = try .init(id: TeammateID(UUID()), profile: .init(displayName: "Proposal Partner", role: "Local reviews"),
            appearance: .init(mode: .creature, grammarVersion: 1, deterministicSeed: 4, silhouette: "round", paletteToken: "mint",
                eyeDialect: "round", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Crest creature"),
            createdAt: date, updatedAt: date)
        conversation = try .init(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id), createdAt: date, updatedAt: date)
    }
}

private struct ProposalSQLiteFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let identity: ProposalTestIdentity
    let clock = ProposalServiceClock()
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextProposalService-\(UUID()).noindex", isDirectory: true)
        protection = try .init(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        identity = try .init()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: .init(fileURL: directory.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore) async throws {
        try await store.provisionDirectChat(teammate: identity.teammate, conversation: identity.conversation, fixtureGreeting: nil, selectConversation: false)
    }
    func service(_ store: SQLiteStore) -> ActionProposalFixtureService {
        .init(repository: store, teammateRepository: store, contextRepository: store, clock: clock)
    }
    func proposal(payload: String) throws -> ActionProposal {
        try .init(id: ApprovalID(UUID()), teammateID: identity.teammate.id, conversationID: identity.conversation.id,
            profileRevision: identity.teammate.profile.revision, contextRevision: 0, action: .send,
            target: "Synthetic target", payload: payload, consequence: "Record a decision only; nothing executes.",
            createdAt: clock.now(), expiresAt: clock.now().addingTimeInterval(300))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class WeakProposalStore: @unchecked Sendable {
    weak var value: SQLiteStore?
    init(_ value: SQLiteStore) { self.value = value }
}
private final class ProposalServiceClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func now() -> Date { lock.withLock { count += 1; return date } }
    func set(_ value: Date) { lock.withLock { date = value } }
}
private final class ProposalServiceIDs: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func next() -> UUID { lock.withLock { count += 1; return UUID() } }
}

private actor ProposalRepositoryDouble: ActionProposalRepository, TeammateRepository, ConversationContextRepository {
    let identity: ProposalTestIdentity
    let mutation: String?
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var lastLimit = 0
    init(identity: ProposalTestIdentity, mutation: String? = nil) { self.identity = identity; self.mutation = mutation }
    func insertProposal(_ proposal: ActionProposal) throws -> ActionProposalRecord {
        writes += 1
        let result = mutation == "conversation" ? try replacing(proposal, conversationID: ConversationID(UUID())) : proposal
        return .init(proposal: result, fingerprint: mutation == "fingerprint" ? "bad" : try result.fingerprint(),
            state: mutation == "state" ? .approved : .pending, revision: mutation == "revision" ? 0 : mutation == "state" ? 2 : 1,
            updatedAt: proposal.createdAt)
    }
    func proposals(conversationID: ConversationID, limit: Int) -> [ActionProposalRecord] { reads += 1; lastLimit = limit; return [] }
    func decideProposal(_ review: ActionProposalRecord, decision: ActionProposalDecision, now: Date) -> ActionProposalRecord {
        writes += 1
        return .init(proposal: review.proposal, fingerprint: review.fingerprint, state: .cancelled, revision: review.revision + 1,
            updatedAt: mutation == "backdatedDecision" ? review.proposal.createdAt : now)
    }
    func teammate(id: TeammateID) -> Teammate? { identity.teammate }
    func listTeammates(includingArchived: Bool) -> [Teammate] { [identity.teammate] }
    func insert(_ teammate: Teammate) throws { throw ActionProposalError.unavailable }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) throws { throw ActionProposalError.unavailable }
    func loadContext(conversationID: ConversationID) -> ConversationContextSelection { identity.context }
    func saveContext(_ selection: ConversationContextSelection) throws -> ConversationContextSelection { throw ActionProposalError.unavailable }
}
