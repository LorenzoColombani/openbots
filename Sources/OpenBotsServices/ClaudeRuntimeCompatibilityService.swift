import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

public struct ClaudeRuntimeCompatibilitySource: Sendable {
    public let artifact: ClaudeRuntimeArtifact
    public let target: ClaudeConnectionTarget
    public init(artifact: ClaudeRuntimeArtifact, target: ClaudeConnectionTarget) {
        self.artifact = artifact; self.target = target
    }
}

public struct ClaudeRuntimeCompatibilityRequest: Sendable {
    public let candidate: ClaudeRuntimeArtifact
    public let candidateTarget: ClaudeConnectionTarget
    public let active: ClaudeRuntimeCompatibilitySource?
    public let contract: ClaudeRuntimeContract
    /// The caller freshly verified the separate profile, policy and official Pro/Max status.
    public let validationProfileReady: Bool
    public init(candidate: ClaudeRuntimeArtifact, candidateTarget: ClaudeConnectionTarget,
                active: ClaudeRuntimeCompatibilitySource? = nil, contract: ClaudeRuntimeContract,
                validationProfileReady: Bool = false) {
        self.candidate = candidate; self.candidateTarget = candidateTarget; self.active = active
        self.contract = contract; self.validationProfileReady = validationProfileReady
    }
}

public struct ClaudeRuntimeCompatibilityFailure: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case alreadyRunning, invalidTarget, fixtureUnavailable, nodeUnavailable, protocolEvidenceMissing
        case replyMismatch, toolEvidenceMissing, cleanupIncomplete, timedOut, runtimeFailed
    }
    public let failedCase: ClaudeRuntimeCompatibilityCase?
    public let reason: Reason
    public var message: String {
        let explanation: String
        switch reason {
        case .alreadyRunning: explanation = "A compatibility check is already running."
        case .invalidTarget: explanation = "The separate validation runtime or profile could not be verified."
        case .fixtureUnavailable: explanation = "The local compatibility fixture is unavailable."
        case .nodeUnavailable: explanation = "Node.js is needed to test this Claude Code version. Install it from nodejs.org or with Homebrew, then retry the compatibility checks."
        case .protocolEvidenceMissing: explanation = "The runtime did not provide the required initialization, replay and completion evidence."
        case .replyMismatch: explanation = "A synthetic model or session reply did not match the compatibility check."
        case .toolEvidenceMissing: explanation = "The synthetic approval or refusal check did not complete as required."
        case .cleanupIncomplete: explanation = "The compatibility process cleanup could not be confirmed."
        case .timedOut: explanation = "The compatibility check exceeded its time limit."
        case .runtimeFailed: explanation = "The runtime failed a compatibility check."
        }
        let label: String?
        switch failedCase {
        case .haikuReply: label = "Haiku reply"
        case .sonnetReply: label = "Sonnet reply"
        case .inertToolAllowed, .inertToolDenied: label = "Tool approval and refusal"
        case .cancellationCleanup: label = "Cancellation and cleanup"
        case .sessionContinuation: label = "Session continuation"
        case nil: label = nil
        }
        return label.map { $0 + ": " + explanation } ?? explanation
    }
    public init(failedCase: ClaudeRuntimeCompatibilityCase? = nil, reason: Reason) {
        self.failedCase = failedCase; self.reason = reason
    }
}

public enum ClaudeRuntimeCompatibilityResult: Equatable, Sendable {
    case passed(ClaudeRuntimeCompatibilityReceipt)
    case authenticationRequired
    case failed(ClaudeRuntimeCompatibilityFailure)
    case cancelled
}

public protocol ClaudeRuntimeCompatibilityChecking: Sendable {
    func run(_ request: ClaudeRuntimeCompatibilityRequest) async -> ClaudeRuntimeCompatibilityResult
    func cancelAndWait() async
}

