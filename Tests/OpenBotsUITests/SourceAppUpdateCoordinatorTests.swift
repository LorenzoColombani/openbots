import Foundation
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@Suite("Source application update coordination") @MainActor
struct SourceAppUpdateCoordinatorTests {
    private var info: [String: Any] {
        ["OpenBotsSourceUpdateEnabled": true,
         "OpenBotsSourceUpdateFeedURL": "https://raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json",
         "OpenBotsSourceUpdatePublicKey": Data(repeating: 9, count: 32).base64EncodedString(),
         "OpenBotsSourceUpdateRepository": "LorenzoColombani/openbots"]
    }

    private func model(admission: AppUpdateAdmission = AppUpdateAdmission(),
                       blocker: @escaping () -> String? = { nil },
                       save: @escaping () async -> Bool = { true }) -> AppUpdateModel {
        AppUpdateModel(configuration: AppUpdateConfiguration(info: info), admission: admission, blocker: blocker, save: save)
    }

    @Test func channelActivationIsExplicit() {
        #expect(AppUpdateConfiguration(info: info)?.delivery == .source(repository: "LorenzoColombani/openbots"))
        for key in ["OpenBotsSourceUpdateEnabled", "OpenBotsSourceUpdateFeedURL",
                    "OpenBotsSourceUpdatePublicKey", "OpenBotsSourceUpdateRepository"] {
            var missing = info
            missing.removeValue(forKey: key)
            #expect(AppUpdateConfiguration(info: missing) == nil)
        }
        var malformed = info
        malformed["OpenBotsSourceUpdateRepository"] = "owner/../other"
        #expect(AppUpdateConfiguration(info: malformed) == nil)
    }

