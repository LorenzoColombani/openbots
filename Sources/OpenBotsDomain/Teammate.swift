import Foundation

public struct TeammateProfile: Codable, Equatable, Sendable {
    public let displayName: String
    public let title: String?
    public let role: String
    public let detailedInstructions: String?
    public let revision: UInt64

    public init(
        displayName: String,
        title: String? = nil,
        role: String,
        detailedInstructions: String? = nil,
        revision: UInt64 = 1
    ) throws {
        guard revision > 0 else {
            throw DomainValidationError.invalid(field: "profile revision", reason: "must be positive")
        }
        self.displayName = try DomainText.required(displayName, field: "teammate name", maximum: 80)
        self.title = try DomainText.optional(title, field: "teammate title", maximum: 120)
        self.role = try DomainText.required(role, field: "teammate role", maximum: 240)
        self.detailedInstructions = try DomainText.optional(
            detailedInstructions,
            field: "teammate instructions",
            maximum: 20_000
        )
        self.revision = revision
    }

    public func revised(
        displayName: String? = nil,
        title: String?? = nil,
        role: String? = nil,
        detailedInstructions: String?? = nil
    ) throws -> Self {
        guard revision < UInt64.max else {
            throw DomainValidationError.invalid(field: "profile revision", reason: "cannot advance further")
        }
        return try Self(
            displayName: displayName ?? self.displayName,
            title: title ?? self.title,
            role: role ?? self.role,
            detailedInstructions: detailedInstructions ?? self.detailedInstructions,
            revision: revision + 1
        )
    }
}

public enum AppearanceMode: String, Codable, Sendable {
    case creature
    case photo
}

/// Explicit, app-bundled models. Kept separate from the versioned generated
/// grammar so adding a model never changes an existing seed's fallback.
public enum BuiltInAvatar: String, Codable, CaseIterable, Sendable {
    case pillow, fin, kite, bean, guide

    public var displayName: String {
        switch self {
        case .pillow: "Pillow"
        case .fin: "Yogurt"
        case .kite: "Kite"
        case .bean: "Bean"
        case .guide: "Canobi"
        }
    }

    /// Used only while allocating a NEW identity, never while loading a saved
    /// appearance. Five slots keep the original generated family eligible.
    public static func allocatedForNewIdentity(seed: UInt64) -> Self? {
        let slot = Int(seed % 10)
        return slot < allCases.count ? allCases[slot] : nil
    }
}

public struct AgentAppearance: Codable, Equatable, Sendable {
    public let mode: AppearanceMode
    public let grammarVersion: UInt16
    public let deterministicSeed: UInt64
    public let silhouette: String
    public let paletteToken: String
    public let eyeDialect: String
    public let nonColorIdentityCue: String
    public let accessibleIdentityDescription: String
    public let profileAssetID: ProfileAssetID?
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
        profileAssetID: ProfileAssetID? = nil,
        builtInAvatarID: String? = nil,
        revision: UInt64 = 1
    ) throws {
        guard grammarVersion > 0 else {
            throw DomainValidationError.invalid(field: "appearance grammar version", reason: "must be positive")
        }
        guard revision > 0 else {
            throw DomainValidationError.invalid(field: "appearance revision", reason: "must be positive")
        }
        guard mode == .photo || profileAssetID == nil else {
            throw DomainValidationError.invalid(
                field: "profile asset",
                reason: "creature appearances do not reference a photo"
            )
        }
        guard mode == .creature || profileAssetID != nil else {
            throw DomainValidationError.invalid(
                field: "profile asset",
                reason: "photo appearances require an immutable profile asset"
            )
        }
        self.mode = mode
        self.grammarVersion = grammarVersion
        self.deterministicSeed = deterministicSeed
        self.silhouette = try DomainText.required(silhouette, field: "silhouette", maximum: 80)
        self.paletteToken = try DomainText.required(paletteToken, field: "palette token", maximum: 80)
        self.eyeDialect = try DomainText.required(eyeDialect, field: "eye dialect", maximum: 80)
        self.nonColorIdentityCue = try DomainText.required(
            nonColorIdentityCue,
            field: "non-color identity cue",
            maximum: 120
        )
        self.accessibleIdentityDescription = try DomainText.required(
            accessibleIdentityDescription,
            field: "accessible identity description",
            maximum: 240
        )
        self.profileAssetID = profileAssetID
        self.builtInAvatarID = try DomainText.optional(builtInAvatarID, field: "built-in avatar", maximum: 80)
        self.revision = revision
    }
}

public enum TeammateLifecycle: String, Codable, Sendable {
    case active
    case archivePendingRunResolution
    case archived
}

