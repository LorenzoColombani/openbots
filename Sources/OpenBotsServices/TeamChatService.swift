import Foundation
import OpenBotsDomain

public struct TeamChatSnapshot: Equatable, Sendable, Identifiable {
    public let team: Team
    public let conversation: Conversation
    /// Active members sorted by display name, then id.
    public let members: [Teammate]

    public var id: TeamID { team.id }
    public var lead: Teammate? { members.first { $0.id == team.leadID } }

    public init(team: Team, conversation: Conversation, members: [Teammate]) {
        self.team = team
        self.conversation = conversation
        self.members = members
    }
}

public struct TeamChatDraft: Equatable, Sendable {
    public let name: String
    public let leadID: TeammateID
    public let memberIDs: Set<TeammateID>

    public init(name: String, leadID: TeammateID, memberIDs: Set<TeammateID>) {
        self.name = name
        self.leadID = leadID
        self.memberIDs = memberIDs
    }
}

/// One saved change to an existing team: its name, its lead and the exact set
/// of members it should hold afterwards.
public struct TeamChatEdit: Equatable, Sendable {
    public let teamID: TeamID
    public let name: String
    public let leadID: TeammateID
    public let memberIDs: Set<TeammateID>
    /// The instant the roster this edit rewrites was read at, which for the
    /// editor is when its sheet was opened, not when Save was pressed. The
    /// write compares against it, so a second writer publishing while the sheet
    /// stood open refuses this save instead of being overwritten by it. Nil
    /// asks the service to guard only its own read-to-write gap.
    public let expectedUpdatedAt: Date?

    public init(teamID: TeamID, name: String, leadID: TeammateID, memberIDs: Set<TeammateID>,
                expectedUpdatedAt: Date? = nil) {
        self.teamID = teamID
        self.name = name
        self.leadID = leadID
        self.memberIDs = memberIDs
        self.expectedUpdatedAt = expectedUpdatedAt
    }
}

public enum TeamChatError: Error, Equatable, Sendable {
    case leadNotMember(TeammateID)
    case tooFewMembers
    case teammateNotFound(TeammateID)
    case teammateNotActive(TeammateID)
    case teamUnavailable(TeamID)
    /// The team moved between the read this edit was derived from and its
    /// write, so the roster the editor computed no longer describes the team.
    case teamChangedElsewhere(TeamID)
}

public protocol TeamChatServing: Sendable {
    func activeTeamChats() async throws -> [TeamChatSnapshot]
    func selectedTeamChat() async throws -> TeamChatSnapshot?
    func select(teamID: TeamID) async throws
    func createTeamChat(_ draft: TeamChatDraft) async throws -> TeamChatSnapshot
    func updateTeamChat(_ edit: TeamChatEdit) async throws -> TeamChatSnapshot
    func teamChat(conversationID: ConversationID) async throws -> TeamChatSnapshot?
}

