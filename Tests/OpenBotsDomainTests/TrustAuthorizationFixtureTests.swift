import Foundation
import OpenBotsDomain
import Testing

@Test("Trust fixture has a closed preview capability vocabulary and no shell")
func trustFixtureClosedCapabilities() {
    #expect(FixtureCapability.allCases == [.readReferenceFolder, .createCompletedArtifact, .connectorUse])
    #expect(FixtureCapability(rawValue: "shell") == nil)
    for capability in FixtureCapability.allCases {
        #expect(!capability.scopeSummary.isEmpty)
        #expect(capability.effectSummary.contains("Nothing is executed"))
    }
}

@Test("Trust reviews retain exact context, payload and fingerprints through encoding")
func trustFixtureReviewValueRoundTrip() throws {
    let context = TrustFixtureContext(teammateID: TeammateID(UUID()), conversationID: ConversationID(UUID()))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let grant = FixtureGrantReview(
        id: UUID(), context: context, capability: .readReferenceFolder,
        scopeSummary: "Demo references", effectSummary: "Read only",
        generation: 3, createdAt: now, expiresAt: now.addingTimeInterval(300),
        fingerprint: String(repeating: "a", count: 64)
    )
    #expect(try JSONDecoder().decode(FixtureGrantReview.self, from: JSONEncoder().encode(grant)) == grant)
    let approval = FixtureApprovalReview(
        id: ApprovalID(UUID()), context: context, proposal: .sampleArtifact,
        grantID: CapabilityGrantID(UUID()), grantGeneration: 4,
        scopeSummary: "Demo destination", effectSummary: "Create new only",
        createdAt: now, expiresAt: now.addingTimeInterval(300),
        fingerprint: String(repeating: "b", count: 64)
    )
    #expect(try JSONDecoder().decode(FixtureApprovalReview.self, from: JSONEncoder().encode(approval)) == approval)
    #expect(context != TrustFixtureContext(teammateID: context.teammateID, conversationID: ConversationID(UUID())))
}

@Test("Every simulated OS state except granted blocks fixture eligibility")
func trustFixturePermissionEligibility() {
    let context = TrustFixtureContext(teammateID: TeammateID(UUID()), conversationID: ConversationID(UUID()))
    let grant = FixtureCapabilityGrant(
        id: CapabilityGrantID(UUID()), context: context, capability: .readReferenceFolder,
        scopeSummary: FixtureCapability.readReferenceFolder.scopeSummary,
        generation: 0, status: .active, grantedAt: .distantPast
    )
    for state in FixtureMacOSPermission.allCases {
        let snapshot = TrustFixtureSnapshot(
            context: context, macOSPermission: state,
            connector: .init(installation: .notInstalled, accountAuthentication: .notAuthenticated,
                             perBotGrant: .notGranted, perActionApproval: .notRequested),
            grants: [grant], grantReviews: [], approvals: [], evidence: []
        )
        #expect((snapshot.eligibilityBlocker(for: .readReferenceFolder) == nil) == (state == .granted))
        #expect(snapshot.eligibilityBlocker(for: .createCompletedArtifact) != nil)
        #expect(snapshot.activeGrant(for: .connectorUse) == nil)
    }
}

@Test("Demo action values describe exact target and consequences without real effects")
func trustFixtureProposalDescriptions() {
    let artifact = FixtureActionProposal.sampleArtifact
    #expect(artifact.targetSummary.contains("research-summary.pdf"))
    #expect(artifact.effectSummary.contains("never replaced"))
    #expect(artifact.effectSummary.contains("macOS"))
    #expect(artifact.effectSummary.contains("writes nothing"))
    let send = FixtureActionProposal.sampleConnectorSend
    #expect(send.targetSummary.contains("@example.invalid"))
    #expect(send.effectSummary.contains("sends nothing"))
    let destructive = FixtureActionProposal.unsupportedMutation(
        operation: .delete, targetSummary: "Untrusted provider root", recursive: true
    )
    #expect(destructive.capability == nil)
    #expect(destructive.payloadSummary.contains("unavailable"))
}
