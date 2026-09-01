import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("Exact displayed-claim correction anchors")
struct MemoryLocalCorrectionAnchorResolverTests {
    @Test("Exact-body forget, confirmation and uncertainty commands anchor one of several displayed claims",
          arguments: ["Forget that ", "I confirm from first-hand knowledge: ", "Remember as uncertain: "])
    func exactBody(_ prefix: String) async throws {
        let f = try AnchorFixture(bodies: ["I like tea.", "I live in Paris, in summer only."])
        let target = f.loaded[1]
        let anchor = try await f.resolver.resolve(text: prefix + target.claim.body, authority: f.authority, loadedClaims: f.loaded)
        #expect(anchor == MemoryLocalCorrectionAnchor(receiptID: f.record.publication.receipt.id, reference: target.reference))
        #expect(await f.store.pageLimits == [12])
        #expect(await f.store.lookupMessageIDs == [f.record.replyMessage.id])
    }

    @Test("An unspecified replacement requires exactly one shown claim; truncated or duplicate bodies stay ambiguous")
    func ambiguity() async throws {
        let many = try AnchorFixture(bodies: ["I like tea.", "I live in Paris, in summer only."])
        #expect(try await many.resolver.resolve(text: "Correct from first-hand knowledge to: I like coffee.",
            authority: many.authority, loadedClaims: many.loaded) == nil)
        #expect(try await many.resolver.resolve(text: "Forget that I live in Paris.",
            authority: many.authority, loadedClaims: many.loaded) == nil)
        #expect(try await many.resolver.resolve(text: "Remember as uncertain: A new claim.",
            authority: many.authority, loadedClaims: many.loaded) == nil)
        let single = try AnchorFixture(bodies: ["I like tea."])
        #expect(try await single.resolver.resolve(text: "Correct from first-hand knowledge to: I like coffee.",
            authority: single.authority, loadedClaims: single.loaded)?.reference == single.loaded[0].reference)
        let duplicate = try AnchorFixture(bodies: ["I like tea.", "I like tea."])
        #expect(try await duplicate.resolver.resolve(text: "Forget that I like tea.",
            authority: duplicate.authority, loadedClaims: duplicate.loaded) == nil)
    }

    @Test("A newer provider or unfinished reply fences an older local anchor; the loader never searches past twelve messages")
    func mostRecentOnly() async throws {
        let f = try AnchorFixture(bodies: ["I like tea."])
        let provider = try f.message(sequence: 3, author: .teammate(f.bot))
        await f.store.replaceMessages([f.record.userMessage, f.record.replyMessage, provider])
        #expect(try await f.resolve() == nil)
        let pending = try f.message(sequence: 3, author: .system, delivery: .pending)
        await f.store.replaceMessages([f.record.userMessage, f.record.replyMessage, pending])
        #expect(try await f.resolve() == nil)
        let laterUser = try f.message(sequence: 3, author: .user)
        await f.store.replaceMessages([f.record.userMessage, f.record.replyMessage, laterUser])
        #expect(try await f.resolve()?.reference == f.loaded[0].reference)
        let users = try (3...15).map { try f.message(sequence: Int64($0), author: .user) }
        await f.store.replaceMessages([f.record.userMessage, f.record.replyMessage] + users)
        #expect(try await f.resolve() == nil)
        #expect(await f.store.pageLimits == [12, 12, 12, 12])
        #expect(await f.store.lookupMessageIDs == [f.record.replyMessage.id])
    }

    @Test("All shown claims must remain current and loaded; narrowing away a stale second claim cannot create a singleton target")
    func currentReferences() async throws {
        let f = try AnchorFixture(bodies: ["I like tea.", "I like quiet libraries."])
        #expect(try await f.resolver.resolve(text: "Forget that I like tea.", authority: f.authority,
            loadedClaims: [f.loaded[0]]) == nil)
        let partial = try f.authority.selecting(messageIDs: [], memoryDocumentIDs: [f.loaded[0].reference.documentID])
        #expect(try await f.resolver.resolve(text: "Correct from first-hand knowledge to: A replacement.",
            authority: partial, loadedClaims: f.loaded) == nil)
        let first = f.loaded[0]
        let changed = MemoryClaim(id: first.claim.id, body: "Substituted body.", assessment: first.claim.assessment,
            provenance: first.claim.provenance)
        let changedBody = MemoryLocalCorrectionAnchorClaim(claim: changed, reference: first.reference, scope: first.scope)
        #expect(try await f.resolver.resolve(text: "Forget that Substituted body.", authority: f.authority,
            loadedClaims: [changedBody, f.loaded[1]]) == nil)
        let assessment = MemoryClaim(id: first.claim.id, body: first.claim.body,
            assessment: .init(level: .confirmed, basis: "Substituted assessment", assessor: .init(kind: .user)), provenance: [])
        #expect(try await f.resolver.resolve(text: "Forget that I like tea.", authority: f.authority,
            loadedClaims: [.init(claim: assessment, reference: first.reference, scope: first.scope), f.loaded[1]]) == nil)
    }

    @Test("A transitive dependency absent from the displayed units cannot become a correction target")
    func hiddenDependency() async throws {
        let f = try AnchorFixture(bodies: ["I like tea.", "An older hidden dependency."], displayedCount: 1)
        #expect(try await f.resolver.resolve(text: "Forget that An older hidden dependency.",
            authority: f.authority, loadedClaims: f.loaded) == nil)
        #expect(try await f.resolve()?.reference == f.loaded[0].reference)
    }

    @Test("Bot, selected-project and membership mismatches never confer an anchor; global scope stays denied")
    func scopes() async throws {
        let own = try AnchorFixture(bodies: ["I like tea."])
        let wrongBot = own.context(bot: TeammateID(UUID()))
        #expect(try await own.resolver.resolve(text: "Forget that I like tea.", authority: wrongBot, loadedClaims: own.loaded) == nil)
        let project = try AnchorFixture(bodies: ["I like tea."], project: true)
        #expect(try await project.resolve()?.reference == project.loaded[0].reference)
        #expect(try await project.resolver.resolve(text: "Forget that I like tea.",
            authority: project.context(project: nil, membership: nil), loadedClaims: project.loaded) == nil)
        #expect(try await project.resolver.resolve(text: "Forget that I like tea.",
            authority: project.context(project: project.projectID, membership: nil), loadedClaims: project.loaded) == nil)
        let global = try AnchorFixture(bodies: ["I like tea."], global: true)
        #expect(try await global.resolve() == nil)
    }

    @Test("Missing receipts, changed displayed bytes and withdrawn targets cannot be reinterpreted as current")
    func receiptAndWithdrawal() async throws {
        let missing = try AnchorFixture(bodies: ["I like tea."])
        await missing.store.replaceRecord(nil)
        #expect(try await missing.resolve() == nil)
        let changed = try AnchorFixture(bodies: ["I like tea."])
        let altered = try Message(id: changed.record.replyMessage.id, conversationID: changed.chat, sequence: 2,
            author: .system, deliveryState: .completed,
            parts: [MessagePart(id: changed.record.replyMessage.parts[0].id, ordinal: 0, content: .text("Different shown content"))],
            createdAt: changed.date, updatedAt: changed.date)
        await changed.store.replaceMessages([changed.record.userMessage, altered])
        #expect(try await changed.resolve() == nil)
        let withdrawn = try AnchorFixture(bodies: ["I like tea."], withdrawn: true)
        #expect(try await withdrawn.resolve() == nil)
    }
}

