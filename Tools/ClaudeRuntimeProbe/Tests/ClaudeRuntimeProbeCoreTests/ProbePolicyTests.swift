import Darwin
import Foundation
import Testing
@testable import ClaudeRuntimeProbeCore

@Test("Provider and API variables are removed from the child environment")
func providerVariablesAreScrubbed() throws {
    var parent = [
        "LANG": "en_US.UTF-8",
        "ANTHROPIC_API_KEY": "sentinel-not-a-secret",
        "ANTHROPIC_AUTH_TOKEN": "sentinel-not-a-secret",
        "ANTHROPIC_MODEL": "sentinel-model",
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "AWS_ACCESS_KEY_ID": "sentinel-not-a-secret",
        "CLAUDE_CODE_OAUTH_TOKEN": "sentinel-not-a-secret",
        "HTTPS_PROXY": "https://sentinel.invalid"
    ]
    parent["DYLD_INSERT_LIBRARIES"] = "/not/allowed"

    let child = try ChildEnvironmentPolicy.makeChildEnvironment(
        parent: parent,
        claudeExecutable: URL(fileURLWithPath: "/usr/local/bin/claude"),
        temporaryDirectory: URL(fileURLWithPath: "/private/tmp/OpenBotsProbe.noindex/tmp"),
        configurationDirectory: URL(
            fileURLWithPath: "/private/tmp/OpenBotsProbe.noindex/config"
        )
    )

    #expect(ChildEnvironmentPolicy.providerVariableNames(in: child).isEmpty)
    #expect(child["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(child["LANG"] == "en_US.UTF-8")
    #expect(child["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] == "1")
    #expect(child["CLAUDE_CONFIG_DIR"] == "/private/tmp/OpenBotsProbe.noindex/config")
}

@Test("Only claude.ai first-party Pro or Max authentication is accepted", arguments: [
    AuthenticationStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", subscriptionType: "pro"),
    AuthenticationStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", subscriptionType: "max")
])
func acceptedSubscriptions(status: AuthenticationStatus) {
    #expect(status.isAcceptedSubscription)
}

@Test("Alternative and unknown authentication routes fail closed", arguments: [
    AuthenticationStatus(loggedIn: false, authMethod: "none", apiProvider: "firstParty", subscriptionType: nil),
    AuthenticationStatus(loggedIn: true, authMethod: "apiKey", apiProvider: "firstParty", subscriptionType: nil),
    AuthenticationStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "bedrock", subscriptionType: "max"),
    AuthenticationStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", subscriptionType: "free")
])
func rejectedAuthentication(status: AuthenticationStatus) {
    #expect(!status.isAcceptedSubscription)
}

@Test("Runtime initialization accepts only the no-API-key marker")
func acceptedRuntimeAuthentication() {
    let receipt = RuntimeInitializationReceipt(
        apiKeySource: "none",
        sessionID: "session",
        toolCount: 0,
        mcpServerCount: 0,
        permissionMode: "dontAsk",
        claudeCodeVersion: "fixture"
    )
    #expect(receipt.isSubscriptionOAuth)
}

@Test("Runtime initialization rejects API, config, and unknown key sources")
func rejectedRuntimeAuthentication() {
    let apiKey = RuntimeInitializationReceipt(
        apiKeySource: "ANTHROPIC_API_KEY",
        sessionID: "session",
        toolCount: 0,
        mcpServerCount: 0,
        permissionMode: "dontAsk",
        claudeCodeVersion: "fixture"
    )
    let configKey = RuntimeInitializationReceipt(
        apiKeySource: "config",
        sessionID: "session",
        toolCount: 0,
        mcpServerCount: 0,
        permissionMode: "dontAsk",
        claudeCodeVersion: "fixture"
    )
    let loginManagedKey = RuntimeInitializationReceipt(
        apiKeySource: "/login managed key",
        sessionID: "session",
        toolCount: 0,
        mcpServerCount: 0,
        permissionMode: "dontAsk",
        claudeCodeVersion: "fixture"
    )
    let unknown = RuntimeInitializationReceipt(
        apiKeySource: "future-marker",
        sessionID: "session",
        toolCount: 0,
        mcpServerCount: 0,
        permissionMode: "dontAsk",
        claudeCodeVersion: "fixture"
    )
    let missing = RuntimeInitializationReceipt(
        apiKeySource: nil,
        sessionID: "session",
        toolCount: 0,
        mcpServerCount: 0,
        permissionMode: "dontAsk",
        claudeCodeVersion: "fixture"
    )
    #expect(!apiKey.isSubscriptionOAuth)
    #expect(!configKey.isSubscriptionOAuth)
    #expect(!loginManagedKey.isSubscriptionOAuth)
    #expect(!unknown.isSubscriptionOAuth)
    #expect(!missing.isSubscriptionOAuth)
}

@Test("Required CLI flag detection is exact")
func flagDetection() {
    let help = """
    --print --input-format --output-format --include-partial-messages
    --replay-user-messages --resume --strict-mcp-config --settings
    --setting-sources --allowed-tools --restricted --no-session-persistence
    """
    #expect(FlagSupport(help: help).missing.isEmpty)
    #expect(FlagSupport(help: help.replacing("--restricted", with: "")).missing == ["--restricted"])
}

