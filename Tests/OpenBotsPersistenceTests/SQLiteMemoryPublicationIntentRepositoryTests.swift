import CryptoKit
import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Durable certainty publication intents")
struct SQLiteMemoryPublicationIntentRepositoryTests {
    @Test("Preparation survives reopen without catalog publication or body persistence; retry binds exact operation")
    func prepareAndReopen() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        let prepared = try await store.prepareMemoryPublication(intent)
        #expect(prepared.state == .pending && prepared.revision == 1)
        #expect(try await store.document(id: intent.document.id) == nil)
        let reopened = try f.open()
        #expect(try await reopened.memoryPublication(id: intent.id) == prepared)
        #expect(try await reopened.prepareMemoryPublication(intent) == prepared)
        #expect(try await reopened.pendingMemoryPublications(limit: 1) == [prepared])
        let rows = try await reopened.query(sql: "SELECT intent_json,staging_relative_path FROM memory_publication_intents WHERE id=?;",
            bindings: [.text(intent.id.uuidString.lowercased())])
        let row = try #require(rows.first)
        let json = try row.text("intent_json")
        #expect(!json.contains(PublicationFixture.userText) && !json.contains(f.directory.path))
        #expect(try row.text("staging_relative_path") == intent.stagingRelativePath)
        #expect(intent.stagingRelativePath.hasSuffix("/.openbots-stage-\(intent.id.uuidString.lowercased()).tmp"))
        let conflict = try await f.intent(store, operationID: intent.id)
        await expectPublicationError(.conflictingOperation) { _ = try await reopened.prepareMemoryPublication(conflict) }
    }

    @Test("Atomic commit is idempotent across reopen and later successors")
    func commitAndSuccessor() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let first = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(first)
        let committed = try await f.commit(store, first)
        #expect(committed.state == .committed && committed.revision == 2)
        #expect(try await store.document(id: first.document.id) == first.document)
        #expect(try await store.pendingMemoryPublications(limit: 100).isEmpty)
        let second = try await f.intent(store, predecessor: first.document)
        _ = try await store.prepareMemoryPublication(second)
        _ = try await f.commit(store, second)
        let reopened = try f.open()
        #expect(try await f.commit(reopened, first) == committed)
        #expect(try await reopened.memoryPublicationBlocksUse(documentID: first.document.id))
        #expect(try await !reopened.memoryPublicationBlocksUse(documentID: second.document.id))
    }

    @Test("A failure after catalog INSERT rolls back the catalog and preserves pending intent")
    func transactionRollback() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(intent)
        _ = try await store.execute(sql: """
            CREATE TRIGGER publication_test_failure BEFORE UPDATE OF state ON memory_publication_intents
            WHEN NEW.state='committed' BEGIN SELECT RAISE(ABORT,'fixture'); END;
            """)
        do { _ = try await f.commit(store, intent); Issue.record("Expected injected transaction failure") }
        catch { }
        #expect(try await store.document(id: intent.document.id) == nil)
        #expect(try await store.memoryPublication(id: intent.id)?.state == .pending)
        _ = try await store.execute(sql: "DROP TRIGGER publication_test_failure;")
        #expect(try await f.commit(store, intent).state == .committed)
    }

    @Test("Current predecessor bytes and competing publication are rechecked")
    func staleAndConcurrentPredecessor() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let first = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(first); _ = try await f.commit(store, first)
        let second = try await f.intent(store, predecessor: first.document, includePredecessor: false)
        _ = try await store.prepareMemoryPublication(second)
        let rival = try await f.intent(store, predecessor: first.document, includePredecessor: false)
        await expectPublicationError(.conflictingOperation) { _ = try await store.prepareMemoryPublication(rival) }
        _ = try await store.execute(sql: "UPDATE memory_documents SET content_digest=? WHERE id=?;",
            bindings: [.text(String(repeating: "b", count: 64)), .text(first.document.id.persistedValue)])
        await expectPublicationError(.stalePredecessor) { _ = try await f.commit(store, second) }
        #expect(try await store.document(id: second.document.id) == nil)
    }

    @Test("Pending operation blocks normal read receipts but its exact commit can validate predecessor")
    func ownPendingExemption() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let first = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(first); _ = try await f.commit(store, first)
        let next = try await f.intent(store, predecessor: first.document)
        #expect(next.authority.memoryDocuments.map(\.documentID) == [first.document.id])
        _ = try await store.prepareMemoryPublication(next)
        #expect(try await store.memoryPublicationBlocksUse(documentID: first.document.id))
        do { try await store.revalidateReadContext(next.authority); Issue.record("Pending correction was readable") }
        catch { }
        #expect(try await store.prepareMemoryPublication(next).state == .pending)
        #expect(try await f.commit(store, next).state == .committed)
    }

    @Test("Project membership revocation invalidates pending admission and recovery retries")
    func revokedAuthority() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let selection = try await store.loadContext(conversationID: f.chat)
        _ = try await store.saveContext(ConversationContextSelection(conversationID: f.chat, teammateID: f.bot,
            projectID: f.project, revision: selection.revision))
        let intent = try await f.intent(store, project: true)
        _ = try await store.prepareMemoryPublication(intent)
        try await store.setMembership(ProjectMembership(projectID: f.project, teammateID: f.bot,
            joinedAt: f.date, revokedAt: f.date.addingTimeInterval(1)))
        await expectPublicationError(.authorityChanged) { _ = try await f.commit(store, intent) }
        await expectPublicationError(.authorityChanged) { _ = try await store.prepareMemoryPublication(intent) }
        #expect(try await store.document(id: intent.document.id) == nil)
    }

    @Test("User correction evidence is exact durable user text; no provider success is required",
          arguments: PublicationEvidenceMutation.allCases)
    func exactUserEvidence(_ mutation: PublicationEvidenceMutation) async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(intent)
        switch mutation {
        case .none: break
        case .body:
            _ = try await store.execute(sql: "UPDATE message_parts SET text_value='Different user statement' WHERE message_id=?;",
                bindings: [.text(f.message.persistedValue)])
        case .author:
            _ = try await store.execute(sql: "UPDATE messages SET author_kind='system' WHERE id=?;",
                bindings: [.text(f.message.persistedValue)])
        case .stamp:
            _ = try await store.execute(sql: "UPDATE messages SET updated_at=updated_at+1 WHERE id=?;",
                bindings: [.text(f.message.persistedValue)])
        case .extraPart:
            _ = try await store.execute(sql: "INSERT INTO message_parts(id,message_id,ordinal,kind,text_value) VALUES (?,?,1,'text','Extra');",
                bindings: [.text(MessagePartID(UUID()).persistedValue), .text(f.message.persistedValue)])
        }
        if mutation == .none {
            #expect(try await f.commit(store, intent).state == .committed)
            let runs = try await store.query(sql: "SELECT id FROM work_runs LIMIT 1;")
            #expect(runs.isEmpty)
        } else {
            await expectPublicationError(.invalidEvidence) { _ = try await f.commit(store, intent) }
            #expect(try await store.document(id: intent.document.id) == nil)
        }
    }

    @Test("Fresh verification cannot substitute content, evidence, policy, bytes or authority")
    func frozenValidation() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(intent)
        let digest = String(repeating: "f", count: 64)
        let valid = f.validation(intent)
        let forged = [
            MemoryPublicationValidation(authority: valid.authority, evidenceDigest: digest,
                policyDigest: valid.policyDigest, contentDigest: valid.contentDigest, byteCount: valid.byteCount),
            MemoryPublicationValidation(authority: valid.authority, evidenceDigest: valid.evidenceDigest,
                policyDigest: digest, contentDigest: valid.contentDigest, byteCount: valid.byteCount),
            MemoryPublicationValidation(authority: valid.authority, evidenceDigest: valid.evidenceDigest,
                policyDigest: valid.policyDigest, contentDigest: digest, byteCount: valid.byteCount),
            MemoryPublicationValidation(authority: valid.authority, evidenceDigest: valid.evidenceDigest,
                policyDigest: valid.policyDigest, contentDigest: valid.contentDigest, byteCount: valid.byteCount + 1)
        ]
        for value in forged {
            await expectPublicationError(.invalidEvidence) {
                _ = try await store.commitMemoryPublication(id: intent.id, expectedRevision: 1, validation: value, now: f.date)
            }
        }
        #expect(try await f.commit(store, intent).state == .committed)
    }

    @Test("Cancel and commit are terminal CAS transitions, never an implicit retry")
    func terminalTransitions() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let cancelled = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(cancelled)
        await expectPublicationError(.invalidTransition) {
            _ = try await store.abortMemoryPublication(id: cancelled.id, expectedRevision: 2, now: f.date)
        }
        let aborted = try await store.abortMemoryPublication(id: cancelled.id, expectedRevision: 1, now: f.date)
        #expect(aborted.state == .aborted)
        #expect(try await store.abortMemoryPublication(id: cancelled.id, expectedRevision: 1, now: f.date) == aborted)
        await expectPublicationError(.invalidTransition) { _ = try await f.commit(store, cancelled) }
        #expect(try await store.prepareMemoryPublication(cancelled).state == .aborted)
        let completed = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(completed); _ = try await f.commit(store, completed)
        await expectPublicationError(.invalidTransition) {
            _ = try await store.abortMemoryPublication(id: completed.id, expectedRevision: 2, now: f.date)
        }
    }

    @Test("An aborted correction fences its old head until an explicit fresh replacement commits")
    func abortedCorrectionDoesNotResurrect() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let first = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(first); _ = try await f.commit(store, first)
        let failed = try await f.intent(store, predecessor: first.document)
        _ = try await store.prepareMemoryPublication(failed)
        _ = try await store.abortMemoryPublication(id: failed.id, expectedRevision: 1, now: failed.createdAt)
        #expect(try await store.memoryPublicationBlocksUse(documentID: first.document.id))
        await expectPublicationError(.invalidTransition) { _ = try await f.commit(store, failed) }
        // The explicit correction binds its exact predecessor; it does not need
        // to include the fenced content as permissive conversation context.
        let replacement = try await f.intent(store, predecessor: first.document, includePredecessor: false)
        _ = try await store.prepareMemoryPublication(replacement)
        _ = try await f.commit(store, replacement)
        #expect(try await !store.memoryPublicationBlocksUse(documentID: replacement.document.id))
        #expect(try await store.memoryPublicationBlocksUse(documentID: first.document.id))
        #expect(try await store.memoryPublication(id: failed.id)?.state == .aborted)
        #expect(try await store.document(id: failed.document.id) == nil)
    }

    @Test("A newer durable message revokes an older command's publication authority")
    func oldCommandCannotReplay() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(intent)
        let newer = try Message(id: MessageID(UUID()), conversationID: f.chat, sequence: 2, author: .user,
            deliveryState: .pending, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                content: .text("Do not use that earlier instruction."))], createdAt: f.date, updatedAt: f.date)
        try await store.append(newer, expectedPreviousSequence: 1)
        await expectPublicationError(.invalidEvidence) { _ = try await f.commit(store, intent) }
        await expectPublicationError(.invalidEvidence) { _ = try await store.prepareMemoryPublication(intent) }
        #expect(try await store.document(id: intent.document.id) == nil)
    }

    @Test("Withdrawal tombstones survive reopen and cannot be dropped; unrelated current claims remain eligible")
    func withdrawalCarryForward() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let withdrawnID = UUID()
        let first = try await f.intent(store, withdrawn: [withdrawnID])
        _ = try await store.prepareMemoryPublication(first); _ = try await f.commit(store, first)
        #expect(try await !store.memoryPublicationBlocksUse(documentID: first.document.id))
        #expect(try await store.withdrawnMemoryClaimIDs(documentID: first.document.id) == [withdrawnID])
        let unsafe = try await f.intent(store, predecessor: first.document)
        await expectPublicationError(.withdrawnClaim) { _ = try await store.prepareMemoryPublication(unsafe) }
        let next = try await f.intent(store, predecessor: first.document, withdrawn: [withdrawnID])
        _ = try await store.prepareMemoryPublication(next)
        #expect(try await store.memoryPublicationBlocksUse(documentID: first.document.id))
        _ = try await f.commit(store, next)
        let reopened = try f.open()
        #expect(try await !reopened.memoryPublicationBlocksUse(documentID: next.document.id))
        #expect(try await reopened.withdrawnMemoryClaimIDs(documentID: next.document.id) == [withdrawnID])
        // No artifact reads occur: a missing/corrupt current file cannot erase its tombstones.
        #expect(try await reopened.memoryPublicationBlocksUse(documentID: first.document.id))
        let bypass = try f.document(predecessor: next.document)
        try await reopened.insert(bypass)
        await expectPublicationError(.invalidStoredState) { _ = try await reopened.memoryPublicationBlocksUse(documentID: bypass.id) }
    }

    @Test("Corrupt metadata and unbounded enumeration fail closed")
    func corruptAndBounded() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(intent)
        for limit in [0, 101, Int.max] {
            await expectPublicationError(.invalidLimit) { _ = try await store.pendingMemoryPublications(limit: limit) }
        }
        _ = try await store.execute(sql: "UPDATE memory_publication_intents SET intent_json='{}' WHERE id=?;",
            bindings: [.text(intent.id.uuidString.lowercased())])
        await expectPublicationError(.invalidStoredState) { _ = try await store.memoryPublication(id: intent.id) }
        await expectPublicationError(.invalidStoredState) { _ = try await store.pendingMemoryPublications(limit: 1) }
        #expect(try await store.document(id: intent.document.id) == nil)
    }

    @Test("A committed receipt cannot claim success after its catalog stamp changes")
    func corruptCommittedReceipt() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let intent = try await f.intent(store)
        _ = try await store.prepareMemoryPublication(intent); _ = try await f.commit(store, intent)
        _ = try await store.execute(sql: "UPDATE memory_documents SET title='Changed metadata' WHERE id=?;",
            bindings: [.text(intent.document.id.persistedValue)])
        await expectPublicationError(.invalidStoredState) { _ = try await store.memoryPublication(id: intent.id) }
        await expectPublicationError(.invalidStoredState) { _ = try await store.prepareMemoryPublication(intent) }
        await expectPublicationError(.invalidStoredState) { _ = try await f.commit(store, intent) }
    }

    @Test("Legacy metadata chains have a finite admission bound, never an unbounded fallback walk")
    func boundedLegacyChain() async throws {
        let f = try PublicationFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        var head = try f.document()
        try await store.insert(head)
        for _ in 1..<256 {
            head = try f.document(predecessor: head)
            try await store.insert(head)
        }
        #expect(try await !store.memoryPublicationBlocksUse(documentID: head.id))
        let overBound = try f.document(predecessor: head)
        try await store.insert(overBound)
        await expectPublicationError(.invalidStoredState) {
            _ = try await store.memoryPublicationBlocksUse(documentID: overBound.id)
        }
        #expect(try await store.document(id: overBound.id) == overBound)
    }
}

