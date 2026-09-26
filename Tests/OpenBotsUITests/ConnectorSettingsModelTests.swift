import Foundation
import OpenBotsDomain
import OpenBotsServices
@testable import OpenBotsUI
import Testing

@MainActor
@Suite("Configured connector settings")
struct ConnectorSettingsModelTests {
    @Test("A bot can save a selection while the master is off, without any connection claim")
    func botAndMasterSelections() async throws {
        let fixture = try Catalog()
        let store = ConnectorAccessStore(repository: Repository(), catalog: fixture)
        let bot = ConnectorSettingsModel(store: store, teammateID: TeammateID(UUID()))
        let master = ConnectorSettingsModel(store: store)
        defer { bot.stopObserving(); master.stopObserving() }
        await bot.load()
        #expect(bot.reading.definitions == [fixture.connector.definition])
        #expect(bot.reading.isAvailable && !bot.reading.appEnabled)
        await bot.setSelected(true, definition: fixture.connector.definition)
        #expect(bot.reading.selectedIDs == [fixture.connector.definition.id])
        #expect(await store.lease(teammateID: try #require(bot.teammateID)) == nil)
        await master.load()
        await master.setAppEnabled(true)
        #expect(master.reading.appEnabled && master.notice == nil)
        #expect(await store.lease(teammateID: try #require(bot.teammateID)) != nil)
    }

    @Test("A connector switched off because its version changed says so, instead of going quiet")
    func aChangedDefinitionIsNamed() async throws {
        // Claude Code once moved its Chrome DevTools plugin from 1.8.0 to
        // 1.9.0, the row became a different definition, the store correctly
        // revoked the grant given to the old one — and nothing told the user.
        // The app just stopped browsing.
        let repository = Repository()
        let before = try Catalog()
        let teammate = TeammateID(UUID())
        let first = ConnectorAccessStore(repository: repository, catalog: before)
        try await first.restore()
        try await first.setBotEnabled(true, identity: before.connector.definition.identity,
                                      teammateID: teammate)
        #expect(await first.current(teammateID: teammate).selectedIDs
            == [before.connector.definition.id])

