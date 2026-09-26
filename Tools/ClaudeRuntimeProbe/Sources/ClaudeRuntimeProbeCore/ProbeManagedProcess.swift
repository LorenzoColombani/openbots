import Darwin
import Foundation

/// Probe-only process ownership primitive. OpenBots product code must not turn
/// this feasibility helper into a general command or shell execution surface.
final class ProbeManagedProcessGroup: @unchecked Sendable {
    struct ExitReceipt: Equatable, Sendable {
        enum Reason: String, Sendable {
            case exit
            case uncaughtSignal
        }

        let reason: Reason
        let status: Int32
        let rawWaitStatus: Int32

        fileprivate init(waitStatus: Int32) {
            rawWaitStatus = waitStatus
            let terminatingSignal = waitStatus & 0x7f
            if terminatingSignal == 0 {
                reason = .exit
                status = (waitStatus >> 8) & 0xff
            } else {
                reason = .uncaughtSignal
                status = terminatingSignal
            }
        }
    }

    struct CleanupReceipt: Equatable, Sendable {
        let exit: ExitReceipt?
        let sentTerminate: Bool
        let sentKill: Bool
        let processGroupGone: Bool
    }

    typealias DataHandler = @Sendable (Data) -> Void
    typealias EOFHandler = @Sendable () -> Void

    let processID: pid_t
    let processGroupID: pid_t

    private let state = NSCondition()
    private let cleanupLock = NSLock()
    private var standardInputDescriptor: Int32?
    private var waitStatus: Int32?
    private var cleanupReceipt: CleanupReceipt?
    private let readerGroup = DispatchGroup()

    private init(
        processID: pid_t,
        processGroupID: pid_t,
        standardInputDescriptor: Int32,
        standardOutputDescriptor: Int32,
        standardErrorDescriptor: Int32,
        standardOutputHandler: @escaping DataHandler,
        standardOutputEOF: @escaping EOFHandler,
        standardErrorHandler: @escaping DataHandler,
        standardErrorEOF: @escaping EOFHandler
    ) {
        self.processID = processID
        self.processGroupID = processGroupID
        self.standardInputDescriptor = standardInputDescriptor

        startReader(
            descriptor: standardOutputDescriptor,
            dataHandler: standardOutputHandler,
            eofHandler: standardOutputEOF
        )
        startReader(
            descriptor: standardErrorDescriptor,
            dataHandler: standardErrorHandler,
            eofHandler: standardErrorEOF
        )
        startWaiter()
    }

