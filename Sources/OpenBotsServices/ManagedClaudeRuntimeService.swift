import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime
import OpenBotsSecurity

public struct ManagedClaudeRuntimeSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case unavailable, idle, discovering, waitingForIdle, needsAuthentication
        case checking, ready, failed, cancelled, stopped
    }
    public let selection: ClaudeRuntimeState?
    public let phase: Phase
    public let message: String?
    public var active: ClaudeRuntimeArtifact? { selection?.active }
    public var previous: ClaudeRuntimeArtifact? { selection?.previous }
    public var candidate: ClaudeRuntimeArtifact? { selection?.candidate }
    public var isChecking: Bool { phase == .discovering || phase == .checking }

    public init(selection: ClaudeRuntimeState? = nil, phase: Phase = .idle, message: String? = nil) {
        self.selection = selection; self.phase = phase; self.message = message
    }
}

public protocol ManagedClaudeRuntimeServing: Sendable {
    func snapshot() async -> ManagedClaudeRuntimeSnapshot
    func updates() async -> AsyncStream<ManagedClaudeRuntimeSnapshot>
    @discardableResult func prepare() async -> ManagedClaudeRuntimeSnapshot
    @discardableResult func checkForUpdates() async -> ManagedClaudeRuntimeSnapshot
    @discardableResult func retry() async -> ManagedClaudeRuntimeSnapshot
    func cancel() async
    func shutdown() async
}

