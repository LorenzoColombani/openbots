import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

@Suite("Teammate navigation and deletion")
struct SQLiteTeammateNavigationDeletionTests {
    @Test("Pin and hide persist without revising the profile")
    func pinAndHide() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let navigation = TeammateNavigationService(repository: store, clock: NavDeleteClock(date: f.at(5)))

        let pinned = try await navigation.setPinned(
            id: original.id, pinned: true, expectedProfileRevision: original.profile.revision
        )
        #expect(pinned.isPinned)
        #expect(pinned.profile.revision == original.profile.revision)

        let hidden = try await navigation.setHidden(
            id: original.id, hidden: true, expectedProfileRevision: pinned.profile.revision
        )
        #expect(hidden.isHidden)
        #expect(hidden.isPinned)
        #expect(try await navigation.hiddenTeammates().map(\.id) == [original.id])
        #expect(try await store.teammate(id: original.id)?.profile.revision == original.profile.revision)
    }

    @Test("Delete removes the bot and refuses when it leads a team")
    func deleteAndLeadRefusal() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let deletion = TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)))

        let inventory = try await deletion.inventory(id: original.id)
        #expect(inventory.displayName == original.profile.displayName)
        #expect(inventory.hasProfile)

        _ = try await deletion.deleteTeammate(
            id: original.id, expectedProfileRevision: original.profile.revision
        )
        #expect(try await store.teammate(id: original.id) == nil)
        #expect(try await store.listTeammates(includingArchived: true).isEmpty)
        // No team history: nothing of the bot is kept, not even a Deleted bot.
        #expect(try await store.deletedTeammateIDs().isEmpty)
        #expect(try await f.count(store, "teammates", "id", original.id.persistedValue) == 0)
        #expect(try await f.foreignKeyProblems(store).isEmpty)

        // Lead refusal on a fresh bot that leads a team.
        let f2 = try NavDeleteFixture(); defer { f2.remove() }
        let store2 = try f2.open()
        let lead = try await f2.seed(store2, asLead: true)
        await #expect(throws: TeammateDeleteError.isTeamLead(teamName: "Lead Team")) {
            try await store2.deleteTeammate(
                id: lead.id, expectedProfileRevision: lead.profile.revision, now: f2.at(9)
            )
        }
        #expect(try await store2.teammate(id: lead.id) == lead)
    }

    @Test("Delete takes the bot's own switches with it and leaves every other switch")
    func deleteRemovesTheBotsSwitches() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let otherBot = TeammateID(UUID())
        for capability in [AgenticWebSwitchCapability.work, .webSearch] {
            try await store.setBotWebSwitch(capability, enabled: true, teammateID: original.id)
            try await store.setBotWebSwitch(capability, enabled: true, teammateID: otherBot)
        }
        try await store.setAppWebSwitch(.work, enabled: true)

        _ = try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)))
            .deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision)

        let switches = try await store.loadWebSwitches()
        #expect(switches.bots[original.id] == nil)
        #expect(switches.bots[otherBot] == [.work, .webSearch])
        #expect(switches.app == [.work])
    }

    /// Found live: the records of a bot's own runs point at
    /// the runs without cascading, so a bot that had ever replied through Claude
    /// or run Work could not be deleted. The earlier fixture bots had no runs.
    @Test("Delete removes a bot that has run real turns, with every record of its runs")
    func deleteRemovesABotWithRealRuns() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let asked = try await f.seedMessage(store, conversationID: f.conversationID, authorID: nil, sequence: 1)
        _ = try await f.seedMessage(store, conversationID: f.conversationID, authorID: original.id, sequence: 2)
        let run = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: f.conversationID,
                                              initiatingMessageID: asked)

        _ = try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)))
            .deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision)

        #expect(try await store.teammate(id: original.id) == nil)
        for (table, column) in NavDeleteFixture.runRecords {
            #expect(try await f.count(store, table, column, run.runID) == 0, "\(table) still holds the run")
        }
        #expect(try await f.count(store, "action_proposal_events", "proposal_id", run.proposalID) == 0)
    }

    /// Sessions were dropped before the delete was tried, so a refused delete
    /// still cost the bot every saved Claude conversation.
    @Test("A bot's saved sessions are dropped only once the delete has happened")
    func sessionsDropOnlyAfterTheDelete() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let lead = try await f.seed(store, asLead: true)
        let refused = RecordingSessionRetention(store: store)
        await #expect(throws: TeammateDeleteError.isTeamLead(teamName: "Lead Team")) {
            try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)), sessionRetention: refused)
                .deleteTeammate(id: lead.id, expectedProfileRevision: lead.profile.revision)
        }
        #expect(await refused.dropped.isEmpty)

        let g = try NavDeleteFixture(); defer { g.remove() }
        let store2 = try g.open()
        let bot = try await g.seed(store2)
        let deleted = RecordingSessionRetention(store: store2)
        _ = try await TeammateDeletionService(repository: store2, clock: NavDeleteClock(date: g.at(8)), sessionRetention: deleted)
            .deleteTeammate(id: bot.id, expectedProfileRevision: bot.profile.revision)
        #expect(await deleted.dropped == [bot.id])
        #expect(await deleted.botStillSaved == [false])
    }

    /// Delete left a bot's connector grants in `connector_access_v1` (found
    /// live). They go through the connector store after the
    /// delete, as saved sessions do; a refused delete keeps them.
    @Test("A bot's connector grants are forgotten only once the delete has happened")
    func grantsForgottenOnlyAfterTheDelete() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let lead = try await f.seed(store, asLead: true)
        let refused = RecordingGrantForgetter(store: store)
        await #expect(throws: TeammateDeleteError.isTeamLead(teamName: "Lead Team")) {
            try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)), connectorGrants: refused)
                .deleteTeammate(id: lead.id, expectedProfileRevision: lead.profile.revision)
        }
        #expect(await refused.forgotten.isEmpty)

        let g = try NavDeleteFixture(); defer { g.remove() }
        let store2 = try g.open()
        let bot = try await g.seed(store2)
        let deleted = RecordingGrantForgetter(store: store2)
        _ = try await TeammateDeletionService(repository: store2, clock: NavDeleteClock(date: g.at(8)), connectorGrants: deleted)
            .deleteTeammate(id: bot.id, expectedProfileRevision: bot.profile.revision)
        #expect(await deleted.forgotten == [bot.id])
        #expect(await deleted.botStillSaved == [false])
    }

    /// Delete goes
    /// through for a bot that spoke in a team chat, and its team chat messages
    /// stay under the name "Deleted bot". The other bot's run they started stays whole.
    @Test("Delete keeps a bot whose words started another bot's run as a Deleted bot, its team words and their run intact")
    func deleteKeepsLinkedHistoryUnderADeletedBot() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let asked = try await f.seedMessage(store, conversationID: f.conversationID, authorID: nil, sequence: 1)
        let ownRun = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: f.conversationID,
                                                 initiatingMessageID: asked)
        let other = try await f.seedOtherBot(store)
        let teamChat = try await f.seedTeamChat(store, lead: other.teammateID, members: [original.id, other.teammateID])
        // What a team chat leaves behind: this bot's message started the other bot's run.
        let words = try await f.seedMessage(store, conversationID: teamChat, authorID: original.id, sequence: 1)
        let theirRun = try await f.seedFinishedRun(store, teammateID: other.teammateID, conversationID: teamChat,
                                                   initiatingMessageID: words)
        try await store.setBotWebSwitch(.work, enabled: true, teammateID: original.id)
        let sessions = RecordingSessionRetention(store: store), grants = RecordingGrantForgetter(store: store)

        let inventory = try await store.inventory(id: original.id)
        #expect(inventory.keepsTeamHistory)
        _ = try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)),
                                              sessionRetention: sessions, connectorGrants: grants)
            .deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision)

        try await f.expectTombstone(store, original.id)
        #expect(try await f.count(store, "messages", "id", words) == 1)
        #expect(try await f.authorOf(store, words) == original.id.persistedValue)
        for (table, column) in NavDeleteFixture.runRecords {
            #expect(try await f.count(store, table, column, theirRun.runID) == 1, "\(table) lost the other bot's run")
            #expect(try await f.count(store, table, column, ownRun.runID) == 0, "\(table) still holds the bot's own run")
        }
        #expect(try await f.count(store, "conversations", "id", f.conversationID.persistedValue) == 0)
        #expect(try await store.loadWebSwitches().bots[original.id] == nil)
        #expect(await sessions.dropped == [original.id])
        #expect(await grants.forgotten == [original.id])
        #expect(try await f.foreignKeyProblems(store).isEmpty)
    }

    /// A later hop between two other bots points back at the hop this bot
    /// received. The chain stays whole and the
    /// record names the bot as deleted.
    @Test("Delete keeps a bot in the middle of another handoff chain as a Deleted bot, and the chain stays whole")
    func deleteKeepsABotInsideAHandoffChain() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let lead = try await f.seedOtherBot(store)
        let third = try await f.seedOtherBot(store, name: "Third Bot")
        let teamChat = try await f.seedTeamChat(store, lead: lead.teammateID,
                                                members: [lead.teammateID, original.id, third.teammateID])
        let received = try await f.seedHandoff(store, in: teamChat, from: lead.teammateID, to: original.id, after: nil)
        let next = try await f.seedHandoff(store, in: teamChat, from: lead.teammateID, to: third.teammateID, after: received)

        _ = try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))

        try await f.expectTombstone(store, original.id)
        #expect(try await f.count(store, "handoffs", "id", received) == 1)
        #expect(try await f.count(store, "handoffs", "id", next) == 1)
        // The record reads each brief, so the fixture's placeholder becomes a real one.
        let brief = try HandoffBrief(goal: "Check the sources", constraints: [], inputReferences: [],
                                     requestedOutput: "A short answer", exclusions: [], stopOrApprovalBoundary: "Ask first")
        _ = try await store.execute(sql: "UPDATE handoffs SET brief_json=?;",
                                    bindings: [.text(String(decoding: try JSONEncoder().encode(brief), as: UTF8.self))])
        let record = try await ConversationWorkRecordService(handoffs: store, approvals: store, activity: store,
                                                             messages: store, teammates: store)
            .workRecord(conversationID: teamChat)
        // Both hops carry one fixture time, so their order is not the point.
        #expect(record.handoffs.map(\.receiverName).sorted() == ["Deleted bot", "Third Bot"])
        #expect(record.handoffs.map(\.senderName) == ["Other Bot", "Other Bot"])
        #expect(try await f.foreignKeyProblems(store).isEmpty)
    }

    /// A kept handoff that could still move lost
    /// its card with its bot, so it could never be sent or declined and held
    /// its chain open for good. Delete ends each one as Decline would, in the
    /// same transaction; a leg whose run still works, and one already done,
    /// are left as they are.
    @Test("Delete ends every handoff to or from the bot that could still move, as needing recovery; a live or finished one stays")
    func deleteEndsTheBotsOpenHandoffs() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let lead = try await f.seedOtherBot(store)
        let third = try await f.seedOtherBot(store, name: "Third Bot")
        let teamChat = try await f.seedTeamChat(store, lead: lead.teammateID,
                                                members: [lead.teammateID, original.id, third.teammateID])
        let asked = try await f.seedMessage(store, conversationID: teamChat, authorID: nil, sequence: 1)
        let ownRun = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: teamChat, initiatingMessageID: asked)
        let liveRun = try await f.seedFinishedRun(store, teammateID: third.teammateID, conversationID: teamChat,
                                                  initiatingMessageID: asked)
        _ = try await store.execute(sql: "UPDATE work_runs SET state='running' WHERE id=?;", bindings: [.text(liveRun.runID)])
        let stagedTo = try await f.seedLeg(store, in: teamChat, from: lead.teammateID, to: original.id, state: "staged")
        let acceptedTo = try await f.seedLeg(store, in: teamChat, from: lead.teammateID, to: original.id, state: "accepted")
        let stagedFrom = try await f.seedLeg(store, in: teamChat, from: original.id, to: third.teammateID, state: "staged")
        let workedTo = try await f.seedLeg(store, in: teamChat, from: lead.teammateID, to: original.id, state: "working",
                                           runID: ownRun.runID)
        let runGone = try await f.seedLeg(store, in: teamChat, from: lead.teammateID, to: original.id, state: "working",
                                          runID: UUID().uuidString.lowercased())
        let stillWorking = try await f.seedLeg(store, in: teamChat, from: original.id, to: third.teammateID, state: "working",
                                               runID: liveRun.runID)
        let workedFrom = try await f.seedLeg(store, in: teamChat, from: original.id, to: third.teammateID, state: "working",
                                             runID: UUID().uuidString.lowercased())
        let finished = try await f.seedHandoff(store, in: teamChat, from: lead.teammateID, to: original.id, after: nil)

        _ = try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))

        try await f.expectTombstone(store, original.id)
        func handoff(_ id: String) async throws -> HandoffRecord? {
            try await store.record(id: HandoffID(try #require(UUID(uuidString: id))))
        }
        // The words say which end was deleted. The
        // deleted bot's name is gone, so they name its role in the hop.
        let words = [
            stagedTo: "Not done: the bot it was for was deleted. The lead can hand this off again.",
            acceptedTo: "Not done: the bot it was for was deleted. The lead can hand this off again.",
            workedTo: "Ended: the bot working on it was deleted before it reported. The lead can hand this off again.",
            runGone: "Ended: the bot working on it was deleted before it reported. The lead can hand this off again.",
            stagedFrom: "Not done: the bot that sent it was deleted.",
            workedFrom: "Not done: the bot that sent it was deleted.",
        ]
        for (id, userMessage) in words {
            let record = try #require(try await handoff(id))
            #expect(record.state == .needsRecovery, "\(id)")
            #expect(record.handoff.recovery?.code == "bot-deleted")
            #expect(record.handoff.recovery?.userMessage == userMessage, "\(id)")
            #expect(record.handoff.recovery?.isRecoverable == false)
            #expect(record.handoff.lastTransitionAt == f.at(9))
        }
        #expect(try await handoff(stillWorking)?.state == .working)
        // The finished hop's fixture brief is a placeholder; its state is read as stored.
        #expect(try await store.query(sql: "SELECT state FROM handoffs WHERE id=?;", bindings: [.text(finished)])
            .first?.text("state") == "succeeded")
        #expect(try await f.foreignKeyProblems(store).isEmpty)
    }

    /// The plain case: a bot that answered in a team chat keeps its
    /// words there even when no other record points at them.
    @Test("A bot that only spoke in a team chat is kept as a Deleted bot and its words stay")
    func teamWordsNothingPointsAtStay() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let other = try await f.seedOtherBot(store)
        let teamChat = try await f.seedTeamChat(store, lead: other.teammateID, members: [original.id, other.teammateID])
        let asked = try await f.seedMessage(store, conversationID: teamChat, authorID: nil, sequence: 1)
        let answered = try await f.seedMessage(store, conversationID: teamChat, authorID: original.id, sequence: 2)
        let ownTeamRun = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: teamChat,
                                                     initiatingMessageID: asked)
        let direct = try await f.seedMessage(store, conversationID: f.conversationID, authorID: original.id, sequence: 1)

        _ = try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))

        try await f.expectTombstone(store, original.id)
        #expect(try await f.count(store, "messages", "id", asked) == 1)
        #expect(try await f.count(store, "messages", "id", answered) == 1)
        #expect(try await f.count(store, "messages", "id", direct) == 0)
        #expect(try await f.count(store, "work_runs", "id", ownTeamRun.runID) == 0)
        #expect(try await f.foreignKeyProblems(store).isEmpty)
    }

    @Test("A Deleted bot is in no list, and cannot be restored, archived, inspected or deleted again")
    func aDeletedBotIsNowhere() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let other = try await f.seedOtherBot(store)
        let teamChat = try await f.seedTeamChat(store, lead: other.teammateID, members: [original.id, other.teammateID])
        _ = try await f.seedMessage(store, conversationID: teamChat, authorID: original.id, sequence: 1)
        _ = try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))
        let tombstone = try #require(try await store.teammate(id: original.id))

        #expect(try await store.listTeammates(includingArchived: true).map(\.id) == [other.teammateID])
        #expect(try await store.listTeammates(includingArchived: false).map(\.id) == [other.teammateID])
        #expect(try await store.archivedTeammates().isEmpty)
        #expect(try await TeammateNavigationService(repository: store, clock: NavDeleteClock(date: f.at(10)))
            .hiddenTeammates().isEmpty)
        #expect(try await store.deletedTeammateIDs() == [original.id])
        let team = try #require(try await store.listTeams(includingArchived: true).first)
        #expect(team.memberIDs == [other.teammateID])
        await #expect(throws: TeammateArchiveError.notFound) {
            try await store.restoreTeammate(id: original.id, expectedProfileRevision: tombstone.profile.revision, now: f.at(10))
        }
        await #expect(throws: TeammateArchiveError.notFound) {
            try await store.archiveTeammate(id: original.id, expectedProfileRevision: tombstone.profile.revision, now: f.at(10))
        }
        await #expect(throws: TeammateDeleteError.notFound) { try await store.inventory(id: original.id) }
        await #expect(throws: TeammateDeleteError.notFound) {
            try await store.deleteTeammate(id: original.id, expectedProfileRevision: tombstone.profile.revision, now: f.at(10))
        }
        #expect(try await store.teammate(id: original.id) == tombstone)
    }

    @Test("A second bot deleted after the first is kept the same way, and both sets of words stay")
    func twoBotsDeletedInTurn() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let second = try await f.seedOtherBot(store, name: "Second Bot")
        let lead = try await f.seedOtherBot(store, name: "Lead Bot")
        let teamChat = try await f.seedTeamChat(store, lead: lead.teammateID,
                                                members: [lead.teammateID, original.id, second.teammateID])
        let first = try await f.seedMessage(store, conversationID: teamChat, authorID: original.id, sequence: 1)
        // The second bot answered the first; the lead answered the second.
        let reply = try await f.seedMessage(store, conversationID: teamChat, authorID: second.teammateID, sequence: 2)
        let secondRun = try await f.seedFinishedRun(store, teammateID: second.teammateID, conversationID: teamChat,
                                                    initiatingMessageID: first)
        let leadRun = try await f.seedFinishedRun(store, teammateID: lead.teammateID, conversationID: teamChat,
                                                  initiatingMessageID: reply)

        _ = try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))
        let secondBot = try #require(try await store.teammate(id: second.teammateID))
        _ = try await store.deleteTeammate(id: second.teammateID, expectedProfileRevision: secondBot.profile.revision,
                                           now: f.at(10))

        try await f.expectTombstone(store, original.id)
        try await f.expectTombstone(store, second.teammateID)
        #expect(try await f.count(store, "messages", "id", first) == 1)
        #expect(try await f.count(store, "messages", "id", reply) == 1)
        #expect(try await f.count(store, "work_runs", "id", secondRun.runID) == 0)
        #expect(try await f.count(store, "work_runs", "id", leadRun.runID) == 1)
        #expect(try await store.listTeammates(includingArchived: true).map(\.id) == [lead.teammateID])
        #expect(try await store.deletedTeammateIDs() == [original.id, second.teammateID])
        #expect(try await f.foreignKeyProblems(store).isEmpty)
    }

    @Test("Migration 31 adds the deleted-bot mark, and the mark goes with its bot's row")
    func deletedMarkMigration() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let newest = try #require(try await store.query(sql: "SELECT version, name FROM schema_migrations ORDER BY version DESC;").first)
        #expect(try newest.integer("version") == 31)
        #expect(try newest.text("name") == "deleted-teammate-marks")
        let bare = try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Bare", role: "Teammate"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 3, deterministicSeed: 1, silhouette: "cloud",
                paletteToken: "violet", eyeDialect: "calm", nonColorIdentityCue: "soft crown",
                accessibleIdentityDescription: "Fixture identity", revision: 1),
            createdAt: f.date, updatedAt: f.date)
        try await store.insert(bare)
        _ = try await store.execute(sql: "INSERT INTO deleted_teammates(teammate_id,deleted_at) VALUES (?,?);",
                                    bindings: [.text(bare.id.persistedValue), .real(f.date.timeIntervalSince1970)])
        _ = try await store.execute(sql: "DELETE FROM teammates WHERE id=?;", bindings: [.text(bare.id.persistedValue)])
        #expect(try await f.count(store, "deleted_teammates", "teammate_id", bare.id.persistedValue) == 0)
    }

    /// A former lead's reply run is named by the handoff it reported, so that
    /// run stays with the chain it closed (Team Settings can change a lead).
    @Test("A former lead is kept as a Deleted bot and the run that reported its handoff stays")
    func formerLeadKeepsItsReportRun() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let member = try await f.seedOtherBot(store, name: "Member Bot")
        let teamChat = try await f.seedTeamChat(store, lead: original.id, members: [original.id, member.teammateID])
        let handoff = try await f.seedHandoff(store, in: teamChat, from: original.id, to: member.teammateID, after: nil)
        let reported = try await f.seedMessage(store, conversationID: teamChat, authorID: member.teammateID, sequence: 1)
        let report = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: teamChat,
                                                 initiatingMessageID: reported)
        _ = try await store.execute(sql: "UPDATE handoffs SET report_run_id=? WHERE id=?;",
                                    bindings: [.text(report.runID), .text(handoff)])
        // Team Settings gave the team a new lead afterwards.
        _ = try await store.execute(sql: "UPDATE teams SET lead_teammate_id=?;",
                                    bindings: [.text(member.teammateID.persistedValue)])

        _ = try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))

        try await f.expectTombstone(store, original.id)
        #expect(try await f.count(store, "handoffs", "id", handoff) == 1)
        #expect(try await f.count(store, "work_runs", "id", report.runID) == 1)
        #expect(try await f.foreignKeyProblems(store).isEmpty)
    }

    /// Only team history is kept. Any other broken reference is a gap in
    /// Delete itself and must come through as the error it is.
    @Test("A reference Delete does not know is an error, never a quiet Deleted bot")
    func unknownReferenceIsNotALinkedRefusal() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let other = try await f.seedOtherBot(store)
        // A shape the delete has no rule for: another bot's proposal in this bot's own chat.
        _ = try await store.execute(sql: """
            INSERT INTO action_proposals(id,teammate_id,conversation_id,run_id,envelope_json,fingerprint,state,
                                         revision,updated_at) VALUES (?,?,?,NULL,'{}','fingerprint','denied',1,?);
            """, bindings: [.text(UUID().uuidString.lowercased()), .text(other.teammateID.persistedValue),
                .text(f.conversationID.persistedValue), .real(f.date.timeIntervalSince1970)])

        await #expect(throws: SQLiteStoreError.self) {
            try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))
        }
        #expect(try await store.teammate(id: original.id) == original)
    }

    /// Asking a bot what it remembers writes records that point into its own
    /// chat and memory without cascading, so such a bot could never be deleted.
    @Test("Delete removes a bot's own memory records and moves its memory folder to the Trash")
    func deleteRemovesTheBotsMemory() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let memory = try await f.seedMemory(store, teammateID: original.id, conversationID: f.conversationID)
        let trash = TrashRecord()
        let memoryRoot = f.root.appending(path: "Memory", directoryHint: .isDirectory)
        let folder = memoryRoot.appending(path: "Documents/Teammates/\(original.id.persistedValue)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        _ = try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)),
                                              fileManager: RecordingTrash(trash), memoryRoot: memoryRoot)
            .deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision)

        #expect(try await store.teammate(id: original.id) == nil)
        for (table, column, value) in memory.rows {
            #expect(try await f.count(store, table, column, value) == 0, "\(table) still holds the bot's memory")
        }
        #expect(trash.trashed.map(\.standardizedFileURL.path) == [folder.standardizedFileURL.path])
    }

    /// Found in use: nothing moves a
    /// card's row past `approved`, and a quit leaves `pending`, so a bot that
    /// had ever been asked could never be deleted.
    @Test("A card left behind by a turn that has ended does not block Delete",
          arguments: ["pending", "approved", "executing"])
    func approvalsOfAnEndedTurn(state: String) async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let asked = try await f.seedMessage(store, conversationID: f.conversationID, authorID: nil, sequence: 1)
        _ = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: f.conversationID,
                                        initiatingMessageID: asked)
        let approval = try f.approval(teammateID: original.id)
        try await store.insert(approval)
        _ = try await store.execute(sql: """
            UPDATE approvals SET state=?1, resolved_at=CASE WHEN ?1='pending' THEN NULL ELSE requested_at END WHERE id=?2;
            """,
                                    bindings: [.text(state), .text(approval.id.persistedValue)])

        _ = try await TeammateDeletionService(repository: store, clock: NavDeleteClock(date: f.at(8)))
            .deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision)

        #expect(try await store.teammate(id: original.id) == nil)
        #expect(try await f.count(store, "approvals", "teammate_id", original.id.persistedValue) == 0)
    }

    @Test("A card still waiting in a running turn blocks Delete")
    func approvalOfARunningTurnBlocksDelete() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let asked = try await f.seedMessage(store, conversationID: f.conversationID, authorID: nil, sequence: 1)
        let run = try await f.seedFinishedRun(store, teammateID: original.id, conversationID: f.conversationID,
                                              initiatingMessageID: asked)
        _ = try await store.execute(sql: "UPDATE work_runs SET state='waitingForUser' WHERE id=?;", bindings: [.text(run.runID)])
        try await store.insert(f.approval(teammateID: original.id))

        await #expect(throws: TeammateDeleteError.unresolvedWork) {
            try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))
        }
        #expect(try await store.teammate(id: original.id) == original)
    }

    @Test("A memory publication still in flight is unresolved work")
    func pendingMemoryPublicationBlocksDelete() async throws {
        let f = try NavDeleteFixture(); defer { f.remove() }
        let store = try f.open()
        let original = try await f.seed(store)
        let memory = try await f.seedMemory(store, teammateID: original.id, conversationID: f.conversationID)
        _ = try await store.execute(sql: "UPDATE memory_publication_intents SET state='pending' WHERE id=?;",
                                    bindings: [.text(memory.laterIntentID)])

        await #expect(throws: TeammateDeleteError.unresolvedWork) {
            try await store.deleteTeammate(id: original.id, expectedProfileRevision: original.profile.revision, now: f.at(9))
        }
        #expect(try await store.teammate(id: original.id) == original)
    }
}

