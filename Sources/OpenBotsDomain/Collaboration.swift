import Foundation

public enum DurableEntityLifecycle: String, Codable, Sendable {
    case active
    case archived

    public func applying(_ event: DurableEntityLifecycleEvent, entity: String) throws -> Self {
        switch (self, event) {
        case (.active, .archive): .archived
        case (.archived, .restore): .active
        default:
            throw LifecycleTransitionError.illegalTransition(
                entity: entity,
                state: rawValue,
                event: event.rawValue
            )
        }
    }
}

public enum DurableEntityLifecycleEvent: String, Sendable {
    case archive
    case restore
}

public struct Project: Codable, Equatable, Sendable, Identifiable {
    public let id: ProjectID
    public var name: String
    public var summary: String?
    public var lifecycle: DurableEntityLifecycle
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ProjectID,
        name: String,
        summary: String? = nil,
        lifecycle: DurableEntityLifecycle = .active,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(field: "project timestamps", reason: "updatedAt cannot precede createdAt")
        }
        self.id = id
        self.name = try DomainText.required(name, field: "project name", maximum: 120)
        self.summary = try DomainText.optional(summary, field: "project summary", maximum: 2_000)
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectMembership: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let teammateID: TeammateID
    public let joinedAt: Date
    public let revokedAt: Date?

    public init(projectID: ProjectID, teammateID: TeammateID, joinedAt: Date, revokedAt: Date? = nil) throws {
        if let revokedAt, revokedAt < joinedAt {
            throw DomainValidationError.invalid(
                field: "project membership timestamps",
                reason: "revokedAt cannot precede joinedAt"
            )
        }
        self.projectID = projectID
        self.teammateID = teammateID
        self.joinedAt = joinedAt
        self.revokedAt = revokedAt
    }

    public var isActive: Bool { revokedAt == nil }
}

public struct Team: Codable, Equatable, Sendable, Identifiable {
    public let id: TeamID
    public var name: String
    public var summary: String?
    public var leadID: TeammateID
    public var memberIDs: Set<TeammateID>
    public var lifecycle: DurableEntityLifecycle
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: TeamID,
        name: String,
        summary: String? = nil,
        leadID: TeammateID,
        memberIDs: Set<TeammateID>,
        lifecycle: DurableEntityLifecycle = .active,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard memberIDs.contains(leadID) else {
            throw DomainValidationError.invalid(field: "team lead", reason: "lead must be an active member")
        }
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(field: "team timestamps", reason: "updatedAt cannot precede createdAt")
        }
        self.id = id
        self.name = try DomainText.required(name, field: "team name", maximum: 120)
        self.summary = try DomainText.optional(summary, field: "team summary", maximum: 2_000)
        self.leadID = leadID
        self.memberIDs = memberIDs
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func addMember(_ teammateID: TeammateID) {
        memberIDs.insert(teammateID)
    }

    public mutating func removeMember(_ teammateID: TeammateID) throws {
        guard teammateID != leadID else {
            throw DomainValidationError.invalid(
                field: "team membership",
                reason: "assign a different lead before removing the current lead"
            )
        }
        memberIDs.remove(teammateID)
    }

    public mutating func assignLead(_ teammateID: TeammateID) throws {
        guard memberIDs.contains(teammateID) else {
            throw DomainValidationError.invalid(field: "team lead", reason: "lead must be an active member")
        }
        leadID = teammateID
    }
}
