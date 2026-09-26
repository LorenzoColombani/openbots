import Foundation

/// The selected-only MCP configuration a granted turn is launched with.
///
/// It goes to the CLI as a file rather than as an argument because it names an
/// absolute interpreter, an entry point and an environment, and an argument
/// vector is readable by anyone who can list processes. The file is created by
/// the same owned, descriptor-relative, single-link route as the system prompt,
/// at `0600`, and is removed when the turn's child is reaped.
///
/// `--strict-mcp-config` is passed with it, so this file is the complete set of
/// servers the turn can see: no account connector, no plugin server, nothing
/// inherited from a settings file. An ungranted turn keeps the shipped inline
/// `{"mcpServers":{}}` and writes no file at all.
public enum ClaudeTextConnectorConfigurationFile {
    /// Independent bound on the serialized file; the server count bound
    /// (`ClaudeTextConnectorAccess.maximumServerCount`) does not replace this
    /// byte bound.
    public static let maximumBytes = 64 * 1024

    /// How long Claude Code waits for one Apple Mail send or reply call before
    /// it tells the bot the call was never answered. Its default is 1e8 ms, about 27
    /// hours, so a sender that never answered left the bot waiting with nothing to say.
    /// The script's longest call is two `osascript` runs, each killed at 60 s, plus
    /// Node's own start.
    public static let mailSendCallLimitMilliseconds = 150_000

    /// Beside the system prompt, in the turn's own temporary directory, named
    /// by the run so two turns can never collide.
    public static func configurationURL(for request: ClaudeTextOnlyRequest) -> URL {
        request.target.temporaryDirectoryURL.appendingPathComponent(
            "openbots-connectors-\(request.runID.uuidString.lowercased()).json")
    }

    /// The configuration bytes for one selection, in one fixed order so the
    /// same selection always produces the same file.
    ///
    /// A server inherits the CLI's environment, and a work turn's CLI runs with
    /// TMPDIR in its shell's own folder, which the turn's commands can read
    /// (`ClaudeTextShellTemporaryDirectory`). So every server that names no
    /// temporary folder of its own is pinned to `temporaryDirectory`, the run's
    /// own: the Google server hands TMPDIR to its Keychain-backed sign-in helper.
    public static func configurationJSON(for access: ClaudeTextConnectorAccess,
                                         temporaryDirectory: URL? = nil) throws -> Data {
        var servers: [String: Any] = [:]
        for server in access.servers {
            var environment = server.environment
            if environment["TMPDIR"] == nil, let temporaryDirectory {
                environment["TMPDIR"] = temporaryDirectory.path
            }
            var entry: [String: Any] = [
                "type": "stdio",
                "command": server.executableURL.path,
                "args": server.arguments,
                "env": environment,
            ]
            // Claude Code 2.1.282 reads a per-server `timeout` in milliseconds.
            if server.role == .appleMailSend { entry["timeout"] = mailSendCallLimitMilliseconds }
            servers[server.name] = entry
        }
        return try JSONSerialization.data(withJSONObject: ["mcpServers": servers],
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
