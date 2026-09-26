import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// Bots that hire bots: the service that turns one call of the
/// hire tool into a teammate, or into a refusal the model and the person read.
/// Over the real store, the real chat and team services and the real switches.
@Suite("Hiring a teammate from a bot's reply")
struct TeammateHiringServiceTests {
    @Test("A granted hire makes a sealed teammate with the hirer's seat, its own desk and chat, and leaves the selection where it was")
    func aHireMakesASealedTeammate() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let switches = await f.grantedSwitches()
        let desks = HiringDeskSpy()
        let service = f.service(store, switches: switches, desks: desks)
        let selectedBefore = try await store.selectedConversationID()

        let outcome = await service.hire(try f.submission(toolUseID: "toolu_1", arguments: [
            "handle": "Scout", "purpose": "Price watching", "instructions": "Check the three shops daily.",
            "purview": "Competitor prices", "never": "Bookkeeping, which Ledger owns",
            "interfaces": "Ledger, for costs", "escalate": "Any spend"]))
        guard case .hired(let hire) = outcome else { Issue.record("not hired: \(outcome)"); return }
        #expect(hire.name == "Scout" && hire.purpose == "Price watching" && !hire.joinedTeam)

        let scout = try #require(try await store.teammate(id: hire.teammateID))
        #expect(scout.lifecycle == .active)
        #expect(scout.profile.displayName == "Scout")
        #expect(scout.profile.role == "Price watching")
        #expect(scout.profile.detailedInstructions == "Check the three shops daily.")
        #expect(scout.profile.seat == (try TeammateSeat(purview: "Competitor prices", never: "Bookkeeping, which Ledger owns",
                                                         interfaces: "Ledger, for costs", escalate: "Any spend")))
        // Kite's reply wrote that profile, and the person has not reviewed it.
        #expect(scout.profileWrittenByHirer == "Kite")
        // Born the way a bot made in the New Bot sheet is born.
        #expect(scout.appearance == (try CreatureAllocation(id: hire.teammateID.rawValue).appearance()))
        // Its own chat, and the person's selection untouched.
        let chats = try await store.conversations(for: hire.teammateID, includingArchived: false)
        #expect(chats.contains { conversation in
            if case .direct(let owner) = conversation.kind { return owner == hire.teammateID }
            return false
        })
        #expect(try await store.selectedConversationID() == selectedBefore)
        // Sealed: no switch of any kind, and its desk made.
        let access = await switches.current(teammateID: hire.teammateID)
        #expect(access.work == .off || !access.work.botEnabled)
        #expect(!access.work.botEnabled && !access.webSearch.botEnabled && !access.webFetch.botEnabled && !access.hire.botEnabled)
        #expect(!(await switches.hireGranted(teammateID: hire.teammateID)))
        #expect(await desks.teammateIDs == [hire.teammateID])
        // At the top of the sidebar, like a bot made by hand.
        #expect(try await store.loadBotSidebarOrder().teammateIDs.first == hire.teammateID)
        #expect(await service.finishReply(f.replyID) == [outcome])
    }

    @Test("Both switches are read at the call: the bot's own off or the app-wide off refuses and creates nothing, and on again hires")
    func switchesAreReadAtTheCall() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let switches = await f.grantedSwitches()
        let service = f.service(store, switches: switches)
        let before = try await store.listTeammates(includingArchived: true).count

        await switches.setBotEnabled(false, capability: .hire, teammateID: f.kite)
        #expect(await service.hire(try f.submission(toolUseID: "toolu_1", arguments: ["handle": "Scout", "purpose": "Prices"]))
            == .refused(.switchedOff))
        await switches.setBotEnabled(true, capability: .hire, teammateID: f.kite)
        await switches.setAppEnabled(false, capability: .hire)
        #expect(await service.hire(try f.submission(toolUseID: "toolu_2", arguments: ["handle": "Scout", "purpose": "Prices"]))
            == .refused(.switchedOff))
        #expect(try await store.listTeammates(includingArchived: true).count == before)
        await switches.setAppEnabled(true, capability: .hire)
        #expect(await service.hire(try f.submission(toolUseID: "toolu_3", arguments: ["handle": "Scout", "purpose": "Prices"])).isHire)
    }

    @Test("A reply that began with hiring on keeps it to the end: switching it off takes effect when that reply ends")
    func aReplyKeepsItsHireSwitches() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let switches = await f.grantedSwitches()
        let service = f.service(store, switches: switches)
        await switches.setBotEnabled(false, capability: .hire, teammateID: f.kite)
        let held = try f.submission(toolUseID: "toolu_1", arguments: ["handle": "Scout", "purpose": "Prices"])
        let forTheReply = TeammateHireSubmission(replyID: held.replyID, toolUseID: held.toolUseID, hirerID: held.hirerID,
            conversationID: held.conversationID, argumentsJSON: held.argumentsJSON, isOwnCall: held.isOwnCall,
            grantedForTheReply: true)
        #expect(await service.hire(forTheReply).isHire)
    }

    @Test("Three calls a reply, refused ones counted; a repeat of one tool use gets its first answer and makes nothing; the next reply starts again")
    func threeCallsAReply() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store, switches: await f.grantedSwitches())

        #expect(await service.hire(try f.submission(toolUseID: "toolu_1", arguments: ["handle": "2 scouts", "purpose": "Prices"]))
            == .refused(.invalidHandle))
        #expect(await service.hire(try f.submission(toolUseID: "toolu_2", arguments: ["handle": "ledger", "purpose": "Books"]))
            == .refused(.nameTaken(existingName: "Ledger")))
        let hired = await service.hire(try f.submission(toolUseID: "toolu_3", arguments: ["handle": "Scout", "purpose": "Prices"]))
        #expect(hired.isHire)
        #expect(await service.hire(try f.submission(toolUseID: "toolu_4", arguments: ["handle": "Pixel", "purpose": "Design"]))
            == .refused(.tooManyCalls))
        #expect(await service.hire(try f.submission(toolUseID: "toolu_3", arguments: ["handle": "Scout", "purpose": "Prices"])) == hired)
        let names = try await store.listTeammates(includingArchived: true).map(\.profile.displayName)
        #expect(names.filter { $0 == "Scout" }.count == 1)
        #expect(!names.contains("Pixel"))
        let outcomes = await service.finishReply(f.replyID)
        #expect(outcomes == [.refused(.invalidHandle), .refused(.nameTaken(existingName: "Ledger")), hired, .refused(.tooManyCalls)])
        #expect(await service.finishReply(f.replyID).isEmpty, "a finished reply keeps nothing")

        let next = UUID()
        #expect(await service.hire(try f.submission(replyID: next, toolUseID: "toolu_9", arguments: ["handle": "Pixel", "purpose": "Design"])).isHire)
    }

    @Test("One name rule: a handle another bot holds in any case is refused, and one handle twice in a reply makes one bot")
    func oneNameRule() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store, switches: await f.grantedSwitches())
        #expect(await service.hire(try f.submission(toolUseID: "toolu_1", arguments: ["handle": "Scout", "purpose": "Prices"])).isHire)
        #expect(await service.hire(try f.submission(toolUseID: "toolu_2", arguments: ["handle": "SCOUT", "purpose": "Prices again"]))
            == .refused(.nameTaken(existingName: "Scout")))
        #expect(try await store.listTeammates(includingArchived: true).filter { TeammateProfile.namesMatch($0.profile.displayName, "scout") }.count == 1)
    }

    /// An archived bot has given its name up for the New Bot sheet, which
    /// already skips its default names; a hire that took one would block that
    /// bot's restore, and the person never chose the newcomer's name.
    @Test("A handle an archived bot holds is refused, creates nothing, and leaves that bot free to be restored")
    func anArchivedBotsNameIsNotTaken() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store, switches: await f.grantedSwitches())
        let ledger = try #require(try await store.teammate(id: f.ledger))
        let archived = try await store.archiveTeammate(id: f.ledger, expectedProfileRevision: ledger.profile.revision,
                                                       now: f.date.addingTimeInterval(10))
        #expect(await service.hire(try f.submission(toolUseID: "toolu_1", arguments: ["handle": "LEDGER", "purpose": "Books"]))
            == .refused(.nameArchived(existingName: "Ledger")))
        #expect(try await store.listTeammates(includingArchived: true).count == 2, "nothing created")
        let restored = try await store.restoreTeammate(id: f.ledger, expectedProfileRevision: archived.profile.revision,
                                                       now: f.date.addingTimeInterval(20))
        #expect(restored.lifecycle == .active)
    }

    /// The store lets an archived bot's name be taken, so the hire's stricter
    /// rule rests on reading the roster: a hire that cannot read it cannot
    /// know the name is free, and makes nothing.
    @Test("A hire that cannot read the roster creates nothing, so an archived bot's name is never taken unchecked")
    func anUnreadableRosterMakesNothing() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let ledger = try #require(try await store.teammate(id: f.ledger))
        _ = try await store.archiveTeammate(id: f.ledger, expectedProfileRevision: ledger.profile.revision,
                                            now: f.date.addingTimeInterval(10))
        let chats = DurableTeammateChatService(teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store)
        let service = TeammateHiringService(access: await f.grantedSwitches(),
                                            teammates: RosterUnreadableTeammates(inner: store),
                                            conversations: store, chats: chats)
        #expect(await service.hire(try f.submission(toolUseID: "toolu_1", arguments: ["handle": "Ledger", "purpose": "Books"]))
            == .refused(.notCreated))
        #expect(try await store.listTeammates(includingArchived: true).count == 2, "nothing created")
    }

    /// The hire stands when the join fails. The lead must then
    /// hear that the newcomer is not on the team, or it briefs a bot no
    /// handoff in this conversation can reach.
    @Test("A hire from a team conversation that cannot join the team stands, and the tool result says it could not join")
    func aFailedJoinIsToldToTheModel() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let teams = TeamChatService(teams: store, provisioning: store, teamConversations: store, teammates: store, selection: store)
        let service = f.service(store, switches: await f.grantedSwitches(), teamChats: JoinRefusingTeamChats(inner: teams))
        let outcome = await service.hire(try f.submission(conversationID: f.teamChat, toolUseID: "toolu_1",
                                                          arguments: ["handle": "Scout", "purpose": "Prices"]))
        guard case .hired(let hire) = outcome else { Issue.record("not hired: \(outcome)"); return }
        #expect(!hire.joinedTeam && hire.couldNotJoinTeam)
        #expect(try await store.team(id: f.teamID)?.memberIDs == [f.kite, f.ledger])
        #expect(outcome.toolResultText.contains("Scout could not join this team"), "\(outcome.toolResultText)")
        #expect(!outcome.toolResultText.contains("joined this team"))
        // A hire in a one-to-one chat had no team to join and says nothing of one.
        let direct = await service.hire(try f.submission(replyID: UUID(), toolUseID: "toolu_2",
                                                         arguments: ["handle": "Pixel", "purpose": "Design"]))
        guard case .hired(let alone) = direct else { Issue.record("not hired: \(direct)"); return }
        #expect(!alone.couldNotJoinTeam && !direct.toolResultText.contains("join"))
    }

    @Test("A call a helper made, or one no reply of the bot announced, is refused and creates nothing")
    func onlyTheBotItselfHires() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store, switches: await f.grantedSwitches())
        #expect(await service.hire(try f.submission(toolUseID: "toolu_1", arguments: ["handle": "Scout", "purpose": "Prices"], isOwnCall: false))
            == .refused(.notTheBot))
        #expect(try await store.listTeammates(includingArchived: true).count == 2)
    }

    /// Two calls for one name at once make one bot. The
    /// provisioning is held open, so the second call arrives while the first
    /// is still being created.
    @Test("Two hire calls for one name at once make one bot; the other is refused as taken")
    func twoCallsForOneNameAtOnceMakeOneBot() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let chats = DurableTeammateChatService(teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store)
        let slow = SlowTeammateChats(inner: chats)
        let service = TeammateHiringService(access: await f.grantedSwitches(), teammates: store, conversations: store,
                                            chats: slow)
        let one = try f.submission(toolUseID: "toolu_1", arguments: ["handle": "Scout", "purpose": "Prices"])
        let other = try f.submission(replyID: UUID(), toolUseID: "toolu_2", arguments: ["handle": "Scout", "purpose": "Prices"])
        async let first = service.hire(one)
        async let second = service.hire(other)
        let outcomes = await [first, second]
        #expect(outcomes.filter(\.isHire).count == 1, "\(outcomes)")
        #expect(outcomes.contains(.refused(.nameTaken(existingName: "Scout"))), "\(outcomes)")
        #expect(try await store.listTeammates(includingArchived: true)
            .filter { TeammateProfile.namesMatch($0.profile.displayName, "Scout") }.count == 1)
        #expect(await slow.creations == 1, "the second call never reached provisioning")
    }

    @Test("A hire from a team conversation joins that team, lead and name unchanged; the hirer archived meanwhile cannot hire")
    func aTeamHireJoinsTheTeam() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = f.service(store, switches: await f.grantedSwitches())
        let outcome = await service.hire(try f.submission(conversationID: f.teamChat, toolUseID: "toolu_1",
                                                          arguments: ["handle": "Scout", "purpose": "Prices"]))
        guard case .hired(let hire) = outcome else { Issue.record("not hired: \(outcome)"); return }
        #expect(hire.joinedTeam)
        let team = try #require(try await store.team(id: f.teamID))
        #expect(team.memberIDs == [f.kite, f.ledger, hire.teammateID])
        #expect(team.leadID == f.kite && team.name == "QA Team")

        let archived = try #require(try await store.teammate(id: f.kite))
        _ = try await store.archiveTeammate(id: f.kite, expectedProfileRevision: archived.profile.revision, now: f.date.addingTimeInterval(10))
        #expect(await service.hire(try f.submission(replyID: UUID(), toolUseID: "toolu_2", arguments: ["handle": "Pixel", "purpose": "Design"]))
            == .refused(.hirerUnavailable))
    }
}

