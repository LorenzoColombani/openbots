import XCTest
@testable import AgencyKit

/// Claude Desktop extension reuse (his order 2026-08-13): Anthropic-authored
/// extensions on this Mac become connectors — first-party servers over
/// community ones. Parsing is fixture-tested; discovery against the real
/// extensions dir is skip-if-absent.
final class AnthropicExtensionsTests: XCTestCase {
    /// The real extension's tool list (manifest.json 0.1.11, verified on this
    /// Mac 2026-08-13) — the send tool is the one agency supersedes.
    static let imessageTools: [[String: Any]] = [
        ["name": "send_imessage", "description": "Send an iMessage to a contact"],
        ["name": "search_contacts", "description": "Search contacts"],
        ["name": "read_imessages", "description": "Read recent iMessages"],
        ["name": "get_unread_imessages", "description": "Get all unread iMessages"],
    ]

    private func manifest(author: String = "Anthropic", name: String = "Read and Send iMessages",
                          args: [String] = ["${__dirname}/server/index.js"],
                          env: [String: String]? = ["HOME": "${HOME}"],
                          tools: [[String: Any]]? = nil) -> [String: Any] {
        var mcp: [String: Any] = ["command": "node", "args": args]
        if let env { mcp["env"] = env }
        var m: [String: Any] = ["display_name": name, "version": "0.1.11",
                                "author": ["name": author],
                                "server": ["type": "node", "entry_point": "server/index.js", "mcp_config": mcp]]
        if let tools { m["tools"] = tools }
        return m
    }

    func testAnthropicManifestBecomesAConnector() throws {
        let c = try XCTUnwrap(AnthropicExtensions.connector(
            manifest: manifest(tools: Self.imessageTools), extensionPath: "/ext/imsg"))
        XCTAssertEqual(c.id, "imessage", "curated id fills the existing catalog placeholder")
        let server = try XCTUnwrap(c.mcpServers["imessage"])
        XCTAssertEqual(server["command"] as? String, "node")
        XCTAssertEqual(server["args"] as? [String], ["/ext/imsg/server/index.js"],
                       "${__dirname} substituted")
        XCTAssertEqual((server["env"] as? [String: String])?["HOME"], NSHomeDirectory(),
                       "${HOME} substituted")
        // His report 2026-08-13: the extension's own sender hardcodes
        // `service type = iMessage`, so Android contacts get nothing. Agency's
        // service-aware sender rides alongside and the broken tool is REMOVED.
        XCTAssertNotNil(c.mcpServers["messages"], "agency's own sender is wired alongside")
        XCTAssertEqual(c.disallowedTools.sorted(),
                       ["mcp__imessage__get_unread_imessages", "mcp__imessage__read_imessages",
                        "mcp__imessage__send_imessage"],
                       "the iMessage-only sender AND the hex-dumping readers are removed from "
                       + "context, not merely un-approved")
        XCTAssertTrue(c.allowedTools.contains("mcp__messages"))
        XCTAssertEqual(c.allowedTools.filter { $0.hasPrefix("mcp__imessage") },
                       ["mcp__imessage__search_contacts"],
                       "contact lookup is the one job the extension still owns — it reads the "
                       + "Contacts app, not chat.db")
        XCTAssertFalse(c.allowedTools.contains("mcp__imessage"),
                       "whole-server approval would re-admit the superseded sender")
        XCTAssertFalse(c.needsNetwork, "iMessage is a LOCAL mechanism — fenced agents keep it")
        // requiresSetup is now LIVE, not a constant (his report: the badge
        // still said "needs setup" after the permission was granted). It
        // reflects whether THIS process can actually read the message DB.
        let dbReadable = FileManager.default.isReadableFile(
            atPath: "\(NSHomeDirectory())/Library/Messages/chat.db")
        XCTAssertEqual(c.requiresSetup, !dbReadable,
                       "the badge must track the real permission, not a hardcoded flag")
    }

    func testNonAnthropicManifestIsRefused() {
        XCTAssertNil(AnthropicExtensions.connector(
            manifest: manifest(author: "Community Author", name: "Control your Mac"),
            extensionPath: "/ext/osa"),
            "community extensions go through normal vetting, not auto-adoption")
    }

    func testFilesystemExtensionIsPinnedToShared() throws {
        let c = try XCTUnwrap(AnthropicExtensions.connector(
            manifest: manifest(name: "Filesystem",
                               args: ["${__dirname}/dist/index.js", "${user_config.allowed_directories}"],
                               env: nil),
            extensionPath: "/ext/fs"))
        XCTAssertEqual(c.id, "filesystem-shared", "replaces the npx server (fence review I6)")
        let args = try XCTUnwrap(c.mcpServers["filesystem-shared"]?["args"] as? [String])
        XCTAssertEqual(args, ["/ext/fs/dist/index.js", "\(Connector.rootToken)/shared"],
                       "agency pins the scope ITSELF — Desktop's user config is ignored; this arg IS the fence (MCP file tools bypass deny rules)")
    }

    func testChromeControlLiftsTheFenceAndWarns() throws {
        let c = try XCTUnwrap(AnthropicExtensions.connector(
            manifest: manifest(name: "Control Chrome", env: nil), extensionPath: "/ext/cc"))
        XCTAssertEqual(c.id, "chrome-control")
        XCTAssertTrue(c.needsNetwork, "driving a real browser IS arbitrary egress")
        XCTAssertTrue(c.summary.contains("REAL Chrome"), "the trust difference is stated, loudly")
    }

    func testUnknownAnthropicExtensionGetsAGenericEntry() throws {
        let c = try XCTUnwrap(AnthropicExtensions.connector(
            manifest: manifest(name: "Future Thing 2.0"), extensionPath: "/ext/ft"))
        XCTAssertEqual(c.id, "ext-future-thing-2-0", "slugged id")
        XCTAssertTrue(c.requiresSetup, "unknown = flagged for his review, not auto-trusted")
        XCTAssertFalse(c.needsNetwork, "sealed by default, like everything")
    }

    func testDiscoveryOnThisMacIfExtensionsPresent() throws {
        let found = AnthropicExtensions.discovered()
        guard !found.isEmpty else { throw XCTSkip("no Claude Desktop extensions on this machine") }
        XCTAssertTrue(found.contains { $0.id == "imessage" })
        XCTAssertTrue(found.allSatisfy { !$0.mcpServers.isEmpty }, "every discovered entry is wired")
        // The catalog overlay: imessage is no longer a placeholder.
        let imessage = try XCTUnwrap(Connector.byID("imessage"))
        XCTAssertFalse(imessage.mcpServers.isEmpty, "the placeholder got filled")
        XCTAssertNotNil(imessage.mcpServers["messages"],
                        "the overlay must keep agency's own sender — losing it restores the Android bug")
        XCTAssertTrue(imessage.allowedTools.contains("mcp__messages"),
                      "whole-entry overlay — no stale empty allowedTools")
    }
}
