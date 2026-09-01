import CoreFoundation
import Darwin
import Foundation

public enum ClaudeTextPolicyAdmission: Equatable, Sendable {
    case admitted
    case rejected(ClaudeTextPolicyRejection)
}

public enum ClaudeTextPolicyRejection: String, Equatable, Sendable {
    case invalidProfile, managedFilePresent, remotePolicyCachePresent
    case managedPreferencesPresent, inspectionUnavailable
}

public protocol ClaudeTextPolicyInspecting: Sendable {
    func inspect(profileURL: URL) -> ClaudeTextPolicyAdmission
}

/// Metadata-only prerequisite for this Pro/Max-only, tool-free slice. This does
/// not inspect authentication or policy values and does not grant runtime access.
/// Services separately requires fresh firstParty claude.ai Pro/Max proof and a
/// fresh environment without API keys, OAuth-token overrides or gateway routes.
///
/// Official sources: code.claude.com/docs/en/managed-settings (macOS domain and
/// three system paths); /server-managed-settings (remote-settings.json cache;
/// fresh remote delivery supports Team/Enterprise OAuth, direct API keys and
/// CLAUDE_CODE_OAUTH_TOKEN, not stored Pro/Max OAuth). Absence is a snapshot, not
/// protection against an administrator changing policy while the CLI runs.
public struct NativeClaudeTextPolicyInspector: ClaudeTextPolicyInspecting {
    public static let managedPreferencesDomain = "com.anthropic.claudecode"
    public static let managedPaths = [
        "/Library/Application Support/ClaudeCode/managed-settings.json",
        "/Library/Application Support/ClaudeCode/managed-settings.d",
        "/Library/Application Support/ClaudeCode/managed-mcp.json"
    ]
    private let metadata: @Sendable (URL) -> ClaudeTextPolicySourceState
    private let preferences: @Sendable () -> ClaudeTextPolicySourceState

    public init() {
        metadata = Self.inspectMetadata
        preferences = Self.inspectPreferences
    }

    init(metadata: @escaping @Sendable (URL) -> ClaudeTextPolicySourceState,
         preferences: @escaping @Sendable () -> ClaudeTextPolicySourceState) {
        self.metadata = metadata
        self.preferences = preferences
    }

    public func inspect(profileURL: URL) -> ClaudeTextPolicyAdmission {
        guard let components = URLComponents(url: profileURL, resolvingAgainstBaseURL: false),
              let path = components.percentEncodedPath.removingPercentEncoding,
              profileURL.isFileURL, profileURL.baseURL == nil,
              profileURL.host == nil || profileURL.host == "" || profileURL.host == "localhost",
              profileURL.query == nil, profileURL.fragment == nil,
              path.hasPrefix("/"), path.utf8.count <= 4_096,
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
              !profileURL.pathComponents.contains(".."), !profileURL.pathComponents.contains("."),
              profileURL.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            return .rejected(.invalidProfile)
        }
        for path in Self.managedPaths {
            switch metadata(URL(fileURLWithPath: path)) {
            case .present: return .rejected(.managedFilePresent)
            case .unknown: return .rejected(.inspectionUnavailable)
            case .absent: break
            }
        }
        switch metadata(profileURL.appendingPathComponent("remote-settings.json")) {
        case .present: return .rejected(.remotePolicyCachePresent)
        case .unknown: return .rejected(.inspectionUnavailable)
        case .absent: break
        }
        switch preferences() {
        case .present: return .rejected(.managedPreferencesPresent)
        case .unknown: return .rejected(.inspectionUnavailable)
        case .absent: return .admitted
        }
    }

    /// Only fstatat/openat on the exact path's components; no file data, directory
    /// enumeration, profile traversal or symlink following. Any final entry,
    /// including an empty directory, dangling symlink or FIFO, counts as present.
    static func inspectMetadata(_ url: URL) -> ClaudeTextPolicySourceState {
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return .unknown }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return .unknown }
        defer { Darwin.close(directory) }
        for (index, component) in components.enumerated() {
            var value = stat()
            guard fstatat(directory, component, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                return errno == ENOENT ? .absent : .unknown
            }
            if index == components.count - 1 { return .present }
            guard value.st_mode & S_IFMT == S_IFDIR else { return .unknown }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return .unknown }
            Darwin.close(directory)
            directory = next
        }
        return .unknown
    }

    static func inspectPreferences() -> ClaudeTextPolicySourceState {
        let domain = managedPreferencesDomain as CFString
        // CFPreferences.h documents NULL from CopyKeyList as no keys set, not
        // an empty settings value. Do not use CopyValue/CopyMultiple, defaults,
        // synchronize (which may write), a guessed MDM plist or a subprocess.
        let users: [CFString] = [kCFPreferencesCurrentUser, kCFPreferencesAnyUser]
        let hosts: [CFString] = [kCFPreferencesAnyHost, kCFPreferencesCurrentHost]
        for user in users {
            for host in hosts {
                if let copied = CFPreferencesCopyKeyList(domain, user, host) {
                    guard let keys = copied as? [String] else { return .unknown }
                    if !keys.isEmpty { return .present }
                }
            }
        }
        // Also query forced status of documented executable/provider controls.
        // This API returns only whether a named key is managed, never its value.
        for key in ["hooks", "disableAllHooks", "statusLine", "fileSuggestion", "env",
                    "policyHelper", "managedSourcesBehavior", "forceLoginMethod",
                    "forceLoginGatewayUrl", "apiKeyHelper", "otelHeadersHelper",
                    "awsAuthRefresh", "awsCredentialExport", "mcpServers",
                    "enabledPlugins", "extraKnownMarketplaces", "model", "modelOverrides",
                    "permissions", "availableModels"] {
            if CFPreferencesAppValueIsForced(key as CFString, domain) { return .present }
        }
        return .absent
    }
}

enum ClaudeTextPolicySourceState: Equatable, Sendable {
    case absent, present, unknown
}
