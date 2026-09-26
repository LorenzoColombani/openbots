import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

/// A cache shaped like the real one: several versions of the same package, each
/// in its own opaque hash directory, so a resolution that keys on anything but
/// the recorded version picks the wrong copy.
private struct Fixture {
    let root: URL
    let cacheRoot: URL
    let interpreter: URL
    let browser: URL

    init(versions: [String] = ["1.0.1", "1.7.0", "1.8.0"], entry: String = "build/src/bin/chrome-devtools-mcp.js") throws {
        root = URL(fileURLWithPath: "/private/tmp/openbots-browser-prep-\(UUID().uuidString).noindex", isDirectory: true)
        cacheRoot = root.appendingPathComponent("_npx", isDirectory: true)
        interpreter = try Fixture.executable(root.appendingPathComponent("bin/node"))
        browser = try Fixture.executable(root.appendingPathComponent("bin/Google Chrome"))
        for (index, version) in versions.enumerated() {
            let packageRoot = cacheRoot
                .appendingPathComponent(String(format: "%016x", index &+ 0x0aed_ce19), isDirectory: true)
                .appendingPathComponent("node_modules/chrome-devtools-mcp", isDirectory: true)
            try Fixture.write(packageRoot.appendingPathComponent("package.json"), """
                {"name":"chrome-devtools-mcp","version":"\(version)","bin":{"chrome-devtools-mcp":"./\(entry)"}}
                """)
            try Fixture.write(packageRoot.appendingPathComponent(entry), "#!/usr/bin/env node\n")
        }
    }

