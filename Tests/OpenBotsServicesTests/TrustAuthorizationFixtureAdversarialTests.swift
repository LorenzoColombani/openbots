import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing

@Suite("Trust authorization fixture adversarial boundaries")
struct TrustAuthorizationFixtureAdversarialTests {
    @Test("Every immutable grant field is bound without consuming the legitimate review")
    func grantReviewTamperingPreservesLegitimateReview() async throws {
        let h = TrustAdversarialHarness()
        let review = try await h.service.prepareGrant(context: h.context, capability: .readReferenceFolder)
        let mutations = [
            replacingGrant(review, id: UUID()),
            replacingGrant(review, context: changedTeammate(h.context)),
            replacingGrant(review, context: changedConversation(h.context)),
            replacingGrant(review, capability: .connectorUse),
            replacingGrant(review, scopeSummary: "A different folder"),
            replacingGrant(review, effectSummary: "Grant write access instead"),
            replacingGrant(review, generation: review.generation + 1),
            replacingGrant(review, createdAt: review.createdAt.addingTimeInterval(-1)),
            replacingGrant(review, expiresAt: review.expiresAt.addingTimeInterval(1)),
            replacingGrant(review, fingerprint: String(repeating: "0", count: 64))
        ]
        for changed in mutations {
            await #expect(throws: TrustFixtureError.self) {
                try await h.service.confirmGrant(context: h.context, review: changed)
            }
            let state = try await h.service.snapshot(context: h.context)
            #expect(state.grants.isEmpty)
            #expect(state.grantReviews.first { $0.id == review.id }?.state == .pending)
        }
        let confirmed = try await h.service.confirmGrant(context: h.context, review: review)
        #expect(confirmed.activeGrant(for: .readReferenceFolder) != nil)
        #expect(confirmed.grants.count == 1)
        #expect(confirmed.macOSPermission == .notDetermined)
        #expect(confirmed.connector.perBotGrant == .notGranted)
    }

    @Test("Action target, payload, context and issuance stay frozen through resolve and consume")
    func approvalReviewTamperingPreservesLegitimateReview() async throws {
        let h = TrustAdversarialHarness()
        let review = try await preparedArtifact(h)
        let mutations = [
            replacingApproval(review, id: ApprovalID(UUID())),
            replacingApproval(review, context: changedTeammate(h.context)),
            replacingApproval(review, context: changedConversation(h.context)),
            replacingApproval(review, proposal: .completedArtifact(
                filename: "different.pdf", contentSummary: review.proposal.payloadSummary)),
            replacingApproval(review, proposal: .completedArtifact(
                filename: "research-summary.pdf", contentSummary: "A different payload")),
            replacingApproval(review, grantID: CapabilityGrantID(UUID())),
            replacingApproval(review, grantGeneration: review.grantGeneration + 1),
            replacingApproval(review, scopeSummary: "Another delivery scope"),
            replacingApproval(review, effectSummary: "Overwrite the existing file"),
            replacingApproval(review, createdAt: review.createdAt.addingTimeInterval(-1)),
            replacingApproval(review, expiresAt: review.expiresAt.addingTimeInterval(1)),
            replacingApproval(review, fingerprint: String(repeating: "0", count: 64))
        ]
        for changed in mutations {
            await #expect(throws: TrustFixtureError.self) {
                try await h.service.resolveApproval(context: h.context, review: changed, decision: .approve)
            }
            let state = try await h.service.snapshot(context: h.context)
            #expect(state.approvals.first { $0.id == review.id }?.state == .pending)
        }
        _ = try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        for changed in mutations {
            await #expect(throws: TrustFixtureError.self) {
                try await h.service.consumeApprovedPreview(context: h.context, review: changed)
            }
            let state = try await h.service.snapshot(context: h.context)
            #expect(state.approvals.first { $0.id == review.id }?.state == .approved)
        }
        let consumed = try await h.service.consumeApprovedPreview(context: h.context, review: review)
        #expect(consumed.approvals.first { $0.id == review.id }?.state == .simulated)
    }

    @Test("Wrong submitted teammate or conversation cannot consume or revoke legitimate context")
    func submittedContextCannotRedirectActions() async throws {
        let h = TrustAdversarialHarness()
        let review = try await preparedArtifact(h)
        _ = try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        for wrong in [changedTeammate(h.context), changedConversation(h.context)] {
            await #expect(throws: TrustFixtureError.contextMismatch) {
                try await h.service.consumeApprovedPreview(context: wrong, review: review)
            }
            await #expect(throws: TrustFixtureError.contextMismatch) {
                try await h.service.revoke(context: wrong, grantID: review.grantID)
            }
            await #expect(throws: TrustFixtureError.contextMismatch) {
                try await h.service.setMacOSPermission(context: wrong, value: .denied)
            }
        }
        let consumed = try await h.service.consumeApprovedPreview(context: h.context, review: review)
        #expect(consumed.macOSPermission == .granted)
        #expect(consumed.activeGrant(for: .createCompletedArtifact)?.id == review.grantID)
        #expect(consumed.approvals.first { $0.id == review.id }?.state == .simulated)
    }

    @Test("An old review is not authority in a fresh service with the same context and clock")
    func freshServiceRejectsOldPrivateIssuance() async throws {
        let h = TrustAdversarialHarness()
        let grant = try await h.service.prepareGrant(context: h.context, capability: .readReferenceFolder)
        let review = try await preparedArtifact(h)
        _ = try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        let fresh = TrustAuthorizationFixtureService(context: h.context, clock: h.clock, reviewLifetime: 60)
        await #expect(throws: TrustFixtureError.unissuedReview) {
            try await fresh.confirmGrant(context: h.context, review: grant)
        }
        await #expect(throws: TrustFixtureError.unissuedReview) {
            try await fresh.resolveApproval(context: h.context, review: review, decision: .approve)
        }
        await #expect(throws: TrustFixtureError.unissuedReview) {
            try await fresh.consumeApprovedPreview(context: h.context, review: review)
        }
        let state = try await fresh.snapshot(context: h.context)
        #expect(state.grants.isEmpty)
        #expect(state.approvals.isEmpty)
        #expect(state.macOSPermission == .notDetermined)
        _ = try await h.service.confirmGrant(context: h.context, review: grant)
        _ = try await h.service.consumeApprovedPreview(context: h.context, review: review)
    }

    @Test("Grant confirmation fails at the exact expiry boundary")
    func grantExpiryIsExclusive() async throws {
        let h = TrustAdversarialHarness()
        let review = try await h.service.prepareGrant(context: h.context, capability: .readReferenceFolder)
        h.clock.set(review.expiresAt)
        await #expect(throws: TrustFixtureError.expiredReview) {
            try await h.service.confirmGrant(context: h.context, review: review)
        }
        let state = try await h.service.snapshot(context: h.context)
        #expect(state.grants.isEmpty)
        #expect(state.grantReviews.first { $0.id == review.id }?.state == .expired)
    }

    @Test("Approval decision fails at expiry without producing an approved action")
    func approvalDecisionExpiryIsExclusive() async throws {
        let h = TrustAdversarialHarness()
        let review = try await preparedArtifact(h)
        h.clock.set(review.expiresAt)
        await #expect(throws: TrustFixtureError.expiredReview) {
            try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        }
        let state = try await h.service.snapshot(context: h.context)
        #expect(state.approvals.first { $0.id == review.id }?.state == .expired)
    }

    @Test("Earlier approval does not bypass expiry at consumption")
    func consumptionRechecksExpiry() async throws {
        let h = TrustAdversarialHarness()
        let review = try await preparedArtifact(h)
        _ = try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        h.clock.set(review.expiresAt)
        await #expect(throws: TrustFixtureError.expiredReview) {
            try await h.service.consumeApprovedPreview(context: h.context, review: review)
        }
        let state = try await h.service.snapshot(context: h.context)
        #expect(state.approvals.first { $0.id == review.id }?.state == .expired)
        #expect(!state.approvals.contains { $0.state == .simulated })
    }

    @Test("Revoking then regranting never revives an old approved action")
    func revokeGenerationCannotBeRevived() async throws {
        let h = TrustAdversarialHarness()
        let oldReview = try await preparedArtifact(h)
        _ = try await h.service.resolveApproval(context: h.context, review: oldReview, decision: .approve)
        let revoked = try await h.service.revoke(context: h.context, grantID: oldReview.grantID)
        #expect(revoked.approvals.first { $0.id == oldReview.id }?.state == .invalidated)
        #expect(revoked.macOSPermission == .granted)
        let newGrantReview = try await h.service.prepareGrant(context: h.context, capability: .createCompletedArtifact)
        let regranted = try await h.service.confirmGrant(context: h.context, review: newGrantReview)
        let newGrant = try #require(regranted.activeGrant(for: .createCompletedArtifact))
        #expect(newGrant.id != oldReview.grantID)
        #expect(newGrant.generation > oldReview.grantGeneration)
        await #expect(throws: TrustFixtureError.grantRevoked) {
            try await h.service.consumeApprovedPreview(context: h.context, review: oldReview)
        }
        let newReview = try await h.service.prepareApproval(context: h.context, proposal: .sampleArtifact)
        _ = try await h.service.resolveApproval(context: h.context, review: newReview, decision: .approve)
        let state = try await h.service.consumeApprovedPreview(context: h.context, review: newReview)
        #expect(state.approvals.first { $0.id == oldReview.id }?.state == .invalidated)
        #expect(state.approvals.first { $0.id == newReview.id }?.state == .simulated)
    }

    @Test("Thirty-two concurrent consume attempts produce exactly one winner")
    func concurrentConsumptionHasOneWinner() async throws {
        let h = TrustAdversarialHarness()
        let review = try await preparedArtifact(h)
        _ = try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        _ = try await h.service.consumeApprovedPreview(context: h.context, review: review)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(successes == 1)
        let state = try await h.service.snapshot(context: h.context)
        #expect(state.approvals.filter { $0.id == review.id && $0.state == .simulated }.count == 1)
        await #expect(throws: TrustFixtureError.alreadyConsumed) {
            try await h.service.consumeApprovedPreview(context: h.context, review: review)
        }
    }

    @Test("Broad read grants confer no change authority and provider mutations never become reviews")
    func broadReadCannotBecomeMutation() async throws {
        let h = TrustAdversarialHarness()
        _ = try await h.service.setMacOSPermission(context: h.context, value: .granted)
        let grantReview = try await h.service.prepareGrant(context: h.context, capability: .readReferenceFolder)
        let granted = try await h.service.confirmGrant(context: h.context, review: grantReview)
        for proposal in [FixtureActionProposal.sampleArtifact, .sampleConnectorSend] {
            await #expect(throws: TrustFixtureError.grantMissing) {
                try await h.service.prepareApproval(context: h.context, proposal: proposal)
            }
        }
        let operations: [ConsequentialActionKind] = [.delete, .overwrite, .move, .rename, .metadataMutation]
        for operation in operations {
            for recursive in [false, true] {
                await #expect(throws: TrustFixtureError.unsupportedOperation) {
                    try await h.service.prepareApproval(context: h.context, proposal: .unsupportedMutation(
                        operation: operation, targetSummary: "Demo provider-managed root and sibling content", recursive: recursive))
                }
            }
        }
        let state = try await h.service.snapshot(context: h.context)
        #expect(state.approvals.isEmpty)
        #expect(state.grants == granted.grants)
        #expect(state.connector == granted.connector)
        #expect(state.activeGrant(for: .createCompletedArtifact) == nil)
        #expect(state.activeGrant(for: .connectorUse) == nil)
    }

    @Test("macOS, install, account, bot grant and action approval remain independent")
    func authorizationAxesRemainIndependent() async throws {
        let h = TrustAdversarialHarness()
        let grantReview = try await h.service.prepareGrant(context: h.context, capability: .connectorUse)
        let granted = try await h.service.confirmGrant(context: h.context, review: grantReview)
        #expect(granted.macOSPermission == .notDetermined)
        #expect(granted.connector.installation == .notInstalled)
        #expect(granted.connector.accountAuthentication == .notAuthenticated)
        #expect(granted.connector.perBotGrant == .granted)
        #expect(granted.connector.perActionApproval == .notRequested)
        let authenticated = try await h.service.setConnectorAuthentication(context: h.context, value: .authenticated)
        #expect(authenticated.macOSPermission == granted.macOSPermission)
        #expect(authenticated.connector.installation == granted.connector.installation)
        #expect(authenticated.grants == granted.grants)
        #expect(authenticated.connector.perActionApproval == .notRequested)
        _ = try await h.service.setMacOSPermission(context: h.context, value: .granted)
        await #expect(throws: TrustFixtureError.prerequisitesNotReady) {
            try await h.service.prepareApproval(context: h.context, proposal: .sampleConnectorSend)
        }
        let installed = try await h.service.setConnectorInstallation(context: h.context, value: .installed)
        #expect(installed.connector.accountAuthentication == .authenticated)
        #expect(installed.connector.perBotGrant == .granted)
        #expect(installed.connector.perActionApproval == .notRequested)
        let review = try await h.service.prepareApproval(context: h.context, proposal: .sampleConnectorSend)
        _ = try await h.service.resolveApproval(context: h.context, review: review, decision: .approve)
        let deniedOS = try await h.service.setMacOSPermission(context: h.context, value: .denied)
        #expect(deniedOS.connector.installation == .installed)
        #expect(deniedOS.connector.accountAuthentication == .authenticated)
        #expect(deniedOS.connector.perBotGrant == .granted)
        #expect(deniedOS.connector.perActionApproval == .approved)
        await #expect(throws: TrustFixtureError.prerequisitesNotReady) {
            try await h.service.consumeApprovedPreview(context: h.context, review: review)
        }
        _ = try await h.service.setMacOSPermission(context: h.context, value: .granted)
        _ = try await h.service.consumeApprovedPreview(context: h.context, review: review)
        let revoked = try await h.service.revoke(context: h.context, grantID: review.grantID)
        #expect(revoked.macOSPermission == .granted)
        #expect(revoked.connector.installation == .installed)
        #expect(revoked.connector.accountAuthentication == .authenticated)
        #expect(revoked.connector.perBotGrant == .revoked)
    }

    @Test("A readiness failure never prevents declining the exact pending action")
    func denialRemainsAvailableWithoutReadiness() async throws {
        let h = TrustAdversarialHarness()
        let review = try await preparedArtifact(h)
        _ = try await h.service.setMacOSPermission(context: h.context, value: .denied)
        let state = try await h.service.resolveApproval(context: h.context, review: review, decision: .deny)
        #expect(state.approvals.first { $0.id == review.id }?.state == .denied)
        #expect(state.macOSPermission == .denied)
        #expect(state.activeGrant(for: .createCompletedArtifact) != nil)
        await #expect(throws: TrustFixtureError.self) {
            try await h.service.consumeApprovedPreview(context: h.context, review: review)
        }
    }
}

