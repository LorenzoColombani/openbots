import Combine
import Foundation
import OpenBotsServices

/// Presentation of the durable selector; this object never invents a passing
/// receipt or chooses a global executable when managed selection is unavailable.
@MainActor
public final class ClaudeRuntimeModel: ObservableObject {
    @Published public private(set) var snapshot = ManagedClaudeRuntimeSnapshot(phase: .unavailable)
    @Published public private(set) var isRequesting = false
    @Published public private(set) var isCancelingForQuit = false
    @Published public private(set) var notice: String?
    public var onSnapshot: ((ManagedClaudeRuntimeSnapshot) -> Void)?
    private let service: any ManagedClaudeRuntimeServing
    private let admission: AppUpdateAdmission
    private let quitBudget: Duration
    private var observer: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private var closing = false

    public init(service: any ManagedClaudeRuntimeServing, admission: AppUpdateAdmission = .shared,
                quitBudget: Duration = .seconds(30)) {
        self.service = service; self.admission = admission; self.quitBudget = quitBudget
    }

    public var hasActiveRuntime: Bool { snapshot.active != nil }
    public var isBusy: Bool { isRequesting || snapshot.isChecking }
    public var canCheck: Bool { started && !closing && !isBusy && !isCancelingForQuit && admission.allowsWork }
    public var needsAuthentication: Bool { snapshot.phase == .needsAuthentication }

    public func start() {
        guard !started, !closing else { return }
        started = true
        observer = Task { [weak self, service] in
            let updates = await service.updates()
            for await value in updates {
                guard let self, !Task.isCancelled, !closing else { return }
                snapshot = value
                onSnapshot?(value)
            }
        }
        check()
    }

    public func check() { perform(retry: false) }
    public func retry() { perform(retry: true) }

    private func perform(retry: Bool) {
        guard canCheck else { return }
        let token = UUID()
        generation = token
        isRequesting = true
        notice = nil
        request = Task { [weak self, service] in
            let value = retry ? await service.retry() : await service.checkForUpdates()
            guard let self, !closing, generation == token else { return }
            request = nil
            isRequesting = false
            snapshot = value
            onSnapshot?(value)
        }
    }

    public func cancel() {
        guard !closing, !isCancelingForQuit else { return }
        let token = UUID()
        generation = token
        request?.cancel()
        isRequesting = true
        request = Task { [weak self, service] in
            await service.cancel()
            guard let self, !closing, generation == token else { return }
            request = nil
            isRequesting = false
        }
    }

    /// Ordinary Quit waits for the candidate's real process cleanup before the
    /// existing draft shutdown begins. A timeout cancels Quit, not the working app.
    @discardableResult
    public func cancelBeforeQuitting(reply: @escaping (Bool) -> Void) -> Bool {
        guard isBusy || isCancelingForQuit else { return false }
        guard !isCancelingForQuit else { return true }
        isCancelingForQuit = true
        generation = UUID()
        request?.cancel()
        let cancellation = Task<Void, any Error> { [service] in await service.cancel() }
        Task { [weak self] in
            guard let self else { return }
            let result = await BudgetedWait.result(of: cancellation, within: quitBudget)
            isCancelingForQuit = false
            switch result {
            case .finished(.success):
                request = nil
                isRequesting = false
                reply(true)
            case .finished(.failure), .budgetExceeded:
                notice = "Claude's compatibility check has not finished stopping. Quit was canceled; try again when it stops."
                reply(false)
            }
        }
        return true
    }

    public func beginShutdown() {
        guard !closing else { return }
        closing = true
        generation = UUID()
        observer?.cancel(); observer = nil
        request?.cancel()
    }

    public func finishShutdown() async { await service.shutdown() }
}

/// Orders a first install's two sign-ins and keeps the screens honest about
/// them.
/// It picks the setup the banner and Settings drive, never lets a test sign-in
/// read as "Connected", starts the paid compatibility suite after a sign-in only
/// for a candidate not tested yet, and checks the bots' own sign-in once for
/// every new working version, whatever the candidate is doing.
@MainActor
public final class ClaudeSetupFlow {
    /// What a sign-in that has just completed may start. A passed, failed or
    /// interrupted candidate runs again only from the disclosed retry control.
    /// `wait`: the runtime is between answers, so the next settled one decides.
    public enum SignInFollowUp: Equatable, Sendable { case none, check, retry, wait }

    public let runtime: ClaudeRuntimeModel
    public let bots: ClaudeSetupModel
    public let compatibility: ClaudeSetupModel
    /// Called for every runtime snapshot, as the composition's own observer was.
    public var onChange: (() -> Void)?
    private let usesReviewFixtures: Bool
    private var checkedActiveHash: String?
    private var compatibilityEpoch: UInt64
    private var sawNoActiveRuntime = false
    /// A verified sign-in whose follow-up is not decided yet. Coming back from
    /// Terminal checks the sign-in and the runtime together, so the sign-in
    /// often lands while the runtime is still discovering.
    private var signInFollowUpPending = false
    private var observation: AnyCancellable?
    private var closed = false

    public init(runtime: ClaudeRuntimeModel, bots: ClaudeSetupModel, compatibility: ClaudeSetupModel,
                usesReviewFixtures: Bool = false) {
        self.runtime = runtime
        self.bots = bots
        self.compatibility = compatibility
        self.usesReviewFixtures = usesReviewFixtures
        compatibilityEpoch = compatibility.authenticationEpoch
        applySteps(runtime: runtime.snapshot, compatibility: compatibility.state)
        runtime.onSnapshot = { [weak self] snapshot in self?.runtimeChanged(snapshot) }
        // Combine publishes on the main actor before the value is stored, so the
        // new state arrives as the argument; the epoch is already advanced.
        observation = compatibility.$state.sink { [weak self] state in self?.compatibilityChanged(state) }
    }

