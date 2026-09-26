import Foundation
import OpenBotsDomain
@testable import OpenBotsServices
import Testing

@Suite("Metadata-only Claude plugin connector catalog")
struct ClaudePluginConnectorCatalogTests {
    @Test("Only enabled user-scope definitions are imported, with stable identity and no process launch")
    func configuredInventory() async throws {
        let f = try Fixture(); defer { f.remove() }
        let pluginRoot = try f.plugin("docs", servers: [
            "documentation": ["type": "http", "url": "https://docs.example.test/mcp"],
            "local": ["command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/server.js"]]
        ])
        try f.plugin("disabled", servers: ["hidden": ["command": "npx", "args": ["never-run-this"]]], enabled: false)
        try f.plugin("project", servers: ["hidden": ["command": "npx", "args": ["never-run-this"]]], scope: "project")
        let first = try await f.catalog().loadConnectorCatalog()
        #expect(first.connectors.map { $0.definition.serverName }.sorted() == ["documentation", "local"])
        #expect(first.excludedCount == 0)
        let local = try #require(first.connectors.first { $0.definition.serverName == "local" })
        #expect(local.launch.arguments == [pluginRoot.appending(path: "server.js").path])
        #expect(!FileManager.default.fileExists(atPath: local.launch.arguments[0]), "Discovery does not run or create the configured script")
        #expect(local.definition.id == "claude-plugin:docs@fixture:local")
        #expect(local.launch.serverKey.hasPrefix("openbots_"))
        #expect(try await f.catalog().loadConnectorCatalog() == first)
        // JSON key order and descriptive notes do not alter launch identity.
        try f.write(["local": ["args": ["${CLAUDE_PLUGIN_ROOT}/server.js"], "command": "node", "note": "Untrusted commentary"],
                     "documentation": ["url": "https://docs.example.test/mcp", "type": "http"]], to: pluginRoot.appending(path: ".mcp.json"))
        #expect(try await f.catalog().loadConnectorCatalog() == first)
        try f.write(["local": ["command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/changed.js"]]], to: pluginRoot.appending(path: ".mcp.json"))
        let changed = try #require(try await f.catalog().loadConnectorCatalog().connectors.first)
        #expect(changed.definition.id == local.definition.id)
        #expect(changed.definition.identity.digest != local.definition.identity.digest)
    }

    @Test("Inline secrets, unresolved variables, unsafe URL forms and unknown launch fields are excluded")
    func credentialAndShapeRejection() async throws {
        let f = try Fixture(); defer { f.remove() }
        let unsafe: [[String: Any]] = [
            ["command": "node", "args": [], "env": ["SAFE_LOOKING_NAME": "fixture-secret"]],
            ["type": "http", "url": "https://example.test/mcp", "headers": ["Authorization": "fixture-secret"]],
            ["type": "http", "url": "https://user:fixture-secret@example.test/mcp"],
            ["type": "http", "url": "https://example.test/mcp?token=fixture-secret"],
            ["type": "http", "url": "https://example.test/mcp#fixture-secret"],
            ["type": "http", "url": "http://example.test/mcp"],
            ["type": "http", "url": "https://example.test/%73ecret"],
            ["command": "node", "args": ["${HOME}/server.js"]],
            ["command": "node", "args": ["$HOME/server.js"]],
            ["command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/../../outside.js"]],
            ["command": "node", "args": ["--token=fixture-secret"]],
            ["command": "sh", "args": ["-c", "do-something"]],
            ["command": "/outside/server", "args": []],
            ["type": "http", "url": "https://example.test/mcp", "headersHelper": "something"],
            ["type": "http", "url": "https://example.test/mcp", "oauth": [:]],
            ["command": "node", "args": "wrong shape"],
            ["type": "unsupported", "command": "node"]
        ]
        let definitions = Dictionary(uniqueKeysWithValues: unsafe.enumerated().map { ("unsafe\($0.offset)", $0.element) })
        try f.plugin("unsafe", servers: definitions)
        let loaded = try await f.catalog().loadConnectorCatalog()
        #expect(loaded.connectors.isEmpty)
        #expect(loaded.excludedCount == unsafe.count)
    }

    @Test("Inline manifest definitions and referenced MCP files share the same bounded import path")
    func manifestSources() async throws {
        let f = try Fixture(); defer { f.remove() }
        let first = try f.plugin("inline", servers: [:])
        try f.write(["mcpServers": ["browser": ["command": "npx", "args": ["a-package"]]]],
            to: first.appending(path: ".claude-plugin/plugin.json"))
        let second = try f.plugin("reference", servers: [:])
        try f.write(["mcpServers": "servers.json"], to: second.appending(path: ".claude-plugin/plugin.json"))
        try f.write(["mcpServers": ["docs": ["type": "http", "url": "https://example.test/mcp"]]],
            to: second.appending(path: "servers.json"))
        let loaded = try await f.catalog().loadConnectorCatalog()
        #expect(loaded.connectors.map { $0.definition.serverName }.sorted() == ["browser", "docs"])
        // Two definitions of the same server are ambiguous; neither wins.
        try f.write(["browser": ["command": "node", "args": ["different.js"]]], to: first.appending(path: ".mcp.json"))
        #expect(try await f.catalog().loadConnectorCatalog().connectors.map { $0.definition.serverName } == ["docs"])
    }

    @Test("Symlinks, traversal, writable metadata and external install roots cannot enter the catalog",
          arguments: ["symlink-file", "symlink-directory", "hardlink", "writable", "traversal", "external"])
    func untrustedPaths(_ mode: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let plugin = try f.plugin("unsafe", servers: ["server": ["command": "node", "args": []]])
        let config = plugin.appending(path: ".mcp.json")
        switch mode {
        case "symlink-file":
            let external = f.root.appending(path: "external.json")
            try FileManager.default.moveItem(at: config, to: external)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: external)
        case "symlink-directory":
            let external = f.root.appending(path: "external-plugin")
            try FileManager.default.moveItem(at: plugin, to: external)
            try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: external)
        case "hardlink":
            try FileManager.default.linkItem(at: config, to: f.root.appending(path: "second-link"))
        case "writable":
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: config.path)
        case "traversal":
            try f.write(["mcpServers": "../outside.json"], to: plugin.appending(path: ".claude-plugin/plugin.json"))
        default:
            try f.write(["plugins": ["unsafe@fixture": [["scope": "user", "installPath": f.root.path]]]],
                to: f.root.appending(path: "plugins/installed_plugins.json"))
        }
        let loaded = try await f.catalog().loadConnectorCatalog()
        #expect(loaded.connectors.isEmpty && loaded.excludedCount > 0)
    }

    @Test("Unknown, malformed and oversized registry data is not a usable catalog")
    func invalidRegistry() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.plugin("docs", servers: ["docs": ["type": "http", "url": "https://example.test/mcp"]])
        let path = f.root.appending(path: "plugins/installed_plugins.json")
        try Data("not json".utf8).write(to: path)
        await #expect(throws: ConnectorCatalogError.invalidConfiguration) { try await f.catalog().loadConnectorCatalog() }
        try Data(repeating: 65, count: 1_048_577).write(to: path)
        await #expect(throws: ConnectorCatalogError.invalidConfiguration) { try await f.catalog().loadConnectorCatalog() }
    }

    private final class Fixture {
        let root: URL
        private var enabled: [String: Bool] = [:]
        private var installed: [String: [[String: String]]] = [:]
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextConnectorCatalog-\(UUID()).noindex")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func catalog() -> ClaudePluginConnectorCatalog { .init(configurationDirectory: root) }
        @discardableResult
        func plugin(_ name: String, servers: [String: Any], enabled: Bool = true, scope: String = "user") throws -> URL {
            let path = root.appending(path: "plugins/cache/fixture/\(name)/version1")
            try write(servers, to: path.appending(path: ".mcp.json"))
            try write(["name": name], to: path.appending(path: ".claude-plugin/plugin.json"))
            self.enabled[name + "@fixture"] = enabled
            installed[name + "@fixture"] = [["scope": scope, "installPath": path.path]]
            try write(["enabledPlugins": self.enabled], to: root.appending(path: "settings.json"))
            try write(["version": 2, "plugins": installed], to: root.appending(path: "plugins/installed_plugins.json"))
            return path
        }
        func write(_ object: [String: Any], to path: URL) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: path)
        }
    }
}
