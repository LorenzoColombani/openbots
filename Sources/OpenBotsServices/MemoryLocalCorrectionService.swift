import Foundation
import OpenBotsContent
import OpenBotsDomain

/// Local-only route. No provider, executor, work run or provider acknowledgement
/// is created. The fixed system response follows a committed memory operation.
public actor MemoryLocalCorrectionService: ClaudeTextReplyServing {
    private let corrections: any MemoryLocalCorrectionRepository
    private let memory: any MemoryRepository
    private let intents: any MemoryPublicationIntentRepository
    private let contexts: any ReadContextRepository
    private let conversationContexts: any ConversationContextRepository
    private let teammates: any TeammateRepository
    private let messages: any MessageRepository
    private let authority: VerifiedAuthoritativeMarkdownRoot
    private let verifier: MemoryEvidenceVerifier
    private let admission: MemoryClaimAdmissionService
    private let anchorResolver: MemoryLocalCorrectionAnchorResolver?
    private let store = AuthoritativeMarkdownStore(maximumBytes: 16_384)
    private let clock: @Sendable () -> Date
    private var active: Set<TeammateID> = []

    public init(corrections: any MemoryLocalCorrectionRepository, memory: any MemoryRepository,
                intents: any MemoryPublicationIntentRepository, contexts: any ReadContextRepository,
                conversationContexts: any ConversationContextRepository, teammates: any TeammateRepository,
                messages: any MessageRepository, authority: VerifiedAuthoritativeMarkdownRoot,
                publications: (any MemoryConversationPublicationRepository)? = nil,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.corrections = corrections; self.memory = memory; self.intents = intents; self.contexts = contexts
        self.conversationContexts = conversationContexts; self.teammates = teammates; self.messages = messages
        self.authority = authority; self.clock = { MemoryPersistenceTimestamp.normalized(clock()) }
        self.anchorResolver = publications.map { MemoryLocalCorrectionAnchorResolver(publications: $0, messages: messages) }
        let verifier = MemoryEvidenceVerifier(messages: messages, teammates: teammates, contexts: contexts)
        self.verifier = verifier
        self.admission = MemoryClaimAdmissionService(memory: memory, intents: intents, contexts: contexts,
            verifier: verifier, authority: authority, clock: clock)
    }

    public func messageProvenance(conversationID: ConversationID,
                                  messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }

    public func sendText(_ submission: ClaudeTextTurnSubmission,
                         onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        await execute(submission, onProgress: onProgress, requiredSavedMarker: nil)
    }

    /// Resume only the exact admitted operation selected by the bounded local
    /// recovery lane. A missing/changed marker never becomes a fresh user action.
    public func recoverSavedOperation(_ marker: MemoryLocalCorrectionRecoveryMarker) async -> ClaudeTextTurnResult {
        do {
            guard let record = try await corrections.memoryLocalCorrection(userMessageID: marker.userMessageID),
                  MemoryLocalCorrectionRecoveryMarker(record: record) == marker,
                  record.state == .admitted || record.state == .committedUnacknowledged,
                  record.userMessage.author == .user, record.userMessage.parts.count == 1,
                  case let .text(text) = record.userMessage.parts[0].content else {
                return .init(outcome: .failed(.contextChanged))
            }
            let submission = ClaudeTextTurnSubmission(conversationID: marker.conversationID,
                teammateID: marker.teammateID, userMessageID: marker.userMessageID, text: text)
            return await execute(submission, onProgress: { _ in }, requiredSavedMarker: marker)
        } catch is CancellationError { return .init(outcome: .stopped) }
        catch { return .init(outcome: .failed(.contextChanged)) }
    }

    private func execute(_ submission: ClaudeTextTurnSubmission,
                         onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void,
                         requiredSavedMarker: MemoryLocalCorrectionRecoveryMarker?) async -> ClaudeTextTurnResult {
        guard submission.attachmentIDs.isEmpty else { return .init(outcome: .failed(.attachmentsNotSupported)) }
        guard MemoryEvidenceVerifier.recognizesUserCommand(submission.text) else { return .init(outcome: .failed(.invalidInput)) }
        guard active.insert(submission.teammateID).inserted else { return .init(outcome: .failed(.busy)) }
        defer { active.remove(submission.teammateID) }
        var saved: MemoryLocalCorrectionRecord?
        do {
            try Task.checkCancellation()
            await onProgress(.stage(.selectingContext))
            if let existing = try await corrections.memoryLocalCorrection(userMessageID: submission.userMessageID) {
                guard requiredSavedMarker == nil || MemoryLocalCorrectionRecoveryMarker(record: existing) == requiredSavedMarker,
                      existing.request.authority.conversationID == submission.conversationID,
                      existing.request.authority.teammateID == submission.teammateID,
                      existing.request.commandDigest == MemoryClaimDigests.bytes(Data(submission.text.utf8)) else {
                    return .init(outcome: .failed(.invalidInput))
                }
                saved = existing
            } else {
                guard requiredSavedMarker == nil else { return .init(outcome: .failed(.contextChanged)) }
                let request = try await freeze(submission)
                saved = try await corrections.admitMemoryLocalCorrection(request, text: submission.text)
            }
            guard let record = saved else { throw MemoryLocalCorrectionError.invalidState }
            await onProgress(.userMessageSaved(record.userMessage))
            if record.state == .acknowledged || record.state == .failed { return result(record) }
            try Task.checkCancellation()
            await onProgress(.stage(.saving))
            let request = record.request
            if let operation = try await intents.memoryPublication(id: request.operationID) {
                switch operation.state {
                case .committed: break
                case .aborted: throw MemoryLocalCorrectionError.invalidState
                case .pending:
                    guard operation.intent.document.id == request.documentID,
                          operation.intent.actor == .user(messageID: request.userMessageID),
                          operation.intent.authority == request.authority else {
                        throw MemoryLocalCorrectionError.invalidState
                    }
                    try await contexts.revalidateReadContext(request.authority.selecting(messageIDs: [], memoryDocumentIDs: []))
                    // The admission service rechecks evidence and authority before
                    // recovering only this exact operation's staging/final file.
                    _ = try await admission.reconcile(operationID: request.operationID)
                }
            } else {
                let prepared: PreparedArtifact
                do { prepared = try await prepareArtifact(record) }
                catch where Self.requiresTargetClarification(error) {
                    try Task.checkCancellation()
                    let clarified = try await corrections.clarifyMemoryLocalCorrection(userMessageID: request.userMessageID,
                        expectedRevision: record.revision, kind: .targetRequired, now: clock())
                    if let reply = clarified.clarification { await onProgress(.assistantMessageSaved(reply)) }
                    return result(clarified)
                }
                try Task.checkCancellation()
                _ = try await admission.publish(operationID: request.operationID, artifact: prepared.artifact,
                    title: prepared.predecessor?.title ?? "Remembered notes", expectedPredecessor: prepared.predecessor,
                    actor: .user(messageID: request.userMessageID), context: request.authority)
            }
            try Task.checkCancellation()
            let acknowledged = try await corrections.acknowledgeMemoryLocalCorrection(userMessageID: request.userMessageID,
                expectedRevision: record.revision, now: clock())
            // The system-authored result is not provider text/model provenance.
            if let reply = acknowledged.acknowledgement { await onProgress(.assistantMessageSaved(reply)) }
            return result(acknowledged)
        } catch {
            if saved == nil { saved = try? await corrections.memoryLocalCorrection(userMessageID: submission.userMessageID) }
            let failure = classify(error)
            if failure == .cancelled, let record = saved,
               let operation = try? await intents.memoryPublication(id: record.request.operationID), operation.state == .committed {
                // Commit already won cancellation. Settle only the exact fixed
                // response, with all repository authority/sequence checks fresh.
                let corrections = self.corrections
                let now = clock()
                if let settled = try? await Task.detached(operation: {
                    try await corrections.acknowledgeMemoryLocalCorrection(userMessageID: record.request.userMessageID,
                        expectedRevision: record.revision, now: now)
                }).value {
                    if let reply = settled.acknowledgement { await onProgress(.assistantMessageSaved(reply)) }
                    return result(settled)
                }
            }
            if let record = saved, record.state == .admitted || record.state == .committedUnacknowledged {
                let corrections = self.corrections, now = clock()
                if let failed = try? await Task.detached(operation: {
                    try await corrections.failMemoryLocalCorrection(userMessageID: record.request.userMessageID,
                        expectedRevision: record.revision, failure: failure, now: now)
                }).value { saved = failed }
            }
            if let saved, saved.clarification != nil || saved.state == .acknowledged || saved.state == .committedUnacknowledged {
                return result(saved)
            }
            return .init(outcome: failure == .cancelled ? .stopped : .failed(problem(failure, error: error)),
                         savedUserMessage: saved?.userMessage)
        }
    }

    private func freeze(_ submission: ClaudeTextTurnSubmission) async throws -> MemoryLocalCorrectionRequest {
        guard let teammate = try await teammates.teammate(id: submission.teammateID), teammate.lifecycle == .active else {
            throw ReadContextError.unavailable
        }
        let selection = try await conversationContexts.loadContext(conversationID: submission.conversationID)
        let latest = try await messages.page(conversationID: submission.conversationID, request: PageRequest(limit: 1))
        let sequence = latest.elements.last?.sequence ?? 0
        guard sequence <= Int64.max - 2 else { throw MemoryLocalCorrectionError.invalidRequest }
        let snapshot = try await contexts.loadReadContextCandidates(ReadContextRequest(conversationID: submission.conversationID,
            teammateID: submission.teammateID, profileRevision: teammate.profile.revision,
            selection: selection, beforeSequence: Int64.max))
        let selected = Array(snapshot.memoryDocuments.prefix(3))
        var frozen = try snapshot.receipt.selecting(messageIDs: [], memoryDocumentIDs: selected.map(\.id))
        var complete = snapshot.memoryDocuments.count <= 3 && !snapshot.omissions.memoryWindowHasMore
            && snapshot.omissions.excludedMemoryLowerBound == 0
        let capture: Bool
        if submission.text.hasPrefix("Remember that "),
           case .newClaim(action: .retainUncertain, body: _) = MemoryEvidenceVerifier.userTarget(text: submission.text, claims: []) {
            capture = true
        } else { capture = false }
        var targetAnchor: MemoryLocalCorrectionAnchor?
        if !capture, let anchorResolver {
            let loaded = try await loadDocuments(frozen)
            complete = complete && loaded.count == frozen.memoryDocuments.count
            let claims = try loaded.flatMap { item in
                try item.artifact.claims.map { claim in
                    MemoryLocalCorrectionAnchorClaim(claim: claim,
                        reference: try MemoryClaimCodec().reference(for: claim, in: item.artifact,
                            contentDigest: item.document.contentDigest), scope: item.document.scope)
                }
            }
            let qualified = try frozen.qualifying(with: claims.map(\.reference))
            targetAnchor = try await anchorResolver.resolve(text: submission.text, authority: qualified, loadedClaims: claims)
            if let targetAnchor {
                frozen = try qualified.selecting(messageIDs: [], memoryDocumentIDs: [targetAnchor.reference.documentID])
                    .qualifying(with: [targetAnchor.reference])
                complete = false // Exact displayed target, never a complete-inventory claim.
            }
        }
        let prefix = "memory-local:" + submission.userMessageID.persistedValue + ":"
        return try MemoryLocalCorrectionRequest(operationID: Self.stableID(prefix + "operation"),
            userMessageID: submission.userMessageID, userPartID: MessagePartID(Self.stableID(prefix + "user-part")),
            acknowledgementMessageID: MessageID(Self.stableID(prefix + "acknowledgement")),
            acknowledgementPartID: MessagePartID(Self.stableID(prefix + "acknowledgement-part")),
            documentID: MemoryDocumentID(Self.stableID(prefix + "document")), claimID: MemoryClaimID(Self.stableID(prefix + "claim")),
            authority: frozen, expectedPreviousSequence: sequence,
            commandDigest: MemoryClaimDigests.bytes(Data(submission.text.utf8)), inventoryComplete: complete,
            captureNewClaim: capture, targetAnchor: targetAnchor, createdAt: clock())
    }

    private struct LoadedDocument { let document: MemoryDocument; let artifact: MemoryClaimArtifact }
    private struct PreparedArtifact { let artifact: MemoryClaimArtifact; let predecessor: MemoryDocument? }
    private enum TargetResolutionError: Error { case clarificationRequired }

    private func prepareArtifact(_ record: MemoryLocalCorrectionRecord) async throws -> PreparedArtifact {
        let request = record.request
        guard request.captureNewClaim || request.inventoryComplete || request.targetAnchor != nil else {
            throw TargetResolutionError.clarificationRequired
        }
        try await contexts.revalidateReadContext(request.authority)
        let loaded = try await loadDocuments(request.authority)
        let complete = request.inventoryComplete && loaded.count == request.authority.memoryDocuments.count
        guard case let .text(text) = record.userMessage.parts[0].content else { throw MemoryLocalCorrectionError.invalidState }
        if request.captureNewClaim {
            let scope = MemoryScope.teammate(request.authority.teammateID)
            let claim = try await verifier.userProposal(messageID: request.userMessageID, claimID: request.claimID,
                scope: scope, authority: request.authority, at: clock())
            guard claim.assessment.level == .uncertain, claim.validity == .active, claim.changes.isEmpty else {
                throw MemoryLocalCorrectionError.invalidRequest
            }
            for candidate in loaded where candidate.document.scope == scope && candidate.artifact.claims.count < 32 {
                var reusable = true
                for prior in candidate.artifact.claims {
                    do { _ = try await verifier.verifyRetained(claim: prior, scope: scope, authority: request.authority, at: clock()) }
                    catch { reusable = false; break }
                }
                guard reusable, candidate.document.revision < UInt64(Int64.max) else { continue }
                let artifact = MemoryClaimArtifact(documentID: request.documentID, revision: candidate.document.revision + 1,
                    scope: scope, claims: candidate.artifact.claims + [claim])
                if (try? MemoryClaimCodec().encode(artifact)) != nil {
                    return PreparedArtifact(artifact: artifact, predecessor: candidate.document)
                }
            }
            return PreparedArtifact(artifact: MemoryClaimArtifact(documentID: request.documentID, revision: 1,
                scope: scope, claims: [claim]), predecessor: nil)
        }
        guard complete || request.targetAnchor != nil else { throw TargetResolutionError.clarificationRequired }
        let targetClaims: [MemoryClaim]
        if let anchor = request.targetAnchor {
            guard let item = loaded.first(where: { $0.document.id == anchor.reference.documentID }),
                  let claim = item.artifact.claims.first(where: { $0.id == anchor.reference.claimID }),
                  try MemoryClaimCodec().reference(for: claim, in: item.artifact,
                    contentDigest: item.document.contentDigest) == anchor.reference else { throw ReadContextError.staleReferences }
            targetClaims = [claim]
        } else { targetClaims = loaded.flatMap { $0.artifact.claims } }
        let target = MemoryEvidenceVerifier.userTarget(text: text, claims: targetClaims)
        switch target {
        case .newClaim:
            guard request.targetAnchor == nil else { throw MemoryEvidenceVerifierError.ambiguousIntent }
            let scope = MemoryScope.teammate(request.authority.teammateID)
            let claim = try await verifier.userProposal(messageID: request.userMessageID, claimID: request.claimID,
                scope: scope, authority: request.authority, at: clock())
            return PreparedArtifact(artifact: MemoryClaimArtifact(documentID: request.documentID, revision: 1,
                                                                  scope: scope, claims: [claim]), predecessor: nil)
        case let .existingClaim(action, body, id):
            guard let candidate = loaded.first(where: { $0.artifact.claims.contains(where: { $0.id == id }) }),
                  let previous = candidate.artifact.claims.first(where: { $0.id == id }),
                  candidate.document.revision < UInt64(Int64.max) else { throw ReadContextError.unavailable }
            let reference = try MemoryClaimCodec().reference(for: previous, in: candidate.artifact,
                                                            contentDigest: candidate.document.contentDigest)
            let claims: [MemoryClaim]
            if (action == .correctFirstHand || action == .correctAdoptedQuotation) && !body.utf8.elementsEqual(previous.body.utf8) {
                let pair = try await verifier.userCorrectionProposal(messageID: request.userMessageID,
                    previous: previous, previousReference: reference, scope: candidate.document.scope,
                    authority: request.authority, at: clock())
                guard candidate.artifact.claims.count < 32,
                      !candidate.artifact.claims.contains(where: { $0.id == pair.successor.id }) else {
                    throw MemoryEvidenceVerifierError.ambiguousIntent
                }
                claims = candidate.artifact.claims.map { $0.id == id ? pair.withdrawnPredecessor : $0 } + [pair.successor]
            } else {
                let claim = try await verifier.userProposal(messageID: request.userMessageID, claimID: id,
                    scope: candidate.document.scope, previous: previous, previousReference: reference,
                    authority: request.authority, at: clock())
                claims = candidate.artifact.claims.map { $0.id == id ? claim : $0 }
            }
            return PreparedArtifact(artifact: MemoryClaimArtifact(documentID: request.documentID,
                revision: candidate.document.revision + 1, scope: candidate.document.scope, claims: claims),
                predecessor: candidate.document)
        case .ambiguous, .unsupported: throw TargetResolutionError.clarificationRequired
        }
    }

    /// Each phase attempts at most the three frozen heads. Failed/legacy reads
    /// never stand in for a proven complete inventory or expand into a scan.
    private func loadDocuments(_ context: ReadContextReceipt) async throws -> [LoadedDocument] {
        var loaded: [LoadedDocument] = []
        for reference in context.memoryDocuments.prefix(3) {
            try Task.checkCancellation()
            do {
                guard allowed(reference.scope, authority: context),
                      let document = try await memory.document(id: reference.documentID),
                      document.scope == reference.scope, document.revision == reference.revision,
                      document.contentDigest == reference.contentDigest else { throw ReadContextError.staleReferences }
                try await contexts.revalidateReadContext(context)
                let content = try await store.read(AuthoritativeMarkdownReference(document: document), inside: authority)
                guard let artifact = MemoryClaimCodec().decode(Data(content.markdown.utf8), expecting: document).artifact else {
                    throw ReadContextError.unavailable
                }
                loaded.append(LoadedDocument(document: document, artifact: artifact))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return loaded
    }

    private func allowed(_ scope: MemoryScope, authority: ReadContextReceipt) -> Bool {
        switch scope {
        case .user: false
        case let .teammate(id): id == authority.teammateID
        case let .project(id): id == authority.selectedProjectID && authority.projectMembershipJoinedAt != nil
        }
    }
    private func result(_ record: MemoryLocalCorrectionRecord) -> ClaudeTextTurnResult {
        if let clarification = record.clarification {
            return .init(outcome: .completed, savedUserMessage: record.userMessage, savedReplyMessage: clarification)
        }
        if record.state == .acknowledged {
            return .init(outcome: .completed, savedUserMessage: record.userMessage, savedReplyMessage: record.acknowledgement)
        }
        if record.state == .committedUnacknowledged {
            return .init(outcome: .failed(.memoryAcknowledgementPending), savedUserMessage: record.userMessage)
        }
        let failure = record.failure ?? .publicationFailed
        return .init(outcome: failure == .cancelled ? .stopped : .failed(problem(failure)), savedUserMessage: record.userMessage)
    }
    private static func requiresTargetClarification(_ error: any Error) -> Bool {
        if error is TargetResolutionError { return true }
        guard let error = error as? MemoryEvidenceVerifierError else { return false }
        return error == .ambiguousIntent || error == .unsupportedIntent
    }
    private func classify(_ error: any Error) -> MemoryLocalCorrectionFailure {
        if error is CancellationError { return .cancelled }
        if let error = error as? MemoryEvidenceVerifierError, error == .ambiguousIntent || error == .unsupportedIntent {
            return .contextUnavailable
        }
        if let error = error as? ReadContextError { return error == .unavailable ? .contextUnavailable : .contextChanged }
        if error is MemoryLocalCorrectionError || error is MemoryPublicationError { return .contextChanged }
        return .publicationFailed
    }
    private func problem(_ failure: MemoryLocalCorrectionFailure, error: (any Error)? = nil) -> ClaudeTextTurnProblem {
        if (error as? MemoryLocalCorrectionError) == .busy { return .busy }
        switch failure {
        case .cancelled: return .contextChanged
        case .contextUnavailable: return .contextUnavailable
        case .contextChanged: return .contextChanged
        case .publicationFailed: return .persistenceFailed
        }
    }
    private static func stableID(_ value: String) -> UUID {
        let chars = Array(MemoryClaimDigests.bytes(Data(value.utf8)).prefix(32))
        return UUID(uuidString: String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16])
                    + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32]))!
    }
}
