import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

@Suite("Atomic app-rendered memory conversation projections")
struct SQLiteMemoryConversationPublicationRepositoryTests {
    @Test("Host explanation limitations persist only exact source-free wording, even with a fresh matching digest")
    func hostLimitationShape() async throws {
        for variant in ["valid", "body", "references", "lineage", "extra-unit"] {
            let f = try ConversationPublicationFixture(); defer { f.remove() }
            let store = try f.open(); let seeded = try await f.seed(store)
            let selection = try await store.loadContext(conversationID: f.chat)
            let snapshot = try await store.loadReadContextCandidates(.init(conversationID: f.chat,
                teammateID: f.bot, profileRevision: 1, selection: selection, beforeSequence: Int64.max))
            let authority = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: []).qualifying(with: [])
            let text = variant == "body" ? "An invented source explanation." : MemoryExplanationLimitation.sourcesUnavailable.text
            var units = [MemoryPublicationUnit(kind: .explanationSourcesUnavailable,
                references: variant == "references" ? [seeded.reference] : [])]
            if variant == "extra-unit" { units.append(.init(kind: .explanationLineageUnverifiable, references: [])) }
            let receipt = MemoryPublicationReceipt(id: UUID(), policyVersion: 1, runID: RunID(UUID()),
                messageID: MessageID(UUID()), teammateID: f.bot, selectedProjectID: nil, intent: .explanation,
                renderedTextDigest: MemoryClaimDigests.bytes(Data(text.utf8)), units: units, dependencies: [],
                lineage: variant == "lineage" ? .derived(receiptIDs: [UUID()]) : .independent, createdAt: f.now)
            let publication = MemoryConversationPublication(completeUnits: [text], receipt: receipt, omittedUnitCount: 0)
            let validation = MemoryConversationPublicationValidation(authority: authority,
                publicationDigest: try MemoryConversationPublicationValidation.digest(of: publication),
                userSourceStamps: [], checkedAt: f.now)
            let request = MemoryConversationPublicationAppend(publication: publication, userMessageID: MessageID(UUID()),
                userPartID: MessagePartID(UUID()), replyPartID: MessagePartID(UUID()),
                userText: "Why did you say that?", expectedPreviousSequence: 2, validation: validation)
            if variant == "valid" {
                let saved = try await store.appendMemoryConversationPublication(request, now: f.now)
                #expect(saved.publication.completeUnits == [MemoryExplanationLimitation.sourcesUnavailable.text])
                #expect(try await f.open().memoryConversationPublication(id: receipt.id) == saved)
            } else {
                await expectConversationPublicationError(.invalidRequest) {
                    _ = try await store.appendMemoryConversationPublication(request, now: f.now)
                }
                #expect(try await store.message(id: request.userMessageID) == nil)
                #expect(try await store.memoryConversationPublication(id: receipt.id) == nil)
            }
            #expect(try await store.runs(conversationID: f.chat, limit: 10).isEmpty)
        }
    }

    @Test("Complete qualified projection, local user and receipt survive reopen without a provider run or old-row changes")
    func atomicReopen() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let prepared = try await f.prepare(store, seeded: seeded)
        let before = try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements
        let saved = try await store.appendMemoryConversationPublication(prepared.request, now: f.now)
        #expect(saved.publication.text.contains("I may have this wrong:"))
        #expect(saved.publication.text.hasSuffix("Does that apply here?"))
        #expect(saved.userMessage.author == .user && saved.userMessage.deliveryState == .completed)
        #expect(saved.replyMessage.author == .system && saved.replyMessage.deliveryState == .completed)
        #expect(saved.replyMessage.parts.map(\.content) == [.text(saved.publication.text)])
        #expect(try await store.runs(conversationID: f.chat, limit: 10).isEmpty)
        let reopened = try f.open()
        #expect(try await reopened.memoryConversationPublication(id: saved.publication.receipt.id) == saved)
        #expect(try await reopened.memoryConversationPublication(messageID: saved.userMessage.id, conversationID: f.chat) == saved)
        #expect(try await reopened.memoryConversationPublication(messageID: saved.replyMessage.id, conversationID: f.chat) == saved)
        #expect(try await reopened.memoryConversationPublication(messageID: saved.replyMessage.id, conversationID: ConversationID(UUID())) == nil)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.prefix(2) == before[...])
        #expect(try await reopened.document(id: seeded.document.id) == seeded.document)
        // Exact retry is a historical read even after its host assertion expires.
        #expect(try await reopened.appendMemoryConversationPublication(prepared.request, now: f.now.addingTimeInterval(60)) == saved)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 4)
    }

    @Test("Raw prose cannot reuse a valid host assertion; reconstruction, not a digest, is the semantic boundary")
    func validationAndTrustBoundary() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let p = try await f.prepare(store, seeded: seeded)
        let raw = "The uncertain claim is an established fact."
        let forged = f.publication(p.request.publication, text: raw)
        let changed = f.request(p.request, publication: forged)
        await expectConversationPublicationError(.invalidValidation) {
            _ = try await store.appendMemoryConversationPublication(changed, now: f.now)
        }
        // A matching digest is intentionally not an unforgeable seal. Trusted
        // host code MUST call the publisher; never decode/mint an assertion from
        // provider fields. The real reconstruction rejects this forged projection.
        let reconstructed = try await p.publisher.revalidate(forged, context: p.context)
        #expect(!reconstructed)
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 2)
        #expect(try await store.memoryConversationPublication(id: forged.receipt.id) == nil)
    }

    @Test("Identity aliases and canonically equivalent but byte-different user text are not idempotent retries")
    func identities() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let p = try await f.prepare(store, seeded: seeded, userText: "Explain caf\u{00e9}")
        _ = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        await expectConversationPublicationError(.conflictingIdentity) {
            _ = try await store.appendMemoryConversationPublication(f.request(p.request, userText: "Explain cafe\u{0301}"), now: f.now)
        }
        let second = try await f.prepare(store, seeded: seeded, operationID: p.request.publication.receipt.runID)
        await expectConversationPublicationError(.conflictingIdentity) {
            _ = try await store.appendMemoryConversationPublication(second.request, now: f.now)
        }
        let reusedUser = f.request(second.request, userID: p.request.userMessageID)
        await expectConversationPublicationError(.conflictingIdentity) {
            _ = try await store.appendMemoryConversationPublication(reusedUser, now: f.now)
        }
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 4)
    }

    @Test("A failure after both message inserts rolls back every projection row and conversation timestamp")
    func rollback() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let p = try await f.prepare(store, seeded: seeded)
        let before = try await store.conversation(id: f.chat)
        _ = try await store.execute(sql: """
            CREATE TRIGGER fail_conversation_publication BEFORE INSERT ON memory_conversation_publications
            BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;
            """)
        do { _ = try await store.appendMemoryConversationPublication(p.request, now: f.now); Issue.record("Expected rollback") }
        catch { }
        #expect(try await store.message(id: p.request.userMessageID) == nil)
        #expect(try await store.message(id: p.request.publication.receipt.messageID) == nil)
        #expect(try await store.memoryConversationPublication(id: p.request.publication.receipt.id) == nil)
        #expect(try await store.conversation(id: f.chat) == before)
        let reopened = try f.open()
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 2)
    }

    @Test("Every durable user-source stamp is rechecked inside commit", arguments: ConversationSourceMutation.allCases)
    func staleSource(_ mutation: ConversationSourceMutation) async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let p = try await f.prepare(store, seeded: seeded)
        switch mutation {
        case .body:
            _ = try await store.execute(sql: "UPDATE message_parts SET text_value='Changed source' WHERE message_id=?;", bindings: [.text(f.sourceID.persistedValue)])
        case .author:
            _ = try await store.execute(sql: "UPDATE messages SET author_kind='system' WHERE id=?;", bindings: [.text(f.sourceID.persistedValue)])
        case .stamp:
            _ = try await store.execute(sql: "UPDATE messages SET updated_at=updated_at+1 WHERE id=?;", bindings: [.text(f.sourceID.persistedValue)])
        case .part:
            _ = try await store.execute(sql: "INSERT INTO message_parts(id,message_id,ordinal,kind,text_value) VALUES (?,?,1,'text','Extra');",
                bindings: [.text(MessagePartID(UUID()).persistedValue), .text(f.sourceID.persistedValue)])
        }
        await expectConversationPublicationError(.invalidSource) {
            _ = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        }
        #expect(try await store.message(id: p.request.userMessageID) == nil)
    }

    @Test("Pending correction, changed document head and expired assertion reject new publication")
    func pendingAndStaleHead() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let p = try await f.prepare(store, seeded: seeded)
        await expectConversationPublicationError(.invalidValidation) {
            _ = try await store.appendMemoryConversationPublication(p.request, now: f.now.addingTimeInterval(30))
        }
        let successor = try f.successor(seeded.document)
        let pending = try MemoryPublicationIntent(id: UUID(), document: successor, expectedPredecessor: seeded.document,
            authority: p.request.validation.authority, actor: .app(verifierID: "synthetic-pending-correction"),
            evidenceDigest: String(repeating: "b", count: 64), policyDigest: String(repeating: "c", count: 64),
            byteCount: 100, createdAt: successor.updatedAt)
        _ = try await store.prepareMemoryPublication(pending)
        await expectConversationPublicationError(.authorityChanged) {
            _ = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        }
        #expect(try await store.message(id: p.request.userMessageID) == nil)
        _ = try await store.abortMemoryPublication(id: pending.id, expectedRevision: 1, now: f.now)
        // Aborting a failed correction does not revive the prior source either.
        await expectConversationPublicationError(.authorityChanged) {
            _ = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        }
    }

    @Test("Selected project admission works, but scope revocation and a changed head cannot race publication")
    func authorityChanges() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store, project: true)
        let p = try await f.prepare(store, seeded: seeded)
        _ = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        let next = try await f.prepare(store, seeded: seeded)
        try await store.setMembership(ProjectMembership(projectID: f.project, teammateID: f.bot,
            joinedAt: f.date, revokedAt: f.now))
        await expectConversationPublicationError(.authorityChanged) {
            _ = try await store.appendMemoryConversationPublication(next.request, now: f.now)
        }
        #expect(try await store.memoryConversationPublication(id: p.request.publication.receipt.id) != nil)
        let other = try ConversationPublicationFixture(); defer { other.remove() }
        let otherStore = try other.open(); let original = try await other.seed(otherStore)
        let stale = try await other.prepare(otherStore, seeded: original)
        try await otherStore.insert(other.successor(original.document))
        await expectConversationPublicationError(.authorityChanged) {
            _ = try await otherStore.appendMemoryConversationPublication(stale.request, now: other.now)
        }
    }

    @Test("Saved app-name source is checked even if profile revision was improperly left unchanged")
    func appSourceStamp() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store, appSource: true)
        let p = try await f.prepare(store, seeded: seeded)
        _ = try await store.execute(sql: "UPDATE teammates SET display_name='Changed without revision' WHERE id=?;",
            bindings: [.text(f.bot.persistedValue)])
        await expectConversationPublicationError(.invalidSource) {
            _ = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        }
    }

    @Test("Missing or cyclic ancestry cannot be saved and saved text tampering is detected on reopen")
    func lineageAndStoredIntegrity() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        for lineage in [MemoryPublicationLineage.unknown, .derived(receiptIDs: [UUID()])] {
            let p = try await f.prepare(store, seeded: seeded)
            let changed = f.publication(p.request.publication, lineage: lineage)
            let v = MemoryConversationPublicationValidation(authority: p.request.validation.authority,
                publicationDigest: try MemoryConversationPublicationValidation.digest(of: changed),
                userSourceStamps: p.request.validation.userSourceStamps, checkedAt: f.now)
            await expectConversationPublicationError(.invalidLineage) {
                _ = try await store.appendMemoryConversationPublication(f.request(p.request, publication: changed, validation: v), now: f.now)
            }
        }
        let p = try await f.prepare(store, seeded: seeded)
        let cyclic = f.publication(p.request.publication, lineage: .derived(receiptIDs: [p.request.publication.receipt.id]))
        let v = MemoryConversationPublicationValidation(authority: p.request.validation.authority,
            publicationDigest: try MemoryConversationPublicationValidation.digest(of: cyclic),
            userSourceStamps: p.request.validation.userSourceStamps, checkedAt: f.now)
        await expectConversationPublicationError(.invalidLineage) {
            _ = try await store.appendMemoryConversationPublication(f.request(p.request, publication: cyclic, validation: v), now: f.now)
        }
        let saved = try await store.appendMemoryConversationPublication(p.request, now: f.now)
        _ = try await store.execute(sql: "UPDATE message_parts SET text_value='Unqualified altered text' WHERE message_id=?;",
            bindings: [.text(saved.replyMessage.id.persistedValue)])
        let reopened = try f.open()
        await expectConversationPublicationError(.invalidStoredState) {
            _ = try await reopened.memoryConversationPublication(id: saved.publication.receipt.id)
        }
    }

    @Test("A grounded local explanation retains the exact earlier publication dependency after reopen")
    func groundedExplanation() async throws {
        let f = try ConversationPublicationFixture(); defer { f.remove() }
        let store = try f.open(); let seeded = try await f.seed(store)
        let first = try await f.prepare(store, seeded: seeded)
        let saved = try await store.appendMemoryConversationPublication(first.request, now: f.now)
        let second = try await f.prepare(store, seeded: seeded, userText: "Why did you say that?",
                                          explainedReceiptID: saved.publication.receipt.id)
        let explained = try await store.appendMemoryConversationPublication(second.request, now: f.now)
        #expect(explained.publication.text.contains("That reply drew on"))
        #expect(explained.publication.text.contains("Not established; it is only a possibility."))
        #expect(explained.publication.receipt.lineage == .derived(receiptIDs: [saved.publication.receipt.id]))
        #expect(explained.publication.receipt.dependencies == saved.publication.receipt.dependencies)
        let reopened = try f.open()
        #expect(try await reopened.memoryConversationPublication(id: explained.publication.receipt.id) == explained)
        #expect(try await reopened.runs(conversationID: f.chat, limit: 10).isEmpty)
    }
}

