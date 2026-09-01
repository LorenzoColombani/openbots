import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

@Suite("Controlled provider publication persistence")
struct SQLiteControlledMemoryTextTurnRepositoryTests {
    @Test("Controlled admission cannot use raw message writers or admit an unqualified receipt")
    func rawBypassesRefused() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let prepared = try await f.prepare(store)
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            try await store.beginTextTurn(request: prepared.request, userMessage: prepared.user,
                expectedPreviousSequence: 1, ownerID: f.owner, token: f.token, now: f.at(1), leaseDuration: 60)
        }
        #expect(try await store.message(id: prepared.user.id) == nil)
        let current = try await f.begin(store, prepared)
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            try await store.checkpointTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "UNTRUSTED CANDIDATE", inputEvidence: .submitted, now: f.at(2))
        }
        await #expect(throws: TextTurnRepositoryError.invalidRequest) {
            try await store.finishTextTurn(id: current.run.id, expectedRevision: current.run.revision,
                token: f.token, text: "UNTRUSTED CANDIDATE", outcome: .succeeded, now: f.at(2))
        }
        #expect(try await store.message(id: prepared.replyID)?.author == .system)
        #expect(try await store.message(id: prepared.replyID)?.parts.first?.content == .status("Waiting for Claude's reply."))
        #expect(try await store.query(sql: "SELECT text_value FROM message_parts WHERE text_value LIKE '%UNTRUSTED%';").isEmpty)
    }

    @Test("A crash leaves only pending status; proven process absence interrupts without a publication or replay")
    func interruptedReopen() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let prepared = try await f.prepare(store)
        let active = try await f.acknowledge(store, prepared)
        let reopened = try f.open()
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10) == [active])
        let stopped = try await reopened.interruptTextTurn(id: active.run.id, expectedRevision: active.run.revision,
            appOwnerID: f.appOwner, processAbsence: .init(runID: active.run.id, leaseOwnerID: f.owner), now: f.at(8))
        #expect(stopped.run.state == .interrupted && stopped.replyText.isEmpty)
        #expect(try await reopened.message(id: prepared.replyID)?.deliveryState == .outcomeUnknown)
        #expect(try await reopened.memoryConversationPublication(id: prepared.publication.receipt.id) == nil)
        #expect(try await reopened.textTurnExecutionEvidence(id: active.run.id)?.resultModel == nil)
        #expect(try await reopened.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }

    @Test("Final projection, receipt, transport outcome and execution evidence commit together and retry exactly after reopen")
    func atomicPublicationAndRetry() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store)
        let active = try await f.acknowledge(store, p)
        _ = try await store.execute(sql: "CREATE TRIGGER reject_controlled_terminal BEFORE INSERT ON run_journal_entries WHEN NEW.state='succeeded' BEGIN SELECT RAISE(ABORT,'terminal rejected'); END;")
        await #expect(throws: SQLiteStoreError.self) { try await f.finish(store, p, active) }
        #expect(try await store.memoryConversationPublication(id: p.publication.receipt.id) == nil)
        #expect(try await store.textTurnExecutionEvidence(id: active.run.id)?.resultModel == nil)
        #expect(try await store.message(id: p.replyID)?.deliveryState == .pending)
        #expect(try await store.run(id: active.run.id)?.revision == active.run.revision)
        _ = try await store.execute(sql: "DROP TRIGGER reject_controlled_terminal;")
        let done = try await f.finish(store, p, active)
        #expect(done.run.state == .succeeded && done.replyText == p.publication.text)
        #expect(done.inputState == .acknowledged)
        let reopened = try f.open()
        let record = try #require(try await reopened.memoryConversationPublication(id: p.publication.receipt.id))
        #expect(record.providerRunID == active.run.id)
        #expect(record.userMessage.id == p.user.id && record.replyMessage.id == p.replyID)
        #expect(record.replyMessage.author == .system && record.replyMessage.deliveryState == .completed)
        #expect(record.publication.text.contains("I may have this wrong:"))
        #expect(try await reopened.memoryConversationPublication(messageID: p.replyID, conversationID: f.chat) == record)
        #expect(try await reopened.memoryConversationPublication(messageID: p.user.id, conversationID: f.chat) == record)
        #expect(try await f.finish(reopened, p, active, now: f.at(90)) == done)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 3)
        await #expect(throws: RunJournalError.staleRevision) {
            try await reopened.finishControlledMemoryTextTurn(id: active.run.id, expectedRevision: active.run.revision,
                token: UUID(), publication: p.publication, validation: p.validation, executionEvidence: f.result, now: f.at(91))
        }
    }

    @Test("Revoked profile, changed memory head or changed user evidence prevents final publication", arguments: ["profile", "memory", "source"])
    func authorityChanged(variant: String) async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store)
        let active = try await f.acknowledge(store, p)
        switch variant {
        case "profile": _ = try await store.execute(sql: "UPDATE teammates SET profile_revision=profile_revision+1 WHERE id=?;", bindings: [.text(f.bot.persistedValue)])
        case "memory": _ = try await store.execute(sql: "UPDATE memory_documents SET content_digest=? WHERE id=?;", bindings: [.text(String(repeating: "e", count: 64)), .text(p.reference.documentID.persistedValue)])
        default: _ = try await store.execute(sql: "UPDATE message_parts SET text_value='A changed source' WHERE message_id=?;", bindings: [.text(f.sourceID.persistedValue)])
        }
        do { _ = try await f.finish(store, p, active); Issue.record("Changed authority unexpectedly published") } catch { }
        #expect(try await store.memoryConversationPublication(id: p.publication.receipt.id) == nil)
        #expect(try await store.message(id: p.replyID)?.deliveryState == .pending)
        #expect(try await store.textTurnExecutionEvidence(id: active.run.id)?.resultModel == nil)
        let failed = try await store.failControlledMemoryTextTurn(id: active.run.id, expectedRevision: active.run.revision,
            token: f.token, outcome: .failed, diagnosticCode: nil, now: f.at(7))
        #expect(failed.replyText.isEmpty && failed.run.state == .failed)
        #expect(try await store.failControlledMemoryTextTurn(id: active.run.id, expectedRevision: active.run.revision,
            token: f.token, outcome: .failed, diagnosticCode: nil, now: f.at(8)) == failed)
    }

    @Test("Cancelled finalization publishes nothing and cannot be retried through a raw finish")
    func cancelledFinish() async throws {
        let f = try ControlledTextFixture(); defer { f.remove() }
        let store = try f.open(); let p = try await f.prepare(store)
        let active = try await f.acknowledge(store, p)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.finish(store, p, active)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.memoryConversationPublication(id: p.publication.receipt.id) == nil)
        #expect(try await store.run(id: active.run.id)?.state == .running)
    }
}

