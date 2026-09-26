import Darwin
import Foundation

public enum ProbeFailure: Error, CustomStringConvertible, Equatable {
    case invalidArguments(String)
    case unsafePath(String)
    case processLaunch(String)
    case processTimeout(String)
    case invalidAuthenticationOutput
    case readinessRejected([String])
    case invalidStreamEvent
    case streamTimeout(String)
    case writeFailed(String)
    case unsafeConfiguration(String)

    public var description: String {
        switch self {
        case .invalidArguments(let detail): "invalid arguments: \(detail)"
        case .unsafePath(let detail): "unsafe path: \(detail)"
        case .processLaunch(let detail): "process launch failed: \(detail)"
        case .processTimeout(let detail): "process timed out: \(detail)"
        case .invalidAuthenticationOutput: "Claude auth status did not return the expected JSON shape"
        case .readinessRejected(let reasons): "readiness rejected: \(reasons.joined(separator: "; "))"
        case .invalidStreamEvent: "Claude emitted a non-JSON stream event"
        case .streamTimeout(let detail): "stream timed out: \(detail)"
        case .writeFailed(let detail): "bounded child input failed: \(detail)"
        case .unsafeConfiguration(let detail): "unsafe Claude configuration: \(detail)"
        }
    }
}

public struct AuthenticationStatus: Codable, Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String
    public let apiProvider: String?
    public let subscriptionType: String?

    public init(
        loggedIn: Bool,
        authMethod: String,
        apiProvider: String?,
        subscriptionType: String?
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.subscriptionType = subscriptionType
    }

    public var isAcceptedSubscription: Bool {
        guard loggedIn, authMethod.lowercased() == "claude.ai" else { return false }
        guard apiProvider?.lowercased() == "firstparty" else { return false }
        let normalizedSubscription = subscriptionType?.lowercased()
        return normalizedSubscription == "pro" || normalizedSubscription == "max"
    }
}

public struct FlagSupport: Codable, Equatable, Sendable {
    public let required: [String: Bool]

    public init(help: String) {
        let flags = [
            "--print",
            "--input-format",
            "--output-format",
            "--include-partial-messages",
            "--replay-user-messages",
            "--resume",
            "--strict-mcp-config",
            "--settings",
            "--setting-sources",
            "--allowed-tools",
            "--restricted",
            "--no-session-persistence"
        ]
        required = Dictionary(uniqueKeysWithValues: flags.map { ($0, help.contains($0)) })
    }

    public var missing: [String] {
        required.compactMap { $0.value ? nil : $0.key }.sorted()
    }
}

public struct ReadinessReport: Codable, Equatable, Sendable {
    public let executable: String
    public let version: String
    public let authentication: AuthenticationStatus
    public let flags: FlagSupport
    public let providerVariablesPresentInParent: [String]
    public let providerVariablesPresentInChild: [String]
    public let childEnvironmentKeys: [String]
    public let accepted: Bool
    public let rejectionReasons: [String]

    public init(
        executable: String,
        version: String,
        authentication: AuthenticationStatus,
        flags: FlagSupport,
        providerVariablesPresentInParent: [String],
        providerVariablesPresentInChild: [String],
        childEnvironmentKeys: [String]
    ) {
        var reasons: [String] = []
        if !authentication.isAcceptedSubscription {
            reasons.append("auth must be logged-in claude.ai with firstParty provider and Pro/Max subscription")
        }
        if !flags.missing.isEmpty {
            reasons.append("missing required flags: \(flags.missing.joined(separator: ", "))")
        }
        if !providerVariablesPresentInChild.isEmpty {
            reasons.append("provider/API variables reached the child: \(providerVariablesPresentInChild.joined(separator: ", "))")
        }

        self.executable = executable
        self.version = version
        self.authentication = authentication
        self.flags = flags
        self.providerVariablesPresentInParent = providerVariablesPresentInParent
        self.providerVariablesPresentInChild = providerVariablesPresentInChild
        self.childEnvironmentKeys = childEnvironmentKeys
        accepted = reasons.isEmpty
        rejectionReasons = reasons
    }
}

