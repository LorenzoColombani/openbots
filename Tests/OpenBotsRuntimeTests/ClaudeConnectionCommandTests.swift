import CryptoKit
import Foundation
import Testing
@testable import OpenBotsRuntime

@Test("Connection commands have no arbitrary arguments or inherited environment")
func claudeConnectionCommandContract() throws {
    let target = try connectionTestTarget()
    #expect(ClaudeConnectionCommandBuilder.statusArguments == ["auth", "status"])
    let environment = ClaudeConnectionCommandBuilder.environment(for: target)
    #expect(environment["HOME"] == target.homeDirectoryURL.path)
    #expect(environment["CLAUDE_CONFIG_DIR"] == target.profileURL.path)
    #expect(environment["TMPDIR"] == target.temporaryDirectoryURL.path)
    #expect(environment["CLAUDE_CODE_TMPDIR"] == target.temporaryDirectoryURL.path)
    #expect(environment["NETRC"] == "/dev/null")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(Set(environment.keys) == [
        "HOME", "PATH", "LANG", "TERM", "TMPDIR", "CLAUDE_CODE_TMPDIR", "CLAUDE_CONFIG_DIR", "NETRC",
        "DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_BUG_COMMAND",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
        "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "CLAUDE_CODE_DISABLE_CLAUDE_MDS",
        "CLAUDE_CODE_DISABLE_CRON", "CLAUDE_CODE_SKIP_PROMPT_HISTORY", "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS"
    ])
    for poison in [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "AWS_PROFILE", "AWS_ACCESS_KEY_ID", "GOOGLE_APPLICATION_CREDENTIALS", "HTTPS_PROXY",
        "BASH_ENV", "ENV", "ZDOTDIR", "PERL5OPT", "DYLD_INSERT_LIBRARIES", "GIT_ASKPASS", "NETRC_FILE"
    ] { #expect(environment[poison] == nil) }
    let script = ClaudeConnectionCommandBuilder.officialLoginScript(for: target)
    #expect(script.hasPrefix("#!/bin/sh\nexec /usr/bin/env -i "))
    #expect(script.contains("exec \"$2\" auth login"))
    #expect(!script.contains("--bare"))
    #expect(!script.contains("--json"))
    #expect(!script.contains("setup-token"))
    #expect(!script.contains("--print"))
}

@Test("Connection target rejects unsafe URL syntax before any I/O")
func claudeConnectionTargetRejectsUnsafePaths() throws {
    let unsafe = [
        URL(string: "https://example.invalid/fake-claude")!,
        URL(string: "file://other-host/private/tmp/fake-claude")!,
        URL(string: "file:///private/tmp/fake-claude?query=1")!,
        URL(string: "file:///private/tmp/fake-claude#fragment")!,
        URL(string: "file:///private/tmp/../fake-claude")!,
        URL(string: "file:///private/tmp/fake%00claude")!,
        URL(string: "file:///private/tmp/fake%0Aclaude")!,
        URL(fileURLWithPath: "/private/tmp/fake\nclaude"),
        URL(fileURLWithPath: "/private/tmp/fake\u{0}claude"),
        URL(fileURLWithPath: "/")
    ]
    for executable in unsafe {
        #expect(throws: ClaudeConnectionTargetError.invalidPath) {
            try connectionTestTarget(executable: executable)
        }
    }
    #expect(throws: ClaudeConnectionTargetError.missingNoIndexBoundary) {
        try connectionTestTarget(profile: URL(fileURLWithPath: "/private/tmp/unbounded-profile"))
    }
    for invalid in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
        #expect(throws: ClaudeConnectionTargetError.invalidExecutableFingerprint) {
            try connectionTestTarget(fingerprint: invalid)
        }
    }
}

