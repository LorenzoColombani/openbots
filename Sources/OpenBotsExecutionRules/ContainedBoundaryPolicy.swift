import Foundation

/// Foundation can shorten an existing physical /private/tmp path to /tmp.
/// Admit only that exact spelling change, retaining standardization and the
/// supplied physical path. This is not a filesystem or symlink authorization.
enum ProbePathSpelling {
    static func isCanonical(_ path: String, standardized: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        if path != "/" {
            let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        }
        if standardized == path { return true }
        return (path == "/private/tmp" || path.hasPrefix("/private/tmp/"))
            && standardized == String(path.dropFirst("/private".count))
    }
}

public enum ContainedBoundaryPolicyError: Error, Equatable, Sendable {
    case unsafePath(String)
    case invalidIdentity
    case modeNotAuthorized(ShellMode)
    case persistentResumeNeedsDifferentSession
    case invalidJSON
}

public enum ProbeSessionPersistence: Codable, Equatable, Hashable, Sendable {
    /// Most destructive and denial cases leave no resumable conversation.
    case ephemeral(sessionID: UUID)
    /// One isolated session is retained solely for the resume/isolation test.
    case persistentFresh(sessionID: UUID)
    /// Resume only an exact session UUID created by this probe.
    case persistentResume(sessionID: UUID)

    public var sessionID: UUID {
        switch self {
        case .ephemeral(let sessionID),
             .persistentFresh(let sessionID),
             .persistentResume(let sessionID):
            sessionID
        }
    }
}

public enum ProbeToolAuthorization: Codable, Equatable, Hashable, Sendable {
    case shellOff(teammateID: TeammateID, runID: RunID)
    case contained(ShellRunAuthorization)

    public var teammateID: TeammateID {
        switch self {
        case .shellOff(let teammateID, _): teammateID
        case .contained(let authorization): authorization.teammateID
        }
    }

    public var runID: RunID {
        switch self {
        case .shellOff(_, let runID): runID
        case .contained(let authorization): authorization.runID
        }
    }

    public var mode: ShellMode {
        switch self {
        case .shellOff: .off
        case .contained(let authorization): authorization.modeAtStart
        }
    }
}

/// Exact, inert paths for one bounded run. Construction performs lexical checks
/// only; a physical runner must revalidate ownership, modes, symlinks, file IDs,
/// and containment immediately before every effect.
public struct AgenticProbePaths: Codable, Equatable, Hashable, Sendable {
    public let root: URL
    public let workingDirectory: URL
    public let temporaryDirectory: URL
    public let settingsFile: URL
    public let mcpFile: URL
    public let configurationDirectory: URL
    public let homeDirectory: URL
    public let claudeExecutable: URL

    public init(
        root: URL,
        configurationDirectory: URL,
        homeDirectory: URL,
        claudeExecutable: URL
    ) throws {
        let root = try Self.requireAbsoluteCanonical(root, label: "probe root")
        let rootPath = Self.physicalTemporarySpelling(root.path)
        guard rootPath.hasPrefix("/private/tmp/"),
              root.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            throw ContainedBoundaryPolicyError.unsafePath(
                "probe root must be beneath /private/tmp and inside a .noindex boundary"
            )
        }

        let configurationDirectory = try Self.requireAbsoluteCanonical(
            configurationDirectory,
            label: "Claude configuration directory"
        )
        let homeDirectory = try Self.requireAbsoluteCanonical(homeDirectory, label: "home directory")
        let claudeExecutable = try Self.requireAbsoluteCanonical(
            claudeExecutable,
            label: "Claude executable"
        )

        self.root = root
        workingDirectory = root.appending(path: "work", directoryHint: .isDirectory)
        temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        settingsFile = root.appending(path: "settings.json")
        mcpFile = root.appending(path: "mcp.json")
        self.configurationDirectory = configurationDirectory
        self.homeDirectory = homeDirectory
        self.claudeExecutable = claudeExecutable
    }

    private static func requireAbsoluteCanonical(_ url: URL, label: String) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ContainedBoundaryPolicyError.unsafePath("\(label) must be an absolute file URL")
        }
        let standardized = url.standardizedFileURL
        guard ProbePathSpelling.isCanonical(url.path, standardized: standardized.path) else {
            throw ContainedBoundaryPolicyError.unsafePath("\(label) must already be lexically canonical")
        }
        return url
    }

    private static func physicalTemporarySpelling(_ path: String) -> String {
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }
}

public enum BoundaryEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case operatingSystemEnforced
    case claudePermissionEnforced
    case openBotsBrokerEnforced
    case advisoryOnly
    case requiresPhysicalEvidence
}

public struct BoundaryClaim: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let evidenceClass: BoundaryEvidenceClass
    public let statement: String

    public init(name: String, evidenceClass: BoundaryEvidenceClass, statement: String) {
        self.name = name
        self.evidenceClass = evidenceClass
        self.statement = statement
    }
}

