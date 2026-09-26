import Foundation
import OpenBotsDomain

/// Something that can say, without running anything, whether one configured row
/// could actually be launched today — and if not, in words the user can act on.
///
/// This exists because the knowledge was being thrown away. The browser's
/// preparation has always been able to tell a pinned version that is not on the
/// disk (`packageNotCached`, documented in that type as *the* needs-setup
/// state) from a Chrome that is not installed, and the service dropped the
/// distinction with a `try?` and simply did not grant the connector. The row in
/// Settings looked ordinary, the switch turned on, and nothing ever happened.
public protocol ConnectorAvailabilityProbing: Sendable {
    /// The row's state, or nil when this probe has no opinion about it.
    func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability?
}

/// A catalog that answers with the same rows, each carrying what the probes know
/// about it. A row nobody has an opinion about keeps whatever it already said.
public struct ConnectorCatalogAvailability: ConnectorCatalogReading {
    private let source: any ConnectorCatalogReading
    private let probes: [any ConnectorAvailabilityProbing]

    public init(_ source: any ConnectorCatalogReading, probes: [any ConnectorAvailabilityProbing]) {
        self.source = source; self.probes = probes
    }

    /// What a row says when no probe owns it: this build has no way to launch
    /// it, so its switch is dead rather than inviting. Every connector Claude
    /// Code has configured appears in the catalog, and this app can drive two of
    /// them today — a live switch on the others would turn on and do nothing,
    /// which is a silently dead grant. It is
    /// the `unowned` case, so anything that treats such a row differently asks
    /// `isUnowned` and never compares these words.
    public static let unownedRow = ConnectorAvailability.unowned(
        "This version of OpenBots Next cannot drive this connector yet.")

    public func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        let snapshot = try await source.loadConnectorCatalog()
        let connectors = snapshot.connectors.map { connector -> ConfiguredConnector in
            let answered = probes.lazy.compactMap { $0.availability(for: connector.launch) }.first
            guard let availability = answered ?? (probes.isEmpty ? nil : Self.unownedRow)
            else { return connector }
            // A row the catalog already refused to promise is not talked up by
            // a probe: the worse answer wins, because the catalog knows things
            // a probe cannot (the app it drives is not even installed).
            if !connector.definition.availability.canBeEnabled { return connector }
            let definition = connector.definition
            return ConfiguredConnector(
                definition: .init(identity: definition.identity, serverName: definition.serverName,
                                  pluginName: definition.pluginName, transport: definition.transport,
                                  title: definition.title, summary: definition.summary,
                                  availability: availability),
                launch: connector.launch, holdsPriorIdentity: connector.holdsPriorIdentity)
        }
        return ConnectorCatalogSnapshot(connectors: connectors, excludedCount: snapshot.excludedCount)
    }
}

extension BrowserConnectorPreparation: ConnectorAvailabilityProbing {
    /// Resolution, with its failures turned into the row's own words. Nothing
    /// is launched and nothing is fetched: this is the same read the turn does,
    /// done early so the pane can say what the turn would find.
    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        do {
            _ = try resolve(launch)
            // A page's text is a stranger's words, so the browser cannot launch
            // outside the fence either. Without this the row read ready, the
            // switch worked, and the launch was dropped in silence.
            try FenceProxyResource().verify()
            return .ready
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch Failure.notABrowserConnector, Failure.unsupportedTransport {
            // Not this probe's row at all.
            return nil
        } catch Failure.packageNotCached(let version) {
            return .needsSetup("Version \(version) of \(Self.browserPackageName) is not on this Mac yet. "
                + "Run it once from the command line to cache it.")
        } catch Failure.browserMissing {
            return .unavailable("Google Chrome is not installed on this Mac.")
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it.")
        } catch {
            return .needsSetup("The browser server on this Mac cannot be used as it is installed.")
        }
    }
}
