import Foundation
import OpenBotsDomain
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

/// A home directory laid out the way `uv tool install` really lays one out: the
/// console script under `.local/share/uv/tools/<package>/bin/`, a symlink to it
/// in `.local/bin`, and the version recorded only in the `dist-info` directory
/// beside the installed package — never in a path.
private struct ToolFixture {
    let root: URL
    let home: URL
    let script: URL

    init(version: String? = "0.10.2", permissions: Int16 = 0o755) throws {
        let package = AppOwnedConnectorCatalog.appleMailPackage
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-mail-tool-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        let toolRoot = home.appendingPathComponent(".local/share/uv/tools/\(package)", isDirectory: true)
        let binary = toolRoot.appendingPathComponent("bin", isDirectory: true)
        let manager = FileManager()
        try manager.createDirectory(at: binary, withIntermediateDirectories: true)
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try manager.createDirectory(at: localBin, withIntermediateDirectories: true)
        let real = binary.appendingPathComponent(package)
        try Data("#!/usr/bin/env python3\nprint('mcp')\n".utf8).write(to: real)
        try manager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: real.path)
        if let version {
            // Python 3.14 is what uv installed here; the search must not assume
            // one version of Python either.
            let packages = toolRoot.appendingPathComponent("lib/python3.14/site-packages", isDirectory: true)
            let distInfo = packages.appendingPathComponent(
                "\(package.replacingOccurrences(of: "-", with: "_"))-\(version).dist-info", isDirectory: true)
            try manager.createDirectory(at: distInfo, withIntermediateDirectories: true)
            try Data("Version: \(version)\n".utf8).write(to: distInfo.appendingPathComponent("METADATA"))
        }
        script = real
    }

    func preparation() -> AppleMailConnectorPreparation {
        AppleMailConnectorPreparation(homeDirectoryURL: home)
    }

    func remove() { try? FileManager().removeItem(at: root) }
}

private func mailLaunch(command: String = AppOwnedConnectorCatalog.appleMailPackage,
                        pinned: String? = "apple-mail-fast-mcp==0.10.2",
                        transport: ConnectorTransport = .stdio) -> ConnectorLaunchConfiguration {
    ConnectorLaunchConfiguration(serverKey: "openbots_" + String(repeating: "c", count: 64),
        transport: transport, command: command, arguments: ["--read-only"], pinnedPackage: pinned)
}

@Suite("Finding the mail reader on this Mac")
struct AppleMailConnectorPreparationTests {
    @Test("The installed script resolves, and its version comes from the install's own record")
    func theToolResolves() throws {
        let fixture = try ToolFixture(); defer { fixture.remove() }
        let resolved = try fixture.preparation().resolve(mailLaunch())
        #expect(resolved.script == fixture.script.resolvingSymlinksInPath())
        #expect(resolved.version == "0.10.2")
    }

