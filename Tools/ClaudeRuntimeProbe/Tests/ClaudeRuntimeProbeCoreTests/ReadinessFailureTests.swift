import Darwin
import Foundation
import Testing
@testable import ClaudeRuntimeProbeCore

private func makeReadinessFailureDirectory() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "OpenBotsReadinessFailure-\(UUID().uuidString).noindex", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func writeReadinessFailureExecutable(_ contents: String, in directory: URL) throws -> URL {
    let executable = directory.appending(path: "fake-claude.sh")
    try Data(contents.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

@Test("Accepted-looking auth JSON is accepted only after a zero exit status", arguments: [0, 23])
func readinessChecksAuthenticationExitStatus(status: Int) throws {
    let directory = try makeReadinessFailureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let originalFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/fake-claude.sh")
    let executable = try writeReadinessFailureExecutable(#"""
        #!/bin/sh
        set -eu
        /bin/sh \#(shellQuote(originalFixture.path)) "$@"
        if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
          exit \#(status)
        fi
        """#, in: directory)
    let configuration = try ClaudeConfigurationPolicy.prepareIsolatedProbeDirectory(
        directory.appending(path: "config", directoryHint: .isDirectory),
        within: directory
    )

    do {
        let report = try ClaudeReadinessProbe.inspect(
            claudeExecutable: executable,
            temporaryDirectory: directory,
            configurationDirectory: configuration,
            parentEnvironment: [:]
        )
        #expect(status == 0)
        #expect(report.accepted)
    } catch ProbeFailure.processLaunch(let detail) {
        #expect(status == 23)
        #expect(detail == "Claude auth status exited 23")
    }
}

private enum RejectedInitialization: CaseIterable, Sendable {
    case missingInit
    case apiKey
    case missingKeySource
    case enabledTools
    case missingTools
    case enabledMCP
    case missingMCP
    case permissiveMode
    case missingPermissionMode

    var event: [String: Any]? {
        guard self != .missingInit else { return nil }
        var event = acceptedInitializationEvent
        switch self {
        case .missingInit: break
        case .apiKey: event["apiKeySource"] = "ANTHROPIC_API_KEY"
        case .missingKeySource: event.removeValue(forKey: "apiKeySource")
        case .enabledTools: event["tools"] = ["Bash"]
        case .missingTools: event.removeValue(forKey: "tools")
        case .enabledMCP: event["mcp_servers"] = [["name": "fixture-server"]]
        case .missingMCP: event.removeValue(forKey: "mcp_servers")
        case .permissiveMode: event["permissionMode"] = "bypassPermissions"
        case .missingPermissionMode: event.removeValue(forKey: "permissionMode")
        }
        return event
    }

    var rejectionReason: String {
        switch self {
        case .missingInit, .apiKey, .missingKeySource:
            "runtime init did not confirm OAuth rather than API/config key auth"
        case .enabledTools, .missingTools:
            "runtime init advertised tools despite the empty tool set"
        case .enabledMCP, .missingMCP:
            "runtime init advertised MCP servers despite strict empty MCP configuration"
        case .permissiveMode, .missingPermissionMode:
            "runtime init did not confirm dontAsk permission mode"
        }
    }
}

private var acceptedInitializationEvent: [String: Any] {
    [
        "type": "system",
        "subtype": "init",
        "apiKeySource": "none",
        "session_id": "fixture-session",
        "tools": [String](),
        "mcp_servers": [String](),
        "permissionMode": "dontAsk",
        "claude_code_version": "fixture"
    ]
}

private func initializationFailureExecutable(event: [String: Any]?, in directory: URL) throws -> URL {
    let emitInitialization: String
    if let event {
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        emitInitialization = "/usr/bin/printf '%s\\n' " + shellQuote(String(decoding: data, as: UTF8.self))
    } else {
        emitInitialization = ":"
    }
    // The fixture records every consumed UUID and keeps a descendant alive so
    // gate rejection must actually clean the owned group, not just stop writing.
    return try writeReadinessFailureExecutable(#"""
        #!/bin/sh
        set -eu
        extract_uuid() {
          /usr/bin/printf '%s\n' "$1" \
            | /usr/bin/sed -nE 's/.*"uuid"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
        }
        emit_replay() {
          /usr/bin/printf '{"type":"user","uuid":"%s","session_id":"fixture-session"}\n' "$1"
        }
        IFS= read -r first_input
        first_uuid=$(extract_uuid "$first_input")
        /usr/bin/printf '%s\n' "$first_uuid" > input-receipt.txt
        /bin/sleep 30 &
        descendant=$!
        trap 'wait "$descendant" 2>/dev/null || :; exit 0' TERM
        /usr/bin/printf '%s %s\n' "$$" "$descendant" > tree-receipt.txt
        \#(emitInitialization)
        emit_replay "$first_uuid"
        if IFS= read -r second_input; then
          second_uuid=$(extract_uuid "$second_input")
          /usr/bin/printf '%s\n' "$second_uuid" >> input-receipt.txt
          emit_replay "$second_uuid"
        fi
        wait "$descendant" || :
        """#, in: directory)
}

private func submitFirstFixtureInput(to child: ProbeManagedProcessGroup) throws {
    var data = try JSONSerialization.data(withJSONObject: [
        "type": "user",
        "uuid": "first-fixture-input",
        "message": ["role": "user", "content": "inert first request"]
    ])
    data.append(0x0a)
    try child.write(data, timeout: 1)
}

@Test("Rejected initialization prevents ACK-2 and removes the owned process tree", arguments: RejectedInitialization.allCases)
private func rejectedInitializationStopsBeforeSecondInput(scenario: RejectedInitialization) throws {
    let directory = try makeReadinessFailureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try initializationFailureExecutable(event: scenario.event, in: directory)
    let events = StreamEventCollector()
    let child = try ProbeManagedProcessGroup.launch(
        executable: executable,
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
        workingDirectory: directory,
        standardOutputHandler: events.append,
        standardOutputEOF: events.markEOF
    )
    defer { child.cleanup() }
    try submitFirstFixtureInput(to: child)
    _ = try #require(events.waitForReplay(uuid: "first-fixture-input", timeout: 2))
    let identifiers = try String(contentsOf: directory.appending(path: "tree-receipt.txt"), encoding: .utf8)
        .split(whereSeparator: \.isWhitespace)
        .compactMap { Int32($0) }
    #expect(identifiers.count == 2)
    #expect(identifiers.first == child.processGroupID)
    #expect(ProbeManagedProcessGroup.groupExists(child.processGroupID))

    do {
        _ = try ClaudeLiveProbe.sendSecondProbeInput(
            uuid: "second-fixture-input",
            events: events,
            to: child
        )
        Issue.record("Incompatible initialization must reject before submitting ACK-2")
    } catch ProbeFailure.readinessRejected(let reasons) {
        #expect(reasons.contains(scenario.rejectionReason))
    }

    let receipt = try String(contentsOf: directory.appending(path: "input-receipt.txt"), encoding: .utf8)
    #expect(receipt.split(whereSeparator: \.isNewline).map(String.init) == ["first-fixture-input"])
    #expect(events.eventCount(type: "user", uuid: "second-fixture-input") == 0)
    #expect(!ProbeManagedProcessGroup.groupExists(child.processGroupID))
    for identifier in identifiers {
        #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifier, timeout: 1))
    }
}

@Test("Accepted inert initialization allows ACK-2 before the first result")
func acceptedInitializationAllowsSecondInput() throws {
    let directory = try makeReadinessFailureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try initializationFailureExecutable(event: acceptedInitializationEvent, in: directory)
    let events = StreamEventCollector()
    let child = try ProbeManagedProcessGroup.launch(
        executable: executable,
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
        workingDirectory: directory,
        standardOutputHandler: events.append,
        standardOutputEOF: events.markEOF
    )
    defer { child.cleanup() }
    try submitFirstFixtureInput(to: child)
    _ = try #require(events.waitForReplay(uuid: "first-fixture-input", timeout: 2))

    #expect(try ClaudeLiveProbe.sendSecondProbeInput(uuid: "second-fixture-input", events: events, to: child))
    _ = try #require(events.waitForReplay(uuid: "second-fixture-input", timeout: 2))
    let receipt = try String(contentsOf: directory.appending(path: "input-receipt.txt"), encoding: .utf8)
    #expect(receipt.split(whereSeparator: \.isNewline).map(String.init) == ["first-fixture-input", "second-fixture-input"])
    #expect(child.cleanup(gracefulTimeout: 0, terminateTimeout: 0.5, killTimeout: 1).processGroupGone)
}