public struct AgenticProbeLaunchPlan: Codable, Equatable, Sendable {
    public let authorization: ProbeToolAuthorization
    public let persistence: ProbeSessionPersistence
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryPath: String
    public let settingsFilePath: String
    public let settingsJSON: Data
    public let mcpFilePath: String
    public let mcpJSON: Data
    public let requiredExecutableSHA256: String
    public let requiredClaudeVersion: String
    public let claims: [BoundaryClaim]
}

/// Generates a no-effect launch receipt for the one approved candidate. It does
/// not create files, inspect credentials, invoke Claude, or spawn a process.
public enum ContainedBoundaryPolicy {
    public static let requiredClaudeVersion = "2.1.251"
    public static let requiredExecutableSHA256 =
        "625869b01e0050f260b2980fac248fd9cef9e462612bded4ec9d3d49ff8969a5"

    /// Values are denied again inside the Claude Bash sandbox even though the
    /// parent launch environment is allowlist-built and never inherits them.
    public static let deniedCredentialEnvironmentNames = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_PROFILE",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GITHUB_TOKEN",
        "GH_TOKEN",
        "NPM_TOKEN",
        "HOMEBREW_GITHUB_API_TOKEN",
        "SSH_AUTH_SOCK"
    ]

    public static func makePlan(
        paths: AgenticProbePaths,
        authorization: ProbeToolAuthorization,
        persistence: ProbeSessionPersistence,
        userName: String
    ) throws -> AgenticProbeLaunchPlan {
        guard !userName.isEmpty,
              userName.utf8.count <= 256,
              userName.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw ContainedBoundaryPolicyError.invalidIdentity
        }

        let tools: String
        switch authorization {
        case .shellOff:
            tools = ""
        case .contained(let runAuthorization):
            guard runAuthorization.modeAtStart == .contained else {
                throw ContainedBoundaryPolicyError.modeNotAuthorized(runAuthorization.modeAtStart)
            }
            tools = "Bash"
        }

        let settingsJSON = try makeSettingsJSON(paths: paths)
        let mcpJSON = try encodeSorted(EmptyMCPConfiguration())
        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--replay-user-messages",
            "--verbose",
            "--safe-mode",
            "--restricted",
            "--no-chrome",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", paths.mcpFile.path,
            "--settings", paths.settingsFile.path,
            "--setting-sources", "",
            "--permission-mode", "dontAsk",
            "--tools", tools,
            "--effort", "low"
        ]

        switch persistence {
        case .ephemeral(let sessionID):
            arguments.append(contentsOf: [
                "--session-id", sessionID.uuidString.lowercased(),
                "--no-session-persistence"
            ])
        case .persistentFresh(let sessionID):
            arguments.append(contentsOf: ["--session-id", sessionID.uuidString.lowercased()])
        case .persistentResume(let sessionID):
            arguments.append(contentsOf: ["--resume", sessionID.uuidString.lowercased()])
        }

        let environment = makeEnvironment(paths: paths, userName: userName)
        return AgenticProbeLaunchPlan(
            authorization: authorization,
            persistence: persistence,
            executablePath: paths.claudeExecutable.path,
            arguments: arguments,
            environment: environment,
            workingDirectoryPath: paths.workingDirectory.path,
            settingsFilePath: paths.settingsFile.path,
            settingsJSON: settingsJSON,
            mcpFilePath: paths.mcpFile.path,
            mcpJSON: mcpJSON,
            requiredExecutableSHA256: requiredExecutableSHA256,
            requiredClaudeVersion: requiredClaudeVersion,
            claims: claims
        )
    }

    private static var claims: [BoundaryClaim] {
        [
            BoundaryClaim(
                name: "Bash descendants only",
                evidenceClass: .requiresPhysicalEvidence,
                statement: "The requested Seatbelt boundary applies to Bash and its children, not to Claude's parent process or non-Bash tools."
            ),
            BoundaryClaim(
                name: "Settings source sealing",
                evidenceClass: .requiresPhysicalEvidence,
                statement: "Restricted and safe modes exclude personal/project customizations, but managed settings still load and must be shown not to widen the boundary."
            ),
            BoundaryClaim(
                name: "Consequential effects",
                evidenceClass: .openBotsBrokerEnforced,
                statement: "External or consequential effects require a frozen broker action and cannot be claimed as an operating-system guarantee."
            ),
            BoundaryClaim(
                name: "Model instructions",
                evidenceClass: .advisoryOnly,
                statement: "Prompts guide behavior but never establish authorization or containment."
            )
        ]
    }

    private static func makeEnvironment(
        paths: AgenticProbePaths,
        userName: String
    ) -> [String: String] {
        let executableDirectory = paths.claudeExecutable.deletingLastPathComponent().path
        let temporary = paths.temporaryDirectory.path
        return [
            "HOME": paths.homeDirectory.path,
            "USER": userName,
            "LOGNAME": userName,
            "LANG": "en_US.UTF-8",
            "PATH": [
                executableDirectory,
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                "/usr/local/bin",
                "/usr/local/sbin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin"
            ].joined(separator: ":"),
            "TMPDIR": temporary,
            "CLAUDE_CODE_TMPDIR": temporary,
            "CLAUDE_CONFIG_DIR": paths.configurationDirectory.path,
            "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_BUG_COMMAND": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_CRON": "1",
            "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK": "1",
            "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
            "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1",
            "MCP_DISCOVERY_CACHE": "0",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "NETRC": "/dev/null",
            "NPM_CONFIG_USERCONFIG": "/dev/null",
            "PIP_CONFIG_FILE": "/dev/null",
            "XDG_CONFIG_HOME": temporary + "/xdg-config",
            "XDG_CACHE_HOME": temporary + "/xdg-cache",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "NO_COLOR": "1"
        ]
    }

    private static func makeSettingsJSON(paths: AgenticProbePaths) throws -> Data {
        let credentials = deniedCredentialEnvironmentNames.map {
            CredentialEnvironmentRule(name: $0, mode: "deny")
        }
        let settings = CandidateSettings(
            schema: "https://json.schemastore.org/claude-code-settings.json",
            permissions: CandidatePermissions(
                allow: [],
                ask: [],
                deny: [
                    "Bash(dangerouslyDisableSandbox:true)",
                    "Read",
                    "Edit",
                    "Write",
                    "NotebookEdit",
                    "WebFetch",
                    "WebSearch",
                    "Agent",
                    "Skill",
                    "mcp__*"
                ],
                defaultMode: "dontAsk",
                disableBypassPermissionsMode: "disable",
                disableAutoMode: "disable",
                additionalDirectories: []
            ),
            sandbox: CandidateSandbox(
                enabled: true,
                autoAllowBashIfSandboxed: true,
                failIfUnavailable: true,
                allowUnsandboxedCommands: false,
                excludedCommands: [],
                allowAppleEvents: false,
                enableWeakerNetworkIsolation: false,
                enableWeakerNestedSandbox: false,
                filesystem: CandidateFilesystem(
                    disabled: false,
                    allowRead: [paths.workingDirectory.path, paths.temporaryDirectory.path],
                    allowWrite: [paths.workingDirectory.path, paths.temporaryDirectory.path],
                    denyRead: ["~/"],
                    denyWrite: ["~/"]
                ),
                network: CandidateNetwork(
                    allowedDomains: [],
                    deniedDomains: ["*"],
                    strictAllowlist: true,
                    allowUnixSockets: [],
                    allowAllUnixSockets: false
                ),
                credentials: CandidateCredentials(
                    files: [
                        "~/.ssh",
                        "~/.aws",
                        "~/.config/gcloud",
                        "~/.config/gh",
                        "~/.netrc",
                        "~/.npmrc",
                        "~/.docker",
                        "~/Library/Keychains"
                    ].map { CredentialFileRule(path: $0, mode: "deny") },
                    envVars: credentials
                )
            )
        )
        return try encodeSorted(settings)
    }

    private static func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            throw ContainedBoundaryPolicyError.invalidJSON
        }
        return data
    }
}

