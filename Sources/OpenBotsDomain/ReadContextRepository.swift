import Foundation

/// Fixed storage-read ceilings, distinct from the assembler's smaller prompt budget.
public enum ReadContextLimits {
    public static let recentMessages = 12
    public static let olderMessages = 12
    public static let messageUTF8Bytes = 8_192
    public static let memoryHeadsPerScope = 8
    public static let searchTerms = 8
    public static let searchInputUTF8Bytes = 4_096
    public static let searchTermUTF8Bytes = 128
}

public enum ReadContextError: Error, Equatable, Sendable {
    case invalidRequest, unavailable, staleReferences, invalidStoredRecord
}

/// Identity and scope are expected values, never a caller-supplied membership grant.
/// `beforeSequence` is exclusive and prevents a newly submitted turn entering itself.
public struct ReadContextRequest: Equatable, Sendable {
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let profileRevision: UInt64
    public let selection: ConversationContextSelection
    public let beforeSequence: Int64
    public let searchTerms: [String]

    public init(conversationID: ConversationID, teammateID: TeammateID, profileRevision: UInt64,
                selection: ConversationContextSelection, beforeSequence: Int64,
                searchTerms: [String] = []) throws {
        guard selection.conversationID == conversationID, selection.teammateID == teammateID,
              profileRevision > 0, profileRevision <= UInt64(Int64.max), beforeSequence > 0,
              selection.revision <= UInt64(Int64.max), searchTerms.count <= ReadContextLimits.searchTerms,
              searchTerms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= ReadContextLimits.searchTermUTF8Bytes
                  && !$0.unicodeScalars.contains(where: { $0.value == 0 }) }) else {
            throw ReadContextError.invalidRequest
        }
        self.conversationID = conversationID; self.teammateID = teammateID
        self.profileRevision = profileRevision; self.selection = selection
        self.beforeSequence = beforeSequence; self.searchTerms = searchTerms
    }

    /// Bounded literal keywords only. This is not another model call or a semantic index.
    public static func literalSearchTerms(from input: String) -> [String] {
        let bounded = String(decoding: input.utf8.prefix(ReadContextLimits.searchInputUTF8Bytes), as: UTF8.self)
        let words = bounded.unicodeScalars.split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
        let stopwords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "could",
            "did", "do", "does", "for", "from", "had", "has", "have", "how", "i", "in", "is", "it", "its", "me", "my",
            "of", "on", "or", "our", "please", "that", "the", "their", "them", "there", "these", "they", "this", "to",
            "us", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your"]
        var result: [String] = []
        var seen: Set<String> = []
        for scalars in words {
            let word = String(String.UnicodeScalarView(scalars))
            guard word.utf8.count <= ReadContextLimits.searchTermUTF8Bytes,
                  !stopwords.contains(word.lowercased()),
                  seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
            if result.count == ReadContextLimits.searchTerms { break }
        }
        return result
    }
}

/// Path-free correlation and source stamps. A digest proves equality, not authority.
public struct ReadContextMessageReference: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let runID: RunID
    public let runRevision: Int64
    public let runUpdatedAt: Date
    public let sequence: Int64
    public let messageUpdatedAt: Date
    public let selectedProjectID: ProjectID?
    public let contentDigest: String
    /// Nil in old receipts means unknown, never proven independent. The live
    /// repository derives this from bounded transitive run/memory ancestry.
    public let memoryQualificationRequired: Bool?

    public init(messageID: MessageID, runID: RunID, runRevision: Int64, runUpdatedAt: Date,
                sequence: Int64, messageUpdatedAt: Date, selectedProjectID: ProjectID?, contentDigest: String,
                memoryQualificationRequired: Bool? = false) {
        self.messageID = messageID; self.runID = runID; self.runRevision = runRevision
        self.runUpdatedAt = runUpdatedAt; self.sequence = sequence; self.messageUpdatedAt = messageUpdatedAt
        self.selectedProjectID = selectedProjectID; self.contentDigest = contentDigest
        self.memoryQualificationRequired = memoryQualificationRequired
    }
}

