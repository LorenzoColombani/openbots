import Foundation
import OpenBotsContent
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Certainty-safe snapshot sharing")
struct MemoryClaimSnapshotSharingTests {
    @Test("Production composition shares one validator and exports only explicitly selected current documents")
    func productionExplicitSelection() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let (storage, database, authority) = try await f.production()
        try await f.seed(database)
        let context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let inspection = MemoryKnowledgeService(repository: database, authority: authority, clock: { f.date })
        let unselected = try await inspection.publishRevision(title: "Unselected legacy note", scope: .teammate(f.bot),
            author: .user, markdown: "This unassessed note was not selected for sharing.")
        let mixedContext = try await f.context(database, documents: [value.document.id, unselected.id])
        let mixed = try await storage.qualifiedMemorySnapshotServices(context: mixedContext,
            locationChecker: SnapshotSharingLocation(), clock: { f.date })
        await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
            _ = try await mixed.sharing.renderSelectedDocuments(documentIDs: [value.document.id, unselected.id],
                workspaceSnapshotID: UUID())
        }
        let selected = try await f.context(database, documents: [value.document.id])
        let services = try await storage.qualifiedMemorySnapshotServices(context: selected,
            locationChecker: SnapshotSharingLocation(), clock: { f.date })
        let workspace = UUID(), target = f.root.appending(path: "Production Selected Snapshot.md")
        let snapshot = try await services.sharing.renderSelectedDocuments(documentIDs: [value.document.id],
            workspaceSnapshotID: workspace)
        #expect(snapshot.purpose == .qualifiedSharing && snapshot.sourceCount == 1)
        #expect(snapshot.sources.map(\.documentID) == [value.document.id])
        #expect(!snapshot.markdown.contains("This unassessed note was not selected"))
        #expect(try await database.document(id: unselected.id) == unselected)
        let raw = try KnowledgeSnapshotRenderer().render(sources: snapshot.sources, generatedAt: f.date)
        await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
            _ = try await services.delivery.freeze(workspaceSnapshotID: workspace, snapshot: raw, exactTarget: target)
        }
        let frozen = try await services.delivery.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let receipt = try await services.delivery.create(workspaceSnapshotID: workspace, delivery: frozen)
        #expect(try Data(contentsOf: target) == snapshot.data)
        #expect(receipt.claimReferences == snapshot.claimReferences && receipt.contentDigest == snapshot.contentDigest)
        await #expect(throws: KnowledgeSnapshotDeliveryError.staleOrUnknownToken) {
            _ = try await services.delivery.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
    }

    @Test("Production selected-ID route refuses unknown, duplicate, empty, excessive and unsafe selections")
    func productionSelectionIsExplicitAndAllOrNothing() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let (storage, database, authority) = try await f.production()
        try await f.seed(database, uncertain: true)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let context = try await f.context(database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let selected = try await f.context(database, documents: [value.document.id])
        let services = try await storage.qualifiedMemorySnapshotServices(context: selected,
            locationChecker: SnapshotSharingLocation(), clock: { f.date })
        let selections: [[MemoryDocumentID]] = [[], [MemoryDocumentID(UUID())],
            [value.document.id, value.document.id], (0..<17).map { _ in MemoryDocumentID(UUID()) }, [value.document.id]]
        for ids in selections {
            await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
                _ = try await services.sharing.renderSelectedDocuments(documentIDs: ids, workspaceSnapshotID: UUID())
            }
        }
        #expect(try await database.document(id: value.document.id) == value.document)
    }

    @Test("Production snapshot composition binds frozen context and rechecks actual evidence before create")
    func productionRevalidation() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let (storage, database, authority) = try await f.production()
        try await f.seed(database)
        let context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let selected = try await f.context(database, documents: [value.document.id])
        let forged = ReadContextReceipt(conversationID: selected.conversationID, teammateID: TeammateID(UUID()),
            profileRevision: selected.profileRevision, contextRevision: selected.contextRevision,
            selectedProjectID: selected.selectedProjectID, selectedTeamID: selected.selectedTeamID,
            participantJoinedAt: selected.participantJoinedAt, projectMembershipJoinedAt: selected.projectMembershipJoinedAt,
            teamMembershipJoinedAt: selected.teamMembershipJoinedAt, messages: [], memoryDocuments: selected.memoryDocuments)
        await #expect(throws: ReadContextError.self) {
            _ = try await storage.qualifiedMemorySnapshotServices(context: forged,
                locationChecker: SnapshotSharingLocation(), clock: { f.date })
        }
        let services = try await storage.qualifiedMemorySnapshotServices(context: selected,
            locationChecker: SnapshotSharingLocation(), clock: { f.date })
        let workspace = UUID(), target = f.root.appending(path: "Invalidated Production Snapshot.md")
        let snapshot = try await services.sharing.renderSelectedDocuments(documentIDs: [value.document.id],
            workspaceSnapshotID: workspace)
        let frozen = try await services.delivery.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        _ = try await database.execute(sql: "UPDATE message_parts SET text_value='Changed after explicit selection' WHERE message_id=?;",
            bindings: [.text(f.message.persistedValue)])
        await #expect(throws: MemoryEvidenceVerifierError.self) {
            _ = try await services.delivery.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(snapshot.contentDigest == MemoryClaimDigests.bytes(snapshot.data))
        await #expect(throws: KnowledgeSnapshotDeliveryError.staleOrUnknownToken) {
            _ = try await services.delivery.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
    }

    @Test("Production project sharing requires the same selected project and live membership through create")
    func productionProjectRevocation() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let (storage, database, authority) = try await f.production()
        try await f.seed(database)
        let project = ProjectID(UUID())
        try await database.insert(Project(id: project, name: "Selected sharing fixture", createdAt: f.date, updatedAt: f.date))
        try await database.setMembership(ProjectMembership(projectID: project, teammateID: f.bot, joinedAt: f.date))
        let initial = try await database.loadContext(conversationID: f.chat)
        _ = try await database.saveContext(ConversationContextSelection(conversationID: f.chat, teammateID: f.bot,
            projectID: project, revision: initial.revision))
        let context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier,
                                            scope: .project(project))
        let selected = try await f.context(database, documents: [value.document.id])
        let services = try await storage.qualifiedMemorySnapshotServices(context: selected,
            locationChecker: SnapshotSharingLocation(), clock: { f.date })
        let workspace = UUID(), target = f.root.appending(path: "Revoked Project Snapshot.md")
        let snapshot = try await services.sharing.renderSelectedDocuments(documentIDs: [value.document.id],
            workspaceSnapshotID: workspace)
        #expect(snapshot.sources.first?.scope == .project(project))
        let frozen = try await services.delivery.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        try await database.setMembership(ProjectMembership(projectID: project, teammateID: f.bot,
            joinedAt: f.date, revokedAt: f.date.addingTimeInterval(1)))
        await #expect(throws: ReadContextError.self) {
            _ = try await services.delivery.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
        await #expect(throws: ReadContextError.self) {
            _ = try await storage.qualifiedMemorySnapshotServices(context: selected,
                locationChecker: SnapshotSharingLocation(), clock: { f.date })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try await database.document(id: value.document.id) == value.document)
    }

    @Test("Registered current confirmed memory freezes and writes only the complete qualified projection")
    func confirmedProjection() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let sharing = f.sharing(database, authority: authority, context: context, evidence: verifier)
        let workspace = UUID()
        let snapshot = try await sharing.render(workspaceSnapshotID: workspace, sources: [value.source], generatedAt: f.date)
        #expect(snapshot.purpose == .qualifiedSharing)
        #expect(snapshot.claimReferences.count == 1)
        #expect(snapshot.markdown.contains("Well supported for now, but still revisable:"))
        #expect(!snapshot.markdown.contains("openbots-memory-claim"))
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: SnapshotSharingLocation(), sharing: sharing)
        let target = f.root.appending(path: "Explicitly Approved Snapshot.md")
        let frozen = try await broker.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let receipt = try await broker.create(workspaceSnapshotID: workspace, delivery: frozen)
        #expect(try Data(contentsOf: target) == snapshot.data)
        #expect(receipt.contentDigest == snapshot.contentDigest && receipt.byteCount == snapshot.data.count)
        #expect(receipt.claimReferences == snapshot.claimReferences && receipt.policyVersion == MemoryClaimUsePolicy.version)
        #expect(try await database.document(id: value.document.id) == value.document)
    }

    @Test("A changed durable evidence body after freeze rejects the write without changing frozen content")
    func changedEvidenceAfterFreeze() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority(), context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let sharing = f.sharing(database, authority: authority, context: context, evidence: verifier)
        let workspace = UUID()
        let snapshot = try await sharing.render(workspaceSnapshotID: workspace, sources: [value.source], generatedAt: f.date)
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: SnapshotSharingLocation(), sharing: sharing)
        let target = f.root.appending(path: "Must Not Exist.md")
        let frozen = try await broker.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        _ = try await database.execute(sql: "UPDATE message_parts SET text_value='Changed source, not frozen approval' WHERE message_id=?;",
            bindings: [.text(f.message.persistedValue)])
        await #expect(throws: MemoryEvidenceVerifierError.self) {
            _ = try await broker.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(snapshot.contentDigest == MemoryClaimDigests.bytes(snapshot.data))
        await #expect(throws: KnowledgeSnapshotDeliveryError.staleOrUnknownToken) {
            _ = try await broker.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
    }

    @Test("A pending correction invalidates already-frozen sharing before any destination write")
    func pendingCorrectionAfterFreeze() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority(), context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let sharing = f.sharing(database, authority: authority, context: context, evidence: verifier)
        let workspace = UUID()
        let snapshot = try await sharing.render(workspaceSnapshotID: workspace, sources: [value.source], generatedAt: f.date)
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: SnapshotSharingLocation(), sharing: sharing)
        let target = f.root.appending(path: "Pending Must Not Export.md")
        let frozen = try await broker.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        let id = MemoryDocumentID(UUID())
        let next = try MemoryDocument(id: id, scope: value.document.scope, author: .user, title: "Pending correction",
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: id, scope: value.document.scope, revision: 2),
            revision: 2, contentDigest: String(repeating: "a", count: 64), supersedes: value.document.id,
            createdAt: f.date, updatedAt: f.date)
        let old = value.intent
        _ = try await database.prepareMemoryPublication(MemoryPublicationIntent(id: UUID(), document: next,
            expectedPredecessor: value.document, authority: context, actor: old.actor,
            evidenceDigest: old.evidenceDigest, policyDigest: old.policyDigest, byteCount: old.byteCount,
            userMessageEvidence: old.userMessageEvidence, createdAt: f.date))
        await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
            _ = try await broker.create(workspaceSnapshotID: workspace, delivery: frozen)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Legacy, uncertain, missing policy markers, foreign scope and degraded sources are not sharing authority")
    func unsafeSources() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database, uncertain: true)
        let authority = try await f.authority(), context = try await f.context(database)
        let verifier = MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database)
        let value = try await f.publishUser(database, authority: authority, context: context, verifier: verifier)
        let sharing = f.sharing(database, authority: authority, context: context, evidence: verifier)
        await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
            _ = try await sharing.render(workspaceSnapshotID: UUID(), sources: [value.source], generatedAt: f.date)
        }
        let knowledge = MemoryKnowledgeService(repository: database, authority: authority, clock: { f.date })
        let legacy = try await knowledge.publishRevision(title: "Legacy unassessed", scope: .teammate(f.bot),
            author: .user, markdown: "Legacy unqualified prose")
        let legacySource = try f.source(legacy, markdown: "Legacy unqualified prose")
        await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
            _ = try await sharing.render(workspaceSnapshotID: UUID(), sources: [legacySource], generatedAt: f.date)
        }
        let recovered = try KnowledgeSnapshotSource(documentID: value.source.documentID, title: value.source.title,
            scope: value.source.scope, author: value.source.author, revision: 1, contentDigest: value.source.contentDigest,
            updatedAt: value.source.updatedAt, revisionStatus: .lastKnownGood(unavailableNewerRevision: 2), markdown: value.source.markdown)
        let foreign = try KnowledgeSnapshotSource(documentID: MemoryDocumentID(UUID()), title: "Excluded",
            scope: .teammate(TeammateID(UUID())), author: .user, revision: 1, contentDigest: String(repeating: "a", count: 64),
            updatedAt: f.date, revisionStatus: .current, markdown: "No file is read for this scope")
        for source in [recovered, foreign] {
            await #expect(throws: KnowledgeSnapshotDeliveryError.sharingDenied) {
                _ = try await sharing.render(workspaceSnapshotID: UUID(), sources: [source], generatedAt: f.date)
            }
        }
        #expect(try await database.document(id: legacy.id) == legacy)
    }

    @Test("A synthetic registered middle predicate preserves attribution, uncertainty and literal text through the write")
    func attributedMiddleProjection() async throws {
        let f = try SnapshotSharingFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority(), context = try await f.context(database)
        let registry = try SnapshotInferenceRegistry(scope: .teammate(f.bot), now: f.date)
        let value = try await f.publish(database, authority: authority, context: context, claim: registry.claim,
            actor: .app(verifierID: "synthetic-inference"), verifier: registry)
        let sharing = f.sharing(database, authority: authority, context: context, evidence: registry)
        let workspace = UUID()
        let snapshot = try await sharing.render(workspaceSnapshotID: workspace, sources: [value.source], generatedAt: f.date)
        #expect(snapshot.markdown.contains("seems plausible, but may be wrong"))
        #expect(snapshot.markdown.contains("From checked recorded sources"))
        #expect(snapshot.markdown.contains("\\n# Not a new heading"))
        #expect(!snapshot.markdown.contains("\n# Not a new heading"))
        let broker = KnowledgeSnapshotDeliveryBroker(locationChecker: SnapshotSharingLocation(), sharing: sharing)
        let target = f.root.appending(path: "Qualified Inference.md")
        let frozen = try await broker.freeze(workspaceSnapshotID: workspace, snapshot: snapshot, exactTarget: target)
        _ = try await broker.create(workspaceSnapshotID: workspace, delivery: frozen)
        #expect(try Data(contentsOf: target) == snapshot.data)
        // Production MemoryEvidenceVerifier has no arbitrary inference predicate;
        // this positive fixture proves only the explicit registered-host seam.
        let native = f.sharing(database, authority: authority, context: context,
            evidence: MemoryEvidenceVerifier(messages: database, teammates: database, contexts: database))
        await #expect(throws: MemoryEvidenceVerifierError.self) {
            _ = try await native.render(workspaceSnapshotID: UUID(), sources: [value.source], generatedAt: f.date)
        }
    }

    @Test("Pure sharing projection cannot relabel low or unknown claims; inspection remains available")
    func lowAndUnknownProjectionDenied() throws {
        let scope = MemoryScope.teammate(TeammateID(UUID()))
        for level in [MemoryClaimAssessmentLevel.unassessed, .uncertain, .unknown("future-assessment")] {
            let id = MemoryDocumentID(UUID())
            let claim = MemoryClaim(id: MemoryClaimID(UUID()), body: "An unproven retained assertion",
                assessment: MemoryClaimAssessment(level: level, basis: "Unverified source",
                    assessor: MemoryClaimAssessor(kind: .unassessed)), provenance: [])
            let artifact = MemoryClaimArtifact(documentID: id, revision: 1, scope: scope, claims: [claim])
            let codec = MemoryClaimCodec()
            let bytes: Data
            if case .unknown = level {
                #expect(throws: MemoryClaimCodecError.unsupported) { _ = try codec.encode(artifact) }
                // Simulate retained future bytes, which the current app must not
                // author or reinterpret as a supported assessed claim.
                var retained = Data(MemoryClaimCodec.header.utf8)
                retained.append(try MemoryClaimDigests.canonicalData(artifact))
                retained.append(Data(MemoryClaimCodec.footer.utf8))
                bytes = retained
                let decoded = codec.decode(bytes)
                #expect(decoded.status == .unsupported && decoded.artifact == nil)
                #expect(decoded.originalBytes == bytes)
            } else {
                bytes = try codec.encode(artifact)
            }
            let source = try KnowledgeSnapshotSource(documentID: id, title: "Private inspection", scope: scope,
                author: .user, revision: 1, contentDigest: MemoryClaimDigests.bytes(bytes),
                updatedAt: Date(timeIntervalSince1970: 10), revisionStatus: .current, markdown: String(decoding: bytes, as: UTF8.self))
            #expect(try KnowledgeSnapshotRenderer().render(sources: [source], generatedAt: Date()).purpose == .ownerInspection)
            #expect(throws: KnowledgeSnapshotError.sharingDenied) {
                _ = try KnowledgeSnapshotRenderer().renderQualifiedSharing(sources: [source], generatedAt: Date())
            }
        }
    }

    @Test("Qualified snapshot equality canonicalizes both sources and claim references")
    func qualifiedProjectionOrderIsDeterministic() throws {
        let scope = MemoryScope.teammate(TeammateID(UUID()))
        let date = Date(timeIntervalSince1970: 10)
        let sources = try (0..<2).map { index in
            let registry = try SnapshotInferenceRegistry(scope: scope, now: date)
            let id = MemoryDocumentID(UUID())
            let artifact = MemoryClaimArtifact(documentID: id, revision: 1, scope: scope, claims: [registry.claim])
            let bytes = try MemoryClaimCodec().encode(artifact)
            return try KnowledgeSnapshotSource(documentID: id, title: "Synthetic source \(index)", scope: scope,
                author: .system, revision: 1, contentDigest: MemoryClaimDigests.bytes(bytes), updatedAt: date,
                revisionStatus: .current, markdown: String(decoding: bytes, as: UTF8.self))
        }
        let renderer = KnowledgeSnapshotRenderer()
        let first = try renderer.renderQualifiedSharing(sources: sources, generatedAt: date)
        let reversed = try renderer.renderQualifiedSharing(sources: Array(sources.reversed()), generatedAt: date)
        #expect(first == reversed)
        #expect(first.sources.map(\.documentID) == first.claimReferences.map(\.documentID))
    }
}