public enum ChildEnvironmentPolicy {
    /// Any one of these can replace, redirect, or otherwise alter the official
    /// Claude subscription route. Values are never logged by the probe.
    public static let prohibitedProviderVariables: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_BEDROCK_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_VERTEX_BASE_URL",
        "ANTHROPIC_VERTEX_PROJECT_ID",
        "ANTHROPIC_FOUNDRY_API_KEY",
        "ANTHROPIC_FOUNDRY_BASE_URL",
        "ANTHROPIC_FOUNDRY_RESOURCE",
        "ANTHROPIC_PROFILE",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION",
        "ANTHROPIC_WORKSPACE_ID",
        "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
        "CLAUDE_CODE_SKIP_VERTEX_AUTH",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_MANTLE",
        "CLAUDE_CODE_USE_VERTEX",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_PROFILE",
        "AWS_REGION",
        "CLOUD_ML_REGION",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy"
    ]

    public static func providerVariableNames(in environment: [String: String]) -> [String] {
        prohibitedProviderVariables.intersection(environment.keys).sorted()
    }

    public static func makeChildEnvironment(
        parent: [String: String],
        claudeExecutable: URL,
        temporaryDirectory: URL,
        configurationDirectory: URL
    ) throws -> [String: String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        let executableDirectory = claudeExecutable.deletingLastPathComponent().path

        var child: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": "\(executableDirectory):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory.path,
            "CLAUDE_CODE_TMPDIR": temporaryDirectory.path,
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_BUG_COMMAND": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_CRON": "1",
            "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
            "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1"
        ]

        for key in ["LANG", "LC_ALL", "LC_CTYPE", "TZ"] {
            if let value = parent[key], isSafeLocaleValue(value) {
                child[key] = value
            }
        }

        child["CLAUDE_CONFIG_DIR"] = configurationDirectory.path

        let contamination = providerVariableNames(in: child)
        guard contamination.isEmpty else {
            throw ProbeFailure.readinessRejected([
                "sanitized child environment retained prohibited keys: \(contamination.joined(separator: ", "))"
            ])
        }
        return child
    }

    private static func isSafeLocaleValue(_ value: String) -> Bool {
        guard value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7f
        }
    }
}

public enum ProbePathPolicy {
    public static func validateTemporaryNoIndexRoot(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        // Foundation may canonicalize macOS's `/private/tmp` as `/tmp` after
        // the path exists. Both names identify the same system temp volume.
        guard path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") else {
            throw ProbeFailure.unsafePath("probe roots must be beneath the macOS system temporary directory")
        }
        guard standardized.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            throw ProbeFailure.unsafePath("probe root must have a .noindex path component")
        }
        return standardized
    }
}

public struct ValidatedClaudeConfigurationDirectory: Sendable {
    public enum Kind: String, Sendable {
        case previewOwned
        case isolatedProbe
    }

    public let url: URL
    public let kind: Kind

    public var permitsLiveClaude: Bool { kind == .previewOwned }

    fileprivate init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

public enum ClaudeConfigurationPolicy {
    public static let previewBundleIdentifier = "com.lorenzocolombani.openbotsnext.preview"
    public static let markerFilename = ".openbots-claude-profile.json"

    private struct Marker: Codable, Equatable {
        let schemaVersion: Int
        let bundleIdentifier: String
        let role: String
    }

