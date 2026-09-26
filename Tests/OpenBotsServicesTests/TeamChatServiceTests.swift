import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private struct TeamClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private final class TeamUUIDs: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]
    init(_ values: [UUID]) { self.values = values }
    func next() -> UUID { lock.lock(); defer { lock.unlock() }; return values.removeFirst() }
}

private actor TeamChatRepositoryFake: TeamRepository, TeamProvisioningRepository, TeamConversationRepository,
                                       TeammateRepository, ChatSelectionRepository {
    private var teammates: [TeammateID: Teammate]
    private(set) var teams: [TeamID: Team] = [:]
    private(set) var conversations: [TeamID: Conversation] = [:]
    private(set) var selection: ConversationID?
    private(set) var provisionCount = 0
    private(set) var lastSelectConversation: Bool?

    init(teammates: [Teammate]) { self.teammates = Dictionary(uniqueKeysWithValues: teammates.map { ($0.id, $0) }) }

    func seed(team: Team, conversation: Conversation?) {
        teams[team.id] = team
        if let conversation { conversations[team.id] = conversation }
    }
    func teammate(id: TeammateID) async throws -> Teammate? { teammates[id] }
    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { Array(teammates.values) }
    func insert(_ teammate: Teammate) async throws { teammates[teammate.id] = teammate }
    func add(teammate: Teammate) { teammates[teammate.id] = teammate }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws { teammates[teammate.id] = teammate }
    func team(id: TeamID) async throws -> Team? { teams[id] }
    func listTeams(includingArchived: Bool) async throws -> [Team] {
        teams.values.filter { includingArchived || $0.lifecycle == .active }.sorted { $0.name < $1.name }
    }
    func insert(_ team: Team) async throws { teams[team.id] = team }
    func update(_ team: Team) async throws { teams[team.id] = team }
    func provisionTeam(_ team: Team, conversation: Conversation, selectConversation: Bool) async throws {
        provisionCount += 1
        lastSelectConversation = selectConversation
        teams[team.id] = team
        conversations[team.id] = conversation
        if selectConversation { selection = conversation.id }
    }
    private(set) var updateCount = 0
    private(set) var lastUpdatedConversation: Conversation?
    private(set) var lastExpectedUpdatedAt: Date?
    /// Compare-and-set, the way SQLite writes it: the row this edit was derived
    /// from is the row it may overwrite.
    func updateTeam(_ team: Team, conversation: Conversation, expectedUpdatedAt: Date) async throws {
        guard let held = teams[team.id] else { throw RepositoryError.notFound(entity: "team", id: team.id.persistedValue) }
        lastExpectedUpdatedAt = expectedUpdatedAt
        guard held.updatedAt == expectedUpdatedAt else {
            throw RepositoryError.optimisticLockFailed(entity: "team", id: team.id.persistedValue)
        }
        updateCount += 1
        teams[team.id] = team
        conversations[team.id] = conversation
        lastUpdatedConversation = conversation
    }
    private var heldTeam: TeamID?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isHolding: Bool { !waiters.isEmpty }
    /// Suspends the conversation read for one team, so a second selection can
    /// overtake the first between its validation and its write.
    func hold(teamID: TeamID) { heldTeam = teamID }
    func release() {
        heldTeam = nil
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func teamConversation(teamID: TeamID) async throws -> Conversation? {
        if heldTeam == teamID {
            await withCheckedContinuation { waiters.append($0) }
        }
        return conversations[teamID]
    }
    func activeParticipantIDs(conversationID: ConversationID) async throws -> Set<TeammateID> {
        guard let team = conversations.first(where: { $0.value.id == conversationID }).map({ teams[$0.key] }) ?? nil else { return [] }
        return team.memberIDs
    }
    func selectedConversationID() async throws -> ConversationID? { selection }
    func setSelectedConversationID(_ conversationID: ConversationID?) async throws { selection = conversationID }
}

@Suite("Team chat service")
struct TeamChatServiceTests {
    let date = Date(timeIntervalSince1970: 500)
    func bot(_ name: String, seed: UInt64 = 1, lifecycle: TeammateLifecycle = .active) throws -> Teammate {
        try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: "Role"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: seed, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "crest", accessibleIdentityDescription: "Round"),
            lifecycle: lifecycle, createdAt: date, updatedAt: date)
    }
    fileprivate func service(_ repository: TeamChatRepositoryFake, uuids: [UUID] = [UUID(), UUID()]) -> TeamChatService {
        TeamChatService(teams: repository, provisioning: repository, teamConversations: repository,
                        teammates: repository, selection: repository, clock: TeamClock(value: date), uuidGenerator: TeamUUIDs(uuids))
    }

    @Test("Creating a team provisions the aggregate once, selects it, and answers with the lead and members")
    func createProvisionsAndSelects() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada])
        let teamID = UUID(), conversationID = UUID()
        let created = try await service(repository, uuids: [teamID, conversationID])
            .createTeamChat(TeamChatDraft(name: "  QA Team ", leadID: mira.id, memberIDs: [mira.id, ada.id]))
        #expect(created.team.id == TeamID(teamID))
        #expect(created.team.name == "QA Team")
        #expect(created.team.leadID == mira.id)
        #expect(created.conversation.id == ConversationID(conversationID))
        #expect(created.conversation.kind == .team(teamID: created.team.id))
        #expect(created.conversation.title == "QA Team")
        #expect(created.members.map(\.profile.displayName) == ["Ada", "Mira"])
        #expect(created.lead?.id == mira.id)
        #expect(await repository.provisionCount == 1)
        #expect(await repository.lastSelectConversation == true)
        #expect(await repository.selection == created.conversation.id)
    }

    @Test("A lead outside the members, fewer than two members, or an inactive member refuse before provisioning",
          arguments: ["leadOutside", "single", "archived", "missing"])
    func refusals(_ mode: String) async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), old = try bot("Old", seed: 3, lifecycle: .archived)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, old])
        let s = service(repository)
        let draft: TeamChatDraft
        let expected: TeamChatError
        switch mode {
        case "leadOutside": draft = TeamChatDraft(name: "QA", leadID: mira.id, memberIDs: [ada.id, old.id]); expected = .leadNotMember(mira.id)
        case "single": draft = TeamChatDraft(name: "QA", leadID: mira.id, memberIDs: [mira.id]); expected = .tooFewMembers
        case "archived": draft = TeamChatDraft(name: "QA", leadID: mira.id, memberIDs: [mira.id, old.id]); expected = .teammateNotActive(old.id)
        default:
            let ghost = TeammateID(UUID())
            draft = TeamChatDraft(name: "QA", leadID: mira.id, memberIDs: [mira.id, ghost]); expected = .teammateNotFound(ghost)
        }
        await #expect(throws: expected) { try await s.createTeamChat(draft) }
        #expect(await repository.provisionCount == 0)
        #expect(await repository.selection == nil)
    }

    @Test("Editing writes the team through the aggregate and answers with the new name, roster and lead")
    func editRewritesTheTeam() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), zed = try bot("Zed", seed: 3)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, zed])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date.addingTimeInterval(90))
        await repository.seed(team: team, conversation: chat)

        let saved = try await service(repository).updateTeamChat(TeamChatEdit(
            teamID: team.id, name: "  Research Team ", leadID: zed.id, memberIDs: [mira.id, zed.id]))

        #expect(saved.team.id == team.id)
        #expect(saved.team.name == "Research Team")
        #expect(saved.team.leadID == zed.id)
        #expect(saved.team.memberIDs == [mira.id, zed.id])
        #expect(saved.team.createdAt == team.createdAt)
        #expect(saved.members.map(\.profile.displayName) == ["Mira", "Zed"])
        #expect(saved.lead?.id == zed.id)
        #expect(saved.conversation.title == "Research Team")
        // A rename is not message activity, so the conversation keeps the
        // recency that orders the sidebar.
        #expect(saved.conversation.updatedAt == chat.updatedAt)
        #expect(await repository.updateCount == 1)
        #expect(await repository.lastUpdatedConversation?.title == "Research Team")
        #expect(await repository.teams[team.id]?.memberIDs == [mira.id, zed.id])
        // The roster was derived from the team as it was read, so that is the
        // instant the write is allowed to overwrite.
        #expect(await repository.lastExpectedUpdatedAt == team.updatedAt)
    }

    @Test("A rename keeps an archived member the editor could not show, and its restored bot returns to the roster")
    func editKeepsMembersTheEditorCannotShow() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), old = try bot("Old", seed: 3, lifecycle: .archived)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, old])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id,
                            memberIDs: [mira.id, ada.id, old.id], createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date)
        await repository.seed(team: team, conversation: chat)

        // The sheet is seeded from the active roster, so the archived bot is
        // not in the submitted member set. It must survive anyway.
        let saved = try await service(repository).updateTeamChat(TeamChatEdit(
            teamID: team.id, name: "Research Team", leadID: mira.id, memberIDs: [mira.id, ada.id]))
        #expect(saved.team.memberIDs == [mira.id, ada.id, old.id])
        // The snapshot still reports the active roster only.
        #expect(saved.members.map(\.profile.displayName) == ["Ada", "Mira"])
        #expect(await repository.teams[team.id]?.memberIDs == [mira.id, ada.id, old.id])
    }

    @Test("Deselecting an active member does remove it")
    func editRemovesADeselectedActiveMember() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date)
        await repository.seed(team: team, conversation: chat)
        let extra = try bot("Zed", seed: 4)
        await repository.add(teammate: extra)

        let saved = try await service(repository).updateTeamChat(TeamChatEdit(
            teamID: team.id, name: "QA Team", leadID: mira.id, memberIDs: [mira.id, extra.id]))
        #expect(saved.team.memberIDs == [mira.id, extra.id])
        #expect(saved.members.map(\.profile.displayName) == ["Mira", "Zed"])
    }

    @Test("An edit is refused before any write when it breaks the team rules or names no live team",
          arguments: ["single", "leadOutside", "archived", "missing", "noTeam", "noConversation"])
    func editRefusals(_ mode: String) async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), old = try bot("Old", seed: 3, lifecycle: .archived)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, old])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date)
        let ghostTeam = try Team(id: TeamID(UUID()), name: "Ghost", leadID: mira.id, memberIDs: [mira.id, ada.id],
                                 createdAt: date, updatedAt: date)
        await repository.seed(team: team, conversation: chat)
        await repository.seed(team: ghostTeam, conversation: nil)

        let edit: TeamChatEdit
        let expected: TeamChatError
        switch mode {
        case "single":
            edit = TeamChatEdit(teamID: team.id, name: "QA", leadID: mira.id, memberIDs: [mira.id])
            expected = .tooFewMembers
        case "leadOutside":
            edit = TeamChatEdit(teamID: team.id, name: "QA", leadID: old.id, memberIDs: [mira.id, ada.id])
            expected = .leadNotMember(old.id)
        case "archived":
            edit = TeamChatEdit(teamID: team.id, name: "QA", leadID: mira.id, memberIDs: [mira.id, old.id])
            expected = .teammateNotActive(old.id)
        case "missing":
            let ghost = TeammateID(UUID())
            edit = TeamChatEdit(teamID: team.id, name: "QA", leadID: mira.id, memberIDs: [mira.id, ghost])
            expected = .teammateNotFound(ghost)
        case "noTeam":
            let absent = TeamID(UUID())
            edit = TeamChatEdit(teamID: absent, name: "QA", leadID: mira.id, memberIDs: [mira.id, ada.id])
            expected = .teamUnavailable(absent)
        default:
            edit = TeamChatEdit(teamID: ghostTeam.id, name: "QA", leadID: mira.id, memberIDs: [mira.id, ada.id])
            expected = .teamUnavailable(ghostTeam.id)
        }
        await #expect(throws: expected) { try await service(repository).updateTeamChat(edit) }
        #expect(await repository.updateCount == 0)
        #expect(await repository.teams[team.id]?.name == "QA Team")
        #expect(await repository.teams[team.id]?.memberIDs == [mira.id, ada.id])
    }

    @Test("An archived team is not editable")
    func archivedTeamIsNotEditable() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            lifecycle: .archived, createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date)
        await repository.seed(team: team, conversation: chat)
        await #expect(throws: TeamChatError.teamUnavailable(team.id)) {
            try await service(repository).updateTeamChat(TeamChatEdit(
                teamID: team.id, name: "Research", leadID: mira.id, memberIDs: [mira.id, ada.id]))
        }
        #expect(await repository.updateCount == 0)
    }

    @Test("An edit whose team moved between the read and the write is refused, and writes nothing")
    func editRefusedWhenTheTeamMovedElsewhere() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), zed = try bot("Zed", seed: 3)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, zed])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date)
        await repository.seed(team: team, conversation: chat)

        // The conversation read is the gap between this edit's read of the team
        // and its write, which is exactly where a second writer lands.
        let s = service(repository)
        await repository.hold(teamID: team.id)
        let stale = Task {
            try await s.updateTeamChat(TeamChatEdit(
                teamID: team.id, name: "Research Team", leadID: mira.id, memberIDs: [mira.id, ada.id]))
        }
        for _ in 0..<400 where !(await repository.isHolding) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await repository.isHolding)

        // Another writer publishes a roster this edit never saw.
        let rival = try Team(id: team.id, name: "Rival Team", leadID: mira.id, memberIDs: [mira.id, zed.id],
                             createdAt: date, updatedAt: date.addingTimeInterval(60))
        await repository.seed(team: rival, conversation: chat)
        await repository.release()

        await #expect(throws: TeamChatError.teamChangedElsewhere(team.id)) { try await stale.value }
        // Zed is not revoked and Ada is not resurrected: the rival roster stands.
        #expect(await repository.updateCount == 0)
        #expect(await repository.teams[team.id]?.name == "Rival Team")
        #expect(await repository.teams[team.id]?.memberIDs == [mira.id, zed.id])
    }

    @Test("An edit carries the instant its roster was read, so a save after a refusal cannot overwrite the other writer")
    func editCarriesTheInstantItsRosterWasRead() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), zed = try bot("Zed", seed: 3)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, zed])
        let team = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: "QA Team",
                                    createdAt: date, updatedAt: date)
        await repository.seed(team: team, conversation: chat)
        let s = service(repository)

        // The editor was opened on this roster; another writer publishes theirs
        // while it is on screen. The service's own read now returns the rival,
        // so only the instant the sheet carries can refuse this save.
        let seeded = team.updatedAt
        let rival = try Team(id: team.id, name: "Rival Team", leadID: mira.id, memberIDs: [mira.id, zed.id],
                             createdAt: date, updatedAt: date.addingTimeInterval(60))
        await repository.seed(team: rival, conversation: chat)
        await #expect(throws: TeamChatError.teamChangedElsewhere(team.id)) {
            try await s.updateTeamChat(TeamChatEdit(teamID: team.id, name: "Research Team", leadID: mira.id,
                                                    memberIDs: [mira.id, ada.id], expectedUpdatedAt: seeded))
        }
        #expect(await repository.updateCount == 0)
        #expect(await repository.teams[team.id]?.name == "Rival Team")
        #expect(await repository.teams[team.id]?.memberIDs == [mira.id, zed.id])

        // An editor reopened on the rival roster carries its instant and saves.
        let saved = try await s.updateTeamChat(TeamChatEdit(teamID: team.id, name: "Research Team", leadID: mira.id,
                                                           memberIDs: [mira.id, zed.id],
                                                           expectedUpdatedAt: rival.updatedAt))
        #expect(saved.team.name == "Research Team")
        #expect(await repository.updateCount == 1)
        #expect(await repository.teams[team.id]?.memberIDs == [mira.id, zed.id])
    }

    @Test("Listing shows only active teams that have a conversation, and the saved selection maps to its team")
    func listingAndSelection() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada])
        let withChat = try Team(id: TeamID(UUID()), name: "Alpha", leadID: mira.id, memberIDs: [mira.id, ada.id], createdAt: date, updatedAt: date)
        let chat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: withChat.id), title: "Alpha", createdAt: date, updatedAt: date)
        let withoutChat = try Team(id: TeamID(UUID()), name: "Beta", leadID: mira.id, memberIDs: [mira.id, ada.id], createdAt: date, updatedAt: date)
        let archived = try Team(id: TeamID(UUID()), name: "Gamma", leadID: mira.id, memberIDs: [mira.id, ada.id], lifecycle: .archived, createdAt: date, updatedAt: date)
        let archivedChat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: archived.id), createdAt: date, updatedAt: date)
        await repository.seed(team: withChat, conversation: chat)
        await repository.seed(team: withoutChat, conversation: nil)
        await repository.seed(team: archived, conversation: archivedChat)
        let s = service(repository)
        let listed = try await s.activeTeamChats()
        #expect(listed.map(\.team.name) == ["Alpha"])
        #expect(try await s.selectedTeamChat() == nil)
        try await s.select(teamID: withChat.id)
        #expect(await repository.selection == chat.id)
        #expect(try await s.selectedTeamChat()?.team.id == withChat.id)
        #expect(try await s.teamChat(conversationID: chat.id)?.team.id == withChat.id)
        await #expect(throws: TeamChatError.teamUnavailable(withoutChat.id)) { try await s.select(teamID: withoutChat.id) }
    }

    @Test("Listing orders by newest conversation, then name, then id")
    func listingOrdersByRecencyThenNameThenID() async throws {
        let mira = try bot("Mira")
        let repository = TeamChatRepositoryFake(teammates: [mira])
        @discardableResult
        func seedTeam(_ name: String, id: TeamID = TeamID(UUID()), updatedAt seconds: TimeInterval) async throws -> TeamID {
            let team = try Team(id: id, name: name, leadID: mira.id, memberIDs: [mira.id], createdAt: date, updatedAt: date)
            let conversationUpdatedAt = Date(timeIntervalSince1970: seconds)
            let conversation = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: name,
                createdAt: conversationUpdatedAt, updatedAt: conversationUpdatedAt)
            await repository.seed(team: team, conversation: conversation)
            return team.id
        }
        try await seedTeam("Zeta", updatedAt: 300)
        try await seedTeam("Beta", updatedAt: 100)
        try await seedTeam("Alpha", updatedAt: 100)
        let s = service(repository)
        #expect(try await s.activeTeamChats().map(\.team.name) == ["Zeta", "Alpha", "Beta"])

        let firstID = TeamID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondID = TeamID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        try await seedTeam("Tie", id: secondID, updatedAt: 200)
        try await seedTeam("Tie", id: firstID, updatedAt: 200)
        let listed = try await s.activeTeamChats()
        #expect(listed.map(\.team.name) == ["Zeta", "Tie", "Tie", "Alpha", "Beta"])
        #expect(listed[1].team.id == firstID)
        #expect(listed[2].team.id == secondID)
    }

    @Test("Listing shows only active members and a nil lead when the lead is archived")
    func listingFiltersArchivedMembersAndLead() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2), old = try bot("Old", seed: 3, lifecycle: .archived)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada, old])

        let ledByMira = try Team(id: TeamID(UUID()), name: "Alpha", leadID: mira.id, memberIDs: [mira.id, ada.id, old.id], createdAt: date, updatedAt: date)
        let miraChat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: ledByMira.id), title: "Alpha", createdAt: date, updatedAt: date)
        await repository.seed(team: ledByMira, conversation: miraChat)

        let ledByOld = try Team(id: TeamID(UUID()), name: "Beta", leadID: old.id, memberIDs: [old.id, ada.id], createdAt: date, updatedAt: date)
        let oldChat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: ledByOld.id), title: "Beta", createdAt: date, updatedAt: date)
        await repository.seed(team: ledByOld, conversation: oldChat)

        let s = service(repository)
        let listed = try await s.activeTeamChats()

        let miraSnapshot = listed.first { $0.team.id == ledByMira.id }
        #expect(miraSnapshot?.members.map(\.profile.displayName) == ["Ada", "Mira"])
        #expect(miraSnapshot?.lead?.id == mira.id)

        let oldSnapshot = listed.first { $0.team.id == ledByOld.id }
        #expect(oldSnapshot?.members == [ada])
        #expect(oldSnapshot?.lead == nil)
    }

    @Test("A team selection overtaken by a newer one is refused instead of overwriting it")
    func supersededTeamSelectionIsNotPersisted() async throws {
        let mira = try bot("Mira"), ada = try bot("Ada", seed: 2)
        let repository = TeamChatRepositoryFake(teammates: [mira, ada])
        let alpha = try Team(id: TeamID(UUID()), name: "Alpha", leadID: mira.id, memberIDs: [mira.id, ada.id],
                             createdAt: date, updatedAt: date)
        let alphaChat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: alpha.id),
                                         title: "Alpha", createdAt: date, updatedAt: date)
        let beta = try Team(id: TeamID(UUID()), name: "Beta", leadID: mira.id, memberIDs: [mira.id, ada.id],
                            createdAt: date, updatedAt: date)
        let betaChat = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: beta.id),
                                        title: "Beta", createdAt: date, updatedAt: date)
        await repository.seed(team: alpha, conversation: alphaChat)
        await repository.seed(team: beta, conversation: betaChat)

        let s = service(repository)
        await repository.hold(teamID: alpha.id)
        let superseded = Task { try await s.select(teamID: alpha.id) }
        for _ in 0..<400 where !(await repository.isHolding) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await repository.isHolding)

        try await s.select(teamID: beta.id)
        #expect(await repository.selection == betaChat.id)
        await repository.release()
        await #expect(throws: CancellationError.self) { try await superseded.value }
        #expect(await repository.selection == betaChat.id)
    }
}