/// Owns ordering for team chats only. Repositories own durability; the text
/// reply service owns the turn; no runtime, credential or filesystem root is
/// reachable from here.
public actor TeamChatService: TeamChatServing {
    private let teams: any TeamRepository
    private let provisioning: any TeamProvisioningRepository
    private let teamConversations: any TeamConversationRepository
    private let teammates: any TeammateRepository
    private let selection: any ChatSelectionRepository
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator
    /// One counter for every selection intent this service starts, so a newer
    /// one always wins the write. It cannot see a newer *bot* selection, which
    /// the direct service counts separately.
    private var selectionGeneration: UInt64 = 0

    public init(teams: any TeamRepository, provisioning: any TeamProvisioningRepository,
                teamConversations: any TeamConversationRepository, teammates: any TeammateRepository,
                selection: any ChatSelectionRepository,
                clock: any OpenBotsClock = SystemClock(), uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()) {
        self.teams = teams
        self.provisioning = provisioning
        self.teamConversations = teamConversations
        self.teammates = teammates
        self.selection = selection
        self.clock = clock
        self.uuidGenerator = uuidGenerator
    }

    public func activeTeamChats() async throws -> [TeamChatSnapshot] {
        var snapshots: [TeamChatSnapshot] = []
        for team in try await teams.listTeams(includingArchived: false) where team.lifecycle == .active {
            guard let conversation = try await teamConversations.teamConversation(teamID: team.id) else { continue }
            snapshots.append(TeamChatSnapshot(team: team, conversation: conversation, members: try await activeMembers(of: team)))
        }
        return snapshots.sorted { left, right in
            if left.conversation.updatedAt != right.conversation.updatedAt { return left.conversation.updatedAt > right.conversation.updatedAt }
            if left.team.name != right.team.name { return left.team.name < right.team.name }
            return left.team.id.persistedValue < right.team.id.persistedValue
        }
    }

    public func selectedTeamChat() async throws -> TeamChatSnapshot? {
        guard let conversationID = try await selection.selectedConversationID() else { return nil }
        return try await teamChat(conversationID: conversationID)
    }

    public func select(teamID: TeamID) async throws {
        try Task.checkCancellation()
        selectionGeneration &+= 1
        let generation = selectionGeneration
        guard let team = try await teams.team(id: teamID), team.lifecycle == .active,
              let conversation = try await teamConversations.teamConversation(teamID: teamID) else {
            throw TeamChatError.teamUnavailable(teamID)
        }
        try Task.checkCancellation()
        // Validation suspends on repository reads. A newer selection invalidates
        // this older intent before it may reach the write boundary, as the
        // direct chat service already does.
        guard generation == selectionGeneration else { throw CancellationError() }
        try await selection.setSelectedConversationID(conversation.id)
    }

    public func createTeamChat(_ draft: TeamChatDraft) async throws -> TeamChatSnapshot {
        guard draft.memberIDs.count >= 2 else { throw TeamChatError.tooFewMembers }
        guard draft.memberIDs.contains(draft.leadID) else { throw TeamChatError.leadNotMember(draft.leadID) }
        var members: [Teammate] = []
        for memberID in draft.memberIDs.sorted(by: { $0.persistedValue < $1.persistedValue }) {
            guard let teammate = try await teammates.teammate(id: memberID) else { throw TeamChatError.teammateNotFound(memberID) }
            guard teammate.lifecycle == .active else { throw TeamChatError.teammateNotActive(memberID) }
            members.append(teammate)
        }
        let now = clock.now()
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let team = try Team(id: TeamID(uuidGenerator.next()), name: name, leadID: draft.leadID,
                            memberIDs: draft.memberIDs, createdAt: now, updatedAt: now)
        let conversation = try Conversation(id: ConversationID(uuidGenerator.next()), kind: .team(teamID: team.id),
                                            title: name, createdAt: now, updatedAt: now)
        try await provisioning.provisionTeam(team, conversation: conversation, selectConversation: true)
        return TeamChatSnapshot(team: team, conversation: conversation, members: Self.sorted(members))
    }

    /// Rewrites one existing team from the editor. Validation mirrors
    /// `createTeamChat` and then the domain `Team` initialiser; the repository
    /// owns the one transaction that publishes the team, its memberships, the
    /// conversation title and the conversation participants together.
    public func updateTeamChat(_ edit: TeamChatEdit) async throws -> TeamChatSnapshot {
        guard edit.memberIDs.count >= 2 else { throw TeamChatError.tooFewMembers }
        guard edit.memberIDs.contains(edit.leadID) else { throw TeamChatError.leadNotMember(edit.leadID) }
        guard let existing = try await teams.team(id: edit.teamID), existing.lifecycle == .active,
              let conversation = try await teamConversations.teamConversation(teamID: edit.teamID) else {
            throw TeamChatError.teamUnavailable(edit.teamID)
        }
        var members: [Teammate] = []
        for memberID in edit.memberIDs.sorted(by: { $0.persistedValue < $1.persistedValue }) {
            guard let teammate = try await teammates.teammate(id: memberID) else { throw TeamChatError.teammateNotFound(memberID) }
            guard teammate.lifecycle == .active else { throw TeamChatError.teammateNotActive(memberID) }
            members.append(teammate)
        }
        // Members the editor could not draw are carried forward. The sheet is
        // seeded from the active roster, so an archived member is invisible to
        // it; dropping it would let a rename permanently evict a bot that
        // restoring used to bring straight back into the team.
        var retained: Set<TeammateID> = []
        for memberID in existing.memberIDs.subtracting(edit.memberIDs) {
            let teammate = try await teammates.teammate(id: memberID)
            if teammate?.lifecycle != .active { retained.insert(memberID) }
        }
        let name = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A clock that reads before the team was created would fail the
        // domain's timestamp rule; the edit is never older than the row.
        let now = max(clock.now(), existing.createdAt)
        let team = try Team(id: existing.id, name: name, summary: existing.summary, leadID: edit.leadID,
                            memberIDs: edit.memberIDs.union(retained), lifecycle: existing.lifecycle,
                            createdAt: existing.createdAt, updatedAt: now)
        // Only the title changes. Keeping the conversation's own recency means
        // a rename does not push the team to the top of the sidebar.
        let retitled = try Conversation(id: conversation.id, kind: conversation.kind, title: name,
                                        lifecycle: conversation.lifecycle, createdAt: conversation.createdAt,
                                        updatedAt: conversation.updatedAt)
        // The instant the edit was derived from is what the write compares
        // against, so a second writer's edit refuses this one rather than being
        // silently overwritten by it. The editor carries the instant its sheet
        // was opened on, which covers the minutes it stood open; an edit that
        // names none is guarded over this call's own read-to-write gap.
        do {
            try await provisioning.updateTeam(team, conversation: retitled,
                                              expectedUpdatedAt: edit.expectedUpdatedAt ?? existing.updatedAt)
        } catch RepositoryError.optimisticLockFailed {
            throw TeamChatError.teamChangedElsewhere(edit.teamID)
        }
        return TeamChatSnapshot(team: team, conversation: retitled, members: Self.sorted(members))
    }

    public func teamChat(conversationID: ConversationID) async throws -> TeamChatSnapshot? {
        try await activeTeamChats().first { $0.conversation.id == conversationID }
    }

    private func activeMembers(of team: Team) async throws -> [Teammate] {
        var members: [Teammate] = []
        for memberID in team.memberIDs {
            if let teammate = try await teammates.teammate(id: memberID), teammate.lifecycle == .active { members.append(teammate) }
        }
        return Self.sorted(members)
    }

    private static func sorted(_ members: [Teammate]) -> [Teammate] {
        members.sorted {
            if $0.profile.displayName != $1.profile.displayName { return $0.profile.displayName < $1.profile.displayName }
            return $0.id.persistedValue < $1.id.persistedValue
        }
    }
}