public struct ReadContextMemoryReference: Codable, Equatable, Sendable {
    public let documentID: MemoryDocumentID
    public let scope: MemoryScope
    public let revision: UInt64
    public let contentDigest: String
    /// Covers all admitted metadata, including title/path, without persisting them here.
    public let metadataDigest: String

    public init(documentID: MemoryDocumentID, scope: MemoryScope, revision: UInt64,
                contentDigest: String, metadataDigest: String) {
        self.documentID = documentID; self.scope = scope; self.revision = revision
        self.contentDigest = contentDigest; self.metadataDigest = metadataDigest
    }
}

/// A frozen read receipt, not a capability. Every use requires fresh repository
/// validation; Codable supports a private durable run audit without storing bodies/paths.
public struct ReadContextReceipt: Codable, Equatable, Sendable {
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let profileRevision: UInt64
    public let contextRevision: UInt64
    public let selectedProjectID: ProjectID?
    public let selectedTeamID: TeamID?
    public let participantJoinedAt: Date
    public let projectMembershipJoinedAt: Date?
    public let teamMembershipJoinedAt: Date?
    public let messages: [ReadContextMessageReference]
    public let memoryDocuments: [ReadContextMemoryReference]
    public let qualificationVersion: UInt16?
    public let claimReferences: [MemoryClaimReference]?

    public var selection: ConversationContextSelection {
        ConversationContextSelection(conversationID: conversationID, teammateID: teammateID,
            projectID: selectedProjectID, teamID: selectedTeamID, revision: contextRevision)
    }

    public init(conversationID: ConversationID, teammateID: TeammateID, profileRevision: UInt64,
                contextRevision: UInt64, selectedProjectID: ProjectID?, selectedTeamID: TeamID?,
                participantJoinedAt: Date, projectMembershipJoinedAt: Date?, teamMembershipJoinedAt: Date?,
                messages: [ReadContextMessageReference], memoryDocuments: [ReadContextMemoryReference],
                qualificationVersion: UInt16? = nil, claimReferences: [MemoryClaimReference]? = nil) {
        self.conversationID = conversationID; self.teammateID = teammateID; self.profileRevision = profileRevision
        self.contextRevision = contextRevision; self.selectedProjectID = selectedProjectID; self.selectedTeamID = selectedTeamID
        self.participantJoinedAt = participantJoinedAt; self.projectMembershipJoinedAt = projectMembershipJoinedAt
        self.teamMembershipJoinedAt = teamMembershipJoinedAt; self.messages = messages; self.memoryDocuments = memoryDocuments
        self.qualificationVersion = qualificationVersion; self.claimReferences = claimReferences
    }

    /// Select only fragments actually included in the assembled payload. Cannot add,
    /// duplicate or relabel a source. Final validation still checks every retained stamp.
    public func selecting(messageIDs: [MessageID], memoryDocumentIDs memoryIDs: [MemoryDocumentID]) throws -> Self {
        guard messageIDs.count <= ReadContextLimits.recentMessages + ReadContextLimits.olderMessages,
              memoryIDs.count <= 3 * ReadContextLimits.memoryHeadsPerScope,
              Set(messageIDs).count == messageIDs.count, Set(memoryIDs).count == memoryIDs.count else {
            throw ReadContextError.invalidRequest
        }
        let selectedMessages = try messageIDs.map { id in
            guard let reference = messages.first(where: { $0.messageID == id }) else { throw ReadContextError.invalidRequest }
            return reference
        }
        let selectedMemory = try memoryIDs.map { id in
            guard let reference = memoryDocuments.first(where: { $0.documentID == id }) else { throw ReadContextError.invalidRequest }
            return reference
        }
        return Self(conversationID: conversationID, teammateID: teammateID, profileRevision: profileRevision,
            contextRevision: contextRevision, selectedProjectID: selectedProjectID, selectedTeamID: selectedTeamID,
            participantJoinedAt: participantJoinedAt, projectMembershipJoinedAt: projectMembershipJoinedAt,
            teamMembershipJoinedAt: teamMembershipJoinedAt, messages: selectedMessages, memoryDocuments: selectedMemory,
            qualificationVersion: qualificationVersion,
            claimReferences: claimReferences?.filter { memoryIDs.contains($0.documentID) })
    }

