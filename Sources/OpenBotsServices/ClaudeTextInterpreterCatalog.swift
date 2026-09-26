import Foundation

/// Interpreters the Mac already has that a Work-on-this-Mac bot may run
/// code with. Discovery only — never installs anything.
public struct ClaudeTextInterpreter: Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let kind: Kind
    public var id: String { path }

    public enum Kind: String, Sendable {
        case python
        case uv
        case node
        case ruby
        case swift
        case shell
    }

    public init(name: String, path: String, kind: Kind) {
        self.name = name
        self.path = path
        self.kind = kind
    }
}

public enum ClaudeTextInterpreterCatalog: Sendable {
    /// Ordered for Details: Python first, then the rest in a fixed order.
    public static func resolve(fileManager: FileManager = .default,
                               pathEnvironment: String? = nil) -> [ClaudeTextInterpreter] {
        var found: [ClaudeTextInterpreter] = []
        var seen = Set<String>()

        func add(_ name: String, _ path: String, _ kind: ClaudeTextInterpreter.Kind) {
            let resolved = (path as NSString).standardizingPath
            guard fileManager.isExecutableFile(atPath: resolved), !seen.contains(resolved) else { return }
            seen.insert(resolved)
            found.append(ClaudeTextInterpreter(name: name, path: resolved, kind: kind))
        }

        // Fixed locations first, then PATH lookups.
        add("Python 3", "/usr/bin/python3", .python)
        for brew in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            add("Homebrew Python 3", brew, .python)
        }
        for uv in ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"] {
            add("uv", uv, .uv)
        }
        for node in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            add("Node.js", node, .node)
        }
        for ruby in ["/usr/bin/ruby", "/opt/homebrew/bin/ruby", "/usr/local/bin/ruby"] {
            add("Ruby", ruby, .ruby)
        }
        for swift in ["/usr/bin/swift", "/opt/homebrew/bin/swift"] {
            add("Swift", swift, .swift)
        }

        let pathDirs = (pathEnvironment ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let pathLookups: [(String, String, ClaudeTextInterpreter.Kind)] = [
            ("python3", "Python 3", .python),
            ("python", "Python", .python),
            ("uv", "uv", .uv),
            ("node", "Node.js", .node),
            ("ruby", "Ruby", .ruby),
            ("swift", "Swift", .swift),
        ]
        for dir in pathDirs {
            for (binary, label, kind) in pathLookups {
                add(label, (dir as NSString).appendingPathComponent(binary), kind)
            }
        }
        return found
    }

    /// Whether an interpreter binary (name or absolute path) is available.
    public static func hasInterpreter(namedOrPath token: String,
                                      fileManager: FileManager = .default,
                                      pathEnvironment: String? = nil) -> Bool {
        if token.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: (token as NSString).standardizingPath)
        }
        return resolve(fileManager: fileManager, pathEnvironment: pathEnvironment)
            .contains { $0.path.hasSuffix("/\(token)") || URL(fileURLWithPath: $0.path).lastPathComponent == token }
    }

    /// Plain-language install suggestion when an interpreter is missing.
    /// Names the install; never runs it.
    public static func namedInstallSuggestion(forInterpreter token: String) -> (title: String, detail: String) {
        let base = URL(fileURLWithPath: token).lastPathComponent.lowercased()
        switch base {
        case "python", "python3":
            return ("Install Python 3",
                    "This Mac has no Python 3 the app can use. Install it with Homebrew (`brew install python`), then try again. OpenBots will not install it for you.")
        case "node", "nodejs":
            return ("Install Node.js",
                    "This Mac has no Node.js the app can use. Install it with Homebrew (`brew install node`), then try again. OpenBots will not install it for you.")
        case "ruby":
            return ("Install Ruby",
                    "This Mac has no Ruby the app can use. Install it with Homebrew (`brew install ruby`), then try again. OpenBots will not install it for you.")
        case "swift":
            return ("Install Swift",
                    "This Mac has no Swift toolchain the app can use. Install Xcode or the Swift toolchain, then try again. OpenBots will not install it for you.")
        case "uv":
            return ("Install uv",
                    "This Mac has no `uv` the app can use. Install it with Homebrew (`brew install uv`), then try again. OpenBots will not install it for you.")
        default:
            return ("Install \(base)",
                    "This Mac does not have `\(base)` available. Install it yourself (for example with Homebrew), then try again. OpenBots will not install it for you.")
        }
    }
}
