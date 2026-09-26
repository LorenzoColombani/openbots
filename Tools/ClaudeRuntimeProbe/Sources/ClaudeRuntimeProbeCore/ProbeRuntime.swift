import Darwin
import Foundation

public struct ProcessCapture: Sendable {
    public let terminationStatus: Int32
    public let terminationReason: Process.TerminationReason
    public let standardOutput: Data
    public let standardError: Data
}

public enum BoundedProcessRunner {
    public static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> ProcessCapture {
        let standardOutput = DataCollector()
        let standardError = DataCollector()
        let process = try ProbeManagedProcessGroup.launch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardOutputHandler: standardOutput.append,
            standardErrorHandler: standardError.append
        )
        defer { process.cleanup() }
        process.closeInput()

        guard let exit = process.wait(timeout: timeout) else {
            _ = process.cleanup(gracefulTimeout: 0, terminateTimeout: 0.25, killTimeout: 1)
            throw ProbeFailure.processTimeout(arguments.first ?? executable.lastPathComponent)
        }
        _ = process.cleanup()

        return ProcessCapture(
            terminationStatus: exit.status,
            terminationReason: exit.reason == .exit ? .exit : .uncaughtSignal,
            standardOutput: standardOutput.snapshot(),
            standardError: standardError.snapshot()
        )
    }
}

public enum ClaudeReadinessProbe {
    public static func inspect(
        claudeExecutable: URL,
        temporaryDirectory: URL,
        configurationDirectory: ValidatedClaudeConfigurationDirectory,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ReadinessReport {
        let configurationDirectory = try ClaudeConfigurationPolicy.revalidate(
            configurationDirectory
        )
        let childEnvironment = try ChildEnvironmentPolicy.makeChildEnvironment(
            parent: parentEnvironment,
            claudeExecutable: claudeExecutable,
            temporaryDirectory: temporaryDirectory,
            configurationDirectory: configurationDirectory.url
        )

        let versionCapture = try BoundedProcessRunner.capture(
            executable: claudeExecutable,
            arguments: ["--version"],
            environment: childEnvironment,
            workingDirectory: temporaryDirectory,
            timeout: 10
        )
        guard versionCapture.terminationStatus == 0 else {
            throw ProbeFailure.processLaunch("Claude --version exited \(versionCapture.terminationStatus)")
        }

        let helpCapture = try BoundedProcessRunner.capture(
            executable: claudeExecutable,
            arguments: ["--help"],
            environment: childEnvironment,
            workingDirectory: temporaryDirectory,
            timeout: 10
        )
        guard helpCapture.terminationStatus == 0 else {
            throw ProbeFailure.processLaunch("Claude --help exited \(helpCapture.terminationStatus)")
        }

        let authCapture = try BoundedProcessRunner.capture(
            executable: claudeExecutable,
            arguments: ["auth", "status", "--json"],
            environment: childEnvironment,
            workingDirectory: temporaryDirectory,
            timeout: 15
        )
        guard authCapture.terminationStatus == 0 else {
            throw ProbeFailure.processLaunch("Claude auth status exited \(authCapture.terminationStatus)")
        }

        let auth = try decodeAuthentication(authCapture.standardOutput)
        let version = String(decoding: versionCapture.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let help = String(decoding: helpCapture.standardOutput, as: UTF8.self)

        return ReadinessReport(
            executable: claudeExecutable.path,
            version: version,
            authentication: auth,
            flags: FlagSupport(help: help),
            providerVariablesPresentInParent: ChildEnvironmentPolicy.providerVariableNames(in: parentEnvironment),
            providerVariablesPresentInChild: ChildEnvironmentPolicy.providerVariableNames(in: childEnvironment),
            childEnvironmentKeys: childEnvironment.keys.sorted()
        )
    }

    private static func decodeAuthentication(_ data: Data) throws -> AuthenticationStatus {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let loggedIn = object["loggedIn"] as? Bool,
            let authMethod = object["authMethod"] as? String
        else {
            throw ProbeFailure.invalidAuthenticationOutput
        }

        return AuthenticationStatus(
            loggedIn: loggedIn,
            authMethod: authMethod,
            apiProvider: object["apiProvider"] as? String,
            subscriptionType: object["subscriptionType"] as? String
        )
    }
}

public struct FileStamp: Equatable, Sendable {
    public let mode: UInt16
    public let size: Int64
    public let modificationNanoseconds: Int64
    public let inode: UInt64
}

public struct WriteSetDiff: Codable, Equatable, Sendable {
    public let created: [String]
    public let modified: [String]
    public let removed: [String]

    public var isEmpty: Bool { created.isEmpty && modified.isEmpty && removed.isEmpty }
}

public enum FileSnapshotter {
    public static func snapshot(roots: [URL]) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        let fileManager = FileManager.default

        for root in roots {
            addStamp(for: root, to: &result)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                addStamp(for: url, to: &result)
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator.skipDescendants()
                }
            }
        }
        return result
    }

    public static func diff(
        before: [String: FileStamp],
        after: [String: FileStamp],
        redactions: [(prefix: String, replacement: String)]
    ) -> WriteSetDiff {
        let beforeKeys = Set(before.keys)
        let afterKeys = Set(after.keys)
        let created = afterKeys.subtracting(beforeKeys)
        let removed = beforeKeys.subtracting(afterKeys)
        let modified = beforeKeys.intersection(afterKeys).filter { before[$0] != after[$0] }

        func redact(_ path: String) -> String {
            for redaction in redactions.sorted(by: { $0.prefix.count > $1.prefix.count }) {
                if path == redaction.prefix {
                    return redaction.replacement
                }
                if path.hasPrefix(redaction.prefix + "/") {
                    return redaction.replacement + path.dropFirst(redaction.prefix.count)
                }
            }
            return path
        }

        return WriteSetDiff(
            created: created.map(redact).sorted(),
            modified: modified.map(redact).sorted(),
            removed: removed.map(redact).sorted()
        )
    }

    private static func addStamp(for url: URL, to result: inout [String: FileStamp]) {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return }
        let nanoseconds = Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(metadata.st_mtimespec.tv_nsec)
        result[url.path] = FileStamp(
            mode: UInt16(metadata.st_mode & 0o7777),
            size: Int64(metadata.st_size),
            modificationNanoseconds: nanoseconds,
            inode: UInt64(metadata.st_ino)
        )
    }
}

