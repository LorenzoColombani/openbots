import Combine
import Foundation
import OpenBotsServices

public enum ClaudeSetupState: Equatable, Sendable {
    case notChecked
    case checking
    /// The local installation and profile are ready, not authenticated.
    case readyToConnect
    case needsSignIn
    case signingIn
    case signedInNeedsVerification
    /// Terminal accepted the command file; no sign-in completion was observed.
    case handedOffNeedsVerification
    case checkingSubscription
    case verified(ClaudeVerifiedSubscription)
    case problem(ClaudeSetupProblem)
    case actionRequired(ClaudeSetupRequirement)
    case cancelled
}

/// What a sign-in on the setup screen is for. A first install asks for two:
/// one for the separate account folder that tests
/// a Claude Code version before the bots use it, then the bots' own. App
/// composition sets it (`ClaudeSetupFlow`); it changes presentation only.
public enum ClaudeSetupStep: Equatable, Sendable {
    /// The bots' own sign-in: the usual screen.
    case bots
    /// No working Claude Code version yet: the first of the two sign-ins.
    case signInForTesting
    /// That sign-in is done, but OpenBots has found no Claude Code version to
    /// test: usually Claude Code is not installed yet.
    case noVersionToTest
    /// That sign-in is done and the version is being tested, waits for its
    /// test, or did not pass. The bots cannot reply yet.
    case testing(ClaudeRuntimeTestProgress)
    /// The version passed its test on this first install: the second sign-in.
    case signInForBots

    /// Only the bots' own sign-in may say "Connected" or hide the banner.
    public var isForBots: Bool { self == .bots || self == .signInForBots }
}

public struct ClaudeRuntimeTestProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case running, waiting, failed }
    public let stage: Stage
    public let version: String?

    public init(stage: Stage, version: String?) {
        self.stage = stage
        self.version = version
    }
}

/// Acknowledges only a completed subscription check requested by the user.
/// Contains no account identifiers, provider output or credential material.
public enum ClaudeSubscriptionFeedback: Equatable, Sendable {
    case verified
    case needsSignIn
    case problem(ClaudeSetupProblem)
    case actionRequired(ClaudeSetupRequirement)
}

/// Shared workspace and Settings presentation, with no credential, message or process input.
/// Construction is inert. Startup may check status once; sign-in always stays explicit.
@MainActor
public final class ClaudeSetupModel: ObservableObject {
    @Published public private(set) var state: ClaudeSetupState = .notChecked
    @Published public private(set) var localFindings: ClaudeOfflineSetupSnapshot?
    @Published public private(set) var subscriptionFeedback: ClaudeSubscriptionFeedback?
    @Published public private(set) var isShuttingDown = false
    @Published public internal(set) var step: ClaudeSetupStep = .bots
    /// This sign-in passed a check earlier in this session, so a later "sign
    /// in" may say the session was lost. A first install never says so.
    public private(set) var hasBeenVerified = false
    /// Advances only when an explicit sign-in is verified, never on ordinary
    /// status checks, whose apparently valid authentication may be stale.
    public private(set) var authenticationEpoch: UInt64 = 0

    private let service: any ClaudeSetupServicing
    private var generation: UInt64 = 0
    private var didCheckOnStartup = false
    private var isVerifyingSignIn = false
    private var checksRuntimeAfterLocalCheck = false
    private(set) var actionTask: Task<Void, Never>?