private struct AnchorFixture: Sendable {
    let bot = TeammateID(UUID()), chat = ConversationID(UUID()), projectID = ProjectID(UUID())
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let authority: ReadContextReceipt
    let loaded: [MemoryLocalCorrectionAnchorClaim]
    let record: MemoryConversationPublicationRecord
    let store: AnchorTestStore
    var resolver: MemoryLocalCorrectionAnchorResolver { .init(publications: store, messages: store) }

    init(bodies: [String], displayedCount: Int? = nil, project: Bool = false, global: Bool = false, withdrawn: Bool = false) throws {
        let scope: MemoryScope = global ? .user : project ? .project(projectID) : .teammate(bot)
        loaded = try bodies.map { body in
            let claim = MemoryClaim(id: MemoryClaimID(UUID()), body: body,
                assessment: .init(level: .uncertain, basis: "Synthetic retained assertion", assessor: .init(kind: .unassessed)),
                provenance: [], validity: withdrawn ? .withdrawn : .active)
            let reference = MemoryClaimReference(documentID: MemoryDocumentID(UUID()), documentRevision: 1,
                contentDigest: String(repeating: "a", count: 64), claimID: claim.id,
                claimDigest: try MemoryClaimDigests.claim(claim), subjectDigest: try MemoryClaimDigests.subject(claim, scope: scope))
            return .init(claim: claim, reference: reference, scope: scope)
        }
        authority = ReadContextReceipt(conversationID: chat, teammateID: bot, profileRevision: 1, contextRevision: 1,
            selectedProjectID: project ? projectID : nil, selectedTeamID: nil, participantJoinedAt: date,
            projectMembershipJoinedAt: project ? date : nil, teamMembershipJoinedAt: nil, messages: [],
            memoryDocuments: loaded.map { .init(documentID: $0.reference.documentID, scope: $0.scope, revision: 1,
                contentDigest: $0.reference.contentDigest, metadataDigest: String(repeating: "b", count: 64)) },
            qualificationVersion: 1, claimReferences: loaded.map(\.reference))
        let shown = Array(loaded.prefix(displayedCount ?? loaded.count))
        let text = shown.map { "Not established; \($0.claim.body)" }.joined(separator: "\n\n")
        let user = try Message(id: MessageID(UUID()), conversationID: chat, sequence: 1, author: .user, deliveryState: .completed,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("What do you remember about me?"))],
            createdAt: date, updatedAt: date)
        let reply = try Message(id: MessageID(UUID()), conversationID: chat, sequence: 2, author: .system, deliveryState: .completed,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))], createdAt: date, updatedAt: date)
        let receipt = MemoryPublicationReceipt(id: UUID(), policyVersion: 1, runID: RunID(UUID()), messageID: reply.id,
            teammateID: bot, selectedProjectID: project ? projectID : nil, intent: withdrawn ? .historyOverview : .overview,
            renderedTextDigest: MemoryClaimDigests.bytes(Data(text.utf8)),
            units: [.init(kind: .overview, references: shown.map(\.reference))],
            dependencies: loaded.map { .init(reference: $0.reference, scope: $0.scope, sourceStamps: [], evidenceStamps: [],
                decision: .init(disposition: .qualified, reasons: [.lowAssessment], requiredFraming: .unconfirmedPossibility, dependency: $0.reference)) },
            lineage: .independent, createdAt: date)
        record = MemoryConversationPublicationRecord(publication: .init(completeUnits: [text], receipt: receipt, omittedUnitCount: 0),
            userMessage: user, replyMessage: reply, authority: authority, userSourceStamps: [], storedAt: date)
        store = AnchorTestStore(record: record)
    }
    func resolve() async throws -> MemoryLocalCorrectionAnchor? {
        try await resolver.resolve(text: "Forget that " + loaded[0].claim.body, authority: authority, loadedClaims: loaded)
    }
    func message(sequence: Int64, author: MessageAuthor, delivery: MessageDeliveryState = .completed) throws -> Message {
        try Message(id: MessageID(UUID()), conversationID: chat, sequence: sequence, author: author, deliveryState: delivery,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Later message"))], createdAt: date, updatedAt: date)
    }
    func context(bot overrideBot: TeammateID? = nil, project: ProjectID? = nil, membership: Date? = nil) -> ReadContextReceipt {
        .init(conversationID: chat, teammateID: overrideBot ?? bot, profileRevision: 1, contextRevision: 1,
            selectedProjectID: project, selectedTeamID: nil, participantJoinedAt: date,
            projectMembershipJoinedAt: membership, teamMembershipJoinedAt: nil, messages: [],
            memoryDocuments: authority.memoryDocuments, qualificationVersion: 1, claimReferences: authority.claimReferences)
    }
}

