import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

/// The store's own suite already proves the grants; this proves the step from a
/// grant to a launch — including the two ways it must refuse.
private actor MemoryConnectorRepository: ConnectorAccessRepository {
    private var state = ConnectorAccessState()
    func loadConnectorAccess() async throws -> ConnectorAccessState { state }
    func saveConnectorAccess(_ next: ConnectorAccessState, expectedRevision: Int64) async throws {
        guard state.revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
        state = next
    }
}

private struct OneBrowserCatalog: ConnectorCatalogReading {
    let identity: ConnectorIdentity
    let serverKey: String
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        ConnectorCatalogSnapshot(connectors: [ConfiguredConnector(
            definition: .init(identity: identity, serverName: "chrome-devtools",
                              pluginName: "chrome-devtools-mcp@official", transport: .stdio),
            launch: .init(serverKey: serverKey, transport: .stdio, command: "npx",
                          arguments: ["chrome-devtools-mcp@1.8.0"]))])
    }
}

private struct ServiceFixture {
    let root: URL
    let store: ConnectorAccessStore
    let service: ConnectorLaunchService
    let teammateID = TeammateID(UUID())
    let identity: ConnectorIdentity
    let serverKey = "openbots_" + String(repeating: "9f3a2b01", count: 8)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/openbots-browser-service-\(UUID().uuidString).noindex",
                   isDirectory: true)
        identity = try ConnectorIdentity(id: "claude-plugin:chrome-devtools-mcp@official:chrome-devtools",
                                         digest: String(repeating: "b", count: 64))
        // A cache holding exactly the pinned version, plus a node and a Chrome.
        let packageRoot = root.appendingPathComponent(
            "_npx/4c14ca9d614c46a6/node_modules/chrome-devtools-mcp", isDirectory: true)
        try Self.write(packageRoot.appendingPathComponent("package.json"),
            #"{"name":"chrome-devtools-mcp","version":"1.8.0","bin":{"chrome-devtools-mcp":"./build/bin.js"}}"#)
        try Self.write(packageRoot.appendingPathComponent("build/bin.js"), "#!/usr/bin/env node\n")
        let node = try Self.write(root.appendingPathComponent("bin/node"), "#!/bin/sh\n", permissions: 0o755)
        let chrome = try Self.write(root.appendingPathComponent("bin/Chrome"), "#!/bin/sh\n", permissions: 0o755)

        store = ConnectorAccessStore(repository: MemoryConnectorRepository(),
                                     catalog: OneBrowserCatalog(identity: identity, serverKey: serverKey))
        service = ConnectorLaunchService(
            store: store,
            preparation: BrowserConnectorPreparation(
                npxCacheRootURL: root.appendingPathComponent("_npx", isDirectory: true),
                interpreterCandidateURLs: [node], browserCandidateURLs: [chrome]),
            profileRootURL: root.appendingPathComponent("Profiles.noindex", isDirectory: true),
            temporaryDirectoryURL: root)
    }

    @discardableResult
    static func write(_ url: URL, _ contents: String, permissions: Int16 = 0o644) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        return url
    }

    func grantBoth() async throws {
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: identity, teammateID: teammateID)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("From a connector grant to a browser this turn can launch")
struct ConnectorLaunchServiceTests {
    @Test("Both switches on gives a launch, with a profile this turn alone owns")
    func bothSwitchesGiveALaunch() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        try await f.grantBoth()
        let runID = UUID()
        let access = try #require(await f.service.connectorAccess(teammateID: f.teammateID, runID: runID))
        #expect(access.servers.map(\.name) == [f.serverKey])
        let profile = try #require(access.ownedProfileURLs.first)
        #expect(profile.path.contains(runID.uuidString.lowercased()))
        #expect(FileManager.default.fileExists(atPath: profile.path))
        // A second turn never shares the first turn's profile: that path is how
        // the app tells its own browser from the user's, so it cannot be reused.
        let second = try #require(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()))
        #expect(second.ownedProfileURLs.first != profile)
        #expect(await f.service.grantedConnectorNames(teammateID: f.teammateID) == [f.serverKey])
    }

    @Test("One switch on either side gives nothing at all")
    func oneSwitchGivesNothing() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        try await f.store.restore()
        // The app master alone.
        try await f.store.setAppEnabled(true)
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        #expect(await f.service.grantedConnectorNames(teammateID: f.teammateID).isEmpty)
        // The bot's own selection alone.
        try await f.store.setAppEnabled(false)
        try await f.store.setBotEnabled(true, identity: f.identity, teammateID: f.teammateID)
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        // And another bot never borrows this one's.
        try await f.store.setAppEnabled(true)
        #expect(await f.service.connectorAccess(teammateID: TeammateID(UUID()), runID: UUID()) == nil)
    }

    @Test("A grant already taken away produces no launch")
    func aWithdrawnLeaseNeverLaunches() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        try await f.grantBoth()
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) != nil)
        try await f.store.setAppEnabled(false)
        // This refusal happens at the very first guard — `lease()` is already
        // nil — so it does not exercise the recheck after the loop. The
        // invariant below is what covers that case, by making it unreachable.
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
    }

    @Test("A run that hands back no launch has written nothing to the disk")
    func nothingIsWrittenWithoutALaunch() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        let profiles = f.root.appendingPathComponent("Profiles.noindex", isDirectory: true)
        func leftBehind() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []
        }
        // No grant at all.
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        #expect(leftBehind().isEmpty)
        // Granted, but the grant is gone before the call.
        try await f.grantBoth()
        try await f.store.setAppEnabled(false)
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        #expect(leftBehind().isEmpty)
        // Granted, but nothing on the disk can be prepared.
        try await f.store.setAppEnabled(true)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("_npx", isDirectory: true))
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        #expect(leftBehind().isEmpty, "left behind: \(leftBehind())")
        // The directory is made only for a launch that is actually handed back,
        // so a grant withdrawn part-way through cannot orphan one: nothing is
        // written until after the recheck has passed.
    }

    @Test("A profile a crashed turn left behind is cleared before anything is granted")
    func abandonedProfilesAreCleared() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        try await f.grantBoth()
        let access = try #require(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()))
        let profile = try #require(access.ownedProfileURLs.first)
        #expect(FileManager.default.fileExists(atPath: profile.path))
        // Nothing cleaned up: exactly what a force quit leaves.
        await f.service.removeAbandonedProfiles()
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test("A connector this version cannot prepare leaves no folder behind")
    func unpreparableConnectorsMakeNoProfile() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        try await f.grantBoth()
        // Break the resolution the way a pruned cache would.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("_npx", isDirectory: true))
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        // Nothing was launched, so nothing may have been left on the disk to
        // clean up later.
        let profiles = f.root.appendingPathComponent("Profiles.noindex", isDirectory: true)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []
        #expect(left.isEmpty, "left behind: \(left)")
    }

    @Test("A connector whose package is not on the disk is simply not granted")
    func anUnpreparedConnectorIsNotGranted() async throws {
        let f = try ServiceFixture(); defer { f.remove() }
        try await f.grantBoth()
        // The pinned version disappears, as a pruned npx cache would do.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("_npx", isDirectory: true))
        #expect(await f.service.connectorAccess(teammateID: f.teammateID, runID: UUID()) == nil)
        // The grant itself is untouched: this is "needs setup", not a revocation.
        #expect(await f.service.grantedConnectorNames(teammateID: f.teammateID) == [f.serverKey])
    }
}

