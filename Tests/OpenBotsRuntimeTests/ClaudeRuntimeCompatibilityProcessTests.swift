import Darwin
import Foundation
import Testing
@testable import OpenBotsRuntime

/// Serial process lane. These exercise the real production transport with inert
/// executables; they never constitute a managed-runtime promotion receipt.
@Suite("Compatibility production transport", .serialized)
struct ClaudeRuntimeCompatibilityProcessTests {
    @Test("The shipped inert fixture records actual allow, deny and stalled executions without user content")
    func shippedFixtureLedger() async throws {
        let node = try #require(["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }))
        let root = URL(fileURLWithPath: "/private/tmp/compatibility-" + UUID().uuidString)
        let directory = root.appendingPathComponent("case-tools")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OpenBotsServices/Resources/claude-runtime-compatibility.js")
        let entry = directory.appendingPathComponent("claude-runtime-compatibility.js")
        try FileManager.default.copyItem(at: source, to: entry)
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node).resolvingSymlinksInPath()
        process.arguments = [entry.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        process.currentDirectoryURL = root
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let frames: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "allow", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "deny", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "stall", "arguments": [:]]]
        ]
        for frame in frames {
            var data = try JSONSerialization.data(withJSONObject: frame); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try input.fileHandleForWriting.close()
        for _ in 0..<500 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
        guard !process.isRunning else { return }
        #expect(process.terminationStatus == 0)
        let response = output.fileHandleForReading.readDataToEndOfFile()
        let responses = try response.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        #expect(responses.compactMap { $0?["id"] as? Int } == [1, 2, 3, 4])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ledger-") }
        #expect(files.count == 1)
        let ledger = try Data(contentsOf: #require(files.first))
        let records = try ledger.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        #expect(records.compactMap { $0?["event"] as? String } == ["started", "initialized", "listed",
            "executed_allow", "executed_deny", "executed_stall", "stdin_closed"])
        #expect(records.allSatisfy { Set($0?.keys.map { $0 } ?? []) == ["event", "pid", "parentPID"] })
    }

    @Test("Strict native parser refuses malformed compatibility initialization and replay",
          arguments: ["initialization", "replay"])
    func malformed(_ kind: String) async throws {
        let template = try textOnlyTestRequest()
        let output = try textOnlyTestInit(template, override: kind == "initialization" ? ["apiKeySource": "environment"] : [:])
            + textOnlyTestReplay(template, override: kind == "replay" ? ["uuid": UUID().uuidString] : [:])
            + textOnlyTestResult(template)
        let fixture = try ClaudeConnectionFixture(body: """
        IFS= read -r line
        \(emit(output))
        """)
        defer { fixture.remove() }
        let request = try textOnlyTestRequest(target: fixture.target)
        let result = await NativeClaudeTextOnlyRunner(testTimeout: 10).run(request: request) { _ in }
        #expect(result == .failed(kind == "initialization" ? .unsafeInitialization : .invalidStream))
    }

    @Test("A native cancelled compatibility turn awaits the CLI and its inert child exit")
    func cancellationReapsChildren() async throws {
        let fixture = try ClaudeConnectionFixture(body: """
        /bin/sleep 60 &
        child=$!
        printf '%s %s' "$$" "$child" > inert-pids
        wait "$child"
        """)
        defer { fixture.remove() }
        let request = try textOnlyTestRequest(target: fixture.target)
        let task = Task { await NativeClaudeTextOnlyRunner(testTimeout: 15).run(request: request) { _ in } }
        var recorded: [Int32] = []
        for _ in 0..<500 {
            if let text = try? fixture.readWorkingFile("inert-pids") {
                recorded = text.split(separator: " ").compactMap { Int32($0) }
                if recorded.count == 2 { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(recorded.count == 2)
        // A killed descendant can briefly remain a zombie before launchd reaps it.
        for _ in 0..<200 {
            if recorded.allSatisfy({ Darwin.kill($0, 0) != 0 && errno == ESRCH }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorded.allSatisfy { Darwin.kill($0, 0) != 0 && errno == ESRCH })
    }

    @Test("A native stalled compatibility turn times out and reaps its child")
    func timeoutReapsChildren() async throws {
        let fixture = try ClaudeConnectionFixture(body: """
        /bin/sleep 60 &
        child=$!
        printf '%s %s' "$$" "$child" > inert-pids
        wait "$child"
        """)
        defer { fixture.remove() }
        let request = try textOnlyTestRequest(target: fixture.target)
        let result = await NativeClaudeTextOnlyRunner(testTimeout: 1).run(request: request) { _ in }
        #expect(result == .failed(.timedOut))
        let pids = try fixture.readWorkingFile("inert-pids").split(separator: " ").compactMap { Int32($0) }
        for _ in 0..<200 {
            if pids.allSatisfy({ Darwin.kill($0, 0) != 0 && errno == ESRCH }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pids.count == 2)
        #expect(pids.allSatisfy { Darwin.kill($0, 0) != 0 && errno == ESRCH })
    }

    private func emit(_ data: Data) -> String {
        "/bin/cat <<'OPENBOTS_COMPATIBILITY_OFFLINE'\n"
            + String(decoding: data, as: UTF8.self) + "OPENBOTS_COMPATIBILITY_OFFLINE"
    }
}
