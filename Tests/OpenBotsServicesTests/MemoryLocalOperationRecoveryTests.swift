import Foundation
import OpenBotsContent
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Bounded local memory restart recovery")
struct MemoryLocalOperationRecoveryTests {
    @Test("Recovery inventory is stable, finite and excludes terminal failed or acknowledged commands")
    func boundedInventory() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), authority = try await f.authority()
        var records: [MemoryLocalCorrectionRecord] = []
        for offset in 0..<4 {
            let subject = RecoverySubject()
            try await f.seed(db, subject: subject)
            let request = try await f.request(db, subject: subject, at: f.date.addingTimeInterval(Double(offset)))
            records.append(try await db.admitMemoryLocalCorrection(request, text: f.command))
        }
        _ = try await db.failMemoryLocalCorrection(userMessageID: records[2].request.userMessageID,
            expectedRevision: records[2].revision, failure: .cancelled, now: f.now)
        let acknowledged = await f.service(db, authority: authority).recoverSavedOperation(.init(record: records[3]))
        #expect(acknowledged.outcome == .completed)
        let first = try await db.recoverableMemoryLocalCorrections(limit: 1)
        #expect(first.markers == [.init(record: records[0])] && first.hasMore)
        #expect(try await db.recoverableMemoryLocalCorrections(limit: 1) == first)
        let all = try await db.recoverableMemoryLocalCorrections(limit: 16)
        #expect(all.markers == records.prefix(2).map { .init(record: $0) } && !all.hasMore)
        for limit in [0, 17] {
            await #expect(throws: MemoryLocalCorrectionError.invalidRequest) {
                _ = try await db.recoverableMemoryLocalCorrections(limit: limit)
            }
        }
    }

    @Test("Reopen resumes the saved command once with its original operation and message identities")
    func admittedRecoveryAndReopen() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), subject = RecoverySubject()
        try await f.seed(db, subject: subject)
        let request = try await f.request(db, subject: subject)
        _ = try await db.admitMemoryLocalCorrection(request, text: f.command)
        let authority = try await f.authority(), reopened = try f.open()
        let recovery = MemoryLocalOperationRecoveryService(repository: reopened, corrections: f.service(reopened, authority: authority))
        let report = await recovery.recover()
        #expect(report.status == .completed && report.recoveredCount == 1 && !report.needsAttention)
        #expect(report.notice == nil && report.entries.first?.marker.operationID == request.operationID)
        #expect(await recovery.recover() == report)
        let saved = try #require(try await reopened.memoryLocalCorrection(userMessageID: request.userMessageID))
        #expect(saved.request == request && saved.state == .acknowledged)
        #expect(saved.userMessage.parts.first?.content == .text(f.command))
        #expect(saved.acknowledgement?.id == request.acknowledgementMessageID)
        let messages = try await reopened.page(conversationID: subject.chat, request: PageRequest(limit: 10))
        #expect(messages.elements.map(\.id) == [request.userMessageID, request.acknowledgementMessageID])
        #expect(try await reopened.runs(conversationID: subject.chat, limit: 10).isEmpty)
        let again = try f.open()
        let second = await MemoryLocalOperationRecoveryService(repository: again, corrections: f.service(again, authority: authority)).recover()
        #expect(second.entries.isEmpty && !second.needsAttention)
        #expect(try await again.allDocuments().count == 1)
    }

    @Test("A staging-only exact publication recovers without scanning or changing an unrelated file")
    func stagedPublicationRecovery() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), subject = RecoverySubject()
        try await f.seed(db, subject: subject)
        let request = try await f.request(db, subject: subject)
        _ = try await db.admitMemoryLocalCorrection(request, text: f.command)
        let authority = try await f.authority()
        let prepared = try await f.preparePublication(db, request: request)
        _ = try await db.prepareMemoryPublication(prepared.intent)
        let file = try await AuthoritativeMarkdownStore().publish(AuthoritativeMarkdownPublicationRequest(
            documentID: request.documentID, scope: prepared.artifact.scope, revision: 1,
            markdown: String(decoding: prepared.bytes, as: UTF8.self), authority: authority, operationID: request.operationID))
        let stage = authority.url.appending(path: prepared.intent.stagingRelativePath)
        try FileManager.default.moveItem(at: file.exactFileURL, to: stage)
        let unrelated = f.root.appending(path: "unrelated-retained.txt")
        let unrelatedBytes = Data("Never part of recovery".utf8)
        try unrelatedBytes.write(to: unrelated, options: .withoutOverwriting)
        let reopened = try f.open()
        let report = await MemoryLocalOperationRecoveryService(repository: reopened, corrections: f.service(reopened, authority: authority)).recover()
        #expect(report.recoveredCount == 1 && !report.needsAttention)
        #expect(try await reopened.memoryPublication(id: request.operationID)?.state == .committed)
        #expect(try Data(contentsOf: file.exactFileURL) == prepared.bytes)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
    }

    @Test("A newer conversation message leaves a committed update saved but does not fabricate its acknowledgement")
    func committedAcknowledgementRemainsUnresolved() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), subject = RecoverySubject()
        try await f.seed(db, subject: subject)
        let request = try await f.request(db, subject: subject)
        let admitted = try await db.admitMemoryLocalCorrection(request, text: f.command)
        let authority = try await f.authority(), prepared = try await f.preparePublication(db, request: request)
        let verifier = MemoryEvidenceVerifier(messages: db, teammates: db, contexts: db)
        let admission = MemoryClaimAdmissionService(memory: db, intents: db, contexts: db, verifier: verifier,
            authority: authority, clock: { f.now })
        _ = try await admission.publish(operationID: request.operationID, artifact: prepared.artifact,
            title: prepared.intent.document.title, expectedPredecessor: nil,
            actor: .user(messageID: request.userMessageID), context: request.authority)
        _ = try await db.failMemoryLocalCorrection(userMessageID: request.userMessageID,
            expectedRevision: admitted.revision, failure: .publicationFailed, now: f.now)
        let newerID = MessageID(UUID())
        try await db.append(Message(id: newerID, conversationID: subject.chat, sequence: 2, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                content: .text("A separate new local message."))], createdAt: f.now, updatedAt: f.now), expectedPreviousSequence: 1)
        let report = await MemoryLocalOperationRecoveryService(repository: db, corrections: f.service(db, authority: authority)).recover()
        #expect(report.status == .completed && report.needsAttention && report.recoveredCount == 0)
        #expect(report.entries.first?.state == .committedUnacknowledged)
        #expect(report.notice?.contains("is saved") == true)
        #expect(try await db.memoryPublication(id: request.operationID)?.state == .committed)
        let messages = try await db.page(conversationID: subject.chat, request: PageRequest(limit: 10))
        #expect(messages.elements.map(\.id) == [request.userMessageID, newerID])
        #expect(try await db.runs(conversationID: subject.chat, limit: 10).isEmpty)
    }

    @Test("Revoked bot scope is retained as failed without publishing or acknowledging")
    func revokedScope() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), subject = RecoverySubject()
        try await f.seed(db, subject: subject)
        let request = try await f.request(db, subject: subject)
        _ = try await db.admitMemoryLocalCorrection(request, text: f.command)
        _ = try await db.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;", bindings: [.text(subject.bot.persistedValue)])
        let authority = try await f.authority()
        let report = await MemoryLocalOperationRecoveryService(repository: db, corrections: f.service(db, authority: authority)).recover()
        #expect(report.needsAttention && report.recoveredCount == 0)
        #expect(report.entries.first?.state == .failed)
        #expect(try await db.memoryPublication(id: request.operationID) == nil)
        #expect(try await db.allDocuments().isEmpty)
        #expect(try await db.message(id: request.acknowledgementMessageID) == nil)
    }

    @Test("A disappeared marker cannot be re-admitted, and corrupt enumeration cannot become an empty success")
    func missingAndCorruptMarkers() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), subject = RecoverySubject()
        try await f.seed(db, subject: subject)
        let request = try await f.request(db, subject: subject)
        _ = try await db.admitMemoryLocalCorrection(request, text: f.command)
        let disappearing = DisappearingRecoveryRepository(base: db)
        let authority = try await f.authority()
        let report = await MemoryLocalOperationRecoveryService(repository: disappearing,
            corrections: f.service(db, authority: authority, corrections: disappearing)).recover()
        #expect(report.needsAttention && report.entries.first?.state == nil)
        #expect(await disappearing.admissions == 0)
        #expect(try await db.allDocuments().isEmpty)
        _ = try await db.execute(sql: "UPDATE memory_local_corrections SET request_json='{}' WHERE user_message_id=?;",
            bindings: [.text(request.userMessageID.persistedValue)])
        let corrupt = await MemoryLocalOperationRecoveryService(repository: db, corrections: f.service(db, authority: authority)).recover()
        #expect(corrupt.status == .unavailable && corrupt.needsAttention && corrupt.entries.isEmpty)
        #expect(try await db.message(id: request.acknowledgementMessageID) == nil)
    }

    @Test("An interrupted startup pass does not attempt its saved commands")
    func cancelledPass() async throws {
        let f = try RecoveryFixture(); defer { f.remove() }
        let db = try f.open(), subject = RecoverySubject()
        try await f.seed(db, subject: subject)
        let request = try await f.request(db, subject: subject)
        let before = try await db.admitMemoryLocalCorrection(request, text: f.command)
        let authority = try await f.authority()
        let recovery = MemoryLocalOperationRecoveryService(repository: db, corrections: f.service(db, authority: authority))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await recovery.recover()
        }
        let report = await task.value
        #expect(report.status == .cancelled && report.needsAttention && report.entries.isEmpty)
        #expect(try await db.memoryLocalCorrection(userMessageID: request.userMessageID) == before)
        #expect(try await db.allDocuments().isEmpty)
    }
}

