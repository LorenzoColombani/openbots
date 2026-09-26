import Darwin
import Foundation
import Testing
@testable import ClaudeRuntimeProbeCore

@Suite("Probe-only managed JSON record session")
struct ProbeToolSessionTests {
    @Test("One object becomes one compact line and input close drains stdout through EOF")
    func recordRoundtrip() throws {
        let directory = try toolSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = ToolSessionOutput()
        let errors = DataCollector()
        let session = try toolSessionCat(in: directory, output: output, errors: errors)
        defer { session.stop() }
        #expect(session.processID == session.processGroupID)
        #expect(getpgid(session.processID) == session.processGroupID)
        try session.sendRecord(Data("  {\n  \"seq\": 1, \"message\": \"first\\nsecond\"\n}\n".utf8), timeout: 1)
        try session.sendRecord(Data("{\"seq\":2}".utf8), timeout: 1)
        session.closeInput()
        #expect(session.waitForExit(timeout: 2))
        let cleanup = session.stop()
        #expect(cleanup.exited && cleanup.status == 0 && cleanup.processGroupGone)
        #expect(output.snapshot() == Data("{\"message\":\"first\\nsecond\",\"seq\":1}\n{\"seq\":2}\n".utf8))
        #expect(output.eofCount == 1)
        #expect(errors.snapshot().isEmpty)
        #expect(session.stop() == cleanup)
        #expect(throws: ProbeFailure.self) { try session.sendRecord(Data("{}".utf8), timeout: 1) }
    }

    @Test("Invalid shapes, multiple objects, size and deadline contracts write nothing and leave valid input usable")
    func invalidRecords() throws {
        let directory = try toolSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = ToolSessionOutput()
        let session = try toolSessionCat(in: directory, output: output)
        defer { session.stop() }
        for record in [Data(), Data("[]".utf8), Data("[{}]".utf8), Data("null".utf8), Data("1".utf8),
                       Data("{}\n{}".utf8), Data("{} {}".utf8), Data("{broken}".utf8), Data([0xff]),
                       Data(repeating: 0x20, count: ProbeToolSession.maximumRecordBytes + 1)] {
            #expect(throws: ProbeFailure.self) { try session.sendRecord(record, timeout: 1) }
        }
        let noRoomForLF = Data(("{\"x\":\"" + String(repeating: "x", count: ProbeToolSession.maximumRecordBytes - 8) + "\"}").utf8)
        #expect(noRoomForLF.count == ProbeToolSession.maximumRecordBytes)
        #expect(throws: ProbeFailure.self) { try session.sendRecord(noRoomForLF, timeout: 1) }
        for timeout in [-1.0, .infinity, .nan, ProbeToolSession.maximumWriteTimeout + 1] {
            #expect(throws: ProbeFailure.self) { try session.sendRecord(Data("{}".utf8), timeout: timeout) }
        }
        try session.sendRecord(Data("{\"valid\":true}\n".utf8), timeout: 1)
        session.closeInput()
        #expect(session.waitForExit(timeout: 2))
        #expect(session.stop().processGroupGone)
        #expect(output.snapshot() == Data("{\"valid\":true}\n".utf8))
    }

    @Test("Concurrent records larger than pipe atomicity remain whole and appear exactly once")
    func concurrentRecordsAreWhole() throws {
        let directory = try toolSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = ToolSessionOutput()
        let session = try toolSessionCat(in: directory, output: output)
        defer { session.stop() }
        let failures = ToolSessionWriteOutcomes()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                let object: [String: Any] = ["id": index, "payload": String(repeating: String(index % 10), count: 65_536)]
                try session.sendRecord(JSONSerialization.data(withJSONObject: object), timeout: 5)
            } catch { failures.recordFailure() }
        }
        session.closeInput()
        #expect(session.waitForExit(timeout: 2))
        #expect(session.stop().processGroupGone)
        #expect(failures.count == 0)
        let bytes = output.snapshot()
        #expect(bytes.last == 0x0a)
        let lines = bytes.split(separator: 0x0a)
        #expect(lines.count == 16)
        var identifiers: Set<Int> = []
        for line in lines {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            let index = try #require(object["id"] as? Int)
            #expect(identifiers.insert(index).inserted)
            #expect(object["payload"] as? String == String(repeating: String(index % 10), count: 65_536))
        }
        #expect(identifiers == Set(0..<16))
    }

    @Test("Stop interrupts a backpressured writer and queued sends without waiting for their writer deadline")
    func stopUnderBackpressure() throws {
        let directory = try toolSessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/runtime-mechanics.sh")
        let output = ToolSessionOutput()
        let session = try ProbeToolSession.launch(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [fixture.path, "stop-reading"], environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
            workingDirectory: directory, standardOutputHandler: { output.append($0) },
            standardOutputEOF: { output.markEOF() }, standardErrorHandler: { _ in })
        defer { session.stop() }
        #expect(output.waitForText("TREE", timeout: 2))
        let payload = try JSONSerialization.data(withJSONObject: ["payload": String(repeating: "x", count: 512 * 1_024)])
        let completed = DispatchSemaphore(value: 0)
        let failures = ToolSessionWriteOutcomes()
        DispatchQueue.global(qos: .userInitiated).async {
            do { try session.sendRecord(payload, timeout: 8) } catch { failures.recordFailure() }
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 0.05) == .timedOut)
        // Queue timeout is local to this unsent record and cannot serialize Stop
        // behind the first record's long backpressure deadline.
        let queueStart = ProcessInfo.processInfo.systemUptime
        #expect(throws: ProbeFailure.self) { try session.sendRecord(Data("{}".utf8), timeout: 0.02) }
        #expect(ProcessInfo.processInfo.systemUptime - queueStart < 0.5)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try session.sendRecord(Data("{\"queued\":true}".utf8), timeout: 8) } catch { failures.recordFailure() }
            completed.signal()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let cleanup = session.stop()
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(cleanup.exited && cleanup.processGroupGone)
        #expect(cleanup.sentTerminate || cleanup.sentKill)
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(failures.count == 2)
        #expect(throws: ProbeFailure.self) { try session.sendRecord(Data("{\"late\":true}".utf8), timeout: 1) }
    }
}

private func toolSessionDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp/OpenBotsToolSession-\(UUID()).noindex", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

private func toolSessionCat(in directory: URL, output: ToolSessionOutput, errors: DataCollector = DataCollector()) throws -> ProbeToolSession {
    try ProbeToolSession.launch(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C"], workingDirectory: directory,
        standardOutputHandler: { output.append($0) }, standardOutputEOF: { output.markEOF() },
        standardErrorHandler: { errors.append($0) })
}

private final class ToolSessionOutput: @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()
    private var eof = 0
    func append(_ bytes: Data) { condition.lock(); data.append(bytes); condition.broadcast(); condition.unlock() }
    func markEOF() { condition.lock(); eof += 1; condition.broadcast(); condition.unlock() }
    func snapshot() -> Data { condition.lock(); defer { condition.unlock() }; return data }
    var eofCount: Int { condition.lock(); defer { condition.unlock() }; return eof }
    func waitForText(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !String(decoding: data, as: UTF8.self).contains(text) {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

private final class ToolSessionWriteOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    func recordFailure() { lock.lock(); failures += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return failures }
}
