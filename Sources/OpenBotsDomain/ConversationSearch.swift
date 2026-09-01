import Foundation

/// Search is local, bounded, and limited to active visible direct conversations.
/// Message terms are literal whole words; profile terms are literal substrings.
public struct ConversationSearchRequest: Equatable, Sendable {
    public static let maximumQueryLength = 200
    public static let maximumQueryUTF8ByteCount = 4_096
    public static let maximumTermCount = 8
    public static let maximumLimit = 50

    public let query: String
    public let limit: Int
    public let terms: [String]

    public init(query: String, limit: Int = 30) throws {
        guard query.utf8.count <= Self.maximumQueryUTF8ByteCount,
              query.count <= Self.maximumQueryLength else {
            throw DomainValidationError.invalid(field: "search query", reason: "must contain at most 200 characters and 4096 UTF-8 bytes")
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { throw DomainValidationError.empty(field: "search query") }
        guard terms.count <= Self.maximumTermCount else {
            throw DomainValidationError.invalid(field: "search query", reason: "must contain at most eight terms")
        }
        guard (1...Self.maximumLimit).contains(limit) else {
            throw DomainValidationError.invalid(field: "search limit", reason: "must be between one and fifty")
        }
        // NUL is not a useful search term and must not depend on tokenizer C-string behavior.
        guard !query.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DomainValidationError.invalid(field: "search query", reason: "cannot contain a null character")
        }
        self.query = query
        self.limit = limit
        self.terms = terms
    }
}

public struct TeammateSearchHit: Equatable, Sendable, Identifiable {
    public var id: TeammateID { teammate.id }
    public let teammate: Teammate
    public let conversationID: ConversationID

    public init(teammate: Teammate, conversationID: ConversationID) {
        self.teammate = teammate
        self.conversationID = conversationID
    }
}

public struct MessageSearchHit: Equatable, Sendable, Identifiable {
    public static let maximumSnippetLength = 500

    public let id: MessageID
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let teammateName: String
    public let author: MessageAuthor
    public let authorName: String
    public let snippet: String
    public let sequence: Int64
    public let createdAt: Date

    public init(
        id: MessageID, conversationID: ConversationID, teammateID: TeammateID,
        teammateName: String, author: MessageAuthor, authorName: String,
        snippet: String, sequence: Int64, createdAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.teammateName = teammateName
        self.author = author
        self.authorName = authorName
        self.snippet = String(snippet.prefix(Self.maximumSnippetLength))
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public struct ConversationSearchPage: Equatable, Sendable {
    public let teammates: [TeammateSearchHit]
    public let messages: [MessageSearchHit]
    public let hasMoreTeammates: Bool
    public let hasMoreMessages: Bool

    public init(
        teammates: [TeammateSearchHit], messages: [MessageSearchHit],
        hasMoreTeammates: Bool, hasMoreMessages: Bool
    ) {
        self.teammates = teammates
        self.messages = messages
        self.hasMoreTeammates = hasMoreTeammates
        self.hasMoreMessages = hasMoreMessages
    }
}

/// A fresh, currently visible target, resolved without loading its transcript.
public struct MessageSearchTarget: Equatable, Sendable {
    public let id: MessageID
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let sequence: Int64
    public let currentTitle: String

    public init(id: MessageID, conversationID: ConversationID, teammateID: TeammateID, sequence: Int64, currentTitle: String) {
        self.id = id
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.sequence = sequence
        self.currentTitle = currentTitle
    }
}

public protocol ConversationSearchRepository: Sendable {
    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage
    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget?
}