    @Test func downloadNeedsAClickAndBusyInstallationRetainsFinishedBuild() async throws {
        let service = SourceUpdateFake()
        let admission = AppUpdateAdmission()
        var busy = true
        var terminations = 0
        let model = model(admission: admission, blocker: { busy ? "A bot is working." : nil })
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { terminations += 1 })
        coordinator.checkForUpdates()
        try await wait { model.state == .available("1.1.0") }
        #expect(await service.counts().builds == 0)
        #expect(await service.counts().installations == 0)
        coordinator.downloadAndBuild()
        try await wait { model.state == .readyToInstall("1.1.0") }
        #expect(admission.allowsWork, "A local build does not freeze bot work")
        #expect(terminations == 0)
        coordinator.installAndRelaunch()
        #expect(model.state == .readyToInstall("1.1.0"))
        #expect(model.message.contains("A bot is working"))
        #expect(await service.counts().installations == 0)
        busy = false
        coordinator.installAndRelaunch()
        try await wait { terminations == 1 }
        #expect(!admission.allowsWork)
        #expect(model.state == .installing)
        #expect(await service.counts().builds == 1)
        #expect(await service.counts().installations == 1)
        #expect(!coordinator.cancelBeforeQuitting(reply: { _ in Issue.record("Approved Quit should not cancel the installer") }))
        coordinator.beginShutdown()
    }

    @Test func failedSaveLeavesCandidateReadyForRetryWithoutArmingInstaller() async throws {
        let service = SourceUpdateFake()
        let admission = AppUpdateAdmission()
        var saved = false
        var terminations = 0
        let model = model(admission: admission, save: { saved })
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { terminations += 1 })
        try await prepare(coordinator, model)
        coordinator.installAndRelaunch()
        try await wait { model.state == .readyToInstall("1.1.0") }
        #expect(admission.allowsWork)
        #expect(model.message.contains("saved"))
        #expect(await service.counts().installations == 0)
        saved = true
        coordinator.installAndRelaunch()
        try await wait { terminations == 1 }
        #expect(await service.counts().builds == 1)
        coordinator.beginShutdown()
    }

    @Test(arguments: [false, true]) func helperMustAcknowledgeBeforeQuitAndLateAcknowledgementCannotReviveCancellation(cancelBeforeAcknowledgement: Bool) async throws {
        let service = SourceUpdateFake(holdInstallation: true)
        let admission = AppUpdateAdmission()
        let model = model(admission: admission)
        var terminations = 0
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { terminations += 1 })
        try await prepare(coordinator, model)
        coordinator.installAndRelaunch()
        try await wait { await service.installationIsWaiting }
        #expect(terminations == 0)
        #expect(model.state == .armingInstallation)
        #expect(!admission.allowsWork)
        if cancelBeforeAcknowledgement {
            var allowed: Bool?
            #expect(coordinator.cancelBeforeQuitting { allowed = $0 })
            try await wait { allowed == true }
            await service.finishInstallation()
            for _ in 0..<20 { await Task.yield() }
            #expect(terminations == 0)
            #expect(model.state == .ready)
            #expect(admission.allowsWork)
        } else {
            await service.finishInstallation()
            try await wait { terminations == 1 }
            #expect(!admission.allowsWork)
            coordinator.beginShutdown()
        }
    }

    @Test func previousRollbackIsVisibleWithoutGrantingAnUpdate() {
        let model = model()
        model.recordSourceInstallationReceipt(.init(status: .rolledBack, message: "internal diagnostic"))
        #expect(model.previousInstallationNotice?.contains("restored the previous version") == true)
        #expect(model.state == .ready)
        #expect(!model.canInstallSourceUpdate)
        model.recordSourceInstallationReceipt(.init(status: .installed, message: "installed"))
        #expect(model.previousInstallationNotice == nil)
    }

    @Test func canceledBuildCannotApplyLateProgressOrReadyResultToNewCycle() async throws {
        let service = SourceUpdateFake(holdBuild: true)
        let model = model()
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { Issue.record("No install was requested") })
        coordinator.checkForUpdates()
        try await wait { model.state == .available("1.1.0") }
        coordinator.downloadAndBuild()
        try await wait { await service.buildIsWaiting }
        coordinator.cancel()
        try await wait { model.state == .ready }
        coordinator.checkForUpdates()
        try await wait { model.state == .available("1.1.0") }
        await service.finishBuild()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.state == .available("1.1.0"))
        #expect(await service.counts().installations == 0)
    }

    @Test(arguments: [1, 2, 3]) func configurationMustStillBeValidAfterBuildAndBeforeQuit(failingVerification: Int) async throws {
        let service = SourceUpdateFake()
        let verification = SourceConfigurationFake(failOn: failingVerification)
        let admission = AppUpdateAdmission()
        let model = model(admission: admission)
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { try await verification.verify() },
            requestTermination: { Issue.record("Changed configuration cannot authorize Quit") })
        coordinator.checkForUpdates()
        try await wait { model.state == .available("1.1.0") }
        coordinator.downloadAndBuild()
        if failingVerification >= 2 {
            try await wait { model.state == .readyToInstall("1.1.0") }
            coordinator.installAndRelaunch()
        }
        try await wait { model.state == .ready }
        #expect(admission.allowsWork)
        #expect(await service.counts().installations == (failingVerification == 3 ? 1 : 0))
        #expect(await service.counts().cancellations == 1)
    }

    @Test func refusedQuitRetainsAdmissionUntilArmedHelperActuallyStops() async throws {
        let service = SourceUpdateFake(holdCancellation: true)
        let admission = AppUpdateAdmission()
        let model = model(admission: admission)
        var terminations = 0
        var canceledReply: Bool?
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { terminations += 1 })
        try await prepare(coordinator, model)
        coordinator.installAndRelaunch()
        try await wait { terminations == 1 }
        coordinator.terminationWasCanceled { canceledReply = $0 }
        try await wait { await service.cancellationIsWaiting }
        #expect(model.state == .canceling)
        #expect(!admission.allowsWork)
        #expect(canceledReply == nil)
        var secondQuitReply: Bool?
        #expect(coordinator.cancelBeforeQuitting { secondQuitReply = $0 }, "A later Quit must not reuse revoked installation intent")
        await service.finishCancellation()
        try await wait { canceledReply != nil && secondQuitReply != nil }
        #expect(canceledReply == true && secondQuitReply == true)
        #expect(admission.allowsWork)
        #expect(model.state == .ready)
    }

    @Test func helperFailureNeverQuitsOrThawsBeforeCleanupAndCanRetryCancellation() async throws {
        let service = SourceUpdateFake(failInstallation: true, failFirstCancellation: true)
        let admission = AppUpdateAdmission()
        let model = model(admission: admission)
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { Issue.record("Helper was not ready") })
        try await prepare(coordinator, model)
        coordinator.installAndRelaunch()
        try await wait { model.state == .canceling && model.notice != nil }
        #expect(!admission.allowsWork)
        #expect(!model.canCheck)
        coordinator.cancel()
        try await wait { model.state == .ready }
        #expect(admission.allowsWork)
        #expect(await service.counts().cancellations == 2)
    }

    @Test func normalQuitCancellationTimeoutRefusesQuitAndRejectsLateBuild() async throws {
        let service = SourceUpdateFake(holdBuild: true, holdCancellation: true)
        let model = model()
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            cancellationTimeout: .milliseconds(10),
            verifyGoogleConfiguration: { .init() }, requestTermination: { Issue.record("No install was requested") })
        coordinator.checkForUpdates()
        try await wait { model.state == .available("1.1.0") }
        coordinator.downloadAndBuild()
        try await wait { await service.buildIsWaiting }
        var quitReplies: [Bool] = []
        #expect(coordinator.cancelBeforeQuitting { quitReplies.append($0) })
        try await wait { quitReplies == [false] }
        #expect(model.state == .canceling)
        #expect(!model.isCancelingForQuit)
        await service.finishCancellation()
        await service.finishBuild()
        try await wait { model.state == .ready }
        #expect(quitReplies == [false], "Late cleanup cannot approve a previously refused Quit")
    }

    @Test func canceledSavingCannotArmALateInstaller() async throws {
        let service = SourceUpdateFake()
        let save = SourceSaveFake()
        let admission = AppUpdateAdmission()
        let model = model(admission: admission, save: { await save.save() })
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: { .init() }, requestTermination: { Issue.record("Saving was canceled") })
        try await prepare(coordinator, model)
        coordinator.installAndRelaunch()
        try await wait { await save.isWaiting }
        #expect(!admission.allowsWork)
        var allowed: Bool?
        #expect(coordinator.cancelBeforeQuitting { allowed = $0 })
        try await wait { allowed == true }
        await save.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(admission.allowsWork)
        #expect(await service.counts().installations == 0)
        #expect(model.state == .ready)
    }

    @Test func failedTerminationRequestDisarmsHelperBeforeReopeningApp() async throws {
        let service = SourceUpdateFake()
        let admission = AppUpdateAdmission()
        let model = model(admission: admission)
        var terminations = 0
        let coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            terminationTimeout: .milliseconds(10),
            verifyGoogleConfiguration: { .init() }, requestTermination: { terminations += 1 })
        try await prepare(coordinator, model)
        coordinator.installAndRelaunch()
        try await wait { model.state == .ready }
        #expect(terminations == 1)
        #expect(await service.counts().cancellations == 1)
        #expect(admission.allowsWork)
    }

    private func prepare(_ coordinator: SourceAppUpdateCoordinator, _ model: AppUpdateModel) async throws {
        coordinator.checkForUpdates()
        try await wait { model.state == .available("1.1.0") }
        coordinator.downloadAndBuild()
        try await wait { model.state == .readyToInstall("1.1.0") }
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await predicate())
    }
}

