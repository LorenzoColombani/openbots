import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Certainty admission with real SQLite and protected artifacts")
struct MemoryClaimAdmissionIntegrationTests {
    @Test("Publication commits exact artifact and catalog; a later-clock retry after reopen is the same operation")
    func publishAndReopen() async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let context = try await f.context(database)
        let artifact = f.artifact()
        let operation = UUID()
        let service = try f.service(database, authority: authority)
        let saved = try await service.publish(operationID: operation, artifact: artifact, title: "Synthetic facts",
            expectedPredecessor: nil, actor: .user(messageID: f.message), context: context)
        #expect(saved.state == .committed && saved.revision == 2)
        #expect(try await database.document(id: artifact.documentID) == saved.intent.document)
        let read = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: saved.intent.document), inside: authority)
        let expected = try MemoryClaimCodec().encode(artifact)
        #expect(Data(read.markdown.utf8) == expected)
        #expect(saved.intent.byteCount == expected.count)
        #expect(saved.intent.document.contentDigest == MemoryClaimDigests.bytes(expected))
        #expect(!FileManager.default.fileExists(atPath: authority.url.appending(path: saved.intent.stagingRelativePath).path))
        let reopened = try f.open()
        let newService = try f.service(reopened, authority: authority, now: f.date.addingTimeInterval(3_600))
        let retried = try await newService.publish(operationID: operation, artifact: artifact, title: "Synthetic facts",
            expectedPredecessor: nil, actor: .user(messageID: f.message), context: context)
        #expect(retried == saved)
        #expect(try await reopened.allDocuments().count == 1)
        #expect(try await newService.reconcile().isEmpty)
    }

    @Test("Recovery considers only named final or staging artifacts; missing bytes abort without publication",
          arguments: AdmissionPendingLocation.allCases)
    func reconcileNamedArtifact(_ location: AdmissionPendingLocation) async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let artifact = f.artifact()
        let intent = try await f.prepare(database, artifact: artifact)
        if location != .missing {
            let publication = try await f.publishArtifact(intent, artifact: artifact, authority: authority)
            if location == .staging {
                try FileManager.default.moveItem(at: publication.exactFileURL,
                    to: authority.url.appending(path: intent.stagingRelativePath))
            }
        }
        let untouched = authority.url.appending(path: "unrelated-private-fixture.txt")
        try Data("untouched fixture".utf8).write(to: untouched, options: .withoutOverwriting)
        let reopened = try f.open()
        let service = try f.service(reopened, authority: authority)
        let settled = try await service.reconcile()
        #expect(settled.count == 1)
        #expect(settled.first?.intent.id == intent.id)
        if location == .missing {
            #expect(settled.first?.state == .aborted)
            #expect(try await reopened.document(id: artifact.documentID) == nil)
        } else {
            #expect(settled.first?.state == .committed)
            #expect(try await reopened.document(id: artifact.documentID) == intent.document)
            let read = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: intent.document), inside: authority)
            let expectedBytes = try MemoryClaimCodec().encode(artifact)
            #expect(Data(read.markdown.utf8) == expectedBytes)
            #expect(!FileManager.default.fileExists(atPath: authority.url.appending(path: intent.stagingRelativePath).path))
        }
        #expect(try Data(contentsOf: untouched) == Data("untouched fixture".utf8))
        #expect(try await service.reconcile().isEmpty)
    }

    @Test("Failed final evidence leaves no success; failed recovery aborts and fences predecessor without deleting files")
    func failedEvidenceRemainsFenced() async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let context = try await f.context(database)
        let first = f.artifact()
        let good = try f.service(database, authority: authority)
        let predecessor = try await good.publish(operationID: UUID(), artifact: first, title: "Original",
            expectedPredecessor: nil, actor: .user(messageID: f.message), context: context)
        let next = f.artifact(predecessor: first)
        let operation = UUID()
        let verifier = AdmissionIntegrationVerifier(evidence: try f.evidence(), failFromCall: 2)
        let failing = try f.service(database, authority: authority, verifier: verifier)
        do {
            _ = try await failing.publish(operationID: operation, artifact: next, title: "Pending correction",
                expectedPredecessor: predecessor.intent.document, actor: .user(messageID: f.message), context: context)
            Issue.record("Unverified final evidence must not acknowledge publication")
        } catch AdmissionIntegrationFailure.rejected { }
        let pendingRecord = try await database.memoryPublication(id: operation)
        let pending = try #require(pendingRecord)
        #expect(pending.state == .pending)
        #expect(try await database.document(id: next.documentID) == nil)
        let pendingURL = authority.url.appending(path: pending.intent.document.relativePath)
        let preservedBytes = try Data(contentsOf: pendingURL)
        let settled = try await failing.reconcile()
        #expect(settled.first?.state == .aborted)
        #expect(try await database.memoryPublicationBlocksUse(documentID: predecessor.intent.document.id))
        #expect(try Data(contentsOf: pendingURL) == preservedBytes)
        _ = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: predecessor.intent.document), inside: authority)
        #expect(try await good.reconcile().isEmpty)
        #expect(try await database.document(id: next.documentID) == nil)
    }

    @Test("Revoked selected-project authority aborts recovery and cannot restore the prior head to active use")
    func revokedProjectRecovery() async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let selected = try await database.loadContext(conversationID: f.chat)
        _ = try await database.saveContext(ConversationContextSelection(conversationID: f.chat, teammateID: f.bot,
            projectID: f.project, revision: selected.revision))
        let authority = try await f.authority()
        let first = f.artifact(project: true)
        let service = try f.service(database, authority: authority)
        let predecessor = try await service.publish(operationID: UUID(), artifact: first, title: "Project fact",
            expectedPredecessor: nil, actor: .user(messageID: f.message), context: f.context(database))
        let next = f.artifact(predecessor: first, project: true)
        let intent = try await f.prepare(database, artifact: next, predecessor: predecessor.intent.document)
        let publication = try await f.publishArtifact(intent, artifact: next, authority: authority)
        let before = try Data(contentsOf: publication.exactFileURL)
        try await database.setMembership(ProjectMembership(projectID: f.project, teammateID: f.bot,
            joinedAt: f.date, revokedAt: f.date.addingTimeInterval(1)))
        let settled = try await service.reconcile()
        #expect(settled.first?.state == .aborted)
        #expect(try await database.memoryPublicationBlocksUse(documentID: predecessor.intent.document.id))
        #expect(try await database.document(id: next.documentID) == nil)
        #expect(try Data(contentsOf: publication.exactFileURL) == before)
    }

    @Test("A new revision cannot silently delete another retained claim")
    func retainedClaimCannotDisappear() async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let service = try f.service(database, authority: authority)
        let first = f.artifact()
        let context = try await f.context(database)
        let saved = try await service.publish(operationID: UUID(), artifact: first, title: "Retained facts",
            expectedPredecessor: nil, actor: .user(messageID: f.message), context: context)
        let removed = MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: 2,
            scope: first.scope, claims: [first.claims[0]])
        let operation = UUID()
        do {
            _ = try await service.publish(operationID: operation, artifact: removed, title: "Missing claim",
                expectedPredecessor: saved.intent.document, actor: .user(messageID: f.message), context: context)
            Issue.record("Retained claim was silently removed")
        } catch let error as MemoryClaimAdmissionError { #expect(error == .retainedClaimRemoved) }
        #expect(try await database.memoryPublication(id: operation) == nil)
        #expect(try await database.allDocuments() == [saved.intent.document])
        let read = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: saved.intent.document), inside: authority)
        #expect(MemoryClaimCodec().decode(Data(read.markdown.utf8)).artifact?.claims == first.claims)
    }

    @Test("An explicit concurrent winner is preserved; a stale loser cannot publish a second successor")
    func staleSuccessorDoesNotReplaceWinner() async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let service = try f.service(database, authority: authority)
        let first = f.artifact()
        let context = try await f.context(database)
        let saved = try await service.publish(operationID: UUID(), artifact: first, title: "First",
            expectedPredecessor: nil, actor: .user(messageID: f.message), context: context)
        let winnerArtifact = f.artifact(predecessor: first)
        let winner = try await service.publish(operationID: UUID(), artifact: winnerArtifact, title: "Winner",
            expectedPredecessor: saved.intent.document, actor: .user(messageID: f.message), context: context)
        let loserArtifact = f.artifact(predecessor: first)
        let loserOperation = UUID()
        do {
            _ = try await service.publish(operationID: loserOperation, artifact: loserArtifact, title: "Stale loser",
                expectedPredecessor: saved.intent.document, actor: .user(messageID: f.message), context: context)
            Issue.record("A stale successor was published")
        } catch let error as MemoryPublicationError { #expect(error == .stalePredecessor) }
        #expect(try await database.memoryPublication(id: loserOperation) == nil)
        #expect(try await database.document(id: winnerArtifact.documentID) == winner.intent.document)
        #expect(try await database.document(id: loserArtifact.documentID) == nil)
        #expect(try await !database.memoryPublicationBlocksUse(documentID: winnerArtifact.documentID))
        _ = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: winner.intent.document), inside: authority)
    }

    @Test("Cancellation after filesystem publication is durable and cannot be resumed by recovery")
    func cancellationCannotBecomeRecoveryPermission() async throws {
        let f = try AdmissionIntegrationFixture(); defer { f.remove() }
        let database = try f.open(); try await f.seed(database)
        let authority = try await f.authority()
        let context = try await f.context(database)
        let artifact = f.artifact()
        let operation = UUID()
        let verifier = AdmissionIntegrationVerifier(evidence: try f.evidence(), pauseOnCall: 2)
        let service = try f.service(database, authority: authority, verifier: verifier)
        let publication = Task {
            do {
                let result = try await service.publish(operationID: operation, artifact: artifact, title: "Cancelled fixture",
                    expectedPredecessor: nil, actor: .user(messageID: f.message), context: context)
                await verifier.publicationEnded()
                return result
            } catch {
                await verifier.publicationEnded()
                throw error
            }
        }
        guard await verifier.waitUntilPaused() else {
            _ = try await publication.value
            Issue.record("Fixture never reached final evidence validation")
            return
        }
        publication.cancel()
        await verifier.release()
        do { _ = try await publication.value; Issue.record("Cancelled publication must not acknowledge success") }
        catch is CancellationError { }
        let record = try await database.memoryPublication(id: operation)
        #expect(record?.state == .aborted)
        #expect(try await database.document(id: artifact.documentID) == nil)
        let recovery = try f.service(database, authority: authority)
        #expect(try await recovery.reconcile().isEmpty)
        #expect(try await database.document(id: artifact.documentID) == nil)
    }
}