    public static func expectedPreviewDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProbeFailure.unsafeConfiguration("Application Support could not be resolved")
        }
        return applicationSupport
            .appending(path: previewBundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
            .appending(path: "Runtime/Claude/CLIProfile", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func validatePreviewDirectory(
        _ candidate: URL
    ) throws -> ValidatedClaudeConfigurationDirectory {
        let expected = try expectedPreviewDirectory()
        return try validate(
            candidate,
            expectedDirectory: expected,
            kind: .previewOwned,
            markerRole: "preview"
        )
    }

    public static func validateIsolatedProbeDirectory(
        _ candidate: URL,
        within probeRoot: URL
    ) throws -> ValidatedClaudeConfigurationDirectory {
        let expected = probeRoot
            .appending(path: "config", directoryHint: .isDirectory)
            .standardizedFileURL
        return try validate(
            candidate,
            expectedDirectory: expected,
            kind: .isolatedProbe,
            markerRole: "probe"
        )
    }

    public static func revalidate(
        _ directory: ValidatedClaudeConfigurationDirectory
    ) throws -> ValidatedClaudeConfigurationDirectory {
        switch directory.kind {
        case .previewOwned:
            return try validatePreviewDirectory(directory.url)
        case .isolatedProbe:
            return try validateIsolatedProbeDirectory(
                directory.url,
                within: directory.url.deletingLastPathComponent()
            )
        }
    }

    /// Creates only a disposable probe profile beneath an already validated
    /// `/private/tmp/*.noindex` root. The real preview profile is exclusively a
    /// StorageLayoutService responsibility and is never created here.
    public static func prepareIsolatedProbeDirectory(
        _ candidate: URL,
        within probeRoot: URL
    ) throws -> ValidatedClaudeConfigurationDirectory {
        let root = try ProbePathPolicy.validateTemporaryNoIndexRoot(probeRoot)
        let expected = root.appending(path: "config", directoryHint: .isDirectory).standardizedFileURL
        guard canonicalPath(candidate) == canonicalPath(expected) else {
            throw ProbeFailure.unsafeConfiguration(
                "isolated probe configuration must be the explicit config child of the probe root"
            )
        }

        try FileManager.default.createDirectory(
            at: expected,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: expected.path
        )
        let marker = Marker(
            schemaVersion: 1,
            bundleIdentifier: previewBundleIdentifier,
            role: "probe"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let markerURL = expected.appending(path: markerFilename)
        try encoder.encode(marker).write(to: markerURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
        return try validateIsolatedProbeDirectory(expected, within: root)
    }

    static func validate(
        _ candidate: URL,
        expectedDirectory: URL,
        kind: ValidatedClaudeConfigurationDirectory.Kind,
        markerRole: String
    ) throws -> ValidatedClaudeConfigurationDirectory {
        let standardized = candidate.standardizedFileURL
        let expected = expectedDirectory.standardizedFileURL
        guard candidate.path.hasPrefix("/"), canonicalPath(standardized) == canonicalPath(expected) else {
            throw ProbeFailure.unsafeConfiguration("path does not equal the required owned profile root")
        }
        guard standardized.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            throw ProbeFailure.unsafeConfiguration("profile must be beneath a .noindex boundary")
        }
        guard normalizedSystemTemporaryPath(standardized.resolvingSymlinksInPath().path)
                == normalizedSystemTemporaryPath(standardized.path) else {
            throw ProbeFailure.unsafeConfiguration("profile or an ancestor resolves through a symlink")
        }

        var directoryMetadata = stat()
        guard lstat(standardized.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o777 == 0o700 else {
            throw ProbeFailure.unsafeConfiguration(
                "profile must be an owned, nonsymlink directory with mode 0700"
            )
        }

        let markerURL = standardized.appending(path: markerFilename)
        var markerMetadata = stat()
        guard lstat(markerURL.path, &markerMetadata) == 0,
              markerMetadata.st_mode & S_IFMT == S_IFREG,
              markerMetadata.st_uid == geteuid(),
              markerMetadata.st_mode & 0o777 == 0o600,
              markerMetadata.st_size > 0,
              markerMetadata.st_size <= 4_096 else {
            throw ProbeFailure.unsafeConfiguration(
                "profile marker must be an owned, nonsymlink regular file with mode 0600"
            )
        }
        let expectedMarker = Marker(
            schemaVersion: 1,
            bundleIdentifier: previewBundleIdentifier,
            role: markerRole
        )
        guard let data = try? Data(contentsOf: markerURL, options: [.mappedIfSafe]),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker == expectedMarker else {
            throw ProbeFailure.unsafeConfiguration("profile marker identity does not match")
        }

        return ValidatedClaudeConfigurationDirectory(url: standardized, kind: kind)
    }

    private static func canonicalPath(_ url: URL) -> String {
        normalizedSystemTemporaryPath(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private static func normalizedSystemTemporaryPath(_ path: String) -> String {
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }
}