/// No account, conversation, bot, memory or user-file repository enters this service.
/// Only the public initializer is available to app composition; it always uses the
/// production transport and requires its post-cleanup completion receipts.
public actor ClaudeRuntimeCompatibilityService: ClaudeRuntimeCompatibilityChecking {
    private let runner: any ClaudeTextOnlyRunning
    private let fixtureURL: URL?
    private let nodeResolver: @Sendable () -> URL?
    private let caseLimit: Duration
    private let overallLimit: Duration
    private let cleanupLimit: Duration
    private let requiresNativeReceipt: Bool
    private let diagnosticSink: @Sendable (String) -> Void
    private var operation: Task<ClaudeRuntimeCompatibilityResult, Never>?

    public init() {
        runner = NativeClaudeTextOnlyRunner()
        fixtureURL = ServicesResourceBundle.url(forResource: "claude-runtime-compatibility", withExtension: "js")
        // Resolved at each run, not at launch: Node installed after the app
        // started is found on the next retry. Same fixed paths as the connectors.
        nodeResolver = { InstalledToolResolution().firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs) }
        caseLimit = .seconds(120); overallLimit = .seconds(600); cleanupLimit = .seconds(30)
        requiresNativeReceipt = true
        diagnosticSink = { AgenticDiagnosticsLog.note("runtime-check", $0) }
    }

    // Offline tests only. No production call site can inject a synthetic runner.
    init(runner: any ClaudeTextOnlyRunning, fixtureURL: URL?, nodeURL: URL?,
         caseLimit: Duration = .seconds(120), overallLimit: Duration = .seconds(600),
         cleanupLimit: Duration = .seconds(30), requiresNativeReceipt: Bool = true,
         diagnosticSink: @escaping @Sendable (String) -> Void = { AgenticDiagnosticsLog.note("runtime-check", $0) }) {
        self.init(runner: runner, fixtureURL: fixtureURL, nodeResolver: { nodeURL }, caseLimit: caseLimit,
            overallLimit: overallLimit, cleanupLimit: cleanupLimit, requiresNativeReceipt: requiresNativeReceipt,
            diagnosticSink: diagnosticSink)
    }

    init(runner: any ClaudeTextOnlyRunning, fixtureURL: URL?, nodeResolver: @escaping @Sendable () -> URL?,
         caseLimit: Duration = .seconds(120), overallLimit: Duration = .seconds(600),
         cleanupLimit: Duration = .seconds(30), requiresNativeReceipt: Bool = true,
         diagnosticSink: @escaping @Sendable (String) -> Void = { AgenticDiagnosticsLog.note("runtime-check", $0) }) {
        self.runner = runner; self.fixtureURL = fixtureURL; self.nodeResolver = nodeResolver
        self.caseLimit = min(caseLimit, .seconds(120)); self.overallLimit = min(overallLimit, .seconds(600))
        self.cleanupLimit = min(cleanupLimit, .seconds(30)); self.requiresNativeReceipt = requiresNativeReceipt
        self.diagnosticSink = diagnosticSink
    }

    public func run(_ request: ClaudeRuntimeCompatibilityRequest) async -> ClaudeRuntimeCompatibilityResult {
        guard operation == nil else { return .failed(.init(reason: .alreadyRunning)) }
        guard request.validationProfileReady else { return .authenticationRequired }
        guard !Task.isCancelled else { return .cancelled }
        let suite = CompatibilitySuite(runner: runner, fixtureURL: fixtureURL, nodeURL: nodeResolver(),
            caseLimit: caseLimit, overallLimit: overallLimit, cleanupLimit: cleanupLimit,
            requiresNativeReceipt: requiresNativeReceipt, diagnosticSink: diagnosticSink)
        let task = Task { await suite.run(request) }
        operation = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        operation = nil
        return result
    }

    public func cancelAndWait() async {
        guard let task = operation else { return }
        task.cancel()
        _ = await task.value // Native runner returns only after its process tree has been reaped.
    }
}

private struct CompatibilitySuite: Sendable {
    let runner: any ClaudeTextOnlyRunning
    let fixtureURL: URL?
    let nodeURL: URL?
    let caseLimit: Duration
    let overallLimit: Duration
    let cleanupLimit: Duration
    let requiresNativeReceipt: Bool
    let diagnosticSink: @Sendable (String) -> Void
    private static let namespace = "openbots_compatibility"
    private static let system = "You are running an isolated OpenBots compatibility check. Follow the synthetic instruction exactly. No user data is present. Use only a requested inert compatibility tool, never ask questions and never retry a call."

