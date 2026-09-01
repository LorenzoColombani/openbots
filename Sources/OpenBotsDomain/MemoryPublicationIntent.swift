import Foundation

/// The trusted application authorizes publication. Decoded model output is not
/// an actor, evidence receipt, or permission to write memory.
public enum MemoryPublicationActor: Codable, Equatable, Sendable {
    case user(messageID: MessageID)
    case app(verifierID: String)
}

/// The digest covers the exact UTF-8 bytes of one durable user text part. This
/// permits a correction without requiring a completed provider reply first.
public struct MemoryPublicationUserMessageEvidence: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let contentDigest: String
    public let updatedAt: Date

    public init(messageID: MessageID, contentDigest: String, updatedAt: Date) throws {
        guard MemoryPublicationIntent.isDigest(contentDigest), updatedAt.timeIntervalSince1970.isFinite else {
            throw MemoryPublicationError.invalidIntent
        }
        self.messageID = messageID; self.contentDigest = contentDigest; self.updatedAt = updatedAt
    }
}

/// Body-free, immutable publication metadata. Filesystem verification and
/// evidence interpretation belong to the trusted application service. SQLite
/// independently rechecks the durable source stamps and scope at admission.
public struct MemoryPublicationIntent: Codable, Equatable, Sendable, Identifiable {
    public static let maximumBytes = 16_384
    public static let maximumEvidenceMessages = 16
    public static let maximumWithdrawnClaims = 256
    public let id: UUID
    public let document: MemoryDocument
    public let expectedPredecessor: MemoryDocument?
    public let authority: ReadContextReceipt
    public let actor: MemoryPublicationActor
    public let evidenceDigest: String
    public let policyDigest: String
    public let byteCount: Int
    public let userMessageEvidence: [MemoryPublicationUserMessageEvidence]
    /// A digest-bound projection of withdrawn claim IDs in the artifact. A
    /// successor must retain these IDs; restoration needs a separate contract.
    public let withdrawnClaimIDs: [UUID]
    public let createdAt: Date

    public var stagingRelativePath: String {
        let parent = document.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        return parent + "/.openbots-stage-" + id.uuidString.lowercased() + ".tmp"
    }

