import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

/// The web switches survive a relaunch. Reinstalls once turned them off each
/// time, because they lived only in memory. These prove the app-owned database keeps them
/// through a real close and reopen, each capability on its own, on and off,
/// app-wide and per bot, and touches nothing else in the table.
@Suite("Web switches kept in the app-owned database")
struct SQLiteAgenticWebSwitchTests {
    @Test("Every switch that was on is on again after a real reopen, and one turned off stays off")
    func roundTripThroughReopen() async throws {
        let f = try WebSwitchFixture()
        defer { f.remove() }
        let a = TeammateID(UUID()), b = TeammateID(UUID())
        weak var closed: SQLiteStore?
        do {
            let store = try f.open(); closed = store
            #expect(try await store.loadWebSwitches() == AgenticWebSwitchSnapshot())
            try await store.setAppWebSwitch(.webSearch, enabled: true)
            try await store.setAppWebSwitch(.webFetch, enabled: true)
            try await store.setBotWebSwitch(.webSearch, enabled: true, teammateID: a)
            try await store.setBotWebSwitch(.webFetch, enabled: true, teammateID: a)
            try await store.setBotWebSwitch(.webFetch, enabled: true, teammateID: b)
            // Two switches turned off again before the app closes: the revoke path.
            try await store.setAppWebSwitch(.webFetch, enabled: false)
            try await store.setBotWebSwitch(.webFetch, enabled: false, teammateID: a)
        }
        #expect(closed == nil, "the first store must really close before the second opens")
        do {
            let reopened = try f.open(); closed = reopened
            #expect(try await reopened.loadWebSwitches()
                == AgenticWebSwitchSnapshot(app: [.webSearch], bots: [a: [.webSearch], b: [.webFetch]]))
            // A capability turned off leaves the other capability alone, on both surfaces.
            try await reopened.setAppWebSwitch(.webSearch, enabled: false)
            try await reopened.setBotWebSwitch(.webFetch, enabled: false, teammateID: b)
        }
        #expect(closed == nil)
        let third = try f.open()
        #expect(try await third.loadWebSwitches() == AgenticWebSwitchSnapshot(bots: [a: [.webSearch]]))
        try await third.setBotWebSwitch(.webSearch, enabled: false, teammateID: a)
        #expect(try await third.loadWebSwitches() == AgenticWebSwitchSnapshot())
        #expect(try await third.integrityCheck())
    }

    @Test("Turning a switch on twice keeps one row, turning an off switch off is not an error, and only 'on' rows count")
    func writesAreIdempotent() async throws {
        let f = try WebSwitchFixture()
        defer { f.remove() }
        let store = try f.open()
        let bot = TeammateID(UUID())
        try await store.setAppWebSwitch(.webSearch, enabled: true)
        try await store.setAppWebSwitch(.webSearch, enabled: true)
        try await store.setBotWebSwitch(.webFetch, enabled: true, teammateID: bot)
        try await store.setBotWebSwitch(.webFetch, enabled: true, teammateID: bot)
        try await store.setBotWebSwitch(.webSearch, enabled: false, teammateID: bot)
        try await store.setAppWebSwitch(.webFetch, enabled: false)
        #expect(try await f.switchRows(store).count == 2)
        #expect(try await store.loadWebSwitches() == AgenticWebSwitchSnapshot(app: [.webSearch], bots: [bot: [.webFetch]]))
        // A row that is not 'on' is not a switch that is on, whatever wrote it.
        _ = try await store.execute(sql: "UPDATE app_metadata SET value='off' WHERE key=?;",
                                    bindings: [.text("agentic_web_switch_v1.app.webSearch")])
        #expect(try await store.loadWebSwitches() == AgenticWebSwitchSnapshot(bots: [bot: [.webFetch]]))
    }

    @Test("Other metadata rows, a stored session marker and an archived bot's grant are left alone")
    func otherRowsAndArchivedGrantsAreLeftAlone() async throws {
        let f = try WebSwitchFixture()
        defer { f.remove() }
        let teammate = try f.teammate()
        weak var closed: SQLiteStore?
        var before: [String] = []
        do {
            let store = try f.open(); closed = store
            try await store.insert(teammate)
            _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('unrelated_web_switch_test','kept');")
            before = try await f.otherMetadataRows(store)
            try await store.setBotWebSwitch(.webSearch, enabled: true, teammateID: teammate.id)
            try await store.setAppWebSwitch(.webSearch, enabled: true)
            // The person archives the bot with its grant on. Nothing revokes it.
            _ = try await store.archiveTeammate(id: teammate.id, expectedProfileRevision: 1, now: f.date.addingTimeInterval(60))
            try await store.setAppWebSwitch(.webSearch, enabled: false)
            #expect(try await f.otherMetadataRows(store) == before)
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.loadWebSwitches() == AgenticWebSwitchSnapshot(bots: [teammate.id: [.webSearch]]))
        #expect(try await reopened.archivedTeammates().map(\.id) == [teammate.id])
        #expect(try await f.otherMetadataRows(reopened) == before)
    }

    @Test("A row this build cannot read is neither on nor an error")
    func unknownRowsAreSkipped() async throws {
        let f = try WebSwitchFixture()
        defer { f.remove() }
        let store = try f.open()
        let bot = TeammateID(UUID())
        try await store.setBotWebSwitch(.webSearch, enabled: true, teammateID: bot)
        for key in ["agentic_web_switch_v1.app.webTeleport", "agentic_web_switch_v1.bot.not-a-uuid.webSearch",
                    "agentic_web_switch_v1.bot.\(bot.persistedValue).webTeleport", "agentic_web_switch_v1.app",
                    "agentic_web_switch_v1.room.\(bot.persistedValue).webSearch", "agentic_web_switch_v2.app.webSearch"] {
            _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,'on');", bindings: [.text(key)])
        }
        #expect(try await store.loadWebSwitches() == AgenticWebSwitchSnapshot(bots: [bot: [.webSearch]]))
    }

    /// Bots that hire bots: the hire pair lives in the same rows,
    /// under its own name, and survives a real reopen like the others.
    @Test("The hire switches are kept in their own rows through a reopen, and off leaves no row")
    func hireSwitchesSurviveAReopen() async throws {
        let f = try WebSwitchFixture()
        defer { f.remove() }
        let bot = TeammateID(UUID())
        weak var closed: SQLiteStore?
        do {
            let store = try f.open(); closed = store
            try await store.setAppWebSwitch(.hire, enabled: true)
            try await store.setBotWebSwitch(.hire, enabled: true, teammateID: bot)
            #expect(try await f.switchRows(store)
                == ["agentic_web_switch_v1.app.hire", "agentic_web_switch_v1.bot.\(bot.persistedValue).hire"])
        }
        #expect(closed == nil)
        let reopened = try f.open()
        #expect(try await reopened.loadWebSwitches() == AgenticWebSwitchSnapshot(app: [.hire], bots: [bot: [.hire]]))
        try await reopened.setBotWebSwitch(.hire, enabled: false, teammateID: bot)
        #expect(try await reopened.loadWebSwitches() == AgenticWebSwitchSnapshot(app: [.hire]))
    }
}

private struct WebSwitchFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 5_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextWebSwitch-\(UUID()).noindex", isDirectory: true)
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

    func teammate() throws -> Teammate {
        try Teammate(id: TeammateID(UUID()),
            profile: TeammateProfile(displayName: "Yogurt", role: "Research", detailedInstructions: nil),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
    }

    func switchRows(_ store: SQLiteStore) async throws -> [String] {
        try await store.query(sql: "SELECT key FROM app_metadata WHERE key GLOB 'agentic_web_switch_v1.*' ORDER BY key;")
            .map { try $0.text("key") }
    }

    func otherMetadataRows(_ store: SQLiteStore) async throws -> [String] {
        try await store.query(sql: "SELECT key||'='||value AS row FROM app_metadata WHERE key NOT GLOB 'agentic_web_switch_v1.*' ORDER BY key;")
            .map { try $0.text("row") }
    }
}
