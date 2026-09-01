import Foundation
import OpenBotsContent
import OpenBotsDomain

/// Current, bounded production reads for the closed local publisher. No source
/// body is opened before scope/head admission, and no model field mints evidence.
public struct MemoryConversationResolver: MemoryConversationPublicationResolving, Sendable {
    private let memory: any MemoryRepository
    private let intents: any MemoryPublicationIntentRepository
    private let contexts: any ReadContextRepository
    private let publications: any MemoryConversationPublicationRepository
    private let evidence: MemoryEvidenceVerifier
    private let authority: VerifiedAuthoritativeMarkdownRoot
    private let context: ReadContextReceipt
    private let clock: @Sendable () -> Date

    public init(memory: any MemoryRepository, intents: any MemoryPublicationIntentRepository,
                contexts: any ReadContextRepository, publications: any MemoryConversationPublicationRepository,
                evidence: MemoryEvidenceVerifier, authority: VerifiedAuthoritativeMarkdownRoot,
                context: ReadContextReceipt, clock: @escaping @Sendable () -> Date = Date.init) {
        self.memory = memory; self.intents = intents; self.contexts = contexts; self.publications = publications
        self.evidence = evidence; self.authority = authority; self.context = context; self.clock = clock
    }

    public func resolveClaim(_ reference: MemoryClaimReference, context publication: MemoryPublicationContext)
        async throws -> MemoryPublicationClaimSnapshot? {
        try await validateContext(publication)
        guard let document = try await memory.document(id: reference.documentID),
              readable(document.scope), document.revision == reference.documentRevision,
              document.contentDigest == reference.contentDigest,
              try await !intents.memoryPublicationBlocksUse(documentID: document.id),
              let committed = try await intents.committedMemoryPublication(documentID: document.id),
              committed.state == .committed, committed.intent.document == document,
              committed.intent.policyDigest == MemoryClaimAdmissionService.policyDigest else { return nil }
        let stored = try await AuthoritativeMarkdownStore(maximumBytes: 16_384)
            .read(AuthoritativeMarkdownReference(document: document), inside: authority)
        let codec = MemoryClaimCodec()
        let decoded = codec.decode(Data(stored.markdown.utf8), expecting: document)
        guard let artifact = decoded.artifact,
              let claim = artifact.claims.first(where: { $0.id == reference.claimID }),
              try codec.reference(for: claim, in: artifact, contentDigest: document.contentDigest) == reference else { return nil }
        let tombstones = try await intents.withdrawnMemoryClaimIDs(documentID: document.id)
        guard !tombstones.contains(claim.id.rawValue) || claim.validity == .withdrawn else { return nil }
        let verified: [MemoryClaimVerifiedEvidence]
        do { verified = try await evidence.verifyRetained(claim: claim, scope: document.scope,
            authority: context, at: publication.now) }
        catch is MemoryEvidenceVerifierError { verified = [] }
        // Source types alone are not lineage proof. Only the initial registered
        // predicates have known independent sources; unsupported extraction/
        // model/history lineage remains withheld pending a registered resolver.
        let independent = !verified.isEmpty && claim.provenance.allSatisfy { source in
            source.derivedFrom.isEmpty && (source.kind == .userMessage || source.kind == .appObservation)
                && verified.contains { $0.reference.source == source }
        }
        let memberships = Set(context.selectedProjectID.flatMap {
            context.projectMembershipJoinedAt == nil ? nil : $0
        }.map { [$0] } ?? [])
        let use = MemoryClaimUseContext(
            purpose: publication.intent == .historyOverview ? .ownerInspection : .conversation,
            now: publication.now, teammateID: context.teammateID,
            selectedProjectID: context.selectedProjectID, activeProjectMemberships: memberships,
            currentReference: reference, freshness: .current,
            isRelevant: publication.relevantReferences.contains(reference),
            ownerInspectionAuthorized: publication.intent == .historyOverview,
            verifiedEvidence: verified, conditionsSatisfied: claim.conditions == nil)
        return MemoryPublicationClaimSnapshot(claim: claim, reference: reference, scope: document.scope,
            useContext: use, lineage: independent ? .independent : .unknown)
    }

    public func resolveReceipt(_ id: UUID, context publication: MemoryPublicationContext)
        async throws -> MemoryPublicationReceipt? {
        try await validateContext(publication)
        guard let record = try await publications.memoryConversationPublication(id: id),
              record.authority.conversationID == context.conversationID,
              record.authority.teammateID == context.teammateID,
              record.authority.selectedProjectID == context.selectedProjectID else { return nil }
        return record.publication.receipt
    }

    public func revalidate(_ receipt: MemoryPublicationReceipt, context publication: MemoryPublicationContext)
        async throws -> Bool {
        try await validateContext(publication)
        guard receipt.teammateID == context.teammateID,
              receipt.selectedProjectID == context.selectedProjectID,
              receipt.dependencies.count <= MemoryPublicationLimits.dependencyReferences else { return false }
        for dependency in receipt.dependencies {
            guard let snapshot = try await resolveClaim(dependency.reference, context: publication),
                  snapshot.scope == dependency.scope,
                  snapshot.claim.provenance == dependency.sourceStamps,
                  snapshot.claim.assessment.evidence == dependency.evidenceStamps,
                  MemoryClaimUsePolicy.evaluate(claim: snapshot.claim, reference: snapshot.reference,
                    scope: snapshot.scope, context: snapshot.useContext) == dependency.decision else { return false }
        }
        try await validateContext(publication)
        return true
    }

    private func validateContext(_ publication: MemoryPublicationContext) async throws {
        let now = clock()
        guard now.timeIntervalSince(publication.now) >= 0, now.timeIntervalSince(publication.now) <= 30,
              publication.teammateID == context.teammateID,
              publication.selectedProjectID == context.selectedProjectID else {
            throw MemoryConversationPublicationError.staleReference
        }
        try await contexts.revalidateReadContext(context)
    }

    private func readable(_ scope: MemoryScope) -> Bool {
        switch scope {
        case .user: false
        case .teammate(let id): id == context.teammateID
        case .project(let id): id == context.selectedProjectID && context.projectMembershipJoinedAt != nil
        }
    }
}
