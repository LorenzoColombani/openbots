import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private let runtimeA = ClaudeRuntimeArtifact(version: "1.0.0", sha256: String(repeating: "a", count: 64),
    signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW", codeDirectoryHash: String(repeating: "a", count: 40))
private let runtimeB = ClaudeRuntimeArtifact(version: "2.0.0", sha256: String(repeating: "b", count: 64),
    signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW", codeDirectoryHash: String(repeating: "b", count: 40))
private let runtimeC = ClaudeRuntimeArtifact(version: "3.0.0", sha256: String(repeating: "c", count: 64),
    signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW", codeDirectoryHash: String(repeating: "c", count: 40))

private actor ManagedStoreFixture: ClaudeRuntimeStoring {
    private struct Key: Hashable { let hash: String; let contract: ClaudeRuntimeContract }
    var value: ClaudeRuntimeState
    var promotions = 0
    var recorded: [ClaudeRuntimeCheckResult] = []
    var pruned: [Set<String>] = []
    private var pruneFails = false
    private var history: [Key: ClaudeRuntimeCheckResult] = [:]
    init(_ value: ClaudeRuntimeState) {
        self.value = value
        if let result = value.lastResult {
            history[Key(hash: result.artifactSHA256, contract: result.contract)] = result
        }
    }
    func load() -> ClaudeRuntimeState { value }
    func checkResult(artifactSHA256: String, contract: ClaudeRuntimeContract) -> ClaudeRuntimeCheckResult? {
        history[Key(hash: artifactSHA256, contract: contract)]
    }
    private func check(_ generation: UInt64) throws {
        guard value.generation == generation else { throw ClaudeRuntimeStoreError.staleGeneration }
    }
    func importCandidate(sourceURL: URL, artifact: ClaudeRuntimeArtifact, expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        try check(expectedGeneration)
        value = .init(active: value.active, previous: value.previous, candidate: artifact,
                      generation: value.generation + 1, activeReceipt: value.activeReceipt)
        return value
    }
    func recordResult(_ result: ClaudeRuntimeCheckResult, expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        try check(expectedGeneration)
        recorded.append(result)
        history[Key(hash: result.artifactSHA256, contract: result.contract)] = result
        value = .init(active: value.active, previous: value.previous, candidate: value.candidate,
                      generation: value.generation + 1, lastResult: result, activeReceipt: value.activeReceipt)
        return value
    }
    func promote(receipt: ClaudeRuntimeCompatibilityReceipt, contract: ClaudeRuntimeContract,
                 expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        try Task.checkCancellation()
        try check(expectedGeneration)
        guard value.lastResult?.status == .passed, value.lastResult?.receipt == receipt,
              value.candidate == receipt.artifact else { throw ClaudeRuntimeStoreError.invalidReceipt }
        promotions += 1
        value = .init(active: receipt.artifact, previous: value.active, generation: value.generation + 1,
                      lastResult: value.lastResult, activeReceipt: receipt)
        return value
    }
    func reject(reason: String, expectedGeneration: UInt64) throws -> ClaudeRuntimeState {
        try check(expectedGeneration)
        return value
    }
    func explicitRetry(expectedGeneration: UInt64, contract: ClaudeRuntimeContract) throws -> ClaudeRuntimeState {
        try check(expectedGeneration)
        if let candidate = value.candidate {
            history[Key(hash: candidate.sha256, contract: contract)] = .init(artifactSHA256: candidate.sha256,
                contract: contract, status: .pending)
        }
        value = .init(active: value.active, previous: value.previous, candidate: value.candidate,
                      generation: value.generation + 1, activeReceipt: value.activeReceipt)
        return value
    }
    func failPruning() { pruneFails = true }
    func pruneRetained(keeping: Set<String>) throws -> Int {
        pruned.append(keeping)
        if pruneFails { throw ClaudeRuntimeStoreError.unavailable }
        return 0
    }
    func replaceCandidate() {
        value = .init(active: value.active, previous: value.previous, candidate: runtimeC,
                      generation: value.generation + 1, activeReceipt: value.activeReceipt)
    }
}

private struct ManagedInstalledFixture: ClaudeInstallationInspecting {
    let inspection: ClaudeInstallationInspection
    func inspectInstallation() async -> ClaudeInstallationInspection { inspection }
}

private actor ManagedInspectionFixture {
    let layout: PreviewStorageLayout
    var calls: [ClaudeRuntimeArtifact] = []
    var reject = false
    init(_ layout: PreviewStorageLayout) { self.layout = layout }
    func setRejected() { reject = true }
    func inspect(_ artifact: ClaudeRuntimeArtifact) -> ClaudeInstallationInspection {
        calls.append(artifact)
        return Self.inspection(artifact, at: layout.claudeRetainedExecutableURL(sha256: artifact.sha256), rejected: reject)
    }
    static func inspection(_ artifact: ClaudeRuntimeArtifact, at url: URL, rejected: Bool = false) -> ClaudeInstallationInspection {
        .init(state: rejected ? .rejected(.changedDuringInspection) : .verified,
              details: .init(requestedPath: url.path, resolvedPath: url.path, versionFilename: artifact.version,
                sha256: artifact.sha256, signature: .init(identifier: artifact.signatureIdentifier,
                    teamIdentifier: artifact.teamIdentifier, codeDirectoryHash: artifact.codeDirectoryHash),
                fileIdentity: .init(device: 1, inode: 2, byteCount: 20)))
    }
}

private actor ManagedAdmissionFixture {
    var busy = false
    var owner: UUID?
    var acquired = 0
    var released = 0
    func setBusy(_ value: Bool) { busy = value }
    func blocker() -> String? { busy ? "A normal turn is running." : nil }
    func acquire(_ token: UUID) -> Bool {
        guard !busy, owner == nil else { return false }
        owner = token; acquired += 1
        return true
    }
    func release(_ token: UUID) {
        guard owner == token else { return }
        released += 1; owner = nil
    }
}

private actor ManagedStatusFixture: ClaudeStatusChecking {
    var result: ClaudeConnectionStatusResult = .eligible(.pro)
    var targets: [ClaudeConnectionTarget] = []
    func set(_ value: ClaudeConnectionStatusResult) { result = value }
    func checkStatus(target: ClaudeConnectionTarget) async -> ClaudeConnectionStatusResult {
        targets.append(target); return result
    }
}

private struct ManagedPolicyFixture: ClaudeTextPolicyInspecting {
    func inspect(profileURL: URL) -> ClaudeTextPolicyAdmission { .admitted }
}

private actor ManagedRunnerFixture: ClaudeRuntimeCompatibilityChecking {
    enum Mode: Sendable { case pass, incomplete, wrongContract, suspend }
    var mode: Mode = .pass
    var requests: [ClaudeRuntimeCompatibilityRequest] = []
    var afterRun: (@Sendable () async -> Void)?
    var pending: CheckedContinuation<Void, Never>?
    var started: [CheckedContinuation<Void, Never>] = []
    var cancellations = 0
    func configure(_ mode: Mode, afterRun: (@Sendable () async -> Void)? = nil) {
        self.mode = mode; self.afterRun = afterRun
    }
    func waitUntilStarted() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { started.append($0) }
    }
    func run(_ request: ClaudeRuntimeCompatibilityRequest) async -> ClaudeRuntimeCompatibilityResult {
        requests.append(request)
        for waiter in started { waiter.resume() }; started.removeAll()
        if mode == .suspend { await withCheckedContinuation { pending = $0 } }
        await afterRun?()
        let contract = mode == .wrongContract
            ? ClaudeRuntimeContract(appBuild: "older-app", compatibilityProfileID: request.contract.compatibilityProfileID)
            : request.contract
        // Deliberately returns pass even after cancellation, to model a late
        // provider result and prove that the manager's generation fence wins.
        return .passed(.init(artifact: request.candidate, contract: contract,
            compatibilityProfilePath: request.candidateTarget.profileURL.path,
            sourceRuntimeSHA256: request.active?.artifact.sha256,
            passedCases: mode == .incomplete ? [.haikuReply] : Set(ClaudeRuntimeCompatibilityCase.allCases),
            completedAt: Date()))
    }
    func cancelAndWait() async {
        cancellations += 1
        pending?.resume(); pending = nil
    }
}

private struct ManagedFixture: Sendable {
    let layout: PreviewStorageLayout
    let store: ManagedStoreFixture
    let runner = ManagedRunnerFixture()
    let admission = ManagedAdmissionFixture()
    let status = ManagedStatusFixture()
    let inspection: ManagedInspectionFixture
    let service: ManagedClaudeRuntimeService

    init(active: ClaudeRuntimeArtifact? = runtimeA, candidate: ClaudeRuntimeArtifact? = nil,
         lastResult: ClaudeRuntimeCheckResult? = nil,
         layout: PreviewStorageLayout = PreviewStorageLayout(homeDirectory: URL(fileURLWithPath: "/synthetic-runtime-home"),
             systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp/runtime-manager.noindex")),
         compatibilityRunner: (any ClaudeRuntimeCompatibilityChecking)? = nil,
         prepareWork: (@Sendable (ClaudeConnectionTarget) async throws -> ClaudeConnectionTarget)? = nil) {
        self.layout = layout
        store = ManagedStoreFixture(.init(active: active, candidate: candidate, lastResult: lastResult))
        inspection = ManagedInspectionFixture(layout)
        let store = self.store, inspection = self.inspection, runner = self.runner
        let admission = self.admission, status = self.status
        let profileID = UUID()
        service = ManagedClaudeRuntimeService(layout: layout, appBuild: "build:source:1", storeProvider: { store },
            installedInspector: ManagedInstalledFixture(inspection: ManagedInspectionFixture.inspection(runtimeB,
                at: URL(fileURLWithPath: "/synthetic-runtime-home/.local/share/claude/versions/2.0.0"))),
            retainedInspection: { await inspection.inspect($0) }, profileIdentity: { profileID },
            prepareCompatibilityWork: prepareWork ?? { target in
                try ClaudeConnectionTarget(executableURL: target.executableURL,
                    expectedExecutableSHA256: target.expectedExecutableSHA256, profileURL: target.profileURL,
                    workingDirectoryURL: layout.runtimeRoot.appending(path: "CompatibilityWork.noindex"),
                    temporaryDirectoryURL: layout.runtimeRoot.appending(path: "CompatibilityTemp.noindex"),
                    homeDirectoryURL: target.homeDirectoryURL)
            }, compatibilityRunner: compatibilityRunner ?? runner, policy: ManagedPolicyFixture(), status: status,
            blocker: { await admission.blocker() }, acquirePromotion: { await admission.acquire($0) },
            releasePromotion: { await admission.release($0) })
    }
}

private struct ManagedOwnedRuntimeFixture: Sendable {
    let directory: URL
    let layout: PreviewStorageLayout
    let root: VerifiedOwnedRoot
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ManagedRuntimeComposition-\(UUID()).noindex", isDirectory: true)
        layout = PreviewStorageLayout(homeDirectory: directory.appending(path: "Home", directoryHint: .isDirectory),
            systemTemporaryDirectory: directory.appending(path: "Temporary", directoryHint: .isDirectory))
        let descriptor = layout.applicationSupportRoot
        try FileManager.default.createDirectory(at: descriptor.url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let installationID = UUID(), rootID = UUID()
        try JSONEncoder().encode(OwnedRootMarker(installationID: installationID, rootID: rootID, kind: .applicationSupport))
            .write(to: descriptor.ownershipMarkerURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.ownershipMarkerURL.path)
        root = try OwnedRootVerifier().verify(descriptor, expectedInstallationID: installationID, expectedRootID: rootID)
        for child in [layout.highChurnRoot, layout.runtimeRoot, layout.runtimeRoot.appending(path: "Claude", directoryHint: .isDirectory)] {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try ClaudeProfileProvisioner().ensureExists(applicationSupportRoot: root, layout: layout.withClaudeProfilePurpose(.compatibility))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ManagedTargetBoundaryRunner: ClaudeTextOnlyRunning {
    var requests: [ClaudeTextOnlyRequest] = []
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        return .failed(.authenticationRequired)
    }
}

@Suite("Managed retained runtime orchestration")
private struct ManagedClaudeRuntimeServiceTests {
    @Test func normalSelectionIsActiveOnlyAndFreshForEveryOperation() async {
        let fixture = ManagedFixture(candidate: runtimeB)
        let normal = ManagedClaudeRuntimeSelector(service: fixture.service)
        let setup = ManagedClaudeRuntimeSelector(service: fixture.service, purpose: .compatibilityCandidate)
        #expect(await normal.inspectInstallation().details.sha256 == runtimeA.sha256)
        #expect(await setup.inspectInstallation().details.sha256 == runtimeB.sha256)
        #expect(await normal.inspectInstallation().details.sha256 == runtimeA.sha256)
        #expect(await fixture.inspection.calls == [runtimeA, runtimeB, runtimeA])
        #expect(await fixture.runner.requests.isEmpty)
    }

    @Test func bootstrapCandidateCannotEnterNormalConnection() async {
        let fixture = ManagedFixture(active: nil, candidate: runtimeB)
        let normal = ManagedClaudeRuntimeSelector(service: fixture.service)
        #expect(await normal.inspectInstallation().state != .verified)
        let setup = ManagedClaudeRuntimeSelector(service: fixture.service, purpose: .compatibilityCandidate)
        #expect(await setup.inspectInstallation().state == .verified)
        let preparer = NativeClaudeConnectionPreparer(layout: fixture.layout,
            installationInspector: normal, applicationSupportRoot: { nil })
        guard case .refused(let report) = await preparer.prepareConnection() else {
            Issue.record("An untested candidate entered normal connection preparation"); return
        }
        #expect(report.outcome == .problem(.installationUnavailable))
        #expect(await fixture.runner.requests.isEmpty)
    }

    @Test func completePassIsDurableBeforePromotionAndPreservesPrevious() async {
        let fixture = ManagedFixture()
        let result = await fixture.service.prepare()
        #expect(result.phase == .ready)
        #expect(result.active == runtimeB)
        #expect(result.previous == runtimeA)
        #expect(result.candidate == nil)
        #expect(await fixture.store.promotions == 1)
        #expect(await fixture.store.recorded.map(\.status) == [.running, .passed])
        #expect(await fixture.admission.acquired == 1)
        #expect(await fixture.admission.released == 1)
        let requests = await fixture.runner.requests
        #expect(requests.count == 1)
        #expect(requests.first?.active?.artifact == runtimeA)
        #expect(requests.first?.candidateTarget.profileURL == fixture.layout.withClaudeProfilePurpose(.compatibility).claudeCLIProfileRoot)
        #expect(requests.first?.active?.target.profileURL == requests.first?.candidateTarget.profileURL)
    }

    @Test func composedManagerTargetPassesRealGateValidationWithWorkOutsideTheProfile() async throws {
        let owned = try ManagedOwnedRuntimeFixture()
        defer { owned.remove() }
        let runner = ManagedTargetBoundaryRunner()
        let gate = ClaudeRuntimeCompatibilityService(runner: runner,
            fixtureURL: ServicesResourceBundle.url(forResource: "claude-runtime-compatibility", withExtension: "js"),
            nodeURL: URL(fileURLWithPath: "/usr/bin/unused-node"), requiresNativeReceipt: true)
        let fixture = ManagedFixture(layout: owned.layout, compatibilityRunner: gate, prepareWork: {
            do {
                let target = try ManagedClaudeRuntimeService.compatibilityWorkTarget(from: $0, applicationSupportRoot: owned.root,
                    layout: owned.layout)
                #expect(target.profileURL.lastPathComponent == "CompatibilityProfile")
                let attributes = try FileManager.default.attributesOfItem(atPath: target.workingDirectoryURL.path)
                #expect(attributes[.posixPermissions] as? Int == 0o700)
                return target
            } catch {
                Issue.record("Composed work preparation failed: \(error)")
                throw error
            }
        })
        // The real gate must reach the injected transport, which deliberately
        // returns auth-required without executing anything. invalidTarget would
        // instead fail before the transport ever sees this composed request.
        let snapshot = await fixture.service.prepare()
        #expect(snapshot.phase == .needsAuthentication, "Actual composed result: \(snapshot)")
        let requests = await runner.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let profile = owned.layout.withClaudeProfilePurpose(.compatibility).claudeCLIProfileRoot
        #expect(request.target.profileURL == profile)
        #expect(request.target.workingDirectoryURL != profile)
        #expect(request.target.temporaryDirectoryURL != profile)
        #expect(!request.target.workingDirectoryURL.path.hasPrefix(profile.path + "/"))
        #expect(!request.target.temporaryDirectoryURL.path.hasPrefix(profile.path + "/"))
        #expect(!FileManager.default.fileExists(atPath: request.target.workingDirectoryURL.path))
        #expect(await fixture.status.targets.first?.workingDirectoryURL == profile)
        #expect(await fixture.store.value.active == runtimeA)
        #expect(await fixture.store.promotions == 0)
    }

    @Test func busyStartDefersWithoutSpawningAndNextDiscoveryCanTry() async {
        let fixture = ManagedFixture()
        await fixture.admission.setBusy(true)
        #expect(await fixture.service.prepare().phase == .waitingForIdle)
        #expect(await fixture.runner.requests.isEmpty)
        #expect(await fixture.status.targets.isEmpty)
        #expect(await fixture.store.value.lastResult == nil)
        await fixture.admission.setBusy(false)
        #expect(await fixture.service.checkForUpdates().active == runtimeB)
    }

    @Test func retryDeferredWhileBusyRunsOnceIdleInsteadOfReadingAsFailed() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.incomplete)
        #expect(await fixture.service.prepare().phase == .failed)
        await fixture.runner.configure(.pass)
        await fixture.admission.setBusy(true)
        #expect(await fixture.service.retry().phase == .waitingForIdle)
        #expect(await fixture.service.checkForUpdates().phase == .waitingForIdle)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.admission.setBusy(false)
        #expect(await fixture.service.checkForUpdates().active == runtimeB)
        #expect(await fixture.runner.requests.count == 2)
    }

    @Test func pruningKeepsTheSelectionAndEveryCopyHandedOutInThisProcess() async {
        let unleased = ManagedFixture(candidate: runtimeC)
        #expect(await unleased.service.prepare().active == runtimeB)
        let expected: [Set<String>] = [[runtimeA.sha256, runtimeC.sha256],
            [runtimeA.sha256, runtimeB.sha256], [runtimeA.sha256, runtimeB.sha256]]
        #expect(await unleased.store.pruned == expected)
        // C went to the compatibility sign-in before installed B superseded it.
        let leased = ManagedFixture(candidate: runtimeC)
        let setup = ManagedClaudeRuntimeSelector(service: leased.service, purpose: .compatibilityCandidate)
        #expect(await setup.inspectInstallation().details.sha256 == runtimeC.sha256)
        #expect(await leased.service.prepare().active == runtimeB)
        let kept = await leased.store.pruned
        #expect(kept.count == 3)
        #expect(kept.allSatisfy { $0.contains(runtimeC.sha256) })
        #expect(kept.last == Set([runtimeA.sha256, runtimeB.sha256, runtimeC.sha256]))
    }

    @Test func pruneFailureNeverFailsTheCheckOrThePromotion() async {
        let fixture = ManagedFixture()
        await fixture.store.failPruning()
        let result = await fixture.service.prepare()
        #expect(result.phase == .ready)
        #expect(result.active == runtimeB)
        #expect(result.previous == runtimeA)
        #expect(await fixture.store.promotions == 1)
        #expect(await fixture.store.pruned.count == 3)
    }

    @Test func missingAuthIsDeduplicatedUntilExplicitRetry() async {
        let fixture = ManagedFixture()
        await fixture.status.set(.signedOut)
        #expect(await fixture.service.prepare().phase == .needsAuthentication)
        #expect(await fixture.service.checkForUpdates().active == runtimeA)
        #expect(await fixture.status.targets.count == 1)
        #expect(await fixture.runner.requests.isEmpty)
        await fixture.status.set(.eligible(.max))
        #expect(await fixture.service.retry().active == runtimeB)
        #expect(await fixture.status.targets.count == 2)
    }

    @Test(arguments: [ClaudeConnectionStatusResult.inconclusive, .cancelled])
    func unavailableStatusIsNotMisreportedAsSignedOut(status: ClaudeConnectionStatusResult) async {
        let fixture = ManagedFixture()
        await fixture.status.set(status)
        let result = await fixture.service.prepare()
        #expect(result.phase == (status == .cancelled ? .cancelled : .failed))
        #expect(result.active == runtimeA)
        #expect(await fixture.store.value.lastResult?.status == (status == .cancelled ? .cancelled : .failed))
        #expect(await fixture.runner.requests.isEmpty)
        #expect(await fixture.store.promotions == 0)
        if status == .inconclusive {
            #expect(result.message == "Claude compatibility sign-in status could not be verified. Retry the check.")
        }
        _ = await fixture.service.checkForUpdates()
        #expect(await fixture.status.targets.count == 1)
    }

    @Test(arguments: [ManagedRunnerFixture.Mode.incomplete, .wrongContract])
    func partialOrStalePassCannotPromote(mode: ManagedRunnerFixture.Mode) async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(mode)
        #expect(await fixture.service.prepare().active == runtimeA)
        #expect(await fixture.store.promotions == 0)
        #expect(await fixture.service.checkForUpdates().active == runtimeA)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.runner.configure(.pass)
        #expect(await fixture.service.retry().active == runtimeB)
    }

    @Test func busyPromotionKeepsWorkingCopyAndReusesExactDurableReceipt() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.pass, afterRun: { await fixture.admission.setBusy(true) })
        let held = await fixture.service.prepare()
        #expect(held.phase == .waitingForIdle)
        #expect(held.active == runtimeA)
        #expect(held.selection?.lastResult?.status == .passed)
        await fixture.admission.setBusy(false)
        #expect(await fixture.service.checkForUpdates().active == runtimeB)
        #expect(await fixture.runner.requests.count == 1)
    }

    @Test func changedCandidateRejectsStaleResult() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.pass, afterRun: { await fixture.store.replaceCandidate() })
        _ = await fixture.service.prepare()
        #expect(await fixture.store.value.active == runtimeA)
        #expect(await fixture.store.value.candidate == runtimeC)
        #expect(await fixture.store.promotions == 0)
    }

    @Test func rediscoveringAnEarlierFailedIdentityRequiresManualRetry() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.incomplete)
        _ = await fixture.service.prepare()
        await fixture.store.replaceCandidate()
        // The installed source is B again, but its earlier failed result must
        // survive the intervening C candidate and suppress an automatic run.
        #expect(await fixture.service.checkForUpdates().active == runtimeA)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.runner.configure(.pass)
        #expect(await fixture.service.retry().active == runtimeB)
        #expect(await fixture.runner.requests.count == 2)
    }

    @Test func freshArtifactFailureReleasesPromotionFreeze() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.pass, afterRun: { await fixture.inspection.setRejected() })
        #expect(await fixture.service.prepare().active == runtimeA)
        #expect(await fixture.store.promotions == 0)
        #expect(await fixture.admission.acquired == 1)
        #expect(await fixture.admission.released == 1)
        #expect(await fixture.admission.owner == nil)
    }

    @Test func retainedValidationFailureIsRememberedBeforeAnyProviderProcess() async {
        let fixture = ManagedFixture()
        await fixture.inspection.setRejected()
        #expect(await fixture.service.prepare().phase == .failed)
        #expect(await fixture.store.value.lastResult?.status == .failed)
        #expect(await fixture.service.checkForUpdates().phase == .failed)
        #expect(await fixture.inspection.calls.count == 1)
        #expect(await fixture.runner.requests.isEmpty)
        #expect(await fixture.status.targets.isEmpty)
        #expect(await fixture.store.value.active == runtimeA)
    }

    @Test func shutdownAwaitsProbeAndRejectsLatePassWhileActiveRemainsAvailableDuringProbe() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.suspend)
        let checking = Task { await fixture.service.prepare() }
        await fixture.runner.waitUntilStarted()
        let selector = ManagedClaudeRuntimeSelector(service: fixture.service)
        #expect(await selector.inspectInstallation().details.sha256 == runtimeA.sha256)
        #expect(await fixture.admission.owner == nil)
        await fixture.service.shutdown()
        _ = await checking.value
        #expect(await fixture.store.value.active == runtimeA)
        #expect(await fixture.store.promotions == 0)
        #expect(await fixture.runner.cancellations == 1)
        #expect(await fixture.service.snapshot().phase == .stopped)
        #expect(await fixture.service.retry().phase == .stopped)
        #expect(await selector.inspectInstallation().state != .verified)
    }

    @Test func cancelCanBeFollowedByAnExplicitRetryWithoutClosingTheService() async {
        let fixture = ManagedFixture()
        await fixture.runner.configure(.suspend)
        let checking = Task { await fixture.service.prepare() }
        await fixture.runner.waitUntilStarted()
        await fixture.service.cancel()
        _ = await checking.value
        #expect(await fixture.store.value.active == runtimeA)
        #expect(await fixture.service.snapshot().phase == .cancelled)
        await fixture.runner.configure(.pass)
        #expect(await fixture.service.retry().active == runtimeB)
    }
}