private struct TrustAdversarialHarness: Sendable {
    let context: TrustFixtureContext
    let clock: TrustAdversarialClock
    let service: TrustAuthorizationFixtureService

    init() {
        let context = TrustFixtureContext(teammateID: TeammateID(UUID()), conversationID: ConversationID(UUID()))
        let clock = TrustAdversarialClock(Date(timeIntervalSince1970: 1_780_000_000))
        self.context = context
        self.clock = clock
        service = TrustAuthorizationFixtureService(context: context, clock: clock, reviewLifetime: 60)
    }
}

private final class TrustAdversarialClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

private func preparedArtifact(_ h: TrustAdversarialHarness) async throws -> FixtureApprovalReview {
    _ = try await h.service.setMacOSPermission(context: h.context, value: .granted)
    let grant = try await h.service.prepareGrant(context: h.context, capability: .createCompletedArtifact)
    _ = try await h.service.confirmGrant(context: h.context, review: grant)
    return try await h.service.prepareApproval(context: h.context, proposal: .sampleArtifact)
}

private func changedTeammate(_ context: TrustFixtureContext) -> TrustFixtureContext {
    TrustFixtureContext(teammateID: TeammateID(UUID()), conversationID: context.conversationID)
}

private func changedConversation(_ context: TrustFixtureContext) -> TrustFixtureContext {
    TrustFixtureContext(teammateID: context.teammateID, conversationID: ConversationID(UUID()))
}

