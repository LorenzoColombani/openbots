import Foundation
import OpenBotsDomain
import OpenBotsServices

/// A project directory row resolved entirely through the injected Services
/// boundary. UI code never receives a repository or database handle.
public struct CollaborationProjectSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String?
    public let members: [TeammateIdentitySnapshot]

    public init(
        id: UUID,
        name: String,
        summary: String?,
        members: [TeammateIdentitySnapshot]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.members = members
    }

    public init(_ snapshot: ProjectDirectorySnapshot) {
        self.init(
            id: snapshot.project.id.rawValue,
            name: snapshot.project.name,
            summary: snapshot.project.summary,
            members: snapshot.members.map(TeammateIdentitySnapshot.init)
        )
    }
}

/// A team directory row with an explicit lead. Lead state is written and does
/// not depend on ordering, color, or a decorative badge.
public struct CollaborationTeamSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String?
    public let leadID: UUID
    public let members: [TeammateIdentitySnapshot]

    public init(
        id: UUID,
        name: String,
        summary: String?,
        leadID: UUID,
        members: [TeammateIdentitySnapshot]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.leadID = leadID
        self.members = members
    }

    public init(_ snapshot: TeamDirectorySnapshot) {
        self.init(
            id: snapshot.team.id.rawValue,
            name: snapshot.team.name,
            summary: snapshot.team.summary,
            leadID: snapshot.team.leadID.rawValue,
            members: snapshot.members.map(TeammateIdentitySnapshot.init)
        )
    }
}

public enum CollaborationCreationKind: String, Equatable, Sendable {
    case project
    case team

    public var visibleName: String {
        switch self {
        case .project: "Project"
        case .team: "Team"
        }
    }
}

public enum CollaborationWorkspaceLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(reason: String)
}

public enum CollaborationFixturePresentationError: Error, Equatable, Sendable {
    case missingParticipant(UUID)
}

public struct CollaborationMemoryExcerptSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let scopeLabel: String
    public let title: String
    public let syntheticExcerpt: String

    public init(
        id: UUID,
        scopeLabel: String,
        title: String,
        syntheticExcerpt: String
    ) {
        self.id = id
        self.scopeLabel = scopeLabel
        self.title = title
        self.syntheticExcerpt = syntheticExcerpt
    }
}

public struct CollaborationMemoryExclusionSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { reason }
    public let reason: String
    public let count: Int

    public init(reason: String, count: Int) {
        self.reason = reason
        self.count = count
    }
}

public struct CollaborationMemoryContextPresentation: Equatable, Sendable {
    public let teammateName: String
    public let projectName: String?
    public let includedExcerpts: [CollaborationMemoryExcerptSnapshot]
    public let exclusions: [CollaborationMemoryExclusionSnapshot]

    public var accessibilityDescription: String {
        let context = projectName.map { "Project: \($0)." } ?? "No project selected."
        let included = includedExcerpts.map {
            "\($0.scopeLabel), \($0.title), synthetic excerpt: \($0.syntheticExcerpt)"
        }.joined(separator: ". ")
        let excluded = exclusions.map { "\($0.count) \($0.reason)" }
            .joined(separator: ", ")
        return "Synthetic scoped memory fixture for \(teammateName). \(context) "
            + "Included: \(included). Excluded counts: \(excluded). "
            + "This handoff fixture did not read or write authoritative Markdown. "
            + "The separate Knowledge section uses the app-owned Markdown authority."
    }
}

public enum ChatHandoffStateSnapshot: String, CaseIterable, Equatable, Sendable {
    case staged
    case accepted
    case working
    case succeeded
    case returnedToOrigin
    case needsRecovery

    public var visibleLabel: String {
        switch self {
        case .staged: "Staged"
        case .accepted: "Accepted"
        case .working: "Working fixture"
        case .succeeded: "Result prepared"
        case .returnedToOrigin: "Returned to sender"
        case .needsRecovery: "Needs attention"
        }
    }

