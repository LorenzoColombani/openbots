import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

public enum HiringConversationRowAuthor: Equatable, Sendable {
    case user
    case guide

    fileprivate init(_ author: HiringTurnAuthor) {
        switch author {
        case .user: self = .user
        case .guide: self = .guide
        }
    }
}

public enum HiringConversationRowDelivery: Equatable, Sendable {
    case saved
    case pending
    case failed(String)
}

public struct HiringConversationRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let author: HiringConversationRowAuthor
    public let text: String
    public let delivery: HiringConversationRowDelivery
    public let timestamp: Date

    public var accessibilityDescription: String {
        let speaker = author == .user ? "You" : "OpenBots hiring guide"
        let state = switch delivery {
        case .saved: "Saved in the local hiring draft."
        case .pending: "Adding to the local hiring draft."
        case .failed(let reason): reason
        }
        return "\(speaker). \(text). \(state)"
    }

    public init(
        id: UUID,
        author: HiringConversationRowAuthor,
        text: String,
        delivery: HiringConversationRowDelivery,
        timestamp: Date
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.delivery = delivery
        self.timestamp = timestamp
    }

    fileprivate init(_ turn: HiringTurn) {
        self.init(
            id: turn.id.rawValue,
            author: HiringConversationRowAuthor(turn.author),
            text: turn.text,
            delivery: .saved,
            timestamp: turn.createdAt
        )
    }
}

public struct HiringCandidateReviewItem: Identifiable, Equatable, Sendable {
    public let field: HiringCandidateField
    public let title: String
    public let rawValue: String
    public let displayValue: String
    public let editorPrompt: String
    public let isComplete: Bool

    public var id: HiringCandidateField { field }

    public var accessibilityDescription: String {
        let state = isComplete ? "Captured" : "Not discussed yet"
        let safety = field == .permissionIntent
            ? " This is proposed need only; no permission is granted."
            : ""
        return "\(title). \(displayValue). \(state).\(safety)"
    }
}

public struct HiringCandidateReviewUpdate: Equatable, Sendable {
    public let fields: [HiringCandidateField]
    public let fieldTitle: String
    public let displayValue: String

    public var accessibilityDescription: String {
        let safety = fields.contains(.permissionIntent)
            ? " Permission text remains intent only and grants nothing."
            : ""
        return "Candidate review updated. \(fieldTitle). \(displayValue).\(safety)"
    }
}