final class StreamEventCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = Data()
    private var events: [[String: Any]] = []
    private var invalidLineCount = 0
    private var reachedEOF = false

    func append(_ data: Data) {
        condition.lock()
        guard !reachedEOF else {
            condition.unlock()
            return
        }
        pending.append(data)
        consumeCompleteLines()
        condition.broadcast()
        condition.unlock()
    }

    func markEOF() {
        condition.lock()
        guard !reachedEOF else {
            condition.unlock()
            return
        }
        // A process may write its final JSON value and close stdout before the
        // trailing newline reaches the pipe. Consume that final value once;
        // repeated EOF notifications are idempotent.
        if !pending.isEmpty {
            consumeLine(pending)
            pending.removeAll(keepingCapacity: false)
        }
        reachedEOF = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForReplay(uuid: String, timeout: TimeInterval) -> [String: Any]? {
        wait(timeout: timeout) { events in
            events.first(where: { event in
                (event["type"] as? String) == "user" && (event["uuid"] as? String) == uuid
            })
        }
    }

    func waitForResultCount(_ count: Int, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { events in
            events.filter { ($0["type"] as? String) == "result" }.count >= count ? true : nil
        } ?? false
    }

    func resultCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return events.filter { ($0["type"] as? String) == "result" }.count
    }

    func resultTexts() -> [String] {
        condition.lock()
        defer { condition.unlock() }
        return events.compactMap { event in
            guard (event["type"] as? String) == "result" else { return nil }
            return event["result"] as? String
        }
    }

    func eventCount(type: String, uuid: String? = nil) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return events.filter { event in
            guard (event["type"] as? String) == type else { return false }
            guard let uuid else { return true }
            return (event["uuid"] as? String) == uuid
        }.count
    }

    func initializationReceipt() -> RuntimeInitializationReceipt? {
        condition.lock()
        defer { condition.unlock() }
        guard let event = events.first(where: {
            ($0["type"] as? String) == "system" && ($0["subtype"] as? String) == "init"
        }) else { return nil }

        return RuntimeInitializationReceipt(
            apiKeySource: event["apiKeySource"] as? String,
            sessionID: event["session_id"] as? String,
            toolCount: (event["tools"] as? [Any])?.count,
            mcpServerCount: (event["mcp_servers"] as? [Any])?.count,
            permissionMode: event["permissionMode"] as? String,
            claudeCodeVersion: event["claude_code_version"] as? String
        )
    }

    func streamSummary() -> (eventCount: Int, invalidLineCount: Int, reachedEOF: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (events.count, invalidLineCount, reachedEOF)
    }

    private func wait<T>(timeout: TimeInterval, find: ([[String: Any]]) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let value = find(events) { return value }
            if reachedEOF { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
    }


    private func consumeCompleteLines() {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            consumeLine(line)
        }
    }

    private func consumeLine<S: DataProtocol>(_ line: S) {
        guard !line.isEmpty else { return }
        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
            events.append(object)
        } else {
            invalidLineCount += 1
        }
    }
}

