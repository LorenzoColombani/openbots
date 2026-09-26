import Darwin
import Foundation
import Testing
@testable import ClaudeRuntimeProbeCore

private final class WriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func record(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedError != nil
    }
}

private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/runtime-mechanics.sh")
}

private func makeTemporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appending(path: "OpenBotsRuntimeFixture-\(UUID().uuidString).noindex", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

private func fixtureMessage(uuid: String, text: String = "fixture") throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: [
            "type": "user",
            "uuid": uuid,
            "message": ["role": "user", "content": text]
        ],
        options: [.sortedKeys]
    )
    data.append(0x0a)
    return data
}

private func launchFixture(
    _ mode: String,
    in directory: URL,
    extraArguments: [String] = [],
    events: StreamEventCollector? = nil,
    output: DataCollector? = nil,
    errors: DataCollector? = nil
) throws -> ProbeManagedProcessGroup {
    try ProbeManagedProcessGroup.launch(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [fixtureURL().path, mode] + extraArguments,
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
        workingDirectory: directory,
        standardOutputHandler: { data in
            events?.append(data)
            output?.append(data)
        },
        standardOutputEOF: { events?.markEOF() },
        standardErrorHandler: { errors?.append($0) }
    )
}

private func waitForText(
    _ collector: DataCollector,
    containing needle: String,
    timeout: TimeInterval = 2
) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let text = String(decoding: collector.snapshot(), as: UTF8.self)
        if text.contains(needle) { return text }
        usleep(10_000)
    } while Date() < deadline
    return nil
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 2) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        usleep(10_000)
    } while Date() < deadline
    return nil
}

private func processIDs(in text: String) -> (pid_t, pid_t)? {
    let fields = text
        .split(whereSeparator: { $0 == " " || $0 == "\n" })
        .compactMap { Int32($0) }
    guard fields.count >= 2 else { return nil }
    return (fields[0], fields[1])
}

@Test("Two steers receive ordered replay acknowledgements in one process and session")
func deterministicLiveSteeringFixture() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let events = StreamEventCollector()
    let child = try launchFixture("stream", in: directory, events: events)
    defer { child.cleanup() }

    #expect(child.processID == child.processGroupID)
    #expect(getpgid(child.processID) == child.processGroupID)
    let firstUUID = UUID().uuidString.lowercased()
    let secondUUID = UUID().uuidString.lowercased()

    #expect(throws: ProbeFailure.self) {
        try child.write(Data(), timeout: 1)
    }
    #expect(ProbeManagedProcessGroup.groupExists(child.processGroupID))

    try child.write(try fixtureMessage(uuid: firstUUID, text: "first"), timeout: 1)
    let firstReplay = events.waitForReplay(uuid: firstUUID, timeout: 2)
    #expect(firstReplay?["session_id"] as? String == "fixture-session")
    #expect(events.resultCount() == 0)

    try child.write(try fixtureMessage(uuid: secondUUID, text: "second"), timeout: 1)
    let secondReplay = events.waitForReplay(uuid: secondUUID, timeout: 2)
    #expect(secondReplay?["session_id"] as? String == "fixture-session")
    #expect(events.waitForResultCount(2, timeout: 2))
    #expect(events.resultTexts() == ["ACK-1", "ACK-2"])
    #expect(events.eventCount(type: "user", uuid: firstUUID) == 1)
    #expect(events.eventCount(type: "user", uuid: secondUUID) == 1)

    child.closeInput()
    let exit = child.wait(timeout: 2)
    let cleanup = child.cleanup()
    #expect(exit?.reason == .exit)
    #expect(exit?.status == 0)
    #expect(cleanup.processGroupGone)
}

@Test("A final result racing stdout EOF is consumed exactly once")
func resultEOFRace() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let events = StreamEventCollector()
    let child = try launchFixture("result-eof", in: directory, events: events)
    defer { child.cleanup() }
    let uuid = UUID().uuidString.lowercased()

    try child.write(try fixtureMessage(uuid: uuid), timeout: 1)
    child.closeInput()
    let exit = child.wait(timeout: 2)
    let cleanup = child.cleanup()

    #expect(exit?.reason == .exit)
    #expect(exit?.status == 0)
    #expect(cleanup.processGroupGone)
    #expect(events.waitForResultCount(1, timeout: 0.1))
    #expect(events.resultTexts() == ["ACK-EOF"])
    #expect(events.eventCount(type: "result") == 1)
    #expect(events.eventCount(type: "user", uuid: uuid) == 1)
    events.markEOF()
    #expect(events.eventCount(type: "result") == 1)
}