    func run(_ input: ClaudeRuntimeCompatibilityRequest) async -> ClaudeRuntimeCompatibilityResult {
        var current: ClaudeRuntimeCompatibilityCase?
        var workspace: CompatibilityWorkspace?
        do {
            try validate(input)
            guard let fixtureURL else { throw failure(.fixtureUnavailable) }
            // Before the first prompt, so a missing interpreter spends no plan request.
            guard let nodeURL else { throw failure(.nodeUnavailable) }
            let files = try CompatibilityWorkspace(parent: input.candidateTarget.workingDirectoryURL, fixtureURL: fixtureURL)
            workspace = files
            let deadline = ContinuousClock.now.advanced(by: overallLimit)
            let candidate = try files.target(from: input.candidateTarget)
            let source = try files.target(from: input.active?.target ?? input.candidateTarget)
            let sourceArtifact = input.active?.artifact ?? input.candidate
            var passed = Set<ClaudeRuntimeCompatibilityCase>()

            current = .haikuReply
            try await reply(target: candidate, artifact: input.candidate, model: "haiku",
                prompt: "Reply with exactly OPENBOTS_HAIKU_OK.", expected: "OPENBOTS_HAIKU_OK", deadline: deadline)
            passed.insert(.haikuReply)
            current = .sonnetReply
            try await reply(target: candidate, artifact: input.candidate, model: "sonnet",
                prompt: "Reply with exactly OPENBOTS_SONNET_OK.", expected: "OPENBOTS_SONNET_OK", deadline: deadline)
            passed.insert(.sonnetReply)

            current = .inertToolAllowed
            let toolAccess = try files.access(caseName: "tools", nodeURL: nodeURL)
            let tools = try makeRequest(target: candidate, model: "haiku",
                text: "Call mcp__openbots_compatibility__allow once with {}. Then call mcp__openbots_compatibility__deny once with {}. The host intentionally refuses the second call. Do not retry either call. After both outcomes, reply with exactly OPENBOTS_TOOLS_OK.", access: toolAccess)
            _ = try await execute(tools, artifact: input.candidate, expected: "OPENBOTS_TOOLS_OK",
                mode: .tools, ledgerDirectory: files.root.appendingPathComponent("case-tools"), deadline: deadline)
            passed.formUnion([.inertToolAllowed, .inertToolDenied])

            current = .cancellationCleanup
            let cancelAccess = try files.access(caseName: "cancel", nodeURL: nodeURL)
            let cancel = try makeRequest(target: candidate, model: "haiku",
                text: "Call mcp__openbots_compatibility__stall exactly once with {} and wait for its response. Do not retry or call anything else.", access: cancelAccess)
            _ = try await execute(cancel, artifact: input.candidate, expected: nil, mode: .cancel,
                ledgerDirectory: files.root.appendingPathComponent("case-cancel"), deadline: deadline)
            passed.insert(.cancellationCleanup)

            current = .sessionContinuation
            let session = UUID()
            let secret = "OPENBOTS_MEMORY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            // Only the first prompt contains the nonce; the resume must recover it from the
            // CLI's own synthetic persistent session, across the active/candidate boundary.
            try await reply(target: source, artifact: sourceArtifact, model: "haiku",
                prompt: "Remember this synthetic token for the next turn: \(secret). Reply with exactly OPENBOTS_REMEMBERED.",
                expected: "OPENBOTS_REMEMBERED", session: session, persists: true, deadline: deadline)
            try await reply(target: candidate, artifact: input.candidate, model: "haiku",
                prompt: "Reply with only the exact synthetic token from the previous turn.", expected: secret,
                session: session, resumes: true, deadline: deadline)
            passed.insert(.sessionContinuation)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw failure(.timedOut) }
            try files.remove()
            workspace = nil
            return .passed(ClaudeRuntimeCompatibilityReceipt(artifact: input.candidate, contract: input.contract,
                compatibilityProfilePath: input.candidateTarget.profileURL.path,
                sourceRuntimeSHA256: input.active?.artifact.sha256, passedCases: passed, completedAt: Date()))
        } catch is CancellationError {
            try? workspace?.remove()
            return .cancelled
        } catch is CompatibilityAuthenticationRequired {
            try? workspace?.remove()
            return .authenticationRequired
        } catch {
            let reason = (error as? ClaudeRuntimeCompatibilityFailure)?.reason ?? .fixtureUnavailable
            let cleaned = workspace.map { (try? $0.remove()) != nil } ?? true
            if Task.isCancelled { return .cancelled }
            return .failed(.init(failedCase: current, reason: cleaned ? reason : .cleanupIncomplete))
        }
    }

    private func validate(_ input: ClaudeRuntimeCompatibilityRequest) throws {
        let target = input.candidateTarget
        guard input.candidate.isWellFormed, target.profileURL.lastPathComponent == "CompatibilityProfile",
              target.expectedExecutableSHA256 == input.candidate.sha256,
              !target.workingDirectoryURL.path.hasPrefix(target.profileURL.path + "/"),
              target.workingDirectoryURL != target.profileURL,
              !target.profileURL.path.hasPrefix(target.workingDirectoryURL.path + "/"),
              !input.contract.appBuild.isEmpty, input.contract.profileSchemaVersion == 1,
              input.contract.protocolRevision == 1,
              input.contract.suiteRevision == ClaudeRuntimeContract.currentSuiteRevision else { throw failure(.invalidTarget) }
        if let active = input.active {
            guard active.artifact.isWellFormed, active.target.profileURL == target.profileURL,
                  active.target.expectedExecutableSHA256 == active.artifact.sha256,
                  active.target.homeDirectoryURL == target.homeDirectoryURL else { throw failure(.invalidTarget) }
        }
    }

    private func makeRequest(target: ClaudeConnectionTarget, model: String, text: String,
                             access: ClaudeTextConnectorAccess? = nil, session: UUID = UUID(),
                             persists: Bool = false, resumes: Bool = false) throws -> ClaudeTextOnlyRequest {
        try ClaudeTextOnlyRequest(target: target, runID: UUID(), sessionID: session, messageID: UUID(),
            text: text, systemPrompt: Self.system, model: model, connectorAccess: access,
            persistsSession: persists, resumesSession: resumes)
    }

    private func reply(target: ClaudeConnectionTarget, artifact: ClaudeRuntimeArtifact, model: String,
                       prompt: String, expected: String, session: UUID = UUID(), persists: Bool = false,
                       resumes: Bool = false, deadline: ContinuousClock.Instant) async throws {
        let request = try makeRequest(target: target, model: model, text: prompt, session: session,
                                      persists: persists, resumes: resumes)
        _ = try await execute(request, artifact: artifact, expected: expected, mode: .text,
                              ledgerDirectory: nil, deadline: deadline)
    }

    private func execute(_ request: ClaudeTextOnlyRequest, artifact: ClaudeRuntimeArtifact, expected: String?,
                         mode: CompatibilityEvidence.Mode, ledgerDirectory: URL?,
                         deadline: ContinuousClock.Instant) async throws -> CompatibilityEvidence.Snapshot {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw failure(.timedOut) }
        let evidence = CompatibilityEvidence(request: request, artifact: artifact, mode: mode)
        var checkpoint = CompatibilityEvidence.Checkpoint.running
        var nativeResult: ClaudeTextOnlyResult?
        defer { diagnosticSink(evidence.diagnosticLine(checkpoint: checkpoint, result: nativeResult)) }
        let control = request.requiresPermissionControl ? ClaudeTextTurnControl() : nil
        let observer = ClaudeTextOnlyCompletionLog.observe { evidence.record($0) }
        defer { ClaudeTextOnlyCompletionLog.removeObserver(observer) }
        let task = Task { await runner.run(request: request, control: control) { evidence.record($0, control: control) } }
        let expires = min(deadline, ContinuousClock.now.advanced(by: caseLimit))
        let monitor = Task {
            while !Task.isCancelled {
                if ContinuousClock.now >= expires { evidence.cancel(timedOut: true); task.cancel(); return }
                if mode == .cancel, let ledgerDirectory,
                   let ledger = try? CompatibilityLedger.read(ledgerDirectory), ledger.count("executed_stall") == 1 {
                    evidence.cancel(timedOut: false); task.cancel(); return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        nativeResult = result
        monitor.cancel()
        _ = await monitor.value
        let proof = evidence.snapshot
        // Native execution has already reaped its leader and children. Confirm the
        // inert fixture's independently recorded process identities also disappeared.
        if let ledgerDirectory {
            checkpoint = .ledger
            let ledger = try CompatibilityLedger.read(ledgerDirectory)
            checkpoint = .childCleanup
            try await ledger.awaitExit(within: cleanupLimit)
            checkpoint = .ledger
            if mode == .tools {
                guard ledger.count("executed_allow") == 1, ledger.count("executed_deny") == 0,
                      ledger.count("executed_stall") == 0 else { throw failure(.toolEvidenceMissing) }
            } else if mode == .cancel {
                guard ledger.count("executed_stall") == 1, ledger.count("executed_allow") == 0,
                      ledger.count("executed_deny") == 0 else { throw failure(.toolEvidenceMissing) }
            }
        }
        checkpoint = .cancellation
        try Task.checkCancellation()
        checkpoint = .deadline
        if proof.timedOut { throw failure(.timedOut) }
        checkpoint = .authentication
        if result == .failed(.authenticationRequired) { throw CompatibilityAuthenticationRequired() }
        checkpoint = .lifecycleEvidence
        guard proof.protocolComplete else { throw failure(.protocolEvidenceMissing) }
        if mode == .cancel {
            checkpoint = .cancellationCleanup
            guard result == .cancelled, proof.intentionalCancellation, proof.provesStall,
                  let cancelledAt = proof.cancelledAt, ContinuousClock.now - cancelledAt <= cleanupLimit else {
                throw failure(.cleanupIncomplete)
            }
        } else {
            checkpoint = .nativeOutcome
            guard case .success(let reply) = result else { throw failure(.runtimeFailed) }
            checkpoint = .terminalModel
            guard reply.sessionID == request.sessionID, let initializedModel = proof.acceptedInitializedModel,
                  ClaudeExecutionSelection.normalizedReportedModel(reply.actualModel) == initializedModel,
                  reply.confirmedActualModel.flatMap(ClaudeExecutionSelection.normalizedReportedModel) == initializedModel else {
                throw failure(.protocolEvidenceMissing)
            }
            checkpoint = .sentinel
            guard reply.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected else { throw failure(.replyMismatch) }
            checkpoint = .nativeReceipt
            guard !requiresNativeReceipt || proof.hasNativeCompletion else { throw failure(.protocolEvidenceMissing) }
            if mode == .tools {
                checkpoint = .toolApprovalEvidence
                guard proof.provesAllowedAndDenied else { throw failure(.toolEvidenceMissing) }
            }
        }
        checkpoint = .passed
        return proof
    }

    private func failure(_ reason: ClaudeRuntimeCompatibilityFailure.Reason) -> ClaudeRuntimeCompatibilityFailure {
        .init(reason: reason)
    }
}

private struct CompatibilityAuthenticationRequired: Error {}

private final class CompatibilityEvidence: @unchecked Sendable {
    enum Mode: Sendable { case text, tools, cancel }
    enum Checkpoint: String { case running, ledger, childCleanup, cancellation, deadline, authentication,
        lifecycleEvidence, cancellationCleanup, nativeOutcome, terminalModel, sentinel, nativeReceipt, toolApprovalEvidence, passed }
    struct Snapshot: Sendable {
        var initialized = false, submitted = false, replayed = false, version = false, controlReady = false
        var invalid = false, hasNativeCompletion = false, timedOut = false, intentionalCancellation = false
        var cancelledAt: ContinuousClock.Instant?
        var initializedModel: String?, acceptedInitializedModel: String?, runtimeVersion: String?
        var diagnostic: ClaudeTextOnlyDiagnosticCode?
        var nativeReceipt: ClaudeTextOnlyCompletionReceipt?
        var allowed = Set<String>(), denied = Set<String>(), uses: [String: String] = [:], finished: [String: Bool] = [:]
        var protocolComplete: Bool { initialized && submitted && replayed && version && !invalid }
        var provesAllowedAndDenied: Bool {
            controlReady && allowed == ["allow"] && denied == ["deny"] && uses.count == 2
                && uses.first(where: { $0.value == "allow" }).map { finished[$0.key] == false } == true
                && uses.first(where: { $0.value == "deny" }).map { finished[$0.key] == true } == true
        }
        var provesStall: Bool { controlReady && allowed == ["stall"] && denied.isEmpty && uses.count == 1
            && uses.values.contains("stall") && finished.isEmpty }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    private let request: ClaudeTextOnlyRequest
    private let artifact: ClaudeRuntimeArtifact
    private let mode: Mode
    init(request: ClaudeTextOnlyRequest, artifact: ClaudeRuntimeArtifact, mode: Mode) {
        self.request = request; self.artifact = artifact; self.mode = mode
    }
    var snapshot: Snapshot { lock.withLock { value } }
    /// A closed metadata projection: no prompt, response text, path, tool input,
    /// authentication payload, arbitrary error description or provider diagnostic.
    /// The log's own line bound includes its category, so reserve twenty bytes.
    func diagnosticLine(checkpoint: Checkpoint, result: ClaudeTextOnlyResult?) -> String {
        let proof = snapshot
        let caseName: String
        switch mode {
        case .tools: caseName = "inertTools"
        case .cancel: caseName = "cancellationCleanup"
        case .text:
            caseName = request.resumesSession ? "sessionResume" : request.persistsSession ? "sessionSeed"
                : request.model == "haiku" ? "haikuReply" : "sonnetReply"
        }
        let outcome: String
        let actualModel: String?, confirmedModel: String?
        switch result {
        case .success(let reply): outcome = "success"; actualModel = reply.actualModel; confirmedModel = reply.confirmedActualModel
        case .failed(let failure): outcome = failure.rawValue; actualModel = nil; confirmedModel = nil
        case .cancelled: outcome = "cancelled"; actualModel = nil; confirmedModel = nil
        case nil: outcome = "unavailable"; actualModel = nil; confirmedModel = nil
        }
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        func count(_ value: Int?) -> String { value.map { String($0) } ?? "none" }
        let receipt = proof.nativeReceipt
        let line = "case=\(caseName) checkpoint=\(checkpoint.rawValue) run=\(request.runID.uuidString.lowercased()) outcome=\(outcome)"
            + " init=\(flag(proof.initialized)) submitted=\(flag(proof.submitted)) replay=\(flag(proof.replayed)) version=\(flag(proof.version))"
            + " invalid=\(flag(proof.invalid)) native=\(flag(proof.hasNativeCompletion)) control=\(flag(proof.controlReady))"
            + " diag=\(proof.diagnostic?.rawValue ?? "none")"
            // Fixed order: stdout bytes, calls, results, successful results, turns, renewals.
            + " counts=\(count(receipt?.stdoutBytes)),\(count(receipt?.toolCalls)),\(count(receipt?.toolResults)),\(count(receipt?.successfulToolResults)),\(count(receipt?.resultTurns)),\(count(receipt?.renewals))"
            + " expected_version=\(Self.version(artifact.version)) seen_version=\(Self.version(proof.runtimeVersion))"
            + " alias=\(request.model == "haiku" ? "haiku" : request.model == "sonnet" ? "sonnet" : "redacted")"
            + " catalog=\(Self.model(request.expectedResolvedModel)) init_model=\(Self.model(proof.initializedModel))"
            + " result_model=\(Self.model(actualModel)) confirmed=\(Self.model(confirmedModel))"
        return String(line.prefix(580))
    }
    private static func model(_ value: String?) -> String {
        guard let value else { return "none" }
        guard value.utf8.count <= 48, ClaudeExecutionSelection.normalizedReportedModel(value) != nil else { return "redacted" }
        return value
    }
    /// Compatibility exercises the provider's Haiku/Sonnet aliases, whose numeric
    /// version can advance beyond the bundled catalog. Freeze the admitted init
    /// identity for this request; terminal confirmation must match that identity.
    /// This is not catalog admission and cannot authorize another model family.
    private static func aliasIdentity(_ reported: String, requestedAlias: String) -> String? {
        guard requestedAlias == "haiku" || requestedAlias == "sonnet",
              let normalized = ClaudeExecutionSelection.normalizedReportedModel(reported) else { return nil }
        let prefix = "claude-" + requestedAlias + "-"
        guard normalized.hasPrefix(prefix) else { return nil }
        let version = normalized.dropFirst(prefix.count)
        let components = version.split(separator: "-", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ component in
            let numbers = component.split(separator: ".", omittingEmptySubsequences: false)
            return !numbers.isEmpty && numbers.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        }) else { return nil }
        return normalized
    }
    private static func version(_ value: String?) -> String {
        guard let value else { return "none" }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.utf8.count <= 32, parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return "redacted" }
        return value
    }
    func cancel(timedOut: Bool) {
        lock.withLock {
            value.timedOut = timedOut; value.intentionalCancellation = !timedOut
            value.cancelledAt = ContinuousClock.now
        }
    }
    func record(_ receipt: ClaudeTextOnlyCompletionReceipt) {
        guard receipt.runID == request.runID else { return }
        lock.withLock {
            value.nativeReceipt = receipt
            value.hasNativeCompletion = receipt.stdoutBytes > 0 && receipt.renewals == 0
                && receipt.toolCalls == (mode == .tools ? 2 : 0)
                && receipt.toolResults == receipt.toolCalls
                && receipt.successfulToolResults == (mode == .tools ? 1 : 0)
        }
    }
    func record(_ event: ClaudeTextOnlyEvent, control: ClaudeTextTurnControl?) {
        lock.withLock {
            switch event {
            case .initialized(let id, let model):
                guard value.initializedModel == nil else { value.invalid = true; return }
                value.initializedModel = model
                value.acceptedInitializedModel = Self.aliasIdentity(model, requestedAlias: request.model)
                value.initialized = id == request.sessionID && value.acceptedInitializedModel != nil
            case .inputSubmitted(let id): value.submitted = id == request.messageID
            case .inputAcknowledged(let id): value.replayed = id == request.messageID
            case .runtimeVersion(let version): value.runtimeVersion = version; value.version = version == artifact.version
            case .controlReady: value.controlReady = true
            case .diagnostic(let code): value.diagnostic = code; value.invalid = true
            case .permissionRequested(let permission):
                let tool = permission.toolName.replacingOccurrences(of: "mcp__openbots_compatibility__", with: "")
                let empty = (try? JSONSerialization.jsonObject(with: permission.inputJSON) as? [String: String])?.isEmpty == true
                let expected = mode == .tools ? ["allow", "deny"] : mode == .cancel ? ["stall"] : []
                let admitted = permission.admitted && permission.inputReadsAsSent && empty
                    && permission.toolName == "mcp__openbots_compatibility__" + tool && expected.contains(tool)
                    && !value.allowed.contains(tool) && !value.denied.contains(tool)
                let allow = admitted && tool != "deny"
                if !admitted { value.invalid = true }
                if allow { value.allowed.insert(tool) } else { value.denied.insert(tool) }
                if control?.respond(requestID: permission.requestID, allow: allow,
                    reason: "This inert compatibility call is intentionally refused.") != true { value.invalid = true }
            case .toolUse(let tool):
                let name = tool.toolName.replacingOccurrences(of: "mcp__openbots_compatibility__", with: "")
                let expected = mode == .tools ? ["allow", "deny"] : mode == .cancel ? ["stall"] : []
                if tool.toolName != "mcp__openbots_compatibility__" + name || !expected.contains(name)
                    || value.uses[tool.id] != nil || value.uses.values.contains(name) { value.invalid = true }
                value.uses[tool.id] = name
            case .toolFinished(let id, let failed):
                if value.uses[id] == nil || value.finished[id] != nil { value.invalid = true }
                value.finished[id] = failed
            default: break
            }
        }
    }
}