private actor AnchorTestStore: MessageRepository, MemoryConversationPublicationRepository {
    var record: MemoryConversationPublicationRecord?
    var values: [Message]
    private(set) var pageLimits: [Int] = []
    private(set) var lookupMessageIDs: [MessageID] = []
    init(record: MemoryConversationPublicationRecord) { self.record = record; values = [record.userMessage, record.replyMessage] }
    func replaceMessages(_ values: [Message]) { self.values = values }
    func replaceRecord(_ value: MemoryConversationPublicationRecord?) { record = value }
    func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message> {
        pageLimits.append(request.limit)
        let selected = values.filter { $0.conversationID == conversationID }.sorted { $0.sequence < $1.sequence }
        return Page(elements: Array(selected.suffix(request.limit)), hasMore: selected.count > request.limit)
    }
    func message(id: MessageID) async throws -> Message? { values.first { $0.id == id } }
    func memoryConversationPublication(messageID: MessageID, conversationID: ConversationID) async throws -> MemoryConversationPublicationRecord? {
        lookupMessageIDs.append(messageID)
        guard let record, record.replyMessage.id == messageID, record.authority.conversationID == conversationID else { return nil }
        return record
    }
    func memoryConversationPublication(id: UUID) async throws -> MemoryConversationPublicationRecord? {
        record?.publication.receipt.id == id ? record : nil
    }
    func appendMemoryConversationPublication(_ request: MemoryConversationPublicationAppend, now: Date) async throws -> MemoryConversationPublicationRecord {
        throw MemoryLocalCorrectionError.invalidState
    }
    func append(_ message: Message, expectedPreviousSequence: Int64) async throws { throw MemoryLocalCorrectionError.invalidState }
    func updateDeliveryState(messageID: MessageID, from expectedState: MessageDeliveryState,
                             to newState: MessageDeliveryState, updatedAt: Date) async throws { throw MemoryLocalCorrectionError.invalidState }
}