        // The same row, a different version of the same plugin.
        let after = try Catalog(digest: String(repeating: "b", count: 64))
        let model = ConnectorSettingsModel(
            store: ConnectorAccessStore(repository: repository, catalog: after), teammateID: teammate)
        defer { model.stopObserving() }
        await model.load()
        let definition = try #require(model.reading.definitions.first)
        #expect(model.reading.selectedIDs.isEmpty, "the old grant must not survive the change")
        #expect(model.reading.changedSinceAllowed.contains(definition.id),
                "and the user must be told which row it was, or the app just looks broken")
    }

    @Test("The app-wide switch takes a row this build cannot drive, because it records the user's decision")
    func theAppWideSwitchRecordsTheUsersDecisionEvenForADeadRow() async throws {
        // The general page is a kill or live switch. A row that cannot run
        // today is still a row the user may rule on, and refusing it would leave a dead switch under a caption saying
        // every row below can be turned off.
        let fixture = try Catalog(availability: .unavailable("This version cannot drive this connector yet."))
        let store = ConnectorAccessStore(repository: Repository(), catalog: fixture)
        let master = ConnectorSettingsModel(store: store)
        defer { master.stopObserving() }
        await master.load()
        let definition = try #require(master.reading.definitions.first)
        #expect(!definition.availability.canBeEnabled)
        await master.setConnectorAppEnabled(false, definition: definition)
        #expect(master.notice == nil, "refusing it with a notice is the defect, not the guard")
        #expect(master.reading.appDisabledIDs.contains(definition.id))
        await master.setConnectorAppEnabled(true, definition: definition)
        #expect(master.reading.appDisabledIDs.isEmpty)
    }

    @Test("A bot's switch for a connector killed app-wide cannot be moved, and the lease is gone")
    func aKilledConnectorIsRefusedToEveryBot() async throws {
        let repository = Repository()
        let fixture = try Catalog()
        let store = ConnectorAccessStore(repository: repository, catalog: fixture)
        let teammate = TeammateID(UUID())
        let bot = ConnectorSettingsModel(store: store, teammateID: teammate)
        let master = ConnectorSettingsModel(store: store)
        defer { bot.stopObserving(); master.stopObserving() }
        await master.load(); await bot.load()
        await master.setAppEnabled(true)
        let definition = try #require(bot.reading.definitions.first)
        await bot.setSelected(true, definition: definition)
        #expect(await store.lease(teammateID: teammate) != nil)
        await master.setConnectorAppEnabled(false, definition: definition)
        await bot.load()
        // Three gates, and this one is closed: the bot keeps its own choice,
        // and still cannot launch.
        #expect(bot.reading.appDisabledIDs.contains(definition.id))
        #expect(bot.reading.selectedIDs.contains(definition.id))
        #expect(await store.lease(teammateID: teammate) == nil)
    }

    /// Past the bound, the launch hands back no connectors at all and the bot
    /// answers with none and no word about why. The switch is where that can
    /// still be said.
    @Test("A bot's switch that would take it past what one turn can launch is refused in words, and turning one off makes room")
    func theSwitchPastTheBoundIsRefused() async throws {
        let bound = ConnectorLaunchService.maximumConnectorsPerBot
        let fixture = try ManyCatalog(count: bound + 1)
        let store = ConnectorAccessStore(repository: Repository(), catalog: fixture)
        let bot = ConnectorSettingsModel(store: store, teammateID: TeammateID(UUID()))
        defer { bot.stopObserving() }
        await bot.load()
        let definitions = bot.reading.definitions
        #expect(definitions.count == bound + 1)
        for definition in definitions.prefix(bound) { await bot.setSelected(true, definition: definition) }
        #expect(bot.reading.selectedIDs.count == bound && bot.notice == nil)
        let extra = try #require(definitions.last)
        await bot.setSelected(true, definition: extra)
        #expect(bot.notice == ConnectorCopy.tooManyConnectors)
        #expect(!bot.reading.selectedIDs.contains(extra.id))
        #expect(ConnectorCopy.tooManyConnectors.contains("at most \(bound) connectors"))
        // Killing one app-wide does not make room: un-killing it later would
        // carry the bot past the bound with nobody's hand on this switch.
        let master = ConnectorSettingsModel(store: store)
        defer { master.stopObserving() }
        await master.load()
        await master.setConnectorAppEnabled(false, definition: definitions[0])
        await bot.load()
        await bot.setSelected(true, definition: extra)
        #expect(bot.notice == ConnectorCopy.tooManyConnectors)
        #expect(!bot.reading.selectedIDs.contains(extra.id))
        await master.setConnectorAppEnabled(true, definition: definitions[0])
        await bot.load()
        // Turning one off is never refused, and it makes room for the other.
        await bot.setSelected(false, definition: definitions[0])
        await bot.setSelected(true, definition: extra)
        #expect(bot.reading.selectedIDs.contains(extra.id) && bot.reading.selectedIDs.count == bound)
        #expect(bot.notice == nil)
    }

    /// Canobi's grant to Claude Code's own iMessage plugin, switched on before
    /// the row froze, once stayed in the count, so a bot with that one and eight working connectors on was refused
    /// a ninth, while the launch skips a row no preparation owns and would have
    /// run all nine. The bound counts what a launch can use.
    @Test("A grant nothing in this build can launch takes no place under the bound, and past what a launch can run the switch still refuses")
    func anUnownedGrantTakesNoPlaceUnderTheBound() async throws {
        let bound = ConnectorLaunchService.maximumConnectorsPerBot
        let fixture = try OwnedAndUnownedCatalog(ownedCount: bound + 1)
        let store = ConnectorAccessStore(repository: Repository(), catalog: ConnectorCatalogAvailability(
            fixture, probes: [OwnsCommand(command: OwnedAndUnownedCatalog.ownedCommand)]))
        try await store.restore()
        let teammate = TeammateID(UUID())
        let plugin = try #require(await store.current().definitions.first { $0.id == fixture.unowned.definition.id })
        #expect(plugin.availability.isUnowned)
        // Switched on before its row froze, as Canobi's was.
        try await store.setBotEnabled(true, identity: plugin.identity, teammateID: teammate)
        let bot = ConnectorSettingsModel(store: store, teammateID: teammate)
        defer { bot.stopObserving() }
        await bot.load()
        let owned = bot.reading.definitions.filter { !$0.availability.isUnowned }
        #expect(owned.count == bound + 1)
        for definition in owned.prefix(bound) { await bot.setSelected(true, definition: definition) }
        #expect(bot.notice == nil, "the ninth working connector is refused only because of a row no launch can use")
        #expect(bot.reading.selectedIDs == Set(owned.prefix(bound).map(\.id)).union([plugin.id]))
        // Past what a launch can run, the switch still refuses in words.
        let extra = try #require(owned.last)
        await bot.setSelected(true, definition: extra)
        #expect(bot.notice == ConnectorCopy.tooManyConnectors)
        #expect(!bot.reading.selectedIDs.contains(extra.id))
    }

    /// Under a changed row, Settings once said
    /// "Turn it back on from that bot’s Access sheet", and for a row nothing in
    /// this build can run that sheet does not list it and no switch can turn
    /// it on.
    @Test("Under a changed row nothing in this build can run, the line says it cannot be turned back on and sends the user to no sheet")
    func theChangedLineUnderAnUnownedRowIsTrue() async throws {
        let repository = Repository()
        let probes: [any ConnectorAvailabilityProbing] = [OwnsCommand(command: OwnedAndUnownedCatalog.ownedCommand)]
        let before = try OwnedAndUnownedCatalog(ownedCount: 1)
        let first = ConnectorAccessStore(repository: repository,
                                         catalog: ConnectorCatalogAvailability(before, probes: probes))
        try await first.restore()
        let teammate = TeammateID(UUID())
        for connector in before.owned + [before.unowned] {
            try await first.setBotEnabled(true, identity: connector.definition.identity, teammateID: teammate)
        }
        // Both rows change underneath the grants.
        let after = try OwnedAndUnownedCatalog(ownedCount: 1, ownedDigest: String(repeating: "b", count: 64),
                                               unownedDigest: String(repeating: "f", count: 64))
        let store = ConnectorAccessStore(repository: repository,
                                         catalog: ConnectorCatalogAvailability(after, probes: probes))
        let settings = ConnectorSettingsModel(store: store)
        let bot = ConnectorSettingsModel(store: store, teammateID: teammate)
        defer { settings.stopObserving(); bot.stopObserving() }
        await settings.load(); await bot.load()
        let owned = try #require(settings.reading.definitions.first { !$0.availability.isUnowned })
        let plugin = try #require(settings.reading.definitions.first { $0.availability.isUnowned })
        #expect(settings.reading.changedSinceAllowed == [owned.id, plugin.id])
        #expect(settings.changedLine(for: owned) == ConnectorCopy.appWideChanged)
        #expect(settings.changedLine(for: plugin) == ConnectorCopy.changedAndUnowned)
        #expect(bot.changedLine(for: owned) == ConnectorCopy.botChanged)
        #expect(bot.changedLine(for: plugin) == ConnectorCopy.changedAndUnowned)
        #expect(ConnectorCopy.changedAndUnowned == "A bot’s own switch for this was turned off when it changed. "
            + "Nothing in this version of OpenBots Next can run this connector, so it cannot be turned back on for any bot.")
        // A row that did not change has no line.
        let unchanged = try ConnectorAccessStore(repository: Repository(), catalog: ConnectorCatalogAvailability(
            OwnedAndUnownedCatalog(ownedCount: 1), probes: probes))
        let quiet = ConnectorSettingsModel(store: unchanged)
        defer { quiet.stopObserving() }
        await quiet.load()
        #expect(quiet.reading.definitions.allSatisfy { quiet.changedLine(for: $0) == nil })
    }

    @Test("What the app-wide pane says about a switched-off row names whose switch it was")
    func theAppWideLineNamesWhoseSwitchWentOff() throws {
        // It used to read "This changed since it was allowed … so it was
        // switched off" directly beneath a row switch that was on — two
        // different objects six pixels apart, the nearer one contradicting the
        // sentence. That is the pane looking broken when it is not.
        #expect(ConnectorCopy.appWideChanged.contains("A bot’s own switch"))
        #expect(!ConnectorCopy.appWideChanged.contains("This changed since it was allowed"))
        // And not "a new version": the identity covers the whole configuration,
        // so a flag or a reinstall trips it with no version change.
        #expect(!ConnectorCopy.appWideChanged.contains("version"))
        #expect(ConnectorCopy.botChanged.contains("connected account changed"))
        #expect(ConnectorCopy.botChanged.contains("grant the current one"))
        #expect(ConnectorCopy.master.contains("Each row below turns one connector on or off for the whole app"))
    }

    /// The per-bot connector switches live on the bot's Access sheet, not on
    /// Details; "in its settings" would send the user to a pane that does not
    /// hold them.
    @Test("The master's sentence and the switched-off line send the user to the bot's Access sheet, not its settings")
    func theConnectorSentencesNameTheAccessSheet() {
        #expect(ConnectorCopy.master ==
            "This switch is the master. Each row below turns one connector on or off for the "
            + "whole app, and each bot still chooses its own on its Access sheet — all three have to be on.")
        #expect(ConnectorCopy.appWideChanged ==
            "A bot’s own switch for this was turned off when it changed. "
            + "Turn it back on from that bot’s Access sheet.")
    }

    @Test("Google's connect disclosure carries every authenticated-access fact before the button")
    func googleDisclosureIsComplete() {
        let copy = ConnectorCopy.googleAuthorizationDisclosure
        for required in ["Google", "Gmail", "Calendar", "gmail.readonly", "gmail.compose",
                         "calendar.calendarlist.readonly", "calendar.events.readonly", "also allows sending", "Gmail send row",
                         "on a card first",
                         "system browser", "never receives your password", "Keychain", "across launches",
                         "Google sign-in file", "original Google Desktop OAuth client JSON", "source file unchanged",
                         "only its issued client secret", "Disconnect disables local use first", "If you decline"] {
            #expect(copy.contains(required), "missing disclosure fact: \(required)")
        }
        // It names exactly the permissions the connect asks for, Drive's too.
        #expect(copy.contains("Drive"))
        for scope in GoogleWorkspaceOAuthScopes.required {
            let short = String(scope.split(separator: "/").last ?? "")
            #expect(copy.contains(short), "the disclosure does not name \(short)")
        }
        #expect(!copy.contains("both Google rows"))
        #expect(ConnectorCopy.googleConnectedAccount("openbots@example.com")
            == "Connected as openbots@example.com")
        // The pane once asked the user for an
        // "original Google OAuth client JSON" and spoke of a "cleanup token".
        // What it shows up front is plain now; the scope names wait behind a
        // disclosure. The file asked for is the same one.
        #expect(ConnectorCopy.googleClientConfigurationImportTitle(isReady: false)
            == "Choose the Google sign-in file…")
        #expect(ConnectorCopy.googleClientConfigurationImportTitle(isReady: true)
            == "Choose a new Google sign-in file…")
        #expect(ConnectorCopy.googleHeading(isConnected: false) == "Connect Google account")
        #expect(ConnectorCopy.googleHeading(isConnected: true) == "Google account")
        #expect(ConnectorCopy.googleSummary.components(separatedBy: ". ").count == 2, "two sentences")
        for fact in ["read", "Gmail", "Calendar", "Drive", "drafts", "cannot", "card"] {
            #expect(ConnectorCopy.googleSummary.contains(fact), "the summary does not say \(fact)")
        }
        let upFront = [ConnectorCopy.googleHeading(isConnected: false), ConnectorCopy.googleSummary,
                       ConnectorCopy.googleNotConnected, ConnectorCopy.googleConnectTitle,
                       ConnectorCopy.googleClientConfigurationImportTitle(isReady: false),
                       ConnectorCopy.googleClientConfigurationImportTitle(isReady: true),
                       ConnectorCopy.googleSignInFileReady, ConnectorCopy.googleSignInFileMissing,
                       ConnectorCopy.googleSignInFileSaved, ConnectorCopy.googleSignInFileNotSaved,
                       ConnectorCopy.googleSignInFileNotChosen, ConnectorCopy.googleDisconnectMessage,
                       ConnectorCopy.googleDisconnectUnconfirmed, ConnectorCopy.googleFinishDisconnectTitle]
        for sentence in upFront {
            for word in ["OAuth", "JSON", "token", "cleanup", "scope", "gmail.", "readonly", "Keychain", "revoke"] {
                #expect(!sentence.contains(word), "\(word): \(sentence)")
            }
        }
        let recovered = ConnectorCopy.googleConnectNotice(
            afterFailure: "The helper stopped.",
            status: .init(state: .connected, accountEmail: "openbots@example.com"))
        #expect(recovered.contains("finished connecting"))
        #expect(recovered.contains("verified the saved connection"))
        #expect(ConnectorCopy.googleConnectNotice(
            afterFailure: "The helper stopped.", status: .init(state: .disconnected))
            == "The helper stopped.")
    }

    @Test("Google client JSON crosses only inherited stdin and unlocks Connect by presence")
    func googleClientImportIsLocalAndOpaque() async throws {
        let sentinel = "GOCSPX-ui-import-sentinel"
        let fixture = try GoogleAuthorizationFixture(secret: sentinel)
        defer { fixture.remove() }
        let service = GoogleWorkspaceAuthorizationService(
            helperURL: fixture.helper,
            clientID: "openbots-test.apps.googleusercontent.com")
        let model = ConnectorSettingsModel(
            store: ConnectorAccessStore(repository: Repository(), catalog: try Catalog()),
            googleAuthorization: service)
        defer { model.stopObserving() }

        await model.load()
        #expect(model.googleClientConfigurationStatus?.state == .missing)
        #expect(!model.canConnectGoogle)
        let original = try Data(contentsOf: fixture.configuration)

        await model.importGoogleClientConfiguration(from: fixture.configuration)

        #expect(model.googleClientConfigurationStatus?.state == .ready)
        #expect(model.canConnectGoogle)
        // A Google account notice is said in the Google account section.
        #expect(model.googleNotice == ConnectorCopy.googleSignInFileSaved)
        #expect(model.googleNotice?.contains(sentinel) == false)
        #expect(model.notice == nil)
        #expect(try Data(contentsOf: fixture.configuration) == original)
    }

    /// The browser sent the user back to the app "for the reason", and the
    /// reason was drawn below every connector row, far from the Connect button
    /// just pressed.
    @Test("A failed connect says why in the Google account section, with the switch's page when there is one")
    func aFailedConnectSaysWhyBesideConnect() async throws {
        let page = "https://console.cloud.google.com/apis/library/drive.googleapis.com?project=123456"
        let sentence = "The Google Drive API is switched off in the Google Cloud project that holds the "
            + "OpenBots sign-in, project 123456. Press Enable on its page, \(page), then try again."
        for (offered, kept) in [(page, URL(string: page)), ("https://evil.example/enable", nil)] {
            let answer = try String(decoding: JSONSerialization.data(
                withJSONObject: ["error": sentence, "enable_page": offered], options: [.sortedKeys]), as: UTF8.self)
            let fixture = try GoogleAuthorizationFixture(secret: "GOCSPX-connect", configured: true,
                                                         authorizeAnswer: answer)
            defer { fixture.remove() }
            let model = ConnectorSettingsModel(
                store: ConnectorAccessStore(repository: Repository(), catalog: try Catalog()),
                googleAuthorization: GoogleWorkspaceAuthorizationService(
                    helperURL: fixture.helper, clientID: "openbots-test.apps.googleusercontent.com"))
            defer { model.stopObserving() }
            await model.load()
            #expect(model.canConnectGoogle)

            await model.connectGoogle()

            #expect(model.googleNotice == sentence)
            #expect(model.googleSwitchPage == kept, "offered \(offered)")
            #expect(model.notice == nil, "the reason is not drawn below the rows")
            #expect(model.googleStatus?.state == .disconnected)
            // Pressing Connect again starts clean.
            await model.connectGoogle()
            #expect(model.googleNotice == sentence)
            // The pane read again (its window reopened) shows the status it
            // reads now, not the last action's reason, as the notice did when
            // it was one line for the whole pane.
            await model.load()
            #expect(model.googleNotice == nil && model.googleSwitchPage == nil)
        }
    }

    @Test("Only the store being unreachable freezes an app-wide switch; a bot's freezes for two more reasons")
    func theTwoSwitchesFreezeForDifferentReasons() async throws {
        let dead = try Catalog(availability: .unavailable("This version cannot drive this connector yet."))
        let store = ConnectorAccessStore(repository: Repository(), catalog: dead)
        let master = ConnectorSettingsModel(store: store)
        let bot = ConnectorSettingsModel(store: store, teammateID: TeammateID(UUID()))
        defer { master.stopObserving(); bot.stopObserving() }
        await master.load(); await bot.load()
        let definition = try #require(master.reading.definitions.first)
        // The master caption promises every row below can be turned off, so a
        // row this build cannot drive must still take the switch.
        #expect(!master.appSwitchIsFrozen(definition))
        // A bot's grant to that same row is authority that could never be
        // exercised, so it fails closed.
        #expect(bot.botSwitchIsFrozen(definition))
        await master.setConnectorAppEnabled(false, definition: definition)
        await bot.load()
        // And a row killed for the whole app is not one bot's to revive.
        #expect(bot.botSwitchIsFrozen(definition))
        #expect(!master.appSwitchIsFrozen(definition))
    }

    @Test("Persistence failures are shown without publishing an enabled setting")
    func saveFailure() async throws {
        let repository = Repository()
        let model = ConnectorSettingsModel(store: ConnectorAccessStore(repository: repository, catalog: try Catalog()))
        defer { model.stopObserving() }
        await model.load()
        await repository.failWrites()
        await model.setAppEnabled(true)
        #expect(!model.reading.appEnabled && !model.reading.isAvailable)
        #expect(model.notice != nil && !model.isWorking)
    }


    @Test("An unavailable row cannot be switched on, and says why instead")
    func anUnavailableRowRefusesToBeEnabled() async throws {
        let fixture = try Catalog(availability: .unavailable("Mail is not installed on this Mac."))
        let model = ConnectorSettingsModel(store: ConnectorAccessStore(repository: Repository(), catalog: fixture),
                                           teammateID: TeammateID(UUID()))
        defer { model.stopObserving() }
        await model.load()
        let definition = try #require(model.reading.definitions.first)
        #expect(definition.availability.badge == "unavailable")
        #expect(!definition.availability.canBeEnabled)
        await model.setSelected(true, definition: definition)
        #expect(model.reading.selectedIDs.isEmpty)
        #expect(model.notice == "Mail is not installed on this Mac.")
    }

    @Test("A needs-setup row can still be switched on, so the selection is ready when the setup is")
    func aNeedsSetupRowCanBeEnabled() async throws {
        let fixture = try Catalog(availability: .needsSetup("Install it once with `uv tool install x`."))
        let model = ConnectorSettingsModel(store: ConnectorAccessStore(repository: Repository(), catalog: fixture),
                                           teammateID: TeammateID(UUID()))
        defer { model.stopObserving() }
        await model.load()
        let definition = try #require(model.reading.definitions.first)
        #expect(definition.availability.badge == "needs setup")
        await model.setSelected(true, definition: definition)
        #expect(model.reading.selectedIDs == [definition.id])
    }

    @Test("A row that went unavailable while it was on can still be switched off")
    func anUnavailableRowCanStillBeSwitchedOff() async throws {
        let repository = Repository()
        let ready = try Catalog()
        let model = ConnectorSettingsModel(store: ConnectorAccessStore(repository: repository, catalog: ready),
                                           teammateID: TeammateID(UUID()))
        defer { model.stopObserving() }
        await model.load()
        let definition = try #require(model.reading.definitions.first)
        await model.setSelected(true, definition: definition)
        #expect(model.reading.selectedIDs == [definition.id])
        // The same row, now unavailable: turning it off must not be refused.
        let gone = try Catalog(availability: .unavailable("Mail is not installed on this Mac.")).connector.definition
        await model.setSelected(false, definition: gone)
        #expect(model.reading.selectedIDs.isEmpty)
    }

    @Test("A row Claude Code configured keeps reading exactly as it did")
    func aPluginRowKeepsItsOldCopy() async throws {
        let fixture = try Catalog()
        #expect(fixture.connector.definition.title == "docs")
        #expect(fixture.connector.definition.summary == "Configured in Claude Code · docs@fixture")
        #expect(fixture.connector.definition.availability.badge == nil)
    }

    private struct Catalog: ConnectorCatalogReading {
        let connector: ConfiguredConnector
        init(availability: ConnectorAvailability = .ready,
             digest: String = String(repeating: "a", count: 64)) throws {
            connector = .init(definition: .init(identity: try .init(id: "claude-plugin:docs@fixture:docs", digest: digest),
                serverName: "docs", pluginName: "docs@fixture", transport: .http, availability: availability),
                launch: .init(serverKey: "fixture", transport: .http, url: URL(string: "https://example.test/mcp")!))
        }
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot { .init(connectors: [connector]) }
    }
    private struct ManyCatalog: ConnectorCatalogReading {
        let connectors: [ConfiguredConnector]
        init(count: Int) throws {
            connectors = try (0..<count).map { index in
                ConfiguredConnector(
                    definition: .init(identity: try .init(id: "claude-plugin:docs\(index)@fixture:docs\(index)",
                                                          digest: String(repeating: "a", count: 64)),
                                      serverName: "docs\(index)", pluginName: "docs\(index)@fixture", transport: .http),
                    launch: .init(serverKey: "fixture\(index)", transport: .http,
                                  url: URL(string: "https://example.test/mcp\(index)")!))
            }
        }
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot { .init(connectors: connectors) }
    }
    /// Rows a preparation owns, and one Claude Code plugin no preparation owns,
    /// composed the way the app composes its catalog.
    private struct OwnedAndUnownedCatalog: ConnectorCatalogReading {
        static let ownedCommand = "owned-connector-fixture"
        let owned: [ConfiguredConnector]
        let unowned: ConfiguredConnector
        init(ownedCount: Int, ownedDigest: String = String(repeating: "a", count: 64),
             unownedDigest: String = String(repeating: "e", count: 64)) throws {
            owned = try (0..<ownedCount).map { index in
                ConfiguredConnector(
                    definition: .init(identity: try .init(id: "openbots:owned\(index):owned\(index)",
                                                          digest: ownedDigest),
                                      serverName: "owned\(index)", pluginName: "owned\(index)", transport: .stdio),
                    launch: .init(serverKey: "", transport: .stdio, command: Self.ownedCommand))
            }
            unowned = ConfiguredConnector(
                definition: .init(identity: try .init(id: "claude-plugin:imessage@claude-plugins-official:imessage",
                                                      digest: unownedDigest),
                                  serverName: "imessage", pluginName: "imessage@claude-plugins-official", transport: .stdio),
                launch: .init(serverKey: "", transport: .stdio, command: "bun"))
        }
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot { .init(connectors: owned + [unowned]) }
    }
    private struct OwnsCommand: ConnectorAvailabilityProbing {
        let command: String
        func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
            launch.command == command ? .ready : nil
        }
    }
    private actor Repository: ConnectorAccessRepository {
        var state = ConnectorAccessState()
        var failing = false
        func failWrites() { failing = true }
        func loadConnectorAccess() async throws -> ConnectorAccessState { state }
        func saveConnectorAccess(_ state: ConnectorAccessState, expectedRevision: Int64) async throws {
            if failing { throw ConnectorAccessError.unavailable }
            guard self.state.revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
            self.state = state
        }
    }

    private struct GoogleAuthorizationFixture {
        let root: URL
        let helper: URL
        let configuration: URL

        init(secret: String, configured: Bool = false, authorizeAnswer: String? = nil) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("openbots-google-ui-import-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
            helper = root.appendingPathComponent("openbots-google-helper")
            configuration = root.appendingPathComponent("oauth-client.json")
            let source = try JSONSerialization.data(withJSONObject: [
                "installed": [
                    "client_id": "openbots-test.apps.googleusercontent.com",
                    "client_secret": secret,
                ],
            ], options: [.sortedKeys])
            try source.write(to: configuration)

            let body = "#!/bin/sh\ncase \"$1\" in\n"
                + "  status) printf '%s\\n' '{\"state\":\"disconnected\"}' ;;\n"
                + "  client_configuration_status) printf '%s\\n' '{\"state\":\"\(configured ? "ready" : "missing")\"}' ;;\n"
                + (authorizeAnswer.map { "  authorize) printf '%s\\n' '\($0)'; exit 1 ;;\n" } ?? "")
                + "  import_client_configuration)\n"
                + "    case \" $* \" in *'\(secret)'*) exit 31 ;; esac\n"
                + "    /usr/bin/env | /usr/bin/grep -Fq '\(secret)' && exit 32\n"
                + "    payload=$(/bin/cat)\n"
                + "    case \"$payload\" in *'\(secret)'*) printf '%s\\n' '{\"state\":\"ready\"}' ;; *) exit 33 ;; esac ;;\n"
                + "  *) exit 34 ;;\n"
                + "esac\n"
            try Data(body.utf8).write(to: helper)
            try FileManager().setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: helper.path)
        }

        func remove() { try? FileManager().removeItem(at: root) }
    }
}