private struct SnapshotSharingValue {
    let document: MemoryDocument
    let source: KnowledgeSnapshotSource
    let intent: MemoryPublicationIntent
}

private struct SnapshotSharingLocation: MacOSLocationAdmissionChecking, LocationEnvironmentChecking {
    func observation(for url: URL) throws -> LocationObservation {
        LocationObservation(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
            fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-sharing-volume")
    }
}

private struct SnapshotSharingFixture: Sendable {
    let root: URL, layout: PreviewStorageLayout, plan: PreviewRootCreationPlan, protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), chat = ConversationID(UUID()), message = MessageID(UUID())
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextSharing-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "Temporary", directoryHint: .isDirectory)
        for directory in [home.appending(path: "Library/Application Support"), home.appending(path: "Library/Caches"), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        plan = try PreviewRootCreationPlan(layout: layout, installationID: UUID(),
            rootIDs: [.applicationSupport: UUID(), .caches: UUID(), .temporary: UUID()])
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: date, rationaleVersion: 2)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func production() async throws -> (StoragePersistenceContext, SQLiteStore, VerifiedAuthoritativeMarkdownRoot) {
        let storage = try await StoragePersistenceCompositionService(layout: layout,
            bootstrapper: StorageBootstrapService(layout: layout, locationAdmission: SnapshotSharingLocation()))
            .bootstrapAndOpen(using: plan, protection: .ordinarySQLite, decision: protection)
        let database = try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: storage.databaseURL,
            protection: .ordinarySQLite(decision: protection)))
        let authority = try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot,
                                                                       inside: storage.applicationSupportRoot)
        return (storage, database, authority)
    }
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let roots = try await StorageBootstrapService(layout: layout, locationAdmission: SnapshotSharingLocation()).bootstrap(using: plan)
        let support = try #require(roots.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: support)
    }
    func seed(_ database: SQLiteStore, uncertain: Bool = false) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Sharing Bot", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await database.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        let command = (uncertain ? "Remember as uncertain: " : "I confirm from first-hand knowledge: ") + "Synthetic cobalt is preferred."
        try await database.append(Message(id: message, conversationID: chat, sequence: 1, author: .user, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(command))],
            createdAt: date, updatedAt: date), expectedPreviousSequence: 0)
    }
    func context(_ database: SQLiteStore, documents: [MemoryDocumentID] = []) async throws -> ReadContextReceipt {
        let selection = try await database.loadContext(conversationID: chat)
        let snapshot = try await database.loadReadContextCandidates(ReadContextRequest(conversationID: chat, teammateID: bot,
            profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        return try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: documents)
    }
    func sharing(_ database: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot, context: ReadContextReceipt,
                 evidence: any MemoryRetainedEvidenceVerifying) -> MemoryClaimSnapshotSharingService {
        MemoryClaimSnapshotSharingService(memory: database, intents: database, contexts: database, evidence: evidence,
            authority: authority, context: context, clock: { date })
    }
    func publishUser(_ database: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot,
                     context: ReadContextReceipt, verifier: MemoryEvidenceVerifier,
                     scope selectedScope: MemoryScope? = nil) async throws -> SnapshotSharingValue {
        let scope = selectedScope ?? .teammate(bot)
        let claim = try await verifier.userProposal(messageID: message, claimID: MemoryClaimID(UUID()),
            scope: scope, authority: context, at: date)
        return try await publish(database, authority: authority, context: context, claim: claim,
            actor: .user(messageID: message), verifier: verifier, scope: scope)
    }
    func publish(_ database: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot, context: ReadContextReceipt,
                 claim: MemoryClaim, actor: MemoryPublicationActor,
                 verifier: any MemoryAdmissionEvidenceVerifying,
                 scope selectedScope: MemoryScope? = nil) async throws -> SnapshotSharingValue {
        let artifact = MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: 1,
            scope: selectedScope ?? .teammate(bot), claims: [claim])
        let service = MemoryClaimAdmissionService(memory: database, intents: database, contexts: database,
            verifier: verifier, authority: authority, clock: { date })
        let record = try await service.publish(operationID: UUID(), artifact: artifact, title: "Qualified source",
            expectedPredecessor: nil, actor: actor, context: context)
        let bytes = try MemoryClaimCodec().encode(artifact)
        return SnapshotSharingValue(document: record.intent.document,
            source: try source(record.intent.document, markdown: String(decoding: bytes, as: UTF8.self)), intent: record.intent)
    }
    func source(_ document: MemoryDocument, markdown: String) throws -> KnowledgeSnapshotSource {
        try KnowledgeSnapshotSource(documentID: document.id, title: document.title, scope: document.scope,
            author: document.author, revision: document.revision, contentDigest: document.contentDigest,
            updatedAt: document.updatedAt, revisionStatus: .current, markdown: markdown)
    }
}

