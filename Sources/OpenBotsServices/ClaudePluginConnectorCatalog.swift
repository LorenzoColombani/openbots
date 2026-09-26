import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain

public enum ConnectorCatalogError: Error, Equatable, Sendable {
    case unavailable, unsafePath, invalidConfiguration
}

/// Transient launch material only. This type deliberately has no Codable
/// conformance and never enters the control database, diagnostics or UI.
public struct ConnectorLaunchConfiguration: Equatable, Sendable {
    public let serverKey: String
    public let transport: ConnectorTransport
    public let command: String?
    public let arguments: [String]
    public let url: URL?
    /// `package==version` for an app-owned row whose program is installed as a
    /// tool rather than shipped in the bundle. Nil for everything Claude Code
    /// configured, where the version travels in the command's own arguments.
    public let pinnedPackage: String?
    /// The chats the bot may read, on the app's Messages row only, and only on
    /// the copy the store hands a turn for one bot (`ConnectorAccessStore.
    /// configurations(for:)`); the catalog's own row never carries one. Nil on
    /// every other row.
    public let chatScope: AppleMessagesChatScope?
    public init(serverKey: String, transport: ConnectorTransport, command: String? = nil,
                arguments: [String] = [], url: URL? = nil, pinnedPackage: String? = nil,
                chatScope: AppleMessagesChatScope? = nil) {
        self.serverKey = serverKey; self.transport = transport; self.command = command
        self.arguments = arguments; self.url = url; self.pinnedPackage = pinnedPackage
        self.chatScope = chatScope
    }

    /// This launch for one bot whose Messages reads these chats.
    public func reading(_ chats: AppleMessagesChatScope) -> ConnectorLaunchConfiguration {
        .init(serverKey: serverKey, transport: transport, command: command, arguments: arguments, url: url,
              pinnedPackage: pinnedPackage, chatScope: chats)
    }
}

public struct ConfiguredConnector: Equatable, Sendable {
    public let definition: ConnectorDefinition
    public let launch: ConnectorLaunchConfiguration
    /// The row could not tell what it is bound to on this read — a helper that
    /// did not answer, a Keychain that would not open — so its identity is a
    /// guess, not a change. The store keeps the identity it already had for
    /// the row, and with it every grant. Launching is unaffected: a turn still
    /// asks the row's preparation, which refuses anything it cannot confirm.
    public let holdsPriorIdentity: Bool
    public init(definition: ConnectorDefinition, launch: ConnectorLaunchConfiguration,
                holdsPriorIdentity: Bool = false) {
        self.definition = definition; self.launch = launch; self.holdsPriorIdentity = holdsPriorIdentity
    }
}

public struct ConnectorCatalogSnapshot: Equatable, Sendable {
    public let connectors: [ConfiguredConnector]
    public let excludedCount: Int
    public init(connectors: [ConfiguredConnector] = [], excludedCount: Int = 0) {
        self.connectors = connectors; self.excludedCount = excludedCount
    }
}

public protocol ConnectorCatalogReading: Sendable {
    func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot
}

/// Reads configuration, never invokes Claude, a server, a package manager or
/// authentication. Account-hosted connectors are not this local inventory.
public struct ClaudePluginConnectorCatalog: ConnectorCatalogReading {
    private let configurationDirectory: URL
    private let ownerUID: uid_t

    public init(configurationDirectory: URL, ownerUID: uid_t = getuid()) {
        self.configurationDirectory = configurationDirectory; self.ownerUID = ownerUID
    }