    public var symbolName: String {
        switch self {
        case .staged: "doc.badge.arrow.up"
        case .accepted: "checkmark.circle"
        case .working: "hammer"
        case .succeeded: "checkmark.seal"
        case .returnedToOrigin: "arrow.uturn.backward.circle"
        case .needsRecovery: "exclamationmark.triangle"
        }
    }

    init(_ state: HandoffState) {
        switch state {
        case .staged: self = .staged
        case .accepted: self = .accepted
        case .working: self = .working
        case .succeeded: self = .succeeded
        case .returnedToOrigin: self = .returnedToOrigin
        case .needsRecovery: self = .needsRecovery
        }
    }
}

public struct ChatHandoffTimelineEntrySnapshot: Identifiable, Equatable, Sendable {
    public let id: Int
    public let actor: TeammateIdentitySnapshot
    public let state: ChatHandoffStateSnapshot
    public let timestamp: Date
    public let summary: String

    public init(
        id: Int,
        actor: TeammateIdentitySnapshot,
        state: ChatHandoffStateSnapshot,
        timestamp: Date,
        summary: String
    ) {
        self.id = id
        self.actor = actor
        self.state = state
        self.timestamp = timestamp
        self.summary = summary
    }
}

/// Complete, display-only handoff provenance. It contains no runtime events,
/// hidden transcript, prompt, file path, or reasoning payload.
public struct ChatHandoffTrailSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sender: TeammateIdentitySnapshot
    public let receiver: TeammateIdentitySnapshot
    public let goal: String
    public let requestedOutput: String
    public let stopOrApprovalBoundary: String
    public let state: ChatHandoffStateSnapshot
    public let timeline: [ChatHandoffTimelineEntrySnapshot]
    public let recoveryMessage: String?
    public let resultSummary: String?
    public let fixtureDisclosure: String

    public var accessibilityDescription: String {
        let events = timeline.map {
            "\($0.actor.name), \($0.state.visibleLabel): \($0.summary)"
        }.joined(separator: ". ")
        let recovery = recoveryMessage.map { " Recovery: \($0)." } ?? ""
        let result = resultSummary.map { " Result returned: \($0)." } ?? ""
        return "Local handoff fixture from \(sender.name) to \(receiver.name). "
            + "State: \(state.visibleLabel). Goal: \(goal). \(events)."
            + recovery + result + " \(fixtureDisclosure)"
    }

    public init(
        id: UUID,
        sender: TeammateIdentitySnapshot,
        receiver: TeammateIdentitySnapshot,
        goal: String,
        requestedOutput: String,
        stopOrApprovalBoundary: String,
        state: ChatHandoffStateSnapshot,
        timeline: [ChatHandoffTimelineEntrySnapshot],
        recoveryMessage: String?,
        resultSummary: String?,
        fixtureDisclosure: String
    ) {
        self.id = id
        self.sender = sender
        self.receiver = receiver
        self.goal = goal
        self.requestedOutput = requestedOutput
        self.stopOrApprovalBoundary = stopOrApprovalBoundary
        self.state = state
        self.timeline = timeline
        self.recoveryMessage = recoveryMessage
        self.resultSummary = resultSummary
        self.fixtureDisclosure = fixtureDisclosure
    }
}

public struct CollaborationReviewPresentation: Equatable, Sendable {
    public let variant: CollaborationReviewFixtureVariant
    public let fixtureProjectName: String
    public let fixtureTeamName: String
    public let memoryContext: CollaborationMemoryContextPresentation
    public let handoff: ChatHandoffTrailSnapshot