enum AdmissionPendingLocation: CaseIterable { case final, staging, missing }
private enum AdmissionIntegrationFailure: Error { case rejected }

/// An explicit synthetic verifier, never a production source of user authority.
private actor AdmissionIntegrationVerifier: MemoryAdmissionEvidenceVerifying {
    let evidence: MemoryAdmissionEvidence
    let failFromCall: Int?
    let pauseOnCall: Int?
    var calls = 0
    var paused = false
    var ended = false
    var pause: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Bool, Never>] = []
    init(evidence: MemoryAdmissionEvidence, failFromCall: Int? = nil, pauseOnCall: Int? = nil) {
        self.evidence = evidence; self.failFromCall = failFromCall; self.pauseOnCall = pauseOnCall
    }
    func verify(artifact: MemoryClaimArtifact, predecessor: MemoryClaimArtifact?, actor: MemoryPublicationActor,
                authority: ReadContextReceipt, at now: Date) async throws -> MemoryAdmissionEvidence {
        calls += 1
        if let failFromCall, calls >= failFromCall { throw AdmissionIntegrationFailure.rejected }
        if calls == pauseOnCall {
            await withCheckedContinuation { continuation in
                pause = continuation; paused = true
                let ready = waiters; waiters = []
                for waiter in ready { waiter.resume(returning: true) }
            }
            try Task.checkCancellation()
        }
        return evidence
    }
    func waitUntilPaused() async -> Bool {
        if paused { return true }
        if ended { return false }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release() { let continuation = pause; pause = nil; continuation?.resume() }
    func publicationEnded() {
        ended = true
        let ready = waiters; waiters = []
        for waiter in ready { waiter.resume(returning: false) }
    }
}

