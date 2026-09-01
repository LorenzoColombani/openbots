import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

enum WorkspaceAccessibilityMetadata {
    static func timestamp(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public enum TeammateActivityState: String, CaseIterable, Codable, Sendable {
    case speaking
    case thinkingOrWorking
    case waitingForUser
    case idle
    case errorOrAttention

    public var visibleLabel: String {
        switch self {
        case .speaking: "Speaking"
        case .thinkingOrWorking: "Working"
        case .waitingForUser: "Waiting for you"
        case .idle: "Idle"
        case .errorOrAttention: "Needs attention"
        }
    }

    public var symbolName: String {
        switch self {
        case .speaking: "waveform"
        case .thinkingOrWorking: "hammer"
        case .waitingForUser: "questionmark.bubble"
        case .idle: "moon"
        case .errorOrAttention: "exclamationmark.triangle"
        }
    }
}

public enum ConversationInputAvailability: Equatable, Sendable {
    case ready
    case unavailable(reason: String)

    public var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

/// Complete, immutable presentation data for a teammate's recognizable
/// character or user-supplied profile image. Views never reconstruct identity
/// from a display name or a partial seed.
public struct CharacterAppearanceSnapshot: Equatable, Sendable {
    public let mode: AppearanceMode
    public let grammarVersion: UInt16
    public let deterministicSeed: UInt64
    public let silhouette: String
    public let paletteToken: String
    public let eyeDialect: String
    public let nonColorIdentityCue: String
    public let accessibleIdentityDescription: String
    public let profileAssetID: UUID?
    public let builtInAvatarID: String?
    public let revision: UInt64

    public init(
        mode: AppearanceMode,
        grammarVersion: UInt16,
        deterministicSeed: UInt64,
        silhouette: String,
        paletteToken: String,
        eyeDialect: String,
        nonColorIdentityCue: String,
        accessibleIdentityDescription: String,
        profileAssetID: UUID? = nil,
        builtInAvatarID: String? = nil,
        revision: UInt64
    ) {
        self.mode = mode
        self.grammarVersion = grammarVersion
        self.deterministicSeed = deterministicSeed
        self.silhouette = silhouette
        self.paletteToken = paletteToken
        self.eyeDialect = eyeDialect
        self.nonColorIdentityCue = nonColorIdentityCue
        self.accessibleIdentityDescription = accessibleIdentityDescription
        self.profileAssetID = profileAssetID
        self.builtInAvatarID = builtInAvatarID
        self.revision = revision
    }

    public init(_ appearance: AgentAppearance) {
        self.init(
            mode: appearance.mode,
            grammarVersion: appearance.grammarVersion,
            deterministicSeed: appearance.deterministicSeed,
            silhouette: appearance.silhouette,
            paletteToken: appearance.paletteToken,
            eyeDialect: appearance.eyeDialect,
            nonColorIdentityCue: appearance.nonColorIdentityCue,
            accessibleIdentityDescription: appearance.accessibleIdentityDescription,
            profileAssetID: appearance.profileAssetID?.rawValue,
            builtInAvatarID: appearance.builtInAvatarID,
            revision: appearance.revision
        )
    }

    /// Stable preview data that exercises the same complete appearance contract
    /// as persisted teammates without opening storage.
    public static func fixture(seed deterministicSeed: UInt64) -> Self {
        let silhouettes = ["soft-arch", "round-ears", "tall-tuft"]
        let palettes = ["violet-coral", "teal-gold", "blue-lilac", "plum-mint"]
        let eyes = ["round-alert", "soft-focused", "wide-curious"]
        let cues = ["single brow notch", "paired cheek marks", "forehead spark"]

        func value(_ values: [String]) -> String {
            values[Int(deterministicSeed % UInt64(values.count))]
        }

        let silhouette = value(silhouettes)
        let palette = value(palettes)
        let eyeDialect = value(eyes)
        let cue = value(cues)
        return Self(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: deterministicSeed,
            silhouette: silhouette,
            paletteToken: palette,
            eyeDialect: eyeDialect,
            nonColorIdentityCue: cue,
            accessibleIdentityDescription: "Creature with \(silhouette), \(eyeDialect) eyes, and \(cue)",
            revision: 1
        )
    }

    /// Only unsaved creation drafts allocate a model; saved appearances never
    /// call this path. The original generated identity remains the fallback.
    public static func newlyAllocated(seed: UInt64) -> Self {
        let original = fixture(seed: seed)
        return Self(
            mode: original.mode, grammarVersion: original.grammarVersion,
            deterministicSeed: original.deterministicSeed, silhouette: original.silhouette,
            paletteToken: original.paletteToken, eyeDialect: original.eyeDialect,
            nonColorIdentityCue: original.nonColorIdentityCue,
            accessibleIdentityDescription: original.accessibleIdentityDescription,
            builtInAvatarID: BuiltInAvatar.allocatedForNewIdentity(seed: seed)?.rawValue,
            revision: original.revision
        )
    }
}

/// The one presentation identity shared by roster rows, conversation headers,
/// authorship, pickers, and profile surfaces.
public struct TeammateIdentitySnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let role: String
    public let appearance: CharacterAppearanceSnapshot

    public init(
        id: UUID,
        name: String,
        role: String,
        appearance: CharacterAppearanceSnapshot
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.appearance = appearance
    }

    public init(_ teammate: Teammate) {
        self.init(
            id: teammate.id.rawValue,
            name: teammate.profile.displayName,
            role: teammate.profile.role,
            appearance: CharacterAppearanceSnapshot(teammate.appearance)
        )
    }
}

public struct TeammateRowSnapshot: Identifiable, Equatable, Sendable {
    public let identity: TeammateIdentitySnapshot
    public let activity: TeammateActivityState
    public let unreadCount: Int
    public let lastActivityAt: Date?

    public var id: UUID { identity.id }
    public var name: String { identity.name }
    public var role: String { identity.role }
    public var identitySeed: UInt64 { identity.appearance.deterministicSeed }

    func accessibilitySummary(locale: Locale, timeZone: TimeZone) -> String {
        let identityAndActivity = "\(name), \(role), \(activity.visibleLabel)"
        guard let lastActivityAt else { return identityAndActivity }
        return "\(identityAndActivity). Last activity \(WorkspaceAccessibilityMetadata.timestamp(lastActivityAt, locale: locale, timeZone: timeZone))"
    }

    public init(
        identity: TeammateIdentitySnapshot,
        activity: TeammateActivityState,
        unreadCount: Int = 0,
        lastActivityAt: Date? = nil
    ) {
        self.identity = identity
        self.activity = activity
        self.unreadCount = unreadCount
        self.lastActivityAt = lastActivityAt
    }

    /// Compatibility seam for existing callers while they adopt the complete
    /// identity snapshot. New product surfaces should pass `identity` directly.
    public init(
        id: UUID,
        name: String,
        role: String,
        activity: TeammateActivityState,
        identitySeed: UInt64,
        unreadCount: Int = 0,
        lastActivityAt: Date? = nil
    ) {
        self.init(
            identity: TeammateIdentitySnapshot(
                id: id,
                name: name,
                role: role,
                appearance: .fixture(seed: identitySeed)
            ),
            activity: activity,
            unreadCount: unreadCount,
            lastActivityAt: lastActivityAt
        )
    }
}

/// Row-scoped observable state keeps a teammate status transition from
/// publishing a replacement for the whole sidebar collection.
@MainActor
public final class TeammateRowModel: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    @Published public private(set) var snapshot: TeammateRowSnapshot

    public init(snapshot: TeammateRowSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }

    public func update(_ snapshot: TeammateRowSnapshot) {
        precondition(snapshot.id == id, "A row model cannot change teammate identity")
        self.snapshot = snapshot
    }
}

public enum MessageDeliveryState: Equatable, Sendable {
    case pending
    case sent
    case failed(String)
}

public enum ChatMessageStreamState: Equatable, Sendable {
    /// The message was delivered as one complete presentation snapshot.
    case notStreaming
    /// More content may be appended to this message row.
    case streaming
    /// A streaming message reached its normal terminal state.
    case complete
    /// A streaming message stopped before normal completion.
    case failed(String)
}

public struct ChatAttachmentSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let detail: String?

