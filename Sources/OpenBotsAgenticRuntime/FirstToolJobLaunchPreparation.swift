import OpenBotsExecutionRules
import Foundation
import OpenBotsContent
import OpenBotsSecurity

public enum FirstToolJobProcessRole: String, CaseIterable, Sendable {
    case conversation, worker
}

public enum FirstToolJobLaunchPreparationError: Error, Equatable, Sendable {
    case invalidPaths, installationMismatch, profileMismatch, invalidLimits, invalidModel
}

/// Request count and wall/startup/write deadlines must be enforced by the host.
/// Claude's --max-turns applies separately to each queued stream input.
public struct FirstToolJobLaunchLimits: Equatable, Sendable {
    public let maximumRequests: Int
    public let maximumTurnsPerRequest: Int
    public let maximumWallTimeSeconds: TimeInterval
    public let startupTimeoutSeconds: TimeInterval
    public let writeTimeoutSeconds: TimeInterval
    /// Total time the worker may spend waiting for the user's decisions. The
    /// wall budget covers working time; review time is bounded separately.
    public let maximumReviewSeconds: TimeInterval
    public let maximumToolRequests = 32

    public init(maximumRequests: Int = 4, maximumTurnsPerRequest: Int = 8,
                maximumWallTimeSeconds: TimeInterval = 180, startupTimeoutSeconds: TimeInterval = 20,
                writeTimeoutSeconds: TimeInterval = 1, maximumReviewSeconds: TimeInterval = 600) {
        self.maximumReviewSeconds = maximumReviewSeconds
        self.maximumRequests = maximumRequests
        self.maximumTurnsPerRequest = maximumTurnsPerRequest
        self.maximumWallTimeSeconds = maximumWallTimeSeconds
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.writeTimeoutSeconds = writeTimeoutSeconds
    }

    public static let firstJob = FirstToolJobLaunchLimits()
}

/// Immutable preparation data. This is neither live admission nor permission to
/// write the configuration files or launch. At-action installation/profile/path
/// revalidation, subscription admission, effective managed-settings inspection,
/// sandbox/IPC verification and explicit run approval remain separate gates.
/// The runtime must own a distinct process group for every conversation/worker.
public struct FirstToolJobLaunchPlan: Equatable, Sendable {
    public let admission: FirstToolJobAdmissionReceipt
    public let paths: AgenticProbePaths
    public let role: FirstToolJobProcessRole
    public let teammateID: TeammateID
    public let runID: RunID
    public let sessionID: UUID
    public let model: String
    public let arguments: [String]
    public let environment: [String: String]
    public let settingsJSON: Data
    public let settingsSHA256: String
    public let mcpJSON: Data
    public let mcpSHA256: String
    public let limits: FirstToolJobLaunchLimits
    /// Web capabilities granted at admission. The conversation role never has
    /// any; every tool-bearing launch input below is derived from this set.
    public let webCapabilities: Set<AgenticWebCapability>

    /// The exact tool list this process was launched with, in launch order.
    public var tools: [String] {
        role == .worker ? ["Bash"] + AgenticWebCapability.toolNames(webCapabilities) : []
    }
    public var executablePath: String { admission.installation.resolvedPath }
    public var requiredExecutableSHA256: String { admission.installation.sha256 }
    public var requiredExecutableFileIdentity: ClaudeInstallationFileIdentity { admission.installation.fileIdentity }
    public var requiredExecutableSignature: ClaudeStaticSignatureIdentity { admission.installation.signature }
    public var workingDirectoryPath: String { paths.workingDirectory.path }
    public var settingsFilePath: String { paths.settingsFile.path }
    public var mcpFilePath: String { paths.mcpFile.path }
    public var launchReady: Bool { false }
    public var containmentVerified: Bool { false }
    public var subscriptionVerified: Bool { false }
}