    deinit {
        closeInput()
        // A caller should always invoke cleanup(). This last-resort signal is
        // intentionally nonblocking so deinit can never deadlock a lifecycle.
        if processGroupID > 1, processGroupID != getpgrp(), Self.groupExists(processGroupID) {
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
    }

    static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        standardOutputHandler: @escaping DataHandler = { _ in },
        standardOutputEOF: @escaping EOFHandler = {},
        standardErrorHandler: @escaping DataHandler = { _ in },
        standardErrorEOF: @escaping EOFHandler = {}
    ) throws -> ProbeManagedProcessGroup {
        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        var errorPipe = [Int32](repeating: -1, count: 2)

        guard Darwin.pipe(&inputPipe) == 0 else {
            throw ProbeFailure.processLaunch("stdin pipe errno \(errno)")
        }
        guard Darwin.pipe(&outputPipe) == 0 else {
            closeDescriptors(inputPipe)
            throw ProbeFailure.processLaunch("stdout pipe errno \(errno)")
        }
        guard Darwin.pipe(&errorPipe) == 0 else {
            closeDescriptors(inputPipe + outputPipe)
            throw ProbeFailure.processLaunch("stderr pipe errno \(errno)")
        }

        let allDescriptors = inputPipe + outputPipe + errorPipe
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            closeDescriptors(allDescriptors)
            throw ProbeFailure.processLaunch("could not initialize spawn file actions")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeDescriptors(allDescriptors)
            throw ProbeFailure.processLaunch("could not initialize spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let actionResults = [
            posix_spawn_file_actions_adddup2(&fileActions, inputPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, errorPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
        ] + allDescriptors.map { descriptor in
            posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        guard let failedAction = actionResults.first(where: { $0 != 0 }) else {
            let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
                closeDescriptors(allDescriptors)
                throw ProbeFailure.processLaunch("could not configure an isolated process group")
            }

            let argv = [executable.path] + arguments
            let environmentEntries = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
            var childPID: pid_t = 0
            let spawnResult = withMutableCStrings(argv) { argumentPointers in
                withMutableCStrings(environmentEntries) { environmentPointers in
                    posix_spawn(
                        &childPID,
                        executable.path,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
            guard spawnResult == 0 else {
                closeDescriptors(allDescriptors)
                throw ProbeFailure.processLaunch("posix_spawn errno \(spawnResult)")
            }

            // The child owns input[0], output[1], and error[1] after dup2.
            closeDescriptors([inputPipe[0], outputPipe[1], errorPipe[1]])
            let parentDescriptors = [inputPipe[1], outputPipe[0], errorPipe[0]]
            guard childPID > 1, getpgid(childPID) == childPID else {
                _ = Darwin.kill(-childPID, SIGKILL)
                _ = Darwin.kill(childPID, SIGKILL)
                _ = waitForSpecificChild(childPID)
                closeDescriptors(parentDescriptors)
                throw ProbeFailure.processLaunch("child did not enter its requested dedicated process group")
            }
            for descriptor in parentDescriptors {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
            _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)

            return ProbeManagedProcessGroup(
                processID: childPID,
                processGroupID: childPID,
                standardInputDescriptor: inputPipe[1],
                standardOutputDescriptor: outputPipe[0],
                standardErrorDescriptor: errorPipe[0],
                standardOutputHandler: standardOutputHandler,
                standardOutputEOF: standardOutputEOF,
                standardErrorHandler: standardErrorHandler,
                standardErrorEOF: standardErrorEOF
            )
        }

        closeDescriptors(allDescriptors)
        throw ProbeFailure.processLaunch("spawn file action errno \(failedAction)")
    }

    /// Duplicates the input descriptor while holding the lifecycle condition,
    /// then releases it before any potentially blocking poll/write loop. This
    /// is the required lock boundary: cleanup remains free to close the owned
    /// descriptor and terminate the process group under backpressure.
    func write(_ data: Data, timeout: TimeInterval) throws {
        // Contract failures are rejected without touching the live child. They
        // are caller input errors, not evidence that the process is unhealthy.
        guard !data.isEmpty else {
            throw ProbeFailure.writeFailed("payload must not be empty")
        }
        guard data.count <= NonblockingLineWriter.maximumLineBytes else {
            throw ProbeFailure.writeFailed(
                "payload exceeds \(NonblockingLineWriter.maximumLineBytes) bytes"
            )
        }
        guard timeout >= 0, timeout.isFinite else {
            throw ProbeFailure.writeFailed("timeout must be finite and nonnegative")
        }

        state.lock()
        let duplicate: Int32
        if let descriptor = standardInputDescriptor {
            duplicate = Darwin.dup(descriptor)
        } else {
            duplicate = -1
        }
        state.unlock()

        guard duplicate >= 0 else {
            throw ProbeFailure.writeFailed("child input is closed")
        }
        defer { Darwin.close(duplicate) }
        _ = fcntl(duplicate, F_SETNOSIGPIPE, 1)
        do {
            try NonblockingLineWriter.write(data, to: duplicate, timeout: timeout)
        } catch {
            // Backpressure expiry or a broken pipe means delivery is unknown
            // until a replay acknowledgement exists. Fail closed and tear down
            // the entire owned process group before surfacing the error.
            _ = cleanup(gracefulTimeout: 0, terminateTimeout: 0.25, killTimeout: 1)
            throw error
        }
    }

    func closeInput() {
        state.lock()
        let descriptor = standardInputDescriptor
        standardInputDescriptor = nil
        state.broadcast()
        state.unlock()
        if let descriptor { Darwin.close(descriptor) }
    }

    func wait(timeout: TimeInterval) -> ExitReceipt? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        state.lock()
        defer { state.unlock() }
        while waitStatus == nil {
            guard state.wait(until: deadline) else { return nil }
        }
        return waitStatus.map(ExitReceipt.init(waitStatus:))
    }

    @discardableResult
    func cleanup(
        gracefulTimeout: TimeInterval = 0.25,
        terminateTimeout: TimeInterval = 0.5,
        killTimeout: TimeInterval = 1
    ) -> CleanupReceipt {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        if let cleanupReceipt { return cleanupReceipt }

        closeInput()
        var exit = wait(timeout: gracefulTimeout)
        var sentTerminate = false
        var sentKill = false

        if Self.groupExists(processGroupID) {
            sentTerminate = Darwin.kill(-processGroupID, SIGTERM) == 0
            if exit == nil { exit = wait(timeout: terminateTimeout) }
            if !Self.waitForGroupToDisappear(processGroupID, timeout: terminateTimeout) {
                sentKill = Darwin.kill(-processGroupID, SIGKILL) == 0
                if exit == nil { exit = wait(timeout: killTimeout) }
                _ = Self.waitForGroupToDisappear(processGroupID, timeout: killTimeout)
            }
        } else if exit == nil {
            exit = wait(timeout: terminateTimeout)
        }

        // Descendants may have inherited stdout/stderr. Their group is gone at
        // this point, so both readers should now receive EOF promptly.
        _ = readerGroup.wait(timeout: .now() + max(0.1, killTimeout))
        let receipt = CleanupReceipt(
            exit: exit ?? wait(timeout: 0),
            sentTerminate: sentTerminate,
            sentKill: sentKill,
            processGroupGone: !Self.groupExists(processGroupID)
        )
        cleanupReceipt = receipt
        return receipt
    }

    static func processExists(_ processID: pid_t) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    static func groupExists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 1, processGroupID != getpgrp() else { return false }
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    static func waitForProcessToDisappear(_ processID: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while processExists(processID), Date() < deadline {
            usleep(10_000)
        }
        return !processExists(processID)
    }

    private static func waitForGroupToDisappear(_ processGroupID: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while groupExists(processGroupID), Date() < deadline {
            usleep(10_000)
        }
        return !groupExists(processGroupID)
    }

    private func startReader(
        descriptor: Int32,
        dataHandler: @escaping DataHandler,
        eofHandler: @escaping EOFHandler
    ) {
        readerGroup.enter()
        // These reads block for the child's lifetime. Give each pipe its own
        // thread: a shared dispatch pool can fill with idle pipes and prevent
        // another owned child's output or exit receipt from being consumed.
        Thread.detachNewThread { [readerGroup] in
            defer {
                Darwin.close(descriptor)
                eofHandler()
                readerGroup.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    dataHandler(Data(buffer.prefix(Int(count))))
                } else if count == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }
    }

    private func startWaiter() {
        let pid = processID
        // Reaping must progress even while every pipe reader is blocked; it
        // cannot depend on a spare worker in the readers' dispatch pool.
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            var outcome: pid_t = -1
            repeat {
                outcome = waitpid(pid, &status, 0)
            } while outcome == -1 && errno == EINTR

            guard let self else { return }
            self.state.lock()
            // ECHILD is not expected because this object is the sole waiter.
            // Leave nil on failure so cleanup fails closed and checks the group.
            if outcome == pid { self.waitStatus = status }
            self.state.broadcast()
            self.state.unlock()
        }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private static func waitForSpecificChild(_ childPID: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
        return status
    }

    private static func withMutableCStrings<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        let allocated = strings.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers = allocated + [nil]
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}
