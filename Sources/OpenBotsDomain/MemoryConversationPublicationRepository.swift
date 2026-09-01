import Foundation

/// A trusted-host assertion, NOT a cryptographic seal or a semantic truth proof.
/// Only app orchestration may construct this after deterministic reconstruction,
/// evidence resolution and the publisher's final revalidation. It is deliberately
/// not Codable and must never be populated from provider/candidate fields.
public struct MemoryConversationPublicationValidation: Equatable, Sendable {
    public static let lifetime: TimeInterval = 30
    public let authority: ReadContextReceipt
    public let publicationDigest: String
    public let userSourceStamps: [MemoryPublicationUserMessageEvidence]
    public let checkedAt: Date

    public init(authority: ReadContextReceipt, publicationDigest: String,
                userSourceStamps: [MemoryPublicationUserMessageEvidence], checkedAt: Date) {
        self.authority = authority; self.publicationDigest = publicationDigest
        self.userSourceStamps = userSourceStamps; self.checkedAt = checkedAt
    }

    /// Binds exact complete-unit bytes, receipt identity, policy and dependencies.
    /// A matching digest alone does not prove the assertion was properly issued.
    public static func digest(of publication: MemoryConversationPublication) throws -> String {
        struct Payload: Encodable {
            let completeUnits: [String]
            let receipt: MemoryPublicationReceipt
            let omittedUnitCount: Int
        }
        return MemoryClaimDigests.bytes(try MemoryClaimDigests.canonicalData(Payload(
            completeUnits: publication.completeUnits, receipt: publication.receipt,
            omittedUnitCount: publication.omittedUnitCount)))
    }
}

/// App-local append. No provider submission/acknowledgment or executor run is
/// manufactured. IDs and sequence are frozen before reconstruction; exact retries
/// return the existing pair without rewriting historical content or receipts.
public struct MemoryConversationPublicationAppend: Sendable {
    public let publication: MemoryConversationPublication
    public let userMessageID: MessageID
    public let userPartID: MessagePartID
    public let replyPartID: MessagePartID
    public let userText: String
    public let expectedPreviousSequence: Int64
    public let validation: MemoryConversationPublicationValidation

    public init(publication: MemoryConversationPublication, userMessageID: MessageID,
                userPartID: MessagePartID, replyPartID: MessagePartID, userText: String,
                expectedPreviousSequence: Int64, validation: MemoryConversationPublicationValidation) {
        self.publication = publication; self.userMessageID = userMessageID
        self.userPartID = userPartID; self.replyPartID = replyPartID; self.userText = userText
        self.expectedPreviousSequence = expectedPreviousSequence; self.validation = validation
    }
}

public struct MemoryConversationPublicationRecord: Equatable, Sendable {
    public let publication: MemoryConversationPublication
    public let userMessage: Message
    /// System-authored literal projection. Provider provenance is explicit below;
    /// the text itself never constitutes a Claude transport receipt.
    public let replyMessage: Message
    public let authority: ReadContextReceipt
    public let userSourceStamps: [MemoryPublicationUserMessageEvidence]
    public let storedAt: Date
    public let providerRunID: RunID?

    public init(publication: MemoryConversationPublication, userMessage: Message, replyMessage: Message,
                authority: ReadContextReceipt, userSourceStamps: [MemoryPublicationUserMessageEvidence], storedAt: Date,
                providerRunID: RunID? = nil) {
        self.publication = publication; self.userMessage = userMessage; self.replyMessage = replyMessage
        self.authority = authority; self.userSourceStamps = userSourceStamps; self.storedAt = storedAt
        self.providerRunID = providerRunID
    }
}

public enum MemoryConversationPublicationRepositoryError: Error, Equatable, Sendable {
    case invalidRequest, invalidValidation, authorityChanged, invalidSource
    case conflictingIdentity, conflictingActiveRun, invalidStoredState, invalidLineage
}

/// Host-only persistence boundary. The service must validate the closed rendered
/// projection first; this repository checks DB-authoritative stamps atomically.
/// Arbitrary compiled app code remains trusted. It cannot certify free prose.
public protocol MemoryConversationPublicationRepository: Sendable {
    func appendMemoryConversationPublication(_ request: MemoryConversationPublicationAppend,
                                              now: Date) async throws -> MemoryConversationPublicationRecord
    /// Historical read, not fresh permission to quote/export/reuse the result.
    func memoryConversationPublication(id: UUID) async throws -> MemoryConversationPublicationRecord?
    func memoryConversationPublication(messageID: MessageID, conversationID: ConversationID)
        async throws -> MemoryConversationPublicationRecord?
}
