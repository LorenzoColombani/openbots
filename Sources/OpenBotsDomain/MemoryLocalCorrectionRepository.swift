import Foundation

public enum MemoryLocalCorrectionState: String, Codable, Equatable, Sendable {
    case admitted, committedUnacknowledged, acknowledged, failed
}
public enum MemoryLocalCorrectionFailure: String, Codable, Equatable, Sendable {
    case cancelled, contextUnavailable, contextChanged, publicationFailed
}
public enum MemoryLocalCorrectionError: Error, Equatable, Sendable {
    case invalidRequest, conflictingCommand, notFound, invalidState, busy, inventoryChanged, publicationNotCommitted
}

/// Body-free marker. The exact command lives once in its real user message row.
public struct MemoryLocalCorrectionRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let userMessageID: MessageID
    public let userPartID: MessagePartID
    public let acknowledgementMessageID: MessageID
    public let acknowledgementPartID: MessagePartID
    public let documentID: MemoryDocumentID
    public let claimID: MemoryClaimID
    public let authority: ReadContextReceipt
    public let expectedPreviousSequence: Int64
    public let commandDigest: String
    public let inventoryComplete: Bool
    /// Initial uncertain capture may add a new identity without resolving an
    /// existing target. It never authorizes modification of an existing claim.
    public let captureNewClaim: Bool
    public let targetAnchor: MemoryLocalCorrectionAnchor?
    public let createdAt: Date

    public init(operationID: UUID, userMessageID: MessageID, userPartID: MessagePartID,
                acknowledgementMessageID: MessageID, acknowledgementPartID: MessagePartID,
                documentID: MemoryDocumentID, claimID: MemoryClaimID, authority: ReadContextReceipt,
                expectedPreviousSequence: Int64, commandDigest: String, inventoryComplete: Bool,
                captureNewClaim: Bool = false, targetAnchor: MemoryLocalCorrectionAnchor? = nil, createdAt: Date) throws {
        guard expectedPreviousSequence >= 0, expectedPreviousSequence <= Int64.max - 2,
              userMessageID != acknowledgementMessageID, userPartID != acknowledgementPartID,
              authority.messages.isEmpty, authority.memoryDocuments.count <= 3,
              Set(authority.memoryDocuments.map(\.documentID)).count == authority.memoryDocuments.count,
              commandDigest.utf8.count == 64,
              commandDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              createdAt.timeIntervalSince1970.isFinite else { throw MemoryLocalCorrectionError.invalidRequest }
        if let targetAnchor {
            guard !captureNewClaim, authority.qualificationVersion == 1,
                  authority.claimReferences?.contains(targetAnchor.reference) == true else {
                throw MemoryLocalCorrectionError.invalidRequest
            }
        }
        self.operationID = operationID; self.userMessageID = userMessageID; self.userPartID = userPartID
        self.acknowledgementMessageID = acknowledgementMessageID; self.acknowledgementPartID = acknowledgementPartID
        self.documentID = documentID; self.claimID = claimID; self.authority = authority
        self.expectedPreviousSequence = expectedPreviousSequence; self.commandDigest = commandDigest
        self.inventoryComplete = inventoryComplete; self.createdAt = createdAt
        self.captureNewClaim = captureNewClaim
        self.targetAnchor = targetAnchor
    }
    public func validated() throws -> Self {
        try Self(operationID: operationID, userMessageID: userMessageID, userPartID: userPartID,
            acknowledgementMessageID: acknowledgementMessageID, acknowledgementPartID: acknowledgementPartID,
            documentID: documentID, claimID: claimID, authority: authority, expectedPreviousSequence: expectedPreviousSequence,
            commandDigest: commandDigest, inventoryComplete: inventoryComplete,
            captureNewClaim: captureNewClaim, targetAnchor: targetAnchor, createdAt: createdAt)
    }
}

public struct MemoryLocalCorrectionRecord: Equatable, Sendable {
    public let request: MemoryLocalCorrectionRequest
    public let state: MemoryLocalCorrectionState
    public let revision: Int64
    public let failure: MemoryLocalCorrectionFailure?
    public let userMessage: Message
    public let acknowledgement: Message?
    public let clarification: Message?
    public let updatedAt: Date
    public init(request: MemoryLocalCorrectionRequest, state: MemoryLocalCorrectionState, revision: Int64,
                failure: MemoryLocalCorrectionFailure?, userMessage: Message, acknowledgement: Message?, updatedAt: Date,
                clarification: Message? = nil) {
        self.request = request; self.state = state; self.revision = revision; self.failure = failure
        self.userMessage = userMessage; self.acknowledgement = acknowledgement; self.updatedAt = updatedAt
        self.clarification = clarification
    }
}

public enum MemoryLocalCorrectionClarificationKind: String, Codable, Equatable, Sendable {
    case targetRequired

    public var text: String {
        "Which memory should I change? Please identify the statement you mean. Nothing has been changed."
    }
}

public enum MemoryLocalCorrectionAcknowledgement {
    public static let text = "Got it—your memory update is saved."
}

/// Bounded restart inventory. Command bodies remain in their exact user rows;
/// a marker does not authorize a new submission or a replacement operation.
public struct MemoryLocalCorrectionRecoveryMarker: Equatable, Sendable {
    public let userMessageID: MessageID
    public let operationID: UUID
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let state: MemoryLocalCorrectionState
    public let revision: Int64

    public init(record: MemoryLocalCorrectionRecord) {
        userMessageID = record.request.userMessageID
        operationID = record.request.operationID
        conversationID = record.request.authority.conversationID
        teammateID = record.request.authority.teammateID
        state = record.state
        revision = record.revision
    }
}

public struct MemoryLocalCorrectionRecoveryPage: Equatable, Sendable {
    public let markers: [MemoryLocalCorrectionRecoveryMarker]
    public let hasMore: Bool

    public init(markers: [MemoryLocalCorrectionRecoveryMarker], hasMore: Bool) {
        self.markers = markers; self.hasMore = hasMore
    }
}

public protocol MemoryLocalCorrectionRepository: Sendable {
    /// Stable oldest-first page of admitted/committed-unacknowledged operations.
    /// Valid limits are 1...16. This never retries or repairs an operation.
    func recoverableMemoryLocalCorrections(limit: Int) async throws -> MemoryLocalCorrectionRecoveryPage
    func memoryLocalCorrection(userMessageID: MessageID) async throws -> MemoryLocalCorrectionRecord?
    func admitMemoryLocalCorrection(_ request: MemoryLocalCorrectionRequest, text: String) async throws -> MemoryLocalCorrectionRecord
    func acknowledgeMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                          now: Date) async throws -> MemoryLocalCorrectionRecord
    func clarifyMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                      kind: MemoryLocalCorrectionClarificationKind, now: Date) async throws -> MemoryLocalCorrectionRecord
    func failMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                   failure: MemoryLocalCorrectionFailure, now: Date) async throws -> MemoryLocalCorrectionRecord
}

extension MemoryLocalCorrectionRepository {
    public func clarifyMemoryLocalCorrection(userMessageID: MessageID, expectedRevision: Int64,
                                              kind: MemoryLocalCorrectionClarificationKind, now: Date) async throws -> MemoryLocalCorrectionRecord {
        throw MemoryLocalCorrectionError.invalidState
    }

    /// Inert repositories cannot imply that an unsupported recovery scan is empty.
    public func recoverableMemoryLocalCorrections(limit: Int) async throws -> MemoryLocalCorrectionRecoveryPage {
        throw MemoryLocalCorrectionError.invalidState
    }
}