    public func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        try Task.checkCancellation()
        let reader = try ConnectorCatalogFileReader(root: configurationDirectory, ownerUID: ownerUID)
        defer { reader.close() }
        guard let settingsData = try reader.read(["settings.json"]) else { return .init() }
        let settings = try Self.object(settingsData)
        guard let enabled = settings["enabledPlugins"] as? [String: Any], !enabled.isEmpty else { return .init() }
        guard enabled.count <= 1024,
              let indexData = try reader.read(["plugins", "installed_plugins.json"]),
              let installed = try Self.object(indexData)["plugins"] as? [String: Any], installed.count <= 2048
        else { throw ConnectorCatalogError.invalidConfiguration }
        var results: [String: ConfiguredConnector] = [:]
        var excluded = 0
        var duplicates: Set<String> = []
        for plugin in enabled.keys.sorted() {
            try Task.checkCancellation()
            guard let value = enabled[plugin] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else { continue }
            guard Self.pluginNameIsValid(plugin), let records = installed[plugin] as? [[String: Any]] else {
                excluded += 1; continue
            }
            let userRecords = records.filter { $0["scope"] as? String == "user" }
            guard !userRecords.isEmpty else { continue }
            guard userRecords.count == 1, let installPath = userRecords[0]["installPath"] as? String else {
                excluded += 1; continue
            }
            do {
                let components = try reader.pluginComponents(absolutePath: installPath)
                try reader.verifyDirectory(components)
                var sources: [[String: Any]] = []
                var files: [[String]] = [components + [".mcp.json"]]
                if let manifestData = try reader.read(components + [".claude-plugin", "plugin.json"]) {
                    let manifest = try Self.object(manifestData)
                    if let inline = manifest["mcpServers"] as? [String: Any] { sources.append(inline) }
                    else if let path = manifest["mcpServers"] as? String {
                        files.append(components + (try Self.relativeComponents(path)))
                    } else if let paths = manifest["mcpServers"] as? [String], paths.count <= 16 {
                        for path in paths { files.append(components + (try Self.relativeComponents(path))) }
                    } else if manifest["mcpServers"] != nil { throw ConnectorCatalogError.invalidConfiguration }
                }
                var seenFiles: Set<String> = []
                for path in files where seenFiles.insert(path.joined(separator: "/")).inserted {
                    guard let data = try reader.read(path) else { continue }
                    let object = try Self.object(data)
                    if let wrapped = object["mcpServers"] as? [String: Any] {
                        guard object.count == 1 else { throw ConnectorCatalogError.invalidConfiguration }
                        sources.append(wrapped)
                    } else { sources.append(object) }
                }
                for source in sources {
                    guard source.count <= ConnectorAccessState.maximumDefinitions else { throw ConnectorCatalogError.invalidConfiguration }
                    for name in source.keys.sorted() {
                        do {
                            let connector = try Self.parse(source[name], server: name, plugin: plugin, pluginRoot: installPath)
                            let id = connector.definition.id
                            if results[id] != nil || duplicates.contains(id) {
                                results[id] = nil; duplicates.insert(id); excluded += 1
                            } else { results[id] = connector }
                        } catch { excluded += 1 }
                    }
                }
            } catch { excluded += 1 }
        }
        guard results.count <= ConnectorAccessState.maximumDefinitions else { throw ConnectorCatalogError.invalidConfiguration }
        return ConnectorCatalogSnapshot(connectors: results.values.sorted { $0.definition.id < $1.definition.id }, excludedCount: excluded)
    }

    private static func parse(_ value: Any?, server: String, plugin: String, pluginRoot: String) throws -> ConfiguredConnector {
        guard nameIsValid(server), let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["type", "command", "args", "url", "env", "headers", "note"])
        else { throw ConnectorCatalogError.invalidConfiguration }
        // Even apparently harmless values in these fields could be credentials.
        // This first importer accepts no inline environment or header payload.
        for key in ["env", "headers"] where object[key] != nil {
            guard let entries = object[key] as? [String: Any], entries.isEmpty else { throw ConnectorCatalogError.invalidConfiguration }
        }
        if let note = object["note"], !(note is String) { throw ConnectorCatalogError.invalidConfiguration }
        let type = object["type"] as? String ?? (object["command"] != nil ? "stdio" : "")
        guard let transport = ConnectorTransport(rawValue: type), object["type"] == nil || object["type"] is String else {
            throw ConnectorCatalogError.invalidConfiguration
        }
        let id = "claude-plugin:\(plugin):\(server)"
        let serverKey = "openbots_" + hash(Data(id.utf8))
        let launch: ConnectorLaunchConfiguration
        var canonical: [String: Any] = ["namespace": id, "pluginRoot": pluginRoot, "type": type]
        switch transport {
        case .stdio:
            guard let rawCommand = object["command"] as? String, object["url"] == nil,
                  object["args"] == nil || object["args"] is [String] else { throw ConnectorCatalogError.invalidConfiguration }
            let command = try expand(rawCommand, pluginRoot: pluginRoot)
            let arguments = try (object["args"] as? [String] ?? []).map { try expand($0, pluginRoot: pluginRoot) }
            guard arguments.count <= 64, !command.contains(where: \.isWhitespace),
                  (Set(["npx", "node", "bun", "uv", "uvx", "python3", "deno"]).contains(command)
                   || command.hasPrefix(pluginRoot + "/")),
                  !command.split(separator: "/").contains("..") else { throw ConnectorCatalogError.unsafePath }
            for argument in arguments {
                if argument.contains("://") {
                    // An embedded URL argument must itself be a plain URL;
                    // query parameters and opaque credential forms are refused.
                    _ = try credentialFreeURL(argument)
                }
            }
            canonical["command"] = command; canonical["args"] = arguments
            launch = .init(serverKey: serverKey, transport: transport, command: command, arguments: arguments)
        case .http, .sse:
            guard object["command"] == nil, object["args"] == nil,
                  let rawURL = object["url"] as? String else { throw ConnectorCatalogError.invalidConfiguration }
            let url = try credentialFreeURL(try expand(rawURL, pluginRoot: pluginRoot))
            canonical["url"] = url.absoluteString
            launch = .init(serverKey: serverKey, transport: transport, url: url)
        }
        let digest = hash(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys, .withoutEscapingSlashes]))
        return ConfiguredConnector(definition: .init(identity: try ConnectorIdentity(id: id, digest: digest),
            serverName: server, pluginName: plugin, transport: transport), launch: launch)
    }

    private static func expand(_ value: String, pluginRoot: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw ConnectorCatalogError.invalidConfiguration
        }
        let result = value.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot)
        guard !result.contains("$"), !result.contains("`"),
              result.range(of: "(?i)(authorization|bearer|password|secret|credential|api[-_]?key|access[-_]?token|refresh[-_]?token|--token|cookie|sk-[a-zA-Z0-9]|ghp_|github_pat_)", options: .regularExpression) == nil
        else { throw ConnectorCatalogError.invalidConfiguration }
        if value.contains("${CLAUDE_PLUGIN_ROOT}") {
            guard result == pluginRoot || result.hasPrefix(pluginRoot + "/"), !result.split(separator: "/").contains("..") else {
                throw ConnectorCatalogError.unsafePath
            }
        }
        return result
    }

    private static func credentialFreeURL(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url, !parts.percentEncodedPath.lowercased().contains("%") else {
            throw ConnectorCatalogError.invalidConfiguration
        }
        return url
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConnectorCatalogError.invalidConfiguration
            }
            return value
        } catch { throw ConnectorCatalogError.invalidConfiguration }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func nameIsValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
    private static func pluginNameIsValid(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { nameIsValid(String($0)) }
    }
    private static func relativeComponents(_ value: String) throws -> [String] {
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else { throw ConnectorCatalogError.unsafePath }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else { throw ConnectorCatalogError.unsafePath }
        return parts
    }
}

