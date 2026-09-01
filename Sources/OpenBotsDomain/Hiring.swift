import Foundation

public enum HiringDraftPhase: String, Codable, Equatable, Sendable {
    case collecting
    case readyForReview
}

/// A provisional candidate assembled through the hiring conversation.
///
/// The draft has its own short-lived identity. Confirmation creates a separate
/// `TeammateID`; callers must never derive teammate authority from this value.
public struct HiringDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: HiringDraftID
    public let phase: HiringDraftPhase
    public let displayName: String?
    public let role: String?
    public let responsibilities: String?
    public let workingStyle: String?
    public let skills: String?
    public let permissionIntent: String?
    public let projectPlacement: String?
    public let teamPlacement: String?
    public let revision: UInt64
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: HiringDraftID,
        phase: HiringDraftPhase = .collecting,
        displayName: String? = nil,
        role: String? = nil,
        responsibilities: String? = nil,
        workingStyle: String? = nil,
        skills: String? = nil,
        permissionIntent: String? = nil,
        projectPlacement: String? = nil,
        teamPlacement: String? = nil,
        revision: UInt64 = 1,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard revision > 0 else {
            throw DomainValidationError.invalid(field: "hiring draft revision", reason: "must be positive")
        }
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(
                field: "hiring draft timestamps",
                reason: "updatedAt cannot precede createdAt"
            )
        }

        let checkedDisplayName = try DomainText.optional(
            displayName,
            field: "candidate name",
            maximum: 80
        )
        let checkedRole = try DomainText.optional(role, field: "candidate role", maximum: 240)
        if phase == .readyForReview {
            guard checkedDisplayName != nil else {
                throw DomainValidationError.empty(field: "candidate name")
            }
            guard checkedRole != nil else {
                throw DomainValidationError.empty(field: "candidate role")
            }
        }

        self.id = id
        self.phase = phase
        self.displayName = checkedDisplayName
        self.role = checkedRole
        self.responsibilities = try DomainText.optional(
            responsibilities,
            field: "candidate responsibilities",
            maximum: 4_000
        )
        self.workingStyle = try DomainText.optional(
            workingStyle,
            field: "candidate working style",
            maximum: 2_000
        )
        self.skills = try DomainText.optional(skills, field: "candidate skills", maximum: 4_000)
        self.permissionIntent = try DomainText.optional(
            permissionIntent,
            field: "candidate permission intent",
            maximum: 4_000
        )
        self.projectPlacement = try DomainText.optional(
            projectPlacement,
            field: "candidate project placement",
            maximum: 240
        )
        self.teamPlacement = try DomainText.optional(
            teamPlacement,
            field: "candidate team placement",
            maximum: 240
        )
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Produces the next optimistic revision while preserving unspecified
    /// values. Passing `.some(nil)` explicitly clears an optional field.
    public func revised(
        phase: HiringDraftPhase? = nil,
        displayName: String?? = nil,
        role: String?? = nil,
        responsibilities: String?? = nil,
        workingStyle: String?? = nil,
        skills: String?? = nil,
        permissionIntent: String?? = nil,
        projectPlacement: String?? = nil,
        teamPlacement: String?? = nil,
        updatedAt: Date
    ) throws -> Self {
        guard revision < UInt64.max else {
            throw DomainValidationError.invalid(
                field: "hiring draft revision",
                reason: "cannot advance further"
            )
        }
        guard updatedAt >= self.updatedAt else {
            throw DomainValidationError.invalid(
                field: "hiring draft timestamps",
                reason: "a revision cannot move updatedAt backwards"
            )
        }
        return try Self(
            id: id,
            phase: phase ?? self.phase,
            displayName: displayName ?? self.displayName,
            role: role ?? self.role,
            responsibilities: responsibilities ?? self.responsibilities,
            workingStyle: workingStyle ?? self.workingStyle,
            skills: skills ?? self.skills,
            permissionIntent: permissionIntent ?? self.permissionIntent,
            projectPlacement: projectPlacement ?? self.projectPlacement,
            teamPlacement: teamPlacement ?? self.teamPlacement,
            revision: revision + 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum HiringTurnAuthor: String, Codable, Equatable, Sendable {
    case user
    case guide
}

public struct HiringTurn: Codable, Equatable, Sendable, Identifiable {
    public static let maximumTextLength = 12_000

    public let id: HiringTurnID
    public let draftID: HiringDraftID
    public let sequence: Int64
    public let author: HiringTurnAuthor
    public let text: String
    public let createdAt: Date

    public init(
        id: HiringTurnID,
        draftID: HiringDraftID,
        sequence: Int64,
        author: HiringTurnAuthor,
        text: String,
        createdAt: Date
    ) throws {
        guard sequence > 0 else {
            throw DomainValidationError.invalid(field: "hiring turn sequence", reason: "must be positive")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.empty(field: "hiring turn text")
        }
        guard text.count <= Self.maximumTextLength else {
            throw DomainValidationError.tooLong(
                field: "hiring turn text",
                maximum: Self.maximumTextLength
            )
        }
        self.id = id
        self.draftID = draftID
        self.sequence = sequence
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

public struct HiringDraftSnapshot: Codable, Equatable, Sendable {
    public let draft: HiringDraft
    public let turns: [HiringTurn]

    public init(draft: HiringDraft, turns: [HiringTurn]) throws {
        var expectedSequence: Int64 = 1
        var seenIDs = Set<HiringTurnID>()
        for turn in turns {
            guard turn.draftID == draft.id else {
                throw DomainValidationError.invalid(
                    field: "hiring turns",
                    reason: "every turn must belong to the draft"
                )
            }
            guard turn.sequence == expectedSequence else {
                throw DomainValidationError.invalid(
                    field: "hiring turns",
                    reason: "sequences must be contiguous and ordered from one"
                )
            }
            guard seenIDs.insert(turn.id).inserted else {
                throw DomainValidationError.invalid(
                    field: "hiring turns",
                    reason: "turn identities must be unique"
                )
            }
            guard turn.createdAt >= draft.createdAt, turn.createdAt <= draft.updatedAt else {
                throw DomainValidationError.invalid(
                    field: "hiring turn timestamps",
                    reason: "turns must fall within the draft lifetime"
                )
            }
            expectedSequence += 1
        }
        self.draft = draft
        self.turns = turns
    }
}