private func replacingGrant(
    _ value: FixtureGrantReview, id: UUID? = nil, context: TrustFixtureContext? = nil,
    capability: FixtureCapability? = nil, scopeSummary: String? = nil, effectSummary: String? = nil,
    generation: UInt64? = nil, createdAt: Date? = nil, expiresAt: Date? = nil, fingerprint: String? = nil
) -> FixtureGrantReview {
    FixtureGrantReview(
        id: id ?? value.id, context: context ?? value.context, capability: capability ?? value.capability,
        scopeSummary: scopeSummary ?? value.scopeSummary, effectSummary: effectSummary ?? value.effectSummary,
        generation: generation ?? value.generation, createdAt: createdAt ?? value.createdAt,
        expiresAt: expiresAt ?? value.expiresAt, fingerprint: fingerprint ?? value.fingerprint
    )
}

private func replacingApproval(
    _ value: FixtureApprovalReview, id: ApprovalID? = nil, context: TrustFixtureContext? = nil,
    proposal: FixtureActionProposal? = nil, grantID: CapabilityGrantID? = nil, grantGeneration: UInt64? = nil,
    scopeSummary: String? = nil, effectSummary: String? = nil,
    createdAt: Date? = nil, expiresAt: Date? = nil, fingerprint: String? = nil
) -> FixtureApprovalReview {
    FixtureApprovalReview(
        id: id ?? value.id, context: context ?? value.context, proposal: proposal ?? value.proposal,
        grantID: grantID ?? value.grantID, grantGeneration: grantGeneration ?? value.grantGeneration,
        scopeSummary: scopeSummary ?? value.scopeSummary, effectSummary: effectSummary ?? value.effectSummary,
        createdAt: createdAt ?? value.createdAt, expiresAt: expiresAt ?? value.expiresAt,
        fingerprint: fingerprint ?? value.fingerprint
    )
}
