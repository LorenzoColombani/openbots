import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsServices
import Testing

@Suite("Configured connector grants and revocation")
struct ConnectorAccessStoreTests {
    @Test("App master AND exact per-bot selection survive a real reopen; old off/on leases never revive")
    func durableGrantsAndRevisions() async throws {
        let f = try Fixture(); defer { f.remove() }
        let a = TeammateID(UUID()), b = TeammateID(UUID())
        let catalog = MutableCatalog(try connector())
        let identity = try connector().definition.identity
        var firstLease: ConnectorAccessLease?
        var finalRevision: Int64 = 0
        weak var closed: SQLiteStore?
        do {
            let db = try f.open(); closed = db
            let store = ConnectorAccessStore(repository: db, catalog: catalog)
            #expect(await store.lease(teammateID: a) == nil)
            try await store.restore()
            #expect(await store.current().isAvailable)
            try await store.setBotEnabled(true, identity: identity, teammateID: a)
            #expect(await store.lease(teammateID: a) == nil)
            try await store.setAppEnabled(true)
            let captured = try #require(await store.lease(teammateID: a))
            firstLease = captured
            #expect(await store.lease(teammateID: b) == nil)
            try await store.refreshCatalog()
            #expect(await store.isCurrent(try #require(firstLease)), "An unchanged metadata refresh must not stop another running bot")
            try await store.setAppEnabled(false)
            #expect(await store.lease(teammateID: a) == nil)
            try await store.setAppEnabled(true)
            #expect(await !store.isCurrent(try #require(firstLease)))
            let second = try #require(await store.lease(teammateID: a))
            #expect(second.revision > (try #require(firstLease)).revision)
            try await store.setBotEnabled(false, identity: identity, teammateID: a)
            try await store.setBotEnabled(true, identity: identity, teammateID: a)
            #expect(await !store.isCurrent(second))
            finalRevision = await store.current().revision
        }
        #expect(closed == nil)
        let db = try f.open()
        let reopened = ConnectorAccessStore(repository: db, catalog: catalog)
        try await reopened.restore()
        let lease = try #require(await reopened.lease(teammateID: a))
        #expect(lease.revision == finalRevision)
        #expect(await !reopened.isCurrent(try #require(firstLease)))
        #expect(try await reopened.configurations(for: lease).count == 1)
        let rows = try await db.query(sql: "SELECT value FROM app_metadata WHERE key='connector_access_v1';")
        let raw = try #require(rows.first).text("value")
        #expect(!raw.contains("https://") && !raw.contains("command") && !raw.contains("arguments") && !raw.contains("headers"))
    }