/// The real chat service, held open for a moment before it creates a bot, so a
/// second call can arrive while the first is still being made.
private actor SlowTeammateChats: TeammateChatProvisioning {
    let inner: DurableTeammateChatService
    private(set) var creations = 0
    init(inner: DurableTeammateChatService) { self.inner = inner }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft,
                                     selectConversation: Bool) async throws -> DurableTeammateChatCreationSnapshot {
        creations += 1
        try await Task.sleep(for: .milliseconds(200))
        return try await inner.createTeammateAndDirectChat(draft, selectConversation: selectConversation)
    }
}

/// The real store, except that the roster cannot be listed; one bot by id still reads.
private struct RosterUnreadableTeammates: TeammateRepository {
    struct Unreadable: Error {}
    let inner: SQLiteStore
    func teammate(id: TeammateID) async throws -> Teammate? { try await inner.teammate(id: id) }
    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { throw Unreadable() }
    func insert(_ teammate: Teammate) async throws { try await inner.insert(teammate) }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        try await inner.update(teammate, expectedProfileRevision: expectedProfileRevision)
    }
}

/// The real team service, except that every roster write fails: a join that cannot land.
private struct JoinRefusingTeamChats: TeamChatServing {
    let inner: TeamChatService
    func activeTeamChats() async throws -> [TeamChatSnapshot] { try await inner.activeTeamChats() }
    func selectedTeamChat() async throws -> TeamChatSnapshot? { try await inner.selectedTeamChat() }
    func select(teamID: TeamID) async throws { try await inner.select(teamID: teamID) }
    func createTeamChat(_ draft: TeamChatDraft) async throws -> TeamChatSnapshot { try await inner.createTeamChat(draft) }
    func updateTeamChat(_ edit: TeamChatEdit) async throws -> TeamChatSnapshot { throw TeamChatError.teamUnavailable(edit.teamID) }
    func teamChat(conversationID: ConversationID) async throws -> TeamChatSnapshot? {
        try await inner.teamChat(conversationID: conversationID)
    }
}

