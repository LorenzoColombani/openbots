import CryptoKit
import Foundation

public struct MemoryClaimID: OpenBotsIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a claim UUID.")
        }
        self.init(id)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }
}

public enum MemoryClaimAssessmentLevel: Equatable, Sendable, Codable {
    case unassessed, uncertain, supportedInference, confirmed
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "unassessed": self = .unassessed
        case "uncertain": self = .uncertain
        case "supported-inference": self = .supportedInference
        case "confirmed": self = .confirmed
        case let value: self = .unknown(value)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .unassessed: value = "unassessed"
        case .uncertain: value = "uncertain"
        case .supportedInference: value = "supported-inference"
        case .confirmed: value = "confirmed"
        case let .unknown(raw): value = raw
        }
        try container.encode(value)
    }
}

public enum MemoryClaimValidity: Equatable, Sendable, Codable {
    case active, needsReview, disputed, withdrawn
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "active": self = .active
        case "needs-review": self = .needsReview
        case "disputed": self = .disputed
        case "withdrawn": self = .withdrawn
        case let value: self = .unknown(value)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .active: value = "active"
        case .needsReview: value = "needs-review"
        case .disputed: value = "disputed"
        case .withdrawn: value = "withdrawn"
        case let .unknown(raw): value = raw
        }
        try container.encode(value)
    }
}

public enum MemoryClaimSourceKind: Equatable, Sendable, Codable {
    case userMessage, appObservation, sourceDocument, modelInference, modelEcho
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "user-message": self = .userMessage
        case "app-observation": self = .appObservation
        case "source-document": self = .sourceDocument
        case "model-inference": self = .modelInference
        case "model-echo": self = .modelEcho
        case let value: self = .unknown(value)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .userMessage: value = "user-message"
        case .appObservation: value = "app-observation"
        case .sourceDocument: value = "source-document"
        case .modelInference: value = "model-inference"
        case .modelEcho: value = "model-echo"
        case let .unknown(raw): value = raw
        }
        try container.encode(value)
    }
}

public struct MemoryClaimSourceReference: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: MemoryClaimSourceKind
    public let sourceID: String
    public let sourceRevision: UInt64?
    public let contentDigest: String?
    public let observedAt: Date?
    public let scope: MemoryScope
    /// Original source identities, not independent support or publication ancestry.
    public let derivedFrom: [UUID]

    public init(id: UUID, kind: MemoryClaimSourceKind, sourceID: String,
                sourceRevision: UInt64? = nil, contentDigest: String? = nil,
                observedAt: Date? = nil, scope: MemoryScope, derivedFrom: [UUID] = []) {
        self.id = id; self.kind = kind; self.sourceID = sourceID
        self.sourceRevision = sourceRevision; self.contentDigest = contentDigest
        self.observedAt = observedAt; self.scope = scope; self.derivedFrom = derivedFrom
    }
}

public enum MemoryClaimEvidenceRelation: String, Codable, Equatable, Sendable {
    case supports, contradicts, invalidates
}

/// A retained attribution, NOT proof that a verifier issued this receipt.
public struct MemoryClaimEvidenceReference: Codable, Equatable, Sendable {
    public let receiptID: UUID
    public let receiptDigest: String
    public let source: MemoryClaimSourceReference
    public let relation: MemoryClaimEvidenceRelation
    public let subjectDigest: String

    public init(receiptID: UUID, receiptDigest: String, source: MemoryClaimSourceReference,
                relation: MemoryClaimEvidenceRelation, subjectDigest: String) {
        self.receiptID = receiptID; self.receiptDigest = receiptDigest; self.source = source
        self.relation = relation; self.subjectDigest = subjectDigest
    }
}

public struct MemoryClaimAssessor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, app, unassessed }
    public let kind: Kind
    public let identity: String?
    public init(kind: Kind, identity: String? = nil) { self.kind = kind; self.identity = identity }
}