/// Current-installation preparation, without the obsolete pinned readiness
/// probe. No filesystem, environment, credential or process reads occur here.
/// Settings/flags are documented at code.claude.com/docs/en/settings-reference,
/// /sandboxing and /cli-reference; compatibility still needs live evidence.
public enum FirstToolJobLaunchPreparation {
    public static func makePlan(admission: FirstToolJobAdmissionReceipt, paths: AgenticProbePaths,
                                role: FirstToolJobProcessRole, teammateID: TeammateID, runID: RunID,
                                sessionID: UUID, model: String = "sonnet",
                                limits: FirstToolJobLaunchLimits = .firstJob,
                                webCapabilities: Set<AgenticWebCapability> = []) throws -> FirstToolJobLaunchPlan {
        try validate(paths: paths, admission: admission)
        guard ["sonnet", "haiku", "opus"].contains(model) else { throw FirstToolJobLaunchPreparationError.invalidModel }
        guard (1...8).contains(limits.maximumRequests), (1...16).contains(limits.maximumTurnsPerRequest),
              limits.maximumRequests * limits.maximumTurnsPerRequest <= 64,
              limits.maximumWallTimeSeconds.isFinite, (1...300).contains(limits.maximumWallTimeSeconds),
              limits.startupTimeoutSeconds.isFinite, (0.1...30).contains(limits.startupTimeoutSeconds),
              limits.startupTimeoutSeconds <= limits.maximumWallTimeSeconds,
              limits.writeTimeoutSeconds.isFinite, (0.1...5).contains(limits.writeTimeoutSeconds),
              limits.writeTimeoutSeconds <= limits.maximumWallTimeSeconds else {
            throw FirstToolJobLaunchPreparationError.invalidLimits
        }
        // Only a worker carries tools. Each granted web tool is asked (so the
        // host decides every use) and removed from the deny list; the rest of
        // the deny list is unchanged. Nothing is granted the conversation.
        let granted = role == .worker ? webCapabilities : []
        let webTools = AgenticWebCapability.toolNames(granted)
        let tools = role == .worker ? ["Bash"] + webTools : []
        let settings = try settingsJSON(paths: paths, webTools: webTools)
        let mcp = Data("{\"mcpServers\":{}}".utf8)
        var arguments = [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--replay-user-messages", "--verbose", "--safe-mode", "--restricted", "--no-chrome",
            "--disable-slash-commands", "--strict-mcp-config", "--mcp-config", paths.mcpFile.path,
            "--settings", paths.settingsFile.path, "--setting-sources", "", "--permission-mode", "default",
            "--tools", tools.joined(separator: ","), "--disallowedTools", "mcp__*,EndConversation",
            "--session-id", sessionID.uuidString.lowercased(), "--no-session-persistence",
            "--max-turns", String(limits.maximumTurnsPerRequest), "--model", model
        ]
        if role == .worker { arguments.append(contentsOf: ["--permission-prompt-tool", "stdio"]) }
        else { arguments.append(contentsOf: ["--permission-prompts", "none"]) }
        return FirstToolJobLaunchPlan(admission: admission, paths: paths, role: role, teammateID: teammateID,
            runID: runID, sessionID: sessionID, model: model, arguments: arguments, environment: environment(paths: paths),
            settingsJSON: settings, settingsSHA256: PayloadDigest.sha256(of: settings).rawValue,
            mcpJSON: mcp, mcpSHA256: PayloadDigest.sha256(of: mcp).rawValue, limits: limits, webCapabilities: granted)
    }

