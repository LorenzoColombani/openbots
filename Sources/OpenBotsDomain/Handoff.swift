import Foundation

public struct HandoffBrief: Codable, Equatable, Sendable {
    public let goal: String
    public let constraints: [String]
    public let inputReferences: [String]
    public let requestedOutput: String
    public let exclusions: [String]
    public let stopOrApprovalBoundary: String

    public init(
        goal: String,
        constraints: [String],
        inputReferences: [String],
        requestedOutput: String,
        exclusions: [String],
        stopOrApprovalBoundary: String
    ) throws {
        self.goal = try DomainText.required(goal, field: "handoff goal", maximum: 2_000)
        self.constraints = try Self.validatedList(
            constraints,
            field: "handoff constraints",
            maximumCount: 32,
            maximumItemLength: 1_000
        )
        self.inputReferences = try Self.validatedList(
            inputReferences,
            field: "handoff input references",
            maximumCount: 64,
            maximumItemLength: 1_000
        )
        self.requestedOutput = try DomainText.required(
            requestedOutput,
            field: "handoff requested output",
            maximum: 2_000
        )
        self.exclusions = try Self.validatedList(
            exclusions,
            field: "handoff exclusions",
            maximumCount: 32,
            maximumItemLength: 1_000
        )
        self.stopOrApprovalBoundary = try DomainText.required(
            stopOrApprovalBoundary,
            field: "handoff stop or approval boundary",
            maximum: 2_000
        )
    }

    private static func validatedList(
        _ values: [String],
        field: String,
        maximumCount: Int,
        maximumItemLength: Int
    ) throws -> [String] {
        guard values.count <= maximumCount else {
            throw DomainValidationError.invalid(
                field: field,
                reason: "cannot contain more than \(maximumCount) items"
            )
        }
        return try values.enumerated().map { index, value in
            try DomainText.required(
                value,
                field: "\(field) item \(index + 1)",
                maximum: maximumItemLength
            )
        }
    }
}

public struct HandoffProvenance: Codable, Equatable, Sendable {
    public let handoffID: HandoffID
    public let legID: HandoffLegID
    public let originConversationID: ConversationID
    public let senderID: TeammateID
    public let receiverID: TeammateID
    public let createdAt: Date

    public init(
        handoffID: HandoffID,
        legID: HandoffLegID,
        originConversationID: ConversationID,
        senderID: TeammateID,
        receiverID: TeammateID,
        createdAt: Date
    ) throws {
        guard senderID != receiverID else {
            throw DomainValidationError.invalid(
                field: "handoff receiver",
                reason: "must differ from the sender"
            )
        }
        self.handoffID = handoffID
        self.legID = legID
        self.originConversationID = originConversationID
        self.senderID = senderID
        self.receiverID = receiverID
        self.createdAt = createdAt
    }
}

public enum HandoffState: String, Codable, CaseIterable, Sendable {
    case staged
    case accepted
    case working
    case succeeded
    case returnedToOrigin
    case needsRecovery
}

public struct HandoffRecovery: Codable, Equatable, Sendable {
    public let code: String
    public let userMessage: String
    public let isRecoverable: Bool
    public let occurredAt: Date

    public init(
        code: String,
        userMessage: String,
        isRecoverable: Bool,
        occurredAt: Date
    ) throws {
        self.code = try DomainText.required(code, field: "handoff recovery code", maximum: 120)
        self.userMessage = try DomainText.required(
            userMessage,
            field: "handoff recovery message",
            maximum: 2_000
        )
        self.isRecoverable = isRecoverable
        self.occurredAt = occurredAt
    }
}

/// A compact receiver result. It intentionally has no transcript, prompt,
/// runtime event stream, or hidden reasoning field.
public struct HandoffResultReference: Equatable, Sendable {
    public let handoffID: HandoffID
    public let legID: HandoffLegID
    public let sourceTeammateID: TeammateID
    public let summary: String
    public let completedAt: Date

    fileprivate init(
        provenance: HandoffProvenance,
        summary: String,
        completedAt: Date
    ) {
        handoffID = provenance.handoffID
        legID = provenance.legID
        sourceTeammateID = provenance.receiverID
        self.summary = summary
        self.completedAt = completedAt
    }
}