/// A bot granted both the browser and the mail reader. The point of the suite
/// below is that the two are prepared by their own owners, and that only the
/// one that needs a directory gets one.
private struct TwoConnectorCatalog: ConnectorCatalogReading {
    let browser: ConfiguredConnector
    let mail: ConfiguredConnector
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        ConnectorCatalogSnapshot(connectors: [browser, mail])
    }
}

@Suite("Two connectors, each prepared by its own owner")
struct TwoConnectorLaunchTests {
    @Test("The browser gets this turn's directory and the mail reader gets none")
    func onlyTheBrowserOwnsADirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-two-connectors-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager().removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)

        // The browser's cache, node and Chrome, exactly as the browser suite
        // lays them out.
        let packageRoot = root.appendingPathComponent(
            "_npx/4c14ca9d614c46a6/node_modules/chrome-devtools-mcp", isDirectory: true)
        try ServiceFixture.write(packageRoot.appendingPathComponent("package.json"),
            #"{"name":"chrome-devtools-mcp","version":"1.8.0","bin":{"chrome-devtools-mcp":"./build/bin.js"}}"#)
        try ServiceFixture.write(packageRoot.appendingPathComponent("build/bin.js"), "#!/usr/bin/env node\n")
        let node = try ServiceFixture.write(root.appendingPathComponent("bin/node"), "#!/bin/sh\n",
                                            permissions: 0o755)
        let chrome = try ServiceFixture.write(root.appendingPathComponent("bin/Chrome"), "#!/bin/sh\n",
                                              permissions: 0o755)
        // And the mail reader, installed the way a tool install writes it.
        let package = AppOwnedConnectorCatalog.appleMailPackage
        let toolRoot = home.appendingPathComponent(".local/share/uv/tools/\(package)", isDirectory: true)
        try ServiceFixture.write(toolRoot.appendingPathComponent("bin/\(package)"),
                                 "#!/usr/bin/env python3\n", permissions: 0o755)
        try FileManager().createDirectory(at: toolRoot.appendingPathComponent(
            "lib/python3.14/site-packages/\(package.replacingOccurrences(of: "-", with: "_"))-0.10.2.dist-info",
            isDirectory: true), withIntermediateDirectories: true)

        let browserIdentity = try ConnectorIdentity(
            id: "claude-plugin:chrome-devtools-mcp@official:chrome-devtools",
            digest: String(repeating: "b", count: 64))
        let mailIdentity = try ConnectorIdentity(id: "openbots:apple-mail:apple-mail",
                                                 digest: String(repeating: "c", count: 64))
        let browserKey = "openbots_" + String(repeating: "9f3a2b01", count: 8)
        let mailKey = "openbots_" + String(repeating: "1c4d5e6f", count: 8)
        let catalog = TwoConnectorCatalog(
            browser: .init(definition: .init(identity: browserIdentity, serverName: "chrome-devtools",
                                             pluginName: "chrome-devtools-mcp@official", transport: .stdio),
                           launch: .init(serverKey: browserKey, transport: .stdio, command: "npx",
                                         arguments: ["chrome-devtools-mcp@1.8.0"])),
            mail: .init(definition: .init(identity: mailIdentity, serverName: "apple-mail",
                                          pluginName: "OpenBots Next", transport: .stdio),
                        launch: .init(serverKey: mailKey, transport: .stdio, command: package,
                                      arguments: ["--read-only"], pinnedPackage: "\(package)==0.10.2")))
        let store = ConnectorAccessStore(repository: MemoryConnectorRepository(), catalog: catalog)
        let profileRoot = root.appendingPathComponent("Profiles.noindex", isDirectory: true)
        let service = ConnectorLaunchService(
            store: store,
            preparations: [
                BrowserConnectorPreparation(npxCacheRootURL: root.appendingPathComponent("_npx", isDirectory: true),
                    interpreterCandidateURLs: [node], browserCandidateURLs: [chrome]),
                AppleMailConnectorPreparation(homeDirectoryURL: home),
            ],
            profileRootURL: profileRoot, temporaryDirectoryURL: root,
            fence: FenceProxyResource(scriptURL: FenceProxyResource.scriptURL,
                                      interpreterCandidateURLs: [node]))
        let teammateID = TeammateID(UUID())
        try await store.restore()
        try await store.setAppEnabled(true)
        try await store.setBotEnabled(true, identity: browserIdentity, teammateID: teammateID)
        try await store.setBotEnabled(true, identity: mailIdentity, teammateID: teammateID)

        let runID = UUID()
        let access = try #require(await service.connectorAccess(teammateID: teammateID, runID: runID))
        #expect(Set(access.servers.map(\.name)) == [browserKey, mailKey])
        #expect(access.role(forToolNamed: "mcp__\(mailKey)__get_messages") == .appleMailRead)
        #expect(access.role(forToolNamed: "mcp__\(browserKey)__new_page") == .browser)
        // One directory, the browser's — the mail reader must not leave a
        // folder nothing owns, a defect this once had.
        #expect(access.ownedProfileURLs.count == 1)
        let turnDirectory = profileRoot.appendingPathComponent("turn-\(runID.uuidString.lowercased())",
                                                               isDirectory: true)
        let entries = try FileManager()
            .contentsOfDirectory(at: turnDirectory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        #expect(entries == [browserKey])
        // Both are fenced: a page and a stranger's email are both somebody
        // else's words.
        let fenced = access.servers.filter { $0.program.isFenced }.count
        #expect(fenced == access.servers.count)
    }
}

