import Combine
import Foundation
import OpenBotsServices

/// Only embedded, release-reviewed values enable the native adapter. Never
/// manufacture a feed or key for a development build. The one delivery route
/// builds reviewed source on this Mac. There is no ready-made app package: it
/// would need a paid Apple Developer membership.
public struct AppUpdateConfiguration: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case source(repository: String)
    }
    public let feedURL: URL
    public let publicKey: String
    public let delivery: Delivery

    public init?(info: [String: Any]) {
        guard info["OpenBotsSourceUpdateEnabled"] as? Bool == true,
              let feed = info["OpenBotsSourceUpdateFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["OpenBotsSourceUpdatePublicKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.base64EncodedString() == key,
              let repository = info["OpenBotsSourceUpdateRepository"] as? String,
              repository.range(of: #"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let name = repository.split(separator: "/").last, name != ".", name != ".." else { return nil }
        delivery = .source(repository: repository)
        feedURL = url
        publicKey = key
    }
}

/// A reversible main-actor admission boundary, separate from irreversible Quit.
/// All user mutation entry points and background work admission share this gate.
@MainActor
public final class AppUpdateAdmission: ObservableObject {
    public static let shared = AppUpdateAdmission(gate: .shared)
    @Published public private(set) var isPreparing = false
    private var owner: UUID?
    private let gate: ApplicationUpdateGate
    public var allowsWork: Bool { gate.allowsWork }
    public init(gate: ApplicationUpdateGate = ApplicationUpdateGate()) { self.gate = gate }

    public func acquire(_ token: UUID, blocker: () -> String?) -> Bool {
        guard owner == nil, blocker() == nil, gate.freeze(token) else { return false }
        owner = token
        isPreparing = true
        return true
    }

    public func owns(_ token: UUID) -> Bool { owner == token }

    public func release(_ token: UUID) {
        guard owner == token else { return }
        owner = nil
        gate.release(token)
        isPreparing = false
    }
}

@MainActor
public final class AppUpdateModel: ObservableObject {
    public enum State: Equatable {
        case inactive, ready, checking, available(String), downloading, preparing, installing
        case building, validating, readyToInstall(String), armingInstallation, canceling
        case blocked(String), failed
    }
    @Published public private(set) var state: State
    @Published public private(set) var driverCanCheck = false
    @Published public private(set) var isCancelingForQuit = false
    @Published public private(set) var notice: String?
    @Published public private(set) var previousInstallationNotice: String?
    public let configuration: AppUpdateConfiguration?
    public var check: (() -> Void)?
    public var downloadSourceUpdate: (() -> Void)?
    public var installSourceUpdate: (() -> Void)?
    public var cancelSourceUpdate: (() -> Void)?
    private let admission: AppUpdateAdmission
    private let blocker: () -> String?
    private let save: () async -> Bool
    private let timeout: Duration
    private var generation = UUID()
    private var authorizedDownload: UUID?
    private var preparation: UUID?
    private var preparationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var reply: ((Bool) -> Void)?
    private var preparedSourceVersion: String?

    public init(configuration: AppUpdateConfiguration?, admission: AppUpdateAdmission = .shared,
                timeout: Duration = .seconds(3), blocker: @escaping () -> String? = { nil },
                save: @escaping () async -> Bool = { true }) {
        self.configuration = configuration
        self.admission = admission
        self.blocker = blocker
        self.save = save
        self.timeout = timeout
        state = configuration == nil ? .inactive : .ready
    }

    public var canCheck: Bool {
        guard configuration != nil, driverCanCheck, !isCancelingForQuit else { return false }
        return switch state {
        case .checking, .downloading, .preparing, .installing, .building, .validating,
             .readyToInstall, .armingInstallation, .canceling: false
        default: true
        }
    }

    public var message: String {
        if let notice { return notice }
        return switch state {
        case .inactive: "App updates are not enabled for this build."
        case .ready: "OpenBots checks automatically while open. You choose when to download and install."
        case .checking: "Checking for an OpenBots update…"
        case .available(let version): "OpenBots \(version) is available. Update now downloads it and builds it on this Mac using Xcode."
        case .downloading: "Downloading your requested update…"
        case .building: "Building the update on this Mac. You can keep using OpenBots while it finishes."
        case .validating: "Checking your update…"
        case .readyToInstall(let version): "OpenBots \(version) is ready. Install and Relaunch saves your work and restarts the app."
        case .armingInstallation: "Preparing to restart OpenBots…"
        case .canceling: "Stopping the update…"
        case .preparing: "Saving your work before updating…"
        case .installing: "Restarting OpenBots to install the update…"
        case .blocked(let reason): reason + " Check for updates again when you’re ready."
        case .failed: driverCanCheck
            ? "The update could not finish. You can check again."
            : "App updates could not start. Reopen OpenBots to try again."
        }
    }

    /// True for any configured build: source is the only delivery route.
    public var isSourceUpdate: Bool { configuration != nil }
    public var canDownloadSourceUpdate: Bool {
        guard isSourceUpdate, !isCancelingForQuit, admission.allowsWork, downloadSourceUpdate != nil else { return false }
        if case .available = state { return true }
        return false
    }
    public var canInstallSourceUpdate: Bool {
        guard isSourceUpdate, !isCancelingForQuit, admission.allowsWork, installSourceUpdate != nil else { return false }
        if case .readyToInstall = state { return true }
        return false
    }
    public var canCancelSourceUpdate: Bool {
        guard isSourceUpdate, !isCancelingForQuit, cancelSourceUpdate != nil else { return false }
        return switch state {
        case .checking, .downloading, .building, .validating, .readyToInstall, .canceling: true
        default: false
        }
    }

    public func checkForUpdates() {
        guard canCheck, admission.allowsWork else { return }
        check?()
    }

    public func setDriverAvailability(_ canCheck: Bool) { driverCanCheck = canCheck }

    public func setQuitCancellationPending(_ pending: Bool) { isCancelingForQuit = pending }

    @discardableResult public func checking() -> UUID? {
        guard configuration != nil, admission.allowsWork, !isCancelingForQuit else { return nil }
        cancelPreparation()
        generation = UUID()
        authorizedDownload = nil
        preparedSourceVersion = nil
        notice = nil
        state = .checking
        return generation
    }

    /// Every native callback is correlated to this update cycle, not merely a
    /// version string that could recur after cancellation.
    public func found(version: String, cycle: UUID) -> Bool {
        guard cycle == generation, configuration != nil else { return false }
        switch state {
        case .checking, .available: break
        default: return false
        }
        state = .available(version)
        return true
    }

    public func authorizeDownload(cycle: UUID) -> Bool {
        guard cycle == generation, case .available = state, admission.allowsWork else { return false }
        authorizedDownload = cycle
        state = .downloading
        return true
    }

    /// Called only after the person's final Install and Relaunch action, for a
    /// build that is ready on this Mac.
    public func prepareInstallation(cycle: UUID, reply: @escaping (Bool) -> Void) {
        guard cycle == generation, authorizedDownload == cycle, preparation == nil else { reply(false); return }
        guard case .readyToInstall = state else { reply(false); return }
        if let reason = blocker() { installationRefused(reason); reply(false); return }
        let token = UUID()
        guard admission.acquire(token, blocker: blocker) else { installationRefused("OpenBots is busy."); reply(false); return }
        preparation = token
        self.reply = reply
        notice = nil
        state = .preparing
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: timeout) } catch { return }
            finishPreparation(token: token, cycle: cycle, saved: false)
        }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let saved = await save()
            guard !Task.isCancelled else { return }
            finishPreparation(token: token, cycle: cycle, saved: saved)
        }
    }

    private func finishPreparation(token: UUID, cycle: UUID, saved: Bool) {
        guard cycle == generation, preparation == token, admission.owns(token) else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        let completion = reply
        reply = nil
        if saved && blocker() == nil {
            state = .armingInstallation
            // Keep admission closed through the committed ordinary Quit.
            completion?(true)
        } else {
            preparationTask?.cancel()
            preparationTask = nil
            admission.release(token)
            preparation = nil
            installationRefused("OpenBots could not confirm that all your work is saved.")
            completion?(false)
        }
    }

    public func finished(cycle: UUID, failed: Bool = false) {
        guard cycle == generation else { return }
        // A late check result is not installation cancellation.
        if !failed, state == .installing { return }
        cancelPreparation()
        authorizedDownload = nil
        preparedSourceVersion = nil
        generation = UUID()
        if failed { state = .failed }
        else if case .blocked = state { /* Keep the actionable refusal. */ }
        else { state = configuration == nil ? .inactive : .ready }
    }

    /// Source callbacks cannot advance a canceled or replaced operation.
    public func sourceProgress(_ progress: SourceAppUpdateProgress, cycle: UUID) {
        guard isSourceUpdate, cycle == generation, authorizedDownload == cycle else { return }
        switch state {
        case .downloading, .building, .validating: break
        default: return
        }
        notice = nil
        switch progress {
        case .downloading: state = .downloading
        case .verifying, .validating: state = .validating
        case .building: state = .building
        }
    }

    public func sourceReady(version: String, cycle: UUID) {
        guard isSourceUpdate, cycle == generation, authorizedDownload == cycle else { return }
        switch state {
        case .downloading, .building, .validating: break
        default: return
        }
        preparedSourceVersion = version
        notice = nil
        state = .readyToInstall(version)
    }

    public func sourceInstallerArmed(cycle: UUID) -> Bool {
        guard isSourceUpdate, cycle == generation, state == .armingInstallation,
              let preparation, admission.owns(preparation) else { return false }
        state = .installing
        return true
    }

    /// Cancel tasks immediately, but keep the admission lease until the backend
    /// proves that its worker and any armed installer have actually stopped.
    public func beginSourceCancellation(cycle: UUID) {
        guard isSourceUpdate, cycle == generation else { return }
        preparationTask?.cancel()
        timeoutTask?.cancel()
        preparationTask = nil
        timeoutTask = nil
        state = .canceling
        notice = nil
        let completion = reply
        reply = nil
        completion?(false)
    }

    public func sourceCancellationFailed(cycle: UUID) {
        guard isSourceUpdate, cycle == generation else { return }
        state = .canceling
        notice = "The update has not finished stopping. Choose Cancel or try quitting again."
    }

    public func sourceCanceled(cycle: UUID, message: String? = nil) {
        guard isSourceUpdate, cycle == generation else { return }
        cancelPreparation()
        authorizedDownload = nil
        preparedSourceVersion = nil
        generation = UUID()
        state = .ready
        notice = message
    }

    public func recordSourceInstallationReceipt(_ receipt: SourceAppUpdateInstallationReceipt?) {
        guard isSourceUpdate else { return }
        switch receipt?.status {
        case .rolledBack:
            previousInstallationNotice = "The previous update could not finish. OpenBots restored the previous version."
        case .failed:
            previousInstallationNotice = "The previous update could not finish. Your current app is still available."
        default: previousInstallationNotice = nil
        }
    }

    private func installationRefused(_ reason: String) {
        if let version = preparedSourceVersion {
            state = .readyToInstall(version)
            notice = reason + " Your update is ready; try Install and Relaunch again when you’re ready."
        } else {
            authorizedDownload = nil
            state = .blocked(reason)
        }
    }

    private func cancelPreparation() {
        preparationTask?.cancel()
        timeoutTask?.cancel()
        preparationTask = nil
        timeoutTask = nil
        if let preparation { admission.release(preparation) }
        preparation = nil
        let completion = reply
        reply = nil
        completion?(false)
    }
}

