import Foundation

public struct ProbeToolSessionCleanup: Equatable, Sendable {
    public let exited: Bool
    public let status: Int32?
    public let processGroupGone: Bool
    public let sentTerminate: Bool
    public let sentKill: Bool
}

/// Probe-only JSON-lines transport. This exposes the existing managed process
/// group; it grants no product executor, provider admission or sandbox authority.
public final class ProbeToolSession: @unchecked Sendable {
    public static let maximumRecordBytes = NonblockingLineWriter.maximumLineBytes
    public static let maximumWriteTimeout: TimeInterval = 30

    public var processID: Int32 { process.processID }
    public var processGroupID: Int32 { process.processGroupID }

    private let process: ProbeManagedProcessGroup
    private let writers = NSCondition()
    private var writing = false
    private var inputClosed = false

    private init(process: ProbeManagedProcessGroup) { self.process = process }

    public static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        standardOutputHandler: @escaping @Sendable (Data) -> Void,
        standardOutputEOF: @escaping @Sendable () -> Void,
        standardErrorHandler: @escaping @Sendable (Data) -> Void
    ) throws -> ProbeToolSession {
        ProbeToolSession(process: try ProbeManagedProcessGroup.launch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, standardOutputHandler: standardOutputHandler,
            standardOutputEOF: standardOutputEOF, standardErrorHandler: standardErrorHandler))
    }

    /// Accept one UTF-8 JSON object, then serialize one compact record plus one
    /// LF. Queue time and pipe backpressure share the caller's finite deadline.
    /// Invalid input never writes to or tears down the child.
    public func sendRecord(_ record: Data, timeout: TimeInterval) throws {
        guard timeout.isFinite, (0...Self.maximumWriteTimeout).contains(timeout) else {
            throw ProbeFailure.writeFailed("record timeout must be between zero and 30 seconds")
        }
        guard !record.isEmpty, record.count <= Self.maximumRecordBytes,
              String(data: record, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: record),
              let dictionary = object as? [String: Any] else {
            throw ProbeFailure.writeFailed("input must contain one bounded UTF-8 JSON object")
        }
        var line = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys, .withoutEscapingSlashes])
        guard line.count < Self.maximumRecordBytes else {
            throw ProbeFailure.writeFailed("serialized record exceeds the input bound")
        }
        line.append(0x0a)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try beginWrite(deadline: deadline)
        defer { endWrite() }
        do {
            try process.write(line, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        } catch {
            // The managed process already performs bounded cleanup on an
            // uncertain/failed write. Deny queued and future records as well.
            closeInput()
            throw error
        }
    }

    public func closeInput() {
        writers.lock()
        inputClosed = true
        writers.broadcast()
        writers.unlock()
        process.closeInput()
    }

    public func waitForExit(timeout: TimeInterval) -> Bool {
        guard timeout.isFinite, timeout >= 0 else { return false }
        return process.wait(timeout: min(timeout, Self.maximumWriteTimeout)) != nil
    }

    /// Never waits for the serialized writer. An already-started write may have
    /// partial/unknown delivery; Stop prevents queued or subsequent records and
    /// uses the existing bounded process-group teardown to interrupt that write.
    @discardableResult
    public func stop() -> ProbeToolSessionCleanup {
        closeInput()
        let receipt = process.cleanup(gracefulTimeout: 0, terminateTimeout: 0.25, killTimeout: 1)
        return ProbeToolSessionCleanup(exited: receipt.exit != nil, status: receipt.exit?.status,
            processGroupGone: receipt.processGroupGone, sentTerminate: receipt.sentTerminate, sentKill: receipt.sentKill)
    }

    private func beginWrite(deadline: TimeInterval) throws {
        writers.lock()
        defer { writers.unlock() }
        while writing && !inputClosed {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, writers.wait(until: Date().addingTimeInterval(remaining)) else {
                throw ProbeFailure.writeFailed("record writer queue deadline exceeded")
            }
        }
        guard !inputClosed else { throw ProbeFailure.writeFailed("session input is closed") }
        writing = true
    }

    private func endWrite() {
        writers.lock()
        writing = false
        writers.broadcast()
        writers.unlock()
    }
}
