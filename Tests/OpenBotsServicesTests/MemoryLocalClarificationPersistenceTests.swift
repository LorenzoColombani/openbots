import Foundation
import OpenBotsContent
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Durable local correction clarification")
struct MemoryLocalClarificationPersistenceTests {
    @Test("An exact clarification is atomic, survives reopen and never becomes a memory acknowledgement")
    func durableQuestionAndRetry() async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db)
        let record = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
            expectedRevision: original.revision, kind: .targetRequired, now: f.now)
        #expect(record.state == .failed && record.failure == .contextUnavailable && record.acknowledgement == nil)
        #expect(record.revision == original.revision + 1)
        let question = try #require(record.clarification)
        #expect(question.id == original.request.acknowledgementMessageID && question.author == .system)
        #expect(question.deliveryState == .completed)
        #expect(question.parts.first?.id == original.request.acknowledgementPartID)
        #expect(question.parts.first?.content == .text(MemoryLocalCorrectionClarificationKind.targetRequired.text))
        #expect(try await db.memoryPublication(id: original.request.operationID) == nil)
        #expect(try await db.allDocuments().isEmpty)
        let reopened = try f.open()
        #expect(try await reopened.memoryLocalCorrection(userMessageID: original.request.userMessageID) == record)
        let retried = try await reopened.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
            expectedRevision: original.revision, kind: .targetRequired, now: f.now.addingTimeInterval(100))
        #expect(retried == record)
        let page = try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10))
        #expect(page.elements.map(\.id) == [original.request.userMessageID, question.id])
        #expect(try await reopened.recoverableMemoryLocalCorrections(limit: 16).markers.isEmpty)
    }

    @Test("A real ambiguous correction delivers the fixed local question and retains a failed memory operation")
    func actualLocalQuestion() async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let authority = try await f.authority(), service = f.service(db, authority: authority)
        let id = MessageID(UUID())
        let submission = ClaudeTextTurnSubmission(conversationID: f.chat, teammateID: f.bot,
            userMessageID: id, text: f.command)
        let progress = ClarificationProgress()
        let result = await service.sendText(submission) { await progress.append($0) }
        // Completed describes delivery of this local question, not a memory edit.
        #expect(result.outcome == .completed)
        let question = try #require(result.savedReplyMessage)
        #expect(question.author == .system)
        #expect(question.parts.first?.content == .text(MemoryLocalCorrectionClarificationKind.targetRequired.text))
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: id))
        #expect(record.clarification == question && record.acknowledgement == nil)
        #expect(record.state == .failed && record.failure == .contextUnavailable)
        #expect(await progress.values.contains(.assistantMessageSaved(question)))
        #expect(try await db.memoryPublication(id: record.request.operationID) == nil)
        #expect(try await db.allDocuments().isEmpty)
        #expect(try await db.runs(conversationID: f.chat, limit: 10).isEmpty)
        let reopened = try f.open()
        let retry = await f.service(reopened, authority: authority).sendText(submission) { _ in }
        #expect(retry == result)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 2)
    }

    @Test("Recovery can deliver a clarification without counting it as a recovered memory update")
    func recoveryQuestionStillNeedsAttention() async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db)
        let authority = try await f.authority()
        let report = await MemoryLocalOperationRecoveryService(repository: db,
            corrections: f.service(db, authority: authority)).recover()
        #expect(report.status == .completed && report.needsAttention && report.recoveredCount == 0)
        #expect(report.entries.first?.state == .failed && report.entries.first?.failure == .contextUnavailable)
        let record = try #require(try await db.memoryLocalCorrection(userMessageID: original.request.userMessageID))
        #expect(record.clarification != nil && record.acknowledgement == nil)
        #expect(try await db.memoryPublication(id: original.request.operationID) == nil)
    }

    @Test("No intent state can be relabeled as nothing changed", arguments: ClarificationIntentState.allCases)
    func existingIntentDenied(_ state: ClarificationIntentState) async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db, text: f.captureCommand)
        let authority = try await f.authority()
        let intent = try await f.intent(db, record: original)
        let prepared = try await db.prepareMemoryPublication(intent)
        switch state {
        case .pending: break
        case .aborted:
            _ = try await db.abortMemoryPublication(id: intent.id, expectedRevision: prepared.revision, now: f.now)
        case .committed:
            let verifier = MemoryEvidenceVerifier(messages: db, teammates: db, contexts: db)
            let claim = try await verifier.userProposal(messageID: original.request.userMessageID,
                claimID: original.request.claimID, scope: intent.document.scope,
                authority: original.request.authority, at: f.now)
            let artifact = MemoryClaimArtifact(documentID: intent.document.id, revision: 1,
                scope: intent.document.scope, claims: [claim])
            let admission = MemoryClaimAdmissionService(memory: db, intents: db, contexts: db, verifier: verifier,
                authority: authority, clock: { f.now })
            _ = try await admission.publish(operationID: intent.id, artifact: artifact, title: intent.document.title,
                expectedPredecessor: nil, actor: .user(messageID: original.request.userMessageID), context: original.request.authority)
        }
        await #expect(throws: MemoryLocalCorrectionError.invalidState) {
            _ = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
                expectedRevision: original.revision, kind: .targetRequired, now: f.now)
        }
        let after = try #require(try await db.memoryLocalCorrection(userMessageID: original.request.userMessageID))
        #expect(after == original && after.clarification == nil)
        #expect(try await db.message(id: original.request.acknowledgementMessageID) == nil)
        #expect(try await db.memoryPublication(id: intent.id)?.state.rawValue == state.rawValue)
    }

    @Test("Scope or sequence changes prevent a stale clarification", arguments: ClarificationAuthorityChange.allCases)
    func changedAuthorityDenied(_ change: ClarificationAuthorityChange) async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db)
        switch change {
        case .scope:
            _ = try await db.execute(sql: "UPDATE teammates SET lifecycle='archived' WHERE id=?;", bindings: [.text(f.bot.persistedValue)])
        case .sequence:
            try await db.append(Message(id: MessageID(UUID()), conversationID: f.chat, sequence: 2, author: .user,
                deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                    content: .text("A separate newer command."))], createdAt: f.now, updatedAt: f.now), expectedPreviousSequence: 1)
        }
        do {
            _ = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
                expectedRevision: original.revision, kind: .targetRequired, now: f.now)
            Issue.record("Stale authority produced a clarification")
        } catch {}
        #expect(try await db.memoryLocalCorrection(userMessageID: original.request.userMessageID) == original)
        #expect(try await db.message(id: original.request.acknowledgementMessageID) == nil)
    }

    @Test("Failure after question insertion rolls back the question and terminal marker together")
    func insertionFailureIsAtomic() async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db)
        _ = try await db.execute(sql: """
            CREATE TRIGGER reject_clarification BEFORE INSERT ON memory_local_correction_clarifications
            BEGIN SELECT RAISE(ABORT, 'synthetic clarification failure'); END;
            """)
        do {
            _ = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
                expectedRevision: original.revision, kind: .targetRequired, now: f.now)
            Issue.record("Injected write failure unexpectedly succeeded")
        } catch {}
        #expect(try await db.memoryLocalCorrection(userMessageID: original.request.userMessageID) == original)
        #expect(try await db.message(id: original.request.acknowledgementMessageID) == nil)
        #expect(try await db.query(sql: "SELECT user_message_id FROM memory_local_correction_clarifications;").isEmpty)
    }

    @Test("Modified clarification bytes fail exact readback and cannot be retried as a valid question")
    func alteredQuestionRefused() async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db)
        _ = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
            expectedRevision: original.revision, kind: .targetRequired, now: f.now)
        _ = try await db.execute(sql: "UPDATE message_parts SET text_value='The memory was changed.' WHERE id=?;",
            bindings: [.text(original.request.acknowledgementPartID.persistedValue)])
        await #expect(throws: MemoryLocalCorrectionError.invalidState) {
            _ = try await db.memoryLocalCorrection(userMessageID: original.request.userMessageID)
        }
        await #expect(throws: MemoryLocalCorrectionError.invalidState) {
            _ = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
                expectedRevision: original.revision, kind: .targetRequired, now: f.now)
        }
    }

    @Test("Cancellation creates no question and does not alter the admitted operation")
    func cancellationBeforeClarification() async throws {
        let f = try ClarificationFixture(); defer { f.remove() }
        let db = try f.open(); try await f.seed(db)
        let original = try await f.admit(db)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await db.clarifyMemoryLocalCorrection(userMessageID: original.request.userMessageID,
                    expectedRevision: original.revision, kind: .targetRequired, now: f.now)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
        #expect(try await db.memoryLocalCorrection(userMessageID: original.request.userMessageID) == original)
        #expect(try await db.message(id: original.request.acknowledgementMessageID) == nil)
    }
}