/// Screen-scoped orchestration for the local, deterministic hiring preview.
/// Construction is inert. Loading, revision, cancellation, and confirmation
/// occur only through the injected service when their explicit methods run.
@MainActor
public final class HiringConversationModel: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    public nonisolated static let previewDisclosure = HiringConversationService.previewDisclosure
    public let mode: LocalChatMode
    public var setupDisclosure: String {
        mode == .reviewFixture ? Self.previewDisclosure : HiringConversationService.localSetupDisclosure
    }
    public static let submitFailureMessage =
        "OpenBots couldn’t add that answer to the local hiring draft. You can try again."
    public static let revisionFailureMessage =
        "OpenBots couldn’t save that candidate detail. The prior local draft is unchanged."
    public static let loadFailureMessage =
        "OpenBots couldn’t open the local hiring draft. No teammate was created."
    public static let cancelFailureMessage =
        "OpenBots couldn’t cancel the local hiring draft. No teammate was created."
    public static let confirmFailureMessage =
        "OpenBots couldn’t create this teammate. The local draft remains available for review."

    @Published public var composerText = ""
    @Published public private(set) var displayRows: [HiringConversationRow] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var isRevising = false
    @Published public private(set) var isCancelling = false
    @Published public private(set) var isConfirming = false
    @Published public private(set) var inlineError: String?
    @Published public private(set) var lastReviewUpdate: HiringCandidateReviewUpdate?
    @Published public private(set) var confirmedCreation: DurableTeammateChatCreationSnapshot?
    @Published public private(set) var isCancelled = false

    private let service: any HiringConversationServing
    private var snapshot: HiringConversationSnapshot?
    private var hasLoaded = false
    public private(set) var isShuttingDown = false
    public func beginShutdown() { isShuttingDown = true }

    public init(service: any HiringConversationServing, mode: LocalChatMode = .localOnly) {
        self.service = service
        self.mode = mode
    }

    public var canSend: Bool {
        guard acceptsConversationInput else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var acceptsConversationInput: Bool {
        snapshot != nil && snapshot?.isReadyForReview == false && !isTerminal && !isBusy
    }

    public var canHire: Bool {
        snapshot?.isReadyForReview == true && !isTerminal && !isBusy
    }

    public var isPerformingConsequentialAction: Bool {
        isCancelling || isConfirming
    }

    public var previewIdentity: TeammateIdentitySnapshot {
        let draft = snapshot?.draft
        let draftID = draft?.id.rawValue ?? Self.placeholderCandidateID
        return TeammateIdentitySnapshot(
            id: draftID,
            name: draft?.displayName ?? "New teammate",
            role: draft?.role ?? "Role still being discussed",
            appearance: .newlyAllocated(seed: Self.stableSeed(for: draftID))
        )
    }

    public var conversationTitle: String {
        guard let name = snapshot?.draft.displayName else { return "Hire a teammate" }
        return "Hiring \(name)"
    }

    public var focusedPrompt: String {
        guard let snapshot else {
            return isLoading ? "Opening the local hiring conversation…" : "Describe who you need."
        }
        guard let field = snapshot.focusedField else {
            return "Review the candidate, refine anything needed, then confirm the hire."
        }
        switch field {
        case .displayName:
            return "What should we call this teammate?"
        case .role:
            return "What role should this teammate have?"
        case .responsibilities:
            return "What should they be responsible for?"
        case .workingStyle:
            return "How should they work and communicate?"
        case .skills:
            return "Which skills should they bring?"
        case .permissionIntent:
            return "Which permissions might they need? This grants nothing."
        case .projectPlacement:
            return "Which project should they join? This creates no membership."
        case .teamPlacement:
            return "Which team should they join? This creates no membership."
        }
    }

    public var readinessTitle: String {
        guard let snapshot else {
            return isLoading ? "Opening local draft" : "Local draft unavailable"
        }
        return snapshot.isReadyForReview ? "Ready to hire" : "Building the candidate"
    }

    public var readinessDetail: String {
        guard let snapshot else {
            return "No teammate exists until the reviewed draft is explicitly confirmed."
        }
        let captured = reviewItems.lazy.filter(\.isComplete).count
        if snapshot.isReadyForReview {
            return "All \(reviewItems.count) details are captured. Review them before confirmation."
        }
        return "\(captured) of \(reviewItems.count) details captured. No teammate exists yet."
    }

    public var readinessSymbolName: String {
        snapshot?.isReadyForReview == true ? "checkmark.seal" : "text.bubble"
    }

    public var reviewItems: [HiringCandidateReviewItem] {
        HiringCandidateField.allCases.map { field in
            let rawValue = value(for: field) ?? ""
            return HiringCandidateReviewItem(
                field: field,
                title: Self.title(for: field),
                rawValue: rawValue,
                displayValue: rawValue.isEmpty ? "Not discussed yet" : rawValue,
                editorPrompt: Self.editorPrompt(for: field),
                isComplete: !rawValue.isEmpty
            )
        }
    }

    public var hireAccessibilityHint: String {
        if canHire {
            return "Create this teammate from the exact reviewed local draft. Permission and placement text grant nothing."
        }
        return "Complete every candidate detail and review the local draft before hiring."
    }

    public var composerAccessibilityHint: String {
        if snapshot?.isReadyForReview == true {
            return "The candidate is ready for review. Refine a detail in Candidate Review or explicitly hire the teammate."
        }
        if acceptsConversationInput {
            return mode == .reviewFixture
                ? "Write naturally. This local preview records the message in the focused candidate detail. Press Command-Return to send."
                : "Each answer is saved in the focused candidate detail. Press Command-Return to add it. Claude does not interpret it."
        }
        return isLoading
            ? "The local hiring conversation is opening."
            : "Hiring input is temporarily unavailable."
    }

    public var composerSupportText: String {
        if snapshot?.isReadyForReview == true {
            return "Review or refine the candidate, then explicitly choose Hire Teammate. Nothing is granted automatically."
        }
        return mode == .reviewFixture
            ? "Write naturally. This preview updates only the focused candidate detail; it does not infer other details, grant permissions, or run tools."
            : "Each answer updates the focused candidate detail. No permissions are granted and no tools run."
    }

    public func load() async {
        guard !hasLoaded, !isLoading, !isTerminal else { return }
        isLoading = true
        inlineError = nil
        defer { if !isShuttingDown { isLoading = false } }

        do {
            let loaded = try await service.loadOrStart()
            guard !isShuttingDown else { return }
            apply(loaded, announceReviewChange: false)
            hasLoaded = true
        } catch {
            guard !isShuttingDown else { return }
            inlineError = Self.loadFailureMessage
        }
    }

    /// Appends the user's row synchronously before the service round trip.
    /// The returned durable snapshot then replaces all provisional row state.
    public func submitCurrentText(
        messageID: UUID = UUID(),
        now: Date = Date()
    ) {
        let text = composerText
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        composerText = ""
        inlineError = nil
        isSubmitting = true
        displayRows.append(
            HiringConversationRow(
                id: messageID,
                author: .user,
                text: text,
                delivery: .pending,
                timestamp: now
            )
        )

        Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown else { return }
            do {
                apply(try await service.submit(text: text), announceReviewChange: true)
            } catch {
                guard !isShuttingDown else { return }
                markPendingRowFailed(id: messageID, reason: Self.submitFailureMessage)
                inlineError = Self.submitFailureMessage
            }
            if !isShuttingDown { isSubmitting = false }
        }
    }

    @discardableResult
    public func revise(_ field: HiringCandidateField, text: String) async -> Bool {
        guard snapshot != nil, !isTerminal, !isBusy else { return false }
        inlineError = nil
        isRevising = true
        defer { if !isShuttingDown { isRevising = false } }

        do {
            apply(
                try await service.revise(field: field, value: text),
                announceReviewChange: true
            )
            return !isShuttingDown
        } catch {
            guard !isShuttingDown else { return false }
            inlineError = Self.revisionFailureMessage
            return false
        }
    }

    /// Success means the service removed the provisional draft. The embedding
    /// conversation coordinator can then leave hiring mode knowing that no
    /// teammate was created by cancellation.
    @discardableResult
    public func cancel() async -> Bool {
        guard snapshot != nil, !isTerminal, !isBusy else { return false }
        inlineError = nil
        isCancelling = true
        defer { if !isShuttingDown { isCancelling = false } }

        do {
            try await service.cancel()
            guard !isShuttingDown else { return false }
            isCancelled = true
            return true
        } catch {
            guard !isShuttingDown else { return false }
            inlineError = Self.cancelFailureMessage
            return false
        }
    }

    /// Explicit confirmation is the only path that asks the service to create
    /// the teammate, direct conversation, greeting, and selection atomically.
    @discardableResult
    public func confirmHire() async -> Bool {
        guard canHire else { return false }
        inlineError = nil
        isConfirming = true
        defer { if !isShuttingDown { isConfirming = false } }

        do {
            let appearance = try Self.agentAppearance(from: previewIdentity.appearance)
            let confirmed = try await service.confirm(appearance: appearance)
            guard !isShuttingDown else { return false }
            confirmedCreation = confirmed
            return true
        } catch {
            guard !isShuttingDown else { return false }
            inlineError = Self.confirmFailureMessage
            return false
        }
    }

    private var isBusy: Bool {
        isLoading || isSubmitting || isRevising || isCancelling || isConfirming
    }

    private var isTerminal: Bool {
        isShuttingDown || isCancelled || confirmedCreation != nil
    }

    private func apply(
        _ snapshot: HiringConversationSnapshot,
        announceReviewChange: Bool
    ) {
        guard !isShuttingDown else { return }
        let previous = self.snapshot
        self.snapshot = snapshot
        displayRows = snapshot.turns.map(HiringConversationRow.init)
        inlineError = nil

        guard announceReviewChange, let previous else { return }
        let changedFields = HiringCandidateField.allCases.filter { field in
            Self.value(for: field, in: previous.draft)
                != Self.value(for: field, in: snapshot.draft)
        }
        guard !changedFields.isEmpty else { return }

        let titles = changedFields.map(Self.title(for:)).joined(separator: ", ")
        let values = changedFields.compactMap { field in
            Self.value(for: field, in: snapshot.draft)
        }
        lastReviewUpdate = HiringCandidateReviewUpdate(
            fields: changedFields,
            fieldTitle: titles,
            displayValue: values.count == 1
                ? values[0]
                : "\(values.count) candidate details changed"
        )
    }

    private func markPendingRowFailed(id: UUID, reason: String) {
        guard let index = displayRows.firstIndex(where: { $0.id == id }) else { return }
        let row = displayRows[index]
        displayRows[index] = HiringConversationRow(
            id: row.id,
            author: row.author,
            text: row.text,
            delivery: .failed(reason),
            timestamp: row.timestamp
        )
    }

    private func value(for field: HiringCandidateField) -> String? {
        guard let draft = snapshot?.draft else { return nil }
        return Self.value(for: field, in: draft)
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

    private static func title(for field: HiringCandidateField) -> String {
        switch field {
        case .displayName: "Name"
        case .role: "Role"
        case .responsibilities: "Responsibilities"
        case .workingStyle: "Personality and working style"
        case .skills: "Skills"
        case .permissionIntent: "Permission intent"
        case .projectPlacement: "Project placement"
        case .teamPlacement: "Team placement"
        }
    }

    private static func editorPrompt(for field: HiringCandidateField) -> String {
        switch field {
        case .displayName: "Candidate name"
        case .role: "Short role"
        case .responsibilities: "What they own"
        case .workingStyle: "How they work and communicate"
        case .skills: "Skills and strengths"
        case .permissionIntent: "Potential needs; grants nothing"
        case .projectPlacement: "Project intent; creates no membership"
        case .teamPlacement: "Team intent; creates no membership"
        }
    }

    private static func agentAppearance(
        from appearance: CharacterAppearanceSnapshot
    ) throws -> AgentAppearance {
        try AgentAppearance(
            mode: appearance.mode,
            grammarVersion: appearance.grammarVersion,
            deterministicSeed: appearance.deterministicSeed,
            silhouette: appearance.silhouette,
            paletteToken: appearance.paletteToken,
            eyeDialect: appearance.eyeDialect,
            nonColorIdentityCue: appearance.nonColorIdentityCue,
            accessibleIdentityDescription: appearance.accessibleIdentityDescription,
            profileAssetID: appearance.profileAssetID.map(ProfileAssetID.init),
            builtInAvatarID: appearance.builtInAvatarID,
            revision: appearance.revision
        )
    }

    private static func stableSeed(for id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(14_695_981_039_346_656_037) { partial, byte in
                (partial ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
    }

    private static let placeholderCandidateID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!
}