    @discardableResult
    static func write(_ url: URL, _ contents: String, permissions: Int16 = 0o644) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        return url
    }

    static func executable(_ url: URL) throws -> URL { try write(url, "#!/bin/sh\n", permissions: 0o755) }

    func preparation() -> BrowserConnectorPreparation {
        BrowserConnectorPreparation(npxCacheRootURL: cacheRoot,
            interpreterCandidateURLs: [interpreter], browserCandidateURLs: [browser])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func launch(command: String = "npx", arguments: [String] = ["chrome-devtools-mcp@1.8.0"],
                    transport: ConnectorTransport = .stdio,
                    key: String = "openbots_" + String(repeating: "a", count: 64)) -> ConnectorLaunchConfiguration {
    ConnectorLaunchConfiguration(serverKey: key, transport: transport, command: command, arguments: arguments)
}

@Suite("Resolving the configured browser server to a copy already on the disk")
struct BrowserConnectorPreparationTests {
    @Test("The pinned version is resolved by its own recorded version, never by the cache directory")
    func resolvesTheExactVersion() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let resolved = try fixture.preparation().resolve(launch())
        #expect(resolved.version == "1.8.0")
        #expect(resolved.entryPointURL.lastPathComponent == "chrome-devtools-mcp.js")
        #expect(resolved.entryPointURL.path.hasPrefix(resolved.cacheDirectoryURL.path + "/"))
        // Compared standardized on both sides: a resolved tool is the file that
        // actually runs, and on this Mac `/private/tmp` standardizes to `/tmp`.
        #expect(resolved.interpreterURL == fixture.interpreter.resolvingSymlinksInPath())
        #expect(resolved.browserURL == fixture.browser.resolvingSymlinksInPath())
        // Several versions sit side by side in the real cache; the resolved
        // copy must be the one whose own manifest records 1.8.0.
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved.entryPointURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("package.json"))) as? [String: Any]
        #expect(manifest?["version"] as? String == "1.8.0")
        // The same launch always resolves to the same bytes.
        #expect(try fixture.preparation().resolve(launch()) == resolved)
    }

    @Test("A version that is not cached is a needs-setup answer, never a fetch")
    func missingVersionFailsClosed() throws {
        let fixture = try Fixture(versions: ["1.0.1", "1.7.0"]); defer { fixture.remove() }
        #expect(throws: BrowserConnectorPreparation.Failure.packageNotCached(version: "1.8.0")) {
            try fixture.preparation().resolve(launch())
        }
    }

    @Test("A floating or unreadable version is refused before anything is looked up")
    func floatingVersionsAreRefused() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for arguments in [["chrome-devtools-mcp@latest"], ["chrome-devtools-mcp"], ["chrome-devtools-mcp@"],
                          ["chrome-devtools-mcp@^1.8.0"], ["chrome-devtools-mcp@1.8.0-beta"], ["-y"], []] {
            #expect(throws: BrowserConnectorPreparation.Failure.self, "\(arguments)") {
                try fixture.preparation().resolve(launch(arguments: arguments))
            }
        }
        // A leading flag is skipped, not mistaken for the specification.
        #expect(try fixture.preparation().resolve(launch(arguments: ["-y", "chrome-devtools-mcp@1.8.0"])).version == "1.8.0")
    }

    @Test("Only the browser server, and only over stdio, is prepared")
    func otherConnectorsAreNotPrepared() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        #expect(throws: BrowserConnectorPreparation.Failure.notABrowserConnector) {
            try fixture.preparation().resolve(launch(arguments: ["some-other-server@1.0.0"]))
        }
        #expect(throws: BrowserConnectorPreparation.Failure.notABrowserConnector) {
            try fixture.preparation().resolve(launch(command: "python3"))
        }
        #expect(throws: BrowserConnectorPreparation.Failure.unsupportedTransport) {
            try fixture.preparation().resolve(launch(transport: .http))
        }
    }

    @Test("An entry point that leaves its package, or that anyone else can write, is refused")
    func untrustedEntryPointsAreRefused() throws {
        let escaping = try Fixture(versions: ["1.8.0"], entry: "build/../../../../escape.js")
        defer { escaping.remove() }
        try Fixture.write(escaping.root.appendingPathComponent("escape.js"), "// not in the package\n")
        #expect(throws: BrowserConnectorPreparation.Failure.entryPointUnusable) {
            try escaping.preparation().resolve(launch())
        }

        let writable = try Fixture(versions: ["1.8.0"]); defer { writable.remove() }
        let entry = try writable.preparation().resolve(launch()).entryPointURL
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o666))],
                                              ofItemAtPath: entry.path)
        #expect(throws: BrowserConnectorPreparation.Failure.entryPointUnusable) {
            try writable.preparation().resolve(launch())
        }
    }

    @Test("The interpreter and the browser are found the way they are actually installed")
    func realWorldInstallationsResolve() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        // Homebrew installs node as a symlink into the Cellar, which is how it
        // sits on this Mac. A check that refuses a symlink refuses node itself.
        let cellar = try Fixture.executable(fixture.root.appendingPathComponent("Cellar/node/26.8.2/bin/node"))
        let linked = fixture.root.appendingPathComponent("bin/node-link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: cellar)
        // Chrome in /Applications is group-writable by `admin` on a normal Mac.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o775))],
                                              ofItemAtPath: fixture.browser.path)
        let preparation = BrowserConnectorPreparation(npxCacheRootURL: fixture.cacheRoot,
            interpreterCandidateURLs: [linked], browserCandidateURLs: [fixture.browser])
        let resolved = try preparation.resolve(launch())
        // The launch names the binary that actually runs, not the link to it.
        #expect(resolved.interpreterURL == cellar.resolvingSymlinksInPath())
        #expect(resolved.browserURL.lastPathComponent == "Google Chrome")
    }

    @Test("An executable anyone on the Mac can rewrite is still refused")
    func worldWritableToolsAreRefused() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o777))],
                                              ofItemAtPath: fixture.interpreter.path)
        #expect(throws: BrowserConnectorPreparation.Failure.interpreterMissing) {
            try fixture.preparation().resolve(launch())
        }
        // The package's own entry point is held to the stricter standard: it
        // lives in the user's own cache, where nothing else should be writing.
        let strict = try Fixture(versions: ["1.8.0"]); defer { strict.remove() }
        let entry = try strict.preparation().resolve(launch()).entryPointURL
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o664))],
                                              ofItemAtPath: entry.path)
        #expect(throws: BrowserConnectorPreparation.Failure.entryPointUnusable) {
            try strict.preparation().resolve(launch())
        }
    }

    @Test("A tool belonging to somebody else on the Mac is refused")
    func toolsOwnedByAnotherUserAreRefused() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        // Everything on disk is ours; the check is told to expect a different
        // owner, which is the same thing as the file belonging to someone else.
        let stranger = BrowserConnectorPreparation(npxCacheRootURL: fixture.cacheRoot,
            interpreterCandidateURLs: [fixture.interpreter], browserCandidateURLs: [fixture.browser],
            ownerUID: getuid() &+ 1)
        #expect(throws: BrowserConnectorPreparation.Failure.self) { try stranger.resolve(launch()) }
        // And the same for the package's own files, which are held to the
        // stricter rule: ours, and writable by nobody else.
        let strangerWithTools = BrowserConnectorPreparation(npxCacheRootURL: fixture.cacheRoot,
            interpreterCandidateURLs: [], browserCandidateURLs: [])
        #expect(throws: BrowserConnectorPreparation.Failure.interpreterMissing) {
            try strangerWithTools.resolve(launch())
        }
    }

    @Test("A missing interpreter or browser is named, and nothing is guessed from the shell")
    func missingToolsAreNamed() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let noNode = BrowserConnectorPreparation(npxCacheRootURL: fixture.cacheRoot,
            interpreterCandidateURLs: [], browserCandidateURLs: [fixture.browser])
        #expect(throws: BrowserConnectorPreparation.Failure.interpreterMissing) { try noNode.resolve(launch()) }
        let noChrome = BrowserConnectorPreparation(npxCacheRootURL: fixture.cacheRoot,
            interpreterCandidateURLs: [fixture.interpreter], browserCandidateURLs: [])
        #expect(throws: BrowserConnectorPreparation.Failure.browserMissing) { try noChrome.resolve(launch()) }
    }

    @Test("The launch is headless, in this turn's own profile, and can say nothing else")
    func theLaunchIsExactlyThreeOptions() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let profile = fixture.root.appendingPathComponent("profiles/turn-1", isDirectory: true)
        // The real shipped shim, run by the fixture's own node so the whole
        // argument vector belongs to the fixture.
        let script = try #require(FenceProxyResource.scriptURL)
        let fence = FenceProxyResource(scriptURL: script, interpreterCandidateURLs: [fixture.interpreter])
        let server = try fixture.preparation().server(for: launch(), profileURL: profile,
                                                      temporaryDirectoryURL: fixture.root, fence: fence)
        let entryPoint = try fixture.preparation().resolve(launch()).entryPointURL
        let node = fixture.interpreter.resolvingSymlinksInPath()
        // A page's text is written by strangers, so the browser only ever runs
        // through the shim: node, the shim, the label the markers will name,
        // then the real command exactly as it would have been.
        #expect(server.program == .fenced(interpreterURL: node, proxyURL: script.standardizedFileURL,
            label: "the-web-page", server: .node(interpreterURL: node, entryPointURL: entryPoint)))
        #expect(server.executableURL == node)
        #expect(server.arguments == [
            script.standardizedFileURL.path, "the-web-page", node.path,
            entryPoint.path, "--executablePath", fixture.browser.resolvingSymlinksInPath().path,
            "--headless", "--userDataDir", profile.path])
        #expect(server.ownedProfileURLsAreOnlyThisTurn(profile))
        // Nothing that would reach the user's own logged-in Chrome.
        for forbidden in ["--browserUrl", "--wsEndpoint", "--wsHeaders", "--autoConnect",
                          "--proxyServer", "--acceptInsecureCerts", "--experimentalVision"] {
            #expect(!server.arguments.contains(forbidden))
        }
        #expect(server.environment["CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS"] == "1")
        #expect(server.environment["CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS"] == "1")
        // The 1.8.0 server never reads CHROME_PATH; Chrome is an argument.
        #expect(server.environment["CHROME_PATH"] == nil)
        // The server's home is its own, never the login the turn authenticates with.
        #expect(server.environment["HOME"] != NSHomeDirectory())
        #expect(server.environment["PATH"] == nil)
    }

    @Test("The server takes the catalog's key as its name, and admits only its own tools")
    func namespaceFollowsTheCatalogKey() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let key = "openbots_" + String(repeating: "9f3a2b01", count: 8)
        let server = try fixture.preparation().server(for: launch(key: key),
            profileURL: fixture.root.appendingPathComponent("p", isDirectory: true),
            temporaryDirectoryURL: fixture.root)
        #expect(server.name == key)
        let access = try ClaudeTextConnectorAccess(servers: [server])
        #expect(access.admitsToolName("mcp__\(key)__navigate_page"))
        #expect(access.admitsToolName("mcp__\(key)__take_snapshot"))
        #expect(!access.admitsToolName("mcp__someone_else__navigate_page"))
        #expect(!access.admitsToolName("mcp__\(key)__nested__tool"))
        #expect(!access.admitsToolName("Bash"))
        #expect(!access.admitsToolName("mcp__\(key)__"))
        #expect(access.ownedProfileURLs.count == 1)
    }
}

private extension ClaudeTextConnectorServer {
    func ownedProfileURLsAreOnlyThisTurn(_ expected: URL) -> Bool {
        options.compactMap(\.ownedProfileURL) == [expected]
    }
}