@Test("A stopped reader bounds input and cleanup removes its process tree")
func stoppedReaderTimeoutAndCleanup() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = DataCollector()
    let child = try launchFixture("stop-reading", in: directory, output: output)
    defer { child.cleanup() }
    let tree = try #require(waitForText(output, containing: "TREE"))
    let identifiers = try #require(processIDs(in: tree))

    #expect(identifiers.0 == child.processID)
    #expect(getpgid(identifiers.0) == child.processGroupID)
    #expect(getpgid(identifiers.1) == child.processGroupID)
    let payload = Data(repeating: 0x78, count: NonblockingLineWriter.maximumLineBytes)
    #expect(throws: ProbeFailure.self) {
        try child.write(payload, timeout: 0.05)
    }
    #expect(!ProbeManagedProcessGroup.groupExists(child.processGroupID))

    let cleanup = child.cleanup(gracefulTimeout: 0, terminateTimeout: 0.25, killTimeout: 1)
    #expect(cleanup.processGroupGone)
    #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifiers.0, timeout: 1))
    #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifiers.1, timeout: 1))
}

@Test("Teardown never waits on the blocked-write lifecycle lock")
func teardownWhileWriterIsBackpressured() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = DataCollector()
    let child = try launchFixture("stop-reading", in: directory, output: output)
    defer { child.cleanup() }
    _ = try #require(waitForText(output, containing: "TREE"))
    let completion = DispatchSemaphore(value: 0)
    let outcome = WriteOutcome()
    let payload = Data(repeating: 0x79, count: NonblockingLineWriter.maximumLineBytes)

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try child.write(payload, timeout: 5)
        } catch {
            outcome.record(error)
        }
        completion.signal()
    }
    usleep(50_000)
    let started = DispatchTime.now().uptimeNanoseconds
    let cleanup = child.cleanup(gracefulTimeout: 0, terminateTimeout: 0.25, killTimeout: 1)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

    #expect(completion.wait(timeout: .now() + 1) == .success)
    #expect(outcome.failed)
    #expect(elapsed < 1.5)
    #expect(cleanup.processGroupGone)
}

@Test("Teardown after acknowledgement preserves one input and removes descendants")
func teardownRacePreservesInputExactlyOnce() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receiptURL = directory.appending(path: "input-receipt.txt")
    let events = StreamEventCollector()
    let errors = DataCollector()
    let child = try launchFixture(
        "teardown-race",
        in: directory,
        extraArguments: [receiptURL.path],
        events: events,
        errors: errors
    )
    defer { child.cleanup() }
    let uuid = UUID().uuidString.lowercased()

    try child.write(try fixtureMessage(uuid: uuid), timeout: 1)
    _ = try #require(events.waitForReplay(uuid: uuid, timeout: 2))
    let tree = try #require(waitForText(errors, containing: "TREE"))
    let identifiers = try #require(processIDs(in: tree))
    let cleanup = child.cleanup(gracefulTimeout: 0, terminateTimeout: 0.25, killTimeout: 1)
    let receipt = try #require(waitForFile(receiptURL))
    let lines = receipt.split(whereSeparator: \.isNewline).map(String.init)

    #expect(lines == [uuid])
    #expect(events.eventCount(type: "user", uuid: uuid) == 1)
    #expect(cleanup.processGroupGone)
    #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifiers.0, timeout: 1))
    #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifiers.1, timeout: 1))
}

@Test("A capture timeout cleans the child and grandchild process group")
func captureTimeoutCleansProcessTree() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receiptURL = directory.appending(path: "tree-receipt.txt")

    #expect(throws: ProbeFailure.self) {
        _ = try BoundedProcessRunner.capture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [fixtureURL().path, "process-tree", receiptURL.path],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
            workingDirectory: directory,
            timeout: 0.1
        )
    }

    let receipt = try #require(waitForFile(receiptURL))
    let identifiers = try #require(processIDs(in: receipt))
    #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifiers.0, timeout: 1))
    #expect(ProbeManagedProcessGroup.waitForProcessToDisappear(identifiers.1, timeout: 1))
}

@Test("A short-lived readiness fixture is captured without live Claude access")
func shortLivedReadinessCapture() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = try BoundedProcessRunner.capture(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            fixtureURL()
                .deletingLastPathComponent()
                .appending(path: "fake-claude.sh")
                .path,
            "--version"
        ],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C"],
        workingDirectory: directory,
        timeout: 1
    )

    #expect(capture.terminationReason == .exit)
    #expect(capture.terminationStatus == 0)
    #expect(String(decoding: capture.standardOutput, as: UTF8.self).contains("Claude Code"))
    #expect(capture.standardError.isEmpty)
}

@Test("Input rejects empty, oversized, and non-finite payload contracts")
func boundedInputContract() {
    #expect(throws: ProbeFailure.self) {
        try NonblockingLineWriter.write(Data(), to: -1, timeout: 0.01)
    }
    #expect(throws: ProbeFailure.self) {
        try NonblockingLineWriter.write(
            Data(repeating: 0, count: NonblockingLineWriter.maximumLineBytes + 1),
            to: -1,
            timeout: 0.01
        )
    }
    #expect(throws: ProbeFailure.self) {
        try NonblockingLineWriter.write(Data([0x0a]), to: -1, timeout: .infinity)
    }
    #expect(throws: ProbeFailure.self) {
        try NonblockingLineWriter.write(Data([0x0a]), to: -1, timeout: -0.01)
    }
}