/// What would have gone to the Trash.
private final class TrashRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var trashed: [URL] { lock.withLock { urls } }
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
}

/// Moves nothing to the Trash, and writes down what it was asked to move.
private final class RecordingTrash: FileManager {
    private let record: TrashRecord
    init(_ record: TrashRecord) { self.record = record; super.init() }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        record.add(url)
    }
}

/// Records each drop, and whether the bot was still saved when it came.
private actor RecordingSessionRetention: ClaudeSessionRetaining {
    let store: SQLiteStore
    private(set) var dropped: [TeammateID] = []
    private(set) var botStillSaved: [Bool] = []

    init(store: SQLiteStore) { self.store = store }

    func dropSessions(teammateID: TeammateID) async throws -> ClaudeSessionDropReport {
        dropped.append(teammateID)
        botStillSaved.append(try await store.teammate(id: teammateID) != nil)
        return ClaudeSessionDropReport(dropped: [], kept: [])
    }
}

/// Records each forget, and whether the bot was still saved when it came.
private actor RecordingGrantForgetter: ConnectorGrantForgetting {
    let store: SQLiteStore
    private(set) var forgotten: [TeammateID] = []
    private(set) var botStillSaved: [Bool] = []

    init(store: SQLiteStore) { self.store = store }

    func forgetGrants(teammateID: TeammateID) async throws {
        forgotten.append(teammateID)
        botStillSaved.append(try await store.teammate(id: teammateID) != nil)
    }
}