enum PublicationEvidenceMutation: CaseIterable { case none, body, author, stamp, extraPart }

private struct PublicationFixture {
    static let userText = "Please remember the synthetic launch color is cobalt."
    let directory: URL
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), chat = ConversationID(UUID()), project = ProjectID(UUID()), message = MessageID(UUID())
    let protection: ProtectionDecisionReceipt

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextPublication-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Memory Bot", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        try await store.insert(Project(id: project, name: "Selected project", createdAt: date, updatedAt: date))
        try await store.setMembership(ProjectMembership(projectID: project, teammateID: bot, joinedAt: date))
        let user = try Message(id: message, conversationID: chat, sequence: 1, author: .user, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(Self.userText))], createdAt: date, updatedAt: date)
        try await store.append(user, expectedPreviousSequence: 0)
    }
    func document(predecessor: MemoryDocument? = nil, project selected: Bool = false) throws -> MemoryDocument {
        let id = MemoryDocumentID(UUID()), revision = (predecessor?.revision ?? 0) + 1
        let scope = selected ? MemoryScope.project(project) : .teammate(bot)
        let folder = selected ? "Projects/\(project.persistedValue)" : "Teammates/\(bot.persistedValue)"
        return try MemoryDocument(id: id, scope: scope, author: .user, title: "Synthetic memory",
            relativePath: "Documents/\(folder)/\(id.persistedValue)-r\(revision).md", revision: revision,
            contentDigest: String(repeating: "a", count: 64), supersedes: predecessor?.id,
            createdAt: predecessor?.createdAt ?? date, updatedAt: date.addingTimeInterval(Double(revision - 1)))
    }
    func intent(_ store: SQLiteStore, operationID: UUID = UUID(), predecessor: MemoryDocument? = nil,
                includePredecessor: Bool = true, project: Bool = false, withdrawn: [UUID] = []) async throws -> MemoryPublicationIntent {
        let document = try document(predecessor: predecessor, project: project)
        let selection = try await store.loadContext(conversationID: chat)
        let snapshot = try await store.loadReadContextCandidates(ReadContextRequest(conversationID: chat,
            teammateID: bot, profileRevision: 1, selection: selection, beforeSequence: Int64.max))
        let receipt = try snapshot.receipt.selecting(messageIDs: [],
            memoryDocumentIDs: includePredecessor ? predecessor.map { [$0.id] } ?? [] : [])
        return try MemoryPublicationIntent(id: operationID, document: document, expectedPredecessor: predecessor,
            authority: receipt, actor: .user(messageID: message), evidenceDigest: String(repeating: "c", count: 64),
            policyDigest: String(repeating: "d", count: 64), byteCount: 200,
            userMessageEvidence: [MemoryPublicationUserMessageEvidence(messageID: message,
                contentDigest: SHA256.hash(data: Data(Self.userText.utf8)).map { String(format: "%02x", $0) }.joined(), updatedAt: date)],
            withdrawnClaimIDs: withdrawn, createdAt: document.updatedAt)
    }
    func validation(_ intent: MemoryPublicationIntent) -> MemoryPublicationValidation {
        MemoryPublicationValidation(authority: intent.authority, evidenceDigest: intent.evidenceDigest,
            policyDigest: intent.policyDigest, contentDigest: intent.document.contentDigest, byteCount: intent.byteCount)
    }
    func commit(_ store: SQLiteStore, _ intent: MemoryPublicationIntent) async throws -> MemoryPublicationIntentRecord {
        try await store.commitMemoryPublication(id: intent.id, expectedRevision: 1,
            validation: validation(intent), now: intent.createdAt)
    }
}

private func expectPublicationError(_ expected: MemoryPublicationError, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected \(expected)") }
    catch let actual as MemoryPublicationError { #expect(actual == expected) }
    catch { Issue.record("Expected \(expected), got \(error)") }
}
