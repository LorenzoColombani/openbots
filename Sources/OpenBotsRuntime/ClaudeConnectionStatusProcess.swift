import CryptoKit
import Darwin
import Foundation

/// A single-purpose, noninteractive status transport. Constructing it is inert.
/// Admission, signed-installation checks and profile ownership remain the
/// application's responsibility; this is not a model/tool executor or sandbox.
public struct NativeClaudeStatusChecker: ClaudeStatusChecking {
    private let timeoutNanoseconds: UInt64
    private let processLifecycleObserver: (@Sendable (Duration) -> Void)?

    public init() {
        timeoutNanoseconds = 15_000_000_000
        processLifecycleObserver = nil
    }

    // Shorter deadlines for synthetic process tests; production cannot extend
    // the fixed fifteen-second operation bound through the public API.
    init(testTimeout: TimeInterval, processLifecycleObserver: (@Sendable (Duration) -> Void)? = nil) {
        let bounded = testTimeout.isFinite ? min(15, max(0.01, testTimeout)) : 15
        timeoutNanoseconds = UInt64(bounded * 1_000_000_000)
        self.processLifecycleObserver = processLifecycleObserver
    }

    public func checkStatus(target: ClaudeConnectionTarget) async -> ClaudeConnectionStatusResult {
        let cancellation = ClaudeConnectionCancellation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                // One owned thread drains a nonblocking pipe, observes exit and
                // reaps the child. There are no detached blocking pipe readers.
                Thread.detachNewThread {
                    let began = ContinuousClock.now
                    let result = ClaudeConnectionStatusProcess.run(
                        target: target, timeoutNanoseconds: timeoutNanoseconds, cancellation: cancellation
                    )
                    processLifecycleObserver?(ContinuousClock.now - began)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ClaudeConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private enum ClaudeConnectionStatusProcess {
    static func run(
        target: ClaudeConnectionTarget,
        timeoutNanoseconds: UInt64,
        cancellation: ClaudeConnectionCancellation
    ) -> ClaudeConnectionStatusResult {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        guard !cancellation.isCancelled else { return .cancelled }
        guard matchesFingerprint(target, deadline: deadline, cancellation: cancellation) else {
            return cancellation.isCancelled ? .cancelled : .inconclusive
        }
        guard !cancellation.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline else {
            return cancellation.isCancelled ? .cancelled : .inconclusive
        }

        var outputPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&outputPipe) == 0 else { return .inconclusive }
        defer { for descriptor in outputPipe where descriptor >= 0 { Darwin.close(descriptor) } }
        guard fcntl(outputPipe[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(outputPipe[1], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(outputPipe[0], F_SETFL, O_NONBLOCK) == 0 else { return .inconclusive }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .inconclusive }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .inconclusive }
        defer { posix_spawnattr_destroy(&attributes) }
        let actionResults = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addclose(&actions, outputPipe[0]),
            posix_spawn_file_actions_addclose(&actions, outputPipe[1]),
            posix_spawn_file_actions_addchdir_np(&actions, target.workingDirectoryURL.path)
        ]
        guard actionResults.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return .inconclusive }
        var childPID: pid_t = 0
        let arguments = [target.executableURL.path] + ClaudeConnectionCommandBuilder.statusArguments
        let environment = ClaudeConnectionCommandBuilder.environment(for: target)
            .map { "\($0.key)=\($0.value)" }.sorted()
        guard !cancellation.isCancelled else { return .cancelled }
        let spawnResult = withStrings(arguments) { argv in
            withStrings(environment) { envp in
                posix_spawn(&childPID, target.executableURL.path, &actions, &attributes, argv, envp)
            }
        }
        guard spawnResult == 0, childPID > 1 else { return .inconclusive }
        Darwin.close(outputPipe[1])
        outputPipe[1] = -1

        var output = Data()
        var completedNormally = false
        while !cancellation.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            guard drain(outputPipe[0], into: &output) else { break }
            // WNOWAIT reserves the child's PID until owned-group cleanup. An
            // exited leader cannot be reaped/reused while we still address its
            // group to close descendants that inherited the output descriptor.
            var observation = siginfo_t()
            let waitResult = waitid(P_PID, id_t(childPID), &observation, WEXITED | WNOHANG | WNOWAIT)
            if waitResult == 0, observation.si_pid == childPID {
                completedNormally = drain(outputPipe[0], into: &output)
                break
            }
            if waitResult != 0, errno != EINTR { break }
            var descriptor = pollfd(fd: outputPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 20)
            if pollResult < 0, errno != EINTR { break }
            // EOF alone is not process completion. Avoid spinning if a process
            // closes stdout and continues running until the deadline.
            if descriptor.revents & Int16(POLLHUP) != 0 { usleep(20_000) }
        }

        // Only the dedicated group created above is signalled. This is cleanup
        // of one admitted status operation, never of a user's Terminal login.
        _ = Darwin.kill(-childPID, SIGKILL)
        var waitStatus: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(childPID, &waitStatus, 0) } while reaped < 0 && errno == EINTR
        guard !cancellation.isCancelled else { return .cancelled }
        guard completedNormally, reaped == childPID, waitStatus & 0x7f == 0 else { return .inconclusive }
        return ClaudeConnectionStatusParser.classify(stdout: output, exitCode: (waitStatus >> 8) & 0xff)
    }

    private static func drain(_ descriptor: Int32, into output: inout Data) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= ClaudeConnectionStatusParser.maximumOutputBytes else { return false }
                output.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                return true
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            } else if errno != EINTR {
                return false
            }
        }
    }

    private static func matchesFingerprint(
        _ target: ClaudeConnectionTarget,
        deadline: UInt64,
        cancellation: ClaudeConnectionCancellation
    ) -> Bool {
        let descriptor = Darwin.open(target.executableURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 1_073_741_824 else { return false }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        while !cancellation.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                total += count
                guard total <= 1_073_741_824 else { return false }
                hasher.update(data: Data(bytes.prefix(count)))
            } else if count == 0 {
                return hasher.finalize().map { String(format: "%02x", $0) }.joined() == target.expectedExecutableSHA256
            } else if errno != EINTR {
                return false
            }
        }
        return false
    }

    private static func withStrings(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) -> Int32 {
        let allocated = values.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else { return ENOMEM }
        var pointers = allocated + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
