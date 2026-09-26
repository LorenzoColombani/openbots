import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// A new bot sets itself up: New Bot makes the bot at
/// once with its question and its waiting mark, and one setup call writes its
/// profile and its own switches. Over the real store and the real switches.
@Suite("A new bot sets itself up")
struct BotSelfSetupServiceTests {
    private final actor FolderSpy: BotFolderRenaming {
        private(set) var renames: [(TeammateID, String)] = []
        func followRename(teammateID: TeammateID, from oldName: String) async -> Bool {
            renames.append((teammateID, oldName)); return true
        }
        var count: Int { renames.count }
        var lastOldName: String? { renames.last?.1 }
    }

    private struct Setting {
        let store: SQLiteStore
        let switches: AgenticJobAccessStore
        let folders: FolderSpy
        let service: BotSelfSetupService
        let bot: TeammateID
        let chat: ConversationID
    }

    private func newBot(_ f: HiringFixture, name: String = "New Bot") async throws -> Setting {
        let store = try f.open()
        try await f.seed(store)
        let chats = DurableTeammateChatService(teammateRepository: store, conversationRepository: store,
            messageRepository: store, provisioningRepository: store, selectionRepository: store)
        let id = TeammateID(UUID())
        let created = try await chats.createSelfSettingTeammateAndDirectChat(teammateID: id, placeholderName: name,
            appearance: try CreatureAllocation(id: id.rawValue).appearance())
        let switches = AgenticJobAccessStore(reportWriteFailure: { _ in })
        let folders = FolderSpy()
        let service = BotSelfSetupService(repository: store, teammates: store, switches: switches, folders: folders)
        return Setting(store: store, switches: switches, folders: folders, service: service, bot: id,
                       chat: created.conversation.id)
    }

