import Foundation
import OpenBotsDomain

extension SQLiteStore {
    /// An anchor disambiguates a recently displayed unit, not all saved memory.
    /// Rechecked inside admission, publication CAS and acknowledgement transactions.
    func validateMemoryLocalCorrectionAnchor(_ anchor: MemoryLocalCorrectionAnchor,
        request: MemoryLocalCorrectionRequest, intent: MemoryPublicationIntent? = nil,
        afterCommit: Bool = false) throws {
        let a = request.authority, reference = anchor.reference
        guard !request.captureNewClaim, a.qualificationVersion == 1,
              a.claimReferences?.contains(reference) == true,
              a.memoryDocuments.contains(where: { $0.documentID == reference.documentID
                  && $0.revision == reference.documentRevision && $0.contentDigest == reference.contentDigest }),
              let previous = try localMemoryPublicationForAnchor(id: anchor.receiptID),
              previous.authority.conversationID == a.conversationID,
              previous.authority.teammateID == a.teammateID,
              previous.authority.selectedProjectID == a.selectedProjectID,
              previous.replyMessage.sequence <= request.expectedPreviousSequence,
              previous.publication.receipt.units.flatMap(\.references).contains(reference),
              let dependency = previous.publication.receipt.dependencies.first(where: { $0.reference == reference }) else {
            throw MemoryLocalCorrectionError.inventoryChanged
        }
        let latest = try query(sql: """
            SELECT id FROM messages WHERE conversation_id=? AND author_kind!='user'
            ORDER BY sequence DESC LIMIT 1;
            """, bindings: [.text(a.conversationID.persistedValue)]).first
        guard try latest?.text("id") == previous.replyMessage.id.persistedValue else {
            throw MemoryLocalCorrectionError.inventoryChanged
        }
        switch dependency.scope {
        case .user: throw MemoryLocalCorrectionError.invalidRequest
        case .teammate(let id):
            guard id == a.teammateID else { throw MemoryLocalCorrectionError.invalidRequest }
        case .project(let id):
            guard id == a.selectedProjectID, a.projectMembershipJoinedAt != nil else {
                throw MemoryLocalCorrectionError.invalidRequest
            }
        }
        if let intent {
            guard let prior = intent.expectedPredecessor,
                  prior.id == reference.documentID, prior.revision == reference.documentRevision,
                  prior.contentDigest == reference.contentDigest, prior.scope == dependency.scope else {
                throw MemoryLocalCorrectionError.inventoryChanged
            }
        } else if afterCommit { throw MemoryLocalCorrectionError.invalidRequest }
        if !afterCommit {
            guard try !memoryPublicationBlocksUseRow(documentID: reference.documentID,
                excludingMemoryPublicationID: intent?.id) else { throw MemoryLocalCorrectionError.inventoryChanged }
        }
    }
}
