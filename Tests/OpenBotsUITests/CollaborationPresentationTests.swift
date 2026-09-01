import Foundation
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@Test("Scoped memory presentation includes only fixture excerpts selected by the service")
func collaborationPresentationDoesNotLeakExcludedMemory() throws {
    let service = try CollaborationReviewFixtureService()
    let presentation = try CollaborationReviewPresentation(
        service.snapshot(variant: .successfulFanIn)
    )
    let rendered = presentation.memoryContext.accessibilityDescription

    #expect(presentation.memoryContext.includedExcerpts.count == 3)
    #expect(rendered.contains("Working preferences"))
    #expect(rendered.contains("Mira's private working note"))
    #expect(rendered.contains("Atlas project brief"))
    #expect(!rendered.contains("ADA-PRIVATE-EXCLUDED-SENTINEL"))
    #expect(!rendered.contains("OTHER-PROJECT-EXCLUDED-SENTINEL"))
    #expect(!rendered.contains("Ada excluded sentinel title"))
    #expect(rendered.contains("This handoff fixture did not read or write authoritative Markdown"))
    #expect(rendered.contains("separate Knowledge section"))
    #expect(presentation.memoryContext.exclusions.map(\.count).reduce(0, +) == 2)
}

@Test("Successful handoff presentation exposes provenance and explicit fan-in")
func successfulHandoffPresentationReturnsResultToOrigin() throws {
    let service = try CollaborationReviewFixtureService()
    let presentation = try CollaborationReviewPresentation(
        service.snapshot(variant: .successfulFanIn)
    )
    let handoff = presentation.handoff

    #expect(handoff.sender.name == "Mira")
    #expect(handoff.receiver.name == "Ada")
    #expect(handoff.state == .returnedToOrigin)
    #expect(handoff.timeline.map(\.state) == [
        .staged, .accepted, .working, .succeeded, .returnedToOrigin
    ])
    #expect(handoff.resultSummary?.contains("Three claims checked") == true)
    #expect(handoff.recoveryMessage == nil)
    #expect(handoff.accessibilityDescription.contains("Result returned"))
    #expect(handoff.accessibilityDescription.contains("no hidden transcript moved"))
    #expect(handoff.fixtureDisclosure == CollaborationReviewFixtureService.disclosure)
}

@Test("Recovery handoff remains visible without fabricating a result or retry")
func recoveryHandoffPresentationDoesNotFakeFanIn() throws {
    let service = try CollaborationReviewFixtureService()
    let presentation = try CollaborationReviewPresentation(
        service.snapshot(variant: .needsRecovery)
    )
    let handoff = presentation.handoff

    #expect(handoff.state == .needsRecovery)
    #expect(handoff.timeline.last?.state == .needsRecovery)
    #expect(handoff.recoveryMessage?.contains("No automatic retry occurred") == true)
    #expect(handoff.resultSummary == nil)
    #expect(!handoff.timeline.contains(where: { $0.state == .returnedToOrigin }))
    #expect(handoff.accessibilityDescription.contains("Needs attention"))
}

@Test("Typed handoff part contributes its full non-color accessibility description")
func typedHandoffPartIsAccessibleWithoutMotionOrColor() throws {
    let service = try CollaborationReviewFixtureService()
    let trail = try CollaborationReviewPresentation(
        service.snapshot(variant: .needsRecovery)
    ).handoff
    let part = ChatMessagePartContentSnapshot.handoff(trail)

    #expect(part.accessibilityDescription.contains("Local handoff fixture from Mira to Ada"))
    #expect(part.accessibilityDescription.contains("Needs attention"))
    #expect(part.accessibilityDescription.contains("Recovery:"))
    #expect(part.accessibilityDescription.contains("This fixture did not read or write authoritative Markdown"))
}