private struct EmptyMCPConfiguration: Codable {
    let mcpServers: [String: String]

    init(mcpServers: [String: String] = [:]) {
        self.mcpServers = mcpServers
    }
}

private struct CandidateSettings: Codable {
    let schema: String
    let permissions: CandidatePermissions
    let sandbox: CandidateSandbox

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case permissions
        case sandbox
    }
}

private struct CandidatePermissions: Codable {
    let allow: [String]
    let ask: [String]
    let deny: [String]
    let defaultMode: String
    let disableBypassPermissionsMode: String
    let disableAutoMode: String
    let additionalDirectories: [String]
}

private struct CandidateSandbox: Codable {
    let enabled: Bool
    let autoAllowBashIfSandboxed: Bool
    let failIfUnavailable: Bool
    let allowUnsandboxedCommands: Bool
    let excludedCommands: [String]
    let allowAppleEvents: Bool
    let enableWeakerNetworkIsolation: Bool
    let enableWeakerNestedSandbox: Bool
    let filesystem: CandidateFilesystem
    let network: CandidateNetwork
    let credentials: CandidateCredentials
}

private struct CandidateFilesystem: Codable {
    let disabled: Bool
    let allowRead: [String]
    let allowWrite: [String]
    let denyRead: [String]
    let denyWrite: [String]
}

private struct CandidateNetwork: Codable {
    let allowedDomains: [String]
    let deniedDomains: [String]
    let strictAllowlist: Bool
    let allowUnixSockets: [String]
    let allowAllUnixSockets: Bool
}

private struct CandidateCredentials: Codable {
    let files: [CredentialFileRule]
    let envVars: [CredentialEnvironmentRule]
}

private struct CredentialFileRule: Codable {
    let path: String
    let mode: String
}

private struct CredentialEnvironmentRule: Codable {
    let name: String
    let mode: String
}
