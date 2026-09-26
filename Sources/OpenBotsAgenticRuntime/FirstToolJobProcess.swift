import ClaudeRuntimeProbeCore
import Foundation
import OpenBotsExecutionRules

public enum FirstToolJobProcessFailure: Error, Equatable, Sendable {
    case alreadyStarted, closed, notReady, busy, invalidInput, invalidPlan
    case admissionDenied, launchFailed, startupTimeout, wallTimeout
    case outputLimit, protocolViolation, unexpectedExit, requestLimit, writeFailed
    case providerFailure, cleanupFailed, consumerBackpressure
    case protocolRejected(ProbeToolControlDiagnostic)
}

public enum FirstToolJobProcessEvent: Equatable, Sendable {
    case started(sessionID: UUID, processID: Int32, processGroupID: Int32)
    case initialized
    case inputSubmitted(UUID)
    case inputAcknowledged(UUID)
    case assistantText(String)
    case toolRequested(ProbeToolInvocation)
    case approvalCancelled(String)
    case toolResult(String, failed: Bool)
    /// Already sanitized display data, never input to policy or execution.
    case providerFailureSummary(String)
    case completed(resultText: String)
    case failed(FirstToolJobProcessFailure)
    case stopped(ProbeToolSessionCleanup?)
}

/// Bounded, after-the-fact facts about one process for the diagnostics log:
/// how long launch and initialization took, the launch-path error that an
/// `admissionDenied` label stood for, and the tail of the peer's own stderr.
/// Display code never shows any of this; the peer's stderr is diagnostics only.
public struct FirstToolJobProcessDiagnostics: Equatable, Sendable {
    public static let standardErrorTailBytes = 4_096
    public static let summaryStandardErrorCharacters = 360

    public let launchedAfter: TimeInterval?
    public let initializedAfter: TimeInterval?
    public let launchErrorDescription: String?
    public let standardErrorTail: String

    public init(launchedAfter: TimeInterval?, initializedAfter: TimeInterval?,
                launchErrorDescription: String?, standardErrorTail: String) {
        self.launchedAfter = launchedAfter; self.initializedAfter = initializedAfter
        self.launchErrorDescription = launchErrorDescription; self.standardErrorTail = standardErrorTail
    }

    /// One log line's worth: timings, the launch error if any, then the END of
    /// the peer's stderr (the last lines name the cause; the first rarely do).
    public var summary: String {
        var parts = [timingSummary]
        if let launchErrorDescription { parts.append("launchError=\(launchErrorDescription)") }
        let tail = standardErrorTail.isEmpty ? "-" : String(standardErrorTail.suffix(Self.summaryStandardErrorCharacters))
        parts.append("cli-stderr(bounded)=\(tail)")
        return parts.joined(separator: "; ")
    }

    public var timingSummary: String {
        func seconds(_ value: TimeInterval?) -> String { value.map { String(format: "%.1fs", $0) } ?? "-" }
        return "launchedAfter=\(seconds(launchedAfter)) initializedAfter=\(seconds(initializedAfter))"
    }

    /// Lossy UTF-8, every control character (newlines, escapes, NUL) becomes a
    /// space, runs of whitespace collapse, and only the last `limit` characters
    /// survive. Never a displayed string; a bounded diagnostics field.
    public static func sanitizedLine(_ data: Data, limit: Int = standardErrorTailBytes) -> String {
        let text = String(decoding: data, as: UTF8.self)
        var collapsed = ""
        collapsed.reserveCapacity(min(text.utf8.count, limit))
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let isControl = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar.properties.isWhitespace
            if isControl { pendingSpace = !collapsed.isEmpty; continue }
            if pendingSpace { collapsed.append(" "); pendingSpace = false }
            collapsed.unicodeScalars.append(scalar)
        }
        return String(collapsed.suffix(limit))
    }
}

