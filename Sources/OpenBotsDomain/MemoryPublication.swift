import Foundation

public enum MemoryPublicationLimits {
    public static let candidateBytes = 16_384
    public static let units = 12
    public static let referencesPerUnit = 12
    public static let renderedBytes = 24_576
    public static let ancestorReceipts = 64
    public static let dependencyReferences = 256
}

/// Selected by an app-owned request path, never by a provider's response.
public enum MemoryConversationIntent: String, Codable, Equatable, Sendable {
    case reply, explanation, overview, historyOverview
}

public enum MemoryPublicationUnitKind: String, Codable, Equatable, Sendable {
    case claim, clarification, reconsideration, explanation, overview
    case explanationSourcesUnavailable, explanationLineageUnverifiable

    public var explanationLimitation: MemoryExplanationLimitation? {
        switch self {
        case .explanationSourcesUnavailable: .sourcesUnavailable
        case .explanationLineageUnverifiable: .lineageUnverifiable
        default: nil
        }
    }
}

/// A closed host observation, never a provider-selected claim or reasoning trace.
public enum MemoryExplanationLimitation: Equatable, Sendable {
    case sourcesUnavailable, lineageUnverifiable

    public var text: String {
        switch self {
        case .sourcesUnavailable:
            "I can’t check the sources behind that reply in this conversation’s current context, so I can’t reliably explain it or repeat those claims."
        case .lineageUnverifiable:
            "I can’t verify a reliable link between that reply and its recorded sources, so I can’t reliably explain why it was said."
        }
    }
}

/// A candidate has no field for prose, assessment, attribution or a replacement
/// body. References still require authoritative resolution and revalidation.
public struct MemoryPublicationUnit: Codable, Equatable, Sendable {
    public let kind: MemoryPublicationUnitKind
    public let references: [MemoryClaimReference]

    public init(kind: MemoryPublicationUnitKind, references: [MemoryClaimReference]) {
        self.kind = kind; self.references = references
    }
}

public struct MemoryPublicationCandidate: Equatable, Sendable {
    public let version: UInt16
    public let units: [MemoryPublicationUnit]

    public init(version: UInt16 = 1, units: [MemoryPublicationUnit]) {
        self.version = version; self.units = units
    }
}

/// Frozen app-selected references and relevance. This is not an authorization:
/// the resolver must independently check current scope, heads and evidence.
public struct MemoryPublicationContext: Sendable {
    public let runID: RunID
    public let messageID: MessageID
    public let teammateID: TeammateID
    public let selectedProjectID: ProjectID?
    public let intent: MemoryConversationIntent
    public let admittedReferences: [MemoryClaimReference]
    public let relevantReferences: [MemoryClaimReference]
    public let explainedReceiptID: UUID?
    public let explanationLimitation: MemoryExplanationLimitation?
    public let now: Date

    public init(runID: RunID, messageID: MessageID, teammateID: TeammateID,
                selectedProjectID: ProjectID? = nil, intent: MemoryConversationIntent = .reply,
                admittedReferences: [MemoryClaimReference], relevantReferences: [MemoryClaimReference],
                explainedReceiptID: UUID? = nil, explanationLimitation: MemoryExplanationLimitation? = nil, now: Date) {
        self.runID = runID; self.messageID = messageID; self.teammateID = teammateID
        self.selectedProjectID = selectedProjectID; self.intent = intent
        self.admittedReferences = admittedReferences; self.relevantReferences = relevantReferences
        self.explainedReceiptID = explainedReceiptID; self.now = now
        self.explanationLimitation = explanationLimitation
    }
}

/// Supplied by authoritative storage, never accepted in candidate JSON.
/// Independent means a proven absence of publication-derived history, not a
/// missing history record. Unknown ancestry cannot take the independent path.
public enum MemoryPublicationLineage: Codable, Equatable, Sendable {
    case independent
    case derived(receiptIDs: [UUID])
    case unknown
}

