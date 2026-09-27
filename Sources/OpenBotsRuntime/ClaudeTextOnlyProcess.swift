import CryptoKit
import Darwin
import Foundation
import OSLog

/// Single-turn transport, not a sandbox or general process executor. Services
/// owns fresh signed-installation, profile, policy and Pro/Max admission.
public struct NativeClaudeTextOnlyRunner: ClaudeTextOnlyRunning {
    private let budget: ClaudeTextOnlyBudget
    private let processLifecycleObserver: (@Sendable (Duration) -> Void)?
    public init() {
        // A long answer is not a failure. Only silence ends a turn early; the
        // ceiling is the one bound a still-writing child cannot push. Time a
        // card waits for the user is given back to the ceiling, forty-five minutes
        // at most, so an ordinary turn lives an hour at the very most.
        budget = ClaudeTextOnlyBudget(silence: 90_000_000_000, overall: 900_000_000_000,
                                      leaseHeartbeat: Self.leaseHeartbeatNanoseconds,
                                      macControlOverall: Self.macControlCeilingNanoseconds,
                                      cardCredit: Self.macControlCeilingNanoseconds)
        processLifecycleObserver = nil
    }
    /// A text turn's run-journal lease lasts 180 seconds and is renewed by every
    /// checkpoint the service writes, and the service checkpoints on every text
    /// snapshot. A child that is busy but not yet speaking, in a web fetch or a
    /// long thinking phase, produces no snapshot; so the transport republishes
    /// the text so far at this cadence, and the checkpoint that follows carries
    /// the lease forward. Well inside the lease, and rare enough that the
    /// journal stays small.
    /// Forty-five minutes: see `ClaudeTextOnlyBudget.macControlOverall`.
    static let macControlCeilingNanoseconds: UInt64 = 2_700_000_000_000
    static let leaseHeartbeatNanoseconds: UInt64 = 60_000_000_000
    /// Both budgets take the same clamped value, so a timing test keeps the
    /// single deadline it was written against. A separate overall cap and a
    /// separate heartbeat exist only for the tests that must tell them apart.
    /// The card credit defaults to the test's own overall budget, so a test
    /// that leaves a card unanswered waits at most twice that, never the
    /// production forty-five minutes.
    init(testTimeout: TimeInterval, testOverallTimeout: TimeInterval? = nil, testLeaseHeartbeat: TimeInterval? = nil,
         testCardCredit: TimeInterval? = nil,
         processLifecycleObserver: (@Sendable (Duration) -> Void)? = nil) {
        let silence = Self.testNanoseconds(testTimeout)
        let overall = testOverallTimeout.map(Self.testNanoseconds) ?? silence
        budget = ClaudeTextOnlyBudget(silence: silence, overall: overall,
                                      leaseHeartbeat: testLeaseHeartbeat.map(Self.testNanoseconds) ?? Self.leaseHeartbeatNanoseconds,
                                      cardCredit: testCardCredit.map(Self.testNanoseconds) ?? overall)
        self.processLifecycleObserver = processLifecycleObserver
    }

