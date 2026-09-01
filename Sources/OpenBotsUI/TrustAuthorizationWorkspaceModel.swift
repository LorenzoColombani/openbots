import Combine
import Foundation
import OpenBotsDomain

/// Presentation state for one conversation's in-memory trust demonstration.
/// The factory creates only fixture services. No repository, runtime, Keychain,
/// permission prompt, URL or filesystem capability is held by this model.
@MainActor
public final class TrustAuthorizationWorkspaceModel: ObservableObject {
    public typealias ServiceFactory = @MainActor (
        TrustFixtureContext
    ) -> any TrustAuthorizationFixtureServicing

    @Published public private(set) var context: TrustFixtureContext?
    @Published public private(set) var teammateName = ""
    @Published public private(set) var snapshot: TrustFixtureSnapshot?
    @Published public private(set) var isBusy = false
    @Published public private(set) var failure: String?
    @Published public private(set) var pendingGrantReview: FixtureGrantReview?
    @Published public private(set) var approvalReview: FixtureApprovalReview?

    private let serviceFactory: ServiceFactory
    private var services: [TrustFixtureContext: any TrustAuthorizationFixtureServicing] = [:]
    private var generation: UInt64 = 0

    public init(serviceFactory: @escaping ServiceFactory) {
        self.serviceFactory = serviceFactory
    }

    /// Switching clears local reviews immediately. Cached fixture grants remain
    /// bound to the exact teammate/conversation, not a display name or project.
    /// No in-flight result can publish into a later activation, even A → B → A.
    public func activateContext(_ context: TrustFixtureContext?, teammateName: String = "") {
        guard self.context != context else {
            self.teammateName = teammateName
            return
        }
        generation &+= 1
        self.context = context
        self.teammateName = teammateName
        snapshot = nil
        isBusy = false
        failure = nil
        pendingGrantReview = nil
        approvalReview = nil
    }

    public var approvalState: FixtureApprovalState? {
        guard let approvalReview else { return nil }
        return snapshot?.approvals.first { $0.id == approvalReview.id }?.state
    }

    public var grantReviewState: FixtureGrantReviewState? {
        guard let pendingGrantReview else { return nil }
        return snapshot?.grantReviews.first { $0.id == pendingGrantReview.id }?.state
    }

    public var hasActiveReview: Bool {
        pendingGrantReview != nil || approvalState == .pending || approvalState == .approved
    }

    public func load() async {
        guard !isBusy, let context else { return }
        let requestedGeneration = generation
        let service = service(for: context)
        isBusy = true
        failure = nil
        do {
            let loaded = try await service.snapshot(context: context)
            guard isCurrent(context, generation: requestedGeneration) else { return }
            try accept(loaded, for: context)
        } catch {
            guard isCurrent(context, generation: requestedGeneration) else { return }
            failure = TrustAuthorizationPresentation.loadFailure
        }
        guard isCurrent(context, generation: requestedGeneration) else { return }
        isBusy = false
    }

    public func prepareGrant(_ capability: FixtureCapability) async {
        guard !isBusy, !hasActiveReview, let context else { return }
        let service = service(for: context)
        let requestedGeneration = generation
        isBusy = true
        failure = nil
        approvalReview = nil
        do {
            let review = try await service.prepareGrant(context: context, capability: capability)
            let loaded = try await service.snapshot(context: context)
            guard isCurrent(context, generation: requestedGeneration) else { return }
            guard review.context == context, review.capability == capability else {
                throw TrustFixtureError.contextMismatch
            }
            try accept(loaded, for: context)
            pendingGrantReview = review
        } catch {
            await recordFailure(error, service: service, context: context, generation: requestedGeneration)
        }
        guard isCurrent(context, generation: requestedGeneration) else { return }
        isBusy = false
    }

    public func confirmPendingGrant() async {
        guard let review = pendingGrantReview, grantReviewState == .pending else { return }
        await mutate { service, context in
            try await service.confirmGrant(context: context, review: review)
        }
        if pendingGrantReview?.id == review.id, grantReviewState == .confirmed {
            pendingGrantReview = nil
        }
    }

    public func cancelPendingGrant() async {
        guard let review = pendingGrantReview else { return }
        if grantReviewState != .pending {
            pendingGrantReview = nil
            return
        }
        await mutate { service, context in
            try await service.declineGrant(context: context, review: review)
        }
        if pendingGrantReview?.id == review.id, grantReviewState != .pending {
            pendingGrantReview = nil
        }
    }

