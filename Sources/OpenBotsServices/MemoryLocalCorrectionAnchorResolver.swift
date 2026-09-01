import Foundation
import OpenBotsDomain

/// A caller-verified current claim, not an inventory-completeness assertion.
/// This helper opens no artifacts and grants no scope or write authority.
public struct MemoryLocalCorrectionAnchorClaim: Sendable {
    public let claim: MemoryClaim
    public let reference: MemoryClaimReference
    public let scope: MemoryScope

    public init(claim: MemoryClaim, reference: MemoryClaimReference, scope: MemoryScope) {
        self.claim = claim; self.reference = reference; self.scope = scope
    }
}

/// Disambiguates a correction against the most recent displayed local reply.
/// The returned frozen anchor still needs atomic repository revalidation when
/// admitting the command. It never authorizes a scan or claims a full inventory.
public struct MemoryLocalCorrectionAnchorResolver: Sendable {
    private let publications: any MemoryConversationPublicationRepository
    private let messages: any MessageRepository

    public init(publications: any MemoryConversationPublicationRepository, messages: any MessageRepository) {
        self.publications = publications; self.messages = messages
    }

    public func resolve(text: String, authority: ReadContextReceipt,
                        loadedClaims: [MemoryLocalCorrectionAnchorClaim]) async throws -> MemoryLocalCorrectionAnchor? {
        guard MemoryEvidenceVerifier.recognizesUserCommand(text), loadedClaims.count <= 96,
              Set(loadedClaims.map(\.reference)).count == loadedClaims.count,
              authority.qualificationVersion == 1, let current = authority.claimReferences,
              (try? authority.qualifying(with: current)) == authority else { return nil }
        let page = try await messages.page(conversationID: authority.conversationID, request: PageRequest(limit: 12))
        guard page.elements.count <= 12,
              page.elements.allSatisfy({ $0.conversationID == authority.conversationID && $0.sequence > 0 }),
              zip(page.elements, page.elements.dropFirst()).allSatisfy({ pair in pair.0.sequence < pair.1.sequence }),
              let latest = page.elements.last(where: { $0.author != .user }),
              latest.author == .system, latest.deliveryState == .completed,
              latest.outputClass == .conversation,
              let record = try await publications.memoryConversationPublication(messageID: latest.id,
                    conversationID: authority.conversationID) else { return nil }
        let receipt = record.publication.receipt
        guard record.replyMessage.id == latest.id,
              try MemoryClaimDigests.canonicalData(record.replyMessage) == MemoryClaimDigests.canonicalData(latest),
              record.authority.conversationID == authority.conversationID,
              record.authority.teammateID == authority.teammateID,
              record.authority.selectedProjectID == authority.selectedProjectID,
              receipt.teammateID == authority.teammateID, receipt.selectedProjectID == authority.selectedProjectID,
              receipt.messageID == latest.id, receipt.policyVersion == MemoryConversationPublicationService.rendererPolicyVersion,
              receipt.renderedTextDigest == MemoryClaimDigests.bytes(Data(record.publication.text.utf8)),
              latest.parts.count == 1, case let .text(shownText) = latest.parts[0].content,
              shownText.utf8.elementsEqual(record.publication.text.utf8),
              receipt.units.count <= MemoryPublicationLimits.units,
              receipt.dependencies.count <= MemoryPublicationLimits.dependencyReferences,
              receipt.units.allSatisfy({ $0.references.count <= MemoryPublicationLimits.referencesPerUnit }) else { return nil }
        // Transitive dependencies may never have appeared in this reply. Only
        // closed units that were actually rendered can anchor an explicit target.
        let displayed = receipt.units.flatMap(\.references)
        guard !displayed.isEmpty, displayed.count <= 96, Set(displayed).count == displayed.count else { return nil }
        var candidates: [MemoryLocalCorrectionAnchorClaim] = []
        for reference in displayed {
            guard current.contains(reference),
                  let loaded = loadedClaims.first(where: { $0.reference == reference }),
                  loaded.claim.id == reference.claimID, loaded.claim.hasKnownSemantics,
                  (try? loaded.claim.validate(scope: loaded.scope)) != nil,
                  try MemoryClaimDigests.claim(loaded.claim) == reference.claimDigest,
                  try MemoryClaimDigests.subject(loaded.claim, scope: loaded.scope) == reference.subjectDigest,
                  receipt.dependencies.contains(where: { $0.reference == reference && $0.scope == loaded.scope }),
                  authority.memoryDocuments.contains(where: {
                    $0.documentID == reference.documentID && $0.revision == reference.documentRevision
                        && $0.contentDigest == reference.contentDigest && $0.scope == loaded.scope
                  }) else { return nil }
            switch loaded.scope {
            case .user: return nil
            case .teammate(let id): guard id == authority.teammateID else { return nil }
            case .project(let id):
                guard id == authority.selectedProjectID, authority.projectMembershipJoinedAt != nil else { return nil }
            }
            candidates.append(loaded)
        }
        guard case let .existingClaim(_, _, id) = MemoryEvidenceVerifier.userTarget(text: text, claims: candidates.map(\.claim)),
              let target = candidates.first(where: { $0.claim.id == id }) else { return nil }
        return MemoryLocalCorrectionAnchor(receiptID: receipt.id, reference: target.reference)
    }
}