    private static func testNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64((seconds.isFinite ? min(900, max(0.1, seconds)) : 120) * 1_000_000_000)
    }

    public func run(request: ClaudeTextOnlyRequest,
                    onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    public func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
                    onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        // A work turn without a channel would leave the CLI waiting on every
        // question. Refusing it here is a launch failure, not a hung child.
        if request.requiresPermissionControl, control == nil { return .failed(.launchRejected) }
        let transfer = ClaudeTextOnlyTransfer()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    let began = ContinuousClock.now
                    let result = ClaudeTextOnlyProcess.run(
                        request: request, budget: budget, transfer: transfer, control: control)
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

/// Two budgets, never one: a turn fails on silence, and the ceiling from
/// launch bounds a child that writes forever without ever finishing. The
/// ceiling measures the model's own time: while a card waits for the user it is
/// moved on by the wait, up to `cardCredit` in all, so the turn is still
/// bounded (ceiling plus credit) even if nobody ever answers. The heartbeat is
/// not a budget; it is how often a working child's text so far is republished
/// so the turn's lease is renewed.
private struct ClaudeTextOnlyBudget {
    let silence: UInt64
    let overall: UInt64
    let leaseHeartbeat: UInt64
    /// The ceiling of a reply that renews its rounds by card (Control this
    /// Mac). Sixty-four look-and-click rounds, with the cards the user answers
    /// between them, do not fit the fifteen minutes of any other reply; a
    /// renewal still restarts its own ceiling. Tests that set
    /// their own overall budget keep it.
    var macControlOverall: UInt64? = nil
    /// The most card time given back to one ceiling. A long work turn can
    /// spend a third of its fifteen minutes on cards the user is reading.
    /// Forty-five minutes in the app: an ordinary turn ends within an hour of
    /// launch, a Control this Mac window within ninety minutes of its launch
    /// or renewal.
    let cardCredit: UInt64
}

private enum ClaudeTextOnlyProcess {
    private static let logger = Logger(subsystem: "com.lorenzocolombani.openbotsnext.preview",
                                       category: "ClaudeTextOnlyProcess")
    static func run(request: ClaudeTextOnlyRequest, budget: ClaudeTextOnlyBudget,
                    transfer: ClaudeTextOnlyTransfer, control: ClaudeTextTurnControl?) -> ClaudeTextOnlyResult {
        let result = execute(request: request, budget: budget, transfer: transfer, control: control)
        if case .failed(let failure) = result, let code = transfer.diagnosticCode ?? diagnostic(for: failure) {
            // execute has already completed owned process cleanup. Deliver one
            // static code after validated prefix events, before final completion.
            transfer.publish(.diagnostic(code))
        }
        return result
    }

    private static func execute(request: ClaudeTextOnlyRequest, budget: ClaudeTextOnlyBudget,
                                transfer: ClaudeTextOnlyTransfer, control: ClaudeTextTurnControl?) -> ClaudeTextOnlyResult {
        let acceptedAt = DispatchTime.now().uptimeNanoseconds
        // Wall time, for the screenshots Control this Mac leaves (below).
        let startedAt = Date(timeIntervalSinceNow: -1)
        let overall = request.renewsRoundsByCard ? (budget.macControlOverall ?? budget.overall) : budget.overall
        let (ceiling, ceilingOverflowed) = acceptedAt.addingReportingOverflow(overall)
        let overallDeadline = ceilingOverflowed ? UInt64.max : ceiling
        guard !transfer.isCancelled else { return .cancelled }
        // Nothing before the spawn reads child output, so every pre-launch wait
        // is bounded by the silence budget measured from this turn's start.
        guard matchesFingerprint(request.target, budget: budget, lastOutputAt: acceptedAt,
                                 overallDeadline: overallDeadline, transfer: transfer) else {
            return transfer.isCancelled ? .cancelled : .failed(.launchRejected)
        }
        let promptFile: ClaudeTextOnlyPromptFile
        do {
            promptFile = try ClaudeTextOnlyPromptFile.create(for: request) {
                !transfer.isCancelled
                    && !expired(budget, lastOutputAt: acceptedAt, overallDeadline: overallDeadline)
            }
        } catch {
            if transfer.isCancelled { return .cancelled }
            return expired(budget, lastOutputAt: acceptedAt, overallDeadline: overallDeadline)
                ? timedOut(acceptedAt: acceptedAt, lastOutputAt: acceptedAt, overallDeadline: overallDeadline,
                           cardCredited: 0, stage: "before launch")
                : .failed(.launchFailed)
        }
        // The configuration naming this turn's servers is owned exactly like the
        // system prompt: private, single-link, and gone when the turn is.
        var connectorFile: ClaudeTextOnlyPromptFile?
        if let access = request.connectorAccess {
            do {
                connectorFile = try ClaudeTextOnlyPromptFile.create(
                    data: try ClaudeTextConnectorConfigurationFile.configurationJSON(
                        for: access, temporaryDirectory: request.target.temporaryDirectoryURL),
                    at: ClaudeTextConnectorConfigurationFile.configurationURL(for: request),
                    target: request.target,
                    maximumBytes: ClaudeTextConnectorConfigurationFile.maximumBytes) {
                        !transfer.isCancelled
                            && !expired(budget, lastOutputAt: acceptedAt, overallDeadline: overallDeadline)
                    }
            } catch {
                _ = promptFile.removeIfUnchanged()
                if transfer.isCancelled { return .cancelled }
                return expired(budget, lastOutputAt: acceptedAt, overallDeadline: overallDeadline)
                    ? timedOut(acceptedAt: acceptedAt, lastOutputAt: acceptedAt, overallDeadline: overallDeadline,
                               cardCredited: 0, stage: "before launch")
                    : .failed(.launchFailed)
            }
        }
        let result = executePrepared(request: request, promptFile: promptFile, connectorFile: connectorFile,
                                     budget: budget, acceptedAt: acceptedAt,
                                     lastOutputAt: acceptedAt, overallDeadline: overallDeadline,
                                     transfer: transfer, control: request.requiresPermissionControl ? control : nil)
        // Whatever ended the turn — success, failure, timeout, Stop, quit — the
        // browser it owns goes with it. Chrome is in its own process group, so
        // the group kill above never reached it.
        if let access = request.connectorAccess {
            ClaudeTextConnectorReaper.reap(profileURLs: access.ownedProfileURLs)
            // Every look at the user's screen this turn took left a file in
            // the user's own temporary folder; they go with the turn. Another bot's Control
            // this Mac turn running now loses its files too, which costs it
            // nothing: the picture was handed back when it was taken.
            if access.servers.contains(where: { $0.role == .macControl }) {
                MacControlScreenshotSweep.remove(modifiedSince: startedAt)
            }
        }
        let removed = promptFile.removeIfUnchanged()
        let connectorRemoved = connectorFile?.removeIfUnchanged() ?? true
        if transfer.isCancelled { return .cancelled }
        guard removed, connectorRemoved else {
            transfer.recordDiagnostic(.processFailed); return .failed(.processFailed)
        }
        return result
    }

    private static func executePrepared(request: ClaudeTextOnlyRequest, promptFile: ClaudeTextOnlyPromptFile,
                                        connectorFile: ClaudeTextOnlyPromptFile?,
                                        budget: ClaudeTextOnlyBudget, acceptedAt: UInt64,
                                        lastOutputAt: UInt64, overallDeadline: UInt64,
                                        transfer: ClaudeTextOnlyTransfer, control: ClaudeTextTurnControl?) -> ClaudeTextOnlyResult {
        var lastOutputAt = lastOutputAt
        // Moves on while a card waits for the user, and when they renew a
        // turn's rounds (below).
        var overallDeadline = overallDeadline
        // Card time given back to the ceiling since launch or the last
        // renewal, and when the loop last looked at an open card.
        var cardCredited: UInt64 = 0
        var cardSeenAt: UInt64?
        guard let userInput = try? ClaudeTextOnlyCommandBuilder.input(for: request) else { return .failed(.inputRejected) }
        // A work turn opens the control channel first, then sends the message;
        // both go out in order on the same pipe. Its stdin stays open for the
        // answers to the questions the child will ask, and closes once the
        // result has landed so the child can end normally.
        let controlID = UUID().uuidString.lowercased()
        var input = Data()
        if request.requiresPermissionControl {
            guard let handshake = try? ClaudeTextOnlyCommandBuilder.initializeControlRecord(
                id: controlID, appServer: request.carriesAppServer) else {
                return .failed(.inputRejected)
            }
            input.append(handshake)
        }
        input.append(userInput)
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
            // A work turn runs in the bot's own folder, the one its prompt names
            // as its working directory; a turn without work keeps the run's
            // private work directory as before.
            posix_spawn_file_actions_addchdir_np(&actions, (request.workAccess?.workingDirectoryURL ?? request.target.workingDirectoryURL).path)
        ]
        guard results.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return .failed(.launchFailed) }
        guard !transfer.isCancelled else { return .cancelled }
        guard !expired(budget, lastOutputAt: lastOutputAt, overallDeadline: overallDeadline) else {
            return timedOut(acceptedAt: acceptedAt, lastOutputAt: lastOutputAt, overallDeadline: overallDeadline,
                            cardCredited: 0, stage: "before launch")
        }
        guard promptFile.isUnchanged(), connectorFile?.isUnchanged() ?? true else { return .failed(.launchFailed) }
        var pid: pid_t = 0
        let argv = [request.target.executableURL.path] + ClaudeTextOnlyCommandBuilder.arguments(for: request)
        // A fresh mark per launch: every shell and script the CLI starts
        // inherits it, so the turn's cleanup can find them wherever they went.
        let mark = UUID().uuidString.lowercased()
        let launchedAt = Date()
        let shellTemporary: URL?
        switch ClaudeTextShellTemporaryDirectory.forLaunch(of: request) {
        case .notNeeded: shellTemporary = nil
        case .ready(let folder): shellTemporary = folder
        case .unavailable: return .failed(.launchFailed)
        }
        defer { if let shellTemporary { ClaudeTextShellTemporaryDirectory.remove(shellTemporary) } }
        var environment = ClaudeTextOnlyCommandBuilder.environment(for: request, shellTemporaryDirectory: shellTemporary)
        environment[ClaudeTextTurnProcessReaper.markName] = mark
        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let launched = withStrings(argv) { argv in
            withStrings(env) { envp in
                posix_spawn(&pid, request.target.executableURL.path, &actions, &attributes, argv, envp)
            }
        }
        guard launched == 0, pid > 1 else { return .failed(.launchFailed) }
        Darwin.close(inputPipe[0]); inputPipe[0] = -1
        Darwin.close(outputPipe[1]); outputPipe[1] = -1
        // The silence budget measures how long the child has produced nothing,
        // so it starts when the child exists, not when the turn was accepted.
        lastOutputAt = DispatchTime.now().uptimeNanoseconds
        var lastSnapshotAt = lastOutputAt

        var stream = ClaudeTextOnlyStream(request: request, control: control)
        if request.requiresPermissionControl { stream.expectControlInitialization(requestID: controlID) }
        var written = 0
        // Answers to the child's questions, queued by the host, written after
        // the message in the order they were made.
        var answers = Data()
        var answersWritten = 0
        var failure: ClaudeTextOnlyFailure?
        var exited = false
        var outputEOF = false
        var ceilingMovedForRenewalCard = false
        while !transfer.isCancelled, !expired(budget, lastOutputAt: lastOutputAt, overallDeadline: overallDeadline) {
            do {
                try drain(outputPipe[0], stream: &stream, transfer: transfer, control: control, reachedEOF: &outputEOF,
                          lastOutputAt: &lastOutputAt, lastSnapshotAt: &lastSnapshotAt, budget: budget,
                          overallDeadline: overallDeadline)
            } catch let rejection as ClaudeTextOnlyRejection {
                // A decline ends the turn at that frame, and nothing went wrong.
                if rejection.failure != .declined { transfer.recordDiagnostic(rejection.code) }
                failure = rejection.failure; break
            } catch let error as ClaudeTextOnlyFailure {
                transfer.recordDiagnostic(.streamReadFailed); failure = error; break
            } catch { failure = .invalidStream; break }
            republishForLease(stream, transfer: transfer, lastSnapshotAt: &lastSnapshotAt, budget: budget)
            // A child waiting on the user's decision is not a silent child: the
            // silence budget pauses while a question is open, and while the
            // card renewing the rounds waits. Nor is it working: the ceiling
            // measures the model's own time, so it moves on by every moment
            // any card is open, whatever kind. It moves while the card is
            // still open, not when it closes, so a long read that crosses the
            // ceiling does not end the turn under the user. At most
            // `cardCredit` is given back, so a turn nobody comes back to still
            // ends: ceiling plus credit from launch or from the last renewal.
            if let control, control.isAwaitingDecision {
                let now = DispatchTime.now().uptimeNanoseconds
                lastOutputAt = now
                if let seen = cardSeenAt, now > seen, cardCredited < budget.cardCredit {
                    let credit = min(now - seen, budget.cardCredit - cardCredited)
                    cardCredited += credit
                    let (moved, overflowed) = overallDeadline.addingReportingOverflow(credit)
                    overallDeadline = overflowed ? UInt64.max : moved
                }
                cardSeenAt = now
            } else {
                cardSeenAt = nil
            }
            // The renewal card waits ten minutes and unanswered is a Deny. A window of
            // sixty-four rounds can leave less than that of the ceiling measured
            // from launch, and the turn would end as "did not finish in time"
            // while the card still waited. So when the rounds run out the
            // ceiling is moved to a whole ceiling from now, once for each card,
            // never earlier: the card's own expiry comes first, and the turn is
            // still bounded, one ceiling past each card.
            if stream.isAwaitingRenewal, !ceilingMovedForRenewalCard {
                let (ceiling, overflowed) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(budget.macControlOverall ?? budget.overall)
                overallDeadline = max(overallDeadline, overflowed ? UInt64.max : ceiling)
                ceilingMovedForRenewalCard = true
            }
            // The user's answer to the renewal card, taken once, here, on the thread
            // that owns the stream. More rounds: the stream learns the new
            // message's id before a byte of it is written, so nothing the CLI
            // says about it can arrive first; then it goes out after any
            // answers already queued. The ceiling starts again with the new
            // allowance, since the user chose to give it: measured from launch, a
            // window of sixty-four rounds and a card that waited would leave
            // the renewal nothing. No: the turn ends here as the turn limit,
            // keeping what it wrote, and the child is reaped like any other.
            if let control, stream.isAwaitingRenewal, let decision = control.takeRoundsRenewalDecision() {
                if decision == .end { transfer.recordDiagnostic(.turnLimitReached); failure = .turnLimitReached; break }
                let renewalID = UUID()
                guard stream.acceptRenewal(messageID: renewalID),
                      let renewal = try? ClaudeTextOnlyCommandBuilder.renewalInput(messageID: renewalID, for: request) else {
                    failure = .inputRejected; break
                }
                answers.append(renewal)
                let now = DispatchTime.now().uptimeNanoseconds
                let (ceiling, overflowed) = now.addingReportingOverflow(budget.macControlOverall ?? budget.overall)
                overallDeadline = overflowed ? UInt64.max : ceiling
                lastOutputAt = now
                ceilingMovedForRenewalCard = false
                // A new window, and a new allowance of card time with it.
                cardCredited = 0
                cardSeenAt = nil
            }

            if inputPipe[1] >= 0, written < input.count {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(inputPipe[1], bytes.baseAddress!.advanced(by: written), input.count - written)
                }
                if count > 0 {
                    written += count
                    if written == input.count {
                        transfer.publish(.inputSubmitted(messageID: request.messageID))
                        if control == nil { Darwin.close(inputPipe[1]); inputPipe[1] = -1 }
                    }
                } else if count < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                    failure = .inputRejected; break
                }
            } else if inputPipe[1] >= 0, let control {
                for frame in control.takePending() { answers.append(frame) }
                if answersWritten < answers.count {
                    let count = answers.withUnsafeBytes { bytes in
                        Darwin.write(inputPipe[1], bytes.baseAddress!.advanced(by: answersWritten), answers.count - answersWritten)
                    }
                    if count > 0 { answersWritten += count }
                    else if count < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK { failure = .inputRejected; break }
                } else if stream.hasCompleted {
                    Darwin.close(inputPipe[1]); inputPipe[1] = -1
                }
            }

            // Keep the zombie leader's PID reserved until group cleanup; never
            // signal a possibly reused group ID after prematurely reaping it.
            var observation = siginfo_t()
            let waited = waitid(P_PID, id_t(pid), &observation, WEXITED | WNOHANG | WNOWAIT)
            if waited == 0, observation.si_pid == pid {
                exited = true
                do {
                    try drain(outputPipe[0], stream: &stream, transfer: transfer, control: control, reachedEOF: &outputEOF,
                              lastOutputAt: &lastOutputAt, lastSnapshotAt: &lastSnapshotAt, budget: budget,
                              overallDeadline: overallDeadline)
                } catch let rejection as ClaudeTextOnlyRejection {
                    if rejection.failure != .declined { transfer.recordDiagnostic(rejection.code) }
                    failure = rejection.failure
                } catch let error as ClaudeTextOnlyFailure {
                    transfer.recordDiagnostic(.streamReadFailed); failure = error
                } catch { failure = .invalidStream }
                break
            }
            if waited != 0, errno != EINTR { failure = .processFailed; break }
            let wantsToWrite = inputPipe[1] >= 0 && (written < input.count || answersWritten < answers.count)
            var descriptors = [pollfd(fd: outputEOF ? -1 : outputPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: wantsToWrite ? inputPipe[1] : -1, events: Int16(POLLOUT), revents: 0)]
            let polled = Darwin.poll(&descriptors, nfds_t(descriptors.count), 20)
            if polled < 0, errno != EINTR { failure = .processFailed; break }
        }
        // Which limit ended the loop is read now, before the reaping below
        // takes its own time.
        let loopEndedAt = DispatchTime.now().uptimeNanoseconds

        // Cleanup is independent of UI callbacks. It is group lifecycle control,
        // not containment against a program deliberately creating another group.
        // The CLI's Bash tool starts each command in a group of its own, so what
        // it ran is reaped first, while the CLI can still be found as its parent.
        ClaudeTextTurnProcessReaper.reap(cliPID: pid, mark: mark, startedAt: launchedAt, cliIsAlive: !exited)
        _ = Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        guard !transfer.isCancelled else { return .cancelled }
        if let failure { return .failed(failure) }
        guard exited else {
            return timedOut(acceptedAt: acceptedAt, lastOutputAt: lastOutputAt, overallDeadline: overallDeadline,
                            cardCredited: cardCredited, stage: "running", at: loopEndedAt)
        }
        guard reaped == pid, status & 0x7f == 0 else { return .failed(.processFailed) }
        guard written == input.count else { return .failed(.inputRejected) }
        return stream.finish(exitCode: (status >> 8) & 0xff) { transfer.recordDiagnostic($0) }
    }

    /// Nil for a turn the model declined: a diagnostic names a fault, and a
    /// decline is not one. It would also reach the saved reply as the status
    /// line "OpenBots diagnostic: …", which is machine text about a working
    /// turn that the person would read as a breakage.
    private static func diagnostic(for failure: ClaudeTextOnlyFailure) -> ClaudeTextOnlyDiagnosticCode? {
        switch failure {
        case .declined: nil
        case .launchRejected: .executableRejected
        case .launchFailed: .launchFailed
        case .inputRejected: .inputWriteFailed
        case .timedOut: .deadlineExceeded
        case .outputLimitExceeded: .outputLimitExceeded
        case .invalidStream: .incompleteResult
        case .unsafeInitialization: .invalidEnvelope
        case .providerFailed: .providerFailure
        case .turnLimitReached: .turnLimitReached
        case .sessionNotFound: .sessionNotFound
        case .processFailed: .processFailed
        }
    }

    /// A child that is working but not speaking produces no snapshot, and the
    /// turn's lease is renewed only by the checkpoint a snapshot causes. Once
    /// the input is acknowledged and until the result lands, the text so far is
    /// republished at the heartbeat cadence; it extends every earlier
    /// checkpoint, so the service saves it again and the lease moves on.
    private static func republishForLease(_ stream: ClaudeTextOnlyStream, transfer: ClaudeTextOnlyTransfer,
                                          lastSnapshotAt: inout UInt64, budget: ClaudeTextOnlyBudget) {
        guard stream.hasAcknowledgedInput, !stream.hasCompleted else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let (due, overflowed) = lastSnapshotAt.addingReportingOverflow(budget.leaseHeartbeat)
        guard !overflowed, now >= due else { return }
        transfer.publish(.textSnapshot(stream.textSoFar))
        lastSnapshotAt = now
    }

    private static func drain(_ descriptor: Int32, stream: inout ClaudeTextOnlyStream,
                              transfer: ClaudeTextOnlyTransfer, control: ClaudeTextTurnControl?, reachedEOF: inout Bool,
                              lastOutputAt: inout UInt64, lastSnapshotAt: inout UInt64,
                              budget: ClaudeTextOnlyBudget, overallDeadline: UInt64) throws {
        guard !reachedEOF else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        // Bound each drain batch so a continuously writing child cannot starve
        // cancellation, input delivery or the process/deadline observation.
        for _ in 0..<16 {
            guard !transfer.isCancelled,
                  !expired(budget, lastOutputAt: lastOutputAt, overallDeadline: overallDeadline) else { return }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                // Any byte from the child is progress. The silence budget restarts
                // here, so an answer that keeps streaming is never timed out.
                lastOutputAt = DispatchTime.now().uptimeNanoseconds
                try stream.consume(Data(bytes.prefix(count))) { event in
                    if case .textSnapshot = event { lastSnapshotAt = DispatchTime.now().uptimeNanoseconds }
                    // The channel learns of a question before the host does, so
                    // an answer arriving straight from the event is never early.
                    if case .permissionRequested(let question) = event { control?.register(question) }
                    if case .permissionCancelled(let id) = event { control?.withdraw(requestID: id) }
                    if case .roundsRanOut = event { control?.offerRoundsRenewal() }
                    transfer.publish(event)
                }
            } else if count == 0 { reachedEOF = true; return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { throw ClaudeTextOnlyFailure.invalidStream }
        }
    }

    /// Both limits end a turn as the one stored code, `deadlineExceeded`: a
    /// new code would be a saved status an older build (a rollback copy,
    /// or a public v1.0) refuses to read, and it reads every saved reply of a
    /// conversation together. So which limit fired is said here, in the log,
    /// with the numbers a reader needs, and nothing of the turn's content.
    private static func timedOut(acceptedAt: UInt64, lastOutputAt: UInt64, overallDeadline: UInt64,
                                 cardCredited: UInt64, stage: String,
                                 at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> ClaudeTextOnlyResult {
        let limit = now >= overallDeadline ? "whole-turn ceiling" : "silence budget"
        func seconds(_ nanoseconds: UInt64) -> String { String(format: "%.1f", Double(nanoseconds) / 1_000_000_000) }
        let sinceLaunch = seconds(now > acceptedAt ? now - acceptedAt : 0)
        let quiet = seconds(now > lastOutputAt ? now - lastOutputAt : 0)
        let credited = seconds(cardCredited)
        logger.error("""
            Text turn timed out \(stage, privacy: .public) on the \(limit, privacy: .public); \
            \(sinceLaunch, privacy: .public) s since launch, \(credited, privacy: .public) s of card time \
            given back to the ceiling, \(quiet, privacy: .public) s since the last output
            """)
        return .failed(.timedOut)
    }

    /// The effective deadline at any check is the earlier of the ceiling (as
    /// moved by card time and renewals) and the last output plus the silence
    /// budget.
    private static func expired(_ budget: ClaudeTextOnlyBudget, lastOutputAt: UInt64,
                                overallDeadline: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < overallDeadline else { return true }
        let (silenceDeadline, overflowed) = lastOutputAt.addingReportingOverflow(budget.silence)
        return !overflowed && now >= silenceDeadline
    }

    private static func matchesFingerprint(_ target: ClaudeConnectionTarget, budget: ClaudeTextOnlyBudget,
                                           lastOutputAt: UInt64, overallDeadline: UInt64,
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
        while !transfer.isCancelled, !expired(budget, lastOutputAt: lastOutputAt, overallDeadline: overallDeadline) {
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