private struct AdmissionIntegrationLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        LocationObservation(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
            fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-admission-volume")
    }
}

private struct AdmissionIntegrationFixture: Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let plan: PreviewRootCreationPlan
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), chat = ConversationID(UUID()), project = ProjectID(UUID()), message = MessageID(UUID())
    static let userText = "Please retain these synthetic uncertain facts."

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextAdmissionIntegration-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        for directory in [home.appending(path: "Library/Application Support", directoryHint: .isDirectory),
                          home.appending(path: "Library/Caches", directoryHint: .isDirectory), temporary] {
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
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let receipt = try await StorageBootstrapService(layout: layout,
            locationAdmission: AdmissionIntegrationLocation()).bootstrap(using: plan)
        let verified = try #require(receipt.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: verified)
    }
    func seed(_ database: SQLiteStore) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Admission Bot", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await database.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        try await database.insert(Project(id: project, name: "Synthetic Project", createdAt: date, updatedAt: date))
        try await database.setMembership(ProjectMembership(projectID: project, teammateID: bot, joinedAt: date))
        try await database.append(Message(id: message, conversationID: chat, sequence: 1, author: .user, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(Self.userText))],
            createdAt: date, updatedAt: date), expectedPreviousSequence: 0)
    }
    func context(_ database: SQLiteStore) async throws -> ReadContextReceipt {
        let selection = try await database.loadContext(conversationID: chat)
        let snapshot = try await database.loadReadContextCandidates(ReadContextRequest(conversationID: chat, teammateID: bot,
            profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        return try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: [])
    }
    func evidence() throws -> MemoryAdmissionEvidence {
        MemoryAdmissionEvidence(verified: [], userMessages: [try MemoryPublicationUserMessageEvidence(messageID: message,
            contentDigest: MemoryClaimDigests.bytes(Data(Self.userText.utf8)), updatedAt: date)])
    }
    func service(_ database: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot,
                 verifier: AdmissionIntegrationVerifier? = nil, now: Date? = nil) throws -> MemoryClaimAdmissionService {
        let time = now ?? date
        let checker = try verifier ?? AdmissionIntegrationVerifier(evidence: evidence())
        return MemoryClaimAdmissionService(memory: database, intents: database, contexts: database,
            verifier: checker, authority: authority, clock: { time })
    }
    func artifact(predecessor: MemoryClaimArtifact? = nil, project selected: Bool = false) -> MemoryClaimArtifact {
        let scope = selected ? MemoryScope.project(project) : .teammate(bot)
        let fresh = (0..<(predecessor == nil ? 2 : 1)).map { index in
            MemoryClaim(id: MemoryClaimID(UUID()), body: "Synthetic uncertain detail \(index).",
                assessment: MemoryClaimAssessment(level: .uncertain, basis: "Retained as an unverified user assertion.",
                    assessor: MemoryClaimAssessor(kind: .user, identity: message.persistedValue), assessedAt: date),
                provenance: [], observedAt: date)
        }
        return MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: (predecessor?.revision ?? 0) + 1,
            scope: scope, claims: (predecessor?.claims ?? []) + fresh)
    }
    func prepare(_ database: SQLiteStore, artifact: MemoryClaimArtifact,
                 predecessor: MemoryDocument? = nil) async throws -> MemoryPublicationIntent {
        let bytes = try MemoryClaimCodec().encode(artifact)
        let document = try MemoryDocument(id: artifact.documentID, scope: artifact.scope, author: .user, title: "Pending fixture",
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: artifact.documentID, scope: artifact.scope,
                revision: artifact.revision), revision: artifact.revision, contentDigest: MemoryClaimDigests.bytes(bytes),
            supersedes: predecessor?.id, createdAt: predecessor?.createdAt ?? date, updatedAt: date)
        let evidence = try evidence()
        let receipt = try await context(database)
        let intent = try MemoryPublicationIntent(id: UUID(), document: document, expectedPredecessor: predecessor,
            authority: receipt, actor: .user(messageID: message), evidenceDigest: evidence.digest(),
            policyDigest: MemoryClaimAdmissionService.policyDigest, byteCount: bytes.count,
            userMessageEvidence: evidence.userMessages, createdAt: date)
        _ = try await database.prepareMemoryPublication(intent)
        return intent
    }
    func publishArtifact(_ intent: MemoryPublicationIntent, artifact: MemoryClaimArtifact,
                         authority: VerifiedAuthoritativeMarkdownRoot) async throws -> AuthoritativeMarkdownPublicationReceipt {
        let bytes = try MemoryClaimCodec().encode(artifact)
        return try await AuthoritativeMarkdownStore().publish(AuthoritativeMarkdownPublicationRequest(
            documentID: artifact.documentID, scope: artifact.scope, revision: artifact.revision,
            markdown: String(decoding: bytes, as: UTF8.self), authority: authority, operationID: intent.id))
    }
}
