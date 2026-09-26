import Foundation
import OpenBotsDomain

/// Gives a row this app can actually drive the name a person would look for.
///
/// A connector Claude Code configured has no words of its own, so the pane has
/// always shown the server's key — `chrome-devtools` — with "Configured in
/// Claude Code" underneath. That is the browser, and a person who opened the
/// app looking for browsing did not find it: what they read first
/// was `browser-use`, which this build cannot drive at all, and the row beneath
/// it named a developer tool rather than a browser.
///
/// **A row is matched by what it would LAUNCH, never by what it is called.**
/// The first version of this keyed on the server's name, and any plugin from
/// anywhere naming a server `chrome-devtools` would have inherited the title
/// "Browser" and a summary that makes promises about the browser this app
/// drives — its own profile, thrown away at the end of the turn. The matcher
/// below is the same resolution the launch itself does, so the two cannot
/// drift: if it is not the package the browser preparation will run, it is not
/// called Browser.
///
/// Only a row that has no title of its own is renamed. An app-owned row already
/// says what it is, and a row nothing here knows keeps reading exactly as it
/// always has — the server's key, and where it came from underneath.
public struct ConnectorCatalogNaming: ConnectorCatalogReading {
    /// What a known row is called, and what it says about itself, with the test
    /// that decides whether a row is that one.
    public struct Naming: Sendable {
        public let title: String
        public let summary: String
        /// True only for a launch this naming describes. Read the launch, never
        /// the label: the label is what is being corrected.
        public let matches: @Sendable (ConnectorLaunchConfiguration) -> Bool
        public init(title: String, summary: String,
                    matches: @escaping @Sendable (ConnectorLaunchConfiguration) -> Bool) {
            self.title = title; self.summary = summary; self.matches = matches
        }
    }

    public static let known: [Naming] = [
        Naming(
            title: "Browser",
            summary: "Opens web pages in a Chrome of its own and reads them — no window on your "
                + "screen, nothing of yours inside it, and it is thrown away when the turn ends.\n"
                + "Use web search and Use web fetch are separate switches in this pane: they let a "
                + "bot search the web and read one page without a browser.",
            // Exactly what `BrowserConnectorPreparation` will accept, and
            // nothing else. It refuses any package but its own, so a row that
            // resolves here is the row that browser preparation would run.
            matches: { (try? BrowserConnectorPreparation.packageSpecification(in: $0)) != nil }),
    ]

    private let source: any ConnectorCatalogReading
    private let naming: [Naming]

    public init(_ source: any ConnectorCatalogReading, naming: [Naming] = ConnectorCatalogNaming.known) {
        self.source = source; self.naming = naming
    }

    public func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        let snapshot = try await source.loadConnectorCatalog()
        let connectors = snapshot.connectors.map { connector -> ConfiguredConnector in
            let definition = connector.definition
            // A title equal to the server's name is the default the domain
            // writes when a row brought none. Anything else is a row that has
            // already said what it is, and this must not talk over it.
            // Both halves have to still be the defaults the domain writes. The
            // title alone happens to imply the summary today only because the
            // one source that omits a title omits both; a source that brought
            // prose of its own would otherwise get this one stacked on top.
            guard definition.title == definition.serverName,
                  definition.summary == ConnectorDefinition.defaultSummary(pluginName: definition.pluginName),
                  let naming = naming.first(where: { $0.matches(connector.launch) }) else { return connector }
            return ConfiguredConnector(
                definition: .init(identity: definition.identity, serverName: definition.serverName,
                                  pluginName: definition.pluginName, transport: definition.transport,
                                  title: naming.title,
                                  // Where the row came from is kept, not traded
                                  // away for the better name: two rows wearing
                                  // one title and no provenance are the same
                                  // row as far as the pane can show.
                                  summary: naming.summary + "\n" + definition.summary,
                                  availability: definition.availability),
                launch: connector.launch, holdsPriorIdentity: connector.holdsPriorIdentity)
        }
        return ConnectorCatalogSnapshot(connectors: connectors, excludedCount: snapshot.excludedCount)
    }
}