private struct RecoverySubject: Sendable {
    let bot = TeammateID(UUID()), chat = ConversationID(UUID())
}

private struct RecoveryLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        .init(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
              fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-recovery-volume")
    }
}

private struct RecoveryFixture: Sendable {
    let root: URL, layout: PreviewStorageLayout, plan: PreviewRootCreationPlan, protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000.25)
    var now: Date { date.addingTimeInterval(60) }
    let command = "Remember that this synthetic bot prefers quiet libraries."

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextMemoryRecovery-\(UUID()).noindex", isDirectory: true)
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
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let roots = try await StorageBootstrapService(layout: layout, locationAdmission: RecoveryLocation()).bootstrap(using: plan)
        let support = try #require(roots.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: support)
    }
    func seed(_ db: SQLiteStore, subject: RecoverySubject) async throws {
        let teammate = try Teammate(id: subject.bot, profile: TeammateProfile(displayName: "Recovery Fixture", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await db.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: subject.chat, kind: .direct(teammateID: subject.bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }
    func request(_ db: SQLiteStore, subject: RecoverySubject, at timestamp: Date? = nil) async throws -> MemoryLocalCorrectionRequest {
        let selection = try await db.loadContext(conversationID: subject.chat)
        let snapshot = try await db.loadReadContextCandidates(ReadContextRequest(conversationID: subject.chat, teammateID: subject.bot,
            profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        return try MemoryLocalCorrectionRequest(operationID: UUID(), userMessageID: MessageID(UUID()), userPartID: MessagePartID(UUID()),
            acknowledgementMessageID: MessageID(UUID()), acknowledgementPartID: MessagePartID(UUID()),
            documentID: MemoryDocumentID(UUID()), claimID: MemoryClaimID(UUID()),
            authority: snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: []), expectedPreviousSequence: 0,
            commandDigest: MemoryClaimDigests.bytes(Data(command.utf8)), inventoryComplete: true,
            captureNewClaim: true, createdAt: timestamp ?? date)
    }
    func service(_ db: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot,
                 corrections: (any MemoryLocalCorrectionRepository)? = nil) -> MemoryLocalCorrectionService {
        MemoryLocalCorrectionService(corrections: corrections ?? db, memory: db, intents: db, contexts: db,
            conversationContexts: db, teammates: db, messages: db, authority: authority, clock: { self.now })
    }
    func preparePublication(_ db: SQLiteStore, request: MemoryLocalCorrectionRequest)
        async throws -> (intent: MemoryPublicationIntent, artifact: MemoryClaimArtifact, bytes: Data) {
        let verifier = MemoryEvidenceVerifier(messages: db, teammates: db, contexts: db)
        let scope = MemoryScope.teammate(request.authority.teammateID)
        let claim = try await verifier.userProposal(messageID: request.userMessageID, claimID: request.claimID,
            scope: scope, authority: request.authority, at: now)
        let artifact = MemoryClaimArtifact(documentID: request.documentID, revision: 1, scope: scope, claims: [claim])
        let bytes = try MemoryClaimCodec().encode(artifact)
        let document = try MemoryDocument(id: request.documentID, scope: scope, author: .user, title: "Remembered notes",
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: request.documentID, scope: scope, revision: 1),
            revision: 1, contentDigest: MemoryClaimDigests.bytes(bytes), createdAt: now, updatedAt: now)
        let evidence = try await verifier.verify(artifact: artifact, predecessor: nil,
            actor: .user(messageID: request.userMessageID), authority: request.authority, at: now)
        let intent = try MemoryPublicationIntent(id: request.operationID, document: document, expectedPredecessor: nil,
            authority: request.authority, actor: .user(messageID: request.userMessageID), evidenceDigest: evidence.digest(),
            policyDigest: MemoryClaimAdmissionService.policyDigest, byteCount: bytes.count,
            userMessageEvidence: evidence.userMessages, createdAt: now)
        return (intent, artifact, bytes)
    }
}

/// Simulates a marker disappearing after enumeration, without deleting user data
/// or allowing an unrelated service/fallback to recreate the command.
private actor DisappearingRecoveryRepository: MemoryLocalCorrectionRepository {
    let base: SQLiteStore
    private(set) var admissions = 0
    init(base: SQLiteStore) { self.base = base }
    func recoverableMemoryLocalCorrections(limit: Int) async throws -> MemoryLocalCorrectionRecoveryPage {
        try await base.recoverableMemoryLocalCorrections(limit: limit)
    }
    func memoryLocalCorrection(userMessageID: MessageID) async throws -> MemoryLocalCorrectionRecord? { nil }
    func admitMemoryLocalCorrection(_ request: MemoryLocalCorrectionRequest, text: String) async throws -> MemoryLocalCorrectionRecord {
        admissions += 1
        throw MemoryLocalCorrectionError.invalidState
    }
    func acknowledgeMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64, now: Date) async throws -> MemoryLocalCorrectionRecord {
        throw MemoryLocalCorrectionError.invalidState
    }
    func failMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                   failure: MemoryLocalCorrectionFailure, now: Date) async throws -> MemoryLocalCorrectionRecord {
        throw MemoryLocalCorrectionError.invalidState
    }
}
