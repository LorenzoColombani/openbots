import AppKit
import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsServices
@testable import OpenBotsUI
import Testing

/// One Access sheet per bot:
/// every switch the bot has, each with its app-wide master's state beside it,
/// writing exactly the stores the Details pane and Settings already write.
@MainActor
@Suite("One Access sheet per bot")
struct BotAccessSheetTests {
    @Test("Open Settings opens the pane the master sentence names, in plain words")
    func openSettingsOpensTheNamedPane() {
        #expect(BotAccessMasterPane.permissions.settingsSection == .permissions)
        #expect(BotAccessMasterPane.connectors.settingsSection == .connectors)
        // The sentence and the pane it opens say the same name.
        for pane in [BotAccessMasterPane.permissions, .connectors] {
            #expect(BotAccessCopy.masterOff(pane).contains(pane.settingsSection.rawValue))
        }
        #expect(BotAccessCopy.openSettings == "Open Settings")
    }

    @Test("The sheet lists every switch once, says why a master off blocks it, and writes the store Details reads")
    func theSheetShowsEveryGrantWithItsMaster() async throws {
        let switches = AgenticJobAccessStore()
        let catalog = try Catalog()
        let connectors = ConnectorAccessStore(repository: Repository(), catalog: catalog)
        let bot = TeammateID(UUID())
        // The full set, as the sheet reads once a worker can run; this build
        // leaves the two worker rows out (the test after this one).
        let model = BotAccessModel(teammateID: bot, botName: "Kite", switches: switches, connectors: connectors,
                                   includesWorkers: true)
        defer { model.stopObserving() }
        await model.load()

        // Every switch the bot has, once: work, the two web capabilities,
        // hiring and the two worker switches,
        // then one row per connector in the order the catalog is read (a row
        // that works before one the user still has to set up).
        let calendarRow = "connector:\(catalog.calendar.definition.id)"
        let mailRow = "connector:\(catalog.mail.definition.id)"
        #expect(model.rows.map(\.id)
            == ["work", "webSearch", "webFetch", "hire", "workers", "fetchers", calendarRow, mailRow])
        #expect(model.rows.map(\.title)
            == ["Work on this Mac", "Web search", "Web fetch", "Hire new bots", "Background workers", "Fetcher workers",
                "Calendar (read-only)", "Apple Mail (read-only)"])
        #expect(Set(model.rows.map(\.id)).count == model.rows.count, "no switch appears twice")

        // Every master is off, so every row says so, and names where the master lives.
        for row in model.rows {
            #expect(!row.isOn, "\(row.id) starts off")
            #expect(!row.masterIsOn, "\(row.id) master starts off")
            let note = try #require(row.masterNote, "\(row.id) has its master off and says nothing")
            #expect(note.hasPrefix("Off for the whole app in Settings"), "\(row.id): \(note)")
        }
        #expect(model.row("work")?.masterNote == BotAccessCopy.masterOff(.permissions))
        #expect(model.row("webFetch")?.masterNote == BotAccessCopy.masterOff(.permissions))
        #expect(model.row(mailRow)?.masterNote == BotAccessCopy.masterOff(.connectors))
        #expect(BotAccessCopy.masterOff(.permissions).contains("Permissions & Bot Access"))
        #expect(BotAccessCopy.masterOff(.connectors).contains("Connectors & Skills"))
        // Each sentence has an Open Settings beside it that
        // opens the pane it names, and only a row with a sentence has one.
        for row in model.rows {
            #expect((row.masterNote == nil) == (row.masterPane == nil), "\(row.id)")
        }
        for id in ["work", "webSearch", "webFetch", "hire", "workers", "fetchers"] {
            #expect(model.row(id)?.masterPane == .permissions, "\(id)")
        }
        #expect(model.row(mailRow)?.masterPane == .connectors)
        #expect(model.row(calendarRow)?.masterPane == .connectors)

        // A connector's Settings badge and its reason travel onto its row.
        let mail = try #require(model.row(mailRow))
        #expect(mail.badge == "needs setup")
        #expect(mail.notes == ["The mail reader is not installed yet. Install it once with `uv tool install apple-mail-fast-mcp==0.10.2`."])
        #expect(!mail.isFrozen, "a needs-setup row can still be switched on, so the choice is ready when the setup is")
        #expect(model.row(calendarRow)?.badge == nil)

        // Turning a master on takes the sentence away, for that row only.
        await switches.setAppEnabled(true, capability: .work)
        await model.refresh()
        #expect(model.row("work")?.masterIsOn == true)
        #expect(model.row("work")?.masterNote == nil)
        #expect(model.row("work")?.masterPane == nil, "no sentence, no Open Settings")
        #expect(model.row("webSearch")?.masterNote == BotAccessCopy.masterOff(.permissions))

        // Toggling a row writes the store Details reads. Work, through the
        // switch store the Details pane observes...
        await model.setOn(true, rowID: "work")
        #expect((await switches.current(teammateID: bot)).work.botEnabled)
        #expect(model.row("work")?.isOn == true)
        let details = AgenticJobAccessModel(store: switches)
        details.selectTeammate(bot)
        await details.refresh()
        #expect(details.workBotEnabled && details.workIsEnabled)
        // ...web search on its own, never dragging web fetch with it...
        await model.setOn(true, rowID: "webSearch")
        #expect((await switches.current(teammateID: bot)).webSearch.botEnabled)
        #expect(!(await switches.current(teammateID: bot)).webFetch.botEnabled)
        #expect(model.row("webSearch")?.isOn == true && model.row("webFetch")?.isOn == false)
        // ...each worker switch on its own, the fetchers never riding along
        // with the workers (a fetcher reads the web, so it is its own grant)...
        await model.setOn(true, rowID: "workers")
        #expect((await switches.current(teammateID: bot)).workers.botEnabled)
        #expect(!(await switches.current(teammateID: bot)).fetchers.botEnabled)
        #expect(model.row("workers")?.isOn == true && model.row("fetchers")?.isOn == false)
        await model.setOn(true, rowID: "fetchers")
        #expect((await switches.current(teammateID: bot)).fetchers.botEnabled)
        #expect(model.row("fetchers")?.isOn == true)
        // ...and a connector through the connector store, master still off,
        // exactly as the Details pane saves a selection today.
        await model.setOn(true, rowID: calendarRow)
        #expect((await connectors.current(teammateID: bot)).selectedIDs == [catalog.calendar.definition.id])
        #expect(model.row(calendarRow)?.isOn == true)
        let detailsConnectors = ConnectorSettingsModel(store: connectors, teammateID: bot)
        defer { detailsConnectors.stopObserving() }
        await detailsConnectors.load()
        #expect(detailsConnectors.reading.selectedIDs == [catalog.calendar.definition.id])
        // Off again lands in the same place.
        await model.setOn(false, rowID: calendarRow)
        #expect((await connectors.current(teammateID: bot)).selectedIDs.isEmpty)
        #expect(model.row(calendarRow)?.isOn == false)
        // Another bot inherits the masters, never the grants.
        let stranger = TeammateID(UUID())
        #expect(!(await switches.current(teammateID: stranger)).work.botEnabled)
        #expect(!(await switches.current(teammateID: stranger)).webSearch.botEnabled)
        #expect((await connectors.current(teammateID: stranger)).selectedIDs.isEmpty)
    }

    /// A worker runs now: the host channel, the blank run and the holder's
    /// wake landed together, so the two switches ship. Built without them, the sheet and the Details line leave them out.
    @Test("The worker switches are on the sheet and the Details line now a worker runs, and a build without workers leaves them out")
    func theWorkerSwitchesShipWithAWorkerThatRuns() async throws {
        #expect(AgenticWorkerAvailability.runsInThisBuild)
        let shipped = BotAccessModel(teammateID: TeammateID(UUID()), botName: "Kite", switches: AgenticJobAccessStore(), connectors: nil)
        defer { shipped.stopObserving() }
        await shipped.load()
        #expect(shipped.rows.map(\.id).contains("workers") && shipped.rows.map(\.id).contains("fetchers"))
        #expect(BotAccessCopy.detailsCaption.contains("workers"))
        let switches = AgenticJobAccessStore()
        let bot = TeammateID(UUID())
        let model = BotAccessModel(teammateID: bot, botName: "Kite", switches: switches, connectors: nil, includesWorkers: false)
        defer { model.stopObserving() }
        await model.load()
        #expect(model.rows.map(\.id) == ["work", "webSearch", "webFetch", "hire"])

        let details = AgenticJobAccessModel(store: switches)
        details.selectTeammate(bot)
        await details.refresh()
        #expect(BotAccessCopy.switchSummary(details, includesWorkers: false) == "Work on this Mac off · Web search off · Web fetch off · Hiring off.")
        #expect(BotAccessCopy.switchSummary(details) == "Work on this Mac off · Web search off · Web fetch off · Hiring off · Workers off · Fetcher workers off.")
    }

    @Test("A connector killed for every bot, or changed since it was allowed, says so on its row")
    func aConnectorRowCarriesTheSettingsBadges() async throws {
        let repository = Repository()
        let before = try Catalog()
        let bot = TeammateID(UUID())
        let first = ConnectorAccessStore(repository: repository, catalog: before)
        try await first.restore()
        try await first.setAppEnabled(true)
        try await first.setBotEnabled(true, identity: before.calendar.definition.identity, teammateID: bot)
        try await first.setBotEnabled(true, identity: before.mail.definition.identity, teammateID: bot)
        try await first.setConnectorAppEnabled(false, id: before.mail.definition.id)

        // The same calendar row, a different version underneath the grant.
        let after = try Catalog(calendarDigest: String(repeating: "b", count: 64))
        let model = BotAccessModel(teammateID: bot, botName: "Kite", switches: nil,
                                   connectors: ConnectorAccessStore(repository: repository, catalog: after))
        defer { model.stopObserving() }
        await model.load()

        // No switch store: no work or web rows are invented for it.
        #expect(model.rows.map(\.id) == ["connector:\(after.calendar.definition.id)",
                                         "connector:\(after.mail.definition.id)"])
        // Killed app-wide: the master reads off in the words Settings uses, and
        // the bot's own switch is kept but cannot move.
        let mail = try #require(model.row("connector:\(after.mail.definition.id)"))
        #expect(!mail.masterIsOn && mail.masterNote == ConnectorCopy.appWideOff)
        #expect(mail.masterPane == .connectors, "the kill switch lives in Connectors & Skills too")
        #expect(mail.isOn && mail.isFrozen)
        // Changed since allowed: the grant is gone and the row says why.
        let calendar = try #require(model.row("connector:\(after.calendar.definition.id)"))
        #expect(calendar.masterIsOn && calendar.masterNote == nil)
        #expect(calendar.masterPane == nil)
        #expect(!calendar.isOn)
        #expect(calendar.notes == [ConnectorCopy.botChanged])
    }

    /// An edit inside the bot's own folder goes through with no card. The work
    /// row's summary once said a card asks before anything that changes
    /// files, which stopped being true when that change landed. The
    /// fix then over-promised the other way: "go through on their own" with no
    /// exception, while the policy still asks for a target under the deny list
    /// and for a link that leads out of the folder (a symlink, or a file the
    /// disk knows under a second name). The sentence names both now. And the
    /// note under an off master promised the switch "works once that one is
    /// on", which a needs-setup or unavailable connector row cannot keep.
    @Test("The work row tells the truth about the card, and a master-off note promises only what is true")
    func theSentencesOnTheSheetAreTrue() {
        #expect(BotAccessCopy.workSummary ==
            "Read, write and run commands in its own folder and the folders you add to it, as you. "
            + "Edits inside its own folder go through on their own, except protected files and links that "
            + "lead outside it; a card asks before anything else that changes files or has effects.")
        #expect(BotAccessCopy.masterOff(.permissions) ==
            "Off for the whole app in Settings → Permissions & Bot Access. "
            + "This bot's switch is kept and counts once that one is on.")
        #expect(BotAccessCopy.masterOff(.connectors) ==
            "Off for the whole app in Settings → Connectors & Skills. "
            + "This bot's switch is kept and counts once that one is on.")
    }

    /// Bots that hire bots: hiring is a switch pair like the
    /// others, the bot's half on this sheet under its own heading, the
    /// app-wide half in Settings, both off until the user turns them on.
    @Test("The hire row is this bot's own hire switch under Team, says what a hire makes, and counts only with the Settings master on")
    func theHireRowIsAPairWithItsMaster() async throws {
        let switches = AgenticJobAccessStore()
        let bot = TeammateID(UUID())
        let model = BotAccessModel(teammateID: bot, botName: "Kite", switches: switches, connectors: nil)
        defer { model.stopObserving() }
        await model.load()
        let row = try #require(model.row("hire"))
        #expect(row.group == .team)
        #expect(BotAccessRow.Group.allCases == [.mac, .web, .team, .connectors])
        #expect(row.title == "Hire new bots")
        #expect(row.summary == BotAccessCopy.hireSummary)
        #expect(row.accessibilityIdentifier == "agentic.bot.hire")
        #expect(!row.isOn && !row.masterIsOn)
        #expect(row.masterNote == BotAccessCopy.masterOff(.permissions))
        // Every bot reads the team's shared folder and its skills, a hired one
        // too.
        #expect(BotAccessCopy.hireSummary == "Ask OpenBots for a new bot from its own replies, at most three a reply. "
            + "A new bot starts with every switch off and no connectors; like every bot, it reads the team's shared folder "
            + "and the skills you give it. Turned off while the bot is answering, it takes effect when that reply ends.")

        await model.setOn(true, rowID: "hire")
        #expect((await switches.current(teammateID: bot)).hire.botEnabled)
        #expect(!(await switches.hireGranted(teammateID: bot)), "the bot's half alone grants nothing")
        #expect(model.row("hire")?.isOn == true)

        // Settings holds the master, through the same shared model it reads.
        let settings = AgenticJobAccessModel(store: switches)
        await settings.refresh()
        #expect(!settings.hireAppEnabled)
        await settings.setHireAppEnabled(true)
        #expect((await switches.current(teammateID: bot)).hire.appEnabled)
        #expect(await switches.hireGranted(teammateID: bot))
        await model.refresh()
        #expect(model.row("hire")?.masterIsOn == true && model.row("hire")?.masterNote == nil)
        #expect(AgenticWebCopy.settingsHireCaption.contains("Access sheet"))
        // The newcomer reads like every bot, and the note is the app's own line, not the hirer's.
        #expect(!AgenticWebCopy.settingsHireCaption.contains("folder but"))
        #expect(AgenticWebCopy.settingsHireCaption.contains("shared folder"))
        #expect(!AgenticWebCopy.settingsHireCaption.contains("the bot that hired it says so"))
        #expect(AgenticWebCopy.settingsHireCaption.contains("OpenBots notes each hire"))

        // Details names the effective state beside the others.
        let details = AgenticJobAccessModel(store: switches)
        details.selectTeammate(bot)
        await details.refresh()
        #expect(details.hireIsEnabled)
        #expect(BotAccessCopy.switchSummary(details, includesWorkers: false)
            == "Work on this Mac off · Web search off · Web fetch off · Hiring on.")
        #expect(BotAccessCopy.switchSummary(details)
            == "Work on this Mac off · Web search off · Web fetch off · Hiring on · Workers off · Fetcher workers off.")
        #expect(BotAccessCopy.detailsCaption.contains("hiring"))
        #expect(BotAccessCopy.detailsCaptionWithoutConnectors.contains("hiring"))
    }

    /// The sample-folder job runner lost its switch, its toggle and its banner
    /// so no bot can be inside a job any more; the
    /// web rows still promised the tools worked there.
    @Test("The web rows say where the tools work and name no retired job")
    func theWebRowsNameNoRetiredJob() {
        #expect(BotAccessCopy.webSummary(.search) == "Look things up on the web, in its conversations.")
        #expect(BotAccessCopy.webSummary(.fetch) == "Read one web page it names, in its conversations.")
        for capability in AgenticWebCapability.allCases {
            #expect(!BotAccessCopy.webSummary(capability).contains("job"))
        }
    }

    /// The same false sentence lived three times — on the sheet, under the
    /// Settings work master and under the old Details switch — and three
    /// captions still sent the user to Details or "its settings" for switches that
    /// live on this sheet. The three copy files are swept as text, so a fourth
    /// copy of either fails here before anyone reads it in the running app. The
    /// same sweep catches the opposite over-promise: "go through on their own;"
    /// with no exception, when the policy still asks for a protected file and
    /// for a link that leads out of the folder.
    @Test("No user-facing copy claims a card before every edit or a quiet edit for every in-folder target, and none sends the user to Details or its settings for a bot's switches")
    func noCopyClaimsACardBeforeEveryEdit() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI")
        for file in ["BotAccessSheet.swift", "AgenticWebCopy.swift", "ConnectorSettingsModel.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            // "anything that changes files" is the false form; the true one
            // reads "anything else that changes files".
            #expect(!text.localizedCaseInsensitiveContains("anything that changes files"),
                    "\(file) still claims a card before every edit")
            // "on their own;" promises a quiet edit for every in-folder target;
            // the true form reads "on their own, except protected files and
            // links that lead outside it;".
            #expect(!text.contains("on their own;"),
                    "\(file) still promises a quiet edit for every target inside the bot's own folder")
            for stale in ["in their Details", "each bot's Details", "in its settings", "bot's settings", "bot’s settings"] {
                #expect(!text.contains(stale), "\(file) still sends the user to \"\(stale)\" for a bot's switches")
            }
        }
    }

    @Test("The workspace opens the sheet for the bot a sidebar row or Details names, over the stores it already holds")
    func theWorkspaceOpensTheSheetForThatBot() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try fixture.open()
        let switches = AgenticJobAccessStore()
        let connectors = ConnectorAccessStore(repository: Repository(), catalog: try Catalog())
        let workspace = DurableWorkspaceModel(
            mode: .localOnly, service: fixture.chatService(store: database),
            agenticJobAccess: switches, connectorAccess: connectors, hiringService: ReferenceUnusedHiringService())
        defer { workspace.finishShutdown() }
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try #require(workspace.selectedTeammate)
        #expect(workspace.supportsBotAccess)
        #expect(workspace.botAccess == nil)

        // A bot that is not in the roster opens nothing.
        workspace.openBotAccess(id: UUID())
        #expect(workspace.botAccess == nil)

        // The row's bot, by id, whether or not it is the selection.
        workspace.openBotAccess(id: teammate.id.rawValue)
        let sheet = try #require(workspace.botAccess)
        #expect(sheet.teammateID == teammate.id)
        #expect(sheet.botName == teammate.profile.displayName)
        await sheet.load()
        #expect(sheet.rows.map(\.id).prefix(3) == ["work", "webSearch", "webFetch"])
        #expect(sheet.rows.count == 8, "six switches, the two worker ones among them, and the two connectors the app lists")
        // A switch moved on the sheet lands in the workspace's own store.
        await sheet.setOn(true, rowID: "work")
        #expect((await switches.current(teammateID: teammate.id)).work.botEnabled)

        workspace.dismissBotAccess()
        #expect(workspace.botAccess == nil)
    }

    /// A bot's sheet once showed Claude Code's own iMessage plugin as a frozen
    /// "unavailable" row beside the app's Messages row, which read as iMessage
    /// being switched off. Leaving such a row off every sheet is not enough: a
    /// bot that already had it on would keep a grant no surface could turn off. So the row is
    /// listed only while the bot has it on, its switch moves only to off, even
    /// with the connector killed for the whole app, and its note says why. The
    /// catalog is composed the way the app composes it, so the row is exactly
    /// the one the live app marks as driven by nothing in this build.
    @Test("A bot's sheet lists a connector nothing in this build can launch only while the bot has it on, with a switch that only turns it off; an app-owned row that cannot run keeps its reason; Settings still lists every row")
    func aConnectorThisBuildCannotLaunchIsListedOnlyWhileOn() async throws {
        let messages = ConfiguredConnector(
            definition: .init(
                identity: try .init(id: "openbots:apple-messages:apple-messages", digest: String(repeating: "d", count: 64)),
                serverName: "apple-messages", pluginName: "apple-messages", transport: .stdio,
                title: "Messages (iMessage, RCS, SMS)", summary: "Sends and reads texts.",
                availability: .unavailable("Messages is not installed on this Mac.")),
            launch: .init(serverKey: "", transport: .stdio, command: "apple-messages"))
        let calendar = try Catalog().calendar
        let plugin = ConfiguredConnector(
            definition: .init(
                identity: try .init(id: "claude-plugin:imessage@claude-plugins-official:imessage",
                                    digest: String(repeating: "e", count: 64)),
                serverName: "imessage", pluginName: "imessage@claude-plugins-official", transport: .stdio,
                title: "imessage", summary: ConnectorDefinition.defaultSummary(pluginName: "imessage@claude-plugins-official"),
                availability: .ready),
            launch: .init(serverKey: "", transport: .stdio, command: "bun",
                          arguments: ["run", "--cwd", "/tmp/imessage", "--shell=bun", "--silent", "start"]))
        let composed = ConnectorCatalogAvailability(
            Rows(connectors: [calendar, messages, plugin]),
            probes: [OwnsCommand(command: "/usr/bin/env", answer: .ready)])
        let repository = Repository()
        let store = ConnectorAccessStore(repository: repository, catalog: composed)
        try await store.restore()
        let pluginID = plugin.definition.id
        let composedPlugin = try #require(await store.current().definitions.first { $0.id == pluginID })
        #expect(composedPlugin.availability.isUnowned,
                "the live composition marks the plugin as driven by nothing in this build")
        // The bot had switched the plugin on before its switch froze, as Canobi had.
        let bot = TeammateID(UUID())
        try await store.setBotEnabled(true, identity: composedPlugin.identity, teammateID: bot)

        let model = BotAccessModel(teammateID: bot, botName: "Canobi", switches: nil, connectors: store)
        defer { model.stopObserving() }
        await model.load()
        let pluginRow = "connector:\(pluginID)"
        let messagesRow = "connector:\(messages.definition.id)"
        // Read order: what works, then what cannot run, each in identity order.
        #expect(model.rows.map(\.id) == ["connector:\(calendar.definition.id)", pluginRow, messagesRow])
        let row = try #require(model.row(pluginRow))
        #expect(row.isOn && !row.isFrozen, "the one move this switch has left is off")
        #expect(row.badge == "unavailable")
        #expect(row.notes == [BotAccessCopy.unownedConnectorOn])
        #expect(row.masterNote == nil, "no sentence may promise the switch counts once a master is on")
        #expect(model.row(messagesRow)?.notes == ["Messages is not installed on this Mac."])
        #expect(model.row(messagesRow)?.isFrozen == true)
        #expect(!model.connectorsAreEmpty)

        // Settings → Connectors & Skills keeps the row: the app-wide switch is the user's.
        let settings = ConnectorSettingsModel(store: store)
        defer { settings.stopObserving() }
        await settings.load()
        #expect(settings.reading.definitions.contains { $0.id == pluginID })
        // Killed for the whole app, the bot's switch still turns it off.
        await settings.setConnectorAppEnabled(false, definition: composedPlugin)
        await model.refresh()
        #expect(model.row(pluginRow)?.isOn == true && model.row(pluginRow)?.isFrozen == false)
        #expect(model.row(pluginRow)?.masterNote == nil)

        // Off, it leaves the sheet, and nothing turns it back on.
        await model.setOn(false, rowID: pluginRow)
        #expect(await store.current(teammateID: bot).selectedIDs.isEmpty)
        #expect(model.row(pluginRow) == nil)
        await model.setOn(true, rowID: pluginRow)
        let direct = ConnectorSettingsModel(store: store, teammateID: bot)
        defer { direct.stopObserving() }
        await direct.load()
        await direct.setSelected(true, definition: composedPlugin)
        #expect(direct.notice == ConnectorCatalogAvailability.unownedRow.reason)
        #expect(await store.current(teammateID: bot).selectedIDs.isEmpty)

        // A catalog of nothing but such rows, none of them on, reads as no connectors on the sheet.
        let onlyPlugin = ConnectorAccessStore(repository: Repository(), catalog: ConnectorCatalogAvailability(
            Rows(connectors: [plugin]), probes: [OwnsCommand(command: "/usr/bin/env", answer: .ready)]))
        let empty = BotAccessModel(teammateID: bot, botName: "Canobi", switches: nil, connectors: onlyPlugin)
        defer { empty.stopObserving() }
        await empty.load()
        #expect(empty.rows.isEmpty)
        #expect(empty.connectorsAreEmpty)
    }

    /// The sheet's empty line also showed when every connector on the Mac was
    /// one nothing in this build can run, and then both its sentences were false: they are
    /// set up, in Claude Code, and Settings lists exactly the ones this build
    /// cannot drive. The sentence is read here, not just the flag.
    @Test("The sheet's empty connectors line is true whether nothing is listed or nothing listed can run, and absent while a row is drawn")
    func theEmptyConnectorsLineIsTrueInEveryState() async throws {
        let plugin = ConfiguredConnector(
            definition: .init(
                identity: try .init(id: "claude-plugin:imessage@claude-plugins-official:imessage",
                                    digest: String(repeating: "e", count: 64)),
                serverName: "imessage", pluginName: "imessage@claude-plugins-official", transport: .stdio),
            launch: .init(serverKey: "", transport: .stdio, command: "bun"))
        let probes: [any ConnectorAvailabilityProbing] = [OwnsCommand(command: "/usr/bin/env", answer: .ready)]
        let bot = TeammateID(UUID())
        func sheet(_ connectors: [ConfiguredConnector]) async throws -> (BotAccessModel, ConnectorAccessStore) {
            let store = ConnectorAccessStore(repository: Repository(), catalog: ConnectorCatalogAvailability(
                Rows(connectors: connectors), probes: probes))
            let model = BotAccessModel(teammateID: bot, botName: "Canobi", switches: nil, connectors: store)
            await model.load()
            return (model, store)
        }

        // Nothing configured at all.
        let (nothing, _) = try await sheet([])
        defer { nothing.stopObserving() }
        #expect(nothing.connectorsEmptyNote == BotAccessCopy.noConnectors)
        #expect(BotAccessCopy.noConnectors == "No connectors are set up on this Mac yet.")

        // Only rows nothing in this build can run, none of them on.
        let (unrunnable, store) = try await sheet([plugin])
        defer { unrunnable.stopObserving() }
        #expect(unrunnable.rows.isEmpty)
        #expect(unrunnable.connectorsEmptyNote == BotAccessCopy.noRunnableConnectors)
        #expect(BotAccessCopy.noRunnableConnectors
            == "None of the connectors on this Mac can be run by this version of OpenBots Next, so this bot has none "
            + "to switch on. Settings → Connectors & Skills lists them, each with the reason.")

        // One of them on: its row is drawn, so there is no empty line.
        let composed = try #require(await store.current().definitions.first)
        try await store.setBotEnabled(true, identity: composed.identity, teammateID: bot)
        await unrunnable.refresh()
        #expect(unrunnable.rows.count == 1)
        #expect(unrunnable.connectorsEmptyNote == nil)

        // A row that can run: no empty line.
        let (working, _) = try await sheet([try Catalog().calendar])
        defer { working.stopObserving() }
        #expect(working.connectorsEmptyNote == nil)
    }

    /// The line under Access… in Details once promised "every
    /// connector, each with its app-wide switch beside it", while the sheet
    /// leaves out a connector nothing in this build can run and shows a
    /// sentence, not a switch, when a master is off.
    @Test("The line under Access… in Details promises neither every connector nor a switch beside each row")
    func theDetailsCaptionPromisesOnlyWhatTheSheetShows() {
        #expect(BotAccessCopy.detailsCaption == "This bot's own switches for Work on this Mac, web search, web fetch, "
            + "hiring, workers and connectors, in one place. The app-wide switches stay in Settings.")
        #expect(BotAccessCopy.detailsCaptionWithoutConnectors == "This bot's own switches for Work on this Mac, "
            + "web search, web fetch, hiring and workers, in one place. The app-wide switches stay in Settings.")
        for caption in [BotAccessCopy.detailsCaption, BotAccessCopy.detailsCaptionWithoutConnectors] {
            #expect(!caption.contains("every connector"))
            #expect(!caption.contains("beside it"))
        }
    }

    @Test("The note on a row nothing in this build can run says so in plain words, and that its switch only turns off")
    func theUnownedRowNoteIsPlain() {
        #expect(BotAccessCopy.unownedConnectorOn == "Nothing in this version of OpenBots Next can run this connector, "
            + "so this switch does nothing. You can switch it off, and then the row leaves this sheet. "
            + "It cannot be switched back on.")
    }

    /// The sheet once decided what to leave out by
    /// comparing a row's reason to the unowned sentence, so a row a preparation
    /// owns whose words happened to match was hidden, and a wording change on
    /// either side would move what is hidden. What is hidden is who owns the row.
    @Test("What a bot's sheet leaves out is decided by whether anything in this build owns the row, never by the row's words")
    func theSheetLeavesOutByOwnershipNotByWording() async throws {
        let unownedWords = try #require(ConnectorCatalogAvailability.unownedRow.reason)
        let contacts = ConfiguredConnector(
            definition: .init(
                identity: try .init(id: "openbots:apple-contacts:apple-contacts", digest: String(repeating: "f", count: 64)),
                serverName: "apple-contacts", pluginName: "apple-contacts", transport: .stdio,
                title: "Contacts (read-only)", summary: "Reads your contacts."),
            launch: .init(serverKey: "", transport: .stdio, command: "contacts-reader"))
        let plugin = ConfiguredConnector(
            definition: .init(
                identity: try .init(id: "claude-plugin:imessage@claude-plugins-official:imessage",
                                    digest: String(repeating: "e", count: 64)),
                serverName: "imessage", pluginName: "imessage@claude-plugins-official", transport: .stdio),
            launch: .init(serverKey: "", transport: .stdio, command: "bun"))
        // The contacts preparation owns its row and answers in exactly the
        // unowned row's words; nothing owns the plugin.
        let store = ConnectorAccessStore(repository: Repository(), catalog: ConnectorCatalogAvailability(
            Rows(connectors: [contacts, plugin]),
            probes: [OwnsCommand(command: "contacts-reader", answer: .unavailable(unownedWords))]))
        let model = BotAccessModel(teammateID: TeammateID(UUID()), botName: "Canobi", switches: nil, connectors: store)
        defer { model.stopObserving() }
        await model.load()
        #expect(model.rows.map(\.id) == ["connector:\(contacts.definition.id)"],
                "an owned row keeps its place whatever its reason says, and the unowned plugin is left out")
        #expect(model.row("connector:\(contacts.definition.id)")?.notes == [unownedWords])
    }

    private struct Rows: ConnectorCatalogReading {
        let connectors: [ConfiguredConnector]
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot { .init(connectors: connectors) }
    }

    /// A preparation that owns one command, as each of the app's does.
    private struct OwnsCommand: ConnectorAvailabilityProbing {
        let command: String
        let answer: ConnectorAvailability
        func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
            launch.command == command ? answer : nil
        }
    }

    @Test("The line under a bot's skills says every bot reads them, with or without Work")
    func theSkillsLineSaysEveryBotReadsThem() {
        #expect(BotSkillsCopy.caption.contains("with or without Work on this Mac"))
        #expect(!BotSkillsCopy.caption.contains("With Work on this Mac on"))
        #expect(BotSkillsCopy.caption.contains("can never change them"))
    }

    /// The Add Skill menu once said "No
    /// skills in ~/.claude/skills" before the library had been read, and also
    /// when it held skills that cannot be added; it read the folder again only
    /// on selection or after an add or a remove.
    @Test("The Add Skill menu reads as loading until the library is read, and then says only what is true")
    func theAddSkillMenuSaysWhatIsTrue() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextSkillsMenu-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PreviewStorageLayout(homeDirectory: root.appending(path: "home"),
                                          systemTemporaryDirectory: root.appending(path: "tmp"))
        let library = layout.homeDirectory.appending(path: ".claude/skills")
        try FileManager.default.createDirectory(at: library.appending(path: "no-skill-file"), withIntermediateDirectories: true)
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        let store = try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
        let model = BotWorkspaceModel(service: BotWorkspaceService(layout: layout, repository: store, teammates: store))

        model.select(TeammateID(UUID()))
        #expect(model.skillMenuNote == BotSkillsCopy.readingSkills, "nothing is claimed before the folder is read")
        try await skillsEventually { model.skillLibraryIsLoaded }
        #expect(model.availableSkills.isEmpty)
        #expect(model.skillMenuNote == BotSkillsCopy.noUsableSkills, "a folder is there; it just cannot be added")

        // A skill added in Finder while Details is open shows once the library is read again.
        let pickup = library.appending(path: "pickup")
        try FileManager.default.createDirectory(at: pickup, withIntermediateDirectories: true)
        try Data("---\ndescription: Resume a paused project\n---\n".utf8).write(to: pickup.appending(path: "SKILL.md"))
        model.refreshSkillLibrary()
        try await skillsEventually { !model.availableSkills.isEmpty }
        #expect(model.availableSkills.map(\.name) == ["pickup"])
        #expect(model.skillMenuNote == nil)

        // Nothing there at all, read again when the user comes back to the app.
        try FileManager.default.removeItem(at: library)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await skillsEventually { model.availableSkills.isEmpty }
        #expect(model.skillMenuNote == BotSkillsCopy.noSkills)
        #expect(BotSkillsCopy.noSkills == "No skills in ~/.claude/skills")
        #expect(BotSkillsCopy.noUsableSkills == "Nothing in ~/.claude/skills can be added: a skill needs its own folder "
            + "with a SKILL.md inside, named with letters, digits, dots, hyphens or underscores.")
    }

    /// Two app-owned rows exactly as `AppOwnedConnectorCatalog` builds them on
    /// a Mac where the calendar reader ships and the mail reader is not yet
    /// installed: same ids, titles and reasons.
    private struct Catalog: ConnectorCatalogReading {
        let calendar: ConfiguredConnector
        let mail: ConfiguredConnector
        init(calendarDigest: String = String(repeating: "a", count: 64)) throws {
            calendar = .init(
                definition: .init(
                    identity: try .init(id: "openbots:apple-calendar:apple-calendar", digest: calendarDigest),
                    serverName: "apple-calendar", pluginName: "apple-calendar", transport: .stdio,
                    title: "Calendar (read-only)",
                    summary: "Reads your own calendars — what is on a given day or week, and one event in full "
                        + "with the people on it and their email addresses.\nNeeds Calendars permission for "
                        + "OpenBots Next in System Settings → Privacy & Security.",
                    availability: .ready),
                launch: .init(serverKey: "", transport: .stdio, command: "/usr/bin/env"))
            mail = .init(
                definition: .init(
                    identity: try .init(id: "openbots:apple-mail:apple-mail", digest: String(repeating: "c", count: 64)),
                    serverName: "apple-mail", pluginName: "apple-mail", transport: .stdio,
                    title: "Apple Mail (read-only)",
                    summary: "Reads and searches your own Mail.app — no send or delete tool exists to be called, "
                        + "and this app stores no mail password.\nNeeds Mail running, and permission for "
                        + "OpenBots Next to control Mail.",
                    availability: .needsSetup("The mail reader is not installed yet. Install it once with "
                        + "`uv tool install apple-mail-fast-mcp==0.10.2`.")),
                launch: .init(serverKey: "", transport: .stdio, command: "apple-mail-fast-mcp",
                              arguments: ["--read-only"], pinnedPackage: "apple-mail-fast-mcp==0.10.2"))
        }
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
            .init(connectors: [calendar, mail])
        }
    }

    private actor Repository: ConnectorAccessRepository {
        var state = ConnectorAccessState()
        func loadConnectorAccess() async throws -> ConnectorAccessState { state }
        func saveConnectorAccess(_ state: ConnectorAccessState, expectedRevision: Int64) async throws {
            guard self.state.revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
            self.state = state
        }
    }

    private func skillsEventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the condition never held")
    }
}
