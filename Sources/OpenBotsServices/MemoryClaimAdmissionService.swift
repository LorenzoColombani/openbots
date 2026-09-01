import Foundation
import OpenBotsContent
import OpenBotsDomain

/// Issued by registered application verifiers, never decoded from a provider.
public struct MemoryAdmissionEvidence: Sendable {
    public let verified: [MemoryClaimVerifiedEvidence]
    public let userMessages: [MemoryPublicationUserMessageEvidence]
    public let previousIndependentEvidenceIDs: Set<UUID>

    public init(verified: [MemoryClaimVerifiedEvidence],
                userMessages: [MemoryPublicationUserMessageEvidence] = [],
                previousIndependentEvidenceIDs: Set<UUID> = []) {
        self.verified = verified; self.userMessages = userMessages
        self.previousIndependentEvidenceIDs = previousIndependentEvidenceIDs
    }

    /// Stable source bindings, independent of the time of this fresh check.
    public func digest() throws -> String {
        struct Binding: Encodable {
            struct Verification: Encodable {
                let reference: MemoryClaimEvidenceReference
                let authority: String
                let verifierID: String
                let verifierVersion: UInt16
                let independentID: UUID
            }
            let verifications: [Verification]
            let messages: [MemoryPublicationUserMessageEvidence]
        }
        let binding = Binding(
            verifications: verified.sorted { $0.reference.receiptID.uuidString < $1.reference.receiptID.uuidString }
                .map { .init(reference: $0.reference, authority: $0.authority.rawValue,
                    verifierID: $0.verifierID, verifierVersion: $0.verifierVersion,
                    independentID: $0.independentEvidenceID) },
            messages: userMessages.sorted { $0.messageID.persistedValue < $1.messageID.persistedValue })
        return MemoryClaimDigests.bytes(try MemoryClaimDigests.canonicalData(binding))
    }
}

public protocol MemoryAdmissionEvidenceVerifying: Sendable {
    /// Re-resolve original sources and the actor's actual intent every time.
    /// A matching citation/hash alone cannot establish its relation to a claim.
    func verify(artifact: MemoryClaimArtifact, predecessor: MemoryClaimArtifact?,
                actor: MemoryPublicationActor, authority: ReadContextReceipt,
                at now: Date) async throws -> MemoryAdmissionEvidence
}

public enum MemoryClaimAdmissionError: Error, Equatable, Sendable {
    case invalidArtifact, predecessorUnavailable, retainedClaimRemoved, evidenceChanged, operationAborted
}