    /// A deleted bot's grants go with it, through the store: editing the
    /// record behind the store's back would
    /// leave its revision stale and take every connector dark at the next switch.
    @Test("A deleted bot's grants are forgotten through the store, and the next switch still saves")
    func forgettingADeletedBotsGrants() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), gone = TeammateID(UUID()), kept = TeammateID(UUID())
        let identity = try connector().definition.identity
        let store = ConnectorAccessStore(repository: db, catalog: MutableCatalog(try connector()))
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: identity, teammateID: gone)
        try await store.setBotEnabled(true, identity: identity, teammateID: kept)
        let before = await store.current().revision

        try await store.forgetGrants(teammateID: gone)

        let saved = try await db.loadConnectorAccess()
        #expect(saved.grants.map(\.teammateID) == [kept])
        #expect(saved.revision == before + 1)
        #expect(await store.lease(teammateID: gone) == nil)
        #expect(await store.lease(teammateID: kept) != nil)
        try await store.setBotEnabled(false, identity: identity, teammateID: kept)
        #expect(await store.current().isAvailable)
        // A bot that had no grant changes nothing.
        try await store.forgetGrants(teammateID: TeammateID(UUID()))
        #expect(try await db.loadConnectorAccess().revision == before + 2)
    }

    @Test("Definition changes revoke old selections durably, including when the original configuration returns")
    func configurationABA() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector(), changed = try connector(digest: "b")
        let catalog = MutableCatalog(original)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        let lease = try #require(await store.lease(teammateID: a))
        await catalog.replace(changed)
        try await store.refreshCatalog()
        #expect(await !store.isCurrent(lease))
        #expect(await store.current(teammateID: a).selectedIDs.isEmpty)
        await #expect(throws: ConnectorAccessError.definitionChanged) {
            try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        }
        await catalog.replace(original)
        try await store.refreshCatalog()
        #expect(await store.lease(teammateID: a) == nil)
        let state = try await db.loadConnectorAccess()
        #expect(state.revision > lease.revision && state.grants.allSatisfy { !$0.enabled })
        let restored = ConnectorAccessStore(repository: db, catalog: catalog)
        try await restored.restore()
        #expect(await restored.lease(teammateID: a) == nil)
    }

    @Test("A row that cannot tell who it is right now keeps the grant the user gave, through a refresh and a reopen")
    func anUnsureRowKeepsItsGrant() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector()
        let unsure = try connector(digest: "b", holdsPriorIdentity: true)
        let catalog = MutableCatalog(original)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        let lease = try #require(await store.lease(teammateID: a))

        await catalog.replace(unsure)
        try await store.refreshCatalog()
        #expect(await store.isCurrent(lease), "Not knowing is not a change")
        #expect(await store.current(teammateID: a).selectedIDs == [original.definition.id])
        #expect(await store.current().definitions.map(\.identity) == [original.definition.identity])

        await catalog.replace(original)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: a).selectedIDs == [original.definition.id])

        await catalog.replace(unsure)
        let reopened = ConnectorAccessStore(repository: db, catalog: catalog)
        try await reopened.restore()
        #expect(await reopened.current(teammateID: a).selectedIDs == [original.definition.id])
        #expect(try await db.loadConnectorAccess().grants.allSatisfy { $0.enabled && !$0.revokedByChange })
    }

    @Test("An unsure row with nothing before it is simply the row it loaded as")
    func anUnsureRowWithNoPastIsItself() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open()
        let unsure = try connector(digest: "b", holdsPriorIdentity: true)
        let store = ConnectorAccessStore(repository: db, catalog: MutableCatalog(unsure))
        try await store.restore()
        #expect(await store.current().definitions.map(\.identity) == [unsure.definition.identity])
    }

    @Test("A switch the user turned off themselves is never blamed on a later version bump")
    func theUsersOwnOffIsNotBlamedOnAChange() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector(), bumped = try connector(digest: "b")
        let catalog = MutableCatalog(original)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        // The user turns it off. That writes a disabled grant carrying the
        // identity of the day, which is the shape the whole question turns on.
        try await store.setBotEnabled(false, identity: original.definition.identity, teammateID: a)
        await catalog.replace(bumped)
        try await store.refreshCatalog()
        // The row did change. The grant was not revoked by it — it was already
        // off — so saying a new version switched it off is a lie, and one
        // that nags the user to turn on something they deliberately turned off.
        #expect(await store.current(teammateID: a).changedSinceAllowed.isEmpty)
        #expect(await store.current().changedSinceAllowed.isEmpty)
        let reopened = ConnectorAccessStore(repository: try f.open(), catalog: catalog)
        try await reopened.restore()
        #expect(await reopened.current(teammateID: a).changedSinceAllowed.isEmpty)
    }

    @Test("A plugin rolled back to the version the user allowed still says it was switched off")
    func aRolledBackPluginStillSaysItWasSwitchedOff() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector(), bumped = try connector(digest: "b")
        let catalog = MutableCatalog(original)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        await catalog.replace(bumped)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: a).changedSinceAllowed.contains(original.definition.identity.id))
        // Back to the version the user allowed — a pinned plugin, a rolled-back cache.
        // `configurationABA` already pins that the grant stays off; the switch
        // being off with nothing said is the exact silence this line exists to
        // end, and an identity that matches again cannot see it.
        await catalog.replace(original)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: a).selectedIDs.isEmpty)
        #expect(await store.current(teammateID: a).changedSinceAllowed.contains(original.definition.identity.id))
        let reopened = ConnectorAccessStore(repository: try f.open(), catalog: catalog)
        try await reopened.restore()
        #expect(await reopened.current(teammateID: a).changedSinceAllowed.contains(original.definition.identity.id))
        // And it stops the moment the user touches the switch.
        try await reopened.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        #expect(await reopened.current(teammateID: a).changedSinceAllowed.isEmpty)
    }

    @Test("A record written before the reason existed keeps its switched-off rows saying why")
    func theOneTimeSeedFillsInAnExistingRecord() throws {
        // The shape an older build's record held: no
        // `revokedByChange`, no `grantFlagsSeeded`, one grant off at a digest
        // the catalog has moved past and one off at the digest it still has.
        let json = """
        {"revision":25,"appEnabled":true,
         "catalog":[{"id":"claude-plugin:chrome-devtools-mcp@p:chrome-devtools","digest":"\(String(repeating: "6", count: 64))"},
                    {"id":"claude-plugin:imessage@p:imessage","digest":"\(String(repeating: "4", count: 64))"}],
         "grants":[{"teammateID":"\(UUID().uuidString)","enabled":false,
                    "identity":{"id":"claude-plugin:chrome-devtools-mcp@p:chrome-devtools","digest":"\(String(repeating: "4", count: 64))"}},
                   {"teammateID":"\(UUID().uuidString)","enabled":false,
                    "identity":{"id":"claude-plugin:imessage@p:imessage","digest":"\(String(repeating: "4", count: 64))"}}]}
        """
        let decoded = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(json.utf8))
        #expect(!decoded.grantFlagsSeeded)
        #expect(decoded.grants.allSatisfy { !$0.revokedByChange })
        let seeded = decoded.seedingGrantFlags()
        #expect(seeded.grantFlagsSeeded)
        // The row whose browser was lost to the change reads as revoked by it.
        #expect(try #require(seeded.grants.first { $0.identity.id.contains("chrome-devtools") }).revokedByChange)
        // The one still at the digest it was allowed at was the user's own doing.
        #expect(!(try #require(seeded.grants.first { $0.identity.id.contains("imessage") }).revokedByChange))
        // And the guess is made once: seeding again changes nothing.
        #expect(seeded.seedingGrantFlags() == seeded)
        // A save carries the field, so the next load has nothing to guess.
        let round = try JSONDecoder().decode(ConnectorAccessState.self, from: JSONEncoder().encode(seeded))
        #expect(round == seeded && round.grantFlagsSeeded)
    }

    @Test("The one-time fill-in is written to disk, so the guess is never made twice")
    func theSeedIsPersistedNotJustHeldInMemory() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector(), bumped = try connector(digest: "b")
        let catalog = MutableCatalog(bumped)
        // A record of the old shape: off at a digest the catalog has moved past,
        // and no field saying why.
        let old = ConnectorAccessState(revision: 1, appEnabled: true,
            catalog: [bumped.definition.identity],
            grants: [.init(teammateID: a, identity: original.definition.identity, enabled: false)],
            grantFlagsSeeded: false)
        try await db.saveConnectorAccess(old, expectedRevision: 0)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        #expect(await store.current(teammateID: a).changedSinceAllowed.contains(original.definition.identity.id))
        let written = try await db.loadConnectorAccess()
        #expect(written.grantFlagsSeeded, "the marker has to reach the disk or the guess repeats")
        #expect(try #require(written.grants.first).revokedByChange)
        #expect(written.revision > old.revision)
    }

    @Test("A failed revoke write leaves live access unavailable and emits a change")
    func failedWriteFailsClosed() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let configured = try connector()
        let store = ConnectorAccessStore(repository: db, catalog: MutableCatalog(configured))
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: configured.definition.identity, teammateID: a)
        let lease = try #require(await store.lease(teammateID: a))
        let changes = await store.changes()
        let observed = Task { () -> Bool in
            var iterator = changes.makeAsyncIterator()
            return await iterator.next() != nil
        }
        _ = try await db.execute(sql: """
            CREATE TRIGGER reject_connector_write BEFORE UPDATE ON app_metadata
            WHEN NEW.key='connector_access_v1' BEGIN SELECT RAISE(ABORT,'fixture write failure'); END;
            """)
        await #expect(throws: ConnectorAccessError.unavailable) { try await store.setAppEnabled(false) }
        #expect(await observed.value)
        #expect(await !store.isCurrent(lease))
        #expect(await !store.current().isAvailable)
        #expect(await store.lease(teammateID: a) == nil)
        #expect(try await db.loadConnectorAccess().appEnabled, "The failed DB write is not misreported as persisted")
    }

    @Test("A catalog read failure removes live authority without treating absence as a successful connection")
    func discoveryFailureFailsClosed() async throws {
        let f = try Fixture(); defer { f.remove() }
        let a = TeammateID(UUID()), configured = try connector()
        let catalog = MutableCatalog(configured)
        let store = ConnectorAccessStore(repository: try f.open(), catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: configured.definition.identity, teammateID: a)
        let lease = try #require(await store.lease(teammateID: a))
        await catalog.fail()
        await #expect(throws: ConnectorAccessError.unavailable) { try await store.refreshCatalog() }
        #expect(await !store.isCurrent(lease))
        #expect(await store.current().definitions.isEmpty)
    }

    @Test("A connector switched off for the whole app is in no bot's lease, and its grant survives")
    func theAppWideKillSwitch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let one = try connector()
        let catalog = MutableCatalog(one)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: one.definition.identity, teammateID: a)
        let lease = try #require(await store.lease(teammateID: a))
        // The app-wide kill switch: off for the whole app, and no bot may launch it.
        try await store.setConnectorAppEnabled(false, id: one.definition.id)
        #expect(await store.lease(teammateID: a) == nil)
        #expect(await !store.isCurrent(lease))
        #expect(await store.current().appDisabledIDs.contains(one.definition.id))
        // The bot's own selection is untouched, because killing a connector for
        // the app is not a decision about any one bot — turning it back on must
        // not make the user set every bot again.
        #expect(await store.current(teammateID: a).selectedIDs.contains(one.definition.id))
        try await store.setConnectorAppEnabled(true, id: one.definition.id)
        #expect(await store.lease(teammateID: a) != nil)
    }

    @Test("A kill survives a reopen, and a new version of the same row stays killed")
    func theKillIsDurableAndOutlivesAVersionBump() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector(), bumped = try connector(digest: "b")
        let catalog = MutableCatalog(original)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        try await store.setConnectorAppEnabled(false, id: original.definition.id)
        let reopened = ConnectorAccessStore(repository: try f.open(), catalog: catalog)
        try await reopened.restore()
        #expect(await reopened.current().appDisabledIDs.contains(original.definition.id))
        #expect(await reopened.lease(teammateID: a) == nil)
        // The kill is keyed by the row's id, not by the exact configuration it
        // had when the user killed it: a plugin naming a new version must not hand
        // back something they switched off.
        await catalog.replace(bumped)
        try await reopened.refreshCatalog()
        #expect(await reopened.current().appDisabledIDs.contains(original.definition.id))
        try await reopened.setBotEnabled(true, identity: bumped.definition.identity, teammateID: a)
        #expect(await reopened.lease(teammateID: a) == nil)
    }

    @Test("A row this build cannot drive can still be killed, and the kill is the user's decision alone")
    func anUndrivableRowCanStillBeKilled() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open()
        let dead = try connector(id: "claude-plugin:browser-use@claude-plugins-official:browser-use",
                                 server: "browser-use", availability: .unavailable("Cannot drive this yet."))
        let store = ConnectorAccessStore(repository: db, catalog: PairCatalog(
            first: dead, second: try connector(id: "claude-plugin:a@o:a", server: "a")))
        try await store.restore()
        try await store.setAppEnabled(true)
        // The switch records what the user decided about the connector, not whether
        // this build happens to be able to run it. A later build that CAN run
        // it must find that decision waiting, not turn itself on.
        try await store.setConnectorAppEnabled(false, id: dead.definition.id)
        #expect(await store.current().appDisabledIDs.contains(dead.definition.id))
        let reopened = ConnectorAccessStore(repository: try f.open(), catalog: PairCatalog(
            first: dead, second: try connector(id: "claude-plugin:a@o:a", server: "a")))
        try await reopened.restore()
        #expect(await reopened.current().appDisabledIDs.contains(dead.definition.id))
    }

    // MARK: the chats a bot may read in Messages

    @Test("Each bot's chats are its own, reach only its Messages launch, and survive a reopen")
    func eachBotsChatsReachOnlyItsMessagesLaunch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let a = TeammateID(UUID()), b = TeammateID(UUID())
        let messages = try messagesConnector(), docs = try connector()
        let catalog = PairCatalog(first: messages, second: docs)
        let chosen = ["any;-;+33612345678", "any;+;chat123456789012345678"]
        do {
            let store = ConnectorAccessStore(repository: try f.open(), catalog: catalog)
            try await store.restore()
            try await store.setAppEnabled(true)
            for bot in [a, b] {
                try await store.setBotEnabled(true, identity: messages.definition.identity, teammateID: bot)
                try await store.setBotEnabled(true, identity: docs.definition.identity, teammateID: bot)
            }
            let before = try #require(await store.lease(teammateID: a))
            try await store.setMessagesChats(chosen, teammateID: a)
            // A list changed while a turn is being launched withdraws that launch,
            // as every other change here does.
            #expect(await !store.isCurrent(before))
            #expect(await store.messagesChats(teammateID: a) == AppleMessagesChatScope(guids: chosen))
            #expect(await store.messagesChats(teammateID: b).isEmpty)
        }
        let store = ConnectorAccessStore(repository: try f.open(), catalog: catalog)
        try await store.restore()
        let launchesA = try await store.configurations(for: try #require(await store.lease(teammateID: a)))
        let launchesB = try await store.configurations(for: try #require(await store.lease(teammateID: b)))
        func messagesLaunch(_ launches: [ConfiguredConnector]) -> ConnectorLaunchConfiguration? {
            launches.first { $0.launch.command == AppleMessagesConnectorPreparation.command }?.launch
        }
        #expect(messagesLaunch(launchesA)?.chatScope == AppleMessagesChatScope(guids: chosen))
        // A bot with none named launches with an empty list, which reads nothing,
        // never with no list at all.
        #expect(messagesLaunch(launchesB)?.chatScope == AppleMessagesChatScope(guids: []))
        #expect(launchesA.filter { $0.launch.command != AppleMessagesConnectorPreparation.command }
            .allSatisfy { $0.launch.chatScope == nil })
    }

    @Test("A list that cannot be kept is refused without taking any connector dark, and the old list stays")
    func aListThatCannotBeKeptIsRefused() async throws {
        let f = try Fixture(); defer { f.remove() }
        let bot = TeammateID(UUID())
        let messages = try messagesConnector()
        let store = ConnectorAccessStore(repository: try f.open(), catalog: PairCatalog(first: messages, second: try connector()))
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: messages.definition.identity, teammateID: bot)
        try await store.setMessagesChats(["any;-;+33612345678"], teammateID: bot)
        let tooMany = (0...AppleMessagesChatScope.maximumChats).map { "any;-;+3361234\($0)" }
        let tooLong = ["any;-;" + String(repeating: "9", count: AppleMessagesChatScope.maximumGUIDBytes)]
        for refused in [tooMany, tooLong, [""], ["any;-;\u{0}"], ["any;-;a\nb"]] {
            await #expect(throws: ConnectorAccessError.invalidState) {
                try await store.setMessagesChats(refused, teammateID: bot)
            }
            #expect(await store.current().isAvailable)
            #expect(await store.lease(teammateID: bot) != nil)
            #expect(await store.messagesChats(teammateID: bot) == AppleMessagesChatScope(guids: ["any;-;+33612345678"]))
        }
    }

    @Test("Switching Messages off keeps the chats the user chose; an empty list and Delete remove them")
    func theListOutlivesTheSwitchButNotTheBot() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), bot = TeammateID(UUID()), listOnly = TeammateID(UUID())
        let messages = try messagesConnector()
        let store = ConnectorAccessStore(repository: db, catalog: PairCatalog(first: messages, second: try connector()))
        try await store.restore()
        try await store.setBotEnabled(true, identity: messages.definition.identity, teammateID: bot)
        try await store.setMessagesChats(["any;-;+33612345678"], teammateID: bot)
        try await store.setBotEnabled(false, identity: messages.definition.identity, teammateID: bot)
        #expect(await store.messagesChats(teammateID: bot) == AppleMessagesChatScope(guids: ["any;-;+33612345678"]))
        try await store.setMessagesChats([], teammateID: bot)
        #expect(try await db.loadConnectorAccess().messagesChats.isEmpty)
        // A bot that has a list and no grant at all is still forgotten whole.
        try await store.setMessagesChats(["any;-;+33612345678"], teammateID: listOnly)
        try await store.forgetGrants(teammateID: listOnly)
        #expect(try await db.loadConnectorAccess().messagesChats.isEmpty)
        #expect(await store.messagesChats(teammateID: listOnly).isEmpty)
        #expect(await store.current().isAvailable)
    }

    @Test("A record written before the chat lists existed decodes with no chats named")
    func anOlderRecordNamesNoChats() throws {
        let raw = """
        {"revision":26,"appEnabled":true,"catalog":[],"grants":[],"grantFlagsSeeded":true,"appDisabledIDs":[]}
        """
        let state = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(raw.utf8))
        #expect(state.messagesChats.isEmpty)
        try state.validate()
    }

    @Test("A record written before the kill switch existed decodes with nothing killed")
    func anOlderRecordKillsNothing() throws {
        // An older build's record has no such field. Decoding it
        // strictly would fail the whole read and take every connector dark.
        let raw = """
        {"revision":26,"appEnabled":true,"catalog":[],"grants":[],"grantFlagsSeeded":true}
        """
        let state = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(raw.utf8))
        #expect(state.appDisabledIDs.isEmpty)
        #expect(state.appEnabled)
        try state.validate()
    }

    /// The rollback check. A build that lists
    /// the Claude Desktop extensions stores their rows under a source the build
    /// before it has never heard of, in the catalog at its first launch, before
    /// any bot is given one. Read strictly, that one row failed the whole record
    /// and took every connector dark on the build one would roll back to. The
    /// source here is one no build knows yet: once `claude-extension` became a
    /// known source, a fixture spelled with it would have tested nothing.
    @Test("A row from a source this build does not know is left out, and the rest of the record still reads")
    func aRowFromAnUnknownSourceIsLeftOut() throws {
        let raw = try recordHoldingAnExtensionRow(bot: TeammateID(UUID()))
        let state = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(raw.utf8))
        try state.validate()
        #expect(state.catalog.map(\.id) == ["claude-plugin:docs@fixture:docs"])
        #expect(state.grants.map(\.identity.id) == ["claude-plugin:docs@fixture:docs"])
        // The app-wide kill of the unknown row is kept: it is only a name, and
        // it must still be killed when the user rolls forward again.
        #expect(state.appDisabledIDs == [Self.extensionID])
    }

    @Test("A row from a source this build does not know leaves every other connector working after a reopen")
    func aRowFromAnUnknownSourceKeepsTheOthersLive() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), bot = TeammateID(UUID())
        _ = try await db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('connector_access_v1',?);",
                                 bindings: [.text(try recordHoldingAnExtensionRow(bot: bot))])
        let store = ConnectorAccessStore(repository: db, catalog: MutableCatalog(try connector()))
        try await store.restore()
        #expect(await store.current().isAvailable)
        #expect(await store.current().appEnabled)
        let lease = try #require(await store.lease(teammateID: bot))
        #expect(lease.identities.map(\.id) == ["claude-plugin:docs@fixture:docs"])
    }

    @Test("A row from a source this build knows is still refused whole when it is malformed")
    func aMalformedRowFromAKnownSourceStillFailsClosed() throws {
        let raw = try recordHoldingAnExtensionRow(bot: TeammateID(UUID()))
            .replacingOccurrences(of: Self.extensionID, with: "claude-plugin:no-owner:notes")
        let state = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(raw.utf8))
        #expect(throws: ConnectorAccessError.invalidState) { try state.validate() }
    }

    private static let extensionID = "claude-future:ant.dir.ant.anthropic.notes:notes"

    /// The record the next build writes: a plugin row and an extension row in
    /// the catalog, a bot allowed both, and the extension killed app-wide. The
    /// extension's identity cannot be minted by a build that does not know its
    /// source, so it is written as the next build encodes it and renamed.
    private func recordHoldingAnExtensionRow(bot: TeammateID) throws -> String {
        let docs = try connector().definition.identity
        let stand = try ConnectorIdentity(id: "claude-plugin:stand-in@fixture:notes",
                                          digest: String(repeating: "b", count: 64))
        let state = ConnectorAccessState(revision: 3, appEnabled: true, catalog: [docs, stand],
            grants: [.init(teammateID: bot, identity: docs, enabled: true),
                     .init(teammateID: bot, identity: stand, enabled: true)],
            appDisabledIDs: [stand.id])
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(state), as: UTF8.self)
            .replacingOccurrences(of: stand.id, with: Self.extensionID)
    }

    @Test("The pane reads the rows that work first, and the dead one last")
    func theListPutsWhatWorksFirst() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open()
        // The pair that shows the problem: `browser-use` sorts first by name and this
        // build cannot drive it, and the browser that works sat underneath.
        let store = ConnectorAccessStore(repository: db, catalog: PairCatalog(
            first: try connector(id: "claude-plugin:browser-use@official:browser-use", server: "browser-use",
                                 availability: .unavailable("Cannot drive this yet.")),
            second: try connector(id: "claude-plugin:chrome-devtools@official:chrome-devtools",
                                  server: "chrome-devtools")))
        try await store.restore()
        #expect(await store.current().definitions.map(\.serverName) == ["chrome-devtools", "browser-use"])
    }

    // MARK: rows gone from the catalog, revocation reasons and kill pruning

    @Test("A row gone from the catalog is not named as changed, and the reason comes back with the row")
    func aRowGoneFromTheCatalogIsNotNamedAsChanged() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), a = TeammateID(UUID())
        let original = try connector(), bumped = try connector(digest: "b")
        let catalog = MutableCatalog(original)
        let store = ConnectorAccessStore(repository: db, catalog: catalog)
        try await store.restore()
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: a)
        await catalog.replace(bumped)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: a).changedSinceAllowed == [original.definition.id])
        // Uninstalled: nothing in the catalog holds the id, so nothing may count it.
        await catalog.replace(try connector(id: "claude-plugin:other@fixture:other", server: "other"))
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: a).changedSinceAllowed.isEmpty)
        #expect(await store.current().changedSinceAllowed.isEmpty)
        // The grant still records why it is off, so reinstalling brings the line back.
        await catalog.replace(bumped)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: a).changedSinceAllowed == [original.definition.id])
        #expect(await store.current().changedSinceAllowed == [original.definition.id])
    }

    @Test("An enabled grant that carries a revocation reason is refused")
    func anEnabledGrantCannotCarryARevocationReason() throws {
        let identity = try connector().definition.identity, bot = TeammateID(UUID())
        // The grant is in the catalog, so the neighbouring clause cannot be what refuses it.
        let off = ConnectorAccessState(catalog: [identity],
            grants: [.init(teammateID: bot, identity: identity, enabled: false, revokedByChange: true)])
        try off.validate()
        let contradicted = ConnectorAccessState(catalog: [identity],
            grants: [.init(teammateID: bot, identity: identity, enabled: true, revokedByChange: true)])
        #expect(throws: ConnectorAccessError.invalidState) { try contradicted.validate() }
    }

    @Test("The app-wide line counts only bots the workspace still lists")
    func theAppWideLineCountsOnlyListedBots() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), listed = TeammateID(UUID()), archived = TeammateID(UUID())
        let original = try connector(), bumped = try connector(digest: "b")
        let catalog = MutableCatalog(original)
        let roster = Roster([listed, archived])
        let store = ConnectorAccessStore(repository: db, catalog: catalog,
                                         listedTeammates: { try await roster.ids() })
        try await store.restore()
        try await store.setBotEnabled(true, identity: original.definition.identity, teammateID: archived)
        await catalog.replace(bumped)
        try await store.refreshCatalog()
        #expect(await store.current().changedSinceAllowed == [original.definition.id])
        // Archived: no listed bot has a switch that would answer the line.
        await roster.set([listed])
        #expect(await store.current().changedSinceAllowed.isEmpty)
        // Archiving is reversible and keeps the grant, so its own pane still says why.
        #expect(await store.current(teammateID: archived).changedSinceAllowed == [original.definition.id])
        await roster.set([listed, archived])
        #expect(await store.current().changedSinceAllowed == [original.definition.id])
        // A roster that cannot be read counts every bot: the line fails toward showing.
        await roster.set([listed])
        await roster.fail()
        #expect(await store.current().changedSinceAllowed == [original.definition.id])
    }

    @Test("A kill is pruned once its id has been gone from the catalog for 90 days, and not a day before")
    func aKillIsPrunedAfterNinetyDaysGone() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gone = try connector(id: "claude-plugin:gone@fixture:gone", server: "gone")
        let catalog = MutableCatalog(gone)
        let store = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day0))
        try await store.restore()
        try await store.setConnectorAppEnabled(false, id: gone.definition.id)
        await catalog.replace(try connector())
        try await store.refreshCatalog()
        #expect(await store.current().appDisabledIDs == [gone.definition.id])
        #expect(try await f.open().loadConnectorAccess().appDisabledAbsentSince == [gone.definition.id: Self.day0])
        let day89 = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(89)))
        try await day89.restore()
        #expect(await day89.current().appDisabledIDs == [gone.definition.id])
        let day90 = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(90)))
        try await day90.restore()
        #expect(await day90.current().appDisabledIDs.isEmpty)
        let written = try await f.open().loadConnectorAccess()
        #expect(written.appDisabledIDs.isEmpty && written.appDisabledAbsentSince.isEmpty)
        #expect(await day90.current().isAvailable)
    }

    @Test("An id the catalog holds is never pruned, and a row that comes back starts the count again")
    func aKillTheCatalogHoldsIsNeverPruned() async throws {
        let f = try Fixture(); defer { f.remove() }
        let row = try connector()
        let catalog = MutableCatalog(row)
        let store = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day0))
        try await store.restore()
        try await store.setConnectorAppEnabled(false, id: row.definition.id)
        // Held for more than a year, and once only as a row that cannot tell who it is.
        let late = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(400)))
        try await late.restore()
        await catalog.replace(try connector(digest: "b", holdsPriorIdentity: true))
        try await late.refreshCatalog()
        #expect(await late.current().appDisabledIDs == [row.definition.id])
        #expect(try await f.open().loadConnectorAccess().appDisabledAbsentSince.isEmpty)
        // Gone at day 400, back at day 450, gone again at day 460: the count starts at 460.
        await catalog.replace(try connector(id: "claude-plugin:other@fixture:other", server: "other"))
        try await late.refreshCatalog()
        let back = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(450)))
        await catalog.replace(row)
        try await back.restore()
        #expect(try await f.open().loadConnectorAccess().appDisabledAbsentSince.isEmpty)
        let again = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(460)))
        await catalog.replace(try connector(id: "claude-plugin:other@fixture:other", server: "other"))
        try await again.restore()
        let day540 = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(540)))
        try await day540.restore()
        #expect(await day540.current().appDisabledIDs == [row.definition.id])
        let day550 = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(550)))
        try await day550.restore()
        #expect(await day550.current().appDisabledIDs.isEmpty)
    }

    @Test("A record written before the count existed decodes, and the count starts at the next launch")
    func anOlderRecordStartsTheCountAtLaunch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let raw = """
        {"revision":4,"appEnabled":true,"catalog":[],"grants":[],"grantFlagsSeeded":true,
         "appDisabledIDs":["claude-plugin:gone@fixture:gone"],"messagesChats":[]}
        """
        let decoded = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(raw.utf8))
        #expect(decoded.appDisabledAbsentSince.isEmpty)
        try decoded.validate()
        let db = try f.open()
        _ = try await db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('connector_access_v1',?);",
                                 bindings: [.text(raw)])
        let catalog = MutableCatalog(try connector())
        let store = ConnectorAccessStore(repository: db, catalog: catalog, clock: FixedClock(Self.day0))
        try await store.restore()
        let stamped = try await db.loadConnectorAccess()
        #expect(stamped.appDisabledAbsentSince == ["claude-plugin:gone@fixture:gone": Self.day0])
        // A second launch inside the 90 days changes nothing and writes nothing.
        let next = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(30)))
        try await next.restore()
        #expect(try await db.loadConnectorAccess() == stamped)
        let day90 = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(90)))
        try await day90.restore()
        #expect(await day90.current().appDisabledIDs.isEmpty)
    }

    @Test("A kill from a source this build does not know is never counted or pruned")
    func aKillFromAnUnknownSourceIsKept() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open(), bot = TeammateID(UUID())
        _ = try await db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('connector_access_v1',?);",
                                 bindings: [.text(try recordHoldingAnExtensionRow(bot: bot))])
        let catalog = MutableCatalog(try connector())
        for day in [0, 400] {
            let store = ConnectorAccessStore(repository: try f.open(), catalog: catalog, clock: FixedClock(Self.day(day)))
            try await store.restore()
            #expect(await store.current().appDisabledIDs == [Self.extensionID])
        }
        #expect(try await db.loadConnectorAccess().appDisabledAbsentSince.isEmpty)
    }

    @Test("Turning a gone row back on for the app drops its count, and the next switch still saves")
    func unkillingAGoneRowDropsItsCount() async throws {
        let f = try Fixture(); defer { f.remove() }
        let db = try f.open()
        let gone = try connector(id: "claude-plugin:gone@fixture:gone", server: "gone")
        let catalog = MutableCatalog(gone)
        let store = ConnectorAccessStore(repository: db, catalog: catalog, clock: FixedClock(Self.day0))
        try await store.restore()
        try await store.setConnectorAppEnabled(false, id: gone.definition.id)
        await catalog.replace(try connector())
        try await store.refreshCatalog()
        try await store.setConnectorAppEnabled(true, id: gone.definition.id)
        #expect(await store.current().isAvailable)
        let written = try await db.loadConnectorAccess()
        #expect(written.appDisabledIDs.isEmpty && written.appDisabledAbsentSince.isEmpty)
        try await store.setAppEnabled(true)
        #expect(await store.current().isAvailable)
    }

    private static let day0 = Date(timeIntervalSince1970: 1_790_000_000)
    private static func day(_ n: Int) -> Date { day0.addingTimeInterval(TimeInterval(n) * 86_400) }

    private struct FixedClock: OpenBotsClock {
        let value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { value }
    }

    private actor Roster {
        var listed: Set<TeammateID>
        var failing = false
        init(_ listed: Set<TeammateID>) { self.listed = listed }
        func set(_ ids: Set<TeammateID>) { listed = ids }
        func fail() { failing = true }
        func ids() throws -> Set<TeammateID> {
            if failing { throw ConnectorAccessError.unavailable }
            return listed
        }
    }

    private struct PairCatalog: ConnectorCatalogReading {
        let first: ConfiguredConnector
        let second: ConfiguredConnector
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
            .init(connectors: [first, second])
        }
    }

    private func connector(id: String, server: String,
                           availability: ConnectorAvailability = .ready) throws -> ConfiguredConnector {
        let identity = try ConnectorIdentity(id: id, digest: String(repeating: "a", count: 64))
        return .init(definition: .init(identity: identity, serverName: server, pluginName: "fixture",
                                       transport: .http, availability: availability),
            launch: .init(serverKey: "fixture-\(server)", transport: .http,
                          url: URL(string: "https://example.test/mcp")!))
    }

    /// The app's own Messages row, as the app-owned catalog mints it.
    private func messagesConnector() throws -> ConfiguredConnector {
        let identity = try ConnectorIdentity(id: "openbots:apple-messages:apple-messages",
                                             digest: String(repeating: "b", count: 64))
        return .init(definition: .init(identity: identity, serverName: "apple-messages", pluginName: "OpenBots Next",
                                       transport: .stdio),
            launch: .init(serverKey: "openbots-messages", transport: .stdio,
                          command: AppleMessagesConnectorPreparation.command))
    }

    private func connector(digest: Character = "a", holdsPriorIdentity: Bool = false) throws -> ConfiguredConnector {
        let identity = try ConnectorIdentity(id: "claude-plugin:docs@fixture:docs", digest: String(repeating: String(digest), count: 64))
        return .init(definition: .init(identity: identity, serverName: "docs", pluginName: "docs@fixture", transport: .http),
            launch: .init(serverKey: "fixture", transport: .http, url: URL(string: "https://example.test/mcp")!),
            holdsPriorIdentity: holdsPriorIdentity)
    }
    private actor MutableCatalog: ConnectorCatalogReading {
        var connector: ConfiguredConnector
        var shouldFail = false
        init(_ connector: ConfiguredConnector) { self.connector = connector }
        func replace(_ connector: ConfiguredConnector) { self.connector = connector }
        func fail() { shouldFail = true }
        func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
            if shouldFail { throw ConnectorCatalogError.unavailable }
            return .init(connectors: [connector])
        }
    }
    private struct Fixture {
        let root: URL
        let protection: ProtectionDecisionReceipt
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextConnectorAccess-\(UUID()).noindex")
            protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: .init(fileURL: root.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
        }
    }
}

