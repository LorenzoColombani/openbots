import Foundation

public protocol ProcessRunning: Sendable {
    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error>
    /// Egress-fence variant (spec 2026-08-13): `extraEnvironment` overlays the
    /// child's environment — the runner uses it to point a fenced child at the
    /// loopback allowlist proxy (HTTPS_PROXY et al).
    func runLines(executable: String, arguments: [String], cwd: URL,
                  extraEnvironment: [String: String]) -> AsyncThrowingStream<String, Error>
}

public extension ProcessRunning {
    /// Default so env-indifferent conformers (test mocks) only implement the
    /// 3-parameter version. Conformers that DO honor env (the real runner,
    /// env-capturing mocks) override this requirement and win dynamic dispatch.
    func runLines(executable: String, arguments: [String], cwd: URL,
                  extraEnvironment: [String: String]) -> AsyncThrowingStream<String, Error> {
        runLines(executable: executable, arguments: arguments, cwd: cwd)
    }
}

/// Non-zero exit from the `claude` binary, carrying whatever it wrote to stderr
/// (not logged in, plan limit reached, bad flag…) so the UI can show something useful.
public struct ProcessFailure: LocalizedError {
    public let status: Int32
    public let stderr: String
    /// Public because AgencyKit ships as a library product: an outside conformer
    /// to ProcessRunning must be able to construct the error the protocol is
    /// contractually expected to throw (review #3 minor 6).
    public init(status: Int32, stderr: String) {
        self.status = status; self.stderr = stderr
    }
    public var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "claude exited with status \(status)"
                              : "claude exited with status \(status): \(detail)"
    }
}

/// Serialises the pipe-reader callbacks (stdout, stderr) plus the termination
/// handler, which run on different threads and would otherwise race on the buffers.
/// The termination-path DRAIN also runs under the same lock (review #3 minor 8):
/// nilling a readabilityHandler does not wait for an in-flight invocation, so an
/// unlocked drain could interleave reads with a still-executing handler.
final class PipeBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    /// Appends stdout bytes, returning every COMPLETE line they made available.
    func appendOut(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return appendOutLocked(chunk)
    }

    private func appendOutLocked(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        out.append(chunk)
        var lines: [String] = []
        while let nl = out.firstIndex(of: 0x0A) {
            let lineData = out[out.startIndex..<nl]
            out.removeSubrange(out.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
        }
        return lines
    }

    func appendErr(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        err.append(chunk)
    }

    /// Drains whatever is ALREADY readable on `fd` without waiting for EOF, under
    /// the buffer lock. readToEnd() would block until every holder of the write
    /// end closes it — and a background child the agent spawned (`sleep 30 &`)
    /// inherits stdout/stderr and holds the pipe open long after `claude` exits;
    /// that hung a teammate forever (review #1 C1, reproduced in tests).
    private static func readAvailable(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        // If we cannot guarantee non-blocking, bail with nothing rather than risk
        // a blocking read that silently reintroduces the hang (review #3 minor 7).
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return Data() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) }
            else if n == -1 && errno == EINTR { continue }  // signal ≠ EOF
            else { break }                                   // 0 (EOF) or EAGAIN
        }
        return data
    }

    /// Termination-path stdout drain: read + append + line-split, all locked.
    func drainOut(fd: Int32) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return appendOutLocked(Self.readAvailable(fd))
    }

    func drainErr(fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        err.append(Self.readAvailable(fd))
    }

    /// Any trailing stdout bytes with no newline terminator.
    func flushOut() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !out.isEmpty, let s = String(data: out, encoding: .utf8) else { return nil }
        out.removeAll()
        return s.isEmpty ? nil : s
    }

    func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}

public struct ClaudeProcessRunner: ProcessRunning {
    public init() {}

    /// The environment handed to every child `claude` process.
    /// HARD RULE: usage rides Lorenzo's Max subscription — no API key may ever leak in.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        return env
    }

    public func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        runLines(executable: executable, arguments: arguments, cwd: cwd, extraEnvironment: [:])
    }

    public func runLines(executable: String, arguments: [String], cwd: URL,
                         extraEnvironment: [String: String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.currentDirectoryURL = cwd
            proc.environment = Self.childEnvironment()
                .merging(extraEnvironment) { _, new in new }

            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            proc.standardInput = FileHandle.nullDevice
            let buffers = PipeBuffers()

            out.fileHandleForReading.readabilityHandler = { handle in
                for line in buffers.appendOut(handle.availableData) { continuation.yield(line) }
            }
            // stderr MUST be drained: an undrained pipe fills at ~64KB and deadlocks the child.
            err.fileHandleForReading.readabilityHandler = { handle in
                buffers.appendErr(handle.availableData)
            }

            proc.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                for line in buffers.drainOut(fd: out.fileHandleForReading.fileDescriptor) {
                    continuation.yield(line)
                }
                buffers.drainErr(fd: err.fileHandleForReading.fileDescriptor)
                if let tail = buffers.flushOut() { continuation.yield(tail) }
                if p.terminationStatus != 0 {
                    continuation.finish(throwing: ProcessFailure(status: p.terminationStatus,
                                                                 stderr: buffers.stderrText()))
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in if proc.isRunning { proc.terminate() } }
            do { try proc.run() } catch {
                // Launch failed: release the handlers installed above, or each
                // failed launch leaks a dispatch source + pipe fds.
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: error)
            }
        }
    }
}