    public init(id: UUID, document: MemoryDocument, expectedPredecessor: MemoryDocument?,
                authority: ReadContextReceipt, actor: MemoryPublicationActor,
                evidenceDigest: String, policyDigest: String, byteCount: Int,
                userMessageEvidence: [MemoryPublicationUserMessageEvidence] = [],
                withdrawnClaimIDs: [UUID] = [], createdAt: Date) throws {
        // Codable and mutable titles must not bypass the ordinary document contract.
        for value in [document, expectedPredecessor].compactMap({ $0 }) {
            let checked = try MemoryDocument(id: value.id, scope: value.scope, author: value.author,
                title: value.title, relativePath: value.relativePath, revision: value.revision,
                contentDigest: value.contentDigest, supersedes: value.supersedes,
                createdAt: value.createdAt, updatedAt: value.updatedAt)
            guard checked.title.utf8.elementsEqual(value.title.utf8),
                  checked.relativePath.utf8.elementsEqual(value.relativePath.utf8) else {
                throw MemoryPublicationError.invalidIntent
            }
        }
        guard (1...Self.maximumBytes).contains(byteCount), Self.isDigest(document.contentDigest),
              Self.isDigest(evidenceDigest), Self.isDigest(policyDigest),
              document.revision <= UInt64(Int64.max),
              document.updatedAt.timeIntervalSince1970.isFinite,
              document.createdAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970.isFinite, createdAt == document.updatedAt,
              document.createdAt <= document.updatedAt,
              userMessageEvidence.count <= Self.maximumEvidenceMessages,
              Set(userMessageEvidence.map(\.messageID)).count == userMessageEvidence.count,
              withdrawnClaimIDs.count <= Self.maximumWithdrawnClaims,
              Set(withdrawnClaimIDs).count == withdrawnClaimIDs.count else {
            throw MemoryPublicationError.invalidIntent
        }
        let scopePath: String
        switch document.scope {
        case .user: throw MemoryPublicationError.authorityChanged
        case .teammate(let owner):
            guard owner == authority.teammateID else { throw MemoryPublicationError.authorityChanged }
            scopePath = "Teammates/" + owner.persistedValue
        case .project(let project):
            guard project == authority.selectedProjectID, authority.projectMembershipJoinedAt != nil else {
                throw MemoryPublicationError.authorityChanged
            }
            scopePath = "Projects/" + project.persistedValue
        }
        let expectedPath = "Documents/\(scopePath)/\(document.id.persistedValue)-r\(document.revision).md"
        guard document.relativePath == expectedPath,
              document.supersedes == expectedPredecessor?.id else { throw MemoryPublicationError.invalidIntent }
        if let predecessor = expectedPredecessor {
            guard predecessor.scope == document.scope, predecessor.revision < UInt64(Int64.max),
                  document.revision == predecessor.revision + 1,
                  document.createdAt == predecessor.createdAt,
                  Self.isDigest(predecessor.contentDigest) else { throw MemoryPublicationError.invalidIntent }
        } else if document.revision != 1 {
            throw MemoryPublicationError.invalidIntent
        }
        for evidence in userMessageEvidence {
            guard Self.isDigest(evidence.contentDigest), evidence.updatedAt.timeIntervalSince1970.isFinite else {
                throw MemoryPublicationError.invalidIntent
            }
        }
        switch actor {
        case .user(let messageID):
            guard document.author == .user,
                  userMessageEvidence.contains(where: { $0.messageID == messageID }) else {
                throw MemoryPublicationError.invalidEvidence
            }
        case .app(let verifierID):
            guard document.author == .system, !verifierID.isEmpty, verifierID.utf8.count <= 128,
                  verifierID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
                throw MemoryPublicationError.invalidEvidence
            }
        }
        self.id = id; self.document = document; self.expectedPredecessor = expectedPredecessor
        self.authority = authority; self.actor = actor; self.evidenceDigest = evidenceDigest
        self.policyDigest = policyDigest; self.byteCount = byteCount
        self.userMessageEvidence = userMessageEvidence; self.withdrawnClaimIDs = withdrawnClaimIDs
        self.createdAt = createdAt
    }

    /// Recheck decoded metadata: synthesized Codable is never admission.
    public func validated() throws -> Self {
        try Self(id: id, document: document, expectedPredecessor: expectedPredecessor,
                 authority: authority, actor: actor, evidenceDigest: evidenceDigest,
                 policyDigest: policyDigest, byteCount: byteCount, userMessageEvidence: userMessageEvidence,
                 withdrawnClaimIDs: withdrawnClaimIDs, createdAt: createdAt)
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Deliberately not Codable. The host supplies this only after rechecking the
/// exact artifact and registered evidence; reading an intent cannot mint it.
public struct MemoryPublicationValidation: Equatable, Sendable {
    public let authority: ReadContextReceipt
    public let evidenceDigest: String
    public let policyDigest: String
    public let contentDigest: String
    public let byteCount: Int

    public init(authority: ReadContextReceipt, evidenceDigest: String, policyDigest: String,
                contentDigest: String, byteCount: Int) {
        self.authority = authority; self.evidenceDigest = evidenceDigest; self.policyDigest = policyDigest
        self.contentDigest = contentDigest; self.byteCount = byteCount
    }
}

public enum MemoryPublicationState: String, Codable, Equatable, Sendable { case pending, committed, aborted }

public struct MemoryPublicationIntentRecord: Equatable, Sendable {
    public let intent: MemoryPublicationIntent
    public let state: MemoryPublicationState
    public let revision: Int64
    public let updatedAt: Date

    public init(intent: MemoryPublicationIntent, state: MemoryPublicationState, revision: Int64, updatedAt: Date) {
        self.intent = intent; self.state = state; self.revision = revision; self.updatedAt = updatedAt
    }
}

public enum MemoryPublicationError: Error, Equatable, Sendable {
    case invalidIntent, invalidEvidence, authorityChanged, stalePredecessor
    case conflictingOperation, invalidStoredState, notFound, invalidTransition, invalidLimit, withdrawnClaim
}

public protocol MemoryPublicationIntentRepository: Sendable {
    func prepareMemoryPublication(_ intent: MemoryPublicationIntent) async throws -> MemoryPublicationIntentRecord
    func memoryPublication(id: UUID) async throws -> MemoryPublicationIntentRecord?
    func committedMemoryPublication(documentID: MemoryDocumentID) async throws -> MemoryPublicationIntentRecord?
    func pendingMemoryPublications(limit: Int) async throws -> [MemoryPublicationIntentRecord]
    func commitMemoryPublication(id: UUID, expectedRevision: Int64, validation: MemoryPublicationValidation,
                                 now: Date) async throws -> MemoryPublicationIntentRecord
    func abortMemoryPublication(id: UUID, expectedRevision: Int64, now: Date) async throws -> MemoryPublicationIntentRecord
    func memoryPublicationBlocksUse(documentID: MemoryDocumentID) async throws -> Bool
    func withdrawnMemoryClaimIDs(documentID: MemoryDocumentID) async throws -> [UUID]
}

extension MemoryPublicationIntentRepository {
    /// Missing durable publication support is not proof of a committed claim.
    public func committedMemoryPublication(documentID: MemoryDocumentID) async throws -> MemoryPublicationIntentRecord? { nil }
}
