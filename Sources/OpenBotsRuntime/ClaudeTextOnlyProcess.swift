import CryptoKit
import Darwin
import Foundation

/// Single-turn transport, not a sandbox or general process executor. Services
/// owns fresh signed-installation, profile, policy and Pro/Max admission.
public struct NativeClaudeTextOnlyRunner: ClaudeTextOnlyRunning {
    private let timeoutNanoseconds: UInt64
    private let processLifecycleObserver: (@Sendable (Duration) -> Void)?
    public init() {
        timeoutNanoseconds = 120_000_000_000
        processLifecycleObserver = nil
    }
    init(testTimeout: TimeInterval, processLifecycleObserver: (@Sendable (Duration) -> Void)? = nil) {
        timeoutNanoseconds = UInt64((testTimeout.isFinite ? min(120, max(0.1, testTimeout)) : 120) * 1_000_000_000)
        self.processLifecycleObserver = processLifecycleObserver
    }

    public func run(request: ClaudeTextOnlyRequest,
                    onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        let transfer = ClaudeTextOnlyTransfer()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    let began = ContinuousClock.now
                    let result = ClaudeTextOnlyProcess.run(
                        request: request, timeoutNanoseconds: timeoutNanoseconds, transfer: transfer)
                    processLifecycleObserver?(ContinuousClock.now - began)
                    transfer.complete(result)
                }
                // Slow UI delivery cannot prevent the independent process thread
                // from draining output, enforcing the deadline or reaping children.
                Task.detached {
                    while true {
                        let (events, result) = transfer.take()
                        for event in events where !transfer.isCancelled { await onEvent(event) }
                        if let result {
                            continuation.resume(returning: transfer.isCancelled ? .cancelled : result)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
        } onCancel: { transfer.cancel() }
    }
}

private final class ClaudeTextOnlyTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var events: [ClaudeTextOnlyEvent] = []
    private var result: ClaudeTextOnlyResult?
    private var rejectionCode: ClaudeTextOnlyDiagnosticCode?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true; events.removeAll() } }
    func publish(_ event: ClaudeTextOnlyEvent) {
        lock.withLock {
            guard !cancelled else { return }
            if case .textSnapshot = event {
                // At most three lifecycle events, one text snapshot and one
                // terminal static diagnostic can be waiting for delivery.
                events.removeAll { if case .textSnapshot = $0 { return true }; return false }
            }
            events.append(event)
        }
    }
    func complete(_ value: ClaudeTextOnlyResult) { lock.withLock { result = value } }
    func recordDiagnostic(_ code: ClaudeTextOnlyDiagnosticCode) {
        lock.withLock { if rejectionCode == nil { rejectionCode = code } }
    }
    var diagnosticCode: ClaudeTextOnlyDiagnosticCode? { lock.withLock { rejectionCode } }
    func take() -> ([ClaudeTextOnlyEvent], ClaudeTextOnlyResult?) {
        lock.withLock { let value = events; events.removeAll(keepingCapacity: true); return (value, result) }
    }
}

private enum ClaudeTextOnlyProcess {
    static func run(request: ClaudeTextOnlyRequest, timeoutNanoseconds: UInt64,
                    transfer: ClaudeTextOnlyTransfer) -> ClaudeTextOnlyResult {
        let result = execute(request: request, timeoutNanoseconds: timeoutNanoseconds, transfer: transfer)
        if case .failed(let failure) = result {
            // execute has already completed owned process cleanup. Deliver one
            // static code after validated prefix events, before final completion.
            transfer.publish(.diagnostic(transfer.diagnosticCode ?? diagnostic(for: failure)))
        }
        return result
    }

