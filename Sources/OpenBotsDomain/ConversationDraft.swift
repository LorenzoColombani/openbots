import Foundation

/// One persisted composer value. Whitespace and all valid UTF-8 are exact;
/// an empty string is a durable tombstone, not permission to remove the row.
/// Inline secret-card fields and attachment source URLs are not part of this
/// model. Absence is represented by nil, never by a revision-zero snapshot.
public struct ConversationDraftSnapshot: Equatable, Sendable, Codable {
    public static let maximumUTF8ByteCount = 1_048_576

    public let conversationID: ConversationID
    public let text: String
    public let revision: UInt64
    public let updatedAt: Date

    public init(conversationID: ConversationID, text: String, revision: UInt64, updatedAt: Date) throws {
        guard text.utf8.count <= Self.maximumUTF8ByteCount else {
            throw DomainValidationError.tooLong(
                field: "conversation draft UTF-8 bytes", maximum: Self.maximumUTF8ByteCount
            )
        }
        guard revision > 0, revision <= UInt64(Int64.max) else {
            throw ConversationDraftError.invalidRevision
        }
        guard updatedAt.timeIntervalSince1970.isFinite else {
            throw ConversationDraftError.invalidTimestamp
        }
        self.conversationID = conversationID
        self.text = text
        self.revision = revision
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID, text, revision, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            conversationID: values.decode(ConversationID.self, forKey: .conversationID),
            text: values.decode(String.self, forKey: .text),
            revision: values.decode(UInt64.self, forKey: .revision),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversationID == rhs.conversationID &&
        lhs.text.utf8.elementsEqual(rhs.text.utf8) &&
        lhs.revision == rhs.revision && lhs.updatedAt == rhs.updatedAt
    }
}

public enum ConversationDraftError: Error, Equatable, Sendable {
    case conversationNotFound
    case conversationArchived
    case staleRevision
    case invalidRevision
    case invalidTimestamp
}

public protocol ConversationDraftRepository: Sendable {
    func loadDraft(conversationID: ConversationID) async throws -> ConversationDraftSnapshot?

    /// Expected revision zero means no row exists. Every successful write,
    /// including an empty tombstone, returns the next positive revision.
    /// Conflicts never overwrite or retry automatically.
    func saveDraft(
        conversationID: ConversationID, text: String,
        expectedRevision: UInt64, updatedAt: Date
    ) async throws -> ConversationDraftSnapshot
}
