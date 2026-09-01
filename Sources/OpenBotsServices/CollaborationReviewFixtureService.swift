import Foundation
import OpenBotsDomain

public enum CollaborationReviewFixtureVariant: String, CaseIterable, Sendable {
    case successfulFanIn
    case needsRecovery
}

public struct CollaborationReviewParticipant: Equatable, Sendable {
    public let id: TeammateID
    public let name: String
    public let role: String

    public init(id: TeammateID, name: String, role: String) throws {
        self.id = id
        self.name = try fixtureText(name, field: "fixture participant name", maximum: 120)
        self.role = try fixtureText(role, field: "fixture participant role", maximum: 240)
    }
}

/// A deliberately synthetic excerpt. It is never parsed, read from, or written
/// to a Markdown path and is returned only when its scope is included.
public struct CollaborationMemoryExcerpt: Equatable, Sendable, Identifiable {
    public let id: MemoryDocumentID
    public let scope: MemoryScope
    public let title: String
    public let syntheticExcerpt: String

    public init(
        id: MemoryDocumentID,
        scope: MemoryScope,
        title: String,
        syntheticExcerpt: String
    ) throws {
        self.id = id
        self.scope = scope
        self.title = try fixtureText(title, field: "fixture memory title", maximum: 200)
        self.syntheticExcerpt = try fixtureText(
            syntheticExcerpt,
            field: "fixture memory excerpt",
            maximum: 2_000
        )
    }
}

public struct CollaborationMemoryContextSnapshot: Equatable, Sendable {
    public let request: MemoryContextRequest
    public let includedExcerpts: [CollaborationMemoryExcerpt]
    public let exclusionCounts: [MemoryContextExclusionReason: Int]

    public init(
        request: MemoryContextRequest,
        includedExcerpts: [CollaborationMemoryExcerpt],
        exclusionCounts: [MemoryContextExclusionReason: Int]
    ) {
        self.request = request
        self.includedExcerpts = includedExcerpts
        self.exclusionCounts = exclusionCounts
    }
}

public struct CollaborationReviewTimelineEntry: Equatable, Sendable, Identifiable {
    public var id: Int { ordinal }

    public let ordinal: Int
    public let actorID: TeammateID
    public let state: HandoffState
    public let timestamp: Date
    public let summary: String

    public init(
        ordinal: Int,
        actorID: TeammateID,
        state: HandoffState,
        timestamp: Date,
        summary: String
    ) throws {
        guard ordinal >= 0 else {
            throw DomainValidationError.invalid(
                field: "fixture timeline ordinal",
                reason: "cannot be negative"
            )
        }
        self.ordinal = ordinal
        self.actorID = actorID
        self.state = state
        self.timestamp = timestamp
        self.summary = try fixtureText(
            summary,
            field: "fixture timeline summary",
            maximum: 1_000
        )
    }
}

public struct CollaborationReviewSnapshot: Equatable, Sendable {
    public let variant: CollaborationReviewFixtureVariant
    public let project: Project
    public let team: Team
    public let participants: [CollaborationReviewParticipant]
    public let memoryContext: CollaborationMemoryContextSnapshot
    public let handoff: Handoff
    public let timeline: [CollaborationReviewTimelineEntry]

    public init(
        variant: CollaborationReviewFixtureVariant,
        project: Project,
        team: Team,
        participants: [CollaborationReviewParticipant],
        memoryContext: CollaborationMemoryContextSnapshot,
        handoff: Handoff,
        timeline: [CollaborationReviewTimelineEntry]
    ) {
        self.variant = variant
        self.project = project
        self.team = team
        self.participants = participants
        self.memoryContext = memoryContext
        self.handoff = handoff
        self.timeline = timeline
    }
}

/// Builds two deterministic, process-local collaboration review states. It has
/// no repository, URL, filesystem, runtime, network, Keychain, connector, or
/// authorization dependency and never claims that a teammate actually ran.
public struct CollaborationReviewFixtureService: Sendable {
    public static let disclosure =
        "Collaboration review fixture — these synthetic memory excerpts and handoff states are process-local. This fixture did not read or write authoritative Markdown, run a teammate, or use hidden files, network, Keychain, connectors, or Claude. The separate Knowledge section uses the decision-0009A app-owned Markdown authority."

