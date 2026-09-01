import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing

private struct TrustServiceFixedClock: OpenBotsClock {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { date }
}

private func trustServiceContext() -> TrustFixtureContext {
    TrustFixtureContext(teammateID: TeammateID(UUID()), conversationID: ConversationID(UUID()))
}

@Test("New trust service has no grants, account or OS authorization")
func trustServiceStartsUntrusted() async throws {
    let context = trustServiceContext()
    let service = TrustAuthorizationFixtureService(context: context)
    let snapshot = try await service.snapshot(context: context)
    #expect(snapshot.context == context)
    #expect(snapshot.grants.isEmpty)
    #expect(snapshot.approvals.isEmpty)
    #expect(snapshot.grantReviews.isEmpty)
    #expect(snapshot.macOSPermission == .notDetermined)
    #expect(snapshot.connector.installation == .notInstalled)
    #expect(snapshot.connector.accountAuthentication == .notAuthenticated)
    #expect(snapshot.connector.perBotGrant == .notGranted)
    #expect(snapshot.connector.perActionApproval == .notRequested)
    #expect(TrustAuthorizationFixtureService.disclosure.contains("Nothing is executed"))
}

@Test("Grant preparation requires confirmation and changes no other layer")
func trustServiceGrantReviewAndDecline() async throws {
    let context = trustServiceContext()
    let service = TrustAuthorizationFixtureService(context: context, clock: TrustServiceFixedClock())
    let review = try await service.prepareGrant(context: context, capability: .readReferenceFolder)
    #expect(review.fingerprint.count == 64)
    #expect(review.expiresAt.timeIntervalSince(review.createdAt) == 300)
    let prepared = try await service.snapshot(context: context)
    #expect(prepared.grants.isEmpty)
    #expect(prepared.grantReviews.first?.state == .pending)
    let declined = try await service.declineGrant(context: context, review: review)
    #expect(declined.grants.isEmpty)
    #expect(declined.grantReviews.first?.state == .declined)
    await #expect(throws: TrustFixtureError.alreadyResolved) {
        try await service.confirmGrant(context: context, review: review)
    }
    let next = try await service.prepareGrant(context: context, capability: .readReferenceFolder)
    let confirmed = try await service.confirmGrant(context: context, review: next)
    #expect(confirmed.activeGrant(for: .readReferenceFolder)?.scopeSummary == review.scopeSummary)
    #expect(confirmed.activeGrant(for: .createCompletedArtifact) == nil)
    #expect(confirmed.macOSPermission == .notDetermined)
    #expect(confirmed.connector == prepared.connector)
    await #expect(throws: TrustFixtureError.alreadyGranted) {
        try await service.prepareGrant(context: context, capability: .readReferenceFolder)
    }
}

@Test("Exact artifact approval is separately approved then consumed as simulation only")
func trustServiceArtifactHappyPath() async throws {
    let context = trustServiceContext()
    let service = TrustAuthorizationFixtureService(context: context, clock: TrustServiceFixedClock())
    let grant = try await service.prepareGrant(context: context, capability: .createCompletedArtifact)
    _ = try await service.confirmGrant(context: context, review: grant)
    _ = try await service.setMacOSPermission(context: context, value: .granted)
    let review = try await service.prepareApproval(context: context, proposal: .sampleArtifact)
    #expect(review.fingerprint.count == 64)
    #expect(review.proposal == .sampleArtifact)
    let pending = try await service.snapshot(context: context)
    #expect(pending.approvals.first?.state == .pending)
    let approved = try await service.resolveApproval(context: context, review: review, decision: .approve)
    #expect(approved.approvals.first?.state == .approved)
    let consumed = try await service.consumeApprovedPreview(context: context, review: review)
    #expect(consumed.approvals.first?.state == .simulated)
    #expect(consumed.evidence.last?.summary.contains("Nothing was executed, created or sent") == true)
    #expect(consumed.connector == pending.connector)
    #expect(consumed.grants == pending.grants)
    await #expect(throws: TrustFixtureError.alreadyConsumed) {
        try await service.consumeApprovedPreview(context: context, review: review)
    }
}