public struct MemoryClaimAssessment: Codable, Equatable, Sendable {
    public let level: MemoryClaimAssessmentLevel
    public let basis: String
    public let assessor: MemoryClaimAssessor
    public let assessedAt: Date?
    public let policyVersion: UInt16
    public let evidence: [MemoryClaimEvidenceReference]

    public init(level: MemoryClaimAssessmentLevel, basis: String,
                assessor: MemoryClaimAssessor, assessedAt: Date? = nil,
                policyVersion: UInt16 = 1, evidence: [MemoryClaimEvidenceReference] = []) {
        self.level = level; self.basis = basis; self.assessor = assessor
        self.assessedAt = assessedAt; self.policyVersion = policyVersion; self.evidence = evidence
    }
}

/// Digests bind a post-encoding artifact and its complete claim; no self-digest occurs in the artifact.
public struct MemoryClaimReference: Codable, Equatable, Hashable, Sendable {
    public let documentID: MemoryDocumentID
    public let documentRevision: UInt64
    public let contentDigest: String
    public let claimID: MemoryClaimID
    public let claimDigest: String
    public let subjectDigest: String

    public init(documentID: MemoryDocumentID, documentRevision: UInt64, contentDigest: String,
                claimID: MemoryClaimID, claimDigest: String, subjectDigest: String) {
        self.documentID = documentID; self.documentRevision = documentRevision
        self.contentDigest = contentDigest; self.claimID = claimID
        self.claimDigest = claimDigest; self.subjectDigest = subjectDigest
    }
}

public struct MemoryClaimChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case correction, reassessment, supersession, withdrawal }
    public let kind: Kind
    public let previous: MemoryClaimReference
    public let reason: String
    public let changedAt: Date
    public init(kind: Kind, previous: MemoryClaimReference, reason: String, changedAt: Date) {
        self.kind = kind; self.previous = previous; self.reason = reason; self.changedAt = changedAt
    }
}

public struct MemoryClaim: Codable, Equatable, Sendable, Identifiable {
    public let id: MemoryClaimID
    /// Exact text: validation never trims, normalizes, summarizes or rewrites it.
    public let body: String
    public let assessment: MemoryClaimAssessment
    public let provenance: [MemoryClaimSourceReference]
    public let observedAt: Date?
    public let validFrom: Date?
    public let validUntil: Date?
    public let conditions: String?
    public let validity: MemoryClaimValidity
    public let changes: [MemoryClaimChange]

    public init(id: MemoryClaimID, body: String, assessment: MemoryClaimAssessment,
                provenance: [MemoryClaimSourceReference], observedAt: Date? = nil,
                validFrom: Date? = nil, validUntil: Date? = nil, conditions: String? = nil,
                validity: MemoryClaimValidity = .active, changes: [MemoryClaimChange] = []) {
        self.id = id; self.body = body; self.assessment = assessment; self.provenance = provenance
        self.observedAt = observedAt; self.validFrom = validFrom; self.validUntil = validUntil
        self.conditions = conditions; self.validity = validity; self.changes = changes
    }

    public var hasKnownSemantics: Bool {
        if case .unknown = assessment.level { return false }
        if case .unknown = validity { return false }
        return assessment.policyVersion == 1 && (provenance + assessment.evidence.map(\.source)).allSatisfy {
            if case .unknown = $0.kind { return false }; return true
        }
    }