/// Finite synthetic registry used only to prove the middle policy branch. It
/// cannot be selected by model output or by the production concrete verifier.
private struct SnapshotInferenceRegistry: MemoryAdmissionEvidenceVerifying, MemoryRetainedEvidenceVerifying {
    let claim: MemoryClaim
    let scope: MemoryScope
    let reference: MemoryClaimEvidenceReference
    init(scope: MemoryScope, now: Date) throws {
        self.scope = scope
        let id = MemoryClaimID(UUID())
        let source = MemoryClaimSourceReference(id: UUID(), kind: .appObservation, sourceID: "synthetic:inference",
            sourceRevision: 1, contentDigest: MemoryClaimDigests.bytes(Data("inert observation".utf8)), observedAt: now, scope: scope)
        let body = "Synthetic pattern\n# Not a new heading"
        let draft = MemoryClaim(id: id, body: body,
            assessment: MemoryClaimAssessment(level: .supportedInference, basis: "A synthetic observation supports a tentative relation.",
                assessor: MemoryClaimAssessor(kind: .app, identity: "synthetic-inference"), assessedAt: now),
            provenance: [source], observedAt: now)
        reference = MemoryClaimEvidenceReference(receiptID: UUID(), receiptDigest: MemoryClaimDigests.bytes(Data("inert receipt".utf8)),
            source: source, relation: .supports, subjectDigest: try MemoryClaimDigests.subject(draft, scope: scope))
        claim = MemoryClaim(id: id, body: body, assessment: MemoryClaimAssessment(level: .supportedInference,
            basis: draft.assessment.basis, assessor: draft.assessment.assessor, assessedAt: now, evidence: [reference]),
            provenance: [source], observedAt: now)
    }
    func verifyRetained(claim: MemoryClaim, scope: MemoryScope, authority: ReadContextReceipt,
                        at now: Date) async throws -> [MemoryClaimVerifiedEvidence] {
        guard claim == self.claim, scope == self.scope else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        return [MemoryClaimVerifiedEvidence(reference: reference, claimID: claim.id, scope: scope,
            authority: .appVerifier, verifierID: "synthetic-inference", verifierVersion: 1,
            checkedAt: now, validUntil: now.addingTimeInterval(60), independentEvidenceID: reference.source.id)]
    }
    func verify(artifact: MemoryClaimArtifact, predecessor: MemoryClaimArtifact?, actor: MemoryPublicationActor,
                authority: ReadContextReceipt, at now: Date) async throws -> MemoryAdmissionEvidence {
        guard artifact.claims == [claim], predecessor == nil, actor == .app(verifierID: "synthetic-inference") else {
            throw KnowledgeSnapshotDeliveryError.sharingDenied
        }
        return MemoryAdmissionEvidence(verified: try await verifyRetained(claim: claim, scope: scope, authority: authority, at: now))
    }
}
