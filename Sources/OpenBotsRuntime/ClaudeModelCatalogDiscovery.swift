import Darwin
import Foundation
import OpenBotsDomain
import OSLog

public protocol ClaudeModelCatalogDiscovering: Sendable {
    /// Called only after fresh official-installation, profile and subscription checks.
    /// Nil means unavailable; it never authorizes a fallback model turn.
    func discover(target: ClaudeConnectionTarget) async -> ClaudeModelCatalogSnapshot?
}

enum ClaudeModelDiscoveryCommand {
    static let requestID = "openbots-model-catalog"
    static var input: Data { try! ClaudeTextOnlyCommandBuilder.initializeControlRecord(id: requestID) }
    static let arguments = [
        "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--safe-mode", "--restricted", "--no-session-persistence", "--no-chrome", "--disable-slash-commands",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "",
        "--permission-mode", "dontAsk", "--tools", "", "--disallowedTools", "*", "--model", "sonnet", "--max-turns", "1",
        "--settings", "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true,\"enableArtifact\":false,\"syncClaudeAiSkills\":false,\"switchModelsOnFlag\":false,\"enabledPlugins\":{\"agents-md@builtin\":false,\"cc-plugin-plugin-authoring@builtin\":false,\"telemetry@builtin\":false},\"permissions\":{\"defaultMode\":\"dontAsk\",\"deny\":[\"*\"]}}"
    ]
}

/// Only the initialize handshake is sent. No user record, prompt, transcript,
/// tool, MCP server, persisted session, parent environment or API key is admitted.
public struct NativeClaudeModelCatalogDiscoverer: ClaudeModelCatalogDiscovering {
    private static let logger = Logger(subsystem: "com.lorenzocolombani.openbotsnext.preview",
                                       category: "ClaudeModelCatalogDiscovery")
    private let timeoutNanoseconds: UInt64
    private let diagnostic: (@Sendable (ClaudeModelCatalogDiscoveryFailure) -> Void)?
    public init() { timeoutNanoseconds = 15_000_000_000; diagnostic = nil }
    init(testTimeout: TimeInterval, diagnostic: (@Sendable (ClaudeModelCatalogDiscoveryFailure) -> Void)? = nil) {
        timeoutNanoseconds = UInt64(min(15, max(0.01, testTimeout.isFinite ? testTimeout : 15)) * 1_000_000_000)
        self.diagnostic = diagnostic
    }