/// Synthetic SQLite + real renderer fixture. This resolver is intentionally
/// narrow and never claims to authenticate provider prose or inspect live data.
struct ControlledTextFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), chat = ConversationID(UUID()), sourceID = MessageID(UUID())
    let owner = UUID(), appOwner = UUID(), token = UUID(), sessionID = UUID()
    var execution: ClaudeExecutionRequest { .init(sessionID: sessionID,
        selection: .init(model: "claude-sonnet-5", effort: "default", contextWindow: "default"), launchModel: "claude-sonnet-5") }
    var initialized: ClaudeExecutionEvidence { .init(request: execution, initializedModel: "claude-sonnet-5", resultModel: nil) }
    var result: ClaudeExecutionEvidence { .init(request: execution, initializedModel: "claude-sonnet-5", resultModel: "claude-sonnet-5") }
    static let sourceText = "Remember that I prefer quieter places."
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextControlledText-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func at(_ offset: TimeInterval) -> Date { date.addingTimeInterval(offset) }
    func open() throws -> SQLiteStore { try SQLiteStore(configuration: .init(fileURL: directory.appendingPathComponent("control.sqlite"), protection: .ordinarySQLite(decision: protection))) }
    struct Prepared: Sendable {
        let request: WorkRequest
        let user: Message
        let replyID: MessageID
        let reference: MemoryClaimReference
        let publication: MemoryConversationPublication
        let validation: MemoryConversationPublicationValidation
    }
    func prepare(_ store: SQLiteStore, controlled: Bool = true, executionRecorded: Bool = true) async throws -> Prepared {
        let teammate = try Teammate(id: bot, profile: .init(displayName: "Memory Bot", role: "Research"),
            appearance: .init(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            claudeModel: "claude-sonnet-5", createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: .init(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date), fixtureGreeting: nil, selectConversation: false)
        try await store.append(Message(id: sourceID, conversationID: chat, sequence: 1, author: .user, deliveryState: .completed,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(Self.sourceText))], createdAt: date, updatedAt: date), expectedPreviousSequence: 0)
        let source = MemoryClaimSourceReference(id: UUID(), kind: .userMessage, sourceID: sourceID.persistedValue, sourceRevision: 1,
            contentDigest: MemoryClaimDigests.bytes(Data(Self.sourceText.utf8)), observedAt: date, scope: .teammate(bot))
        let claim = MemoryClaim(id: MemoryClaimID(UUID()), body: "I prefer quieter places",
            assessment: .init(level: .uncertain, basis: "A retained tentative note.", assessor: .init(kind: .unassessed)), provenance: [source], observedAt: date)
        let artifact = MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: 1, scope: .teammate(bot), claims: [claim])
        let codec = MemoryClaimCodec(), bytes = try codec.encode(artifact)
        let document = try MemoryDocument(id: artifact.documentID, scope: .teammate(bot), author: .system, title: "Tentative preference",
            relativePath: "Documents/Teammates/\(bot.persistedValue)/\(artifact.documentID.persistedValue)-r1.md", revision: 1,
            contentDigest: MemoryClaimDigests.bytes(bytes), createdAt: date, updatedAt: date)
        try await store.insert(document)
        let reference = try codec.reference(for: claim, in: artifact, contentDigest: document.contentDigest)
        let selection = try await store.loadContext(conversationID: chat)
        let snapshot = try await store.loadReadContextCandidates(.init(conversationID: chat, teammateID: bot,
            profileRevision: 1, selection: selection, beforeSequence: 2))
        let authority = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [document.id]).qualifying(with: [reference])
        let runID = RunID(UUID()), replyID = MessageID(UUID())
        let user = try Message(id: MessageID(UUID()), conversationID: chat, sequence: 2, author: .user, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("What should I keep in mind?"))], createdAt: at(1), updatedAt: at(1))
        let request = try WorkRequest(runID: runID, teammateID: bot, conversationID: chat, initiatingMessageID: user.id,
            profileRevision: 1, initialInput: .init(messageID: user.id, sequence: 1, text: "What should I keep in mind?"), submittedAt: at(1),
            textTurnIdentity: .init(appOwnerID: appOwner, replyMessageID: replyID, replyPartID: MessagePartID(UUID()),
                executionRequest: executionRecorded ? execution : nil, controlledMemoryPolicyVersion: controlled ? 1 : nil), readContextReceipt: authority)
        let context = MemoryPublicationContext(runID: runID, messageID: replyID, teammateID: bot,
            admittedReferences: [reference], relevantReferences: [reference], now: at(5))
        let publisher = MemoryConversationPublicationService(resolver: ControlledTextResolver(claim: claim, reference: reference, authority: authority, store: store))
        let publication = try await publisher.publish(.init(units: [.init(kind: .claim, references: [reference])]), context: context)
        let validation = MemoryConversationPublicationValidation(authority: authority,
            publicationDigest: try MemoryConversationPublicationValidation.digest(of: publication),
            userSourceStamps: [try .init(messageID: sourceID, contentDigest: #require(source.contentDigest), updatedAt: date)], checkedAt: at(5))
        return .init(request: request, user: user, replyID: replyID, reference: reference, publication: publication, validation: validation)
    }
    func begin(_ store: SQLiteStore, _ p: Prepared) async throws -> TextTurnSnapshot {
        try await store.beginControlledMemoryTextTurn(request: p.request, userMessage: p.user,
            expectedPreviousSequence: 1, ownerID: owner, token: token, now: at(1), leaseDuration: 60)
    }
    func acknowledge(_ store: SQLiteStore, _ p: Prepared) async throws -> TextTurnSnapshot {
        var current = try await begin(store, p)
        current = try await store.checkpointControlledMemoryTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: token, inputEvidence: .submitted, executionEvidence: initialized, now: at(2))
        return try await store.checkpointControlledMemoryTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: token, inputEvidence: .acknowledged, executionEvidence: nil, now: at(3))
    }
    func finish(_ store: SQLiteStore, _ p: Prepared, _ current: TextTurnSnapshot, now: Date? = nil) async throws -> TextTurnSnapshot {
        try await store.finishControlledMemoryTextTurn(id: current.run.id, expectedRevision: current.run.revision,
            token: token, publication: p.publication, validation: p.validation, executionEvidence: result, now: now ?? at(6))
    }
}

private struct ControlledTextResolver: MemoryConversationPublicationResolving {
    let claim: MemoryClaim; let reference: MemoryClaimReference; let authority: ReadContextReceipt; let store: SQLiteStore
    func resolveClaim(_ requested: MemoryClaimReference, context: MemoryPublicationContext) async throws -> MemoryPublicationClaimSnapshot? {
        guard requested == reference else { return nil }
        return .init(claim: claim, reference: reference, scope: .teammate(context.teammateID),
            useContext: .init(purpose: .conversation, now: context.now, teammateID: context.teammateID,
                currentReference: reference, freshness: .current, isRelevant: true, conditionsSatisfied: true), lineage: .independent)
    }
    func resolveReceipt(_ id: UUID, context: MemoryPublicationContext) async throws -> MemoryPublicationReceipt? {
        try await store.memoryConversationPublication(id: id)?.publication.receipt
    }
    func revalidate(_ receipt: MemoryPublicationReceipt, context: MemoryPublicationContext) async throws -> Bool {
        try await store.revalidateReadContext(authority); return true
    }
}