    public init(id: UUID, displayName: String, detail: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

public struct ChatArtifactSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String?

    public init(id: UUID, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct ChatQuestionChoiceSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String?

    public init(id: UUID, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    public init(_ choice: QuestionCardChoice) {
        self.init(id: choice.id.rawValue, title: choice.label)
    }
}

public enum QuestionCardResolutionSnapshot: Equatable, Sendable {
    case pending
    case answered
    case declined
}

/// Immutable, display-only question content. Answer drafts and action state
/// live in the conversation-scoped interaction model, never in the transcript
/// snapshot.
public struct ChatQuestionCardSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let prompt: String
    public let choices: [ChatQuestionChoiceSnapshot]
    public let allowsFreeText: Bool
    public let resolution: QuestionCardResolutionSnapshot

    public var hasValidChoiceContract: Bool {
        (1...6).contains(choices.count)
            && Set(choices.map(\.id)).count == choices.count
            && choices.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// Deliberately summarizes only the interaction shape. Arbitrary question
    /// copy is exposed by the visible child controls, not duplicated into a
    /// flattened string that could accidentally include a local path.
    public var accessibilityDescription: String {
        let freeText = allowsFreeText
            ? "A written answer is also available."
            : "Choose one of the listed answers."
        return "Question card. \(choices.count) answer choices. \(freeText)"
    }

    public init(
        id: UUID,
        prompt: String,
        choices: [ChatQuestionChoiceSnapshot],
        allowsFreeText: Bool,
        resolution: QuestionCardResolutionSnapshot = .pending
    ) {
        self.id = id
        self.prompt = prompt
        self.choices = choices
        self.allowsFreeText = allowsFreeText
        self.resolution = resolution
    }

    public init(_ card: InlineQuestionCard) {
        let resolution: QuestionCardResolutionSnapshot
        switch card.resolution {
        case .none:
            resolution = .pending
        case .answered:
            resolution = .answered
        case .declined:
            resolution = .declined
        }
        self.init(
            id: card.id.rawValue,
            prompt: card.prompt,
            choices: card.choices.map(ChatQuestionChoiceSnapshot.init),
            allowsFreeText: card.allowsFreeText,
            resolution: resolution
        )
    }
}

public enum ConnectorInstallationSnapshot: String, Equatable, Sendable {
    case notInstalled
    case installed
    case failed

    public var visibleLabel: String {
        switch self {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .failed: "Installation needs attention"
        }
    }

    public var symbolName: String {
        switch self {
        case .notInstalled: "shippingbox"
        case .installed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

public enum ConnectorAuthenticationSnapshot: String, Equatable, Sendable {
    case notAuthenticated
    case authenticated
    case failed

    public var visibleLabel: String {
        switch self {
        case .notAuthenticated: "Not authenticated"
        case .authenticated: "Authenticated"
        case .failed: "Authentication needs attention"
        }
    }

    public var symbolName: String {
        switch self {
        case .notAuthenticated: "person.crop.circle.badge.questionmark"
        case .authenticated: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

public enum ConnectorBotGrantSnapshot: String, Equatable, Sendable {
    case notGranted
    case granted
    case revoked

    public var visibleLabel: String {
        switch self {
        case .notGranted: "Not granted to this teammate"
        case .granted: "Granted to this teammate"
        case .revoked: "Grant revoked"
        }
    }

    public var symbolName: String {
        switch self {
        case .notGranted: "person.crop.circle.badge.minus"
        case .granted: "person.crop.circle.badge.checkmark"
        case .revoked: "person.crop.circle.badge.xmark"
        }
    }
}

public enum ConnectorActionApprovalSnapshot: String, Equatable, Sendable {
    case notRequested
    case pending
    case approved
    case denied

    public var visibleLabel: String {
        switch self {
        case .notRequested: "No action requested"
        case .pending: "Exact action approval required"
        case .approved: "Exact action approved"
        case .denied: "Action denied"
        }
    }

    public var symbolName: String {
        switch self {
        case .notRequested: "hand.raised"
        case .pending: "checkmark.shield"
        case .approved: "checkmark.shield.fill"
        case .denied: "xmark.shield"
        }
    }
}

/// Four separate state axes prevent connector installation, provider account
/// authentication, per-teammate grant, and per-action approval from being
/// flattened into a misleading single "connected" state.
public struct ChatConnectorSetupCardSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let connectorName: String
    public let installation: ConnectorInstallationSnapshot
    public let authentication: ConnectorAuthenticationSnapshot
    public let botGrant: ConnectorBotGrantSnapshot
    public let actionApproval: ConnectorActionApprovalSnapshot
    public let authenticationAttemptCount: UInt64

    public var accessibilityDescription: String {
        "Connector setup card. Installation: \(installation.visibleLabel). "
            + "Account authentication: \(authentication.visibleLabel). "
            + "Teammate grant: \(botGrant.visibleLabel). "
            + "Action approval: \(actionApproval.visibleLabel)."
    }

    public init(
        id: UUID,
        connectorName: String,
        installation: ConnectorInstallationSnapshot,
        authentication: ConnectorAuthenticationSnapshot,
        botGrant: ConnectorBotGrantSnapshot,
        actionApproval: ConnectorActionApprovalSnapshot,
        authenticationAttemptCount: UInt64 = 0
    ) {
        self.id = id
        self.connectorName = connectorName
        self.installation = installation
        self.authentication = authentication
        self.botGrant = botGrant
        self.actionApproval = actionApproval
        self.authenticationAttemptCount = authenticationAttemptCount
    }

    public init(_ card: ConnectorSetupCard) {
        self.init(
            id: card.id.rawValue,
            connectorName: card.providerName,
            installation: ConnectorInstallationSnapshot(card.state.installation),
            authentication: ConnectorAuthenticationSnapshot(
                card.state.accountAuthentication
            ),
            botGrant: ConnectorBotGrantSnapshot(card.state.perBotGrant),
            actionApproval: ConnectorActionApprovalSnapshot(
                card.state.perActionApproval
            ),
            authenticationAttemptCount: card.authenticationAttemptCount
        )
    }
}

private extension ConnectorInstallationSnapshot {
    init(_ state: ConnectorInstallationState) {
        switch state {
        case .notInstalled: self = .notInstalled
        case .installed: self = .installed
        case .failed: self = .failed
        }
    }
}

private extension ConnectorAuthenticationSnapshot {
    init(_ state: ConnectorAccountAuthenticationState) {
        switch state {
        case .notAuthenticated: self = .notAuthenticated
        case .authenticated: self = .authenticated
        case .failed: self = .failed
        }
    }
}

private extension ConnectorBotGrantSnapshot {
    init(_ state: ConnectorPerBotGrantState) {
        switch state {
        case .notGranted: self = .notGranted
        case .granted: self = .granted
        case .revoked: self = .revoked
        }
    }
}

private extension ConnectorActionApprovalSnapshot {
    init(_ state: ConnectorPerActionApprovalState) {
        switch state {
        case .notRequested: self = .notRequested
        case .pending: self = .pending
        case .approved: self = .approved
        case .denied: self = .denied
        }
    }
}

public enum SecretPresenceSnapshot: Equatable, Sendable {
    case absent
    case present(receiptID: UUID)
    case failed(receiptID: UUID)

    public var visibleLabel: String {
        switch self {
        case .absent: "Not provided"
        case .present: "Present"
        case .failed: "Needs attention"
        }
    }

    public var symbolName: String {
        switch self {
        case .absent: "key.horizontal"
        case .present: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// Secret values are structurally absent from immutable presentation data.
/// Only an opaque receipt may represent presence or a failed write.
public struct ChatSecretCardSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let purpose: String
    public let presence: SecretPresenceSnapshot

    public var accessibilityDescription: String {
        "Secret entry card. Status: \(presence.visibleLabel). The value is never shown."
    }

    public init(
        id: UUID,
        label: String,
        purpose: String,
        presence: SecretPresenceSnapshot
    ) {
        self.id = id
        self.label = label
        self.purpose = purpose
        self.presence = presence
    }

    public init(_ card: SecretEntryCard, purpose: String) {
        let presence: SecretPresenceSnapshot
        switch card.state {
        case .absent:
            presence = .absent
        case .present(let receiptID):
            presence = .present(receiptID: receiptID.rawValue)
        case .failed(let receiptID):
            presence = .failed(receiptID: receiptID.rawValue)
        }
        self.init(
            id: card.id.rawValue,
            label: card.label,
            purpose: purpose,
            presence: presence
        )
    }
}

public enum ChatMessagePartContentSnapshot: Equatable, Sendable {
    case text(String)
    case status(String)
    case attachment(ChatAttachmentSnapshot)
    case artifact(ChatArtifactSnapshot)
    case question(ChatQuestionCardSnapshot)
    case connectorSetup(ChatConnectorSetupCardSnapshot)
    case secret(ChatSecretCardSnapshot)
    case handoff(ChatHandoffTrailSnapshot)

    public var accessibilityDescription: String {
        switch self {
        case .text(let text), .status(let text):
            text
        case .attachment(let attachment):
            ["Attachment: \(attachment.displayName)", attachment.detail]
                .compactMap { $0 }
                .joined(separator: ". ")
        case .artifact(let artifact):
            ["Artifact: \(artifact.title)", artifact.detail]
                .compactMap { $0 }
                .joined(separator: ". ")
        case .question(let question):
            question.accessibilityDescription
        case .connectorSetup(let connector):
            connector.accessibilityDescription
        case .secret(let secret):
            secret.accessibilityDescription
        case .handoff(let handoff):
            handoff.accessibilityDescription
        }
    }
}

/// An ordered, typed presentation part. The part ID belongs to the message
/// stream; resource IDs remain independently stable inside attachment/artifact
/// snapshots.
public struct ChatMessagePartSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public let content: ChatMessagePartContentSnapshot

    public init(id: UUID, ordinal: Int, content: ChatMessagePartContentSnapshot) {
        self.id = id
        self.ordinal = ordinal
        self.content = content
    }
}

public enum ChatAuthorSnapshot: Equatable, Sendable {
    case user
    case teammate(TeammateIdentitySnapshot)
    case system(label: String)

    public var visibleName: String {
        switch self {
        case .user:
            "You"
        case .teammate(let identity):
            identity.name
        case .system(let label):
            label
        }
    }

    public var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    public var identity: TeammateIdentitySnapshot? {
        guard case .teammate(let identity) = self else { return nil }
        return identity
    }
}

public struct ChatMessageSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let author: ChatAuthorSnapshot
    public let body: String
    public let parts: [ChatMessagePartSnapshot]
    public let delivery: MessageDeliveryState
    public let streamState: ChatMessageStreamState
    public let timestamp: Date
    /// Explicit per-message provenance; nil retains legacy fixture rendering.
    public var deliveryNotice: String? = nil

    /// Names the container without flattening its readable text and actionable
    /// cards into a duplicate summary. The date comes from the stored message.
    func accessibilityGroupLabel(locale: Locale, timeZone: TimeZone) -> String {
        "\(author.visibleName). \(WorkspaceAccessibilityMetadata.timestamp(timestamp, locale: locale, timeZone: timeZone))"
    }

    public var authorName: String { author.visibleName }
    public var isFromUser: Bool { author.isUser }
    public var accessibilityBody: String {
        let description = parts
            .map(\.content.accessibilityDescription)
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        return description.isEmpty ? body : description
    }

    /// Message equality stays source-compatible for callers that previously
    /// knew only the message body. Part IDs are row-local streaming identities;
    /// the ordered ordinal/content payload is the user-visible value.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.author == rhs.author
            && lhs.body == rhs.body
            && lhs.delivery == rhs.delivery
            && lhs.streamState == rhs.streamState
            && lhs.timestamp == rhs.timestamp
            && lhs.deliveryNotice == rhs.deliveryNotice
            && lhs.parts.map { ($0.ordinal, $0.content) }
                .elementsEqual(
                    rhs.parts.map { ($0.ordinal, $0.content) },
                    by: { left, right in
                        left.0 == right.0 && left.1 == right.1
                    }
                )
    }

    public init(
        id: UUID,
        author: ChatAuthorSnapshot,
        body: String,
        parts: [ChatMessagePartSnapshot]? = nil,
        delivery: MessageDeliveryState,
        streamState: ChatMessageStreamState = .notStreaming,
        timestamp: Date
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.parts = Self.orderedUniqueParts(
            parts ?? Self.compatibilityParts(messageID: id, body: body)
        )
        self.delivery = delivery
        self.streamState = streamState
        self.timestamp = timestamp
    }

    public init(
        id: UUID,
        author: ChatAuthorSnapshot,
        parts: [ChatMessagePartSnapshot],
        delivery: MessageDeliveryState,
        streamState: ChatMessageStreamState = .notStreaming,
        timestamp: Date
    ) {
        let orderedParts = Self.orderedUniqueParts(parts)
        self.id = id
        self.author = author
        self.body = Self.plainTextBody(from: orderedParts)
        self.parts = orderedParts
        self.delivery = delivery
        self.streamState = streamState
        self.timestamp = timestamp
    }

    /// Compatibility initializer for fixture callers that do not yet provide a
    /// typed teammate identity. Non-user authors remain explicitly system-owned.
    public init(
        id: UUID,
        authorName: String,
        body: String,
        isFromUser: Bool,
        parts: [ChatMessagePartSnapshot]? = nil,
        delivery: MessageDeliveryState,
        streamState: ChatMessageStreamState = .notStreaming,
        timestamp: Date
    ) {
        self.init(
            id: id,
            author: isFromUser ? .user : .system(label: authorName),
            body: body,
            parts: parts,
            delivery: delivery,
            streamState: streamState,
            timestamp: timestamp
        )
    }

    fileprivate func replacing(
        parts: [ChatMessagePartSnapshot]? = nil,
        delivery: MessageDeliveryState? = nil,
        streamState: ChatMessageStreamState? = nil
    ) -> Self {
        let resolvedParts = parts ?? self.parts
        var replacement = Self(
            id: id,
            author: author,
            body: parts == nil ? body : Self.plainTextBody(from: resolvedParts),
            parts: resolvedParts,
            delivery: delivery ?? self.delivery,
            streamState: streamState ?? self.streamState,
            timestamp: timestamp
        )
        replacement.deliveryNotice = deliveryNotice
        return replacement
    }

    private static func compatibilityParts(
        messageID: UUID,
        body: String
    ) -> [ChatMessagePartSnapshot] {
        guard !body.isEmpty else { return [] }
        return [
            ChatMessagePartSnapshot(id: messageID, ordinal: 0, content: .text(body))
        ]
    }

    private static func orderedUniqueParts(
        _ parts: [ChatMessagePartSnapshot]
    ) -> [ChatMessagePartSnapshot] {
        var firstIndexByID: [UUID: Int] = [:]
        var latestByID: [UUID: ChatMessagePartSnapshot] = [:]
        for (index, part) in parts.enumerated() {
            if firstIndexByID[part.id] == nil {
                firstIndexByID[part.id] = index
            }
            latestByID[part.id] = part
        }
        return latestByID.values.sorted { left, right in
            if left.ordinal != right.ordinal { return left.ordinal < right.ordinal }
            return (firstIndexByID[left.id] ?? 0) < (firstIndexByID[right.id] ?? 0)
        }
    }

    private static func plainTextBody(from parts: [ChatMessagePartSnapshot]) -> String {
        parts.compactMap { part -> String? in
            switch part.content {
            case .text(let text), .status(let text): text
            case .attachment, .artifact, .question, .connectorSetup, .secret, .handoff: nil
            }
        }.joined(separator: "\n\n")
    }
}

/// Message-scoped observable state lets streaming and delivery updates redraw
/// only the affected transcript row.
@MainActor
public final class ChatMessageModel: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    @Published public private(set) var snapshot: ChatMessageSnapshot

    public init(snapshot: ChatMessageSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }

    public func update(_ snapshot: ChatMessageSnapshot) {
        precondition(snapshot.id == id, "A message row model cannot change message identity")
        self.snapshot = snapshot
    }

    /// Replaces exactly one stable part in this row while preserving both the
    /// message model and the part's stream identity/ordinal. This is the only
    /// mutation S2B cards need when an immutable service snapshot changes.
    @discardableResult
    public func replacePart(
        id partID: UUID,
        content: ChatMessagePartContentSnapshot
    ) -> Bool {
        guard let index = snapshot.parts.firstIndex(where: { $0.id == partID }) else {
            return false
        }
        var parts = snapshot.parts
        let existing = parts[index]
        parts[index] = ChatMessagePartSnapshot(
            id: existing.id,
            ordinal: existing.ordinal,
            content: content
        )
        snapshot = snapshot.replacing(parts: parts)
        return true
    }

    @discardableResult
    public func beginStreaming() -> Bool {
        guard snapshot.streamState == .notStreaming else { return false }
        snapshot = snapshot.replacing(streamState: .streaming)
        return true
    }

    /// Appends a delta to one stable text part in this row. Callers may provide
    /// the runtime's stable part ID; otherwise the latest text part is reused.
    /// Empty or post-terminal deltas are ignored.
    @discardableResult
    public func appendStreamingDelta(
        _ delta: String,
        partID requestedPartID: UUID? = nil,
        ordinal requestedOrdinal: Int? = nil
    ) -> Bool {
        guard snapshot.streamState == .streaming, !delta.isEmpty else { return false }

        var parts = snapshot.parts
        let targetIndex: Int?
        if let requestedPartID {
            targetIndex = parts.firstIndex(where: { $0.id == requestedPartID })
        } else {
            targetIndex = parts.indices.reversed().first(where: { index in
                if case .text = parts[index].content { return true }
                return false
            })
        }

        if let targetIndex {
            let target = parts[targetIndex]
            guard case .text(let existingText) = target.content else { return false }
            parts[targetIndex] = ChatMessagePartSnapshot(
                id: target.id,
                ordinal: target.ordinal,
                content: .text(existingText + delta)
            )
        } else {
            let partID = requestedPartID ?? defaultStreamingPartID(avoiding: parts)
            guard !parts.contains(where: { $0.id == partID }) else { return false }
            let ordinal = requestedOrdinal ?? ((parts.map(\.ordinal).max() ?? -1) + 1)
            parts.append(
                ChatMessagePartSnapshot(id: partID, ordinal: ordinal, content: .text(delta))
            )
        }

        snapshot = snapshot.replacing(parts: parts)
        return true
    }

    @discardableResult
    public func completeStreaming(
        delivery: MessageDeliveryState = .sent
    ) -> Bool {
        guard snapshot.streamState == .streaming else { return false }
        snapshot = snapshot.replacing(delivery: delivery, streamState: .complete)
        return true
    }

    @discardableResult
    public func failStreaming(reason: String) -> Bool {
        guard snapshot.streamState == .streaming else { return false }
        snapshot = snapshot.replacing(
            delivery: .failed(reason),
            streamState: .failed(reason)
        )
        return true
    }

    private func defaultStreamingPartID(
        avoiding parts: [ChatMessagePartSnapshot]
    ) -> UUID {
        guard parts.contains(where: { $0.id == id }) else { return id }
        var bytes = id.uuid
        bytes.0 ^= 0x80
        return UUID(uuid: bytes)
    }
}

public enum ConversationHistoryLoadState: Equatable, Sendable {
    case idle
    case loading
    case failed(String)

    public var failureReason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }
}

public struct ConversationMessagePageSnapshot: Equatable, Sendable {
    public let messages: [ChatMessageSnapshot]
    public let hasEarlierMessages: Bool

    public init(messages: [ChatMessageSnapshot], hasEarlierMessages: Bool) {
        self.messages = messages
        self.hasEarlierMessages = hasEarlierMessages
    }
}

@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var rowModels: [TeammateRowModel]
    @Published public var selection: UUID? {
        didSet {
            if selection != oldValue { cancelCreationReveal() }
        }
    }
    @Published public private(set) var isOrderSaving = false
    @Published public private(set) var orderError: String?
    @Published private(set) var creationRevealID: UUID?
    @Published private(set) var sidebarDrag: BotSidebarDragSession?
    @Published private(set) var sidebarInsertion: BotSidebarInsertion?

    private var orderMoveHandler: (@MainActor ([UUID], [UUID]) -> Void)?

    public var canReorder: Bool { orderMoveHandler != nil && !isOrderSaving && rowModels.count > 1 }

    public var rows: [TeammateRowSnapshot] {
        rowModels.map(\.snapshot)
    }

    public init(rows: [TeammateRowSnapshot] = [], selection: UUID? = nil) {
        self.rowModels = rows.map(TeammateRowModel.init(snapshot:))
        self.selection = selection
    }

    public func replace(rows: [TeammateRowSnapshot]) {
        let existing = Dictionary(uniqueKeysWithValues: rowModels.map { ($0.id, $0) })
        let replacement = rows.map { snapshot in
            if let row = existing[snapshot.id] {
                row.update(snapshot)
                return row
            }
            return TeammateRowModel(snapshot: snapshot)
        }
        if replacement.map(\.id) != rowModels.map(\.id) {
            cancelSidebarDrag()
            rowModels = replacement
        }
        if let selection, !rows.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    public func update(_ row: TeammateRowSnapshot) {
        guard let model = rowModels.first(where: { $0.id == row.id }) else {
            cancelSidebarDrag()
            rowModels.append(TeammateRowModel(snapshot: row))
            return
        }
        model.update(row)
    }

    /// Only explicit creation/hiring asks the List to reveal a new selected row.
    /// Roster refreshes, recency, restores and reorders never request scrolling.
    func requestCreationReveal(_ id: UUID) {
        guard selection == id, rowModels.first?.id == id else { return }
        creationRevealID = id
    }

    func completeCreationReveal(_ id: UUID) {
        guard creationRevealID == id else { return }
        cancelCreationReveal()
    }

    func cancelCreationReveal() {
        guard creationRevealID != nil else { return }
        creationRevealID = nil
    }

    public func configureOrderMoves(handler: (@MainActor ([UUID], [UUID]) -> Void)?) {
        orderMoveHandler = handler
        cancelSidebarDrag()
        objectWillChange.send()
    }

    public func setOrderSaveState(isSaving: Bool, error: String? = nil) {
        isOrderSaving = isSaving
        orderError = error
        if isSaving { cancelSidebarDrag() }
    }

    /// Only a permutation of the complete, unchanged active roster may reach
    /// persistence. The confirmed collection and selection remain untouched.
    @discardableResult
    public func requestOrderMove(ids: [UUID], fromSnapshot sourceIDs: [UUID]) -> Bool {
        guard canReorder, let orderMoveHandler,
              sourceIDs == rowModels.map(\.id),
              ids.count == sourceIDs.count, Set(ids).count == ids.count,
              Set(ids) == Set(sourceIDs), ids != sourceIDs else { return false }
        orderMoveHandler(ids, sourceIDs)
        return true
    }

    @discardableResult
    func requestRelativeOrderMove(id: UUID, offset: Int) -> Bool {
        let ids = rowModels.map(\.id)
        guard let index = ids.firstIndex(of: id), offset == -1 || offset == 1,
              ids.indices.contains(index + offset) else { return false }
        var reordered = ids
        reordered.swapAt(index, index + offset)
        return requestOrderMove(ids: reordered, fromSnapshot: ids)
    }

    func beginSidebarDrag(id: UUID) -> BotSidebarDragSession? {
        let ids = rowModels.map(\.id)
        guard canReorder, ids.contains(id), Set(ids).count == ids.count else { return nil }
        let session = BotSidebarDragSession(token: UUID(), sourceID: id, sourceIDs: ids)
        sidebarDrag = session
        sidebarInsertion = nil
        return session
    }

    func updateSidebarInsertion(_ insertion: BotSidebarInsertion?) {
        if sidebarInsertion != insertion { sidebarInsertion = insertion }
    }

    func cancelSidebarDrag() {
        if sidebarDrag != nil { sidebarDrag = nil }
        if sidebarInsertion != nil { sidebarInsertion = nil }
    }
}

@MainActor
public final class ConversationModel: ObservableObject {
    public private(set) var isShuttingDown = false
    private var didFinishShutdown = false
    private var acceptedSubmissions: [UUID: Task<Void, Never>] = [:]
    public var hasPendingSubmissions: Bool { !acceptedSubmissions.isEmpty }

    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        historyRequestGeneration += 1
        inputAvailability = .unavailable(reason: "Closing OpenBots. Saving available local changes briefly…")
    }

    public func settleForShutdown() async -> Bool {
        for task in Array(acceptedSubmissions.values) {
            if Task.isCancelled || didFinishShutdown { return false }
            await task.value
        }
        return !Task.isCancelled && !didFinishShutdown && acceptedSubmissions.isEmpty
    }

    public func finishShutdown() {
        beginShutdown()
        didFinishShutdown = true
        for task in acceptedSubmissions.values { task.cancel() }
        acceptedSubmissions.removeAll()
        historyRequestGeneration += 1
    }
    public typealias Submission = @Sendable (UUID, UUID, String) async -> Void
    public typealias BeforeSubmission = @MainActor (_ messageID: UUID, _ conversationID: UUID, _ rawText: String) -> Bool
    public typealias LatestPageLoader = @MainActor () async -> Void
    public typealias EarlierPageLoader = @Sendable (
        _ conversationID: UUID,
        _ earliestLoadedMessageID: UUID?
    ) async throws -> ConversationMessagePageSnapshot

    public static let defaultUnavailableReason =
        "Claude runtime is not configured in this preview."

    @Published public private(set) var conversationID: UUID?
    @Published public private(set) var title: String
    @Published public private(set) var messageRows: [ChatMessageModel]
    @Published public var composerText: String
    @Published public private(set) var inputAvailability: ConversationInputAvailability
    @Published public private(set) var draftSubmissionAllowed = true
    @Published public private(set) var attachmentSubmissionAllowed = true
    @Published public private(set) var hasAttachmentContent = false
    @Published public private(set) var textReplyPhase: ClaudeTextReplyPhase?
    @Published public private(set) var textReplyContextDisclosure: ClaudeContextDisclosure?
    public let textRepliesEnabled: Bool
    private let stopTextReply: (@MainActor () -> Void)?
    private let saveLocally: Submission?
    @Published public private(set) var hasEarlierMessages: Bool
    @Published public private(set) var historyLoadState: ConversationHistoryLoadState
    @Published public private(set) var searchFocus: TranscriptSearchFocus?
    @Published public private(set) var latestFocus: TranscriptSearchFocus?
    @Published public private(set) var searchNavigationNotice: String?
    @Published public private(set) var isReturningToLatest = false
    @Published public private(set) var isShowingLatestPlaceholder = false
    public var isViewingSearchResult: Bool { searchFocus != nil }
    public var needsLatestPage: Bool { isViewingSearchResult || isShowingLatestPlaceholder }

    /// Truthful copy for the currently injected delivery adapter. A local
    /// fixture must not borrow production runtime language merely because both
    /// use the same native composer.
    public let readyDeliveryDescription: String
    public let isLocalOnly: Bool
    public var submissionActionTitle: String { isLocalOnly ? "Save Message" : "Send" }

    private let submit: Submission?
    private let beforeSubmission: BeforeSubmission?
    private let beforeLocalSubmission: BeforeSubmission?
    private let earlierPageLoader: EarlierPageLoader?
    private let latestPageLoader: LatestPageLoader?
    private var historyRequestGeneration = 0

    public var messages: [ChatMessageSnapshot] {
        messageRows.map(\.snapshot)
    }

    public var canSend: Bool {
        guard !isShuttingDown, inputAvailability == .ready, submit != nil, draftSubmissionAllowed,
              attachmentSubmissionAllowed else { return false }
        if textRepliesEnabled && (hasAttachmentContent || textReplyPhase?.isBusy == true) { return false }
        return hasAttachmentContent || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canSaveLocally: Bool {
        !isShuttingDown && inputAvailability == .ready && saveLocally != nil
            && draftSubmissionAllowed && attachmentSubmissionAllowed
            && textReplyPhase?.isBusy != true
            && (hasAttachmentContent || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public func setTextReplyPhase(_ phase: ClaudeTextReplyPhase?) { textReplyPhase = phase }
    public func setTextReplyContextDisclosure(_ disclosure: ClaudeContextDisclosure?) {
        textReplyContextDisclosure = disclosure
    }
    public func stopCurrentTextReply() { stopTextReply?() }
    public func saveCurrentTextLocally() { submitCurrentText(locally: true) }

    public init(
        conversationID: UUID? = nil,
        title: String = "Conversation",
        messages: [ChatMessageSnapshot] = [],
        composerText: String = "",
        readyDeliveryDescription: String =
            "Messages appear immediately; the configured local adapter handles delivery.",
        isLocalOnly: Bool = false,
        textRepliesEnabled: Bool = false,
        stopTextReply: (@MainActor () -> Void)? = nil,
        saveLocally: Submission? = nil,
        inputAvailability: ConversationInputAvailability? = nil,
        submit: Submission? = nil,
        beforeSubmission: BeforeSubmission? = nil,
        beforeLocalSubmission: BeforeSubmission? = nil,
        hasEarlierMessages: Bool = false,
        earlierPageLoader: EarlierPageLoader? = nil,
        latestPageLoader: LatestPageLoader? = nil
    ) {
        self.conversationID = conversationID
        self.title = title
        self.messageRows = messages.map(ChatMessageModel.init(snapshot:))
        self.composerText = composerText
        self.readyDeliveryDescription = readyDeliveryDescription
        self.isLocalOnly = isLocalOnly
        self.textRepliesEnabled = textRepliesEnabled
        self.stopTextReply = stopTextReply
        self.saveLocally = saveLocally
        self.submit = submit
        self.beforeSubmission = beforeSubmission
        self.beforeLocalSubmission = beforeLocalSubmission
        self.hasEarlierMessages = hasEarlierMessages
        self.historyLoadState = .idle
        self.earlierPageLoader = earlierPageLoader
        self.latestPageLoader = latestPageLoader
        if submit == nil {
            self.inputAvailability = .unavailable(reason: Self.defaultUnavailableReason)
        } else {
            self.inputAvailability = inputAvailability ?? .ready
        }
    }

    public func show(
        conversationID: UUID?,
        title: String,
        messages: [ChatMessageSnapshot],
        hasEarlierMessages: Bool = false
    ) {
        let preservesRows = self.conversationID == conversationID
        historyRequestGeneration += 1
        self.conversationID = conversationID
        self.title = title
        self.messageRows = reconciledRows(messages, reusingExistingRows: preservesRows)
        self.hasEarlierMessages = hasEarlierMessages
        self.historyLoadState = .idle
        searchFocus = nil
        latestFocus = nil
        isShowingLatestPlaceholder = false
        searchNavigationNotice = nil
    }

    public func focusSearchMessage(_ messageID: UUID) {
        guard let conversationID, messageRows.contains(where: { $0.id == messageID }) else { return }
        searchFocus = TranscriptSearchFocus(conversationID: conversationID, messageID: messageID)
        latestFocus = nil
        searchNavigationNotice = nil
    }

    public func setSearchNavigationNotice(_ text: String) { searchNavigationNotice = text }

    public func focusLatestMessage() {
        guard let conversationID, let lastID = messageRows.last?.id, !isViewingSearchResult else { return }
        latestFocus = TranscriptSearchFocus(conversationID: conversationID, messageID: lastID)
    }

    public func requestLatestMessages() {
        guard !isShuttingDown, needsLatestPage, !isReturningToLatest, let latestPageLoader else { return }
        isReturningToLatest = true
        Task { [weak self] in
            await latestPageLoader()
            if self?.isShuttingDown == false { self?.isReturningToLatest = false }
        }
    }

    public func setInputAvailability(_ availability: ConversationInputAvailability) {
        guard !isShuttingDown else { return }
        inputAvailability = submit == nil
            ? .unavailable(reason: Self.defaultUnavailableReason)
            : availability
    }

    /// Prevents another local send while draft authority is unresolved without
    /// disabling the composer or changing runtime input availability.
    public func setDraftSubmissionAllowed(_ allowed: Bool) {
        guard draftSubmissionAllowed != allowed else { return }
        draftSubmissionAllowed = allowed
    }

    /// A profile rename changes the current heading, not historical authors,
    /// row identities, scroll state or an in-progress composer draft.
    public func renameTitle(_ title: String) {
        guard self.title != title else { return }
        self.title = title
    }

    public func setAttachmentSubmission(allowed: Bool, hasContent: Bool) {
        if attachmentSubmissionAllowed != allowed { attachmentSubmissionAllowed = allowed }
        if hasAttachmentContent != hasContent { hasAttachmentContent = hasContent }
    }

    /// The pending bubble is inserted synchronously on the main actor. Durable
    /// persistence and runtime delivery occur through the injected async seam.
    public func sendCurrentText(now: Date = Date(), messageID: UUID = UUID()) {
        submitCurrentText(now: now, messageID: messageID, locally: false)
    }

    private func submitCurrentText(now: Date = Date(), messageID: UUID = UUID(), locally: Bool) {
        guard !isShuttingDown else { return }
        guard locally ? canSaveLocally : canSend else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !text.isEmpty || hasAttachmentContent,
            inputAvailability == .ready,
            draftSubmissionAllowed,
            attachmentSubmissionAllowed,
            let conversationID,
            let submit = locally ? saveLocally : submit
        else { return }
        let prepare = locally ? beforeLocalSubmission : beforeSubmission
        guard prepare?(messageID, conversationID, composerText) ?? true else { return }
        if isViewingSearchResult {
            // An own-send leaves historical browsing immediately. Until the
            // newest page arrives, show only the current pending message with
            // an explicit loading/recovery boundary, never a false sequence
            // from an old saved result straight into a new message.
            historyRequestGeneration += 1
            searchFocus = nil
            latestFocus = nil
            messageRows = []
            hasEarlierMessages = false
            historyLoadState = .idle
            isShowingLatestPlaceholder = true
        }
        composerText = ""
        var pending = ChatMessageSnapshot(
            id: messageID, author: .user,
            body: text.isEmpty ? "Saving attachment…" : text,
            delivery: .pending, timestamp: now
        )
        if locally { pending.deliveryNotice = "Saving locally…" }
        messageRows.append(ChatMessageModel(snapshot: pending))
        // Capture the target synchronously with the pending row. A fast sidebar
        // switch cannot redirect this message to a different conversation.
        acceptedSubmissions[messageID] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await submit(messageID, conversationID, text)
            self?.acceptedSubmissions[messageID] = nil
        }
    }

    public func replaceMessage(_ message: ChatMessageSnapshot) {
        guard !didFinishShutdown else { return }
        guard let row = messageRows.first(where: { $0.id == message.id }) else {
            messageRows.append(ChatMessageModel(snapshot: message))
            return
        }
        row.update(message)
    }

    /// Prepends one older page without rebuilding any already-visible row.
    /// Duplicate IDs are collapsed deterministically at their first position;
    /// the latest duplicate snapshot updates the reused row.
    public func prependEarlierMessages(
        _ messages: [ChatMessageSnapshot],
        hasEarlierMessages: Bool
    ) {
        let uniqueMessages = Self.orderedUniqueMessages(messages)
        let existingByID = Dictionary(uniqueKeysWithValues: messageRows.map { ($0.id, $0) })

        for message in uniqueMessages {
            existingByID[message.id]?.update(message)
        }
        let newRows = uniqueMessages.compactMap { message -> ChatMessageModel? in
            guard existingByID[message.id] == nil else { return nil }
            return ChatMessageModel(snapshot: message)
        }
        if !newRows.isEmpty {
            messageRows = newRows + messageRows
        }
        self.hasEarlierMessages = hasEarlierMessages
        historyLoadState = .idle
    }

    public func loadEarlierMessages() {
        guard !isShuttingDown else { return }
        guard hasEarlierMessages, historyLoadState != .loading else { return }
        guard let conversationID, let earlierPageLoader else {
            historyLoadState = .failed(
                "Earlier messages are not connected in this preview."
            )
            return
        }

        historyRequestGeneration += 1
        let generation = historyRequestGeneration
        let earliestID = messageRows.first?.id
        historyLoadState = .loading

        Task { [weak self] in
            do {
                let page = try await earlierPageLoader(conversationID, earliestID)
                guard let self, self.historyRequestGeneration == generation,
                      self.conversationID == conversationID else { return }
                self.prependEarlierMessages(
                    page.messages,
                    hasEarlierMessages: page.hasEarlierMessages
                )
            } catch {
                guard let self, self.historyRequestGeneration == generation,
                      self.conversationID == conversationID else { return }
                self.historyLoadState = .failed(
                    "The local history service did not complete. Try again."
                )
            }
        }
    }

    @discardableResult
    public func beginStreamingMessage(_ message: ChatMessageSnapshot) -> ChatMessageModel {
        let row: ChatMessageModel
        if let existing = messageRows.first(where: { $0.id == message.id }) {
            existing.update(message)
            row = existing
        } else {
            row = ChatMessageModel(snapshot: message)
            messageRows.append(row)
        }
        _ = row.beginStreaming()
        return row
    }

    @discardableResult
    public func appendStreamingDelta(
        messageID: UUID,
        delta: String,
        partID: UUID? = nil,
        ordinal: Int? = nil
    ) -> Bool {
        messageRows.first(where: { $0.id == messageID })?.appendStreamingDelta(
            delta,
            partID: partID,
            ordinal: ordinal
        ) ?? false
    }

    @discardableResult
    public func completeStreamingMessage(
        id: UUID,
        delivery: MessageDeliveryState = .sent
    ) -> Bool {
        messageRows.first(where: { $0.id == id })?.completeStreaming(
            delivery: delivery
        ) ?? false
    }

    @discardableResult
    public func failStreamingMessage(id: UUID, reason: String) -> Bool {
        messageRows.first(where: { $0.id == id })?.failStreaming(reason: reason) ?? false
    }

    private func reconciledRows(
        _ messages: [ChatMessageSnapshot],
        reusingExistingRows: Bool
    ) -> [ChatMessageModel] {
        let uniqueMessages = Self.orderedUniqueMessages(messages)
        guard reusingExistingRows else {
            return uniqueMessages.map(ChatMessageModel.init(snapshot:))
        }
        let existingByID = Dictionary(uniqueKeysWithValues: messageRows.map { ($0.id, $0) })
        return uniqueMessages.map { message in
            if let existing = existingByID[message.id] {
                existing.update(message)
                return existing
            }
            return ChatMessageModel(snapshot: message)
        }
    }

    private static func orderedUniqueMessages(
        _ messages: [ChatMessageSnapshot]
    ) -> [ChatMessageSnapshot] {
        var firstIndexByID: [UUID: Int] = [:]
        var latestByID: [UUID: ChatMessageSnapshot] = [:]
        for (index, message) in messages.enumerated() {
            if firstIndexByID[message.id] == nil {
                firstIndexByID[message.id] = index
            }
            latestByID[message.id] = message
        }
        return latestByID.values.sorted {
            (firstIndexByID[$0.id] ?? 0) < (firstIndexByID[$1.id] ?? 0)
        }
    }
}