enum ConversationSourceMutation: CaseIterable { case body, author, stamp, part }

private struct ConversationPublicationFixture {
    static let sourceText = "Please remember that I might prefer quieter places."
    let directory: URL
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    var now: Date { date.addingTimeInterval(10) }
    let bot = TeammateID(UUID()), chat = ConversationID(UUID()), project = ProjectID(UUID())
    let sourceID = MessageID(UUID())
    let protection: ProtectionDecisionReceipt

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextConversationPublication-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    struct Seeded { let claim: MemoryClaim; let reference: MemoryClaimReference; let document: MemoryDocument; let appSource: Bool }
    func seed(_ store: SQLiteStore, project selected: Bool = false, appSource: Bool = false) async throws -> Seeded {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Memory Bot", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        if selected {
            try await store.insert(Project(id: project, name: "Selected", createdAt: date, updatedAt: date))
            try await store.setMembership(ProjectMembership(projectID: project, teammateID: bot, joinedAt: date))
            let selection = try await store.loadContext(conversationID: chat)
            _ = try await store.saveContext(ConversationContextSelection(conversationID: chat, teammateID: bot,
                projectID: project, revision: selection.revision))
        }
        try await store.append(Message(id: sourceID, conversationID: chat, sequence: 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(Self.sourceText))],
            createdAt: date, updatedAt: date), expectedPreviousSequence: 0)
        try await store.append(Message(id: MessageID(UUID()), conversationID: chat, sequence: 2, author: .teammate(bot),
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                content: .text("Untouched historical provider prose."))], createdAt: date, updatedAt: date), expectedPreviousSequence: 1)
        let scope: MemoryScope = selected ? .project(project) : .teammate(bot)
        let source: MemoryClaimSourceReference
        if appSource {
            struct NameStamp: Encodable { let id: TeammateID; let name: String; let revision: UInt64; let updatedAt: Date }
            source = .init(id: UUID(), kind: .appObservation, sourceID: "teammate.saved-name:" + bot.persistedValue,
                sourceRevision: 1, contentDigest: try MemoryClaimDigests.bytes(MemoryClaimDigests.canonicalData(NameStamp(
                    id: bot, name: "Memory Bot", revision: 1, updatedAt: date))), observedAt: date, scope: scope)
        } else {
            source = .init(id: UUID(), kind: .userMessage, sourceID: sourceID.persistedValue, sourceRevision: 1,
                contentDigest: MemoryClaimDigests.bytes(Data(Self.sourceText.utf8)), observedAt: date, scope: scope)
        }
        let claim = MemoryClaim(id: MemoryClaimID(UUID()), body: "I prefer quieter places",
            assessment: .init(level: .uncertain, basis: "The retained observation is tentative.",
                assessor: .init(kind: .unassessed)), provenance: [source], observedAt: date)
        let artifact = MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: 1, scope: scope, claims: [claim])
        let codec = MemoryClaimCodec(), bytes = try codec.encode(artifact)
        let folder = selected ? "Projects/\(project.persistedValue)" : "Teammates/\(bot.persistedValue)"
        let document = try MemoryDocument(id: artifact.documentID, scope: scope, author: .system, title: "Tentative preference",
            relativePath: "Documents/\(folder)/\(artifact.documentID.persistedValue)-r1.md", revision: 1,
            contentDigest: MemoryClaimDigests.bytes(bytes), createdAt: date, updatedAt: date)
        try await store.insert(document)
        return Seeded(claim: claim, reference: try codec.reference(for: claim, in: artifact, contentDigest: document.contentDigest),
                      document: document, appSource: appSource)
    }
    struct Prepared { let request: MemoryConversationPublicationAppend; let publisher: MemoryConversationPublicationService; let context: MemoryPublicationContext }
    func prepare(_ store: SQLiteStore, seeded: Seeded, userText: String = "What should I keep in mind?",
                 operationID: RunID = RunID(UUID()), explainedReceiptID: UUID? = nil) async throws -> Prepared {
        let selection = try await store.loadContext(conversationID: chat)
        let snapshot = try await store.loadReadContextCandidates(ReadContextRequest(conversationID: chat, teammateID: bot,
            profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        let authority = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [seeded.document.id])
            .qualifying(with: [seeded.reference])
        let context = MemoryPublicationContext(runID: operationID, messageID: MessageID(UUID()), teammateID: bot,
            selectedProjectID: selection.projectID, intent: explainedReceiptID == nil ? .reply : .explanation,
            admittedReferences: [seeded.reference], relevantReferences: [seeded.reference],
            explainedReceiptID: explainedReceiptID, now: now)
        let resolver = ConversationPublicationResolver(claim: seeded.claim, reference: seeded.reference,
                                                       scope: seeded.document.scope, authority: authority, store: store)
        let publisher = MemoryConversationPublicationService(resolver: resolver)
        let publication = try await publisher.publish(.init(units: [.init(kind: explainedReceiptID == nil ? .claim : .explanation,
            references: [seeded.reference])]), context: context)
        let revalidated = try await publisher.revalidate(publication, context: context)
        #expect(revalidated)
        let stamps = seeded.appSource ? [] : [try MemoryPublicationUserMessageEvidence(messageID: sourceID,
            contentDigest: MemoryClaimDigests.bytes(Data(Self.sourceText.utf8)), updatedAt: date)]
        let validation = MemoryConversationPublicationValidation(authority: authority,
            publicationDigest: try MemoryConversationPublicationValidation.digest(of: publication), userSourceStamps: stamps, checkedAt: now)
        let page = try await store.page(conversationID: chat, request: PageRequest(limit: 1))
        return Prepared(request: .init(publication: publication, userMessageID: MessageID(UUID()),
            userPartID: MessagePartID(UUID()), replyPartID: MessagePartID(UUID()), userText: userText,
            expectedPreviousSequence: page.elements.last?.sequence ?? 0, validation: validation), publisher: publisher, context: context)
    }
    func successor(_ previous: MemoryDocument) throws -> MemoryDocument {
        let id = MemoryDocumentID(UUID())
        let folder: String
        switch previous.scope { case .project(let id): folder = "Projects/\(id.persistedValue)"
        case .teammate(let id): folder = "Teammates/\(id.persistedValue)"
        case .user: folder = "User" }
        return try MemoryDocument(id: id, scope: previous.scope, author: .system, title: "Correction",
            relativePath: "Documents/\(folder)/\(id.persistedValue)-r2.md", revision: 2,
            contentDigest: String(repeating: "d", count: 64), supersedes: previous.id,
            createdAt: previous.createdAt, updatedAt: now)
    }
    func request(_ original: MemoryConversationPublicationAppend, publication: MemoryConversationPublication? = nil,
                 userText: String? = nil, userID: MessageID? = nil,
                 validation: MemoryConversationPublicationValidation? = nil) -> MemoryConversationPublicationAppend {
        .init(publication: publication ?? original.publication, userMessageID: userID ?? original.userMessageID,
              userPartID: original.userPartID, replyPartID: original.replyPartID, userText: userText ?? original.userText,
              expectedPreviousSequence: original.expectedPreviousSequence, validation: validation ?? original.validation)
    }
    func publication(_ original: MemoryConversationPublication, text: String? = nil,
                     lineage: MemoryPublicationLineage? = nil) -> MemoryConversationPublication {
        let r = original.receipt, rendered = text ?? original.text
        let receipt = MemoryPublicationReceipt(id: r.id, policyVersion: r.policyVersion, runID: r.runID, messageID: r.messageID,
            teammateID: r.teammateID, selectedProjectID: r.selectedProjectID, intent: r.intent,
            renderedTextDigest: MemoryClaimDigests.bytes(Data(rendered.utf8)), units: r.units, dependencies: r.dependencies,
            omittedUnitCount: r.omittedUnitCount, lineage: lineage ?? r.lineage, createdAt: r.createdAt)
        return .init(completeUnits: text.map { [$0] } ?? original.completeUnits, receipt: receipt, omittedUnitCount: original.omittedUnitCount)
    }
}