final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func byteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }


    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public struct ReplayReceipt: Codable, Equatable, Sendable {
    public let inputSequence: Int
    public let inputUUID: String
    public let replayUUID: String?
    public let sessionID: String?
    public let acknowledged: Bool
}

public struct RuntimeInitializationReceipt: Codable, Equatable, Sendable {
    public let apiKeySource: String?
    public let sessionID: String?
    public let toolCount: Int?
    public let mcpServerCount: Int?
    public let permissionMode: String?
    public let claudeCodeVersion: String?

    public var isSubscriptionOAuth: Bool {
        guard let source = apiKeySource?.lowercased() else { return false }
        // Current Claude Code emits `none` when no API key is in use, including
        // claude.ai OAuth. It describes `/login managed key` as an Anthropic
        // Console API key, so that value must fail the subscription-only gate.
        // Auth-status and child-environment checks separately narrow `none` to
        // first-party claude.ai Pro/Max with no bearer/cloud override. Unknown
        // future values must fail until the compatibility receipt is reviewed.
        return source == "none"
    }
}

public struct LiveProbeReport: Codable, Equatable, Sendable {
    public let readiness: ReadinessReport
    public let processID: Int32
    public let processGroupID: Int32
    public let receipts: [ReplayReceipt]
    public let runtimeInitialization: RuntimeInitializationReceipt?
    public let sessionCorrelationPassed: Bool
    public let secondInputSentBeforeFirstResult: Bool
    public let resultCount: Int
    public let ack1Observed: Bool
    public let ack2Observed: Bool
    public let ackResultsInOrder: Bool
    public let eventCount: Int
    public let invalidEventLineCount: Int
    public let stderrByteCount: Int
    public let terminationStatus: Int32
    public let terminationReason: String
    public let writeSet: WriteSetDiff
    public let accepted: Bool
    public let rejectionReasons: [String]
}