/// Proof that the receiver's compact result was explicitly returned to the
/// originating teammate. Merely succeeding does not expose a result to the
/// origin lane.
public struct HandoffFanInReceipt: Equatable, Sendable {
    public let handoffID: HandoffID
    public let legID: HandoffLegID
    public let sourceTeammateID: TeammateID
    public let originTeammateID: TeammateID
    public let result: HandoffResultReference
    public let returnedAt: Date

    fileprivate init(
        provenance: HandoffProvenance,
        result: HandoffResultReference,
        returnedAt: Date
    ) {
        handoffID = provenance.handoffID
        legID = provenance.legID
        sourceTeammateID = provenance.receiverID
        originTeammateID = provenance.senderID
        self.result = result
        self.returnedAt = returnedAt
    }
}

public enum HandoffEvent: Equatable, Sendable {
    case accept(at: Date)
    case beginWork(at: Date)
    case succeed(summary: String, at: Date)
    case returnToOrigin(at: Date)
    case requireRecovery(HandoffRecovery)

    fileprivate var name: String {
        switch self {
        case .accept: "accept"
        case .beginWork: "beginWork"
        case .succeed: "succeed"
        case .returnToOrigin: "returnToOrigin"
        case .requireRecovery: "requireRecovery"
        }
    }

    fileprivate var occurredAt: Date {
        switch self {
        case .accept(let at), .beginWork(let at), .returnToOrigin(let at): at
        case .succeed(_, let at): at
        case .requireRecovery(let recovery): recovery.occurredAt
        }
    }
}

/// One directed, process-independent handoff state machine. The Sprint 3A
/// service uses it only to build a deterministic local review fixture; no
/// persistence or runtime delivery is implied by constructing this value.
public struct Handoff: Equatable, Sendable {
    public let provenance: HandoffProvenance
    public let brief: HandoffBrief
    public private(set) var state: HandoffState
    public private(set) var recovery: HandoffRecovery?
    public private(set) var lastTransitionAt: Date

    private var completedResult: HandoffResultReference?
    private var fanInReceipt: HandoffFanInReceipt?

    public var resultForOrigin: HandoffFanInReceipt? { fanInReceipt }

    public init(provenance: HandoffProvenance, brief: HandoffBrief) {
        self.provenance = provenance
        self.brief = brief
        state = .staged
        recovery = nil
        lastTransitionAt = provenance.createdAt
        completedResult = nil
        fanInReceipt = nil
    }

    public mutating func apply(_ event: HandoffEvent) throws {
        let occurredAt = event.occurredAt
        guard occurredAt >= lastTransitionAt else {
            throw DomainValidationError.invalid(
                field: "handoff transition timestamp",
                reason: "cannot precede the previous transition"
            )
        }

        switch (state, event) {
        case (.staged, .accept):
            state = .accepted

        case (.accepted, .beginWork):
            state = .working

        case let (.working, .succeed(summary, completedAt)):
            let safeSummary = try DomainText.required(
                summary,
                field: "handoff result summary",
                maximum: 2_000
            )
            completedResult = HandoffResultReference(
                provenance: provenance,
                summary: safeSummary,
                completedAt: completedAt
            )
            state = .succeeded

        case let (.succeeded, .returnToOrigin(returnedAt)):
            guard let completedResult else {
                throw DomainValidationError.invalid(
                    field: "handoff fan-in",
                    reason: "requires a completed receiver result"
                )
            }
            fanInReceipt = HandoffFanInReceipt(
                provenance: provenance,
                result: completedResult,
                returnedAt: returnedAt
            )
            state = .returnedToOrigin

        case let (.staged, .requireRecovery(recovery)),
             let (.accepted, .requireRecovery(recovery)),
             let (.working, .requireRecovery(recovery)):
            self.recovery = recovery
            completedResult = nil
            fanInReceipt = nil
            state = .needsRecovery

        default:
            throw LifecycleTransitionError.illegalTransition(
                entity: "handoff",
                state: state.rawValue,
                event: event.name
            )
        }

        lastTransitionAt = occurredAt
    }
}
