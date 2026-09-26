import Foundation
import OpenBotsDomain

/// One catalog made of several, so the store, the settings pane and the grants
/// go on knowing nothing about where a row came from.
///
/// Order is by identity, as the plugin catalog already sorts, so the pane never
/// reshuffles between reads. A source that fails is not allowed to hide the
/// others: its failure is counted as excluded rows and reported, because a
/// catalog read that silently returns fewer rows is how a granted connector
/// disappears without anyone being told. If *every* source fails, the failure
/// is thrown — the store's own rule is that losing the catalog loses the
/// authority, and that must not be softened into an empty list.
public struct ConnectorCatalogComposite: ConnectorCatalogReading {
    private let sources: [any ConnectorCatalogReading]

    public init(_ sources: [any ConnectorCatalogReading]) { self.sources = sources }

    public func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        var connectors: [String: ConfiguredConnector] = [:]
        var excluded = 0
        var failures: [any Error] = []
        for source in sources {
            try Task.checkCancellation()
            do {
                let snapshot = try await source.loadConnectorCatalog()
                excluded += snapshot.excludedCount
                for connector in snapshot.connectors {
                    // A duplicate identity cannot be resolved by preferring
                    // one source: the two would disagree about what a granted
                    // row launches. Both are dropped and counted.
                    if connectors.updateValue(connector, forKey: connector.definition.id) != nil {
                        connectors[connector.definition.id] = nil
                        excluded += 2
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error)
            }
        }
        if failures.count == sources.count, let first = failures.first { throw first }
        excluded += failures.count
        return ConnectorCatalogSnapshot(
            connectors: connectors.values.sorted { $0.definition.id < $1.definition.id },
            excludedCount: excluded)
    }
}