@Test("Connector setup axes precede one exact send approval without executing a send")
func trustServiceConnectorHappyPathAndDenial() async throws {
    let context = trustServiceContext()
    let service = TrustAuthorizationFixtureService(context: context)
    _ = try await service.setConnectorInstallation(context: context, value: .installed)
    _ = try await service.setConnectorAuthentication(context: context, value: .authenticated)
    _ = try await service.setMacOSPermission(context: context, value: .granted)
    let review = try await service.prepareGrant(context: context, capability: .connectorUse)
    let granted = try await service.confirmGrant(context: context, review: review)
    #expect(granted.connector.perBotGrant == .granted)
    #expect(granted.connector.perActionApproval == .notRequested)
    let action = try await service.prepareApproval(context: context, proposal: .sampleConnectorSend)
    let pending = try await service.snapshot(context: context)
    #expect(pending.connector.perActionApproval == .pending)
    let denied = try await service.resolveApproval(context: context, review: action, decision: .deny)
    #expect(denied.connector.perActionApproval == .denied)
    #expect(denied.connector.perBotGrant == .granted)
    await #expect(throws: TrustFixtureError.alreadyResolved) {
        try await service.consumeApprovedPreview(context: context, review: action)
    }
    let newAction = try await service.prepareApproval(context: context, proposal: .sampleConnectorSend)
    _ = try await service.resolveApproval(context: context, review: newAction, decision: .approve)
    let consumed = try await service.consumeApprovedPreview(context: context, review: newAction)
    #expect(consumed.approvals.last?.state == .simulated)
    #expect(consumed.connector.perActionApproval == .notRequested)
    #expect(consumed.connector.installation == .installed)
    #expect(consumed.connector.accountAuthentication == .authenticated)
}

@Test("Preview refuses ambiguous paths, glob-like targets, real recipients and oversized payloads")
func trustServiceRejectsUnboundedProposalInputs() async throws {
    let context = trustServiceContext()
    let service = TrustAuthorizationFixtureService(context: context)
    let values: [FixtureActionProposal] = [
        .completedArtifact(filename: "../report.pdf", contentSummary: "demo"),
        .completedArtifact(filename: "report*.pdf", contentSummary: "demo"),
        .completedArtifact(filename: "report.pdf", contentSummary: String(repeating: "x", count: 2_001)),
        .completedArtifact(filename: "report\u{0}.pdf", contentSummary: "demo"),
        .connectorSend(recipient: "somebody@example.com", message: "demo"),
        .connectorSend(recipient: "@example.invalid", message: "demo"),
        .connectorSend(recipient: "person@example.invalid", message: "")
    ]
    for value in values {
        await #expect(throws: TrustFixtureError.invalidInput) {
            try await service.prepareApproval(context: context, proposal: value)
        }
    }
    let snapshot = try await service.snapshot(context: context)
    #expect(snapshot.approvals.isEmpty)
}

@Test("Process-local review ledger and evidence trail have explicit bounds")
func trustServiceBoundedReviewHistory() async throws {
    let context = trustServiceContext()
    let service = TrustAuthorizationFixtureService(context: context)
    for _ in 0..<64 {
        let review = try await service.prepareGrant(context: context, capability: .readReferenceFolder)
        _ = try await service.declineGrant(context: context, review: review)
    }
    await #expect(throws: TrustFixtureError.capacityReached) {
        try await service.prepareGrant(context: context, capability: .readReferenceFolder)
    }
    let snapshot = try await service.snapshot(context: context)
    #expect(snapshot.grantReviews.count == 64)
    #expect(snapshot.evidence.count == 100)
    #expect(snapshot.evidence.first?.id == 29)
    #expect(snapshot.evidence.last?.id == 128)
}

@Test("Invalid fixture lifetime fails closed before producing a review")
func trustServiceInvalidLifetime() async throws {
    let context = trustServiceContext()
    for lifetime in [0.0, -1.0, .infinity, .nan, 3_601] {
        let service = TrustAuthorizationFixtureService(context: context, reviewLifetime: lifetime)
        await #expect(throws: TrustFixtureError.invalidInput) {
            try await service.prepareGrant(context: context, capability: .readReferenceFolder)
        }
    }
}
