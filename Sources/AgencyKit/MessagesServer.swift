import Foundation

/// Agency's own Apple Messages MCP server (`Resources/mcp/messages-server.js`).
///
/// WHY IT EXISTS — his report 2026-08-13: "my iMessage connector can't
/// differentiate between iMessage and RCS or texts and sends iMessages by
/// default, which fails for Android users". Anthropic's Desktop extension
/// hardcodes `service type = iMessage` in its send script, so every message
/// goes out as iMessage whatever the recipient actually uses.
///
/// It runs on `node` on purpose rather than as a Swift executable: the very
/// same interpreter the Desktop extension already uses, launched the same way,
/// so it inherits the Automation→Messages and Full-Disk-Access grants that are
/// already working instead of appearing to macOS as a NEW client that needs its
/// own TCC prompts (this project has lost enough time to permission churn).
public enum MessagesServer {
    public static let scriptName = "messages-server.js"

    /// Where the script is, checked in the order that makes the shipped app
    /// self-contained first and the source checkout a fallback:
    ///  1. the running .app's Resources (Agency.app/Contents/Resources/mcp)
    ///  2. next to the executable, walking up to a `Resources/mcp` sibling
    ///     (covers `.build/debug/agency-cli` and `.build/release/`)
    ///  3. this source file's own repo (keeps `swift test` cwd-independent)
    ///  4. the agency root passed in
    /// Returns nil when none exists, which the caller reports rather than
    /// wiring a server that cannot start.
    public static func scriptPath(root: URL? = nil) -> String? {
        scriptPath(named: scriptName, root: root)
    }

    /// Same lookup for ANY of agency's bundled MCP servers (the Apple-Mail
    /// sender joined 2026-08-13 — one resolver, not one per script).
    public static func scriptPath(named name: String, root: URL? = nil) -> String? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("mcp/\(name)"))
        }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<5 {
                candidates.append(dir.appendingPathComponent("Resources/mcp/\(name)"))
                dir = dir.deletingLastPathComponent()
            }
        }
        // #filePath → Sources/AgencyKit/MessagesServer.swift → repo root.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(sourceRoot.appendingPathComponent("Resources/mcp/\(name)"))
        if let root {
            candidates.append(root.appendingPathComponent("Resources/mcp/\(name)"))
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }?.path
    }

    /// The server entry for an agent's mcp.json. `{MESSAGES_SERVER}` is
    /// resolved at generation time, like the other connector tokens.
    public static var serverConfig: [String: Any] {
        ["command": "node", "args": [Connector.messagesServerToken]]
    }

    /// Tool names on Anthropic's iMessage extension that agency SUPERSEDES —
    /// everything that touches the Messages database or sends, which is all of
    /// it except contact lookup. Two independent defects, both measured
    /// against a real Messages database:
    ///  - its sender hardcodes `service type = iMessage`, so Android recipients
    ///    get nothing and no error is raised (his report);
    ///  - its readers fall back to `hex(m.attributedBody)`, and ~90% of rows on
    ///    a real install have a NULL `text` column, so most of what it reads
    ///    back is a hex dump of an archived attributed string, not the message.
    /// Contact lookup goes through the Contacts app, not chat.db, and works —
    /// so that one stays with the first-party extension.
    ///
    /// Derived from the manifest's own tool list rather than hardcoded, so a
    /// renamed or newly added tool is covered by default (fail closed: an
    /// unknown tool is superseded, not silently trusted).
    public static func supersededTools(inManifestTools tools: [[String: Any]]) -> [String] {
        let derived = tools.compactMap { $0["name"] as? String }
            .filter { !$0.lowercased().contains("contact") }
        // FLOOR (review finding I-3): `tools` is optional in the manifest spec,
        // so an extension update that drops or renames it would leave `derived`
        // empty — and the caller's "don't narrow when nothing survives" guard
        // would then restore whole-server approval, silently re-admitting the
        // iMessage-only sender this whole file exists to replace. The names we
        // KNOW are broken are denied whatever the manifest says.
        let floor = ["send_imessage", "read_imessages", "get_unread_imessages"]
        return derived + floor.filter { !derived.contains($0) }
    }
}
