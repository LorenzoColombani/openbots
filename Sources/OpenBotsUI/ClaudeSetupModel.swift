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

/// Acknowledges only a completed subscription check requested by the user.
/// Contains no account identifiers, provider output or credential material.
public enum ClaudeSubscriptionFeedback: Equatable, Sendable {
    case verified
    case needsSignIn
    case problem(ClaudeSetupProblem)
    case actionRequired(ClaudeSetupRequirement)
}

/// Settings-scoped presentation, with no credential, message or process input.
/// Construction is inert. Every service call follows a distinct explicit action.
@MainActor
public final class ClaudeSetupModel: ObservableObject {
    @Published public private(set) var state: ClaudeSetupState = .notChecked
    @Published public private(set) var localFindings: ClaudeOfflineSetupSnapshot?
    @Published public private(set) var subscriptionFeedback: ClaudeSubscriptionFeedback?
    @Published public private(set) var isShuttingDown = false

    private let service: any ClaudeSetupServicing
    private var generation: UInt64 = 0
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

    public var localInstallationChecked: Bool {
        localFindings?.installation == .verified
    }

    /// Controls presentation only. The service must recheck the installation,
    /// profile and operation-specific admission before any provider action.
    public var hasVerifiedLocalSetup: Bool {
        localInstallationChecked && localFindings?.profile == .metadataVerified
    }

    public func connectClaude() { start(.localCheck) }
    public func checkSubscription() { start(.subscription) }
    public func beginOfficialSignIn() { start(.signIn) }

    public func dismissSubscriptionFeedback() {
        subscriptionFeedback = nil
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
        case signIn

        var pendingState: ClaudeSetupState {
            switch self {
            case .localCheck: .checking
            case .subscription: .checkingSubscription
            case .signIn: .signingIn
            }
        }
    }

    private func start(_ action: Action) {
        guard !isShuttingDown else { return }
        invalidatePendingAction()
        let requestedGeneration = generation
        let service = self.service
        state = action.pendingState
        actionTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let report: ClaudeSetupReport
            switch action {
            case .localCheck: report = await service.checkThisMac()
            case .subscription: report = await service.checkSubscription()
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
            case .verified(let evidence): state = .verified(evidence)
            case .problem(let problem): state = .problem(problem)
            case .cancelled: state = .cancelled
            }
            actionTask = nil
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
        }
    }

    private func invalidatePendingAction() {
        dismissSubscriptionFeedback()
        generation &+= 1
        actionTask?.cancel()
        actionTask = nil
    }
}
