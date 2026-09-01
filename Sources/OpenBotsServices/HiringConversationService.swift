import Foundation
import OpenBotsDomain

public enum HiringCandidateField: String, CaseIterable, Equatable, Sendable {
    case displayName
    case role
    case responsibilities
    case workingStyle
    case skills
    case permissionIntent
    case projectPlacement
    case teamPlacement

    public var label: String {
        switch self {
        case .displayName: "Name"
        case .role: "Role"
        case .responsibilities: "Responsibilities"
        case .workingStyle: "Working style"
        case .skills: "Skills"
        case .permissionIntent: "Permission intent"
        case .projectPlacement: "Project placement intent"
        case .teamPlacement: "Team placement intent"
        }
    }
}

/// The bounded context supplied to a hiring-message interpreter.
///
/// Interpretation remains provisional: it may suggest draft text, but it
/// cannot create a teammate, grant a capability, or establish membership.
public struct HiringCandidateInterpretationRequest: Equatable, Sendable {
    public let message: String
    public let draft: HiringDraft
    public let focusedField: HiringCandidateField

    public init(
        message: String,
        draft: HiringDraft,
        focusedField: HiringCandidateField
    ) {
        self.message = message
        self.draft = draft
        self.focusedField = focusedField
    }
}

/// A provisional interpretation of one natural-language hiring message.
///
/// Several fields may be revised together. `guideResponse` can ask a natural
/// follow-up when information is missing or ambiguous; omitting it keeps the
/// service's deterministic next-question/review wording.
public struct HiringCandidateInterpretation: Equatable, Sendable {
    public let provisionalValues: [HiringCandidateField: String]
    public let guideResponse: String?

    public init(
        provisionalValues: [HiringCandidateField: String],
        guideResponse: String? = nil
    ) {
        self.provisionalValues = provisionalValues
        self.guideResponse = guideResponse
    }
}

/// Interprets hiring chat without receiving repositories, grants, tools, or
/// any other application authority.
public protocol HiringCandidateInterpreting: Sendable {
    /// User-visible opening text for this interpreter's actual execution mode.
    /// Implementations must not claim a runtime or inference mode that did not
    /// run.
    var openingGuideText: String { get }

    func interpret(
        _ request: HiringCandidateInterpretationRequest
    ) async throws -> HiringCandidateInterpretation
}

/// The honest executor-independent preview behavior.
///
/// This adapter performs no semantic inference: it places the user's exact
/// message into the one currently focused field. A future authorized runtime
/// interpreter can be injected without changing the persistence boundary.
public struct ExactFocusedFieldHiringInterpreter: HiringCandidateInterpreting {
    private let mode: LocalChatMode

    public init(mode: LocalChatMode = .localOnly) { self.mode = mode }

    public var openingGuideText: String {
        let disclosure = mode == .reviewFixture
            ? HiringConversationService.previewDisclosure : HiringConversationService.localSetupDisclosure
        return "\(disclosure) I’ll keep each exact answer in the transcript and place it into one labeled field without interpreting it. What should we call this teammate?"
    }

    public func interpret(
        _ request: HiringCandidateInterpretationRequest
    ) async throws -> HiringCandidateInterpretation {
        HiringCandidateInterpretation(
            provisionalValues: [request.focusedField: request.message]
        )
    }
}

public struct HiringConversationSnapshot: Equatable, Sendable {
    public let persisted: HiringDraftSnapshot
    public let focusedField: HiringCandidateField?

    public var draft: HiringDraft { persisted.draft }
    public var turns: [HiringTurn] { persisted.turns }
    public var isReadyForReview: Bool { draft.phase == .readyForReview }

    public init(
        persisted: HiringDraftSnapshot,
        focusedField: HiringCandidateField?
    ) {
        self.persisted = persisted
        self.focusedField = focusedField
    }
}

public enum HiringConversationError: Error, Equatable, Sendable {
    case draftUnavailable
    case draftAlreadyReadyForReview
    case noFieldAwaitingInput
    case emptyCandidateValue(HiringCandidateField)
    case draftNotReadyForReview(missingFields: [HiringCandidateField])
}