private struct BoundedConnectorCatalog: ConnectorCatalogReading {
    let connectors: [ConfiguredConnector]
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        ConnectorCatalogSnapshot(connectors: connectors)
    }
}

private struct BoundedConnectorPreparation: ConnectorLaunchPreparing {
    func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        prepares(launch) ? .ready : nil
    }

    func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == "bounded-connector-fixture"
    }

    let needsOwnedProfile = false

    func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                temporaryDirectoryURL: URL,
                fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        guard prepares(launch), profileURL == nil, launch.arguments.count == 1,
              let roleName = launch.arguments.first,
              let role = ClaudeTextConnectorRole(rawValue: roleName) else {
            throw ClaudeTextConnectorAccessError.invalidServer
        }
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role,
            program: .installedTool(URL(fileURLWithPath: "/private/tmp/\(launch.serverKey)")),
            options: [], environment: [:])
    }
}

private func boundedConnectorFixtures() throws -> [ConfiguredConnector] {
    let roles = ClaudeTextConnectorRole.allCases
    return try (0...ClaudeTextConnectorAccess.maximumServerCount).map { index in
        let role = roles[index % roles.count]
        let identity = try ConnectorIdentity(
            id: index == 0
                ? "claude-plugin:bounded-fixture@official:server-\(index)"
                : "openbots:bounded-fixture-\(index):server-\(index)",
            // Sixty-four hex digits for any index: repeating the index itself
            // made a 128-character digest at ten, the day the bound passed nine.
            digest: String(format: "%064x", index))
        return ConfiguredConnector(
            definition: .init(identity: identity, serverName: "server-\(index)",
                              pluginName: "Bounded fixture", transport: .stdio),
            launch: .init(serverKey: "openbots_limit_service_\(index)", transport: .stdio,
                          command: "bounded-connector-fixture", arguments: [role.rawValue]))
    }
}