/// Descriptor-relative, no-follow reads: a replaced ancestor or symlink never
/// turns the metadata importer into a reader of arbitrary files or credentials.
private struct ConnectorCatalogFileReader {
    private enum PathError: Error { case missing }
    let root: URL
    let ownerUID: uid_t
    let descriptor: Int32
    init(root: URL, ownerUID: uid_t) throws {
        // Foundation rewrites an existing /private/tmp directory to /tmp when
        // standardizing it. Validate lexical components, then walk the actual
        // supplied path with O_NOFOLLOW instead of trusting that rewrite.
        guard root.isFileURL, root.host == nil || root.host == "", root.query == nil, root.fragment == nil,
              root.path.hasPrefix("/"), !root.pathComponents.contains(".."), !root.pathComponents.contains("."),
              !root.absoluteString.lowercased().contains("%00"), !root.path.contains("\0") else { throw ConnectorCatalogError.unsafePath }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ConnectorCatalogError.unavailable }
        for part in root.path.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            Darwin.close(fd)
            guard next >= 0 else { throw ConnectorCatalogError.unsafePath }
            fd = next
        }
        self.root = root; self.ownerUID = ownerUID; descriptor = fd
        do { try verify(fd, directory: true) } catch { Darwin.close(fd); throw error }
    }
    func close() { Darwin.close(descriptor) }
    func pluginComponents(absolutePath: String) throws -> [String] {
        let prefix = root.path + "/plugins/cache/"
        guard absolutePath.hasPrefix(prefix), !absolutePath.contains("\\"), !absolutePath.contains("\0") else {
            throw ConnectorCatalogError.unsafePath
        }
        let parts = absolutePath.dropFirst(root.path.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ConnectorCatalogError.unsafePath
        }
        return parts
    }
    func verifyDirectory(_ components: [String]) throws {
        let fd = try directory(components)
        Darwin.close(fd)
    }
    private func directory(_ components: [String]) throws -> Int32 {
        var fd = dup(descriptor)
        guard fd >= 0 else { throw ConnectorCatalogError.unavailable }
        do {
            for part in components {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT { throw PathError.missing }
                guard next >= 0 else { throw ConnectorCatalogError.unsafePath }
                Darwin.close(fd); fd = next
                try verify(fd, directory: true)
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func read(_ components: [String]) throws -> Data? {
        guard let name = components.last else { throw ConnectorCatalogError.unsafePath }
        let parent: Int32
        do { parent = try directory(Array(components.dropLast())) }
        catch PathError.missing { return nil }
        defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ConnectorCatalogError.unsafePath }
        defer { Darwin.close(fd) }
        try verify(fd, directory: false)
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= 1_048_576 else { throw ConnectorCatalogError.invalidConfiguration }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ConnectorCatalogError.unavailable }
            offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw ConnectorCatalogError.unavailable }
        return Data(bytes)
    }
    private func verify(_ fd: Int32, directory: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == ownerUID, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else {
            throw ConnectorCatalogError.unsafePath
        }
    }
}