    public func discover(target: ClaudeConnectionTarget) async -> ClaudeModelCatalogSnapshot? {
        let cancellation = ClaudeConnectionCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: Self.run(target: target,
                        timeoutNanoseconds: timeoutNanoseconds, cancellation: cancellation, diagnostic: diagnostic))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func run(target: ClaudeConnectionTarget, timeoutNanoseconds: UInt64,
                            cancellation: ClaudeConnectionCancellation,
                            diagnostic: (@Sendable (ClaudeModelCatalogDiscoveryFailure) -> Void)?) -> ClaudeModelCatalogSnapshot? {
        // Fixed codes only. Provider output, model descriptions, account data,
        // local paths and stderr never enter diagnostics.
        func fail(_ reason: ClaudeModelCatalogDiscoveryFailure) -> ClaudeModelCatalogSnapshot? {
            logger.error("Model catalog discovery failed: \(reason.rawValue, privacy: .public)")
            diagnostic?(reason)
            return nil
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        guard ClaudeConnectionStatusProcess.matchesFingerprint(target, deadline: deadline, cancellation: cancellation),
              !cancellation.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline else {
            return fail(cancellation.isCancelled ? .cancelled : .fingerprintOrDeadline)
        }
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        defer { for fd in input + output where fd >= 0 { close(fd) } }
        guard pipe(&input) == 0, pipe(&output) == 0,
              fcntl(output[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(input[1], F_SETFL, O_NONBLOCK) == 0,
              fcntl(input[1], F_SETNOSIGPIPE, 1) == 0 else { return fail(.pipeSetup) }
        for fd in input + output { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return fail(.pipeSetup) } }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return fail(.processSetup) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return fail(.processSetup) }
        defer { posix_spawnattr_destroy(&attributes) }
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addclose(&actions, input[0]),
            posix_spawn_file_actions_addclose(&actions, input[1]),
            posix_spawn_file_actions_addclose(&actions, output[0]),
            posix_spawn_file_actions_addclose(&actions, output[1]),
            posix_spawn_file_actions_addchdir_np(&actions, target.workingDirectoryURL.path)
        ]
        guard actionResults.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return fail(.processSetup) }
        let arguments = [target.executableURL.path] + ClaudeModelDiscoveryCommand.arguments
        let environment = ClaudeTextOnlyCommandBuilder.environment(for: target).map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        guard !cancellation.isCancelled else { return fail(.cancelled) }
        let result = ClaudeConnectionStatusProcess.withStrings(arguments) { argv in
            ClaudeConnectionStatusProcess.withStrings(environment) { envp in
                posix_spawn(&pid, target.executableURL.path, &actions, &attributes, argv, envp)
            }
        }
        guard result == 0, pid > 1 else { return fail(.launch) }
        close(input[0]); input[0] = -1
        close(output[1]); output[1] = -1
        defer {
            // Reserve the leader PID until group cleanup, including descendants
            // that retained a pipe after the leader exited. Never signal Terminal.
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        }
        let handshake = ClaudeModelDiscoveryCommand.input
        // One tiny PIPE_BUF-sized record, so a partial nonblocking write fails
        // closed without ever sending another record or a user message.
        let written = handshake.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        guard written == handshake.count else { return fail(.handshakeWrite) }
        var parser = ClaudeModelCatalogWireParser()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while !cancellation.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            let count = Darwin.read(output[0], &bytes, bytes.count)
            if count > 0 {
                do {
                    if let catalog = try parser.append(Data(bytes.prefix(count))) {
                        return cancellation.isCancelled ? fail(.cancelled) : catalog
                    }
                } catch let reason as ClaudeModelCatalogDiscoveryFailure { return fail(reason) }
                catch { return fail(.invalidCatalog) }
            } else if count == 0 { return fail(.earlyEOF) }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return fail(.read) }
            var observation = siginfo_t()
            let waitResult = waitid(P_PID, id_t(pid), &observation, WEXITED | WNOHANG | WNOWAIT)
            if waitResult != 0 && errno != EINTR { return fail(.wait) }
            if waitResult == 0 && observation.si_pid == pid && count <= 0 { return fail(.earlyExit) }
            var descriptor = pollfd(fd: output[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            if Darwin.poll(&descriptor, 1, 20) < 0 && errno != EINTR { return fail(.read) }
        }
        return fail(cancellation.isCancelled ? .cancelled : .deadline)
    }
}

/// Content-free failure categories, never a string supplied by Claude.
enum ClaudeModelCatalogDiscoveryFailure: String, Error, Sendable {
    case fingerprintOrDeadline, pipeSetup, processSetup, launch, handshakeWrite
    case read, wait, earlyEOF, earlyExit, deadline, cancelled
    case outputLimit, invalidFrame, unexpectedFrame, responseMismatch, invalidCatalog
}

/// Bounded extraction discards account identifiers and local paths. Neither the
/// raw response nor its descriptions are logged, published or persisted.
struct ClaudeModelCatalogWireParser {
    static let maximumOutputBytes = 1_048_576
    private var pending = Data()
    private var total = 0
    mutating func append(_ data: Data) throws -> ClaudeModelCatalogSnapshot? {
        total += data.count
        guard total <= Self.maximumOutputBytes else { throw ClaudeModelCatalogDiscoveryFailure.outputLimit }
        pending.append(data)
        while let end = pending.firstIndex(of: 0x0a) {
            let line = Data(pending[..<end])
            pending.removeSubrange(...end)
            guard !line.isEmpty, line.count <= 524_288,
                  let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = root["type"] as? String else { throw ClaudeModelCatalogDiscoveryFailure.invalidFrame }
            guard type == "control_response" else { throw ClaudeModelCatalogDiscoveryFailure.unexpectedFrame }
            guard let response = root["response"] as? [String: Any],
                  response["request_id"] as? String == ClaudeModelDiscoveryCommand.requestID,
                  response["subtype"] as? String == "success",
                  let body = response["response"] as? [String: Any], let models = body["models"] else {
                throw ClaudeModelCatalogDiscoveryFailure.responseMismatch
            }
            return try ClaudeModelCatalogSnapshot.parse(modelsJSON: JSONSerialization.data(withJSONObject: models),
                                                         checkedAt: Date())
        }
        guard pending.count <= 524_288 else { throw ClaudeModelCatalogDiscoveryFailure.outputLimit }
        return nil
    }
}
