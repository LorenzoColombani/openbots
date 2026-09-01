import Foundation

/// An explicit, repeatable navigation request. The view checks both IDs after
/// its next layout turn, so a stale jump cannot move a different conversation.
public struct TranscriptSearchFocus: Equatable, Sendable {
    public let requestID = UUID()
    public let conversationID: UUID
    public let messageID: UUID
}

struct TranscriptTailScrollRequest: Equatable {
    let conversationID: UUID?
    let searchRequestID: UUID?
    let latestRequestID: UUID?
    let tailID: UUID

    func matches(conversationID: UUID?, searchRequestID: UUID?, latestRequestID: UUID?, tailID: UUID?) -> Bool {
        self.conversationID != nil && self.conversationID == conversationID
            && self.searchRequestID == nil && searchRequestID == nil
            && self.latestRequestID == latestRequestID && self.tailID == tailID
    }
}
