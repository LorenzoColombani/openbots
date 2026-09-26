import ClaudeRuntimeProbeCore
import Darwin
import Foundation

private struct Options {
    enum Command: String {
        case inspect
        case isolation
        case live
    }

    let command: Command
    let claudeExecutable: URL
    let probeRoot: URL
    let configurationDirectory: URL
}

private struct IsolationReport: Codable {
    let root: String
    let readiness: ReadinessReport
    let writeSet: WriteSetDiff
    let isolatedConfigCreated: Bool
    let isolatedAuthenticationAvailable: Bool
    let gatePassed: Bool
    let nextAction: String
}

private func parseOptions() throws -> Options {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first, let command = Options.Command(rawValue: first) else {
        throw ProbeFailure.invalidArguments("expected inspect, isolation, or live")
    }
    arguments.removeFirst()

    var claudePath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/bin/claude")
        .path
    var rootPath: String?
    var configurationPath: String?
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        guard !arguments.isEmpty else {
            throw ProbeFailure.invalidArguments("missing value for \(flag)")
        }
        let value = arguments.removeFirst()
        switch flag {
        case "--claude": claudePath = value
        case "--root": rootPath = value
        case "--config": configurationPath = value
        default: throw ProbeFailure.invalidArguments("unknown flag \(flag)")
        }
    }

    guard let rootPath else {
        throw ProbeFailure.invalidArguments("--root is required and must name an explicit /private/tmp .noindex root")
    }
    guard let configurationPath else {
        throw ProbeFailure.invalidArguments(
            "--config is required; the default Claude profile is never accepted"
        )
    }
    let root = try ProbePathPolicy.validateTemporaryNoIndexRoot(URL(fileURLWithPath: rootPath))
    return Options(
        command: command,
        claudeExecutable: URL(fileURLWithPath: claudePath).standardizedFileURL,
        probeRoot: root,
        configurationDirectory: URL(fileURLWithPath: configurationPath).standardizedFileURL
    )
}

private func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

do {
    let options = try parseOptions()
    let root = options.probeRoot
    let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
    try createPrivateDirectory(root)
    try createPrivateDirectory(temporaryDirectory)

    switch options.command {
    case .inspect:
        let configuration = try ClaudeConfigurationPolicy.validatePreviewDirectory(
            options.configurationDirectory
        )
        let report = try ClaudeReadinessProbe.inspect(
            claudeExecutable: options.claudeExecutable,
            temporaryDirectory: temporaryDirectory,
            configurationDirectory: configuration
        )
        try printJSON(report)
        if !report.accepted { exit(2) }

    case .isolation:
        let configurationDirectory = options.configurationDirectory
        let configuration = try ClaudeConfigurationPolicy.prepareIsolatedProbeDirectory(
            configurationDirectory,
            within: root
        )
        let backupDirectory = configurationDirectory.appending(path: "backups", directoryHint: .isDirectory)
        // Claude Code creates this directory as 0755 when it is absent. The
        // preview owns the enclosing layout, so pre-create it as 0700.
        try createPrivateDirectory(backupDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let watchedRoots = [
            root,
            home.appending(path: ".claude", directoryHint: .isDirectory),
            home.appending(path: ".claude.json")
        ]
        let before = FileSnapshotter.snapshot(roots: watchedRoots)
        let readiness = try ClaudeReadinessProbe.inspect(
            claudeExecutable: options.claudeExecutable,
            temporaryDirectory: temporaryDirectory,
            configurationDirectory: configuration
        )
        let after = FileSnapshotter.snapshot(roots: watchedRoots)
        let writeSet = FileSnapshotter.diff(
            before: before,
            after: after,
            redactions: [
                (root.path, "$PROBE_ROOT"),
                (root.resolvingSymlinksInPath().path, "$PROBE_ROOT"),
                (home.path, "$HOME")
            ]
        )
        let report = IsolationReport(
            root: "$PROBE_ROOT",
            readiness: readiness,
            writeSet: writeSet,
            isolatedConfigCreated: FileManager.default.fileExists(atPath: configurationDirectory.path),
            isolatedAuthenticationAvailable: readiness.authentication.isAcceptedSubscription,
            gatePassed: readiness.accepted,
            nextAction: readiness.accepted
                ? "Stop: a disposable probe profile unexpectedly authenticated. It is not eligible for live use."
                : "Expected isolation control: default authentication was not reused. Create the real preview profile only through StorageLayoutService; never log this disposable control in."
        )
        try printJSON(report)
        if !report.gatePassed { exit(3) }

    case .live:
        let configuration = try ClaudeConfigurationPolicy.validatePreviewDirectory(
            options.configurationDirectory
        )
        let readiness = try ClaudeReadinessProbe.inspect(
            claudeExecutable: options.claudeExecutable,
            temporaryDirectory: temporaryDirectory,
            configurationDirectory: configuration
        )
        let report = try ClaudeLiveProbe.run(
            claudeExecutable: options.claudeExecutable,
            probeRoot: root,
            readiness: readiness,
            configurationDirectory: configuration
        )
        try printJSON(report)
        if !report.accepted { exit(4) }
    }
} catch {
    let message = "claude-runtime-probe: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
