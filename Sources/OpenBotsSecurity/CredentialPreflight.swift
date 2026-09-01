import Foundation

public enum CredentialClass: String, Codable, CaseIterable, Sendable {
    case gitOrPackageDownload
    case claudeSubscriptionOAuth
    case releaseCodeSigning
    case connectorSecret
    case databaseEncryptionKey
}

public enum CredentialAccessDirection: String, Codable, Sendable {
    case read
    case write
    case readWrite
}

public enum CredentialPersistence: Equatable, Sendable {
    case oneShot
    case currentSession
    case untilRevoked(revocation: String)
}

public enum CredentialDisclosureError: Error, Equatable, Sendable {
    case missingField(String)
}

public struct CredentialAccessDisclosure: Equatable, Sendable {
    public let id: UUID
    public let resource: String
    public let provider: String
    public let credentialClass: CredentialClass
    public let leastScope: String
    public let accessDirection: CredentialAccessDirection
    public let publicRouteFailure: String
    public let promptOwner: String
    public let persistence: CredentialPersistence
    public let safeDeclineConsequence: String

    public init(
        id: UUID,
        resource: String,
        provider: String,
        credentialClass: CredentialClass,
        leastScope: String,
        accessDirection: CredentialAccessDirection,
        publicRouteFailure: String,
        promptOwner: String,
        persistence: CredentialPersistence,
        safeDeclineConsequence: String
    ) throws {
        try Self.require(resource, field: "resource")
        try Self.require(provider, field: "provider")
        try Self.require(leastScope, field: "leastScope")
        try Self.require(publicRouteFailure, field: "publicRouteFailure")
        try Self.require(promptOwner, field: "promptOwner")
        try Self.require(safeDeclineConsequence, field: "safeDeclineConsequence")
        if case let .untilRevoked(revocation) = persistence {
            try Self.require(revocation, field: "revocation")
        }
        self.id = id
        self.resource = resource
        self.provider = provider
        self.credentialClass = credentialClass
        self.leastScope = leastScope
        self.accessDirection = accessDirection
        self.publicRouteFailure = publicRouteFailure
        self.promptOwner = promptOwner
        self.persistence = persistence
        self.safeDeclineConsequence = safeDeclineConsequence
    }

    private static func require(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CredentialDisclosureError.missingField(field)
        }
    }
}

public enum CredentialRoute: Equatable, Sendable {
    case publicUnauthenticated(resource: String)
    case authenticated(CredentialAccessDisclosure)
}

public struct CredentialDisclosureReceipt: Equatable, Sendable {
    public let disclosureID: UUID
    public let presentedAt: Date

    public init(disclosureID: UUID, presentedAt: Date) {
        self.disclosureID = disclosureID
        self.presentedAt = presentedAt
    }
}

public struct CredentialApprovalReceipt: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case approved
        case declined
    }

    public let disclosureID: UUID
    public let decision: Decision
    public let decidedAt: Date

    public init(disclosureID: UUID, decision: Decision, decidedAt: Date) {
        self.disclosureID = disclosureID
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

public struct CredentialExecutionAuthorization: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case anonymousPublic
        case exactAuthenticatedClass(CredentialClass)
    }

    public let mode: Mode
    public let allowsAmbientCredentialProviders: Bool
    public let disclosureID: UUID?

    fileprivate init(mode: Mode, disclosureID: UUID?) {
        self.mode = mode
        allowsAmbientCredentialProviders = false
        self.disclosureID = disclosureID
    }
}

public enum CredentialPreflightError: Error, Equatable, Sendable {
    case disclosureRequired
    case approvalRequired
    case receiptMismatch
    case approvalPredatesDisclosure
    case declined(safeConsequence: String)
}

public struct CredentialPreflightGate: Sendable {
    public init() {}

    /// Public routes always return an anonymous policy and ignore ambient providers.
    /// Authenticated routes require proof that the exact disclosure was presented and approved.
    public func authorize(
        route: CredentialRoute,
        disclosureReceipt: CredentialDisclosureReceipt? = nil,
        approvalReceipt: CredentialApprovalReceipt? = nil
    ) throws -> CredentialExecutionAuthorization {
        switch route {
        case .publicUnauthenticated:
            return CredentialExecutionAuthorization(mode: .anonymousPublic, disclosureID: nil)
        case let .authenticated(disclosure):
            guard let disclosureReceipt else { throw CredentialPreflightError.disclosureRequired }
            guard disclosureReceipt.disclosureID == disclosure.id else {
                throw CredentialPreflightError.receiptMismatch
            }
            guard let approvalReceipt else { throw CredentialPreflightError.approvalRequired }
            guard approvalReceipt.disclosureID == disclosure.id else {
                throw CredentialPreflightError.receiptMismatch
            }
            guard approvalReceipt.decidedAt >= disclosureReceipt.presentedAt else {
                throw CredentialPreflightError.approvalPredatesDisclosure
            }
            switch approvalReceipt.decision {
            case .declined:
                throw CredentialPreflightError.declined(
                    safeConsequence: disclosure.safeDeclineConsequence
                )
            case .approved:
                return CredentialExecutionAuthorization(
                    mode: .exactAuthenticatedClass(disclosure.credentialClass),
                    disclosureID: disclosure.id
                )
            }
        }
    }
}