/// The resolver binds the claim and policy context to current authoritative
/// bytes. The publication service also invokes the domain digest/use checks.
public struct MemoryPublicationClaimSnapshot: Sendable {
    public let claim: MemoryClaim
    public let reference: MemoryClaimReference
    public let scope: MemoryScope
    public let useContext: MemoryClaimUseContext
    public let lineage: MemoryPublicationLineage

    public init(claim: MemoryClaim, reference: MemoryClaimReference, scope: MemoryScope,
                useContext: MemoryClaimUseContext, lineage: MemoryPublicationLineage) {
        self.claim = claim; self.reference = reference; self.scope = scope
        self.useContext = useContext; self.lineage = lineage
    }
}

/// No body or hidden reasoning is duplicated here. Exact claim digests bind the
/// body, assessment, qualifications and source/evidence reference stamps.
public struct MemoryPublicationDependency: Codable, Equatable, Sendable {
    public let reference: MemoryClaimReference
    public let scope: MemoryScope
    public let sourceStamps: [MemoryClaimSourceReference]
    public let evidenceStamps: [MemoryClaimEvidenceReference]
    public let decision: MemoryClaimUseDecision

    public init(reference: MemoryClaimReference, scope: MemoryScope,
                sourceStamps: [MemoryClaimSourceReference], evidenceStamps: [MemoryClaimEvidenceReference],
                decision: MemoryClaimUseDecision) {
        self.reference = reference; self.scope = scope
        self.sourceStamps = sourceStamps; self.evidenceStamps = evidenceStamps
        self.decision = decision
    }
}

/// A proposed publication receipt, not persistence success or an effect grant.
/// The caller must atomically save this with the exact complete rendered text,
/// after fresh revalidation. Existing provider records remain distinct.
public struct MemoryPublicationReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let policyVersion: UInt16
    public let runID: RunID
    public let messageID: MessageID
    public let teammateID: TeammateID
    public let selectedProjectID: ProjectID?
    public let intent: MemoryConversationIntent
    public let renderedTextDigest: String
    /// Closed render inputs permit deterministic reconstruction when validating
    /// a saved projection; a matching caller-computed text hash alone is not enough.
    public let units: [MemoryPublicationUnit]
    public let dependencies: [MemoryPublicationDependency]
    public let omittedUnitCount: Int
    public let lineage: MemoryPublicationLineage
    public let createdAt: Date

    public init(id: UUID, policyVersion: UInt16, runID: RunID, messageID: MessageID,
                teammateID: TeammateID, selectedProjectID: ProjectID?, intent: MemoryConversationIntent,
                renderedTextDigest: String, units: [MemoryPublicationUnit], dependencies: [MemoryPublicationDependency],
                omittedUnitCount: Int = 0,
                lineage: MemoryPublicationLineage, createdAt: Date) {
        self.id = id; self.policyVersion = policyVersion; self.runID = runID; self.messageID = messageID
        self.teammateID = teammateID; self.selectedProjectID = selectedProjectID; self.intent = intent
        self.renderedTextDigest = renderedTextDigest; self.units = units; self.dependencies = dependencies
        self.omittedUnitCount = omittedUnitCount
        self.lineage = lineage; self.createdAt = createdAt
    }
}

/// Plain text only: downstream Markdown/HTML interpretation would create another
/// publication boundary. These complete units already include all qualifications.
public struct MemoryConversationPublication: Equatable, Sendable {
    public let completeUnits: [String]
    public let receipt: MemoryPublicationReceipt
    public let omittedUnitCount: Int
    public var text: String { completeUnits.joined(separator: "\n\n") }

    public init(completeUnits: [String], receipt: MemoryPublicationReceipt, omittedUnitCount: Int) {
        self.completeUnits = completeUnits; self.receipt = receipt; self.omittedUnitCount = omittedUnitCount
    }
}