private actor SourceUpdateFake: SourceAppUpdateServing {
    struct Counts: Sendable { let checks: Int; let builds: Int; let installations: Int; let cancellations: Int }
    private var checks = 0, builds = 0, installations = 0, cancellations = 0
    private let holdBuild: Bool
    private let holdCancellation: Bool
    private let holdInstallation: Bool
    private let failInstallation: Bool
    private let failFirstCancellation: Bool
    private var buildWaiter: CheckedContinuation<PreparedSourceAppUpdate, any Error>?
    private var cancellationWaiter: CheckedContinuation<Void, any Error>?
    private var installationWaiter: CheckedContinuation<SourceAppUpdateInstallation, any Error>?
    private var progress: (@Sendable (SourceAppUpdateProgress) -> Void)?
    private let candidate = PreparedSourceAppUpdate(appURL: URL(fileURLWithPath: "/source-update-fixture/OpenBots Next.app"),
        sourceCommit: String(repeating: "a", count: 40), build: "110", version: "1.1.0", fingerprint: String(repeating: "b", count: 64))

    init(holdBuild: Bool = false, holdCancellation: Bool = false, holdInstallation: Bool = false,
         failInstallation: Bool = false, failFirstCancellation: Bool = false) {
        self.holdBuild = holdBuild; self.holdCancellation = holdCancellation
        self.holdInstallation = holdInstallation
        self.failInstallation = failInstallation; self.failFirstCancellation = failFirstCancellation
    }
    var buildIsWaiting: Bool { buildWaiter != nil }
    var cancellationIsWaiting: Bool { cancellationWaiter != nil }
    var installationIsWaiting: Bool { installationWaiter != nil }
    func counts() -> Counts { Counts(checks: checks, builds: builds, installations: installations, cancellations: cancellations) }
    func check() async throws -> VerifiedSourceAppUpdate? {
        checks += 1
        return .init(version: "1.1.0", build: "110", sourceCommit: String(repeating: "a", count: 40))
    }
    func prepare(_ release: VerifiedSourceAppUpdate,
                 progress: @escaping @Sendable (SourceAppUpdateProgress) -> Void) async throws -> PreparedSourceAppUpdate {
        builds += 1
        self.progress = progress
        progress(.building)
        if holdBuild { return try await withCheckedThrowingContinuation { buildWaiter = $0 } }
        return candidate
    }
    func finishBuild() {
        progress?(.validating)
        buildWaiter?.resume(returning: candidate)
        buildWaiter = nil
    }
    func cancel() async throws {
        cancellations += 1
        if failFirstCancellation && cancellations == 1 { throw SourceAppUpdateError.cancellationIncomplete }
        if holdCancellation { try await withCheckedThrowingContinuation { cancellationWaiter = $0 } }
    }
    func finishCancellation() { cancellationWaiter?.resume(); cancellationWaiter = nil }
    func discard(_ prepared: PreparedSourceAppUpdate) async throws {}
    func beginInstallation(_ prepared: PreparedSourceAppUpdate,
                           googleConfiguration: GoogleWorkspaceUpdateConfiguration) async throws -> SourceAppUpdateInstallation {
        installations += 1
        if failInstallation { throw SourceAppUpdateError.operationFailed("The installer could not start.") }
        if holdInstallation { return try await withCheckedThrowingContinuation { installationWaiter = $0 } }
        return .init(id: prepared.id, receiptURL: URL(fileURLWithPath: "/source-update-fixture/receipt.json"))
    }
    func finishInstallation() {
        installationWaiter?.resume(returning: .init(id: candidate.id, receiptURL: URL(fileURLWithPath: "/source-update-fixture/receipt.json")))
        installationWaiter = nil
    }
    func abortInstallation(_ installation: SourceAppUpdateInstallation) async throws { try await cancel() }
    func receipt(_ installation: SourceAppUpdateInstallation) async throws -> SourceAppUpdateInstallationReceipt? { nil }
    func latestInstallationReceipt() async throws -> SourceAppUpdateInstallationReceipt? { nil }
}

private actor SourceConfigurationFake {
    private let failOn: Int
    private var calls = 0
    init(failOn: Int) { self.failOn = failOn }
    func verify() throws -> GoogleWorkspaceUpdateConfiguration {
        calls += 1
        if calls == failOn { throw SourceAppUpdateError.invalidPreparation }
        return .init()
    }
}

private actor SourceSaveFake {
    private var waiter: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { waiter != nil }
    func save() async -> Bool { await withCheckedContinuation { waiter = $0 } }
    func finish() { waiter?.resume(returning: true); waiter = nil }
}