/// Opaque lifetime delegation to the existing job owner. It exposes process
/// identity and registration only; there is no raw transport or byte-send API.
public struct FirstToolJobProcessRegistration: Sendable {
    private let transport: ProbeToolSession
    public var processID: Int32 { transport.processID }
    public var processGroupID: Int32 { transport.processGroupID }
    fileprivate init(_ transport: ProbeToolSession) { self.transport = transport }
    public func attachConversation(to owner: ProbeReferenceJobSession, for ticket: ProbeReferenceConversationTicket) throws {
        try owner.attachConversation(transport, for: ticket)
    }
    public func registerWorker(id: UUID, in owner: ProbeReferenceJobSession) throws {
        try owner.registerWorker(id: id, session: transport)
    }
}

/// One explicitly admitted process, with no default production activation.
/// Services supplies fresh user/subscription/policy/path admission and prepared
/// files. Returning a plan from that required closure is the host's at-action
/// grant; the descriptive launchReady property is never treated as authority.
public actor FirstToolJobProcess {
    public typealias Admission = @Sendable () async throws -> FirstToolJobLaunchPlan
    public nonisolated let events: AsyncStream<FirstToolJobProcessEvent>

    private enum Phase { case idle, starting, running, finishing, finished }
    private let admission: Admission
    private let ledger: ApprovalLedger
    private let policyGeneration: UInt64
    private let continuation: AsyncStream<FirstToolJobProcessEvent>.Continuation
    private var phase = Phase.idle
    private var plan: FirstToolJobLaunchPlan?
    private var transport: ProbeToolSession?
    private var control: FirstToolControlBox?
    private var output: FirstToolProcessOutput?
    private var startupTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var wallDeadline: Task<Void, Never>?
    /// The wall budget counts working time only. While every pending
    /// invocation waits for the user's decision the clock pauses, bounded by
    /// the review allowance so a forgotten prompt cannot keep a process alive.
    private var wallRemaining: TimeInterval = 0
    private var wallSegmentStart: TimeInterval?
    private var reviewRemaining: TimeInterval = 0
    private var reviewDeadline: Task<Void, Never>?
    private var awaitingDecision = Set<String>()
    private var cleanup: ProbeToolSessionCleanup?
    private var launchTask: Task<ProbeToolSession, Error>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var initialInput: (UUID, String)?
    private var initialInputID: UUID?
    private var initialized = false
    private var initialInputAcknowledged = false
    private var writing = false
    private var requests = 0
    private var startTime: TimeInterval = 0
    private var launchedAt: TimeInterval?
    private var initializedAt: TimeInterval?
    private var launchErrorDescription: String?

    public init(policyGeneration: UInt64, ledger: ApprovalLedger, admission: @escaping Admission) {
        self.policyGeneration = policyGeneration; self.ledger = ledger; self.admission = admission
        let pair = AsyncStream<FirstToolJobProcessEvent>.makeStream(bufferingPolicy: .bufferingOldest(512))
        events = pair.stream; continuation = pair.continuation
    }

    /// Starts admission once. Actual launch/readiness and failure arrive on
    /// events; returning is not evidence that a child exists or is ready.
    public func start(initialInput text: String, id: UUID = UUID()) throws {
        guard phase == .idle else { throw FirstToolJobProcessFailure.alreadyStarted }
        guard Self.validInput(text) else { throw FirstToolJobProcessFailure.invalidInput }
        phase = .starting; initialInput = (id, text); initialInputID = id
        startTime = ProcessInfo.processInfo.systemUptime
        startupDeadline = deadline(after: 30, failure: .startupTimeout)
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.admitAndLaunch()
        }
    }

    public func sendInput(id: UUID = UUID(), text: String) async throws {
        guard phase == .running else { throw FirstToolJobProcessFailure.closed }
        guard initialized else { throw FirstToolJobProcessFailure.notReady }
        guard Self.validInput(text) else { throw FirstToolJobProcessFailure.invalidInput }
        try await writeInput(id: id, text: text)
    }

    /// Facts for the diagnostics log; available before, during and after finish.
    public func diagnostics() -> FirstToolJobProcessDiagnostics {
        let tail = output.map { FirstToolJobProcessDiagnostics.sanitizedLine($0.standardErrorTailSnapshot()) } ?? ""
        return FirstToolJobProcessDiagnostics(
            launchedAfter: launchedAt.map { max(0, $0 - startTime) },
            initializedAfter: initializedAt.map { max(0, $0 - startTime) },
            launchErrorDescription: launchErrorDescription, standardErrorTail: tail)
    }

    public func lifetimeRegistration() throws -> FirstToolJobProcessRegistration {
        // A buffered started event may reach the job owner after a short
        // process has already finished. Retain its lifetime/cleanup handoff;
        // this opaque registration cannot send bytes or restart execution.
        guard let transport else { throw FirstToolJobProcessFailure.notReady }
        return FirstToolJobProcessRegistration(transport)
    }

    /// Withdraw an old request without treating an already observed CLI
    /// cancellation as a new protocol failure. This can only deny, never allow.
    public func cancelApproval(requestID: String) async throws {
        guard phase == .running else { return }
        await drain()
        guard phase == .running else { return }
        try await performWrite { box, transport, timeout in
            try box.withControl { try $0.denyIfPending(requestID, transport: transport, timeout: timeout) }
        }
        decisionSettled(requestID)
    }

    public func approve(requestID: String, action: FrozenAction, receipt: ApprovalReceipt,
                        currentPolicyGeneration: UInt64, now: Date) async throws {
        // Process already-buffered cancellations before admitting this response.
        await drain()
        try await performWrite { box, transport, timeout in
            try box.withControl {
                try $0.approveAndSend(requestID, action: action, receipt: receipt,
                    currentPolicyGeneration: currentPolicyGeneration, now: now, transport: transport, timeout: timeout)
            }
        }
        decisionSettled(requestID)
    }

    public func deny(requestID: String) async throws {
        await drain()
        try await performWrite { box, transport, timeout in
            try box.withControl { try $0.denyAndSend(requestID, transport: transport, timeout: timeout) }
        }
        decisionSettled(requestID)
    }

    @discardableResult
    public func stop() async -> ProbeToolSessionCleanup? {
        await finish(failure: nil, result: nil)
        return cleanup
    }

    private func admitAndLaunch() async {
        do {
            let admitted = try await admission()
            guard phase == .starting, !Task.isCancelled else { return }
            guard Self.validLimits(admitted.limits), admitted.executablePath.hasPrefix("/"),
                  admitted.workingDirectoryPath.hasPrefix("/") else { throw FirstToolJobProcessFailure.invalidPlan }
            plan = admitted
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            guard elapsed < admitted.limits.startupTimeoutSeconds else { throw FirstToolJobProcessFailure.startupTimeout }
            startupDeadline?.cancel()
            startupDeadline = deadline(after: admitted.limits.startupTimeoutSeconds - elapsed, failure: .startupTimeout)
            wallRemaining = max(0, admitted.limits.maximumWallTimeSeconds - elapsed)
            reviewRemaining = admitted.limits.maximumReviewSeconds
            resumeWallClock()
            let sink = FirstToolProcessOutput()
            output = sink
            control = FirstToolControlBox(ProbeToolControlSession(sessionID: admitted.sessionID,
                teammateID: admitted.teammateID, runID: admitted.runID,
                policyGeneration: policyGeneration, ledger: ledger, role: admitted.role,
                webCapabilities: admitted.webCapabilities))
            let pending = Task.detached {
                try ProbeToolSession.launch(executable: URL(fileURLWithPath: admitted.executablePath),
                    arguments: admitted.arguments, environment: admitted.environment,
                    workingDirectory: URL(fileURLWithPath: admitted.workingDirectoryPath),
                    standardOutputHandler: { sink.append($0) }, standardOutputEOF: { sink.end() },
                    standardErrorHandler: { sink.stderr($0) })
            }
            launchTask = pending
            let child: ProbeToolSession
            do { child = try await pending.value }
            catch { throw FirstToolJobProcessFailure.launchFailed }
            guard phase == .starting else { return } // finish() owns late handles through launchTask.
            transport = child; phase = .running
            launchedAt = ProcessInfo.processInfo.systemUptime
            guard emit(.started(sessionID: admitted.sessionID, processID: child.processID, processGroupID: child.processGroupID)) else {
                await finish(failure: .consumerBackpressure, result: nil); return
            }
            try await performWrite { box, transport, timeout in
                try box.withControl { try $0.initializeAndSend(transport: transport, timeout: timeout) }
            }
            guard phase == .running else { return }
            readerTask = Task { [weak self] in
                for await _ in sink.signals {
                    guard let self else { return }
                    await self.drain()
                }
            }
            sink.wake()
        } catch {
            guard phase != .finishing, phase != .finished else { return }
            if !(error is FirstToolJobProcessFailure) {
                // The user-facing label stays `admissionDenied`; the diagnostics
                // log gets the enum description that stood behind it.
                launchErrorDescription = String(String(describing: error).prefix(240))
            }
            await finish(failure: (error as? FirstToolJobProcessFailure) ?? .admissionDenied, result: nil)
        }
    }

    private func writeInput(id: UUID, text: String) async throws {
        guard let plan else { throw FirstToolJobProcessFailure.notReady }
        guard !writing else { throw FirstToolJobProcessFailure.busy }
        guard requests < plan.limits.maximumRequests else {
            await finish(failure: .requestLimit, result: nil)
            throw FirstToolJobProcessFailure.requestLimit
        }
        requests += 1
        try await performWrite(submitted: id) { box, transport, timeout in
            try box.withControl { control in
                let record = try control.inputRecord(id: id, text: text)
                try transport.sendRecord(record, timeout: timeout)
                try control.markInputWritten(id)
            }
        }
    }

    private func performWrite(submitted: UUID? = nil,
                              _ operation: @escaping @Sendable (FirstToolControlBox, ProbeToolSession, TimeInterval) throws -> Void) async throws {
        guard phase == .running, let control, let transport, let plan else { throw FirstToolJobProcessFailure.closed }
        guard !writing else { throw FirstToolJobProcessFailure.busy }
        writing = true
        defer { writing = false; output?.wake() }
        do {
            try await Task.detached { try operation(control, transport, plan.limits.writeTimeoutSeconds) }.value
            guard phase == .running else { throw FirstToolJobProcessFailure.closed }
            if let submitted, !emit(.inputSubmitted(submitted)) { throw FirstToolJobProcessFailure.consumerBackpressure }
        } catch {
            if phase == .running {
                await finish(failure: (error as? FirstToolJobProcessFailure) ?? .writeFailed, result: nil)
            }
            throw error
        }
    }

    private func drain() async {
        guard phase == .running, !writing, let output, let control else { return }
        while phase == .running, !writing, let item = output.next() {
            switch item {
            case .failed(let failure): await finish(failure: failure, result: nil); return
            case .end: await finish(failure: .unexpectedExit, result: nil); return
            case .record(let record):
                do {
                    let observed = try control.withControl { parser in
                        let event = try parser.receive(record)
                        return (event, parser.lastAssistantText, parser.lastResultText, parser.lastProviderFailureSummary)
                    }
                    let event: FirstToolJobProcessEvent?
                    switch observed.0 {
                    case .transportMetadata: event = nil
                    case .controlInitialized:
                        guard let initialInput else { throw FirstToolJobProcessFailure.protocolViolation }
                        self.initialInput = nil
                        try await writeInput(id: initialInput.0, text: initialInput.1)
                        event = nil
                    case .initialized:
                        initialized = true
                        initializedAt = ProcessInfo.processInfo.systemUptime
                        if initialInputAcknowledged { startupDeadline?.cancel() }
                        event = .initialized
                    case .inputAcknowledged(let id):
                        if id == initialInputID {
                            initialInputAcknowledged = true
                            if initialized { startupDeadline?.cancel() }
                        }
                        event = .inputAcknowledged(id)
                    case .assistantMessage: event = observed.1.map(FirstToolJobProcessEvent.assistantText)
                    case .approvalRequired(let invocation):
                        decisionPending(invocation.requestID)
                        event = .toolRequested(invocation)
                    case .approvalReconfirmed(let id):
                        // The decision was already made and written once; the
                        // second callback is answered from it without a prompt.
                        try await performWrite { box, transport, timeout in
                            try box.withControl { try $0.reconfirmAndSend(id, transport: transport, timeout: timeout) }
                        }
                        event = nil
                    case .approvalCancelled(let id):
                        decisionSettled(id)
                        event = .approvalCancelled(id)
                    case .decisionEcho: event = nil
                    case .toolResult(let id, let failed): event = .toolResult(id, failed: failed)
                    case .turnCompleted: event = nil // a later input is queued; the CLI replays it next
                    case .completed(let failed):
                        if failed, let summary = observed.3, !emit(.providerFailureSummary(summary)) {
                            await finish(failure: .consumerBackpressure, result: nil)
                            return
                        }
                        await finish(failure: failed ? .providerFailure : nil, result: failed ? nil : (observed.2 ?? ""))
                        return
                    }
                    if let event, !emit(event) { await finish(failure: .consumerBackpressure, result: nil); return }
                } catch {
                    let diagnostic = control.withControl { $0.lastRejection }
                    let failure = (error as? FirstToolJobProcessFailure)
                        ?? diagnostic.map(FirstToolJobProcessFailure.protocolRejected) ?? .protocolViolation
                    await finish(failure: failure, result: nil)
                    return
                }
            }
        }
    }

    private func finish(failure: FirstToolJobProcessFailure?, result: String?) async {
        if phase == .finished { return }
        if phase == .finishing {
            await withCheckedContinuation { finishWaiters.append($0) }
            return
        }
        phase = .finishing
        startupDeadline?.cancel(); wallDeadline?.cancel(); reviewDeadline?.cancel(); startupTask?.cancel(); readerTask?.cancel()
        // An already-dispatched launch remains owned even after Stop. Late
        // handles are cleaned before any caller receives final cleanup evidence.
        if transport == nil, let launchTask { transport = try? await launchTask.value }
        if let transport {
            let normalCompletion = result != nil && failure == nil
            cleanup = await Task.detached {
                if normalCompletion {
                    transport.closeInput()
                    _ = transport.waitForExit(timeout: 0.25)
                }
                return transport.stop()
            }.value
        }
        // Stop interrupts the detached writer through the managed transport;
        // it never first waits on the parser lock held by that writer.
        control?.withControl { $0.stop() }
        output?.close()
        _ = emit(.stopped(cleanup))
        if let cleanup, !cleanup.processGroupGone || !cleanup.exited {
            _ = emit(.failed(.cleanupFailed))
        } else if let failure { _ = emit(.failed(failure)) }
        else if let result {
            if cleanup?.status == 0 { _ = emit(.completed(resultText: result)) }
            else { _ = emit(.failed(.unexpectedExit)) }
        }
        phase = .finished
        continuation.finish()
        let waiting = finishWaiters; finishWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    private func resumeWallClock() {
        guard phase == .running || phase == .starting, wallSegmentStart == nil else { return }
        if let paused = reviewDeadline { paused.cancel(); reviewDeadline = nil }
        wallSegmentStart = ProcessInfo.processInfo.systemUptime
        wallDeadline = deadline(after: wallRemaining, failure: .wallTimeout)
    }

    private func pauseWallClock() {
        guard let started = wallSegmentStart else { return }
        wallDeadline?.cancel(); wallDeadline = nil
        wallRemaining = max(0, wallRemaining - (ProcessInfo.processInfo.systemUptime - started))
        wallSegmentStart = nil
        reviewDeadline = deadline(after: reviewRemaining, failure: .wallTimeout)
        reviewSegmentStart = ProcessInfo.processInfo.systemUptime
    }

    private var reviewSegmentStart: TimeInterval?

    private func decisionPending(_ requestID: String) {
        awaitingDecision.insert(requestID)
        pauseWallClock()
    }

    private func decisionSettled(_ requestID: String) {
        awaitingDecision.remove(requestID)
        guard awaitingDecision.isEmpty, wallSegmentStart == nil else { return }
        if let started = reviewSegmentStart {
            reviewRemaining = max(0, reviewRemaining - (ProcessInfo.processInfo.systemUptime - started))
            reviewSegmentStart = nil
        }
        resumeWallClock()
    }

    private func deadline(after seconds: TimeInterval, failure: FirstToolJobProcessFailure) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.finish(failure: failure, result: nil)
        }
    }

    private func emit(_ event: FirstToolJobProcessEvent) -> Bool {
        if case .enqueued = continuation.yield(event) { return true }
        return false
    }

    private static func validInput(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= ProbeToolControlSession.maximumInputBytes && !text.contains("\0") }
    private static func validLimits(_ limits: FirstToolJobLaunchLimits) -> Bool {
        (1...8).contains(limits.maximumRequests) && (1...16).contains(limits.maximumTurnsPerRequest)
            && limits.maximumRequests * limits.maximumTurnsPerRequest <= 64
            && limits.maximumWallTimeSeconds.isFinite && (1...300).contains(limits.maximumWallTimeSeconds)
            && limits.maximumReviewSeconds.isFinite && (0...3_600).contains(limits.maximumReviewSeconds)
            && limits.startupTimeoutSeconds.isFinite && (0.1...30).contains(limits.startupTimeoutSeconds)
            && limits.startupTimeoutSeconds <= limits.maximumWallTimeSeconds
            && limits.writeTimeoutSeconds.isFinite && (0.1...5).contains(limits.writeTimeoutSeconds)
            && limits.writeTimeoutSeconds <= limits.maximumWallTimeSeconds
    }
}

