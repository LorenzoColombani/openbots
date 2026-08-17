import Foundation

/// Absolute paths for the runtimes MCP servers are launched with.
///
/// A bundled .app inherits NO shell PATH (the same reason
/// `SessionRunner.claudeCandidates` exists). Homebrew's `node`/`npx` live in
/// `/opt/homebrew/bin` and `uvx` in `~/.local/bin` — neither is on a GUI
/// app's PATH — so an mcp.json saying `"command": "node"` spawned fine from
/// Terminal and failed silently from Agency.app. The agent then reported
/// "the tools disconnected from the MCP server" (live 2026-08-13), which is
/// exactly what a server that never started looks like from inside.
public enum Executables {
    /// Where each runtime actually lives on a Mac, in priority order.
    static let candidates: [String: [String]] = [
        "node":    ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"],
        "npx":     ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"],
        "npm":     ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"],
        "uvx":     ["\(NSHomeDirectory())/.local/bin/uvx", "/opt/homebrew/bin/uvx", "/usr/local/bin/uvx"],
        "uv":      ["\(NSHomeDirectory())/.local/bin/uv", "/opt/homebrew/bin/uv"],
        "python3": ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"],
        "bun":     ["/opt/homebrew/bin/bun", "\(NSHomeDirectory())/.bun/bin/bun"],
        "deno":    ["/opt/homebrew/bin/deno", "\(NSHomeDirectory())/.deno/bin/deno"],
    ]

    /// An absolute path for `command`, or the command unchanged when it is
    /// already absolute or genuinely unknown (better a clear "not found" than
    /// a wrong guess).
    public static func resolve(_ command: String) -> String {
        guard !command.hasPrefix("/") else { return command }
        guard let paths = candidates[command] else { return command }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? command
    }

    /// PATH for spawned servers: many tools shell out to their own siblings
    /// (npx → node, uvx → python), so resolving the entry point is not enough.
    public static var searchPath: String {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                    "\(NSHomeDirectory())/.local/bin"]
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            dirs += inherited.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}