    public init(service: any ClaudeSetupServicing) {
        self.service = service
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .signingIn, .checkingSubscription: true
        default: false
        }
    }

    public var preventsApplicationUpdate: Bool {
        isBusy || state == .handedOffNeedsVerification || state == .signedInNeedsVerification
    }

    public var localInstallationChecked: Bool {
        localFindings?.installation == .verified
    }

    /// Controls presentation only. The service must recheck the installation,
    /// profile and operation-specific admission before any provider action.
    public var hasVerifiedLocalSetup: Bool {
        localInstallationChecked && localFindings?.profile == .metadataVerified
    }

    public var offersSignIn: Bool {
        guard !isShuttingDown else { return false }
        // While a version is tested or failed its test, signing in again is not
        // the next step; a lost sign-in still reports needsSignIn and is offered.
        if case .testing = step { return state == .needsSignIn }
        return switch state {
        case .notChecked, .readyToConnect, .needsSignIn: true
        default: false
        }
    }

    /// Called after local storage and the workspace are ready. A check is never
    /// a sign-in, never repeats automatically, and never supersedes a user's action.
    public func checkOnStartupOnce() {
        guard !didCheckOnStartup, !isShuttingDown else { return }
        didCheckOnStartup = true
        guard state == .notChecked else { return }
        start(.startupSubscription)
    }

    /// A new working Claude Code version, at launch or once a tested one is
    /// switched in, is checked against this sign-in so live models are found.
    /// A sign-in under way is never replaced: its own
    /// check follows it. False when nothing started and nothing is under way.
    @discardableResult
    public func checkForNewRuntime() -> Bool {
        guard !isShuttingDown else { return false }
        switch state {
        case .signingIn, .checkingSubscription, .handedOffNeedsVerification, .signedInNeedsVerification: return true
        case .checking:
            // Inspect Installation is running: it is not replaced, and this
            // check follows it.
            checksRuntimeAfterLocalCheck = true
            return true
        default: break
        }
        start(.startupSubscription)
        return state == .checkingSubscription
    }

    public func connectClaude() { start(.localCheck) }
    public func checkSubscription() { start(.subscription) }
    public func beginOfficialSignIn() {
        guard offersSignIn else { return }
        start(.signIn)
    }


    /// The app came to the front. Sign-in finishes in Terminal and the browser,
    /// so while the screen waits on one, run the same check Check Claude runs.
    /// Every other state stays as it is: nothing is checked that the user did
    /// not start.
    public func appBecameActive() {
        switch state {
        case .handedOffNeedsVerification, .signedInNeedsVerification: checkSubscription()
        default: return
        }
    }

    public func dismissSubscriptionFeedback() {
        subscriptionFeedback = nil
    }

    /// A settled, correlated turn failure invalidates older status evidence.
    /// This changes presentation only: reconnecting stays the user's action.
    public func requireSignInAfterTurnFailure(observedEpoch: UInt64) {
        guard observedEpoch == authenticationEpoch, !isShuttingDown, !isVerifyingSignIn else { return }
        switch state {
        case .signingIn, .handedOffNeedsVerification, .signedInNeedsVerification: return
        default: break
        }
        invalidatePendingAction()
        state = .needsSignIn
    }

    /// Stops presentation of a pending result. It does not claim that a
    /// provider session was revoked or that a completed sign-in was undone.
    public func cancelCurrentAction() {
        guard isBusy else { return }
        invalidatePendingAction()
        state = .cancelled
    }

    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelCurrentAction()
        invalidatePendingAction()
    }

    private enum Action {
        case localCheck
        case subscription
        case startupSubscription
        case signIn

        var pendingState: ClaudeSetupState {
            switch self {
            case .localCheck: .checking
            case .subscription, .startupSubscription: .checkingSubscription
            case .signIn: .signingIn
            }
        }
    }

    private func start(_ action: Action) {
        guard ApplicationUpdateGate.shared.allowsWork else { return }
        guard !isShuttingDown else { return }
        let followsSignIn: Bool
        switch action {
        case .signIn: followsSignIn = true
        case .subscription:
            followsSignIn = isVerifyingSignIn || state == .handedOffNeedsVerification || state == .signedInNeedsVerification
        default: followsSignIn = false
        }
        // A repeated Inspect Installation keeps the waiting runtime check; any
        // other action is itself a check or a sign-in, whose check follows it.
        let keepsRuntimeCheck = action == .localCheck && checksRuntimeAfterLocalCheck
        invalidatePendingAction()
        checksRuntimeAfterLocalCheck = keepsRuntimeCheck
        isVerifyingSignIn = followsSignIn
        let requestedGeneration = generation
        let service = self.service
        state = action.pendingState
        actionTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let report: ClaudeSetupReport
            switch action {
            case .localCheck: report = await service.checkThisMac()
            case .subscription, .startupSubscription: report = await service.checkSubscription()
            case .signIn: report = await service.beginOfficialSignIn()
            }
            guard !Task.isCancelled, let self,
                  !isShuttingDown, generation == requestedGeneration else { return }
            if let local = report.local { localFindings = local }
            switch report.outcome {
            case .readyToConnect: state = .readyToConnect
            case .actionRequired(let requirement): state = .actionRequired(requirement)
            case .needsSignIn: state = .needsSignIn
            case .signedInNeedsVerification: state = .signedInNeedsVerification
            case .handedOffNeedsVerification: state = .handedOffNeedsVerification
            case .verified(let evidence):
                if followsSignIn { authenticationEpoch &+= 1 }
                hasBeenVerified = true
                if step == .signInForBots { step = .bots }
                state = .verified(evidence)
            case .problem(let problem): state = .problem(problem)
            case .cancelled: state = .cancelled
            }
            actionTask = nil
            isVerifyingSignIn = false
            if case .subscription = action {
                switch report.outcome {
                case .verified: subscriptionFeedback = .verified
                case .needsSignIn: subscriptionFeedback = .needsSignIn
                case .problem(let problem): subscriptionFeedback = .problem(problem)
                case .actionRequired(let requirement): subscriptionFeedback = .actionRequired(requirement)
                case .readyToConnect, .signedInNeedsVerification, .handedOffNeedsVerification, .cancelled:
                    subscriptionFeedback = nil
                }
            }
            if checksRuntimeAfterLocalCheck {
                checksRuntimeAfterLocalCheck = false
                start(.startupSubscription)
            }
        }
    }

    private func invalidatePendingAction() {
        dismissSubscriptionFeedback()
        checksRuntimeAfterLocalCheck = false
        isVerifyingSignIn = false
        generation &+= 1
        actionTask?.cancel()
        actionTask = nil
    }
}
