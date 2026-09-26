import Foundation
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsPersistence
@testable import OpenBotsServices
import Testing

/// The Claude Desktop extensions as a third catalog source: every one listed,
/// only a reviewed one launchable, and that one only as the exact copy
/// reviewed. Everything here runs on a made-up extensions folder; nothing
/// reads the real one.
@Suite("Claude Desktop extensions: listed, unavailable until reviewed, pinned to the reviewed copy")
struct ClaudeExtensionConnectorTests {
    /// The made-up reviewed folder's files, and their digest as computed by an
    /// independent script (Python's hashlib, the same line format).
    static let files: [String: String] = [
        "manifest.json": "{\"version\":\"0.1.7\",\"name\":\"Notes\"}\n",
        "server/index.js": "console.log(\"fixture\")\n",
        "node_modules/pkg/package.json": "{\"name\":\"pkg\"}\n",
    ]
    static let digest = "b6066e37f32784e6d0a9cd32296fb8f99dcbd497631968c38676f6c3898f2507"
    static let folder = "ant.dir.test.notes"

    private struct Fixture {
        let root: URL
        let extensions: URL
        let node: URL
        let fenceScript: URL

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextExtensions-\(UUID()).noindex", isDirectory: true)
            extensions = root.appendingPathComponent("Claude Extensions", isDirectory: true)
            node = root.appendingPathComponent("bin/node")
            fenceScript = root.appendingPathComponent("fence-proxy.js")
            let manager = FileManager()
            try manager.createDirectory(at: extensions, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try write(node, "#!/bin/sh\n", mode: 0o755)
            try write(fenceScript, "// fence\n", mode: 0o644)
            for (path, contents) in ClaudeExtensionConnectorTests.files {
                try write(extensions.appendingPathComponent("\(ClaudeExtensionConnectorTests.folder)/\(path)"), contents)
            }
        }