@Suite("The connector launch keeps its server bound")
struct ConnectorLaunchSelectionBoundTests {
    @Test("Connectors up to the bound flow through with every role among them, and one more refuses the whole launch")
    func upToTheBoundFlowsThroughAndOneMoreIsRejected() async throws {
        // Every role this build can launch fits under the bound at once; the
        // bound itself is read, never typed, so raising it rewrites nothing here.
        let bound = ClaudeTextConnectorAccess.maximumServerCount
        #expect(ClaudeTextConnectorRole.allCases.count <= bound)
        #expect(ConnectorLaunchService.maximumConnectorsPerBot == bound)
        let connectors = try boundedConnectorFixtures()
        #expect(connectors.count == bound + 1)
        let store = ConnectorAccessStore(repository: MemoryConnectorRepository(),
                                         catalog: BoundedConnectorCatalog(connectors: connectors))
        let service = ConnectorLaunchService(
            store: store, preparations: [BoundedConnectorPreparation()],
            profileRootURL: URL(fileURLWithPath: "/private/tmp/openbots-limit-profiles", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        let teammateID = TeammateID(UUID())
        try await store.restore()
        try await store.setAppEnabled(true)
        for connector in connectors.prefix(bound) {
            try await store.setBotEnabled(true, identity: connector.definition.identity, teammateID: teammateID)
        }

        let access = try #require(await service.connectorAccess(teammateID: teammateID, runID: UUID()))
        let expected = Set(connectors.prefix(bound).map(\.launch.serverKey))
        #expect(Set(access.servers.map(\.name)) == expected)
        // A set: the fixtures cycle through the roles, so once the bound is
        // larger than the role count a role appears twice.
        #expect(Set(access.servers.map(\.role)) == Set(ClaudeTextConnectorRole.allCases))

        try await store.setBotEnabled(true, identity: connectors[bound].definition.identity,
                                      teammateID: teammateID)
        #expect(await service.connectorAccess(teammateID: teammateID, runID: UUID()) == nil)
    }

    /// Why the per-bot switch counts only rows a launch can use: a grant no preparation owns is skipped here, so
    /// it never takes one of the bound's places.
    @Test("A grant no preparation owns is skipped by the launch, so the bound's places all go to connectors that run")
    func anUnownedGrantTakesNoPlaceInTheLaunch() async throws {
        let bound = ClaudeTextConnectorAccess.maximumServerCount
        let owned = Array(try boundedConnectorFixtures().prefix(bound))
        let unowned = ConfiguredConnector(
            definition: .init(identity: try ConnectorIdentity(id: "claude-plugin:imessage@claude-plugins-official:imessage",
                                                              digest: String(repeating: "e", count: 64)),
                              serverName: "imessage", pluginName: "imessage@claude-plugins-official", transport: .stdio),
            launch: .init(serverKey: "openbots_limit_service_unowned", transport: .stdio, command: "bun"))
        let store = ConnectorAccessStore(repository: MemoryConnectorRepository(),
                                         catalog: BoundedConnectorCatalog(connectors: owned + [unowned]))
        let service = ConnectorLaunchService(
            store: store, preparations: [BoundedConnectorPreparation()],
            profileRootURL: URL(fileURLWithPath: "/private/tmp/openbots-limit-profiles", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        let teammateID = TeammateID(UUID())
        try await store.restore()
        try await store.setAppEnabled(true)
        for connector in owned + [unowned] {
            try await store.setBotEnabled(true, identity: connector.definition.identity, teammateID: teammateID)
        }
        let access = try #require(await service.connectorAccess(teammateID: teammateID, runID: UUID()))
        #expect(Set(access.servers.map(\.name)) == Set(owned.map(\.launch.serverKey)))
    }
}