public protocol HiringConversationServing: Sendable {
    func loadOrStart() async throws -> HiringConversationSnapshot
    func submit(text: String) async throws -> HiringConversationSnapshot
    func revise(
        field: HiringCandidateField,
        value: String
    ) async throws -> HiringConversationSnapshot
    func cancel() async throws
    func confirm(
        appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot
}

/// Coordinates provisional hiring chat and its atomic persistence boundary.
///
/// The default interpreter maps one exact answer to one visibly focused field
/// without inference. Injected interpreters may propose several draft fields,
/// but neither path creates grants, memberships, or teammate state before the
/// repository's explicit atomic confirmation boundary.
public actor HiringConversationService: HiringConversationServing {
    public static let localSetupDisclosure =
        "Local teammate setup — each answer is saved on this Mac. Claude isn’t connected."
    public static let previewDisclosure =
        "Local guided hiring preview — no Claude runtime or tool ran."
    public static let fixtureGreetingPrefix = "Local guided hiring preview —"

    private let repository: any HiringDraftRepository
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator
    private let interpreter: any HiringCandidateInterpreting
    private let mode: LocalChatMode

    public init(
        mode: LocalChatMode = .localOnly,
        repository: any HiringDraftRepository,
        clock: any OpenBotsClock = SystemClock(),
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator(),
        interpreter: (any HiringCandidateInterpreting)? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.interpreter = interpreter ?? ExactFocusedFieldHiringInterpreter(mode: mode)
        self.mode = mode
    }

    public func loadOrStart() async throws -> HiringConversationSnapshot {
        if let existing = try await repository.latestHiringDraft() {
            return conversationSnapshot(existing)
        }

        let timestamp = clock.now()
        let draft = try HiringDraft(
            id: HiringDraftID(uuidGenerator.next()),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let initialTurn = try HiringTurn(
            id: HiringTurnID(uuidGenerator.next()),
            draftID: draft.id,
            sequence: 1,
            author: .guide,
            text: interpreter.openingGuideText,
            createdAt: timestamp
        )
        let created = try await repository.createHiringDraft(
            HiringDraftSnapshot(draft: draft, turns: [initialTurn])
        )
        return conversationSnapshot(created)
    }

    public func submit(text: String) async throws -> HiringConversationSnapshot {
        let snapshot = try await requiredDraft()
        guard snapshot.draft.phase == .collecting else {
            throw HiringConversationError.draftAlreadyReadyForReview
        }
        guard let field = Self.firstMissingField(in: snapshot.draft) else {
            throw HiringConversationError.noFieldAwaitingInput
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HiringConversationError.emptyCandidateValue(field)
        }
        let interpretation = try await interpreter.interpret(
            HiringCandidateInterpretationRequest(
                message: text,
                draft: snapshot.draft,
                focusedField: field
            )
        )
        return try await persistInterpretation(
            snapshot: snapshot,
            userText: text,
            interpretation: interpretation
        )
    }

    public func revise(
        field: HiringCandidateField,
        value: String
    ) async throws -> HiringConversationSnapshot {
        let snapshot = try await requiredDraft()
        return try await persistInterpretation(
            snapshot: snapshot,
            userText: value,
            interpretation: HiringCandidateInterpretation(
                provisionalValues: [field: value]
            )
        )
    }

    public func cancel() async throws {
        let snapshot = try await requiredDraft()
        try await repository.cancelHiringDraft(
            id: snapshot.draft.id,
            expectedRevision: snapshot.draft.revision
        )
    }

    public func confirm(
        appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot {
        let snapshot = try await requiredDraft()
        let draft = snapshot.draft
        let missingFields = Self.missingFields(in: draft)
        guard draft.phase == .readyForReview, missingFields.isEmpty else {
            throw HiringConversationError.draftNotReadyForReview(
                missingFields: missingFields
            )
        }

        guard let displayName = draft.displayName,
              let role = draft.role else {
            throw HiringConversationError.draftNotReadyForReview(
                missingFields: Self.missingFields(in: draft)
            )
        }

        let timestamp = clock.now()
        // The provisional draft grants no authority. Its raw UUID becomes a
        // teammate identity only inside this explicit confirmation operation.
        let teammateID = TeammateID(draft.id.rawValue)
        let teammate = try Teammate(
            id: teammateID,
            profile: TeammateProfile(
                displayName: displayName,
                role: role,
                detailedInstructions: Self.detailedInstructions(from: draft)
            ),
            appearance: appearance,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let conversation = try Conversation(
            id: ConversationID(uuidGenerator.next()),
            kind: .direct(teammateID: teammateID),
            title: displayName,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let fixtureGreeting: Message? = if mode == .reviewFixture { try Message(
            id: MessageID(uuidGenerator.next()),
            conversationID: conversation.id,
            sequence: 1,
            author: .teammate(teammateID),
            deliveryState: .completed,
            parts: [
                try MessagePart(
                    id: MessagePartID(uuidGenerator.next()),
                    ordinal: 0,
                    content: .text(
                        "\(Self.fixtureGreetingPrefix) \(displayName) was created from the reviewed draft. No Claude runtime or tool ran. Permission and placement text remain intent only; no grant or membership was created."
                    )
                )
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        ) } else { nil }

        try await repository.confirmHiringDraft(
            id: draft.id,
            expectedRevision: draft.revision,
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: fixtureGreeting,
            selectConversation: true
        )

        let selection = DurableChatSelectionSnapshot(
            teammate: teammate,
            conversation: conversation
        )
        return DurableTeammateChatCreationSnapshot(
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: fixtureGreeting,
            selection: selection
        )
    }

    private func requiredDraft() async throws -> HiringDraftSnapshot {
        guard let snapshot = try await repository.latestHiringDraft() else {
            throw HiringConversationError.draftUnavailable
        }
        return snapshot
    }

    private func persistInterpretation(
        snapshot: HiringDraftSnapshot,
        userText: String,
        interpretation: HiringCandidateInterpretation
    ) async throws -> HiringConversationSnapshot {
        for (field, value) in interpretation.provisionalValues {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HiringConversationError.emptyCandidateValue(field)
            }
        }
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let field = Self.firstMissingField(in: snapshot.draft)
                ?? HiringCandidateField.displayName
            throw HiringConversationError.emptyCandidateValue(field)
        }

        let timestamp = clock.now()
        let remainingMissingFields = Self.missingFields(
            in: snapshot.draft,
            afterApplying: interpretation.provisionalValues
        )
        let revised = try Self.revise(
            snapshot.draft,
            provisionalValues: interpretation.provisionalValues,
            phase: remainingMissingFields.isEmpty ? .readyForReview : .collecting,
            timestamp: timestamp
        )

        let userSequence = Int64(snapshot.turns.count) + 1
        let userTurn = try HiringTurn(
            id: HiringTurnID(uuidGenerator.next()),
            draftID: revised.id,
            sequence: userSequence,
            author: .user,
            text: userText,
            createdAt: timestamp
        )
        let guideTurn = try HiringTurn(
            id: HiringTurnID(uuidGenerator.next()),
            draftID: revised.id,
            sequence: userSequence + 1,
            author: .guide,
            text: interpretation.guideResponse ?? Self.guideText(after: revised, mode: mode),
            createdAt: timestamp
        )
        let stored = try await repository.reviseHiringDraft(
            revised,
            expectedRevision: snapshot.draft.revision,
            appending: [userTurn, guideTurn]
        )
        return conversationSnapshot(stored)
    }

    private func conversationSnapshot(
        _ snapshot: HiringDraftSnapshot
    ) -> HiringConversationSnapshot {
        HiringConversationSnapshot(
            persisted: snapshot,
            focusedField: snapshot.draft.phase == .collecting
                ? Self.firstMissingField(in: snapshot.draft)
                : nil
        )
    }

    private static func revise(
        _ draft: HiringDraft,
        provisionalValues: [HiringCandidateField: String],
        phase: HiringDraftPhase,
        timestamp: Date
    ) throws -> HiringDraft {
        try draft.revised(
            phase: phase,
            displayName: revisionValue(for: .displayName, in: provisionalValues),
            role: revisionValue(for: .role, in: provisionalValues),
            responsibilities: revisionValue(for: .responsibilities, in: provisionalValues),
            workingStyle: revisionValue(for: .workingStyle, in: provisionalValues),
            skills: revisionValue(for: .skills, in: provisionalValues),
            permissionIntent: revisionValue(for: .permissionIntent, in: provisionalValues),
            projectPlacement: revisionValue(for: .projectPlacement, in: provisionalValues),
            teamPlacement: revisionValue(for: .teamPlacement, in: provisionalValues),
            updatedAt: timestamp
        )
    }

    private static func revisionValue(
        for field: HiringCandidateField,
        in provisionalValues: [HiringCandidateField: String]
    ) -> String?? {
        guard let value = provisionalValues[field] else { return nil }
        return .some(.some(value))
    }

    private static func firstMissingField(
        in draft: HiringDraft
    ) -> HiringCandidateField? {
        missingFields(in: draft).first
    }

    private static func missingFields(
        in draft: HiringDraft
    ) -> [HiringCandidateField] {
        HiringCandidateField.allCases.filter { field in
            switch field {
            case .displayName: draft.displayName == nil
            case .role: draft.role == nil
            case .responsibilities: draft.responsibilities == nil
            case .workingStyle: draft.workingStyle == nil
            case .skills: draft.skills == nil
            case .permissionIntent: draft.permissionIntent == nil
            case .projectPlacement: draft.projectPlacement == nil
            case .teamPlacement: draft.teamPlacement == nil
            }
        }
    }

    private static func missingFields(
        in draft: HiringDraft,
        afterApplying provisionalValues: [HiringCandidateField: String]
    ) -> [HiringCandidateField] {
        HiringCandidateField.allCases.filter { field in
            provisionalValues[field] == nil && value(for: field, in: draft) == nil
        }
    }

    private static func guideText(after draft: HiringDraft, mode: LocalChatMode) -> String {
        let disclosure = mode == .reviewFixture ? previewDisclosure : localSetupDisclosure
        if draft.phase == .readyForReview {
            return reviewText(for: draft, disclosure: disclosure)
        }
        guard let field = firstMissingField(in: draft) else {
            return "\(disclosure) The draft needs review before any teammate is created."
        }
        switch field {
        case .displayName:
            return "What should we call this teammate?"
        case .role:
            return "What role should \(draft.displayName ?? "this teammate") have?"
        case .responsibilities:
            return "What should they be responsible for?"
        case .workingStyle:
            return "How should they work and communicate?"
        case .skills:
            return "Which skills should they bring?"
        case .permissionIntent:
            return "Which permissions might they need? This records intent only and grants nothing."
        case .projectPlacement:
            return "Which project should they join? This records intent only and creates no membership."
        case .teamPlacement:
            return "Which team should they join? This records intent only and creates no membership."
        }
    }

    private static func reviewText(for draft: HiringDraft, disclosure: String) -> String {
        let fields = HiringCandidateField.allCases.map { field in
            "\(field.label): \(preview(value(for: field, in: draft)))"
        }
        return "\(disclosure) Review the exact draft below; nothing has been created or granted yet. \(fields.joined(separator: " · ")) Confirm Hire Teammate when it is correct."
    }

    private static func value(
        for field: HiringCandidateField,
        in draft: HiringDraft
    ) -> String? {
        switch field {
        case .displayName: draft.displayName
        case .role: draft.role
        case .responsibilities: draft.responsibilities
        case .workingStyle: draft.workingStyle
        case .skills: draft.skills
        case .permissionIntent: draft.permissionIntent
        case .projectPlacement: draft.projectPlacement
        case .teamPlacement: draft.teamPlacement
        }
    }

    private static func preview(_ value: String?) -> String {
        guard let value else { return "Not specified" }
        let limit = 160
        guard value.count > limit else { return value }
        return "\(value.prefix(limit))…"
    }

    private static func detailedInstructions(from draft: HiringDraft) -> String {
        [
            "Responsibilities:\n\(draft.responsibilities ?? "Not specified")",
            "Working style:\n\(draft.workingStyle ?? "Not specified")",
            "Skills:\n\(draft.skills ?? "Not specified")",
            "Permission intent only — no grant was created:\n\(draft.permissionIntent ?? "Not specified")",
            "Project placement intent only — no membership was created:\n\(draft.projectPlacement ?? "Not specified")",
            "Team placement intent only — no membership was created:\n\(draft.teamPlacement ?? "Not specified")"
        ].joined(separator: "\n\n")
    }
}