/// Coordinates the source route without AppKit or real processes. A service
/// result never supplies user intent; only the two explicit actions below do.
@MainActor
public final class SourceAppUpdateCoordinator {
    private let model: AppUpdateModel
    private let service: any SourceAppUpdateServing
    private let verifyGoogleConfiguration: @Sendable () async throws -> GoogleWorkspaceUpdateConfiguration
    private let requestTermination: () -> Void
    private let cancellationTimeout: Duration
    private let terminationTimeout: Duration
    private var cycle: UUID?
    private var offer: VerifiedSourceAppUpdate?
    private var prepared: PreparedSourceAppUpdate?
    private var installation: SourceAppUpdateInstallation?
    private var operationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var cancellationTimer: Task<Void, Never>?
    private var cancellationReplies: [(Bool) -> Void] = []
    private var cancellationMessage: String?
    private var terminationTimer: Task<Void, Never>?
    private var automaticChecks: Task<Void, Never>?
    private var automaticInterval: Duration?
    private var terminationAuthorized = false
    private var shutdownCommitted = false
    private var didReadInstallationReceipt = false

    public init(model: AppUpdateModel, service: any SourceAppUpdateServing,
                cancellationTimeout: Duration = .seconds(8), terminationTimeout: Duration = .seconds(8),
                verifyGoogleConfiguration: @escaping @Sendable () async throws -> GoogleWorkspaceUpdateConfiguration,
                requestTermination: @escaping () -> Void) {
        self.model = model
        self.service = service
        self.cancellationTimeout = cancellationTimeout
        self.terminationTimeout = terminationTimeout
        self.verifyGoogleConfiguration = verifyGoogleConfiguration
        self.requestTermination = requestTermination
        guard model.isSourceUpdate else { return }
        model.setDriverAvailability(true)
        model.check = { [weak self] in self?.checkForUpdates() }
        model.downloadSourceUpdate = { [weak self] in self?.downloadAndBuild() }
        model.installSourceUpdate = { [weak self] in self?.installAndRelaunch() }
        model.cancelSourceUpdate = { [weak self] in self?.cancel() }
    }

