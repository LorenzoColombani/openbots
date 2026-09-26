import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private func availabilityConnector(_ id: String, availability: ConnectorAvailability = .ready,
                                   command: String = "npx",
                                   arguments: [String] = ["chrome-devtools-mcp@1.8.0"]) throws -> ConfiguredConnector {
    let identity = try ConnectorIdentity(id: id, digest: String(repeating: "b", count: 64))
    return ConfiguredConnector(
        definition: .init(identity: identity, serverName: "s", pluginName: "p", transport: .stdio,
                          availability: availability),
        launch: .init(serverKey: "openbots_k", transport: .stdio, command: command, arguments: arguments))
}

private struct OneRowCatalog: ConnectorCatalogReading {
    let connector: ConfiguredConnector
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        .init(connectors: [connector], excludedCount: 3)
    }
}

private struct FixedProbe: ConnectorAvailabilityProbing {
    let answer: ConnectorAvailability?
    func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? { answer }
}

@Suite("What a row can say about itself before anything is launched")
struct ConnectorCatalogAvailabilityTests {
    @Test("A probe's answer reaches the row, and the excluded count is untouched")
    func theProbeAnswerReachesTheRow() async throws {
        let catalog = ConnectorCatalogAvailability(
            OneRowCatalog(connector: try availabilityConnector("claude-plugin:a@o:s")),
            probes: [FixedProbe(answer: .needsSetup("Cache it first."))])
        let snapshot = try await catalog.loadConnectorCatalog()
        let definition = try #require(snapshot.connectors.first).definition
        #expect(definition.availability == .needsSetup("Cache it first."))
        #expect(snapshot.excludedCount == 3)
    }

    @Test("A row unsure of its identity stays unsure when a probe rewrites its badge")
    func aProbeKeepsTheHold() async throws {
        let row = try availabilityConnector("claude-plugin:a@o:s")
        let unsure = ConfiguredConnector(definition: row.definition, launch: row.launch, holdsPriorIdentity: true)
        let catalog = ConnectorCatalogAvailability(OneRowCatalog(connector: unsure),
                                                   probes: [FixedProbe(answer: .needsSetup("Not now."))])
        let loaded = try #require(try await catalog.loadConnectorCatalog().connectors.first)
        #expect(loaded.definition.availability == .needsSetup("Not now."))
        #expect(loaded.holdsPriorIdentity)
    }

    @Test("A row nobody owns cannot be turned on, because nothing here could launch it")
    func anUnownedRowIsUnavailable() async throws {
        let catalog = ConnectorCatalogAvailability(
            OneRowCatalog(connector: try availabilityConnector("claude-plugin:a@o:s")),
            probes: [FixedProbe(answer: nil)])
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        // Every connector Claude Code has configured shows up in this catalog,
        // and this app can drive two of them. A live switch on the rest turns on
        // and does nothing, which is the defect this rule closes.
        #expect(definition.availability == ConnectorCatalogAvailability.unownedRow)
        #expect(definition.availability.isUnowned)
        #expect(!definition.availability.canBeEnabled)
        #expect(definition.availability.badge == "unavailable")
        #expect(definition.availability.listRank == ConnectorAvailability.unavailable("x").listRank)
        #expect(try #require(definition.availability.reason).contains("cannot drive this connector yet"))
    }

    /// The marker is the kind of answer, not its words: a probe that owns a row
    /// and answers in the same sentence has still answered, and an unowned row
    /// reworded stays unowned.
    @Test("Only a row no probe answers for is marked unowned, whatever any row's words say")
    func theUnownedMarkerIsTypedNotWorded() async throws {
        let words = try #require(ConnectorCatalogAvailability.unownedRow.reason)
        let owned = ConnectorCatalogAvailability(
            OneRowCatalog(connector: try availabilityConnector("claude-plugin:a@o:s")),
            probes: [FixedProbe(answer: .unavailable(words))])
        let answered = try #require(try await owned.loadConnectorCatalog().connectors.first).definition.availability
        #expect(!answered.isUnowned)
        #expect(answered.reason == words)
        #expect(ConnectorAvailability.unowned("Reworded.").isUnowned)
        for other in [ConnectorAvailability.ready, .needsSetup(words), .unavailable(words)] {
            #expect(!other.isUnowned)
        }
    }

    @Test("With no probes at all, the rows are left exactly as the catalog wrote them")
    func noProbesChangesNothing() async throws {
        let catalog = ConnectorCatalogAvailability(
            OneRowCatalog(connector: try availabilityConnector("claude-plugin:a@o:s")), probes: [])
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        #expect(definition.availability == .ready)
    }

    @Test("A probe cannot talk up a row the catalog already refused to promise")
    func theWorseAnswerWins() async throws {
        let catalog = ConnectorCatalogAvailability(
            OneRowCatalog(connector: try availabilityConnector("openbots:apple-mail:apple-mail",
                                                               availability: .unavailable("Mail is not installed."))),
            probes: [FixedProbe(answer: .ready)])
        let definition = try #require(try await catalog.loadConnectorCatalog().connectors.first).definition
        #expect(definition.availability == .unavailable("Mail is not installed."))
    }
}

@Suite("The browser's own resolution, read early so the pane can say what the turn would find")
struct BrowserAvailabilityProbeTests {
    /// `/bin/sh` is a real, root-owned, executable file, so it passes the same
    /// check node and Chrome pass. Nothing here is a synthetic permission mask.
    private let realTool = URL(fileURLWithPath: "/bin/sh")

    private func emptyCacheRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-empty-npx-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A pinned version that is not on the disk is needs-setup, with its version named")
    func anUncachedVersionIsNeedsSetup() throws {
        let root = try emptyCacheRoot(); defer { try? FileManager().removeItem(at: root) }
        let preparation = BrowserConnectorPreparation(npxCacheRootURL: root,
            interpreterCandidateURLs: [realTool], browserCandidateURLs: [realTool])
        let launch = try availabilityConnector("claude-plugin:a@o:s").launch
        let availability = try #require(preparation.availability(for: launch))
        #expect(availability.badge == "needs setup")
        #expect(try #require(availability.reason).contains("1.8.0"))
    }

    @Test("No Chrome on the Mac is unavailable, not merely unset")
    func noBrowserIsUnavailable() throws {
        let root = try emptyCacheRoot(); defer { try? FileManager().removeItem(at: root) }
        let preparation = BrowserConnectorPreparation(npxCacheRootURL: root,
            interpreterCandidateURLs: [realTool], browserCandidateURLs: [])
        let launch = try availabilityConnector("claude-plugin:a@o:s").launch
        let availability = try #require(preparation.availability(for: launch))
        #expect(availability.badge == "unavailable")
        #expect(!availability.canBeEnabled)
    }

    @Test("A row that is not the browser server gets no opinion at all")
    func anotherServerGetsNoOpinion() throws {
        let root = try emptyCacheRoot(); defer { try? FileManager().removeItem(at: root) }
        let preparation = BrowserConnectorPreparation(npxCacheRootURL: root,
            interpreterCandidateURLs: [realTool], browserCandidateURLs: [realTool])
        let mail = try availabilityConnector("openbots:apple-mail:apple-mail",
            command: "apple-mail-fast-mcp", arguments: ["--read-only"]).launch
        #expect(preparation.availability(for: mail) == nil)
    }
}