/// The actor prevents concurrent parser reads while this box owns a detached
/// write. Stop closes the independent managed transport before taking its lock.
private final class FirstToolControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var control: ProbeToolControlSession
    init(_ control: ProbeToolControlSession) { self.control = control }
    func withControl<T>(_ body: (inout ProbeToolControlSession) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&control)
    }
}

private final class FirstToolProcessOutput: @unchecked Sendable {
    enum Item: Sendable { case record(Data), failed(FirstToolJobProcessFailure), end }
    let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [Item] = []
    private var partial = Data()
    private var bytes = 0
    private var records = 0
    private var ended = false
    /// The last few KiB of the peer's stderr, kept through close() for diagnostics.
    private var standardErrorTail = Data()
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = pair.stream; continuation = pair.continuation
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock(); wake() }
        guard !ended else { return }
        guard count(chunk.count) else { return }
        partial.append(chunk)
        while let newline = partial.firstIndex(of: 10) {
            guard newline <= 65_536, records < 256, pending.count < 64 else { fail(.outputLimit); return }
            let line = Data(partial[..<newline])
            guard !line.isEmpty else { fail(.protocolViolation); return }
            pending.append(.record(line)); records += 1; partial.removeSubrange(...newline)
        }
        if partial.count > 65_536 { fail(.outputLimit) }
    }
    func stderr(_ chunk: Data) {
        lock.lock(); defer { lock.unlock(); wake() }
        if !ended { _ = count(chunk.count) }
        standardErrorTail.append(chunk)
        let limit = FirstToolJobProcessDiagnostics.standardErrorTailBytes
        if standardErrorTail.count > limit { standardErrorTail.removeFirst(standardErrorTail.count - limit) }
    }
    func standardErrorTailSnapshot() -> Data { lock.lock(); defer { lock.unlock() }; return standardErrorTail }
    func end() {
        lock.lock(); defer { lock.unlock(); wake() }
        guard !ended else { return }
        if !partial.isEmpty { fail(.protocolViolation) }
        else { pending.append(.end); ended = true }
    }
    func next() -> Item? { lock.lock(); defer { lock.unlock() }; return pending.isEmpty ? nil : pending.removeFirst() }
    func wake() { continuation.yield(()) }
    func close() { lock.lock(); ended = true; pending.removeAll(); partial.removeAll(); lock.unlock(); continuation.finish() }
    private func count(_ amount: Int) -> Bool {
        guard amount <= 2_097_152 - bytes else { fail(.outputLimit); return false }
        bytes += amount; return true
    }
    private func fail(_ failure: FirstToolJobProcessFailure) {
        ended = true; partial.removeAll(); pending = [.failed(failure)]
    }
}