/// Only fixed fixture event names and process IDs are read; never transcript/tool payloads.
private struct CompatibilityLedger {
    struct Entry: Decodable { let event: String; let pid: Int32; let parentPID: Int32 }
    let entries: [Entry]
    func count(_ name: String) -> Int { entries.filter { $0.event == name }.count }
    static func read(_ directory: URL) throws -> Self {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("ledger-") }
        guard !names.isEmpty, names.count <= 4 else { throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing) }
        var entries: [Entry] = []
        let accepted: Set<String> = ["started", "initialized", "listed", "executed_allow", "executed_deny", "executed_stall", "stdin_closed", "terminated"]
        for name in names {
            guard name.hasSuffix(".jsonl"), !name.contains("/") else { throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing) }
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing) }
            defer { close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o7777 == 0o600,
                  metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 16_384 else {
                throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing)
            }
            let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: 16_385)
            guard data.count <= 16_384, data.last == 10 else { throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing) }
            let lines = data.split(separator: 10)
            guard lines.count <= 64 else { throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing) }
            let values = try lines.map { try JSONDecoder().decode(Entry.self, from: Data($0)) }
            guard let first = values.first, first.event == "started", first.pid > 1, first.parentPID > 1,
                  first.pid != getpid(), first.parentPID != getpid(), name == "ledger-\(first.pid).jsonl",
                  values.allSatisfy({ $0.pid == first.pid && accepted.contains($0.event) }) else {
                throw ClaudeRuntimeCompatibilityFailure(reason: .toolEvidenceMissing)
            }
            entries += values
        }
        return Self(entries: entries)
    }
    func awaitExit(within limit: Duration) async throws {
        let pids = Set(entries.filter { $0.event == "started" }.flatMap { [$0.pid, $0.parentPID] })
        let deadline = ContinuousClock.now.advanced(by: limit)
        while pids.contains(where: { Darwin.kill($0, 0) == 0 || errno != ESRCH }) {
            guard ContinuousClock.now < deadline else { throw ClaudeRuntimeCompatibilityFailure(reason: .cleanupIncomplete) }
            // Cleanup still completes when the caller has cancelled the suite.
            await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
        }
    }
}