    private let selector = MemoryContextSelectionService()
    private let participants: [CollaborationReviewParticipant]
    private let project: Project
    private let team: Team
    private let memoryRequest: MemoryContextRequest
    private let memoryExcerpts: [CollaborationMemoryExcerpt]
    private let provenance: HandoffProvenance
    private let brief: HandoffBrief

    public init() throws {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let miraID = TeammateID(fixtureUUID(1))
        let adaID = TeammateID(fixtureUUID(2))
        let projectID = ProjectID(fixtureUUID(3))
        let otherProjectID = ProjectID(fixtureUUID(4))

        participants = [
            try CollaborationReviewParticipant(
                id: miraID,
                name: "Mira",
                role: "Research lead"
            ),
            try CollaborationReviewParticipant(
                id: adaID,
                name: "Ada",
                role: "Source verifier"
            )
        ]
        project = try Project(
            id: projectID,
            name: "Atlas",
            summary: "A local product-research project fixture.",
            createdAt: base,
            updatedAt: base
        )
        team = try Team(
            id: TeamID(fixtureUUID(5)),
            name: "Research Studio",
            summary: "Two persistent teammate identities in a local fixture.",
            leadID: miraID,
            memberIDs: [miraID, adaID],
            createdAt: base,
            updatedAt: base
        )
        memoryRequest = MemoryContextRequest(
            teammateID: miraID,
            selectedProjectID: projectID,
            activeProjectMemberships: [projectID]
        )
        memoryExcerpts = [
            try CollaborationMemoryExcerpt(
                id: MemoryDocumentID(fixtureUUID(10)),
                scope: .user,
                title: "Working preferences",
                syntheticExcerpt: "Lead with the useful outcome, then show the evidence."
            ),
            try CollaborationMemoryExcerpt(
                id: MemoryDocumentID(fixtureUUID(11)),
                scope: .teammate(miraID),
                title: "Mira's private working note",
                syntheticExcerpt: "Verify primary sources before drafting a recommendation."
            ),
            try CollaborationMemoryExcerpt(
                id: MemoryDocumentID(fixtureUUID(12)),
                scope: .teammate(adaID),
                title: "Ada excluded sentinel title",
                syntheticExcerpt: "ADA-PRIVATE-EXCLUDED-SENTINEL"
            ),
            try CollaborationMemoryExcerpt(
                id: MemoryDocumentID(fixtureUUID(13)),
                scope: .project(projectID),
                title: "Atlas project brief",
                syntheticExcerpt: "Compare evidence, retain provenance, and surface uncertainty."
            ),
            try CollaborationMemoryExcerpt(
                id: MemoryDocumentID(fixtureUUID(14)),
                scope: .project(otherProjectID),
                title: "Other project excluded sentinel title",
                syntheticExcerpt: "OTHER-PROJECT-EXCLUDED-SENTINEL"
            )
        ]
        provenance = try HandoffProvenance(
            handoffID: HandoffID(fixtureUUID(20)),
            legID: HandoffLegID(fixtureUUID(21)),
            originConversationID: ConversationID(fixtureUUID(22)),
            senderID: miraID,
            receiverID: adaID,
            createdAt: base.addingTimeInterval(60)
        )
        brief = try HandoffBrief(
            goal: "Verify the three source claims in the Atlas draft.",
            constraints: ["Use the supplied synthetic fixture references only."],
            inputReferences: ["Atlas draft revision 3", "Source checklist"],
            requestedOutput: "A compact verification result with uncertainties.",
            exclusions: ["Do not publish or contact anyone."],
            stopOrApprovalBoundary: "Stop and return needs-attention if a source cannot be verified."
        )
    }