@Test("Probe roots must be explicit private temp .noindex paths")
func rootValidation() throws {
    let accepted = try ProbePathPolicy.validateTemporaryNoIndexRoot(
        URL(fileURLWithPath: "/private/tmp/OpenBotsProbe.noindex/run")
    )
    #expect(accepted.path == "/private/tmp/OpenBotsProbe.noindex/run")
    _ = try ProbePathPolicy.validateTemporaryNoIndexRoot(
        URL(fileURLWithPath: "/tmp/OpenBotsProbe.noindex/run")
    )

    #expect(throws: ProbeFailure.self) {
        try ProbePathPolicy.validateTemporaryNoIndexRoot(URL(fileURLWithPath: "/private/tmp/OpenBotsProbe/run"))
    }
    #expect(throws: ProbeFailure.self) {
        try ProbePathPolicy.validateTemporaryNoIndexRoot(URL(fileURLWithPath: "/var/tmp/OpenBotsProbe.noindex"))
    }
}

@Test("Isolated probe profiles require an exact marker-owned noindex directory")
func isolatedProfilePolicy() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "OpenBotsClaudeProfile-\(UUID().uuidString).noindex", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let configuration = root.appending(path: "config", directoryHint: .isDirectory)
    let validated = try ClaudeConfigurationPolicy.prepareIsolatedProbeDirectory(
        configuration,
        within: root
    )

    #expect(validated.kind == .isolatedProbe)
    #expect(!validated.permitsLiveClaude)
    #expect(validated.url == configuration.standardizedFileURL)
    var directoryMetadata = stat()
    var markerMetadata = stat()
    #expect(lstat(configuration.path, &directoryMetadata) == 0)
    #expect(directoryMetadata.st_mode & 0o777 == 0o700)
    let marker = configuration.appending(path: ClaudeConfigurationPolicy.markerFilename)
    #expect(lstat(marker.path, &markerMetadata) == 0)
    #expect(markerMetadata.st_mode & 0o777 == 0o600)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: configuration.path
    )
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validateIsolatedProbeDirectory(configuration, within: root)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: configuration.path
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validateIsolatedProbeDirectory(configuration, within: root)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    try Data(
        "{\"bundleIdentifier\":\"wrong\",\"role\":\"probe\",\"schemaVersion\":1}".utf8
    ).write(to: marker)
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validateIsolatedProbeDirectory(configuration, within: root)
    }
    try FileManager.default.removeItem(at: marker)
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validateIsolatedProbeDirectory(configuration, within: root)
    }
}

@Test("Default, misplaced, and symlinked Claude profiles fail closed")
func unsafeProfilesAreRejected() throws {
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validatePreviewDirectory(
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        )
    }

    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "OpenBotsClaudeProfile-\(UUID().uuidString).noindex", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let misplaced = root.appending(path: "other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: misplaced,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validateIsolatedProbeDirectory(misplaced, within: root)
    }

    let target = root.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: target,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let symlink = root.appending(path: "config", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    #expect(throws: ProbeFailure.self) {
        try ClaudeConfigurationPolicy.validateIsolatedProbeDirectory(symlink, within: root)
    }
}

@Test("An isolated probe profile can never authorize the live runtime")
func isolatedProfileCannotRunLiveClaude() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "OpenBotsClaudeProfile-\(UUID().uuidString).noindex", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let configuration = try ClaudeConfigurationPolicy.prepareIsolatedProbeDirectory(
        root.appending(path: "config", directoryHint: .isDirectory),
        within: root
    )
    let help = """
    --print --input-format --output-format --include-partial-messages
    --replay-user-messages --resume --strict-mcp-config --settings
    --setting-sources --allowed-tools --restricted --no-session-persistence
    """
    let readiness = ReadinessReport(
        executable: "/bin/false",
        version: "fixture",
        authentication: AuthenticationStatus(
            loggedIn: true,
            authMethod: "claude.ai",
            apiProvider: "firstParty",
            subscriptionType: "max"
        ),
        flags: FlagSupport(help: help),
        providerVariablesPresentInParent: [],
        providerVariablesPresentInChild: [],
        childEnvironmentKeys: ["CLAUDE_CONFIG_DIR"]
    )

    #expect(readiness.accepted)
    #expect(throws: ProbeFailure.self) {
        try ClaudeLiveProbe.run(
            claudeExecutable: URL(fileURLWithPath: "/bin/false"),
            probeRoot: root,
            readiness: readiness,
            configurationDirectory: configuration,
            parentEnvironment: [:]
        )
    }
}

@Test("Nonblocking input enforces its byte bound")
func boundedInput() {
    let oversized = Data(repeating: 0, count: NonblockingLineWriter.maximumLineBytes + 1)
    #expect(throws: ProbeFailure.self) {
        try NonblockingLineWriter.write(oversized, to: -1, timeout: 0.01)
    }
}
