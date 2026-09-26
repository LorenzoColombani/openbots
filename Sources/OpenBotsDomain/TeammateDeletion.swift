import Foundation

public enum TeammateDeleteError: Error, Equatable, Sendable {
    case notFound
    case staleRevision
    case unresolvedWork
    case isTeamLead(teamName: String)
    case invalidDate
}

/// What is left of a bot deleted while its words stay in a team chat: its row, emptied and
/// marked deleted, so those messages keep an author. It is in no list and
/// nothing brings it back; its messages read under this name.
public enum DeletedTeammate {
    public static let displayName = "Deleted bot"
    /// A neutral role the profile's rules accept (migration 24's word).
    public static let role = "Teammate"
}

/// What the confirmation names before the person deletes a bot. Workspace and
/// published project artifacts are separate exact choices; this receipt
/// only covers the bot-owned graph that Delete removes.
public struct TeammateDeleteInventory: Equatable, Sendable {
    public let displayName: String
    public let hasProfile: Bool
    public let conversationCount: Int
    public let memoryDocumentCount: Int
    public let membershipCount: Int
    public let hasProfileAsset: Bool
    public let botHomePath: String?
    public let skillsPath: String?
    /// The bot spoke or took part in a team chat, so what it said and did
    /// there stays, under the name "Deleted bot".
    public let keepsTeamHistory: Bool

    public init(
        displayName: String,
        hasProfile: Bool,
        conversationCount: Int,
        memoryDocumentCount: Int,
        membershipCount: Int,
        hasProfileAsset: Bool,
        botHomePath: String?,
        skillsPath: String?,
        keepsTeamHistory: Bool = false
    ) {
        self.displayName = displayName
        self.hasProfile = hasProfile
        self.conversationCount = conversationCount
        self.memoryDocumentCount = memoryDocumentCount
        self.membershipCount = membershipCount
        self.hasProfileAsset = hasProfileAsset
        self.botHomePath = botHomePath
        self.skillsPath = skillsPath
        self.keepsTeamHistory = keepsTeamHistory
    }
}

public protocol TeammateDeletionRepository: Sendable {
    func inventory(id: TeammateID) async throws -> TeammateDeleteInventory
    /// Removes the bot and its owned graph. Refuses when the bot leads a team
    /// or still has unresolved work. Does not silently assign a new lead. A
    /// bot with team chat history is kept instead as an emptied row marked
    /// deleted, its team chat messages and handoffs staying under "Deleted bot".
    func deleteTeammate(id: TeammateID, expectedProfileRevision: UInt64, now: Date) async throws -> Teammate
    /// Every bot Delete kept only for its team chat history.
    func deletedTeammateIDs() async throws -> Set<TeammateID>
}