    public func snapshot(
        variant: CollaborationReviewFixtureVariant
    ) throws -> CollaborationReviewSnapshot {
        let manifest = try selector.manifest(
            candidates: memoryExcerpts.map {
                MemoryContextCandidate(documentID: $0.id, scope: $0.scope)
            },
            request: memoryRequest
        )
        let excerptsByID = Dictionary(uniqueKeysWithValues: memoryExcerpts.map { ($0.id, $0) })
        let includedExcerpts = manifest.includedDocumentIDs.compactMap { excerptsByID[$0] }
        let memoryContext = CollaborationMemoryContextSnapshot(
            request: memoryRequest,
            includedExcerpts: includedExcerpts,
            exclusionCounts: manifest.exclusionCounts
        )

        var handoff = Handoff(provenance: provenance, brief: brief)
        var timeline = [
            try timelineEntry(
                ordinal: 0,
                actorID: provenance.senderID,
                state: .staged,
                offset: 0,
                summary: "Mira prepared a simulated handoff for Ada. No work was sent."
            )
        ]

        try handoff.apply(.accept(at: provenance.createdAt.addingTimeInterval(10)))
        timeline.append(
            try timelineEntry(
                ordinal: 1,
                actorID: provenance.receiverID,
                state: .accepted,
                offset: 10,
                summary: "Ada accepted the local fixture leg. No teammate ran."
            )
        )
        try handoff.apply(.beginWork(at: provenance.createdAt.addingTimeInterval(20)))
        timeline.append(
            try timelineEntry(
                ordinal: 2,
                actorID: provenance.receiverID,
                state: .working,
                offset: 20,
                summary: "The fixture displays Ada as working without launching a runtime."
            )
        )

        switch variant {
        case .successfulFanIn:
            try handoff.apply(
                .succeed(
                    summary: "Three claims checked; two supported and one marked uncertain.",
                    at: provenance.createdAt.addingTimeInterval(40)
                )
            )
            timeline.append(
                try timelineEntry(
                    ordinal: 3,
                    actorID: provenance.receiverID,
                    state: .succeeded,
                    offset: 40,
                    summary: "Ada produced a compact synthetic result reference."
                )
            )
            try handoff.apply(
                .returnToOrigin(at: provenance.createdAt.addingTimeInterval(50))
            )
            timeline.append(
                try timelineEntry(
                    ordinal: 4,
                    actorID: provenance.senderID,
                    state: .returnedToOrigin,
                    offset: 50,
                    summary: "Mira received the compact result reference; no hidden transcript moved."
                )
            )

        case .needsRecovery:
            let recovery = try HandoffRecovery(
                code: "fixture-source-unavailable",
                userMessage: "One synthetic source is unavailable. No automatic retry occurred.",
                isRecoverable: true,
                occurredAt: provenance.createdAt.addingTimeInterval(40)
            )
            try handoff.apply(.requireRecovery(recovery))
            timeline.append(
                try timelineEntry(
                    ordinal: 3,
                    actorID: provenance.receiverID,
                    state: .needsRecovery,
                    offset: 40,
                    summary: recovery.userMessage
                )
            )
        }

        return CollaborationReviewSnapshot(
            variant: variant,
            project: project,
            team: team,
            participants: participants,
            memoryContext: memoryContext,
            handoff: handoff,
            timeline: timeline
        )
    }

    private func timelineEntry(
        ordinal: Int,
        actorID: TeammateID,
        state: HandoffState,
        offset: TimeInterval,
        summary: String
    ) throws -> CollaborationReviewTimelineEntry {
        try CollaborationReviewTimelineEntry(
            ordinal: ordinal,
            actorID: actorID,
            state: state,
            timestamp: provenance.createdAt.addingTimeInterval(offset),
            summary: summary
        )
    }
}

private func fixtureText(_ value: String, field: String, maximum: Int) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw DomainValidationError.empty(field: field) }
    guard trimmed.count <= maximum else {
        throw DomainValidationError.tooLong(field: field, maximum: maximum)
    }
    return trimmed
}

private func fixtureUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a4000000-0000-0000-0000-%012llu", value))!
}