/// The only certainty write orchestrator. Acknowledgement is the committed return
/// value; prepared intents and published files are not successful memory edits.
public actor MemoryClaimAdmissionService {
    public static let policyDigest = MemoryClaimDigests.bytes(Data("openbots-memory-admission-v1".utf8))
    private let memory: any MemoryRepository
    private let intents: any MemoryPublicationIntentRepository
    private let contexts: any ReadContextRepository
    private let verifier: any MemoryAdmissionEvidenceVerifying
    private let authority: VerifiedAuthoritativeMarkdownRoot
    private let store: AuthoritativeMarkdownStore
    private let clock: @Sendable () -> Date

    public init(memory: any MemoryRepository, intents: any MemoryPublicationIntentRepository,
                contexts: any ReadContextRepository, verifier: any MemoryAdmissionEvidenceVerifying,
                authority: VerifiedAuthoritativeMarkdownRoot,
                store: AuthoritativeMarkdownStore = AuthoritativeMarkdownStore(maximumBytes: 16_384),
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.memory = memory; self.intents = intents; self.contexts = contexts
        self.verifier = verifier; self.authority = authority; self.store = store
        self.clock = { MemoryPersistenceTimestamp.normalized(clock()) }
    }

    @discardableResult
    public func publish(operationID: UUID, artifact: MemoryClaimArtifact, title: String,
                        expectedPredecessor: MemoryDocument?, actor: MemoryPublicationActor,
                        context: ReadContextReceipt) async throws -> MemoryPublicationIntentRecord {
        try Task.checkCancellation()
        try await revalidateScope(context)
        guard try await memory.authorityContract() == .appOwnedMarkdownV1 else {
            throw MemoryClaimAdmissionError.invalidArtifact
        }
        try artifact.validate()
        guard expectedPredecessor.map({ $0.revision < UInt64.max }) ?? true else {
            throw MemoryClaimAdmissionError.invalidArtifact
        }
        guard artifact.hasKnownSemantics,
              artifact.revision == (expectedPredecessor.map { $0.revision + 1 } ?? 1),
              expectedPredecessor == nil || expectedPredecessor?.scope == artifact.scope else {
            throw MemoryClaimAdmissionError.invalidArtifact
        }
        let bytes = try MemoryClaimCodec().encode(artifact)
        guard let markdown = String(data: bytes, encoding: .utf8) else {
            throw MemoryClaimAdmissionError.invalidArtifact
        }
        let existing = try await intents.memoryPublication(id: operationID)
        if let existing {
            guard existing.intent.document.id == artifact.documentID,
                  existing.intent.document.contentDigest == MemoryClaimDigests.bytes(bytes),
                  existing.intent.document.title == title,
                  existing.intent.expectedPredecessor == expectedPredecessor,
                  existing.intent.actor == actor, existing.intent.authority == context else {
                throw MemoryPublicationError.conflictingOperation
            }
            if existing.state == .committed { return existing }
            guard existing.state == .pending else { throw MemoryClaimAdmissionError.operationAborted }
        }
        let previous = try await predecessorArtifact(expectedPredecessor)
        let evidence = try await verifiedEvidence(artifact, predecessor: previous,
            document: expectedPredecessor, actor: actor, context: context)
        let now = existing?.intent.createdAt ?? clock()
        let author: MemoryAuthor
        switch actor { case .user: author = .user; case .app: author = .system }
        let document = try MemoryDocument(id: artifact.documentID, scope: artifact.scope,
            author: author, title: title,
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: artifact.documentID,
                scope: artifact.scope, revision: artifact.revision),
            revision: artifact.revision, contentDigest: MemoryClaimDigests.bytes(bytes),
            supersedes: expectedPredecessor?.id,
            createdAt: expectedPredecessor?.createdAt ?? now, updatedAt: now)
        let intent = try MemoryPublicationIntent(id: operationID, document: document,
            expectedPredecessor: expectedPredecessor, authority: context, actor: actor,
            evidenceDigest: evidence.digest(), policyDigest: Self.policyDigest, byteCount: bytes.count,
            userMessageEvidence: evidence.userMessages,
            withdrawnClaimIDs: artifact.claims.filter { $0.validity == .withdrawn }.map { $0.id.rawValue },
            createdAt: now)
        let prepared = try await intents.prepareMemoryPublication(intent)
        if prepared.state == .committed { return prepared }
        guard prepared.state == .pending else { throw MemoryClaimAdmissionError.operationAborted }
        do {
            try Task.checkCancellation()
            // Failure leaves an exact durable intent. Recovery may finish only after
            // fresh validation; no in-process delete rollback can race commit.
            let request = try AuthoritativeMarkdownPublicationRequest(documentID: document.id,
                scope: document.scope, revision: document.revision, markdown: markdown,
                authority: authority, operationID: operationID)
            do { _ = try await store.publish(request) }
            catch AuthoritativeMarkdownError.collision {
                _ = try await store.read(AuthoritativeMarkdownReference(document: document), inside: authority)
            }
            return try await finish(prepared, artifact: artifact, predecessor: previous)
        } catch is CancellationError {
            if let settled = try await settleCancellation(operationID), settled.state == .committed { return settled }
            throw CancellationError()
        }
    }

    /// The bounded list contains only exact operation-owned paths. No directory
    /// enumeration, legacy data, export traversal or credential access is possible.
    public func reconcile(limit: Int = 32) async throws -> [MemoryPublicationIntentRecord] {
        let records = try await intents.pendingMemoryPublications(limit: limit)
        return try await reconcile(records: records)
    }

    /// An explicit local-command retry must never enumerate or resume a different
    /// operation. Non-pending results are historical receipts, not new authority.
    public func reconcile(operationID: UUID) async throws -> MemoryPublicationIntentRecord {
        guard let record = try await intents.memoryPublication(id: operationID) else {
            throw MemoryPublicationError.notFound
        }
        if record.state != .pending { return record }
        if let settled = try await reconcile(records: [record]).first { return settled }
        guard let current = try await intents.memoryPublication(id: operationID) else {
            throw MemoryPublicationError.notFound
        }
        return current
    }

    private func reconcile(records: [MemoryPublicationIntentRecord]) async throws -> [MemoryPublicationIntentRecord] {
        var settled: [MemoryPublicationIntentRecord] = []
        for record in records {
            try Task.checkCancellation()
            let intent = record.intent
            do {
                try await revalidateScope(intent.authority)
                guard intent.policyDigest == Self.policyDigest,
                      try await memory.authorityContract() == .appOwnedMarkdownV1 else {
                    throw MemoryClaimAdmissionError.invalidArtifact
                }
                // Recheck the exact actor/head and local command marker before
                // opening recovery bytes, including revoked/cancelled operations.
                let admitted = try await intents.prepareMemoryPublication(intent)
                guard admitted.state == .pending else { continue }
                let reference = try AuthoritativeMarkdownReference(document: intent.document)
                let pending = try await store.readPendingPublication(reference: reference,
                    operationID: intent.id, expectedByteCount: intent.byteCount, inside: authority)
                let artifact = try decode(pending.markdown, document: intent.document)
                try await revalidateScope(intent.authority)
                let previous = try await predecessorArtifact(intent.expectedPredecessor)
                let evidence = try await verifiedEvidence(artifact, predecessor: previous,
                    document: intent.expectedPredecessor, actor: intent.actor, context: intent.authority)
                guard try evidence.digest() == intent.evidenceDigest,
                      evidence.userMessages == intent.userMessageEvidence else {
                    throw MemoryClaimAdmissionError.evidenceChanged
                }
                // Revalidate durable actor/source stamps before the recovery mutation.
                let current = try await intents.prepareMemoryPublication(intent)
                guard current.state == .pending else { continue }
                _ = try await store.recoverPublication(reference: reference, operationID: intent.id,
                    expectedByteCount: intent.byteCount, inside: authority)
                settled.append(try await finish(current, artifact: artifact, predecessor: previous))
            } catch is CancellationError {
                _ = try await settleCancellation(intent.id)
                throw CancellationError()
            }
            catch {
                // An explicit failed operation cannot silently resume. Exact artifacts
                // remain private; there is no cleanup or deletion contract here.
                if let current = try await intents.memoryPublication(id: intent.id), current.state == .pending {
                    settled.append(try await intents.abortMemoryPublication(id: intent.id,
                        expectedRevision: current.revision, now: clock()))
                }
            }
        }
        return settled
    }

    private func finish(_ record: MemoryPublicationIntentRecord, artifact: MemoryClaimArtifact,
                        predecessor: MemoryClaimArtifact?) async throws -> MemoryPublicationIntentRecord {
        try Task.checkCancellation()
        let intent = record.intent
        try await revalidateScope(intent.authority)
        let final = try await store.read(AuthoritativeMarkdownReference(document: intent.document), inside: authority)
        guard final.markdown.utf8.count == intent.byteCount,
              try decode(final.markdown, document: intent.document) == artifact else {
            throw MemoryClaimAdmissionError.invalidArtifact
        }
        let evidence = try await verifiedEvidence(artifact, predecessor: predecessor,
            document: intent.expectedPredecessor, actor: intent.actor, context: intent.authority)
        guard try evidence.digest() == intent.evidenceDigest,
              evidence.userMessages == intent.userMessageEvidence else {
            throw MemoryClaimAdmissionError.evidenceChanged
        }
        let validation = MemoryPublicationValidation(authority: intent.authority,
            evidenceDigest: intent.evidenceDigest, policyDigest: Self.policyDigest,
            contentDigest: intent.document.contentDigest, byteCount: intent.byteCount)
        return try await intents.commitMemoryPublication(id: intent.id,
            expectedRevision: record.revision, validation: validation, now: clock())
    }

    private func settleCancellation(_ id: UUID) async throws -> MemoryPublicationIntentRecord? {
        let intents = intents
        let now = clock()
        return try await Task.detached {
            guard let current = try await intents.memoryPublication(id: id) else { return nil }
            if current.state != .pending { return current }
            do {
                return try await intents.abortMemoryPublication(id: id, expectedRevision: current.revision, now: now)
            } catch {
                if let winner = try await intents.memoryPublication(id: id), winner.state != .pending { return winner }
                throw error
            }
        }.value
    }

    private func predecessorArtifact(_ document: MemoryDocument?) async throws -> MemoryClaimArtifact? {
        guard let document else { return nil }
        guard try await memory.document(id: document.id) == document else {
            throw MemoryClaimAdmissionError.predecessorUnavailable
        }
        let bytes = try await store.read(AuthoritativeMarkdownReference(document: document), inside: authority)
        return try decode(bytes.markdown, document: document)
    }

    private func revalidateScope(_ context: ReadContextReceipt) async throws {
        // The intent repository validates full sources in its transaction with
        // only this operation exempted from its own pending-correction fence.
        try await contexts.revalidateReadContext(context.selecting(messageIDs: [], memoryDocumentIDs: []))
    }

    private func decode(_ markdown: String, document: MemoryDocument) throws -> MemoryClaimArtifact {
        let decoded = MemoryClaimCodec().decode(Data(markdown.utf8))
        guard let artifact = decoded.artifact, artifact.hasKnownSemantics,
              artifact.documentID == document.id, artifact.revision == document.revision,
              artifact.scope == document.scope else { throw MemoryClaimAdmissionError.invalidArtifact }
        return artifact
    }

    private func verifiedEvidence(_ artifact: MemoryClaimArtifact, predecessor: MemoryClaimArtifact?,
                                  document: MemoryDocument?, actor: MemoryPublicationActor,
                                  context: ReadContextReceipt) async throws -> MemoryAdmissionEvidence {
        let evidence = try await verifier.verify(artifact: artifact, predecessor: predecessor,
            actor: actor, authority: context, at: clock())
        let priorByID = Dictionary(uniqueKeysWithValues: (predecessor?.claims ?? []).map { ($0.id, $0) })
        guard Set(priorByID.keys).isSubset(of: Set(artifact.claims.map(\.id))) else {
            throw MemoryClaimAdmissionError.retainedClaimRemoved
        }
        let assessor: MemoryClaimAssessor
        switch actor {
        case .user(let id): assessor = .init(kind: .user, identity: id.persistedValue)
        case .app(let id): assessor = .init(kind: .app, identity: id)
        }
        for claim in artifact.claims {
            var prior = priorByID[claim.id]
            if let prior, try MemoryClaimDigests.canonicalData(prior) == MemoryClaimDigests.canonicalData(claim) { continue }
            if prior == nil, !claim.changes.isEmpty {
                guard claim.changes.count == 1, let change = claim.changes.first,
                      change.kind == .supersession,
                      let replaced = priorByID[change.previous.claimID],
                      replaced.id != claim.id,
                      artifact.claims.contains(where: { $0.id == replaced.id && $0.validity == .withdrawn }) else {
                    throw MemoryClaimAdmissionError.invalidArtifact
                }
                // Bind a new identity to the actual prior artifact below. The
                // transition requires the complete exact reference, while this
                // publication must also retain the withdrawn predecessor.
                prior = replaced
            }
            let reference: MemoryClaimReference?
            if let prior, let document {
                reference = MemoryClaimReference(documentID: document.id, documentRevision: document.revision,
                    contentDigest: document.contentDigest, claimID: prior.id,
                    claimDigest: try MemoryClaimDigests.claim(prior),
                    subjectDigest: try MemoryClaimDigests.subject(prior, scope: document.scope))
            } else { reference = nil }
            try MemoryClaimAssessmentTransition.validate(previous: prior, previousReference: reference,
                proposal: claim, scope: artifact.scope, actor: assessor,
                verifiedEvidence: evidence.verified.filter { $0.claimID == claim.id },
                previousIndependentEvidenceIDs: evidence.previousIndependentEvidenceIDs, at: clock())
        }
        return evidence
    }
}