private final class CompatibilityWorkspace {
    let root: URL
    private let identity: stat
    private let fixture: Data
    init(parent: URL, fixtureURL: URL) throws {
        // The freshly admitted target supplies this private owned parent. Refuse
        // lexical symlinks and preserve a replaced workspace on cleanup.
        guard let parentMetadata = Self.directoryMetadata(parent),
              parentMetadata.st_uid == geteuid(), parentMetadata.st_mode & 0o7777 == 0o700 else {
            throw ClaudeRuntimeCompatibilityFailure(reason: .invalidTarget)
        }
        fixture = try Data(contentsOf: fixtureURL)
        guard !fixture.isEmpty, fixture.count <= 32_768 else { throw ClaudeRuntimeCompatibilityFailure(reason: .fixtureUnavailable) }
        root = parent.appendingPathComponent("compatibility-" + UUID().uuidString, isDirectory: true)
        var metadata = stat()
        guard mkdir(root.path, 0o700) == 0, lstat(root.path, &metadata) == 0 else {
            throw ClaudeRuntimeCompatibilityFailure(reason: .fixtureUnavailable)
        }
        identity = metadata
        do {
            for name in ["workspace", "temporary", "case-tools", "case-cancel"] {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                guard mkdir(directory.path, 0o700) == 0 else { throw ClaudeRuntimeCompatibilityFailure(reason: .fixtureUnavailable) }
                if name.hasPrefix("case-") {
                    let file = directory.appendingPathComponent("claude-runtime-compatibility.js")
                    try fixture.write(to: file, options: .withoutOverwriting)
                    guard chmod(file.path, 0o600) == 0 else { throw ClaudeRuntimeCompatibilityFailure(reason: .fixtureUnavailable) }
                }
            }
        } catch { try? remove(); throw error }
    }
    func target(from original: ClaudeConnectionTarget) throws -> ClaudeConnectionTarget {
        try ClaudeConnectionTarget(executableURL: original.executableURL,
            expectedExecutableSHA256: original.expectedExecutableSHA256, profileURL: original.profileURL,
            workingDirectoryURL: root.appendingPathComponent("workspace"),
            temporaryDirectoryURL: root.appendingPathComponent("temporary"), homeDirectoryURL: original.homeDirectoryURL)
    }
    func access(caseName: String, nodeURL: URL) throws -> ClaudeTextConnectorAccess {
        let server = try ClaudeTextConnectorServer(name: "openbots_compatibility", role: .appleMailSend,
            program: .node(interpreterURL: nodeURL, entryPointURL: root.appendingPathComponent("case-" + caseName)
                .appendingPathComponent("claude-runtime-compatibility.js")), options: [], environment: [:])
        return try ClaudeTextConnectorAccess(servers: [server])
    }
    func remove() throws {
        guard let current = Self.directoryMetadata(root), current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino else { throw ClaudeRuntimeCompatibilityFailure(reason: .cleanupIncomplete) }
        try FileManager.default.removeItem(at: root)
    }

    /// Foundation may rewrite a physical /private/tmp path to its /tmp alias.
    /// Walk the supplied path without following any component instead of comparing
    /// those display spellings. This also checks intermediate directory symlinks.
    private static func directoryMetadata(_ url: URL) -> stat? {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        for component in url.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(descriptor)
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return metadata
    }
}
