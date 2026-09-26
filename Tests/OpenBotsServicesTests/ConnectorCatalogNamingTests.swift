import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private func namedConnector(_ id: String, server: String, title: String? = nil,
                            availability: ConnectorAvailability = .ready,
                            arguments: [String] = ["chrome-devtools-mcp@1.9.0"]) throws -> ConfiguredConnector {
    let identity = try ConnectorIdentity(id: id, digest: String(repeating: "c", count: 64))
    return ConfiguredConnector(
        definition: .init(identity: identity, serverName: server, pluginName: "chrome-devtools-mcp",
                          transport: .stdio, title: title, availability: availability),
        launch: .init(serverKey: "openbots_k", transport: .stdio, command: "npx",
                      arguments: arguments))
}

private struct RowsCatalog: ConnectorCatalogReading {
    let connectors: [ConfiguredConnector]
    var excludedCount = 0
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        .init(connectors: connectors, excludedCount: excludedCount)
    }
}

@Suite("The row the user looks for when they want a bot to browse")
struct ConnectorCatalogNamingTests {
    @Test("The browser row is called Browser, not chrome-devtools")
    func theBrowserRowIsCalledBrowser() async throws {
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools", server: "chrome-devtools"),
        ]))
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        #expect(definition.title == "Browser")
        // The server's key is still the row's identity underneath; only what the
        // user reads changed.
        #expect(definition.serverName == "chrome-devtools")
    }

    @Test("A row unsure of its identity stays unsure when it is renamed")
    func renamingKeepsTheHold() async throws {
        let row = try namedConnector("claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools",
                                     server: "chrome-devtools")
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            ConfiguredConnector(definition: row.definition, launch: row.launch, holdsPriorIdentity: true)
        ]))
        let loaded = try #require(try await catalog.loadConnectorCatalog().connectors.first)
        #expect(loaded.definition.title == "Browser")
        #expect(loaded.holdsPriorIdentity)
    }

    @Test("The browser row names the two switches that are not it")
    func theBrowserRowNamesTheWebSwitches() async throws {
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools", server: "chrome-devtools"),
        ]))
        let summary = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition.summary
        // "Can this bot browse?" was answered in three places and none of them
        // mentioned the others. This is the row that works, so it is the one
        // that points at the rest.
        #expect(summary.contains("Use web search"))
        #expect(summary.contains("Use web fetch"))
    }

    @Test("Where the row came from is kept, not traded away for the better name")
    func theProvenanceLineSurvivesTheRename() async throws {
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools",
                               server: "chrome-devtools"),
        ]))
        let summary = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition.summary
        // Two rows wearing one title and no provenance are the same row as far
        // as the pane can show.
        #expect(summary.contains("Configured in Claude Code · chrome-devtools-mcp"))
    }

    @Test("A row merely CALLED chrome-devtools is not the browser and is not renamed")
    func anImposterKeepsItsOwnName() async throws {
        // The name is what is being corrected, so the name cannot be what
        // decides. This row would launch something else entirely.
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("claude-plugin:someone-else@third-party:chrome-devtools",
                               server: "chrome-devtools", arguments: ["not-the-browser@1.0.0"]),
        ]))
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        #expect(definition.title == "chrome-devtools")
        #expect(!definition.summary.contains("thrown away when the turn ends"))
    }

    @Test("A row that wrote prose of its own keeps it, even with the default title")
    func aSourceThatBroughtItsOwnWordsIsNotStackedOnTop() async throws {
        let identity = try ConnectorIdentity(id: "claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools",
                                             digest: String(repeating: "c", count: 64))
        let row = ConfiguredConnector(
            definition: .init(identity: identity, serverName: "chrome-devtools",
                              pluginName: "chrome-devtools-mcp", transport: .stdio,
                              summary: "Words this source wrote on purpose."),
            launch: .init(serverKey: "openbots_k", transport: .stdio, command: "npx",
                          arguments: ["chrome-devtools-mcp@1.9.0"]))
        let definition = try #require(try await ConnectorCatalogNaming(RowsCatalog(connectors: [row]))
            .loadConnectorCatalog().connectors.first).definition
        #expect(definition.summary == "Words this source wrote on purpose.")
        #expect(definition.title == "chrome-devtools")
    }

    @Test("A row this app knows nothing about is left exactly as it read before")
    func anUnknownRowIsUntouched() async throws {
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("claude-plugin:netlify-skills@claude-plugins-official:netlify", server: "netlify",
                               arguments: ["netlify-mcp@2.0.0"]),
        ]))
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        #expect(definition.title == "netlify")
        #expect(definition.summary.contains("Configured in Claude Code"))
    }

    @Test("A row that already says what it is is never talked over")
    func anAppOwnedRowKeepsItsOwnWords() async throws {
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("openbots:browser:chrome-devtools", server: "chrome-devtools",
                               title: "Browser (app-owned)"),
        ]))
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        #expect(definition.title == "Browser (app-owned)")
    }

    @Test("The excluded count passes through untouched")
    func theExcludedCountSurvives() async throws {
        let catalog = ConnectorCatalogNaming(RowsCatalog(connectors: [
            try namedConnector("claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools", server: "chrome-devtools"),
        ], excludedCount: 4))
        #expect(try await catalog.loadConnectorCatalog().excludedCount == 4)
    }
}

@Suite("The order the connector list is read in")
struct ConnectorListOrderTests {
    @Test("A row this build cannot drive sinks below the rows that work")
    func theDeadRowSinks() throws {
        // Exactly the list a user met: browser-use sorts first by name and cannot
        // be driven at all, and the browser that works sat underneath it.
        let rows = [
            try namedConnector("claude-plugin:browser-use@claude-plugins-official:browser-use", server: "browser-use",
                               availability: .unavailable("This version of OpenBots Next cannot drive this connector yet."),
                               arguments: ["browser-use@1.0.0"]),
            try namedConnector("claude-plugin:chrome-devtools-mcp@claude-plugins-official:chrome-devtools", server: "chrome-devtools"),
        ].map(\.definition)
        let ordered = ConnectorDefinition.inListOrder(rows)
        #expect(ordered.map(\.serverName) == ["chrome-devtools", "browser-use"])
    }

    @Test("A row the user can fix themselves sits between what works and what cannot")
    func needsSetupSitsInTheMiddle() throws {
        let rows = [
            try namedConnector("claude-plugin:a@o:a", server: "a",
                               availability: .unavailable("No.")),
            try namedConnector("claude-plugin:b@o:b", server: "b",
                               availability: .needsSetup("Cache it first.")),
            try namedConnector("claude-plugin:c@o:c", server: "c"),
        ].map(\.definition)
        #expect(ConnectorDefinition.inListOrder(rows).map(\.serverName) == ["c", "b", "a"])
    }

    @Test("Two rows in the same state keep the identity order the catalog mints")
    func tiesKeepIdentityOrder() throws {
        let rows = [
            try namedConnector("claude-plugin:z@o:z", server: "z"),
            try namedConnector("claude-plugin:a@o:a", server: "a"),
        ].map(\.definition)
        let ordered = ConnectorDefinition.inListOrder(rows)
        #expect(ordered.map(\.id) == ["claude-plugin:a@o:a", "claude-plugin:z@o:z"])
        // Read twice, the same list: the pane must not reshuffle under the user.
        #expect(ConnectorDefinition.inListOrder(ordered).map(\.id) == ordered.map(\.id))
    }
}