    @Test("A version the app does not pin is refused, and the row says which one is installed")
    func anotherVersionIsRefused() throws {
        let fixture = try ToolFixture(version: "0.11.0"); defer { fixture.remove() }
        #expect(throws: AppleMailConnectorPreparation.Failure.wrongVersion(installed: "0.11.0")) {
            try fixture.preparation().resolve(mailLaunch())
        }
        let reason = try #require(fixture.preparation().availability(for: mailLaunch())?.reason)
        #expect(reason.contains("0.11.0") && reason.contains("0.10.2"))
    }

    @Test("An install with no record of its version is not taken on trust")
    func anUnrecordedVersionIsRefused() throws {
        let fixture = try ToolFixture(version: nil); defer { fixture.remove() }
        #expect(throws: AppleMailConnectorPreparation.Failure.wrongVersion(installed: nil)) {
            try fixture.preparation().resolve(mailLaunch())
        }
    }

    @Test("Nothing installed is a needs-setup answer naming the one command that fixes it")
    func nothingInstalledIsNeedsSetup() throws {
        let fixture = try ToolFixture(); defer { fixture.remove() }
        try FileManager().removeItem(at: fixture.script)
        #expect(throws: AppleMailConnectorPreparation.Failure.toolNotInstalled) {
            try fixture.preparation().resolve(mailLaunch())
        }
        let availability = try #require(fixture.preparation().availability(for: mailLaunch()))
        #expect(availability.badge == "needs setup")
        #expect(try #require(availability.reason).contains("uv tool install apple-mail-fast-mcp==0.10.2"))
    }

    @Test("A script anyone on the Mac could rewrite is not run")
    func aWorldWritableScriptIsRefused() throws {
        let fixture = try ToolFixture(permissions: 0o777); defer { fixture.remove() }
        #expect(throws: AppleMailConnectorPreparation.Failure.toolNotInstalled) {
            try fixture.preparation().resolve(mailLaunch())
        }
    }

    @Test("The launch is the script itself, read-only, fenced, and owns no directory")
    func theLaunchIsReadOnlyAndFenced() throws {
        let fixture = try ToolFixture(); defer { fixture.remove() }
        let script = try #require(FenceProxyResource.scriptURL)
        let node = URL(fileURLWithPath: "/bin/sh")
        let fence = FenceProxyResource(scriptURL: script, interpreterCandidateURLs: [node])
        let launch = mailLaunch()
        let server = try fixture.preparation().server(for: launch, profileURL: nil,
                                                      temporaryDirectoryURL: fixture.root, fence: fence)
        #expect(server.role == .appleMailRead)
        #expect(server.name == launch.serverKey)
        #expect(server.program.isFenced)
        #expect(server.arguments == [script.standardizedFileURL.path, "apple-mail",
                                     fixture.script.resolvingSymlinksInPath().path, "--read-only"])
        // Nothing to reap and nothing to clean up: a mail turn owns no profile.
        #expect(server.options.compactMap(\.ownedProfileURL).isEmpty)
        // Its own home is named rather than inherited, and it sits inside the
        // app's scratch space so nothing it writes outlives that.
        #expect(server.environment == ["APPLE_MAIL_MCP_HOME":
            fixture.root.appendingPathComponent("apple-mail", isDirectory: true).path])
        #expect(!FileManager().fileExists(
            atPath: fixture.root.appendingPathComponent("apple-mail").path), "nothing is created up front")
        #expect(!fixture.preparation().needsOwnedProfile)
    }

    @Test("Without the fence the reader is not launched at all")
    func noFenceNoLaunch() throws {
        let fixture = try ToolFixture(); defer { fixture.remove() }
        #expect(throws: AppleMailConnectorPreparation.Failure
            .fenceUnavailable(.scriptMissing)) {
            try fixture.preparation().server(for: mailLaunch(), profileURL: nil,
                temporaryDirectoryURL: fixture.root, fence: FenceProxyResource(scriptURL: nil))
        }
    }

    @Test("Another connector's row is not this preparation's to answer")
    func anotherRowIsNotItsOwn() throws {
        let fixture = try ToolFixture(); defer { fixture.remove() }
        let preparation = fixture.preparation()
        let browser = ConnectorLaunchConfiguration(serverKey: "openbots_x", transport: .stdio,
            command: "npx", arguments: ["chrome-devtools-mcp@1.8.0"])
        #expect(!preparation.prepares(browser))
        #expect(preparation.availability(for: browser) == nil)
        #expect(throws: AppleMailConnectorPreparation.Failure.notTheMailConnector) {
            try preparation.resolve(browser)
        }
        // The right command with the wrong pin is not it either: the pin is
        // part of what the grant was given for.
        #expect(throws: AppleMailConnectorPreparation.Failure.notTheMailConnector) {
            try preparation.resolve(mailLaunch(pinned: "apple-mail-fast-mcp==0.9.0"))
        }
        #expect(throws: AppleMailConnectorPreparation.Failure.unsupportedTransport) {
            try preparation.resolve(mailLaunch(transport: .http))
        }
    }
}