@Test("Generated handoff treats hostile path characters as data under a clean environment")
func claudeConnectionHandoffQuotingAndFreshEnvironment() throws {
    let fixture = try ClaudeConnectionFixture(body: """
    [ "$#" -eq 2 ] && [ "$1" = auth ] && [ "$2" = login ] || exit 31
    /usr/bin/printf '%s' "$CLAUDE_CONFIG_DIR" > profile-observed
    /usr/bin/printf '%s' "$HOME" > home-observed
    /usr/bin/printf '%s' "$TMPDIR" > temporary-observed
    /usr/bin/env > environment-observed
    """, name: "fake ' $(touch injected) `touch backtick` ; tool")
    defer { fixture.remove() }
    let poison = fixture.root.appendingPathComponent("poison-startup.sh")
    try Data("/usr/bin/touch '\(fixture.root.path)/startup-ran'\n".utf8).write(to: poison)
    let result = try fixture.runLoginScript(environment: [
        "PATH": "/no-tools-here", "ANTHROPIC_API_KEY": "synthetic-test-poison",
        "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-test-poison", "HOME": "/wrong-home",
        "CLAUDE_CONFIG_DIR": "/wrong-profile", "NETRC": "/wrong-netrc",
        "BASH_ENV": poison.path, "ENV": poison.path, "PERL5OPT": "-MNonexistentPoisonModule"
    ])
    #expect(result == 0)
    #expect(try fixture.readWorkingFile("profile-observed") == fixture.target.profileURL.path)
    #expect(try fixture.readWorkingFile("home-observed") == fixture.target.homeDirectoryURL.path)
    #expect(try fixture.readWorkingFile("temporary-observed") == fixture.target.temporaryDirectoryURL.path)
    let observed = try fixture.readWorkingFile("environment-observed")
    #expect(!observed.contains("synthetic-test-poison"))
    #expect(!observed.contains("PERL5OPT="))
    #expect(!observed.contains("BASH_ENV="))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("startup-ran").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("injected").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("backtick").path))
}

@Test("Delayed handoff refuses a changed executable rather than starting sign-in")
func claudeConnectionHandoffRejectsChangedBinary() throws {
    let fixture = try ClaudeConnectionFixture(body: "/usr/bin/touch login-was-invoked")
    defer { fixture.remove() }
    try Data("#!/bin/sh\n/usr/bin/touch login-was-invoked\n# changed\n".utf8).write(to: fixture.target.executableURL)
    #expect(try fixture.runLoginScript(environment: [:]) != 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.workingDirectoryURL.appendingPathComponent("login-was-invoked").path))
}

private func connectionTestTarget(
    executable: URL = URL(fileURLWithPath: "/private/tmp/never-created.noindex/fake-claude"),
    profile: URL = URL(fileURLWithPath: "/private/tmp/never-created.noindex/profile"),
    fingerprint: String = String(repeating: "a", count: 64)
) throws -> ClaudeConnectionTarget {
    try ClaudeConnectionTarget(
        executableURL: executable, expectedExecutableSHA256: fingerprint, profileURL: profile,
        workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/never-created.noindex/work"),
        temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/never-created.noindex/temp"),
        homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/never-created.noindex/home")
    )
}

/// Every executable in these tests is authored synthetic data in a unique
/// disposable directory. No discovery or invocation of the installed CLI occurs.
struct ClaudeConnectionFixture {
    let root: URL
    let target: ClaudeConnectionTarget

    init(body: String, name: String = "fake-claude") throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-connection-test-\(UUID().uuidString).noindex", isDirectory: true)
        self.root = root
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for component in ["profile", "work", "temp", "home"] {
                try fileManager.createDirectory(at: root.appendingPathComponent(component), withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
            }
            let executable = root.appendingPathComponent(name)
            let data = Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8)
            try data.write(to: executable, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            target = try ClaudeConnectionTarget(
                executableURL: executable,
                expectedExecutableSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                profileURL: root.appendingPathComponent("profile"), workingDirectoryURL: root.appendingPathComponent("work"),
                temporaryDirectoryURL: root.appendingPathComponent("temp"), homeDirectoryURL: root.appendingPathComponent("home")
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func readWorkingFile(_ name: String) throws -> String {
        try String(contentsOf: target.workingDirectoryURL.appendingPathComponent(name), encoding: .utf8)
    }

    func runLoginScript(environment: [String: String]) throws -> Int32 {
        let command = root.appendingPathComponent("sign-in.command")
        try Data(ClaudeConnectionCommandBuilder.officialLoginScript(for: target).utf8).write(to: command, options: .withoutOverwriting)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [command.path]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

final class ClaudeProcessLifecycleObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration?

    var duration: Duration? { lock.withLock { value } }
    func record(_ duration: Duration) { lock.withLock { value = duration } }
}