public enum ClaudeLiveProbe {
    public static func run(
        claudeExecutable: URL,
        probeRoot: URL,
        readiness: ReadinessReport,
        configurationDirectory: ValidatedClaudeConfigurationDirectory,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LiveProbeReport {
        guard configurationDirectory.permitsLiveClaude else {
            throw ProbeFailure.unsafeConfiguration(
                "live Claude requires the exact marker-owned preview CLI profile"
            )
        }
        let configurationDirectory = try ClaudeConfigurationPolicy.revalidate(
            configurationDirectory
        )
        guard readiness.accepted else {
            throw ProbeFailure.readinessRejected(readiness.rejectionReasons)
        }

        let root = try ProbePathPolicy.validateTemporaryNoIndexRoot(probeRoot)
        let fileManager = FileManager.default
        let temporaryDirectory = root.appending(path: "tmp", directoryHint: .isDirectory)
        let workingDirectory = root.appending(path: "work", directoryHint: .isDirectory)
        try createPrivateDirectory(root)
        try createPrivateDirectory(temporaryDirectory)
        try createPrivateDirectory(workingDirectory)

        let settingsURL = root.appending(path: "settings.json")
        let mcpURL = root.appending(path: "mcp.json")
        try writePrivateJSON([
            "permissions": ["defaultMode": "dontAsk"],
            "cleanupPeriodDays": 1
        ], to: settingsURL)
        try writePrivateJSON(["mcpServers": [:]], to: mcpURL)

        let childEnvironment = try ChildEnvironmentPolicy.makeChildEnvironment(
            parent: parentEnvironment,
            claudeExecutable: claudeExecutable,
            temporaryDirectory: temporaryDirectory,
            configurationDirectory: configurationDirectory.url
        )
        guard ChildEnvironmentPolicy.providerVariableNames(in: childEnvironment).isEmpty else {
            throw ProbeFailure.readinessRejected(["provider/API environment reached live child"])
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let watchedRoots = [
            home.appending(path: ".claude", directoryHint: .isDirectory),
            home.appending(path: ".claude.json"),
            home.appending(path: "Library/Caches/claude-cli-nodejs", directoryHint: .isDirectory),
            root
        ]
        let before = FileSnapshotter.snapshot(roots: watchedRoots)

        let events = StreamEventCollector()
        let errors = DataCollector()
        let sessionID = UUID().uuidString.lowercased()
        let arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--replay-user-messages",
            "--verbose",
            "--safe-mode",
            "--restricted",
            "--no-session-persistence",
            "--no-chrome",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", mcpURL.path,
            "--settings", settingsURL.path,
            "--setting-sources", "",
            "--permission-mode", "dontAsk",
            "--tools", "",
            "--effort", "low",
            "--session-id", sessionID,
            "--system-prompt", "You are an inert protocol probe. Never use tools. Follow each ACK-only request exactly."
        ]
        let process = try ProbeManagedProcessGroup.launch(
            executable: claudeExecutable,
            arguments: arguments,
            environment: childEnvironment,
            workingDirectory: workingDirectory,
            standardOutputHandler: events.append,
            standardOutputEOF: events.markEOF,
            standardErrorHandler: errors.append
        )
        defer { process.cleanup() }

        let processID = process.processID
        let processGroupID = process.processGroupID
        let firstUUID = UUID().uuidString.lowercased()
        let secondUUID = UUID().uuidString.lowercased()

        try writeUserMessage(
            uuid: firstUUID,
            text: "OpenBots runtime probe turn 1. Reply with exactly ACK-1 and nothing else.",
            to: process
        )
        let firstReplay = events.waitForReplay(uuid: firstUUID, timeout: 20)
        guard firstReplay != nil else {
            throw ProbeFailure.streamTimeout("first replay acknowledgement")
        }

        let secondBeforeResult = try sendSecondProbeInput(
            uuid: secondUUID,
            events: events,
            to: process
        )
        let secondReplay = events.waitForReplay(uuid: secondUUID, timeout: 20)
        guard secondReplay != nil else {
            throw ProbeFailure.streamTimeout("second replay acknowledgement")
        }

        let receivedTwoResults = events.waitForResultCount(2, timeout: 90)
        process.closeInput()
        let exit = process.wait(timeout: 15)
        let cleanup = process.cleanup(gracefulTimeout: 0, terminateTimeout: 0.5, killTimeout: 1)
        let exitedCleanly = exit?.reason == .exit && exit?.status == 0 && cleanup.processGroupGone
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

        let firstReceipt = receipt(sequence: 1, inputUUID: firstUUID, event: firstReplay)
        let secondReceipt = receipt(sequence: 2, inputUUID: secondUUID, event: secondReplay)
        let initialization = events.initializationReceipt()
        let resultTexts = events.resultTexts()
        let normalizedResultTexts = resultTexts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let receiptSessionIDs = Set([firstReceipt.sessionID, secondReceipt.sessionID].compactMap { $0 })
        let sessionCorrelationPassed = receiptSessionIDs.count == 1
            && initialization?.sessionID == receiptSessionIDs.first
        let ackResultsInOrder = Array(normalizedResultTexts.prefix(2)) == ["ACK-1", "ACK-2"]
        let summary = events.streamSummary()

        var rejectionReasons: [String] = []
        if !receivedTwoResults { rejectionReasons.append("did not observe two result events before timeout") }
        if !firstReceipt.acknowledged || !secondReceipt.acknowledged {
            rejectionReasons.append("replayed UUID did not correlate to each input UUID")
        }
        rejectionReasons.append(contentsOf: initializationRejectionReasons(initialization))
        if !sessionCorrelationPassed {
            rejectionReasons.append("runtime init and both replay receipts did not share one session ID")
        }
        if !ackResultsInOrder {
            rejectionReasons.append("did not observe exact ACK-1 then ACK-2 result order")
        }
        if !secondBeforeResult {
            rejectionReasons.append("second input was not proven to enter before the first result")
        }
        if summary.invalidLineCount != 0 {
            rejectionReasons.append("Claude emitted non-JSON stdout lines")
        }
        if !exitedCleanly {
            rejectionReasons.append("Claude did not exit cleanly after stdin EOF or left a process-group member behind")
        }

        return LiveProbeReport(
            readiness: readiness,
            processID: processID,
            processGroupID: processGroupID,
            receipts: [firstReceipt, secondReceipt],
            runtimeInitialization: initialization,
            sessionCorrelationPassed: sessionCorrelationPassed,
            secondInputSentBeforeFirstResult: secondBeforeResult,
            resultCount: events.resultCount(),
            ack1Observed: normalizedResultTexts.contains("ACK-1"),
            ack2Observed: normalizedResultTexts.contains("ACK-2"),
            ackResultsInOrder: ackResultsInOrder,
            eventCount: summary.eventCount,
            invalidEventLineCount: summary.invalidLineCount,
            stderrByteCount: errors.byteCount(),
            terminationStatus: exit?.status ?? cleanup.exit?.status ?? -1,
            terminationReason: (exit ?? cleanup.exit)?.reason.rawValue ?? "timeout",
            writeSet: writeSet,
            accepted: rejectionReasons.isEmpty,
            rejectionReasons: rejectionReasons
        )
    }

    /// The first replay is not authority to submit another request. Confirm the
    /// runtime's auth and inert-tool receipt before crossing that boundary.
    /// Kept internal so the same gate can be exercised with model-free children
    /// without weakening the public entrypoint's preview-profile requirement.
    static func sendSecondProbeInput(
        uuid: String,
        events: StreamEventCollector,
        to process: ProbeManagedProcessGroup
    ) throws -> Bool {
        let rejectionReasons = initializationRejectionReasons(events.initializationReceipt())
        guard rejectionReasons.isEmpty else {
            _ = process.cleanup(gracefulTimeout: 0, terminateTimeout: 0.5, killTimeout: 1)
            throw ProbeFailure.readinessRejected(rejectionReasons)
        }

        let beforeFirstResult = events.resultCount() == 0
        try writeUserMessage(
            uuid: uuid,
            text: "OpenBots runtime probe turn 2. Reply with exactly ACK-2 and nothing else.",
            to: process
        )
        return beforeFirstResult
    }

    private static func initializationRejectionReasons(
        _ initialization: RuntimeInitializationReceipt?
    ) -> [String] {
        var reasons: [String] = []
        if initialization?.isSubscriptionOAuth != true {
            reasons.append("runtime init did not confirm OAuth rather than API/config key auth")
        }
        if initialization?.toolCount != 0 {
            reasons.append("runtime init advertised tools despite the empty tool set")
        }
        if initialization?.mcpServerCount != 0 {
            reasons.append("runtime init advertised MCP servers despite strict empty MCP configuration")
        }
        if initialization?.permissionMode != "dontAsk" {
            reasons.append("runtime init did not confirm dontAsk permission mode")
        }
        return reasons
    }

    private static func receipt(
        sequence: Int,
        inputUUID: String,
        event: [String: Any]?
    ) -> ReplayReceipt {
        let replayUUID = event?["uuid"] as? String
        return ReplayReceipt(
            inputSequence: sequence,
            inputUUID: inputUUID,
            replayUUID: replayUUID,
            sessionID: event?["session_id"] as? String,
            acknowledged: replayUUID == inputUUID
        )
    }

    private static func writeUserMessage(
        uuid: String,
        text: String,
        to process: ProbeManagedProcessGroup
    ) throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "session_id": "",
            "parent_tool_use_id": NSNull(),
            "message": [
                "role": "user",
                "content": text
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try process.write(data, timeout: 2)
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func writePrivateJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum NonblockingLineWriter {
    public static let maximumLineBytes = 1 << 20

    public static func write(_ data: Data, to fileDescriptor: Int32, timeout: TimeInterval) throws {
        guard !data.isEmpty else {
            throw ProbeFailure.writeFailed("payload must not be empty")
        }
        guard data.count <= maximumLineBytes else {
            throw ProbeFailure.writeFailed("payload exceeds \(maximumLineBytes) bytes")
        }
        guard timeout >= 0, timeout.isFinite else {
            throw ProbeFailure.writeFailed("timeout must be finite and nonnegative")
        }

        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        guard existingFlags >= 0, fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
            throw ProbeFailure.writeFailed("could not enable O_NONBLOCK")
        }
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)

        let timeoutNanoseconds = UInt64(min(timeout * 1_000_000_000, Double(UInt64.max)))
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start.addingReportingOverflow(timeoutNanoseconds).overflow
            ? UInt64.max
            : start + timeoutNanoseconds
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1, errno == EINTR { continue }
                guard written == -1, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw ProbeFailure.writeFailed("write errno \(errno)")
                }

                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    throw ProbeFailure.writeFailed("backpressure deadline exceeded")
                }
                let remainingNanoseconds = deadline - now
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let remainingMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
                let milliseconds = Int32(min(remainingMilliseconds, UInt64(Int32.max)))
                let outcome = poll(&descriptor, 1, max(milliseconds, 1))
                if outcome == -1, errno == EINTR { continue }
                guard outcome > 0 else {
                    throw ProbeFailure.writeFailed("poll deadline exceeded")
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw ProbeFailure.writeFailed("child input closed during backpressure")
                }
            }
        }
    }
}