    /// The bots' own setup once a working version exists; until then, the test's.
    /// Before the retained selection is read, the neutral bots' screen shows.
    public var presented: ClaudeSetupModel {
        usesReviewFixtures || !Self.awaitsFirstVersion(runtime.snapshot) ? bots : compatibility
    }

    public func close() {
        closed = true
        observation = nil
        runtime.onSnapshot = nil
    }

    nonisolated static func awaitsFirstVersion(_ snapshot: ManagedClaudeRuntimeSnapshot) -> Bool {
        guard snapshot.active == nil else { return false }
        if snapshot.selection != nil { return true }
        return ![.unavailable, .idle, .discovering].contains(snapshot.phase)
    }

    /// The step the presented setup is on. Pure, so the order is testable.
    nonisolated static func step(runtime snapshot: ManagedClaudeRuntimeSnapshot, compatibility: ClaudeSetupState,
                                 sawNoActiveRuntime: Bool) -> ClaudeSetupStep {
        guard awaitsFirstVersion(snapshot) else {
            return snapshot.active != nil && sawNoActiveRuntime ? .signInForBots : .bots
        }
        let version = snapshot.candidate?.version
        switch snapshot.phase {
        case .needsAuthentication: return .signInForTesting
        case .checking: return .testing(.init(stage: .running, version: version))
        case .waitingForIdle: return .testing(.init(stage: .waiting, version: version))
        case .failed, .cancelled: return .testing(.init(stage: .failed, version: version))
        case .unavailable, .idle, .discovering, .ready, .stopped:
            guard case .verified = compatibility else { return .signInForTesting }
            guard snapshot.candidate != nil else { return .noVersionToTest }
            return .testing(.init(stage: .waiting, version: version))
        }
    }

    /// Only a candidate still waiting on its sign-in is retried; one not yet
    /// looked at gets the ordinary check, which never reruns a stored result.
    nonisolated static func followUp(afterSignInAt phase: ManagedClaudeRuntimeSnapshot.Phase) -> SignInFollowUp {
        switch phase {
        case .needsAuthentication: .retry
        case .idle, .unavailable: .check
        case .discovering, .checking: .wait
        case .waitingForIdle, .ready, .failed, .cancelled, .stopped: .none
        }
    }

    private func runtimeChanged(_ snapshot: ManagedClaudeRuntimeSnapshot) {
        guard !closed else { return }
        if snapshot.selection != nil, snapshot.active == nil { sawNoActiveRuntime = true }
        applySteps(runtime: snapshot, compatibility: compatibility.state)
        if !usesReviewFixtures, let active = snapshot.active, active.sha256 != checkedActiveHash,
           bots.checkForNewRuntime() {
            checkedActiveHash = active.sha256
        }
        resolveSignInFollowUp(at: snapshot.phase)
        onChange?()
    }

    private func compatibilityChanged(_ state: ClaudeSetupState) {
        guard !closed else { return }
        applySteps(runtime: runtime.snapshot, compatibility: state)
        // Check Claude and ordinary status checks never advance the epoch; only
        // a verified explicit sign-in does, so they never start the suite.
        guard !usesReviewFixtures, case .verified = state,
              compatibility.authenticationEpoch != compatibilityEpoch else { return }
        compatibilityEpoch = compatibility.authenticationEpoch
        signInFollowUpPending = true
        resolveSignInFollowUp(at: runtime.snapshot.phase)
    }

    /// Decides a pending follow-up once the runtime has settled. A request the
    /// runtime cannot take yet (its own check still returning) also waits: the
    /// check's result arrives as one more snapshot.
    private func resolveSignInFollowUp(at phase: ManagedClaudeRuntimeSnapshot.Phase) {
        guard signInFollowUpPending, !usesReviewFixtures else { return }
        let followUp = Self.followUp(afterSignInAt: phase)
        switch followUp {
        case .wait: return
        case .none: signInFollowUpPending = false
        case .retry, .check:
            guard runtime.canCheck else { return }
            signInFollowUpPending = false
            if followUp == .retry { runtime.retry() } else { runtime.check() }
        }
    }

    private func applySteps(runtime snapshot: ManagedClaudeRuntimeSnapshot, compatibility state: ClaudeSetupState) {
        var step: ClaudeSetupStep = usesReviewFixtures ? .bots
            : Self.step(runtime: snapshot, compatibility: state, sawNoActiveRuntime: sawNoActiveRuntime)
        // Step 2 ends once the bots' sign-in has passed; a later loss says so.
        if step == .signInForBots, bots.hasBeenVerified { step = .bots }
        let firstVersion = Self.awaitsFirstVersion(snapshot) && !usesReviewFixtures
        // The test's setup outside a first install still serves the runtime
        // settings' sign-in for a later candidate: that, too, is for testing.
        let compatibilityStep: ClaudeSetupStep = firstVersion ? step : .signInForTesting
        let botsStep: ClaudeSetupStep = firstVersion ? .bots : step
        if compatibility.step != compatibilityStep { compatibility.step = compatibilityStep }
        if bots.step != botsStep { bots.step = botsStep }
    }
}