/// Owns discovery and one bounded probe task. The retained active selection is
/// independent of that task; promotion alone takes the application's idle freeze.
public actor ManagedClaudeRuntimeService: ManagedClaudeRuntimeServing {
    typealias StoreProvider = @Sendable () async throws -> any ClaudeRuntimeStoring
    typealias RetainedInspection = @Sendable (ClaudeRuntimeArtifact) async -> ClaudeInstallationInspection
    private let layout: PreviewStorageLayout
    private let compatibilityLayout: PreviewStorageLayout
    private let appBuild: String
    private let storeProvider: StoreProvider
    private let installedInspector: any ClaudeInstallationInspecting
    private let retainedInspection: RetainedInspection
    private let profileIdentity: @Sendable () async throws -> UUID
    private let prepareCompatibilityWork: @Sendable (ClaudeConnectionTarget) async throws -> ClaudeConnectionTarget
    private let compatibilityRunner: any ClaudeRuntimeCompatibilityChecking
    private let policy: any ClaudeTextPolicyInspecting
    private let status: any ClaudeStatusChecking
    private let blocker: @Sendable () async -> String?
    private let acquirePromotion: @Sendable (UUID) async -> Bool
    private let releasePromotion: @Sendable (UUID) async -> Void
    private var current = ManagedClaudeRuntimeSnapshot()
    private var observers: [UUID: AsyncStream<ManagedClaudeRuntimeSnapshot>.Continuation] = [:]
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var stopped = false
    /// Every copy handed to a consumer in this process. The selector has no
    /// release, so a launch may still be pending on one; pruning keeps them
    /// until the next app start.
    private var handedOut: Set<String> = []

    public init(layout: PreviewStorageLayout,
                applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?,
                appBuild: String,
                compatibilityRunner: any ClaudeRuntimeCompatibilityChecking,
                blocker: @escaping @Sendable () async -> String?,
                acquirePromotion: @escaping @Sendable (UUID) async -> Bool,
                releasePromotion: @escaping @Sendable (UUID) async -> Void) {
        let validation = layout.withClaudeProfilePurpose(.compatibility)
        let provider = ManagedClaudeRuntimeStoreProvider(layout: layout, root: applicationSupportRoot)
        self.init(layout: layout, appBuild: appBuild, storeProvider: { try await provider.store() },
            installedInspector: ClaudeInstallationInspector(homeDirectory: layout.homeDirectory),
            retainedInspection: { artifact in
                guard let root = await applicationSupportRoot(), !Task.isCancelled else {
                    return Self.unavailable(layout: layout)
                }
                return await RetainedClaudeInstallationInspector(applicationSupportRootURL: root.url,
                    installationID: root.installationID, rootID: root.rootID, artifact: artifact)
                    .inspectInstallation()
            }, profileIdentity: {
                guard let root = await applicationSupportRoot(), !Task.isCancelled else {
                    throw ManagedClaudeRuntimeFailure.storageUnavailable
                }
                try ClaudeProfileProvisioner().ensureExists(applicationSupportRoot: root, layout: validation)
                return try ClaudeProfileInspector().verifiedProfileIdentity(applicationSupportRoot: root, layout: validation)
            }, prepareCompatibilityWork: { target in
                guard let root = await applicationSupportRoot(), !Task.isCancelled else {
                    throw ManagedClaudeRuntimeFailure.storageUnavailable
                }
                return try Self.compatibilityWorkTarget(from: target, applicationSupportRoot: root, layout: layout)
            }, compatibilityRunner: compatibilityRunner, policy: NativeClaudeTextPolicyInspector(),
            status: NativeClaudeStatusChecker(), blocker: blocker,
            acquirePromotion: acquirePromotion, releasePromotion: releasePromotion)
    }

    /// Trusted host seams keep lifecycle and race tests entirely synthetic.
    init(layout: PreviewStorageLayout, appBuild: String,
         storeProvider: @escaping StoreProvider,
         installedInspector: any ClaudeInstallationInspecting,
         retainedInspection: @escaping RetainedInspection,
         profileIdentity: @escaping @Sendable () async throws -> UUID,
         prepareCompatibilityWork: @escaping @Sendable (ClaudeConnectionTarget) async throws -> ClaudeConnectionTarget,
         compatibilityRunner: any ClaudeRuntimeCompatibilityChecking,
         policy: any ClaudeTextPolicyInspecting, status: any ClaudeStatusChecking,
         blocker: @escaping @Sendable () async -> String?,
         acquirePromotion: @escaping @Sendable (UUID) async -> Bool,
         releasePromotion: @escaping @Sendable (UUID) async -> Void) {
        self.layout = layout; compatibilityLayout = layout.withClaudeProfilePurpose(.compatibility)
        self.appBuild = appBuild; self.storeProvider = storeProvider
        self.installedInspector = installedInspector; self.retainedInspection = retainedInspection
        self.profileIdentity = profileIdentity; self.compatibilityRunner = compatibilityRunner
        self.prepareCompatibilityWork = prepareCompatibilityWork
        self.policy = policy; self.status = status; self.blocker = blocker
        self.acquirePromotion = acquirePromotion; self.releasePromotion = releasePromotion
    }

    public func snapshot() -> ManagedClaudeRuntimeSnapshot { current }

    public func updates() -> AsyncStream<ManagedClaudeRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(current)
            guard !stopped else { continuation.finish(); return }
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    /// Startup and foreground use the same deduplicated discovery path.
    @discardableResult public func prepare() async -> ManagedClaudeRuntimeSnapshot {
        await checkForUpdates()
    }

    @discardableResult public func checkForUpdates() async -> ManagedClaudeRuntimeSnapshot {
        await start(retry: false)
    }

    /// Only explicit user retry clears a failed/interrupted attempt for this contract.
    @discardableResult public func retry() async -> ManagedClaudeRuntimeSnapshot {
        await start(retry: true)
    }

    public func cancel() async {
        operationID = UUID()
        let pending = operation
        pending?.cancel()
        await compatibilityRunner.cancelAndWait()
        await pending?.value
        operation = nil
        if !stopped { publish(.cancelled, "Compatibility check cancelled. The working runtime is unchanged.") }
    }

    public func shutdown() async {
        stopped = true
        await cancel()
        publish(.stopped, "Runtime checks stopped.")
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    func inspectSelectedRuntime(purpose: ManagedClaudeRuntimeSelector.Purpose) async -> ClaudeInstallationInspection {
        guard !stopped, !Task.isCancelled else { return Self.unavailable(layout: layout) }
        do {
            let state = try await storeProvider().load()
            let artifact: ClaudeRuntimeArtifact?
            switch purpose {
            case .active: artifact = state.active
            case .compatibilityCandidate: artifact = state.candidate
            }
            guard let artifact else {
                // A present installed candidate may still need its real gate;
                // report unavailable so normal setup never suggests reinstall.
                return Self.unavailable(layout: layout)
            }
            handedOut.insert(artifact.sha256)
            // Reinspect every operation, then freeze executable path/hash in the
            // consumer's target. A concurrent promotion cannot retarget that value.
            let inspection = await retainedInspection(artifact)
            guard !stopped, !Task.isCancelled, matches(inspection, artifact: artifact) else {
                return Self.unavailable(layout: layout)
            }
            return inspection
        } catch { return Self.unavailable(layout: layout) }
    }

    private func start(retry: Bool) async -> ManagedClaudeRuntimeSnapshot {
        guard !stopped, operation == nil else { return current }
        let token = UUID()
        operationID = token
        let task = Task { await self.performCheck(token: token, retry: retry) }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if operationID == token { operation = nil }
        return current
    }

    private func performCheck(token: UUID, retry: Bool) async {
        var attempted: (any ClaudeRuntimeStoring, ClaudeRuntimeState, ClaudeRuntimeContract)?
        do {
            try requireCurrent(token)
            publish(.discovering)
            let store = try await storeProvider()
            var state = try await store.load()
            setSelection(state)
            await pruneRetained(store, state: state)
            let installed = await installedInspector.inspectInstallation()
            try requireCurrent(token)
            if let artifact = artifact(from: installed), artifact.sha256 != state.active?.sha256,
               artifact.sha256 != state.candidate?.sha256,
               let source = installed.details.resolvedPath {
                state = try await store.importCandidate(sourceURL: URL(fileURLWithPath: source),
                    artifact: artifact, expectedGeneration: state.generation)
                setSelection(state)
                await pruneRetained(store, state: state)
            }
            guard let candidate = state.candidate else {
                publish(state.active == nil ? .unavailable : .ready,
                    state.active == nil ? "No verified Claude candidate is available." : nil)
                return
            }
            let identity = try await profileIdentity()
            let contract = ClaudeRuntimeContract(appBuild: appBuild, compatibilityProfileID: identity)
            try requireCurrent(token)
            if retry {
                state = try await store.explicitRetry(expectedGeneration: state.generation, contract: contract)
                setSelection(state)
            } else if let result = try await store.checkResult(artifactSHA256: candidate.sha256, contract: contract),
                      // Pending is an explicit retry that waited for idle; nothing
                      // has run yet, so it runs now rather than reading as failed.
                      result.status != .pending {
                if result.status == .passed, let receipt = result.receipt {
                    try await promote(receipt, state: state, store: store, token: token)
                } else {
                    publish(result.status == .needsAuthentication ? .needsAuthentication : .failed,
                        result.message ?? "This candidate was already checked or interrupted. Retry explicitly to check it again.")
                }
                return
            }
            if let reason = await blocker() {
                publish(.waitingForIdle, reason)
                return
            }
            try requireCurrent(token)
            attempted = (store, state, contract)
            let candidateTarget = try await verifiedTarget(candidate)
            let source: ClaudeRuntimeCompatibilitySource?
            if let active = state.active {
                source = .init(artifact: active, target: try await verifiedTarget(active))
            } else { source = nil }
            try requireCurrent(token)
            if let reason = await blocker() {
                publish(.waitingForIdle, reason)
                return
            }
            try requireCurrent(token)
            // Durable before starting any auth/model process: a crash never looks
            // like an untried candidate and cannot silently restart a costly probe.
            state = try await store.recordResult(.init(artifactSHA256: candidate.sha256,
                contract: contract, status: .running), expectedGeneration: state.generation)
            attempted = (store, state, contract)
            setSelection(state)
            publish(.checking)
            guard policy.inspect(profileURL: compatibilityLayout.claudeCLIProfileRoot) == .admitted else {
                throw ManagedClaudeRuntimeFailure.policyNotAdmitted
            }
            let authentication = await status.checkStatus(target: candidateTarget)
            try requireCurrent(token)
            switch authentication {
            case .eligible: break
            case .signedOut:
                state = try await store.recordResult(.init(artifactSHA256: candidate.sha256,
                    contract: contract, status: .needsAuthentication,
                    message: "Sign in to the separate Claude compatibility profile, then retry."),
                    expectedGeneration: state.generation)
                setSelection(state); publish(.needsAuthentication, state.lastResult?.message)
                return
            case .inconclusive:
                let message = "Claude compatibility sign-in status could not be verified. Retry the check."
                state = try await store.recordResult(.init(artifactSHA256: candidate.sha256,
                    contract: contract, status: .failed, message: message), expectedGeneration: state.generation)
                setSelection(state); publish(.failed, message)
                return
            case .cancelled: throw CancellationError()
            }
            try requireCurrent(token)
            // Auth status is scoped to the separate profile. The gate's actual
            // model work needs an independently protected parent outside it.
            let checkTarget = try await prepareCompatibilityWork(candidateTarget)
            guard checkTarget.executableURL == candidateTarget.executableURL,
                  checkTarget.expectedExecutableSHA256 == candidateTarget.expectedExecutableSHA256,
                  checkTarget.profileURL == candidateTarget.profileURL,
                  checkTarget.homeDirectoryURL == candidateTarget.homeDirectoryURL else {
                throw ManagedClaudeRuntimeFailure.invalidArtifact
            }
            let checkSource = try source.map {
                ClaudeRuntimeCompatibilitySource(artifact: $0.artifact,
                    target: try Self.scopedTarget(from: $0.target, working: checkTarget.workingDirectoryURL,
                                                  temporary: checkTarget.temporaryDirectoryURL))
            }
            try requireCurrent(token)
            let result = await compatibilityRunner.run(.init(candidate: candidate, candidateTarget: checkTarget,
                active: checkSource, contract: contract, validationProfileReady: true))
            try requireCurrent(token)
            switch result {
            case .passed(let receipt):
                guard receiptMatches(receipt, state: state, contract: contract) else {
                    throw ManagedClaudeRuntimeFailure.staleReceipt
                }
                state = try await store.recordResult(.init(artifactSHA256: candidate.sha256,
                    contract: contract, status: .passed, receipt: receipt), expectedGeneration: state.generation)
                attempted = nil
                setSelection(state)
                try await promote(receipt, state: state, store: store, token: token)
            case .authenticationRequired:
                state = try await store.recordResult(.init(artifactSHA256: candidate.sha256,
                    contract: contract, status: .needsAuthentication,
                    message: "Sign in to the separate Claude compatibility profile, then retry."),
                    expectedGeneration: state.generation)
                setSelection(state); publish(.needsAuthentication, state.lastResult?.message)
            case .failed(let failure):
                state = try await store.recordResult(.init(artifactSHA256: candidate.sha256,
                    contract: contract, status: .failed, message: failure.message), expectedGeneration: state.generation)
                setSelection(state); publish(.failed, failure.message)
            case .cancelled: throw CancellationError()
            }
        } catch {
            if let (store, state, contract) = attempted, let candidate = state.candidate {
                let result = ClaudeRuntimeCheckResult(artifactSHA256: candidate.sha256, contract: contract,
                    status: error is CancellationError ? .cancelled : .failed,
                    message: error is CancellationError ? "Compatibility check cancelled." : "The candidate could not complete its compatibility check.")
                if let saved = try? await store.recordResult(result, expectedGeneration: state.generation) {
                    setSelection(saved)
                }
            }
            guard operationID == token, !stopped else { return }
            publish(error is CancellationError ? .cancelled : .failed,
                error is CancellationError ? "Compatibility check cancelled." : "Runtime validation failed. The working runtime is unchanged.")
        }
    }

    private func promote(_ receipt: ClaudeRuntimeCompatibilityReceipt, state: ClaudeRuntimeState,
                         store: any ClaudeRuntimeStoring, token: UUID) async throws {
        try requireCurrent(token)
        guard receiptMatches(receipt, state: state, contract: receipt.contract) else {
            throw ManagedClaudeRuntimeFailure.staleReceipt
        }
        let freeze = UUID()
        guard await acquirePromotion(freeze) else {
            publish(.waitingForIdle, "Compatibility checks passed. The runtime can switch when OpenBots is idle.")
            return
        }
        do {
            try requireCurrent(token)
            let fresh = try await store.load()
            guard fresh == state, let candidate = fresh.candidate,
                  receipt.contract.appBuild == appBuild,
                  try await profileIdentity() == receipt.contract.compatibilityProfileID else {
                throw ManagedClaudeRuntimeFailure.staleReceipt
            }
            _ = try await verifiedTarget(candidate)
            try requireCurrent(token)
            let activated = try await store.promote(receipt: receipt, contract: receipt.contract,
                expectedGeneration: fresh.generation)
            await releasePromotion(freeze)
            setSelection(activated)
            publish(.ready)
            await pruneRetained(store, state: activated)
        } catch {
            await releasePromotion(freeze)
            throw error
        }
    }

    /// Best effort after each published selection: a copy that cannot go is
    /// logged and left, and never fails the check or the promotion.
    private func pruneRetained(_ store: any ClaudeRuntimeStoring, state: ClaudeRuntimeState) async {
        let keeping = handedOut.union([state.active, state.previous, state.candidate].compactMap { $0?.sha256 })
        do {
            let left = try await store.pruneRetained(keeping: keeping)
            if left > 0 { AgenticDiagnosticsLog.note("runtime-check", "prune left=\(left)") }
        } catch {
            AgenticDiagnosticsLog.note("runtime-check", "prune skipped error=\(String(describing: error))")
        }
    }

    private func verifiedTarget(_ artifact: ClaudeRuntimeArtifact) async throws -> ClaudeConnectionTarget {
        let inspection = await retainedInspection(artifact)
        guard matches(inspection, artifact: artifact), let path = inspection.details.resolvedPath else {
            throw ManagedClaudeRuntimeFailure.invalidArtifact
        }
        return try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: path),
            expectedExecutableSHA256: artifact.sha256, profileURL: compatibilityLayout.claudeCLIProfileRoot,
            workingDirectoryURL: compatibilityLayout.claudeCLIProfileRoot,
            temporaryDirectoryURL: compatibilityLayout.claudeCLIProfileRoot, homeDirectoryURL: layout.homeDirectory)
    }

    /// Shared by the public composition and its offline manager-to-gate test.
    /// The Content store revalidates root ownership and creates fresh 0700
    /// siblings of the profile; the gate owns cleanup of its disposable child.
    nonisolated static func compatibilityWorkTarget(from target: ClaudeConnectionTarget,
                                                   applicationSupportRoot: VerifiedOwnedRoot,
                                                   layout: PreviewStorageLayout) throws -> ClaudeConnectionTarget {
        let directories = try ClaudeTextRunDirectoryStore().create(runID: UUID(),
            applicationSupportRoot: applicationSupportRoot, layout: layout)
        return try scopedTarget(from: target, working: directories.workingDirectory, temporary: directories.temporaryDirectory)
    }

    private nonisolated static func scopedTarget(from target: ClaudeConnectionTarget, working: URL,
                                                 temporary: URL) throws -> ClaudeConnectionTarget {
        try ClaudeConnectionTarget(executableURL: target.executableURL,
            expectedExecutableSHA256: target.expectedExecutableSHA256, profileURL: target.profileURL,
            workingDirectoryURL: working, temporaryDirectoryURL: temporary, homeDirectoryURL: target.homeDirectoryURL)
    }

    private func matches(_ inspection: ClaudeInstallationInspection, artifact: ClaudeRuntimeArtifact) -> Bool {
        inspection.state == .verified
            && inspection.details.resolvedPath == layout.claudeRetainedExecutableURL(sha256: artifact.sha256).path
            && inspection.details.sha256 == artifact.sha256
            && inspection.details.signature?.identifier == artifact.signatureIdentifier
            && inspection.details.signature?.teamIdentifier == artifact.teamIdentifier
            && inspection.details.signature?.codeDirectoryHash == artifact.codeDirectoryHash
            && inspection.details.fileIdentity != nil
    }

    private func artifact(from inspection: ClaudeInstallationInspection) -> ClaudeRuntimeArtifact? {
        guard inspection.state == .verified, let version = inspection.details.versionFilename,
              let hash = inspection.details.sha256, let signature = inspection.details.signature,
              let codeHash = signature.codeDirectoryHash, inspection.details.fileIdentity != nil else { return nil }
        let value = ClaudeRuntimeArtifact(version: version, sha256: hash,
            signatureIdentifier: signature.identifier, teamIdentifier: signature.teamIdentifier, codeDirectoryHash: codeHash)
        return value.isWellFormed ? value : nil
    }

    private func receiptMatches(_ receipt: ClaudeRuntimeCompatibilityReceipt, state: ClaudeRuntimeState,
                                contract: ClaudeRuntimeContract) -> Bool {
        receipt.artifact == state.candidate && receipt.contract == contract
            && receipt.compatibilityProfilePath == compatibilityLayout.claudeCLIProfileRoot.path
            && receipt.sourceRuntimeSHA256 == state.active?.sha256
            && receipt.passedCases == Set(ClaudeRuntimeCompatibilityCase.allCases)
            && receipt.completedAt.timeIntervalSince1970.isFinite
    }

    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !stopped, operationID == token else { throw CancellationError() }
    }

    private func setSelection(_ state: ClaudeRuntimeState) {
        current = .init(selection: state, phase: current.phase, message: current.message)
        emit()
    }

    private func publish(_ phase: ManagedClaudeRuntimeSnapshot.Phase, _ message: String? = nil) {
        current = .init(selection: current.selection, phase: phase, message: message)
        emit()
    }
    private func emit() { for continuation in observers.values { continuation.yield(current) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private nonisolated static func unavailable(layout: PreviewStorageLayout) -> ClaudeInstallationInspection {
        .init(state: .unavailable(.invalidPolicy), details: .init(requestedPath: layout.claudeRetainedRoot.path))
    }
}

private enum ManagedClaudeRuntimeFailure: Error { case storageUnavailable, invalidArtifact, policyNotAdmitted, staleReceipt }

private actor ManagedClaudeRuntimeStoreProvider {
    private let layout: PreviewStorageLayout
    private let root: @Sendable () async -> VerifiedOwnedRoot?
    private var cached: (any ClaudeRuntimeStoring)?
    init(layout: PreviewStorageLayout, root: @escaping @Sendable () async -> VerifiedOwnedRoot?) {
        self.layout = layout; self.root = root
    }
    func store() async throws -> any ClaudeRuntimeStoring {
        if let cached { return cached }
        guard let root = await root() else { throw ManagedClaudeRuntimeFailure.storageUnavailable }
        if let cached { return cached }
        let value = ClaudeRuntimeStore(applicationSupportRoot: root, layout: layout)
        cached = value
        return value
    }
}
