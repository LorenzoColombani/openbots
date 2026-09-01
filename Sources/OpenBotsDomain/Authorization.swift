import Foundation

public enum CapabilityClass: String, Codable, CaseIterable, Sendable {
    case appOwnedFiles
    case userSelectedRead
    case completedArtifactCreate
    case connectorUse
    case isolatedBrowser
    case packageProposal
    case shell
    case notifications
}

public enum CapabilityScope: Codable, Equatable, Sendable {
    case appOwnedWorkspace(teammateID: TeammateID)
    /// Opaque reference to a broker-owned native-picker grant; never a credential or raw bookmark.
    case userSelectedRead(reference: String)
    /// Opaque reference to one frozen destination or a narrowly approved folder.
    case externalWrite(reference: String)
    case connector(reference: String)
    case teammate

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case teammateID
        case reference
    }

    private enum Kind: String, Codable {
        case appOwnedWorkspace
        case userSelectedRead
        case externalWrite
        case connector
        case teammate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt8.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported capability-scope encoding version."
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .appOwnedWorkspace:
            self = .appOwnedWorkspace(
                teammateID: try container.decode(TeammateID.self, forKey: .teammateID)
            )
        case .userSelectedRead:
            self = .userSelectedRead(reference: try container.decode(String.self, forKey: .reference))
        case .externalWrite:
            self = .externalWrite(reference: try container.decode(String.self, forKey: .reference))
        case .connector:
            self = .connector(reference: try container.decode(String.self, forKey: .reference))
        case .teammate:
            self = .teammate
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(UInt8(1), forKey: .version)
        switch self {
        case let .appOwnedWorkspace(teammateID):
            try container.encode(Kind.appOwnedWorkspace, forKey: .kind)
            try container.encode(teammateID, forKey: .teammateID)
        case let .userSelectedRead(reference):
            try container.encode(Kind.userSelectedRead, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case let .externalWrite(reference):
            try container.encode(Kind.externalWrite, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case let .connector(reference):
            try container.encode(Kind.connector, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case .teammate:
            try container.encode(Kind.teammate, forKey: .kind)
        }
    }
}

public enum CapabilityGrantStatus: String, Codable, Sendable {
    case active
    case revoked
}

public struct CapabilityGrant: Codable, Equatable, Sendable, Identifiable {
    public let id: CapabilityGrantID
    public let teammateID: TeammateID
    public let capability: CapabilityClass
    public let scope: CapabilityScope
    public private(set) var status: CapabilityGrantStatus
    public let grantedAt: Date
    public private(set) var revokedAt: Date?

    public init(
        id: CapabilityGrantID,
        teammateID: TeammateID,
        capability: CapabilityClass,
        scope: CapabilityScope,
        grantedAt: Date
    ) {
        self.id = id
        self.teammateID = teammateID
        self.capability = capability
        self.scope = scope
        self.status = .active
        self.grantedAt = grantedAt
        self.revokedAt = nil
    }

    /// Persistence-only shape validation for a previously stored grant.
    public init(
        rehydrating id: CapabilityGrantID,
        teammateID: TeammateID,
        capability: CapabilityClass,
        scope: CapabilityScope,
        status: CapabilityGrantStatus,
        grantedAt: Date,
        revokedAt: Date?
    ) throws {
        guard (status == .active && revokedAt == nil) || (status == .revoked && revokedAt != nil) else {
            throw DomainValidationError.invalid(
                field: "capability grant state",
                reason: "active grants cannot have a revocation and revoked grants require one"
            )
        }
        if let revokedAt, revokedAt < grantedAt {
            throw DomainValidationError.invalid(
                field: "revocation timestamp",
                reason: "cannot precede grant"
            )
        }
        self.id = id
        self.teammateID = teammateID
        self.capability = capability
        self.scope = scope
        self.status = status
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }

    public mutating func revoke(at date: Date) throws {
        guard status == .active else {
            throw LifecycleTransitionError.illegalTransition(
                entity: "capability grant",
                state: status.rawValue,
                event: "revoke"
            )
        }
        guard date >= grantedAt else {
            throw DomainValidationError.invalid(field: "revocation timestamp", reason: "cannot precede grant")
        }
        status = .revoked
        revokedAt = date
    }
}

public enum ConsequentialActionKind: String, Codable, CaseIterable, Sendable {
    case send
    case publish
    case delete
    case overwrite
    case move
    case rename
    case metadataMutation
    case purchase
    case packageInstall
    case calendarChange
    case productionChange
    case deployment
    case credentialAccess
    case permissionChange
}

public struct ApprovalFingerprint: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        self.value = try DomainText.required(value, field: "approval fingerprint", maximum: 256)
    }
}