    private func call(_ s: Setting, _ toolUseID: String, _ arguments: [String: Any], own: Bool = true) async throws
        -> Result<BotSelfSetup, BotSelfSetupRefusal> {
        await s.service.setUp(BotSelfSetupSubmission(toolUseID: toolUseID, teammateID: s.bot,
            argumentsJSON: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), isOwnCall: own))
    }

    private let priceWatch: [String: Any] = [
        "handle": "PriceWatch", "purpose": "Watches competitor prices and flags drops",
        "instructions": "Check each product page and report drops first.", "purview": "Competitor prices",
        "switches": ["web_search", "web_fetch"]]

    @Test("New Bot: a placeholder name and role, its chat selected and opened on its one question, marked as waiting")
    func newBotAsksItsJob() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        let bot = try #require(try await s.store.teammate(id: s.bot))
        #expect(bot.profile.displayName == "New Bot" && bot.profile.role == BotSelfSetup.placeholderRole)
        #expect(BotSelfSetup.isUntouched(bot.profile, placeholderName: "New Bot"))
        let page = try await s.store.page(conversationID: s.chat, request: PageRequest(limit: 10))
        #expect(page.elements.count == 1)
        #expect(page.elements.first?.author == .teammate(s.bot))
        #expect(page.elements.first?.parts.first?.content == .text(BotSelfSetup.firstQuestion))
        #expect(try await s.store.selectedConversationID() == s.chat)
        #expect(await s.service.placeholderName(teammateID: s.bot) == "New Bot")
        #expect(await s.service.placeholderName(teammateID: f.kite) == nil)
    }

    @Test("A setup writes the profile in the bot's words, turns on only its own asked switches, and is offered once")
    func setUpOnce() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        await s.switches.setAppEnabled(true, capability: .web(.search))
        await s.switches.setAppEnabled(true, capability: .web(.fetch))

        let result = try await call(s, "toolu_1", priceWatch)
        let setup = try result.get()
        #expect(setup == BotSelfSetup(previousName: "New Bot", name: "PriceWatch",
            purpose: "Watches competitor prices and flags drops", wroteProfile: true,
            turnedOn: [.webSearch, .webFetch], offForTheApp: []))
        let bot = try #require(try await s.store.teammate(id: s.bot))
        #expect(bot.profile.displayName == "PriceWatch")
        #expect(bot.profile.role == "Watches competitor prices and flags drops")
        #expect(bot.profile.detailedInstructions == "Check each product page and report drops first.")
        #expect(bot.profile.seat?.purview == "Competitor prices")
        #expect(bot.profileWrittenByHirer == nil)
        let access = await s.switches.current(teammateID: s.bot)
        #expect(access.webSearch.isEnabled && access.webFetch.isEnabled)
        #expect(!access.work.botEnabled && !access.hire.botEnabled && !access.workers.botEnabled && !access.fetchers.botEnabled)
        // The masters are the user's: the work master stays off, the others as they were.
        #expect(!access.work.appEnabled)
        let renames = await s.folders.count, oldName = await s.folders.lastOldName
        #expect(renames == 1 && oldName == "New Bot")
        // Offered once: the mark is gone, a repeat of the call gets its answer, a new call is refused.
        #expect(await s.service.placeholderName(teammateID: s.bot) == nil)
        #expect(try await call(s, "toolu_1", priceWatch) == result)
        #expect(try await call(s, "toolu_2", ["handle": "Other", "purpose": "x"]) == .failure(.notPending))
        #expect(try await s.store.teammate(id: s.bot)?.profile.displayName == "PriceWatch")
    }

    @Test("A master that is off stays off and is named; asking for nothing turns nothing on")
    func masterOffNamed() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        let setup = try await call(s, "toolu_1", ["handle": "Tidy", "purpose": "Sorts Downloads", "switches": ["work"]]).get()
        #expect(setup.turnedOn == [.work] && setup.offForTheApp == [.work])
        let access = await s.switches.current(teammateID: s.bot)
        #expect(access.work.botEnabled && !access.work.appEnabled)

        let g = try HiringFixture(); defer { g.remove() }
        let t = try await newBot(g)
        let none = try await call(t, "toolu_1", ["handle": "Poet", "purpose": "Writes poems"]).get()
        #expect(none.turnedOn.isEmpty)
        let quiet = await t.switches.current(teammateID: t.bot)
        #expect(!quiet.webSearch.botEnabled && !quiet.webFetch.botEnabled && !quiet.work.botEnabled)
    }

    @Test("The user's edits win: a role they wrote before answering stays, and the switches still come on")
    func theUsersEditWins() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        var edited = try #require(try await s.store.teammate(id: s.bot))
        let revision = edited.profile.revision
        edited.profile = try edited.profile.revised(role: "My own words about prices")
        try await s.store.update(edited, expectedProfileRevision: revision)

        let setup = try await call(s, "toolu_1", priceWatch).get()
        #expect(!setup.wroteProfile && setup.name == "New Bot" && setup.purpose == "My own words about prices")
        #expect(setup.turnedOn == [.webSearch, .webFetch])
        let bot = try #require(try await s.store.teammate(id: s.bot))
        #expect(bot.profile.displayName == "New Bot" && bot.profile.role == "My own words about prices")
        #expect(bot.profile.detailedInstructions == nil)
        #expect(await s.folders.count == 0, "the name did not change, so the folder stays")
        #expect(await s.service.placeholderName(teammateID: s.bot) == nil)
    }

    @Test("A name another bot holds, active or archived, is refused and changes nothing; the bot can try again")
    func nameRule() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        #expect(try await call(s, "toolu_1", ["handle": "kite", "purpose": "x", "switches": ["work"]])
            == .failure(.profile(.nameTaken(existingName: "Kite"))))
        var ledger = try #require(try await s.store.teammate(id: f.ledger))
        ledger.lifecycle = .archived
        try await s.store.update(ledger, expectedProfileRevision: ledger.profile.revision)
        #expect(try await call(s, "toolu_2", ["handle": "Ledger", "purpose": "x"])
            == .failure(.profile(.nameArchived(existingName: "Ledger"))))
        #expect(try await s.store.teammate(id: s.bot)?.profile.displayName == "New Bot")
        let unchanged = await s.switches.current(teammateID: s.bot)
        #expect(!unchanged.work.botEnabled)
        #expect(await s.service.placeholderName(teammateID: s.bot) == "New Bot")
        #expect(try await call(s, "toolu_3", priceWatch).get().name == "PriceWatch")
    }

    @Test("Only the bot's own call sets it up, and a malformed or unknown switch changes nothing")
    func refusals() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        #expect(try await call(s, "toolu_1", priceWatch, own: false) == .failure(.notTheBot))
        #expect(try await call(s, "toolu_2", ["handle": "A", "purpose": "b", "switches": ["hire"]]) == .failure(.unknownSwitch))
        #expect(try await call(s, "toolu_3", ["handle": "A", "purpose": "b", "role": "c"]) == .failure(.malformed))
        #expect(await s.service.placeholderName(teammateID: s.bot) == "New Bot")
        let sealed = await s.switches.current(teammateID: s.bot)
        #expect(!sealed.hire.botEnabled)
        // A bot never marked is never set up.
        let kite = BotSelfSetupSubmission(toolUseID: "toolu_4", teammateID: f.kite,
            argumentsJSON: try JSONSerialization.data(withJSONObject: priceWatch), isOwnCall: true)
        #expect(await s.service.setUp(kite) == .failure(.notPending))
        #expect(try await s.store.teammate(id: f.kite)?.profile.displayName == "Kite")
    }

    @Test("An edit's line is saved as the app's own status line at the end of the chat")
    func statusLine() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let s = try await newBot(f)
        let chats = DurableTeammateChatService(teammateRepository: s.store, conversationRepository: s.store,
            messageRepository: s.store, provisioningRepository: s.store, selectionRepository: s.store)
        let note = try await chats.saveStatusLine("You changed PriceWatch's role.", conversationID: s.chat)
        #expect(note.author == .system && note.sequence == 2 && note.deliveryState == .completed)
        #expect(note.parts.map(\.content) == [.status("You changed PriceWatch's role.")])
        let page = try await s.store.page(conversationID: s.chat, request: PageRequest(limit: 10))
        #expect(page.elements.last?.id == note.id)
    }
}
