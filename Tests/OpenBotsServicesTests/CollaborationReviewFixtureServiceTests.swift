import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Test("Successful fixture preserves A to B to A provenance and returns only a compact result")
func successfulCollaborationFixture() throws {
    let snapshot = try CollaborationReviewFixtureService().snapshot(
        variant: .successfulFanIn
    )

    #expect(snapshot.variant == .successfulFanIn)
    #expect(snapshot.project.name == "Atlas")
    #expect(snapshot.team.name == "Research Studio")
    #expect(snapshot.team.memberIDs == Set(snapshot.participants.map(\.id)))
    #expect(snapshot.handoff.provenance.senderID == snapshot.participants[0].id)
    #expect(snapshot.handoff.provenance.receiverID == snapshot.participants[1].id)
    #expect(snapshot.handoff.state == .returnedToOrigin)

    let receipt = try #require(snapshot.handoff.resultForOrigin)
    #expect(receipt.sourceTeammateID == snapshot.participants[1].id)
    #expect(receipt.originTeammateID == snapshot.participants[0].id)
    #expect(receipt.handoffID == snapshot.handoff.provenance.handoffID)
    #expect(receipt.legID == snapshot.handoff.provenance.legID)
    #expect(receipt.result.summary == "Three claims checked; two supported and one marked uncertain.")
    #expect(
        snapshot.timeline.map(\.state)
            == [.staged, .accepted, .working, .succeeded, .returnedToOrigin]
    )
    #expect(snapshot.timeline.map(\.ordinal) == Array(0...4))
    #expect(snapshot.timeline.map(\.timestamp) == snapshot.timeline.map(\.timestamp).sorted())
}

@Test("Recovery fixture has no fan-in and no automatic retry")
func recoveryCollaborationFixture() throws {
    let snapshot = try CollaborationReviewFixtureService().snapshot(
        variant: .needsRecovery
    )

    #expect(snapshot.handoff.state == .needsRecovery)
    #expect(snapshot.handoff.resultForOrigin == nil)
    let recovery = try #require(snapshot.handoff.recovery)
    #expect(recovery.isRecoverable)
    #expect(recovery.userMessage.contains("No automatic retry occurred"))
    #expect(snapshot.timeline.map(\.state) == [.staged, .accepted, .working, .needsRecovery])
    #expect(!snapshot.timeline.contains(where: { $0.state == .succeeded }))
    #expect(!snapshot.timeline.contains(where: { $0.state == .returnedToOrigin }))
}

@Test("Fixture output excludes every non-readable sentinel and is deterministic")
func collaborationFixtureIsScopedAndDeterministic() throws {
    let firstService = try CollaborationReviewFixtureService()
    let secondService = try CollaborationReviewFixtureService()
    let first = try firstService.snapshot(variant: .successfulFanIn)
    let second = try secondService.snapshot(variant: .successfulFanIn)

    #expect(first == second)
    #expect(first.memoryContext.includedExcerpts.count == 3)
    #expect(first.memoryContext.exclusionCounts[.otherTeammate] == 1)
    #expect(first.memoryContext.exclusionCounts[.differentProject] == 1)
    #expect(first.memoryContext.exclusionCounts.values.reduce(0, +) == 2)

    let visibleDescription = String(describing: first)
    #expect(!visibleDescription.contains("ADA-PRIVATE-EXCLUDED-SENTINEL"))
    #expect(!visibleDescription.contains("OTHER-PROJECT-EXCLUDED-SENTINEL"))
    #expect(!visibleDescription.contains("Ada excluded sentinel title"))
    #expect(!visibleDescription.contains("Other project excluded sentinel title"))
    #expect(visibleDescription.contains("Working preferences"))
    #expect(visibleDescription.contains("Atlas project brief"))
}

@Test("Fixture disclosure states every unavailable authority and side effect")
func collaborationFixtureDisclosureIsHonest() {
    let disclosure = CollaborationReviewFixtureService.disclosure
    for requiredPhrase in [
        "process-local",
        "did not read or write authoritative Markdown",
        "separate Knowledge section",
        "run a teammate",
        "hidden files",
        "network",
        "Keychain",
        "connectors",
        "Claude"
    ] {
        #expect(disclosure.contains(requiredPhrase))
    }
}