actor HiringDeskSpy: TeammateDeskProvisioning {
    private(set) var teammateIDs: [TeammateID] = []
    func workspace(teammateID: TeammateID) async throws -> BotWorkspace {
        teammateIDs.append(teammateID)
        return BotWorkspace(homeURL: URL(fileURLWithPath: "/private/tmp/hiring-desk.noindex/\(teammateID.persistedValue)"), folders: [])
    }
}

struct HiringFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let kite = TeammateID(UUID()), ledger = TeammateID(UUID())
    let kiteChat = ConversationID(UUID()), teamID = TeamID(UUID()), teamChat = ConversationID(UUID())
    let replyID = UUID()
    let date = Date(timeIntervalSince1970: 4_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextHiring-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }

    /// Kite, whose chat is selected, and Ledger; both on the QA Team, Kite leading.
    func seed(_ store: SQLiteStore) async throws {
        for (id, chat, name, selected) in [(kite, kiteChat, "Kite", true), (ledger, ConversationID(UUID()), "Ledger", false)] {
            let bot = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: "Teammate"),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                    paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest",
                    accessibleIdentityDescription: "Round creature with a crest"),
                createdAt: date, updatedAt: date)
            try await store.provisionDirectChat(teammate: bot,
                conversation: Conversation(id: chat, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                fixtureGreeting: nil, selectConversation: selected)
        }
        try await store.provisionTeam(Team(id: teamID, name: "QA Team", leadID: kite, memberIDs: [kite, ledger], createdAt: date, updatedAt: date),
            conversation: Conversation(id: teamChat, kind: .team(teamID: teamID), title: "QA Team", createdAt: date, updatedAt: date),
            selectConversation: false)
    }

    /// Both hire switches on for Kite.
    func grantedSwitches() async -> AgenticJobAccessStore {
        let switches = AgenticJobAccessStore(reportWriteFailure: { _ in })
        await switches.setAppEnabled(true, capability: .hire)
        await switches.setBotEnabled(true, capability: .hire, teammateID: kite)
        return switches
    }

    func service(_ store: SQLiteStore, switches: AgenticJobAccessStore,
                 desks: (any TeammateDeskProvisioning)? = nil,
                 teamChats: (any TeamChatServing)? = nil) -> TeammateHiringService {
        let chats = DurableTeammateChatService(teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store)
        let teams = TeamChatService(teams: store, provisioning: store, teamConversations: store, teammates: store, selection: store)
        return TeammateHiringService(access: switches, teammates: store, conversations: store, chats: chats,
                                     desks: desks, teamChats: teamChats ?? teams)
    }

    func submission(replyID: UUID? = nil, conversationID: ConversationID? = nil, toolUseID: String,
                    arguments: [String: Any], isOwnCall: Bool = true) throws -> TeammateHireSubmission {
        TeammateHireSubmission(replyID: replyID ?? self.replyID, toolUseID: toolUseID, hirerID: kite,
            conversationID: conversationID ?? kiteChat,
            argumentsJSON: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            isOwnCall: isOwnCall)
    }
}