    public func startAutomaticChecks(interval: Duration = .seconds(14_400), checkImmediately: Bool = true) {
        guard model.isSourceUpdate, automaticChecks == nil, !shutdownCommitted else { return }
        automaticInterval = interval
        automaticChecks = Task { [weak self] in
            if checkImmediately { self?.checkForUpdates() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !shutdownCommitted else { return }
                // An existing offer or prepared build belongs to the person.
                if model.state == .ready { checkForUpdates() }
            }
        }
    }

    public func checkForUpdates() {
        guard model.isSourceUpdate, !shutdownCommitted, operationTask == nil, cancellationTask == nil,
              model.canCheck, let cycle = model.checking() else { return }
        self.cycle = cycle
        offer = nil
        let token = UUID()
        operationID = token
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !didReadInstallationReceipt {
                    let receipt = try? await service.latestInstallationReceipt()
                    try Task.checkCancellation()
                    guard operationID == token else { return }
                    model.recordSourceInstallationReceipt(receipt)
                    didReadInstallationReceipt = true
                }
                let release = try await service.check()
                try Task.checkCancellation()
                guard operationID == token else { return }
                operationTask = nil
                operationID = nil
                if let release, model.found(version: release.version, cycle: cycle) {
                    offer = release
                } else {
                    model.finished(cycle: cycle)
                    self.cycle = nil
                }
            } catch {
                guard operationID == token else { return }
                beginCancellation(message: Self.message(for: error))
            }
        }
    }

    public func downloadAndBuild() {
        guard !shutdownCommitted, operationTask == nil, cancellationTask == nil,
              let cycle, let offer, model.canDownloadSourceUpdate,
              model.authorizeDownload(cycle: cycle) else { return }
        let token = UUID()
        operationID = token
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await service.prepare(offer) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == token else { return }
                        self.model.sourceProgress(progress, cycle: cycle)
                    }
                }
                try Task.checkCancellation()
                guard operationID == token else { return }
                prepared = value
                // Durable configuration can change during a long local build.
                _ = try await verifyGoogleConfiguration()
                try Task.checkCancellation()
                guard operationID == token else { return }
                model.sourceReady(version: value.version, cycle: cycle)
                operationTask = nil
                operationID = nil
            } catch {
                guard operationID == token else { return }
                beginCancellation(message: Self.message(for: error))
            }
        }
    }

    public func installAndRelaunch() {
        guard !shutdownCommitted, operationTask == nil, cancellationTask == nil,
              let cycle, let prepared, model.canInstallSourceUpdate else { return }
        let token = UUID()
        operationID = token
        model.prepareInstallation(cycle: cycle) { [weak self] allowed in
            guard let self, operationID == token else { return }
            guard allowed else { operationID = nil; return }
            operationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let fresh = try await verifyGoogleConfiguration()
                    try Task.checkCancellation()
                    guard operationID == token else { return }
                    let ticket = try await service.beginInstallation(prepared, googleConfiguration: fresh)
                    try Task.checkCancellation()
                    guard operationID == token else { return }
                    installation = ticket
                    // The helper acknowledgement is an await boundary too.
                    // Recheck durable setup immediately before asking to quit.
                    guard try await verifyGoogleConfiguration() == fresh else {
                        throw SourceAppUpdateError.invalidPreparation
                    }
                    try Task.checkCancellation()
                    guard operationID == token else { return }
                    guard model.sourceInstallerArmed(cycle: cycle) else {
                        beginCancellation(message: "The update was canceled before restarting.")
                        return
                    }
                    operationTask = nil
                    operationID = nil
                    terminationAuthorized = true
                    // The backend's ready acknowledgement precedes ordinary
                    // Quit. It can replace the bundle only after this PID exits.
                    armTerminationDeadline()
                    requestTermination()
                } catch {
                    guard operationID == token else { return }
                    beginCancellation(message: Self.message(for: error))
                }
            }
        }
    }

    public func cancel() {
        guard !shutdownCommitted, !terminationAuthorized else { return }
        beginCancellation()
    }

    /// Also true for an armed installation, so closing the last window cannot
    /// begin irreversible shutdown before AppKit consults the normal quit path.
    public var requiresCancellationBeforeQuit: Bool {
        operationID != nil || prepared != nil || installation != nil || cancellationTask != nil
            || model.state == .canceling
    }

    public func cancelBeforeQuitting(reply: @escaping (Bool) -> Void) -> Bool {
        stopAutomaticChecks()
        guard !terminationAuthorized, requiresCancellationBeforeQuit else { return false }
        model.setQuitCancellationPending(true)
        beginCancellation { [weak self] canceled in
            self?.model.setQuitCancellationPending(false)
            reply(canceled)
        }
        return true
    }

    /// AppKit declined Quit (for example, another cancellation timed out).
    /// Reopen admission only after the armed helper acknowledges cancellation.
    public func terminationWasCanceled(reply: @escaping (Bool) -> Void) {
        guard !shutdownCommitted else { reply(false); return }
        if terminationAuthorized || installation != nil {
            beginCancellation(message: "OpenBots stayed open. The update was canceled; you can try again.") { [weak self] stopped in
                self?.resumeAutomaticChecks()
                reply(stopped)
            }
        } else {
            resumeAutomaticChecks()
            reply(true)
        }
    }

    /// Called only where the existing AppKit quit guard commits shutdown.
    public func beginShutdown() {
        shutdownCommitted = true
        stopAutomaticChecks()
        terminationTimer?.cancel()
        terminationTimer = nil
    }

    private func beginCancellation(message: String? = nil, reply: ((Bool) -> Void)? = nil) {
        guard let cycle else { reply?(true); return }
        if let message { cancellationMessage = message }
        if let reply { cancellationReplies.append(reply) }
        guard cancellationTask == nil else {
            if cancellationTimer == nil { resolveCancellationReplies(false) }
            return
        }
        operationID = nil
        operationTask?.cancel()
        operationTask = nil
        // Once cancellation starts, a later ordinary Quit cannot consume the
        // earlier Install click while its helper is still being disarmed.
        terminationAuthorized = false
        terminationTimer?.cancel()
        terminationTimer = nil
        model.beginSourceCancellation(cycle: cycle)
        cancellationTimer = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: cancellationTimeout) } catch { return }
            cancellationTimer = nil
            model.sourceCancellationFailed(cycle: cycle)
            resolveCancellationReplies(false)
            // Keep the task and admission lease. A timeout proves no cleanup.
        }
        cancellationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.cancel()
                cancellationTimer?.cancel()
                cancellationTimer = nil
                cancellationTask = nil
                installation = nil
                prepared = nil
                offer = nil
                terminationAuthorized = false
                model.sourceCanceled(cycle: cycle, message: cancellationMessage)
                cancellationMessage = nil
                self.cycle = nil
                resolveCancellationReplies(true)
            } catch {
                cancellationTimer?.cancel()
                cancellationTimer = nil
                cancellationTask = nil
                model.sourceCancellationFailed(cycle: cycle)
                resolveCancellationReplies(false)
            }
        }
    }

    private func resolveCancellationReplies(_ allowed: Bool) {
        let replies = cancellationReplies
        cancellationReplies = []
        // Always reply after the original applicationShouldTerminate call.
        Task { for reply in replies { reply(allowed) } }
    }

    private func armTerminationDeadline() {
        terminationTimer?.cancel()
        terminationTimer = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: terminationTimeout) } catch { return }
            guard !shutdownCommitted, terminationAuthorized else { return }
            terminationWasCanceled { _ in }
        }
    }

    private func stopAutomaticChecks() { automaticChecks?.cancel(); automaticChecks = nil }
    private func resumeAutomaticChecks() {
        if let automaticInterval { startAutomaticChecks(interval: automaticInterval, checkImmediately: false) }
    }
    private static func message(for error: any Error) -> String {
        if let error = error as? SourceAppUpdateError { return error.localizedDescription }
        return "The update could not finish. Your current app is still available. Check for updates to try again."
    }
}
