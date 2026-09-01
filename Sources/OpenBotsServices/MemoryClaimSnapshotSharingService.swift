import Foundation
import OpenBotsContent
import OpenBotsDomain

/// Registered host evidence only; no Codable/provider authority conversion.
public protocol MemoryRetainedEvidenceVerifying: Sendable {
    func verifyRetained(claim: MemoryClaim, scope: MemoryScope, authority: ReadContextReceipt,
                        at now: Date) async throws -> [MemoryClaimVerifiedEvidence]
}

extension MemoryEvidenceVerifier: MemoryRetainedEvidenceVerifying {}

/// A bounded sharing exit. Raw/private inspection snapshots cannot acquire
/// permission here. Rendering is frozen before destination approval; fresh
/// checks can reject it, but may never silently edit or replace its bytes.
public actor MemoryClaimSnapshotSharingService: KnowledgeSnapshotSharingValidating {
    private let memory: any MemoryRepository
    private let intents: any MemoryPublicationIntentRepository
    private let contexts: any ReadContextRepository
    private let evidence: any MemoryRetainedEvidenceVerifying
    private let authority: VerifiedAuthoritativeMarkdownRoot
    private let context: ReadContextReceipt
    private let store: AuthoritativeMarkdownStore
    private let renderer = KnowledgeSnapshotRenderer()
    private let clock: @Sendable () -> Date
    private var rendered: [UUID: NonAuthoritativeKnowledgeSnapshot] = [:]
    private var order: [UUID] = []

    public init(memory: any MemoryRepository, intents: any MemoryPublicationIntentRepository,
                contexts: any ReadContextRepository, evidence: any MemoryRetainedEvidenceVerifying,
                authority: VerifiedAuthoritativeMarkdownRoot, context: ReadContextReceipt,
                store: AuthoritativeMarkdownStore = AuthoritativeMarkdownStore(maximumBytes: 16_384),
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.memory = memory; self.intents = intents; self.contexts = contexts; self.evidence = evidence
        self.authority = authority; self.context = context; self.store = store; self.clock = clock
    }

    /// Loads only the explicitly selected immutable heads from the caller's
    /// frozen context. This is not the broad owner-inspection workspace loader:
    /// no catalog enumeration, fallback revision, or silent unsafe omission is
    /// permitted. Rendering does not grant an external destination or write.
    public func renderSelectedDocuments(documentIDs: [MemoryDocumentID], workspaceSnapshotID: UUID,
                                        generatedAt: Date? = nil) async throws -> NonAuthoritativeKnowledgeSnapshot {
        guard !documentIDs.isEmpty, documentIDs.count <= 16,
              Set(documentIDs).count == documentIDs.count,
              documentIDs.allSatisfy({ id in context.memoryDocuments.contains { $0.documentID == id } }) else {
            throw KnowledgeSnapshotDeliveryError.sharingDenied
        }
        let selected = try context.selecting(messageIDs: [], memoryDocumentIDs: documentIDs)
        for reference in selected.memoryDocuments { try requireScope(reference.scope) }
        try await contexts.revalidateReadContext(selected)
        var documents: [MemoryDocument] = []
        for reference in selected.memoryDocuments {
            let document = try await currentDocument(id: reference.documentID)
            guard document.scope == reference.scope, document.revision == reference.revision,
                  document.contentDigest == reference.contentDigest else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
            documents.append(document)
        }
        var sources: [KnowledgeSnapshotSource] = []
        for document in documents {
            try Task.checkCancellation()
            try await contexts.revalidateReadContext(selected)
            let value = try await store.read(AuthoritativeMarkdownReference(document: document), inside: authority)
            sources.append(try KnowledgeSnapshotSource(documentID: document.id, title: document.title,
                scope: document.scope, author: document.author, revision: document.revision,
                contentDigest: document.contentDigest, updatedAt: document.updatedAt,
                revisionStatus: .current, markdown: value.markdown))
        }
        return try await render(workspaceSnapshotID: workspaceSnapshotID, sources: sources,
                                generatedAt: generatedAt ?? clock())
    }

    public func render(workspaceSnapshotID: UUID, sources: [KnowledgeSnapshotSource],
                       generatedAt: Date) async throws -> NonAuthoritativeKnowledgeSnapshot {
        try await validateSources(sources, payload: nil, grant: nil, target: nil)
        let snapshot = try renderer.renderQualifiedSharing(sources: sources, generatedAt: generatedAt)
        rendered[workspaceSnapshotID] = snapshot
        order.removeAll { $0 == workspaceSnapshotID }; order.append(workspaceSnapshotID)
        while order.count > 16 { rendered.removeValue(forKey: order.removeFirst()) }
        return snapshot
    }

    public func validate(snapshot: NonAuthoritativeKnowledgeSnapshot, workspaceSnapshotID: UUID,
                         capabilityID: CapabilityGrantID, exactTarget: URL) async throws {
        guard snapshot.purpose == .qualifiedSharing, rendered[workspaceSnapshotID] == snapshot,
              exactTarget.isFileURL, exactTarget.path.hasPrefix("/"),
              MemoryClaimDigests.bytes(snapshot.data) == snapshot.contentDigest,
              Data(snapshot.markdown.utf8) == snapshot.data else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        try await validateSources(snapshot.sources, payload: snapshot.contentDigest, grant: capabilityID.rawValue, target: exactTarget.path)
        let rebuilt = try renderer.renderQualifiedSharing(sources: snapshot.sources, generatedAt: snapshot.generatedAt)
        guard rebuilt == snapshot else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
    }

    private func validateSources(_ sources: [KnowledgeSnapshotSource], payload: String?, grant: UUID?, target: String?) async throws {
        guard !sources.isEmpty, sources.count <= 16,
              Set(sources.map(\.documentID)).count == sources.count else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        // Scope and catalog eligibility are checked before opening any body.
        let scopeOnly = try context.selecting(messageIDs: [], memoryDocumentIDs: [])
        try await contexts.revalidateReadContext(scopeOnly)
        guard try await memory.authorityContract() == .appOwnedMarkdownV1 else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        for source in sources {
            try Task.checkCancellation()
            try requireScope(source.scope)
            let document = try await currentDocument(source)
            try await contexts.revalidateReadContext(scopeOnly)
            let value = try await store.read(AuthoritativeMarkdownReference(document: document), inside: authority)
            guard value.markdown.utf8.elementsEqual(source.markdown.utf8),
                  let artifact = MemoryClaimCodec().decode(Data(value.markdown.utf8)).artifact,
                  artifact.hasKnownSemantics, artifact.documentID == document.id,
                  artifact.scope == document.scope, artifact.revision == document.revision else {
                throw KnowledgeSnapshotDeliveryError.sharingDenied
            }
            try artifact.validate()
            let withdrawn = try await intents.withdrawnMemoryClaimIDs(documentID: document.id)
            guard Set(withdrawn).isSubset(of: Set(artifact.claims.filter { $0.validity == .withdrawn }.map { $0.id.rawValue })) else {
                throw KnowledgeSnapshotDeliveryError.sharingDenied
            }
            for claim in artifact.claims {
                guard claim.assessment.level == .confirmed || claim.assessment.level == .supportedInference else {
                    throw KnowledgeSnapshotDeliveryError.sharingDenied
                }
                let now = clock()
                let verified = try await evidence.verifyRetained(claim: claim, scope: artifact.scope, authority: scopeOnly, at: now)
                let reference = MemoryClaimReference(documentID: document.id, documentRevision: document.revision,
                    contentDigest: document.contentDigest, claimID: claim.id, claimDigest: try MemoryClaimDigests.claim(claim),
                    subjectDigest: try MemoryClaimDigests.subject(claim, scope: document.scope))
                let authorization: MemoryClaimExternalAuthorization?
                if let payload, let grant, let target {
                    authorization = MemoryClaimExternalAuthorization(grantID: grant, reference: reference, purpose: .sharing,
                        destination: target, payloadDigest: payload, checkedAt: now, validUntil: now.addingTimeInterval(1),
                        qualificationPreserved: true)
                } else { authorization = nil }
                let decision = MemoryClaimUsePolicy.evaluate(claim: claim, reference: reference, scope: document.scope,
                    context: MemoryClaimUseContext(purpose: authorization == nil ? .conversation : .sharing, now: now,
                        teammateID: context.teammateID, selectedProjectID: context.selectedProjectID,
                        activeProjectMemberships: Set(context.selectedProjectID.map { [$0] } ?? []),
                        currentReference: reference, freshness: .current, isRelevant: true, verifiedEvidence: verified,
                        destination: target, payloadDigest: payload, externalAuthorization: authorization,
                        conditionsSatisfied: claim.conditions == nil))
                guard decision.disposition == .allow || (decision.disposition == .qualified && decision.requiredFraming == .attributionAndHedge) else {
                    throw KnowledgeSnapshotDeliveryError.sharingDenied
                }
            }
            _ = try await currentDocument(source)
        }
        try await contexts.revalidateReadContext(scopeOnly)
        // Recheck the whole set after async evidence calls; an earlier source
        // must not become stale while a later source is being examined.
        for source in sources { _ = try await currentDocument(source) }
    }

    private func requireScope(_ scope: MemoryScope) throws {
        switch scope {
        case .user: throw KnowledgeSnapshotDeliveryError.sharingDenied
        case .teammate(let id):
            guard id == context.teammateID else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        case .project(let id):
            guard id == context.selectedProjectID, context.projectMembershipJoinedAt != nil else {
                throw KnowledgeSnapshotDeliveryError.sharingDenied
            }
        }
    }

    private func currentDocument(_ source: KnowledgeSnapshotSource) async throws -> MemoryDocument {
        guard source.revisionStatus == .current else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        let document = try await currentDocument(id: source.documentID)
        guard document.scope == source.scope, document.author == source.author, document.revision == source.revision,
              document.contentDigest == source.contentDigest, document.title.utf8.elementsEqual(source.title.utf8),
              document.updatedAt == source.updatedAt else { throw KnowledgeSnapshotDeliveryError.sharingDenied }
        return document
    }

    private func currentDocument(id: MemoryDocumentID) async throws -> MemoryDocument {
        guard let document = try await memory.document(id: id),
              try await !intents.memoryPublicationBlocksUse(documentID: document.id),
              let publication = try await intents.committedMemoryPublication(documentID: document.id),
              publication.state == .committed, publication.intent.document == document,
              publication.intent.policyDigest == MemoryClaimAdmissionService.policyDigest else {
            throw KnowledgeSnapshotDeliveryError.sharingDenied
        }
        return document
    }
}