public enum ApprovalState: String, Codable, Sendable {
    case pending
    case approved
    case denied
    case expired
    case executing
    case succeeded
    case failed
}

public enum ApprovalDecision: String, Codable, Sendable {
    case approve
    case deny
}

public enum ApprovalTransition: Sendable {
    case resolve(ApprovalDecision)
    case expire
    case beginExecution
    case executionSucceeded
    case executionFailed
}

public struct ApprovalRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: ApprovalID
    public let teammateID: TeammateID
    public let conversationID: ConversationID
    public let action: ConsequentialActionKind
    public let exactTargetSummary: String
    public let consequenceSummary: String
    public let fingerprint: ApprovalFingerprint
    public private(set) var state: ApprovalState
    public let requestedAt: Date
    public private(set) var resolvedAt: Date?

    public init(
        id: ApprovalID,
        teammateID: TeammateID,
        conversationID: ConversationID,
        action: ConsequentialActionKind,
        exactTargetSummary: String,
        consequenceSummary: String,
        fingerprint: ApprovalFingerprint,
        requestedAt: Date
    ) throws {
        self.id = id
        self.teammateID = teammateID
        self.conversationID = conversationID
        self.action = action
        self.exactTargetSummary = try DomainText.required(
            exactTargetSummary,
            field: "approval target",
            maximum: 2_000
        )
        self.consequenceSummary = try DomainText.required(
            consequenceSummary,
            field: "approval consequence",
            maximum: 2_000
        )
        self.fingerprint = fingerprint
        self.state = .pending
        self.requestedAt = requestedAt
        self.resolvedAt = nil
    }

    /// Persistence-only shape validation for a previously stored approval.
    public init(
        rehydrating id: ApprovalID,
        teammateID: TeammateID,
        conversationID: ConversationID,
        action: ConsequentialActionKind,
        exactTargetSummary: String,
        consequenceSummary: String,
        fingerprint: ApprovalFingerprint,
        state: ApprovalState,
        requestedAt: Date,
        resolvedAt: Date?
    ) throws {
        let unresolved = state == .pending
        guard unresolved == (resolvedAt == nil) else {
            throw DomainValidationError.invalid(
                field: "approval resolution",
                reason: "only pending approvals may omit a resolution timestamp"
            )
        }
        if let resolvedAt, resolvedAt < requestedAt {
            throw DomainValidationError.invalid(
                field: "approval resolution timestamp",
                reason: "cannot precede request"
            )
        }
        self.id = id
        self.teammateID = teammateID
        self.conversationID = conversationID
        self.action = action
        self.exactTargetSummary = try DomainText.required(
            exactTargetSummary,
            field: "approval target",
            maximum: 2_000
        )
        self.consequenceSummary = try DomainText.required(
            consequenceSummary,
            field: "approval consequence",
            maximum: 2_000
        )
        self.fingerprint = fingerprint
        self.state = state
        self.requestedAt = requestedAt
        self.resolvedAt = resolvedAt
    }

    public mutating func apply(_ transition: ApprovalTransition, at date: Date) throws {
        guard date >= requestedAt else {
            throw DomainValidationError.invalid(field: "approval timestamp", reason: "cannot precede request")
        }
        switch (state, transition) {
        case (.pending, .resolve(.approve)):
            state = .approved
            resolvedAt = date
        case (.pending, .resolve(.deny)):
            state = .denied
            resolvedAt = date
        case (.pending, .expire):
            state = .expired
            resolvedAt = date
        case (.approved, .beginExecution):
            state = .executing
        case (.executing, .executionSucceeded):
            state = .succeeded
        case (.executing, .executionFailed):
            state = .failed
        default:
            throw LifecycleTransitionError.illegalTransition(
                entity: "approval",
                state: state.rawValue,
                event: String(describing: transition)
            )
        }
    }
}
