import Foundation

/// Navigation order is independent of profiles, pin metadata and content.
public struct BotSidebarOrder: Equatable, Sendable {
    public let teammateIDs: [TeammateID]
    public let revision: UInt64

    public init(teammateIDs: [TeammateID], revision: UInt64) {
        self.teammateIDs = teammateIDs
        self.revision = revision
    }
}

public enum BotSidebarOrderError: Error, Equatable, Sendable {
    case staleRevision
    case invalidMembership
    case revisionExhausted
}

/// Saves are atomic full-roster permutations. Membership and revision are
/// checked together, so a stale drag cannot discard a newly created bot.
public protocol BotSidebarOrderRepository: Sendable {
    func loadBotSidebarOrder() async throws -> BotSidebarOrder
    func saveBotSidebarOrder(_ ids: [TeammateID], expectedRevision: UInt64) async throws -> BotSidebarOrder
}