public enum TeammateLifecycleEvent: Equatable, Sendable {
    case requestArchive(hasActiveRun: Bool)
    case activeRunResolved
    case restore
}

public enum LifecycleTransitionError: Error, Equatable, Sendable {
    case illegalTransition(entity: String, state: String, event: String)
}

public extension TeammateLifecycle {
    func applying(_ event: TeammateLifecycleEvent) throws -> Self {
        switch (self, event) {
        case let (.active, .requestArchive(hasActiveRun)):
            hasActiveRun ? .archivePendingRunResolution : .archived
        case (.archivePendingRunResolution, .activeRunResolved):
            .archived
        case (.archived, .restore):
            .active
        default:
            throw LifecycleTransitionError.illegalTransition(
                entity: "teammate",
                state: rawValue,
                event: String(describing: event)
            )
        }
    }
}

public enum NotificationPreference: String, Codable, Sendable {
    case inherit
    case disabled
    case enabled
}

public struct Teammate: Codable, Equatable, Sendable, Identifiable {
    public let id: TeammateID
    public var profile: TeammateProfile
    public var appearance: AgentAppearance
    public var lifecycle: TeammateLifecycle
    public var isPinned: Bool
    public var isHidden: Bool
    public var notificationPreference: NotificationPreference
    /// The user's saved next-run choice. Unknown/retired values remain exact;
    /// validation belongs to explicit selection, never loading existing records.
    public var claudeModel: String?
    /// Nil retains CLI-default effort. Unknown saved values remain exact.
    public var claudeEffort: String?
    /// Nil keeps the model's normal context behavior; explicit default resets it.
    public var claudeContextWindow: String?
    public let createdAt: Date
    public var updatedAt: Date

    /// Preserve the original fixed Sonnet launch for records without a choice.
    public var requestedClaudeModel: String { claudeModel ?? "sonnet" }
    public var requestedClaudeEffort: String { claudeEffort ?? "default" }
    public var requestedClaudeContextWindow: String { claudeContextWindow ?? "default" }

    public init(
        id: TeammateID,
        profile: TeammateProfile,
        appearance: AgentAppearance,
        lifecycle: TeammateLifecycle = .active,
        isPinned: Bool = false,
        isHidden: Bool = false,
        notificationPreference: NotificationPreference = .inherit,
        claudeModel: String? = nil,
        claudeEffort: String? = nil,
        claudeContextWindow: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(
                field: "teammate timestamps",
                reason: "updatedAt cannot precede createdAt"
            )
        }
        self.id = id
        self.profile = profile
        self.appearance = appearance
        self.lifecycle = lifecycle
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.notificationPreference = notificationPreference
        self.claudeModel = claudeModel
        self.claudeEffort = claudeEffort
        self.claudeContextWindow = claudeContextWindow
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Official Claude Code effort support shared by picker and launch validation.
/// "default" is an app selection that omits the CLI flag, not an effort value.
public enum ClaudeEffortPolicy {
    public static func supportedValues(for model: String) -> [String] {
        switch model {
        case "sonnet", "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-opus-4-7":
            ["low", "medium", "high", "xhigh", "max"]
        case "claude-opus-4-6", "claude-sonnet-4-6":
            ["low", "medium", "high", "max"]
        default:
            []
        }
    }

    public static func defaultValue(for model: String) -> String? {
        if model == "claude-opus-4-7" { return "xhigh" }
        return supportedValues(for: model).isEmpty ? nil : "high"
    }
}

/// Context selections describe CLI budgeting, never a physical model variant.
public enum ClaudeContextWindowPolicy {
    public static func supportedValues(for model: String) -> [String] {
        switch model {
        case "sonnet", "claude-fable-5", "claude-sonnet-5", "claude-opus-5", "claude-opus-4-8",
             "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6":
            ["default", "standard", "long"]
        case "claude-opus-4-5-20251101", "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001":
            // A saved standard cap remains compatible, though redundant at 200K.
            ["default", "standard"]
        default:
            ["default"]
        }
    }

    public static func defaultTokenLimit(for model: String) -> Int? {
        switch model {
        case "sonnet", "claude-fable-5", "claude-sonnet-5", "claude-opus-5", "claude-opus-4-8",
             "claude-opus-4-7", "claude-opus-4-6":
            1_000_000
        case "claude-sonnet-4-6", "claude-opus-4-5-20251101", "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001":
            200_000
        default:
            nil
        }
    }
}

public enum CharacterSemanticState: String, Codable, CaseIterable, Sendable {
    case idle
    case thinkingOrWorking
    case speaking
    case waitingForUser
    case errorOrAttention
}