    public func qualifying(with references: [MemoryClaimReference]) throws -> Self {
        guard references.count <= 96, Set(references).count == references.count,
              references.allSatisfy({ claim in memoryDocuments.contains {
                  $0.documentID == claim.documentID && $0.revision == claim.documentRevision
                      && $0.contentDigest == claim.contentDigest
              } }) else { throw ReadContextError.invalidRequest }
        for reference in references { try MemoryClaimValidation.reference(reference) }
        return Self(conversationID: conversationID, teammateID: teammateID, profileRevision: profileRevision,
            contextRevision: contextRevision, selectedProjectID: selectedProjectID, selectedTeamID: selectedTeamID,
            participantJoinedAt: participantJoinedAt, projectMembershipJoinedAt: projectMembershipJoinedAt,
            teamMembershipJoinedAt: teamMembershipJoinedAt, messages: messages, memoryDocuments: memoryDocuments,
            qualificationVersion: 1, claimReferences: references)
    }
}

/// The assembler uses the selected subset; this is the same durable, path-free receipt.
public typealias ReadContextReferences = ReadContextReceipt

public struct ReadContextMessage: Equatable, Sendable, Identifiable {
    public var id: MessageID { reference.messageID }
    public var sequence: Int64 { reference.sequence }
    public let author: MessageAuthor
    public let text: String
    public let reference: ReadContextMessageReference

    /// Repository output contains only succeeded, acknowledged and completed text turns.
    public init(author: MessageAuthor, text: String, reference: ReadContextMessageReference) {
        self.author = author; self.text = text; self.reference = reference
    }
}

public struct ReadContextOmissions: Equatable, Sendable {
    /// Only candidates examined in bounded windows are counted, never a full history count.
    public let excludedMessageLowerBound: Int
    public let recentWindowHasMore: Bool
    public let olderWindowHasMore: Bool
    public let memoryWindowHasMore: Bool
    public let excludedMemoryLowerBound: Int

    public init(excludedMessageLowerBound: Int = 0, recentWindowHasMore: Bool = false,
                olderWindowHasMore: Bool = false, memoryWindowHasMore: Bool = false,
                excludedMemoryLowerBound: Int = 0) {
        self.excludedMessageLowerBound = excludedMessageLowerBound; self.recentWindowHasMore = recentWindowHasMore
        self.olderWindowHasMore = olderWindowHasMore; self.memoryWindowHasMore = memoryWindowHasMore
        self.excludedMemoryLowerBound = excludedMemoryLowerBound
    }
}

public struct ReadContextSnapshot: Equatable, Sendable {
    public let receipt: ReadContextReceipt
    public let recentMessages: [ReadContextMessage]
    public let olderMessages: [ReadContextMessage]
    public let memoryDocuments: [MemoryDocument]
    public let omissions: ReadContextOmissions

    public init(receipt: ReadContextReceipt, recentMessages: [ReadContextMessage], olderMessages: [ReadContextMessage],
                memoryDocuments: [MemoryDocument], omissions: ReadContextOmissions) {
        self.receipt = receipt; self.recentMessages = recentMessages; self.olderMessages = olderMessages
        self.memoryDocuments = memoryDocuments; self.omissions = omissions
    }
}

public protocol ReadContextRepository: Sendable {
    func loadReadContextCandidates(_ request: ReadContextRequest) async throws -> ReadContextSnapshot
    func revalidateReadContext(_ receipt: ReadContextReceipt) async throws
}