private struct NavDeleteClock: OpenBotsClock {
    let date: Date
    func now() -> Date { date }
}

private struct NavDeleteFixture: Sendable {
    let root: URL
    let receipt: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let date = Date(timeIntervalSince1970: 20_000)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNavDeleteTests-\(UUID()).noindex")
        receipt = try ProtectionDecisionReceipt(
            decisionID: UUID(), selectedAt: Date(timeIntervalSince1970: 20_000), rationaleVersion: 2
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: root.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: receipt)
        ))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func at(_ seconds: TimeInterval) -> Date { date.addingTimeInterval(seconds) }

    /// A card's row in the bot's direct chat, pending as every card begins.
    func approval(teammateID: TeammateID) throws -> ApprovalRequest {
        try ApprovalRequest(id: ApprovalID(UUID()), teammateID: teammateID, conversationID: conversationID,
            action: .send, exactTargetSummary: "Synthetic target", consequenceSummary: "No external action",
            fingerprint: ApprovalFingerprint("fixture"), requestedAt: date)
    }

    func seed(_ store: SQLiteStore, asLead: Bool = false) async throws -> Teammate {
        let teammate = try Teammate(
            id: teammateID,
            profile: TeammateProfile(
                displayName: "Nav Bot", title: nil, role: "Local synthetic work"
            ),
            appearance: AgentAppearance(
                mode: .creature, grammarVersion: 3, deterministicSeed: 42,
                silhouette: "cloud", paletteToken: "violet", eyeDialect: "calm",
                nonColorIdentityCue: "soft crown", accessibleIdentityDescription: "Fixture identity",
                revision: 1
            ),
            createdAt: date, updatedAt: date
        )
        try await store.provisionDirectChat(
            teammate: teammate,
            conversation: Conversation(
                id: conversationID, kind: .direct(teammateID: teammateID),
                title: "Saved chat", createdAt: date, updatedAt: date
            ),
            fixtureGreeting: nil, selectConversation: true
        )
        if asLead {
            try await seedLeadTeam(store)
        }
        return teammate
    }

    /// Each table that records one run, and the column naming the run.
    static let runRecords = [("work_runs", "id"), ("run_journal_metadata", "run_id"), ("agentic_job_states", "run_id"),
        ("claude_text_execution_evidence", "run_id"), ("controlled_memory_text_turns", "run_id"),
        ("action_proposals", "run_id"), ("read_context_turn_proofs", "run_id")]

    func seedMessage(_ store: SQLiteStore, conversationID: ConversationID, authorID: TeammateID?,
                     sequence: Int64) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let at = date.timeIntervalSince1970
        _ = try await store.execute(sql: """
            INSERT INTO messages(id,conversation_id,sequence,author_kind,author_teammate_id,output_class,
                                 delivery_state,created_at,updated_at)
            VALUES (?,?,?,?,?,'conversation','completed',?,?);
            """, bindings: [.text(id), .text(conversationID.persistedValue), .integer(sequence),
                .text(authorID == nil ? "user" : "teammate"), authorID.map { .text($0.persistedValue) } ?? .null,
                .real(at), .real(at)])
        return id
    }

    /// A finished run shaped like the app's own: its journal, the Work job's
    /// saved state, the Claude reply's proof, the memory turn, and a denied
    /// proposal with its event.
    func seedFinishedRun(_ store: SQLiteStore, teammateID: TeammateID, conversationID: ConversationID,
                         initiatingMessageID: String) async throws -> (runID: String, proposalID: String) {
        let run = UUID().uuidString.lowercased(), proposal = UUID().uuidString.lowercased()
        let at = SQLiteBinding.real(date.timeIntervalSince1970)
        let rows: [(String, [SQLiteBinding])] = [
            ("""
             INSERT INTO work_runs(id,teammate_id,conversation_id,initiating_message_id,profile_revision,state,
                                   created_at,updated_at) VALUES (?,?,?,?,1,'succeeded',?,?);
             """, [.text(run), .text(teammateID.persistedValue), .text(conversationID.persistedValue),
                   .text(initiatingMessageID), at, at]),
            ("INSERT INTO run_journal_metadata(run_id,request_json,origin,revision) VALUES (?,'{}','executor',1);",
             [.text(run)]),
            ("""
             INSERT INTO agentic_job_states(run_id,revision,conversation_generation,session_id,state_json,recorded_at)
             VALUES (?,1,0,NULL,'{}',?);
             """, [.text(run), at]),
            ("INSERT INTO claude_text_execution_evidence(run_id,evidence_json,admission_token) VALUES (?,'{}','token');",
             [.text(run)]),
            ("INSERT INTO controlled_memory_text_turns(run_id,policy_version,admission_token) VALUES (?,1,'token');",
             [.text(run)]),
            ("""
             INSERT INTO read_context_turn_proofs(run_id,proven,memory_qualification_required,memory_references_json)
             VALUES (?,1,0,'[]');
             """, [.text(run)]),
            ("""
             INSERT INTO action_proposals(id,teammate_id,conversation_id,run_id,envelope_json,fingerprint,state,
                                          revision,updated_at) VALUES (?,?,?,?,'{}','fingerprint','denied',1,?);
             """, [.text(proposal), .text(teammateID.persistedValue), .text(conversationID.persistedValue),
                   .text(run), at]),
            ("INSERT INTO action_proposal_events(proposal_id,revision,state,recorded_at) VALUES (?,1,'denied',?);",
             [.text(proposal), at]),
        ]
        for (sql, bindings) in rows { _ = try await store.execute(sql: sql, bindings: bindings) }
        return (run, proposal)
    }

    /// A second bot with its own direct chat.
    func seedOtherBot(_ store: SQLiteStore, name: String = "Other Bot") async throws
        -> (teammateID: TeammateID, conversationID: ConversationID) {
        let id = TeammateID(UUID()), chat = ConversationID(UUID())
        let teammate = try Teammate(
            id: id,
            profile: TeammateProfile(displayName: name, title: nil, role: "Local synthetic work"),
            appearance: AgentAppearance(
                mode: .creature, grammarVersion: 3, deterministicSeed: 43,
                silhouette: "cloud", paletteToken: "violet", eyeDialect: "calm",
                nonColorIdentityCue: "soft crown", accessibleIdentityDescription: "Fixture identity",
                revision: 1
            ),
            createdAt: date, updatedAt: date
        )
        try await store.provisionDirectChat(
            teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: id), title: "Other chat",
                                       createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false
        )
        return (id, chat)
    }

    /// One hop of a handoff chain, as the chain triggers allow it: a first hop
    /// that finished, or a later hop from the same sender naming it as chain and parent.
    func seedHandoff(_ store: SQLiteStore, in chat: ConversationID, from sender: TeammateID, to receiver: TeammateID,
                     after previous: String?) async throws -> String {
        let id = UUID().uuidString.lowercased(), at = SQLiteBinding.real(date.timeIntervalSince1970)
        let finished = previous == nil
        _ = try await store.execute(sql: """
            INSERT INTO handoffs(id,leg_id,origin_conversation_id,sender_teammate_id,receiver_teammate_id,brief_json,state,
                result_summary,created_at,last_transition_at,completed_at,chain_id,parent_handoff_id,hop_count)
            VALUES (?,?,?,?,?,'{}',?,?,?,?,?,?,?,?);
            """, bindings: [.text(id), .text(UUID().uuidString.lowercased()), .text(chat.persistedValue),
                .text(sender.persistedValue), .text(receiver.persistedValue), .text(finished ? "succeeded" : "accepted"),
                finished ? .text("Done") : .null, at, at, finished ? at : .null, .text(previous ?? id),
                previous.map { .text($0) } ?? .null, .integer(finished ? 1 : 2)])
        return id
    }

    /// A first hop in any state short of done, its run named when given.
    func seedLeg(_ store: SQLiteStore, in chat: ConversationID, from sender: TeammateID, to receiver: TeammateID,
                 state: String, runID: String? = nil) async throws -> String {
        let id = UUID().uuidString.lowercased(), at = SQLiteBinding.real(date.timeIntervalSince1970)
        let brief = try HandoffBrief(goal: "Check the sources", constraints: [], inputReferences: [],
                                     requestedOutput: "A short answer", exclusions: [], stopOrApprovalBoundary: "Ask first")
        _ = try await store.execute(sql: """
            INSERT INTO handoffs(id,leg_id,origin_conversation_id,sender_teammate_id,receiver_teammate_id,brief_json,state,
                run_id,created_at,last_transition_at,chain_id,hop_count)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,1);
            """, bindings: [.text(id), .text(UUID().uuidString.lowercased()), .text(chat.persistedValue),
                .text(sender.persistedValue), .text(receiver.persistedValue),
                .text(String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)), .text(state),
                runID.map { .text($0) } ?? .null, at, at, .text(id)])
        return id
    }

    /// A team chat, provisioned the way the app does it.
    func seedTeamChat(_ store: SQLiteStore, lead: TeammateID, members: Set<TeammateID>) async throws -> ConversationID {
        let teamID = TeamID(UUID()), chat = ConversationID(UUID())
        let team = try Team(id: teamID, name: "Shared Team", leadID: lead, memberIDs: members, createdAt: date, updatedAt: date)
        try await store.provisionTeam(team, conversation: Conversation(id: chat, kind: .team(teamID: teamID),
            title: "Shared Team", createdAt: date, updatedAt: date), selectConversation: false)
        return chat
    }

    /// What asking a bot what it remembers leaves behind: two revisions of one
    /// memory document in its scope, published by the system through intents as
    /// the app's writer does, a memory reply published in its chat, and a
    /// correction with its clarification.
    func seedMemory(_ store: SQLiteStore, teammateID: TeammateID, conversationID: ConversationID) async throws
        -> (rows: [(String, String, String)], laterIntentID: String) {
        let tid = teammateID.persistedValue, folder = "Documents/Teammates/\(teammateID.persistedValue)"
        let asked = try await seedMessage(store, conversationID: conversationID, authorID: nil, sequence: 11)
        let replied = try await seedMessage(store, conversationID: conversationID, authorID: teammateID, sequence: 12)
        let corrected = try await seedMessage(store, conversationID: conversationID, authorID: nil, sequence: 13)
        let clarified = try await seedMessage(store, conversationID: conversationID, authorID: teammateID, sequence: 14)
        let new = { UUID().uuidString.lowercased() }
        let (part, first, second, firstIntent, laterIntent, publication, operation) = (new(), new(), new(), new(), new(), new(), new())
        let at = SQLiteBinding.real(date.timeIntervalSince1970), digest = SQLiteBinding.text(String(repeating: "a", count: 64))
        let rows: [(String, [SQLiteBinding])] = [
            ("INSERT INTO message_parts(id,message_id,ordinal,kind,text_value,referenced_id) VALUES (?,?,0,'text','Which one?',NULL);",
             [.text(part), .text(clarified)]),
            ("""
             INSERT INTO memory_documents(id,scope_kind,scope_id,author_kind,author_teammate_id,title,relative_path,revision,
                                          content_digest,supersedes_id,created_at,updated_at)
             VALUES (?,'teammate',?,'system',NULL,'Likes tea',?,1,?,NULL,?,?);
             """, [.text(first), .text(tid), .text("\(folder)/\(first)-r1.md"), digest, at, at]),
            ("""
             INSERT INTO memory_documents(id,scope_kind,scope_id,author_kind,author_teammate_id,title,relative_path,revision,
                                          content_digest,supersedes_id,created_at,updated_at)
             VALUES (?,'teammate',?,'system',NULL,'Likes green tea',?,2,?,?,?,?);
             """, [.text(second), .text(tid), .text("\(folder)/\(second)-r2.md"), digest, .text(first), at, at]),
            ("""
             INSERT INTO memory_publication_intents(id,document_id,predecessor_id,intent_json,staging_relative_path,
                 final_relative_path,content_digest,byte_count,state,revision,created_at,updated_at)
             VALUES (?,?,NULL,'{}',?,?,?,9,'committed',1,?,?);
             """, [.text(firstIntent), .text(first), .text("\(folder)/.openbots-stage-\(firstIntent).tmp"),
                   .text("\(folder)/\(first)-r1.md"), digest, at, at]),
            ("""
             INSERT INTO memory_publication_intents(id,document_id,predecessor_id,intent_json,staging_relative_path,
                 final_relative_path,content_digest,byte_count,state,revision,created_at,updated_at)
             VALUES (?,?,?,'{}',?,?,?,9,'committed',1,?,?);
             """, [.text(laterIntent), .text(second), .text(first), .text("\(folder)/.openbots-stage-\(laterIntent).tmp"),
                   .text("\(folder)/\(second)-r2.md"), digest, at, at]),
            ("""
             INSERT INTO memory_conversation_publications(id,local_operation_id,conversation_id,teammate_id,user_message_id,
                 reply_message_id,record_json,rendered_digest,created_at) VALUES (?,?,?,?,?,?,'{}',?,?);
             """, [.text(publication), .text(new()), .text(conversationID.persistedValue), .text(tid), .text(asked),
                   .text(replied), digest, at]),
            ("""
             INSERT INTO memory_local_corrections(user_message_id,operation_id,conversation_id,acknowledgement_message_id,
                 request_json,command_digest,state,revision,failure_code,created_at,updated_at)
             VALUES (?,?,?,?,'{}',?,'acknowledged',1,NULL,?,?);
             """, [.text(corrected), .text(operation), .text(conversationID.persistedValue), .text(new()), digest, at, at]),
            ("""
             INSERT INTO memory_local_correction_clarifications(user_message_id,operation_id,reply_message_id,reply_part_id,
                 kind,created_at) VALUES (?,?,?,?,'targetRequired',?);
             """, [.text(corrected), .text(operation), .text(clarified), .text(part), at]),
        ]
        for (sql, bindings) in rows { _ = try await store.execute(sql: sql, bindings: bindings) }
        return ([("memory_documents", "id", first), ("memory_documents", "id", second),
                 ("memory_publication_intents", "id", firstIntent), ("memory_publication_intents", "id", laterIntent),
                 ("memory_conversation_publications", "id", publication),
                 ("memory_local_corrections", "user_message_id", corrected),
                 ("memory_local_correction_clarifications", "user_message_id", corrected)], laterIntent)
    }

    /// What Delete leaves of a bot whose team history stays: one row with no
    /// name, profile, history, membership or picture, marked as deleted.
    func expectTombstone(_ store: SQLiteStore, _ id: TeammateID) async throws {
        let kept = try #require(try await store.teammate(id: id))
        #expect(kept.profile.displayName == "Deleted bot")
        #expect(kept.profile.role == "Teammate")
        #expect(kept.profile.title == nil && kept.profile.detailedInstructions == nil && kept.profile.seat == nil)
        #expect(kept.lifecycle == .archived && kept.isHidden && !kept.isPinned)
        #expect(kept.claudeModel == nil && kept.profileWrittenByHirer == nil)
        #expect(kept.appearance.mode == .creature && kept.appearance.profileAssetID == nil)
        #expect(kept.appearance.accessibleIdentityDescription == "Deleted bot")
        let tid = id.persistedValue
        #expect(try await count(store, "deleted_teammates", "teammate_id", tid) == 1)
        for table in ["teammate_profile_revisions", "team_memberships", "project_memberships", "conversation_participants",
                      "capability_grants", "approvals", "action_proposals", "bot_sidebar_order",
                      "conversation_context_selections", "memory_conversation_publications"] {
            #expect(try await count(store, table, "teammate_id", tid) == 0, "\(table) still names the deleted bot")
        }
    }

    func authorOf(_ store: SQLiteStore, _ messageID: String) async throws -> String? {
        try await store.query(sql: "SELECT author_teammate_id FROM messages WHERE id=?;", bindings: [.text(messageID)])
            .first?.optionalText("author_teammate_id")
    }

    /// Every row whose reference no longer resolves.
    func foreignKeyProblems(_ store: SQLiteStore) async throws -> [String] {
        try await store.query(sql: "PRAGMA foreign_key_check;").map { try $0.text("table") }
    }

    func count(_ store: SQLiteStore, _ table: String, _ column: String, _ value: String) async throws -> Int64 {
        try await store.query(sql: "SELECT COUNT(*) AS n FROM \(table) WHERE \(column)=?;", bindings: [.text(value)])
            .first?.integer("n") ?? 0
    }

    private func seedLeadTeam(_ store: SQLiteStore) async throws {
        let teamID = UUID().uuidString.lowercased()
        _ = try await store.execute(
            sql: """
            INSERT INTO teams(id,name,summary,lead_teammate_id,lifecycle,created_at,updated_at)
            VALUES (?,'Lead Team',NULL,?,'active',?,?);
            """,
            bindings: [
                .text(teamID), .text(teammateID.persistedValue),
                .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)
            ]
        )
        _ = try await store.execute(
            sql: "INSERT INTO team_memberships(team_id,teammate_id,joined_at) VALUES (?,?,?);",
            bindings: [.text(teamID), .text(teammateID.persistedValue), .real(date.timeIntervalSince1970)]
        )
    }
}