    private static func validate(paths: AgenticProbePaths, admission: FirstToolJobAdmissionReceipt) throws {
        // Codable paths can bypass their validating initializer. Reconstruct all
        // derived members, then reject glob/control characters in policy paths.
        guard let reconstructed = try? AgenticProbePaths(root: paths.root,
            configurationDirectory: paths.configurationDirectory, homeDirectory: paths.homeDirectory,
            claudeExecutable: paths.claudeExecutable), reconstructed == paths,
              [paths.root, paths.homeDirectory, paths.configurationDirectory, paths.claudeExecutable].allSatisfy({
                  $0.path.utf8.count <= 4_096 && !$0.path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) || "*?[]".unicodeScalars.contains($0)
                  })
              }), !overlap(paths.root.path, paths.homeDirectory.path),
              !overlap(paths.root.path, paths.configurationDirectory.path),
              !overlap(paths.root.path, paths.claudeExecutable.path) else {
            throw FirstToolJobLaunchPreparationError.invalidPaths
        }
        let installation = admission.installation
        let expectedRequested = paths.homeDirectory.appending(path: ".local/bin/claude").path
        let versions = paths.homeDirectory.appending(path: ".local/share/claude/versions")
        let filename = installation.versionFilename
        guard exact(installation.requestedPath, expectedRequested), !filename.isEmpty, filename.utf8.count <= 255,
              filename != ".", filename != "..", !filename.contains("/"),
              exact(installation.resolvedPath, paths.claudeExecutable.path),
              exact(installation.resolvedPath, versions.appending(path: filename).path),
              hex(installation.sha256, count: 64),
              installation.signature.identifier == ClaudeInstallationInspector.expectedIdentifier,
              installation.signature.teamIdentifier == ClaudeInstallationInspector.expectedTeamIdentifier,
              installation.signature.codeDirectoryHash.map({ hex($0, count: 40) }) == true,
              installation.fileIdentity.inode > 0, installation.fileIdentity.byteCount >= 4,
              installation.fileIdentity.byteCount <= ClaudeInstallationInspector.maximumExecutableBytes,
              admission.checkedAt.timeIntervalSince1970.isFinite else {
            throw FirstToolJobLaunchPreparationError.installationMismatch
        }
        let layout = PreviewStorageLayout(homeDirectory: paths.homeDirectory,
            systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp"))
        let profile = admission.profile
        guard exact(profile.applicationSupportPath, layout.applicationSupportRoot.url.path),
              exact(profile.profilePath, layout.claudeCLIProfileRoot.path),
              exact(profile.profilePath, paths.configurationDirectory.path),
              exact(profile.markerPath, layout.claudeCLIProfileRoot.appending(path: ClaudeProfileInspector.markerFilename).path),
              profile.bundleIdentifier == OpenBotsPreviewIdentity.bundleIdentifier,
              profile.markerSchemaVersion == 1, profile.role == "preview" else {
            throw FirstToolJobLaunchPreparationError.profileMismatch
        }
    }

    static func settingsJSON(paths: AgenticProbePaths, webTools: [String]) throws -> Data {
        let deniedTools = ["Read", "Edit", "Write", "Glob", "Grep", "LSP", "NotebookEdit", "WebFetch", "WebSearch",
                           "Agent", "Skill", "mcp__*", "EndConversation"].filter { !webTools.contains($0) }
        // The parts are typed one by one: as one nested literal the whole object
        // took Swift 6.1's type checker past its time limit.
        let permissions: [String: Any] = [
            "allow": [String](), "ask": ["Bash"] + webTools,
            "deny": ["Bash(dangerouslyDisableSandbox:true)"] + deniedTools,
            "defaultMode": "default", "disableBypassPermissionsMode": "disable",
            "blockReadsOutsideWorkingDirectories": true, "additionalDirectories": [String]()
        ]
        let filesystem: [String: Any] = [
            "disabled": false, "denyRead": ["/"],
            "allowRead": [paths.workingDirectory.path, paths.temporaryDirectory.path,
                "/bin", "/sbin", "/usr", "/System", "/dev"],
            "allowWrite": [paths.workingDirectory.path, paths.temporaryDirectory.path],
            "denyWrite": [paths.homeDirectory.path, paths.settingsFile.path, paths.mcpFile.path]
        ]
        let network: [String: Any] = [
            "allowedDomains": [String](), "deniedDomains": ["*"], "strictAllowlist": true,
            "allowUnixSockets": [String](), "allowAllUnixSockets": false, "allowLocalBinding": false
        ]
        let credentialFiles: [[String: String]] = [
            ["path": paths.configurationDirectory.path, "mode": "deny"],
            ["path": paths.homeDirectory.appending(path: "Library/Keychains").path, "mode": "deny"]
        ]
        let credentials: [String: Any] = [
            "files": credentialFiles,
            "envVars": ContainedBoundaryPolicy.deniedCredentialEnvironmentNames.map { ["name": $0, "mode": "deny"] }
        ]
        let sandbox: [String: Any] = [
            "enabled": true, "failIfUnavailable": true, "autoAllowBashIfSandboxed": false,
            "allowUnsandboxedCommands": false, "excludedCommands": [String](), "allowAppleEvents": false,
            "enableWeakerNetworkIsolation": false, "enableWeakerNestedSandbox": false,
            "filesystem": filesystem, "network": network, "credentials": credentials
        ]
        // Claude Code 2.1.281 announces its built-in AGENTS.md plugin unless
        // this switches it off, and the job session refuses any plugin.
        let object: [String: Any] = [
            "disableAutoMode": "disable",
            "enabledPlugins": ["agents-md@builtin": false],
            "permissions": permissions,
            "sandbox": sandbox
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func environment(paths: AgenticProbePaths) -> [String: String] {
        let temporary = paths.temporaryDirectory.path
        return [
            "HOME": paths.homeDirectory.path, "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporary, "CLAUDE_CODE_TMPDIR": temporary, "CLAUDE_CONFIG_DIR": paths.configurationDirectory.path,
            "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1", "DISABLE_BUG_COMMAND": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_CRON": "1", "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
            "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK": "1",
            "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1", "MCP_DISCOVERY_CACHE": "0", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false", "NETRC": "/dev/null", "NPM_CONFIG_USERCONFIG": "/dev/null",
            "PIP_CONFIG_FILE": "/dev/null", "XDG_CONFIG_HOME": temporary + "/xdg-config",
            "XDG_CACHE_HOME": temporary + "/xdg-cache", "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
            "NO_COLOR": "1"
        ]
    }

    private static func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
    private static func overlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