    public func revoke(_ capability: FixtureCapability) async {
        guard let grant = snapshot?.activeGrant(for: capability) else { return }
        await mutate { service, context in
            try await service.revoke(context: context, grantID: grant.id)
        }
    }

    public func prepareApproval(_ proposal: FixtureActionProposal) async {
        guard !isBusy, !hasActiveReview, let context else { return }
        let service = service(for: context)
        let requestedGeneration = generation
        isBusy = true
        failure = nil
        approvalReview = nil
        do {
            let review = try await service.prepareApproval(context: context, proposal: proposal)
            let loaded = try await service.snapshot(context: context)
            guard isCurrent(context, generation: requestedGeneration) else { return }
            guard review.context == context, review.proposal == proposal else {
                throw TrustFixtureError.contextMismatch
            }
            try accept(loaded, for: context)
            approvalReview = review
        } catch {
            await recordFailure(error, service: service, context: context, generation: requestedGeneration)
        }
        guard isCurrent(context, generation: requestedGeneration) else { return }
        isBusy = false
    }

    public func approveOnce() async {
        await resolveApproval(.approve)
    }

    public func deny() async {
        await resolveApproval(.deny)
    }

    public func simulateOnce() async {
        guard let review = approvalReview, approvalState == .approved else { return }
        await mutate { service, context in
            try await service.consumeApprovedPreview(context: context, review: review)
        }
    }

    public func setMacOSPermission(_ value: FixtureMacOSPermission) async {
        await mutate { service, context in
            try await service.setMacOSPermission(context: context, value: value)
        }
    }

    public func setConnectorInstallation(_ value: ConnectorInstallationState) async {
        await mutate { service, context in
            try await service.setConnectorInstallation(context: context, value: value)
        }
    }

    public func setConnectorAuthentication(_ value: ConnectorAccountAuthenticationState) async {
        await mutate { service, context in
            try await service.setConnectorAuthentication(context: context, value: value)
        }
    }

    private func resolveApproval(_ decision: ApprovalDecision) async {
        guard let review = approvalReview, approvalState == .pending else { return }
        await mutate { service, context in
            try await service.resolveApproval(context: context, review: review, decision: decision)
        }
    }

    private func mutate(
        _ operation: @Sendable (
            any TrustAuthorizationFixtureServicing, TrustFixtureContext
        ) async throws -> TrustFixtureSnapshot
    ) async {
        guard !isBusy, let context else { return }
        let requestedGeneration = generation
        let service = service(for: context)
        isBusy = true
        failure = nil
        do {
            let updated = try await operation(service, context)
            guard isCurrent(context, generation: requestedGeneration) else { return }
            try accept(updated, for: context)
        } catch {
            await recordFailure(error, service: service, context: context, generation: requestedGeneration)
        }
        guard isCurrent(context, generation: requestedGeneration) else { return }
        isBusy = false
    }

    private func service(for context: TrustFixtureContext) -> any TrustAuthorizationFixtureServicing {
        if let cached = services[context] { return cached }
        let service = serviceFactory(context)
        services[context] = service
        return service
    }

    private func isCurrent(_ context: TrustFixtureContext, generation: UInt64) -> Bool {
        self.context == context && self.generation == generation
    }

    private func accept(_ snapshot: TrustFixtureSnapshot, for context: TrustFixtureContext) throws {
        guard snapshot.context == context,
              snapshot.grants.allSatisfy({ $0.context == context }),
              snapshot.grantReviews.allSatisfy({ $0.review.context == context }),
              snapshot.approvals.allSatisfy({ $0.review.context == context }) else {
            throw TrustFixtureError.contextMismatch
        }
        self.snapshot = snapshot
    }

    private func recordFailure(
        _ error: any Error,
        service: any TrustAuthorizationFixtureServicing,
        context: TrustFixtureContext,
        generation: UInt64
    ) async {
        guard isCurrent(context, generation: generation) else { return }
        // Refresh expiry/revocation state after a rejected operation without
        // displaying raw error material or affecting another conversation.
        if let refreshed = try? await service.snapshot(context: context),
           isCurrent(context, generation: generation) {
            try? accept(refreshed, for: context)
        }
        guard isCurrent(context, generation: generation) else { return }
        failure = (error as? TrustFixtureError) == .expiredReview
            ? "This demo review expired. Prepare a fresh review; no real action ran."
            : TrustAuthorizationPresentation.actionFailure
    }
}
