import Foundation

/// Syntactic input validation only. The application must freshly admit the
/// signed installation and owned profile before passing this value to a transport.
/// Constructing a target performs no filesystem, credential or provider access.
public struct ClaudeConnectionTarget: Equatable, Sendable {
    public let executableURL: URL
    public let expectedExecutableSHA256: String
    public let profileURL: URL
    public let workingDirectoryURL: URL
    public let temporaryDirectoryURL: URL
    public let homeDirectoryURL: URL

    public init(
        executableURL: URL,
        expectedExecutableSHA256: String,
        profileURL: URL,
        workingDirectoryURL: URL,
        temporaryDirectoryURL: URL,
        homeDirectoryURL: URL
    ) throws {
        for url in [executableURL, profileURL, workingDirectoryURL, temporaryDirectoryURL, homeDirectoryURL] {
            // URL.path can truncate at an encoded NUL. Validate the complete
            // decoded URL component before using Foundation's filesystem path.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let completePath = components.percentEncodedPath.removingPercentEncoding,
                  completePath.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
            else { throw ClaudeConnectionTargetError.invalidPath }
            guard url.isFileURL, url.baseURL == nil,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), url.path != "/",
                  !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
                  url.path.utf8.count <= 4_096,
                  url.path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
            else { throw ClaudeConnectionTargetError.invalidPath }
        }
        for url in [profileURL, workingDirectoryURL, temporaryDirectoryURL] {
            guard url.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
                throw ClaudeConnectionTargetError.missingNoIndexBoundary
            }
        }
        guard expectedExecutableSHA256.utf8.count == 64,
              expectedExecutableSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ClaudeConnectionTargetError.invalidExecutableFingerprint }
        self.executableURL = executableURL
        self.expectedExecutableSHA256 = expectedExecutableSHA256
        self.profileURL = profileURL
        self.workingDirectoryURL = workingDirectoryURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.homeDirectoryURL = homeDirectoryURL
    }
}

public enum ClaudeConnectionTargetError: Error, Equatable, Sendable {
    case invalidPath
    case missingNoIndexBoundary
    case invalidExecutableFingerprint
}

/// Two fixed official commands, never a shell/tool execution interface.
public enum ClaudeConnectionCommandBuilder {
    public static let statusArguments = ["auth", "status"]

    /// Deliberately has no parent-environment input. HOME remains the caller's
    /// real home for the official CLI's own account flow; the separately verified
    /// Preview profile scopes CLI state. This is not a filesystem sandbox.
    public static func environment(for target: ClaudeConnectionTarget) -> [String: String] {
        [
            "HOME": target.homeDirectoryURL.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "TMPDIR": target.temporaryDirectoryURL.path,
            "CLAUDE_CODE_TMPDIR": target.temporaryDirectoryURL.path,
            "CLAUDE_CONFIG_DIR": target.profileURL.path,
            "NETRC": "/dev/null",
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
    }

    /// Generation only: no file creation, Terminal launch, provider invocation
    /// or credential capture. The inner noninteractive shell is also under the
    /// fresh environment, including while invoking the system hash utility.
    public static func officialLoginScript(for target: ClaudeConnectionTarget) -> String {
        let body = """
        set -eu
        cd -- "$1"
        [ -f "$2" ] && [ -x "$2" ] && [ ! -L "$2" ] || exit 1
        fingerprint=$(/usr/bin/shasum -a 256 -- "$2")
        [ "${fingerprint%% *}" = "$3" ] || exit 1
        exec "$2" auth login
        """
        let assignments = environment(for: target).sorted(by: { $0.key < $1.key })
            .map { shellQuote("\($0.key)=\($0.value)") }
        let command = ["exec", "/usr/bin/env", "-i"] + assignments
            + ["/bin/sh", "-c", shellQuote(body), "openbots-claude-sign-in",
               shellQuote(target.workingDirectoryURL.path), shellQuote(target.executableURL.path),
               shellQuote(target.expectedExecutableSHA256)]
        return "#!/bin/sh\n" + command.joined(separator: " ") + "\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