enum ClarificationIntentState: String, CaseIterable { case pending, aborted, committed }
enum ClarificationAuthorityChange: CaseIterable { case scope, sequence }

private actor ClarificationProgress {
    private(set) var values: [ClaudeTextTurnProgress] = []
    func append(_ progress: ClaudeTextTurnProgress) { values.append(progress) }
}

private struct ClarificationLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        .init(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
              fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-clarification-volume")
    }
}

private struct ClarificationFixture: Sendable {
    let root: URL, layout: PreviewStorageLayout, plan: PreviewRootCreationPlan, protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000.25)
    var now: Date { date.addingTimeInterval(30) }
    let bot = TeammateID(UUID()), chat = ConversationID(UUID())
    let command = "Correct from first-hand knowledge to: Synthetic changed preference."
    let captureCommand = "Remember that this synthetic bot prefers quiet libraries."
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextClarification-\(UUID()).noindex", isDirectory: true)
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
        let roots = try await StorageBootstrapService(layout: layout, locationAdmission: ClarificationLocation()).bootstrap(using: plan)
        let support = try #require(roots.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: support)
    }
    func seed(_ db: SQLiteStore) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Clarification Fixture", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await db.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }
    func admit(_ db: SQLiteStore, text: String? = nil) async throws -> MemoryLocalCorrectionRecord {
        let text = text ?? command
        let selection = try await db.loadContext(conversationID: chat)
        let snapshot = try await db.loadReadContextCandidates(ReadContextRequest(conversationID: chat, teammateID: bot,
            profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        let request = try MemoryLocalCorrectionRequest(operationID: UUID(), userMessageID: MessageID(UUID()), userPartID: MessagePartID(UUID()),
            acknowledgementMessageID: MessageID(UUID()), acknowledgementPartID: MessagePartID(UUID()),
            documentID: MemoryDocumentID(UUID()), claimID: MemoryClaimID(UUID()),
            authority: snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: []), expectedPreviousSequence: 0,
            commandDigest: MemoryClaimDigests.bytes(Data(text.utf8)), inventoryComplete: true,
            captureNewClaim: text == captureCommand, createdAt: date)
        return try await db.admitMemoryLocalCorrection(request, text: text)
    }
    func service(_ db: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot) -> MemoryLocalCorrectionService {
        MemoryLocalCorrectionService(corrections: db, memory: db, intents: db, contexts: db,
            conversationContexts: db, teammates: db, messages: db, authority: authority, clock: { self.now })
    }
    func intent(_ db: SQLiteStore, record: MemoryLocalCorrectionRecord) async throws -> MemoryPublicationIntent {
        let request = record.request, scope = MemoryScope.teammate(bot)
        let verifier = MemoryEvidenceVerifier(messages: db, teammates: db, contexts: db)
        let claim = try await verifier.userProposal(messageID: request.userMessageID, claimID: request.claimID,
            scope: scope, authority: request.authority, at: now)
        let artifact = MemoryClaimArtifact(documentID: request.documentID, revision: 1, scope: scope, claims: [claim])
        let bytes = try MemoryClaimCodec().encode(artifact)
        let document = try MemoryDocument(id: request.documentID, scope: scope, author: .user, title: "Remembered notes",
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: request.documentID, scope: scope, revision: 1),
            revision: 1, contentDigest: MemoryClaimDigests.bytes(bytes), createdAt: now, updatedAt: now)
        let evidence = try await verifier.verify(artifact: artifact, predecessor: nil,
            actor: .user(messageID: request.userMessageID), authority: request.authority, at: now)
        return try MemoryPublicationIntent(id: request.operationID, document: document, expectedPredecessor: nil,
            authority: request.authority, actor: .user(messageID: request.userMessageID), evidenceDigest: evidence.digest(),
            policyDigest: MemoryClaimAdmissionService.policyDigest, byteCount: bytes.count,
            userMessageEvidence: evidence.userMessages, createdAt: now)
    }
}