    public init(_ snapshot: CollaborationReviewSnapshot) throws {
        let participants = Dictionary(
            uniqueKeysWithValues: snapshot.participants.map { participant in
                (
                    participant.id.rawValue,
                    TeammateIdentitySnapshot(
                        id: participant.id.rawValue,
                        name: participant.name,
                        role: participant.role,
                        appearance: .fixture(
                            seed: Self.appearanceSeed(participant.id.rawValue)
                        )
                    )
                )
            }
        )
        let senderID = snapshot.handoff.provenance.senderID.rawValue
        let receiverID = snapshot.handoff.provenance.receiverID.rawValue
        guard let sender = participants[senderID] else {
            throw CollaborationFixturePresentationError.missingParticipant(senderID)
        }
        guard let receiver = participants[receiverID] else {
            throw CollaborationFixturePresentationError.missingParticipant(receiverID)
        }
        guard let contextTeammate = participants[snapshot.memoryContext.request.teammateID.rawValue]
        else {
            throw CollaborationFixturePresentationError.missingParticipant(
                snapshot.memoryContext.request.teammateID.rawValue
            )
        }

        variant = snapshot.variant
        fixtureProjectName = snapshot.project.name
        fixtureTeamName = snapshot.team.name

        let memoryExcerpts = snapshot.memoryContext.includedExcerpts.map { excerpt in
            CollaborationMemoryExcerptSnapshot(
                id: excerpt.id.rawValue,
                scopeLabel: Self.scopeLabel(
                    excerpt.scope,
                    participants: participants,
                    project: snapshot.project
                ),
                title: excerpt.title,
                syntheticExcerpt: excerpt.syntheticExcerpt
            )
        }
        let exclusions = snapshot.memoryContext.exclusionCounts
            .map { reason, count in
                CollaborationMemoryExclusionSnapshot(
                    reason: Self.exclusionLabel(reason),
                    count: count
                )
            }
            .sorted { $0.reason < $1.reason }
        memoryContext = CollaborationMemoryContextPresentation(
            teammateName: contextTeammate.name,
            projectName: snapshot.memoryContext.request.selectedProjectID == snapshot.project.id
                ? snapshot.project.name
                : nil,
            includedExcerpts: memoryExcerpts,
            exclusions: exclusions
        )

        let timeline = try snapshot.timeline.map { event in
            guard let actor = participants[event.actorID.rawValue] else {
                throw CollaborationFixturePresentationError.missingParticipant(
                    event.actorID.rawValue
                )
            }
            return ChatHandoffTimelineEntrySnapshot(
                id: event.ordinal,
                actor: actor,
                state: ChatHandoffStateSnapshot(event.state),
                timestamp: event.timestamp,
                summary: event.summary
            )
        }
        handoff = ChatHandoffTrailSnapshot(
            id: snapshot.handoff.provenance.handoffID.rawValue,
            sender: sender,
            receiver: receiver,
            goal: snapshot.handoff.brief.goal,
            requestedOutput: snapshot.handoff.brief.requestedOutput,
            stopOrApprovalBoundary: snapshot.handoff.brief.stopOrApprovalBoundary,
            state: ChatHandoffStateSnapshot(snapshot.handoff.state),
            timeline: timeline,
            recoveryMessage: snapshot.handoff.recovery?.userMessage,
            resultSummary: snapshot.handoff.resultForOrigin?.result.summary,
            fixtureDisclosure: CollaborationReviewFixtureService.disclosure
        )
    }

    private static func scopeLabel(
        _ scope: MemoryScope,
        participants: [UUID: TeammateIdentitySnapshot],
        project: Project
    ) -> String {
        switch scope {
        case .user:
            "User memory"
        case .teammate(let teammateID):
            "Teammate memory — \(participants[teammateID.rawValue]?.name ?? "Unknown teammate")"
        case .project(let projectID):
            projectID == project.id
                ? "Project memory — \(project.name)"
                : "Other project memory"
        }
    }

    private static func exclusionLabel(_ reason: MemoryContextExclusionReason) -> String {
        switch reason {
        case .otherTeammate: "other-teammate documents withheld"
        case .noSelectedProject: "project documents withheld because no project is selected"
        case .differentProject: "other-project documents withheld"
        case .inactiveMembership: "project documents withheld because membership is inactive"
        }
    }

    private static func appearanceSeed(_ id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