    public func validate(scope: MemoryScope) throws {
        try MemoryClaimValidation.text(body, maximum: 8_192)
        try MemoryClaimValidation.text(assessment.basis, maximum: 2_048, emptyAllowed: assessment.level == .unassessed)
        if let conditions { try MemoryClaimValidation.text(conditions, maximum: 2_048) }
        if let identity = assessment.assessor.identity { try MemoryClaimValidation.text(identity, maximum: 256) }
        guard provenance.count <= 16, assessment.evidence.count <= 16, changes.count <= 16,
              Set(provenance.map(\.id)).count == provenance.count,
              Set(assessment.evidence.map(\.receiptID)).count == assessment.evidence.count else {
            throw MemoryClaimValidationError.invalid("claim reference bounds or duplicates")
        }
        let dates = [observedAt, validFrom, validUntil, assessment.assessedAt].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              validFrom == nil || validUntil == nil || validFrom! < validUntil! else {
            throw MemoryClaimValidationError.invalid("claim time")
        }
        for source in provenance + assessment.evidence.map(\.source) {
            try MemoryClaimValidation.text(source.sourceID, maximum: 512)
            guard source.scope == scope, source.sourceRevision != 0, source.derivedFrom.count <= 16,
                  !source.derivedFrom.contains(source.id),
                  Set(source.derivedFrom).count == source.derivedFrom.count,
                  source.observedAt?.timeIntervalSince1970.isFinite != false else {
                throw MemoryClaimValidationError.invalid("source scope, time or lineage")
            }
            if let digest = source.contentDigest { try MemoryClaimValidation.digest(digest) }
        }
        for evidence in assessment.evidence {
            try MemoryClaimValidation.digest(evidence.receiptDigest)
            try MemoryClaimValidation.digest(evidence.subjectDigest)
        }
        for change in changes {
            try MemoryClaimValidation.text(change.reason, maximum: 2_048)
            try MemoryClaimValidation.reference(change.previous)
            guard change.changedAt.timeIntervalSince1970.isFinite else {
                throw MemoryClaimValidationError.invalid("change time")
            }
        }
    }
}

public struct MemoryClaimArtifact: Codable, Equatable, Sendable {
    public let formatVersion: UInt16
    public let documentID: MemoryDocumentID
    public let revision: UInt64
    public let scope: MemoryScope
    public let claims: [MemoryClaim]
    public init(formatVersion: UInt16 = 1, documentID: MemoryDocumentID, revision: UInt64,
                scope: MemoryScope, claims: [MemoryClaim]) {
        self.formatVersion = formatVersion; self.documentID = documentID
        self.revision = revision; self.scope = scope; self.claims = claims
    }
    public func validate() throws {
        guard revision > 0, !claims.isEmpty, claims.count <= 32,
              Set(claims.map(\.id)).count == claims.count else {
            throw MemoryClaimValidationError.invalid("artifact revision or claim bounds")
        }
        for claim in claims {
            try claim.validate(scope: scope)
            guard claim.changes.allSatisfy({ $0.previous.documentRevision < revision && $0.previous.documentID != documentID }) else {
                throw MemoryClaimValidationError.invalid("change must refer to an earlier immutable revision")
            }
        }
    }
    public var hasKnownSemantics: Bool { formatVersion == 1 && claims.allSatisfy(\.hasKnownSemantics) }
}

public enum MemoryClaimValidationError: Error, Equatable, Sendable { case invalid(String) }

enum MemoryClaimValidation {
    static func text(_ value: String, maximum: Int, emptyAllowed: Bool = false) throws {
        guard value.utf8.count <= maximum, !value.contains("\0"),
              emptyAllowed || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryClaimValidationError.invalid("bounded nonempty text")
        }
    }
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MemoryClaimValidationError.invalid("SHA-256 digest")
        }
    }
    static func reference(_ value: MemoryClaimReference) throws {
        guard value.documentRevision > 0 else { throw MemoryClaimValidationError.invalid("reference revision") }
        try digest(value.contentDigest); try digest(value.claimDigest); try digest(value.subjectDigest)
    }
}

/// Canonical encoding is versioned with the claim format; changing it requires a new version.
public enum MemoryClaimDigests {
    public static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func claim(_ claim: MemoryClaim) throws -> String { try digest(claim) }
    public static func subject(_ claim: MemoryClaim, scope: MemoryScope) throws -> String {
        try digest(Subject(body: claim.body, scope: scope, observedAt: claim.observedAt,
                           validFrom: claim.validFrom, validUntil: claim.validUntil, conditions: claim.conditions))
    }
    public static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String { bytes(try canonicalData(value)) }
    private struct Subject: Encodable {
        let body: String; let scope: MemoryScope; let observedAt: Date?
        let validFrom: Date?; let validUntil: Date?; let conditions: String?
    }
}