    private static func execute(request: ClaudeTextOnlyRequest, timeoutNanoseconds: UInt64,
                                transfer: ClaudeTextOnlyTransfer) -> ClaudeTextOnlyResult {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        guard !transfer.isCancelled else { return .cancelled }
        guard matchesFingerprint(request.target, deadline: deadline, transfer: transfer) else {
            return transfer.isCancelled ? .cancelled : .failed(.launchRejected)
        }
        let promptFile: ClaudeTextOnlyPromptFile
        do {
            promptFile = try ClaudeTextOnlyPromptFile.create(for: request) {
                !transfer.isCancelled && DispatchTime.now().uptimeNanoseconds < deadline
            }
        } catch {
            if transfer.isCancelled { return .cancelled }
            return .failed(DispatchTime.now().uptimeNanoseconds < deadline ? .launchFailed : .timedOut)
        }
        let result = executePrepared(request: request, promptFile: promptFile, deadline: deadline, transfer: transfer)
        let removed = promptFile.removeIfUnchanged()
        if transfer.isCancelled { return .cancelled }
        guard removed else { transfer.recordDiagnostic(.processFailed); return .failed(.processFailed) }
        return result
    }

    private static func executePrepared(request: ClaudeTextOnlyRequest, promptFile: ClaudeTextOnlyPromptFile,
                                        deadline: UInt64, transfer: ClaudeTextOnlyTransfer) -> ClaudeTextOnlyResult {
        guard let input = try? ClaudeTextOnlyCommandBuilder.input(for: request) else { return .failed(.inputRejected) }
        var inputPipe: [Int32] = [-1, -1], outputPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&inputPipe) == 0 else { return .failed(.launchFailed) }
        defer { for fd in inputPipe where fd >= 0 { Darwin.close(fd) } }
        guard Darwin.pipe(&outputPipe) == 0 else { return .failed(.launchFailed) }
        defer { for fd in outputPipe where fd >= 0 { Darwin.close(fd) } }
        for fd in inputPipe + outputPipe {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return .failed(.launchFailed) }
        }
        guard fcntl(inputPipe[1], F_SETFL, O_NONBLOCK) == 0,
              fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == 0,
              fcntl(outputPipe[0], F_SETFL, O_NONBLOCK) == 0 else { return .failed(.launchFailed) }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failed(.launchFailed) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failed(.launchFailed) }
        defer { posix_spawnattr_destroy(&attributes) }
        let results = [
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addclose(&actions, inputPipe[0]),
            posix_spawn_file_actions_addclose(&actions, inputPipe[1]),
            posix_spawn_file_actions_addclose(&actions, outputPipe[0]),
            posix_spawn_file_actions_addclose(&actions, outputPipe[1]),
            posix_spawn_file_actions_addchdir_np(&actions, request.target.workingDirectoryURL.path)
        ]
        guard results.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return .failed(.launchFailed) }
        guard !transfer.isCancelled else { return .cancelled }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failed(.timedOut) }
        guard promptFile.isUnchanged() else { return .failed(.launchFailed) }
        var pid: pid_t = 0
        let argv = [request.target.executableURL.path] + ClaudeTextOnlyCommandBuilder.arguments(for: request)
        let env = ClaudeTextOnlyCommandBuilder.environment(for: request).map { "\($0.key)=\($0.value)" }.sorted()
        let launched = withStrings(argv) { argv in
            withStrings(env) { envp in
                posix_spawn(&pid, request.target.executableURL.path, &actions, &attributes, argv, envp)
            }
        }
        guard launched == 0, pid > 1 else { return .failed(.launchFailed) }
        Darwin.close(inputPipe[0]); inputPipe[0] = -1
        Darwin.close(outputPipe[1]); outputPipe[1] = -1

        var stream = ClaudeTextOnlyStream(request: request)
        var written = 0
        var failure: ClaudeTextOnlyFailure?
        var exited = false
        var outputEOF = false
        while !transfer.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                try drain(outputPipe[0], stream: &stream, transfer: transfer, reachedEOF: &outputEOF,
                          deadline: deadline)
            } catch let rejection as ClaudeTextOnlyRejection {
                transfer.recordDiagnostic(rejection.code); failure = rejection.failure; break
            } catch let error as ClaudeTextOnlyFailure {
                transfer.recordDiagnostic(.streamReadFailed); failure = error; break
            } catch { failure = .invalidStream; break }

            if inputPipe[1] >= 0 {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(inputPipe[1], bytes.baseAddress!.advanced(by: written), input.count - written)
                }
                if count > 0 {
                    written += count
                    if written == input.count {
                        transfer.publish(.inputSubmitted(messageID: request.messageID))
                        Darwin.close(inputPipe[1]); inputPipe[1] = -1
                    }
                } else if count < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                    failure = .inputRejected; break
                }
            }

            // Keep the zombie leader's PID reserved until group cleanup; never
            // signal a possibly reused group ID after prematurely reaping it.
            var observation = siginfo_t()
            let waited = waitid(P_PID, id_t(pid), &observation, WEXITED | WNOHANG | WNOWAIT)
            if waited == 0, observation.si_pid == pid {
                exited = true
                do {
                    try drain(outputPipe[0], stream: &stream, transfer: transfer, reachedEOF: &outputEOF,
                              deadline: deadline)
                } catch let rejection as ClaudeTextOnlyRejection {
                    transfer.recordDiagnostic(rejection.code); failure = rejection.failure
                } catch let error as ClaudeTextOnlyFailure {
                    transfer.recordDiagnostic(.streamReadFailed); failure = error
                } catch { failure = .invalidStream }
                break
            }
            if waited != 0, errno != EINTR { failure = .processFailed; break }
            var descriptors = [pollfd(fd: outputEOF ? -1 : outputPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: inputPipe[1], events: Int16(POLLOUT), revents: 0)]
            let polled = Darwin.poll(&descriptors, nfds_t(descriptors.count), 20)
            if polled < 0, errno != EINTR { failure = .processFailed; break }
        }

        // Cleanup is independent of UI callbacks. It is group lifecycle control,
        // not containment against a program deliberately creating another group.
        _ = Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        guard !transfer.isCancelled else { return .cancelled }
        if let failure { return .failed(failure) }
        guard exited else { return .failed(.timedOut) }
        guard reaped == pid, status & 0x7f == 0 else { return .failed(.processFailed) }
        guard written == input.count else { return .failed(.inputRejected) }
        return stream.finish(exitCode: (status >> 8) & 0xff) { transfer.recordDiagnostic($0) }
    }

    private static func diagnostic(for failure: ClaudeTextOnlyFailure) -> ClaudeTextOnlyDiagnosticCode {
        switch failure {
        case .launchRejected: .executableRejected
        case .launchFailed: .launchFailed
        case .inputRejected: .inputWriteFailed
        case .timedOut: .deadlineExceeded
        case .outputLimitExceeded: .outputLimitExceeded
        case .invalidStream: .incompleteResult
        case .unsafeInitialization: .invalidEnvelope
        case .providerFailed: .providerFailure
        case .processFailed: .processFailed
        }
    }

    private static func drain(_ descriptor: Int32, stream: inout ClaudeTextOnlyStream,
                              transfer: ClaudeTextOnlyTransfer, reachedEOF: inout Bool, deadline: UInt64) throws {
        guard !reachedEOF else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        // Bound each drain batch so a continuously writing child cannot starve
        // cancellation, input delivery or the process/deadline observation.
        for _ in 0..<16 {
            guard !transfer.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline else { return }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                try stream.consume(Data(bytes.prefix(count))) { transfer.publish($0) }
            } else if count == 0 { reachedEOF = true; return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { throw ClaudeTextOnlyFailure.invalidStream }
        }
    }

    private static func matchesFingerprint(_ target: ClaudeConnectionTarget, deadline: UInt64,
                                           transfer: ClaudeTextOnlyTransfer) -> Bool {
        let fd = Darwin.open(target.executableURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 536_870_912 else { return false }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        while !transfer.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                total += count
                guard total <= 536_870_912 else { return false }
                hasher.update(data: Data(bytes.prefix(count)))
            } else if count == 0 {
                return total == metadata.st_size && hasher.finalize().map { String(format: "%02x", $0) }.joined() == target.expectedExecutableSHA256
            } else if errno != EINTR { return false }
        }
        return false
    }

    private static func withStrings(_ values: [String],
                                    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) -> Int32 {
        let allocated = values.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else { return ENOMEM }
        var pointers = allocated + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