private struct ConversationPublicationResolver: MemoryConversationPublicationResolving {
    let claim: MemoryClaim; let reference: MemoryClaimReference; let scope: MemoryScope
    let authority: ReadContextReceipt; let store: SQLiteStore
    func resolveClaim(_ requested: MemoryClaimReference, context: MemoryPublicationContext) async throws -> MemoryPublicationClaimSnapshot? {
        guard requested == reference else { return nil }
        return .init(claim: claim, reference: reference, scope: scope,
            useContext: .init(purpose: .conversation, now: context.now, teammateID: context.teammateID,
                selectedProjectID: context.selectedProjectID, activeProjectMemberships: Set(context.selectedProjectID.map { [$0] } ?? []),
                currentReference: reference, freshness: .current, isRelevant: true, conditionsSatisfied: true), lineage: .independent)
    }
    func resolveReceipt(_ id: UUID, context: MemoryPublicationContext) async throws -> MemoryPublicationReceipt? {
        try await store.memoryConversationPublication(id: id)?.publication.receipt
    }
    func revalidate(_ receipt: MemoryPublicationReceipt, context: MemoryPublicationContext) async throws -> Bool {
        try await store.revalidateReadContext(authority); return true
    }
}

private func expectConversationPublicationError(_ expected: MemoryConversationPublicationRepositoryError,
                                               operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected \(expected)") }
    catch let actual as MemoryConversationPublicationRepositoryError { #expect(actual == expected) }
    catch { Issue.record("Expected \(expected), got \(error)") }
}