        func write(_ url: URL, _ contents: String, mode: Int16 = 0o644) throws {
            try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o755])
            try Data(contents.utf8).write(to: url)
            try FileManager().setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        }

        func extensionFolder(_ name: String = ClaudeExtensionConnectorTests.folder) -> URL {
            extensions.appendingPathComponent(name, isDirectory: true)
        }

        var review: ClaudeExtensionConnectorPreparation.Review {
            ClaudeExtensionConnectorPreparation.Review(
                folder: ClaudeExtensionConnectorTests.folder, version: "0.1.7",
                treeSHA256: ClaudeExtensionConnectorTests.digest, entryPoint: "server/index.js", role: .appleNotes,
                tools: ClaudeExtensionConnectorPreparation.notes.tools, title: "Apple Notes", summary: "Reviewed.")
        }

        func preparation() -> ClaudeExtensionConnectorPreparation {
            ClaudeExtensionConnectorPreparation(extensionsRootURL: extensions, interpreterCandidateURLs: [node],
                reviews: [review], fence: fenceResource())
        }

        func fenceResource() -> FenceProxyResource {
            FenceProxyResource(scriptURL: fenceScript, interpreterCandidateURLs: [node])
        }

        func catalog(_ preparation: ClaudeExtensionConnectorPreparation) -> ClaudeExtensionConnectorCatalog {
            ClaudeExtensionConnectorCatalog(extensionsRootURL: extensions, preparation: preparation)
        }

        func remove() { try? FileManager().removeItem(at: root) }
    }

    @Test("The digest is every file's path and SHA-256, in path order, and Finder's .DS_Store is left out")
    func theDigestIsTheReviewedFormat() throws {
        let f = try Fixture(); defer { f.remove() }
        let folder = f.extensionFolder()
        #expect(try ClaudeExtensionConnectorPreparation.treeDigest(of: folder, ownerUID: getuid()) == Self.digest)
        try f.write(folder.appendingPathComponent(".DS_Store"), "Finder was here")
        try f.write(folder.appendingPathComponent("server/.DS_Store"), "and here")
        #expect(try ClaudeExtensionConnectorPreparation.treeDigest(of: folder, ownerUID: getuid()) == Self.digest)
        try f.write(folder.appendingPathComponent("node_modules/pkg/package.json"), "{\"name\":\"pkg!\"}\n")
        #expect(try ClaudeExtensionConnectorPreparation.treeDigest(of: folder, ownerUID: getuid()) != Self.digest)
    }

    @Test("A link, or a file anyone else can write, refuses the whole folder")
    func anUnsafeTreeIsRefused() throws {
        let f = try Fixture(); defer { f.remove() }
        let folder = f.extensionFolder()
        try FileManager().createSymbolicLink(atPath: folder.appendingPathComponent("server/link.js").path,
                                             withDestinationPath: "/etc/hosts")
        #expect(throws: ClaudeExtensionConnectorPreparation.Failure.unsafeTree) {
            try ClaudeExtensionConnectorPreparation.treeDigest(of: folder, ownerUID: getuid())
        }
        try FileManager().removeItem(at: folder.appendingPathComponent("server/link.js"))
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o666))],
            ofItemAtPath: folder.appendingPathComponent("server/index.js").path)
        #expect(throws: ClaudeExtensionConnectorPreparation.Failure.unsafeTree) {
            try ClaudeExtensionConnectorPreparation.treeDigest(of: folder, ownerUID: getuid())
        }
    }

    @Test("The reviewed copy is a ready row under the extension source, and a changed copy is a different, unavailable one")
    func theReviewedCopyIsReadyAndAChangedOneIsNot() async throws {
        let f = try Fixture(); defer { f.remove() }
        let catalog = f.catalog(f.preparation())
        let ready = try #require(try await catalog.loadConnectorCatalog().connectors.first)
        #expect(ready.definition.id == "claude-extension:\(Self.folder):notes")
        #expect(ready.definition.identity.source == .claudeExtension)
        #expect(ready.definition.availability == .ready)
        #expect(ready.definition.title == "Apple Notes" && ready.definition.pluginName == "Claude Desktop extension")
        #expect(ready.launch.command == ClaudeExtensionConnectorPreparation.command)
        #expect(ready.launch.arguments == [Self.folder])

        try f.write(f.extensionFolder().appendingPathComponent("server/index.js"), "console.log(\"changed\")\n")
        let changed = try #require(try await catalog.loadConnectorCatalog().connectors.first)
        #expect(changed.definition.id == ready.definition.id)
        #expect(changed.definition.identity != ready.definition.identity, "a changed copy must switch a grant off")
        #expect(changed.definition.availability
                == .unavailable("This copy is not the one OpenBots Next checked, so it will not run it."))
    }

    @Test("Another version of a reviewed extension says which version was checked")
    func anotherVersionIsUnavailable() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.extensionFolder().appendingPathComponent("manifest.json"), "{\"version\":\"0.1.8\",\"name\":\"Notes\"}\n")
        let row = try #require(try await f.catalog(f.preparation()).loadConnectorCatalog().connectors.first)
        #expect(row.definition.availability == .unavailable(
            "This is version 0.1.8; OpenBots Next checked version 0.1.7, so it will not run it."))
    }

    @Test("An extension not reviewed is listed with its own words and a reason, and nothing here runs it")
    func anUnreviewedExtensionIsUnowned() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.extensionFolder("ant.dir.ant.anthropic.chrome-control").appendingPathComponent("manifest.json"),
            "{\"version\":\"0.1.6\",\"name\":\"chrome-control\",\"display_name\":\"Control Chrome\","
                + "\"description\":\"Control Google Chrome\\nbrowser tabs.\",\"author\":{\"name\":\"Anthropic\"}}")
        try f.write(f.extensionFolder("ant.dir.gh.k6l3.osascript").appendingPathComponent("manifest.json"),
            "{\"version\":\"0.0.1\",\"name\":\"Control your Mac\"}")
        let rows = try await f.catalog(f.preparation()).loadConnectorCatalog().connectors
        let chrome = try #require(rows.first { $0.definition.serverName == "chrome-control" })
        #expect(chrome.definition.title == "Control Chrome")
        #expect(chrome.definition.summary == "Control Google Chrome browser tabs.\n"
            + "Claude Desktop extension by Anthropic · version 0.1.6")
        #expect(chrome.definition.availability == .unowned(ClaudeExtensionConnectorCatalog.notReviewedYet))
        let script = try #require(rows.first { $0.definition.serverName == "osascript" })
        #expect(script.definition.title == "Control your Mac")
        #expect(script.definition.availability == .unowned(
            "It runs any AppleScript as you. Control this Mac does this, with cards."))
        #expect(!f.preparation().prepares(chrome.launch) && !f.preparation().prepares(script.launch))
    }

    @Test("A folder or manifest that cannot be read is one row left out, and a missing folder is an empty list")
    func aBadRowIsLeftOutAndCounted() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(f.extensionFolder("ant.dir.x.broken").appendingPathComponent("manifest.json"), "not json")
        try f.write(f.extensionFolder("bad name").appendingPathComponent("manifest.json"), "{\"version\":\"1\"}")
        try f.write(f.extensionFolder("ant.dir.x.odd").appendingPathComponent("manifest.json"),
                    "{\"version\":\"1.0-beta\"}")
        let snapshot = try await f.catalog(f.preparation()).loadConnectorCatalog()
        #expect(snapshot.connectors.map(\.definition.serverName) == ["notes"])
        #expect(snapshot.excludedCount == 3)
        let absent = ClaudeExtensionConnectorCatalog(
            extensionsRootURL: f.root.appendingPathComponent("nowhere"), preparation: f.preparation())
        #expect(try await absent.loadConnectorCatalog() == ConnectorCatalogSnapshot())
    }

    @Test("The reviewed copy launches its own server through the fence, with only a search path for osascript")
    func theReviewedCopyLaunchesFenced() async throws {
        let f = try Fixture(); defer { f.remove() }
        let preparation = f.preparation()
        let row = try #require(try await f.catalog(preparation).loadConnectorCatalog().connectors.first)
        #expect(preparation.prepares(row.launch) && !preparation.needsOwnedProfile)
        #expect(preparation.availability(for: row.launch) == .ready)
        let server = try preparation.server(for: row.launch, profileURL: nil,
            temporaryDirectoryURL: f.root, fence: f.fenceResource())
        #expect(server.role == .appleNotes)
        #expect(server.program.isFenced)
        #expect(server.arguments.contains(
            f.extensionFolder().appendingPathComponent("server/index.js").standardizedFileURL.path))
        #expect(server.arguments.contains("apple-notes"))
        #expect(server.environment == ["PATH": "/usr/bin:/bin"])

        try f.write(f.extensionFolder().appendingPathComponent("server/index.js"), "console.log(\"swapped\")\n")
        #expect(throws: ClaudeExtensionConnectorPreparation.Failure.notTheReviewedCopy) {
            try preparation.server(for: row.launch, profileURL: nil, temporaryDirectoryURL: f.root,
                                   fence: f.fenceResource())
        }
        #expect(preparation.availability(for: row.launch)
                == .unavailable("This copy is not the one OpenBots Next checked, so it will not run it."))
    }

    /// A read that could not tell (a file unreadable for a moment, a manifest
    /// that would not open, a folder that would not list) is not a change: the
    /// row keeps the identity it had, so no bot's grant is switched off for good
    /// by a blip (the store's Google rows work the same way).
    @Test("A reviewed extension that cannot be read just now keeps its identity, unavailable, and is read again next time")
    func aReadThatCannotTellHoldsTheRow() async throws {
        let f = try Fixture(); defer { f.remove() }
        let catalog = f.catalog(f.preparation())
        let index = f.extensionFolder().appendingPathComponent("server/index.js")
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: index.path)
        let held = try #require(try await catalog.loadConnectorCatalog().connectors.first)
        #expect(held.holdsPriorIdentity)
        #expect(held.definition.availability == .unavailable(ClaudeExtensionConnectorCatalog.couldNotReadNow))
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: index.path)

        let manifest = f.extensionFolder().appendingPathComponent("manifest.json")
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: manifest.path)
        #expect(try await catalog.loadConnectorCatalog().connectors.first?.holdsPriorIdentity == true)
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: manifest.path)

        // The folder of every extension, listed but unreadable: the reviewed
        // rows are held; nothing is said about rows it cannot see.
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: f.extensions.path)
        let listing = try await catalog.loadConnectorCatalog()
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: f.extensions.path)
        #expect(listing.connectors.map(\.definition.id) == ["claude-extension:\(Self.folder):notes"])
        #expect(listing.connectors.allSatisfy { $0.holdsPriorIdentity })
        #expect(try await catalog.loadConnectorCatalog().connectors.first?.definition.availability == .ready)
    }

    @Test("A bot's Notes grant survives a read that could not tell, and runs again after it")
    func aGrantSurvivesABlip() async throws {
        let f = try Fixture(); defer { f.remove() }
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        let db = try SQLiteStore(configuration: .init(fileURL: f.root.appending(path: "control.sqlite"),
                                                      protection: .ordinarySQLite(decision: protection)))
        let bot = TeammateID(UUID())
        let store = ConnectorAccessStore(repository: db, catalog: f.catalog(f.preparation()))
        try await store.restore()
        try await store.setAppEnabled(true)
        let row = try #require(await store.current().definitions.first)
        try await store.setBotEnabled(true, identity: row.identity, teammateID: bot)
        #expect(await store.lease(teammateID: bot) != nil)

        let index = f.extensionFolder().appendingPathComponent("server/index.js")
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: index.path)
        try await store.refreshCatalog()
        #expect(await store.current(teammateID: bot).selectedIDs == [row.id])
        #expect(await store.current(teammateID: bot).changedSinceAllowed.isEmpty)
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: index.path)
        try await store.refreshCatalog()
        #expect(await store.lease(teammateID: bot)?.identities == [row.identity])

        // A copy that reads cleanly and differs is a change, and says so.
        try f.write(index, "console.log(\"updated\")\n")
        try await store.refreshCatalog()
        #expect(await store.lease(teammateID: bot) == nil)
        #expect(await store.current(teammateID: bot).changedSinceAllowed == [row.id])
    }

    /// Claude Desktop keeps a list of extensions Anthropic has blocked. A
    /// reviewed copy on it is not run, and a list that cannot be read blocks
    /// too; the grant is kept, so an entry taken off gives the bot Notes back.
    @Test("An extension on Claude Desktop's blocklist, or behind an unreadable one, is not run")
    func theBlocklistIsHonoured() async throws {
        let f = try Fixture(); defer { f.remove() }
        let preparation = f.preparation()
        let row = try #require(try await f.catalog(preparation).loadConnectorCatalog().connectors.first)
        let blocklist = f.root.appendingPathComponent("extensions-blocklist.json")
        try f.write(blocklist, "[{\"entries\":[{\"id\":\"ant.dir.gh.other.thing\",\"hash\":null}],\"lastUpdated\":\"x\"}]")
        #expect(preparation.availability(for: row.launch) == .ready)
        try f.write(blocklist, "[{\"entries\":[{\"id\":\"\(Self.folder)\",\"hash\":null,\"reason\":\"\"}]}]")
        #expect(preparation.availability(for: row.launch) == .unavailable(
            "Claude Desktop has blocked this extension, so OpenBots Next will not run it."))
        #expect(throws: ClaudeExtensionConnectorPreparation.Failure.blockedByClaudeDesktop) {
            try preparation.server(for: row.launch, profileURL: nil, temporaryDirectoryURL: f.root,
                                   fence: f.fenceResource())
        }
        try f.write(blocklist, "{\"not\":\"a list\"}")
        #expect(preparation.availability(for: row.launch) == .unavailable(
            "Claude Desktop's list of blocked extensions could not be read, so OpenBots Next will not run this one."))
    }

    /// The browser's preparation reads any `node` or `npx` row as its own and
    /// calls one it cannot parse a broken browser; an extension row is written
    /// so that no preparation but its own answers for it.
    @Test("No other preparation claims an extension row, so none can answer for it first")
    func noOtherPreparationClaimsAnExtensionRow() async throws {
        let f = try Fixture(); defer { f.remove() }
        let row = try #require(try await f.catalog(f.preparation()).loadConnectorCatalog().connectors.first)
        let others: [any ConnectorLaunchPreparing] = [
            BrowserConnectorPreparation(npxCacheRootURL: f.root),
            AppleMailConnectorPreparation(homeDirectoryURL: f.root),
            AppleMailSendPreparation(), AppleContactsConnectorPreparation(), AppleCalendarConnectorPreparation(),
            AppleMessagesConnectorPreparation(databaseURL: f.root.appendingPathComponent("chat.db")),
            GoogleWorkspaceConnectorPreparation(), MacControlConnectorPreparation(npxCacheRootURL: f.root),
        ]
        for other in others {
            #expect(!other.prepares(row.launch), "\(type(of: other)) claims an extension row")
            #expect(other.availability(for: row.launch) == nil, "\(type(of: other)) answers for an extension row")
        }
    }
}
