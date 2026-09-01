import Foundation
import OpenBotsDomain

public struct QuickTeammateDraft: Equatable, Sendable {
    public let displayName: String
    public let role: String

    public init(displayName: String, role: String) {
        self.displayName = displayName
        self.role = role
    }
}

/// Canonical choices from the existing creature grammar. These strings are
/// presentation tokens, never asset names or paths.
public struct TeammateCreatureDraft: Equatable, Sendable {
    public static let silhouettes = ["round", "sprout", "drop", "cloud"]
    public static let paletteTokens = ["sky", "mint", "violet", "amber", "coral"]
    public static let eyeDialects = ["round", "bright", "calm", "wide"]
    public static let nonColorIdentityCues = ["single crest", "two antennae", "leaf ears", "soft crown"]

    public let silhouette: String
    public let paletteToken: String
    public let eyeDialect: String
    public let nonColorIdentityCue: String

    public init(
        silhouette: String,
        paletteToken: String,
        eyeDialect: String,
        nonColorIdentityCue: String
    ) {
        self.silhouette = silhouette
        self.paletteToken = paletteToken
        self.eyeDialect = eyeDialect
        self.nonColorIdentityCue = nonColorIdentityCue
    }

    fileprivate func revising(_ appearance: AgentAppearance) throws -> AgentAppearance {
        for (value, choices, field) in [
            (silhouette, Self.silhouettes, "silhouette"),
            (paletteToken, Self.paletteTokens, "palette token"),
            (eyeDialect, Self.eyeDialects, "eye dialect"),
            (nonColorIdentityCue, Self.nonColorIdentityCues, "non-color identity cue")
        ] {
            guard choices.contains(value) else {
                throw DomainValidationError.invalid(field: field, reason: "unsupported creature choice")
            }
        }
        guard appearance.revision < UInt64.max else {
            throw DomainValidationError.invalid(field: "appearance revision", reason: "cannot advance further")
        }
        // Switching from a photo drops only its reference. This service never
        // imports, opens, modifies, or deletes the immutable asset itself.
        return try AgentAppearance(
            mode: .creature,
            grammarVersion: appearance.grammarVersion,
            deterministicSeed: appearance.deterministicSeed,
            silhouette: silhouette,
            paletteToken: paletteToken,
            eyeDialect: eyeDialect,
            nonColorIdentityCue: nonColorIdentityCue,
            accessibleIdentityDescription: "\(silhouette.capitalized) creature with \(eyeDialect) eyes and \(nonColorIdentityCue)",
            revision: appearance.revision + 1
        )
    }
}

/// A complete editable profile, with an optional explicit creature or photo
/// change. Nil optional text clears that field; both appearance choices nil
/// preserves all appearance data, including any existing photo reference.
public struct TeammateProfileEditDraft: Equatable, Sendable {
    public let displayName: String
    public let title: String?
    public let role: String
    public let detailedInstructions: String?
    public let creature: TeammateCreatureDraft?
    public let photoAssetID: ProfileAssetID?
    public let builtInAvatar: BuiltInAvatar?
    /// Nil preserves the saved choice, including unknown or retired values.
    public let claudeModel: String?
    /// Nil preserves the saved choice; "default" explicitly resets effort.
    public let claudeEffort: String?
    /// Nil preserves the saved choice; "default" explicitly resets context.
    public let claudeContextWindow: String?

    public init(
        displayName: String,
        title: String? = nil,
        role: String,
        detailedInstructions: String? = nil,
        creature: TeammateCreatureDraft? = nil,
        photoAssetID: ProfileAssetID? = nil,
        builtInAvatar: BuiltInAvatar? = nil,
        claudeModel: String? = nil,
        claudeEffort: String? = nil,
        claudeContextWindow: String? = nil
    ) {
        self.displayName = displayName
        self.title = title
        self.role = role
        self.detailedInstructions = detailedInstructions
        self.creature = creature
        self.photoAssetID = photoAssetID
        self.builtInAvatar = builtInAvatar
        self.claudeModel = claudeModel
        self.claudeEffort = claudeEffort
        self.claudeContextWindow = claudeContextWindow
    }
}

public protocol TeammateProfileEditing: Sendable {
    func loadProfile(teammateID: TeammateID) async throws -> Teammate
    func saveProfile(
        teammateID: TeammateID,
        expectedRevision: UInt64,
        draft: TeammateProfileEditDraft
    ) async throws -> Teammate
}

/// Owns only teammate profile creation, editing and listing. Runtime sessions, grants,
/// projects, conversations, and memory are deliberately coordinated elsewhere.
public actor TeammateProfileService: TeammateProfileEditing {
    private let repository: any TeammateRepository
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator
    private let photoValidator: (any ProfilePhotoValidating)?

    public init(
        repository: any TeammateRepository,
        clock: any OpenBotsClock = SystemClock(),
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator(),
        photoValidator: (any ProfilePhotoValidating)? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.photoValidator = photoValidator
    }

    public func createQuickTeammate(_ draft: QuickTeammateDraft) async throws -> Teammate {
        let id = TeammateID(uuidGenerator.next())
        let now = clock.now()
        let appearance = try Self.defaultAppearance(for: id)
        let teammate = try Teammate(
            id: id,
            profile: TeammateProfile(displayName: draft.displayName, role: draft.role),
            appearance: appearance,
            createdAt: now,
            updatedAt: now
        )
        try await repository.insert(teammate)
        return teammate
    }

    public func activeTeammates() async throws -> [Teammate] {
        try await repository.listTeammates(includingArchived: false)
    }

    public func loadProfile(teammateID: TeammateID) async throws -> Teammate {
        guard let teammate = try await repository.teammate(id: teammateID) else {
            throw RepositoryError.notFound(entity: "teammate", id: teammateID.persistedValue)
        }
        return teammate
    }

    public func saveProfile(
        teammateID: TeammateID,
        expectedRevision: UInt64,
        draft: TeammateProfileEditDraft
    ) async throws -> Teammate {
        let appearanceChoiceCount = [draft.creature != nil, draft.photoAssetID != nil, draft.builtInAvatar != nil]
            .filter { $0 }.count
        guard appearanceChoiceCount <= 1 else {
            throw ProfilePhotoServiceError.conflictingAppearanceChoices
        }
        var teammate = try await loadProfile(teammateID: teammateID)
        guard teammate.profile.revision == expectedRevision else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammateID.persistedValue)
        }
        if let model = draft.claudeModel {
            try Self.validateSelectionToken(model, field: "Claude model")
            teammate.claudeModel = model
        }
        if let effort = draft.claudeEffort {
            try Self.validateSelectionToken(effort, field: "Claude effort")
            teammate.claudeEffort = effort
        }
        if let context = draft.claudeContextWindow {
            try Self.validateSelectionToken(context, field: "Claude context window")
            teammate.claudeContextWindow = context
        }
        teammate.profile = try teammate.profile.revised(
            displayName: draft.displayName,
            title: .some(draft.title),
            role: draft.role,
            detailedInstructions: .some(draft.detailedInstructions)
        )
        if let avatar = draft.builtInAvatar {
            let appearance = teammate.appearance
            guard appearance.revision < UInt64.max else {
                throw DomainValidationError.invalid(field: "appearance revision", reason: "cannot advance further")
            }
            teammate.appearance = try AgentAppearance(
                mode: .creature, grammarVersion: appearance.grammarVersion,
                deterministicSeed: appearance.deterministicSeed, silhouette: appearance.silhouette,
                paletteToken: appearance.paletteToken, eyeDialect: appearance.eyeDialect,
                nonColorIdentityCue: appearance.nonColorIdentityCue,
                accessibleIdentityDescription: appearance.accessibleIdentityDescription,
                builtInAvatarID: avatar.rawValue, revision: appearance.revision + 1
            )
        } else if let creature = draft.creature {
            teammate.appearance = try creature.revising(teammate.appearance)
        } else if let photoID = draft.photoAssetID {
            guard let photoValidator else { throw ProfilePhotoServiceError.unavailable }
            try await photoValidator.validatePhoto(id: photoID)
            let appearance = teammate.appearance
            guard appearance.revision < UInt64.max else {
                throw DomainValidationError.invalid(field: "appearance revision", reason: "cannot advance further")
            }
            teammate.appearance = try AgentAppearance(
                mode: .photo, grammarVersion: appearance.grammarVersion,
                deterministicSeed: appearance.deterministicSeed, silhouette: appearance.silhouette,
                paletteToken: appearance.paletteToken, eyeDialect: appearance.eyeDialect,
                nonColorIdentityCue: appearance.nonColorIdentityCue,
                accessibleIdentityDescription: appearance.accessibleIdentityDescription,
                profileAssetID: photoID, revision: appearance.revision + 1
            )
        }
        teammate.updatedAt = max(teammate.updatedAt, clock.now())

        // The repository's compare-and-swap is the final authority: an actor
        // can suspend above, so a second editor may win after our read. Never
        // retry a rejected edit against the newer profile silently.
        try await repository.update(teammate, expectedProfileRevision: expectedRevision)
        return teammate
    }

    private static func validateSelectionToken(_ token: String, field: String) throws {
        // Validate only explicit new selections. Do not trim, normalize,
        // consult a catalog, or revalidate values preserved by other edits.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.[]")
        guard !token.isEmpty, token.utf8.count <= 200,
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              token.first?.isASCII == true,
              token.first?.isLetter == true || token.first?.isNumber == true else {
            throw DomainValidationError.invalid(field: field, reason: "must be a safe selection token of at most 200 bytes")
        }
    }

    private static func defaultAppearance(for id: TeammateID) throws -> AgentAppearance {
        let seed = stableSeed(for: id.rawValue)
        let silhouettes = TeammateCreatureDraft.silhouettes
        let palettes = TeammateCreatureDraft.paletteTokens
        let eyes = TeammateCreatureDraft.eyeDialects
        let cues = TeammateCreatureDraft.nonColorIdentityCues

        return try AgentAppearance(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: seed,
            silhouette: silhouettes[Int(seed % UInt64(silhouettes.count))],
            paletteToken: palettes[Int((seed / 7) % UInt64(palettes.count))],
            eyeDialect: eyes[Int((seed / 17) % UInt64(eyes.count))],
            nonColorIdentityCue: cues[Int((seed / 31) % UInt64(cues.count))],
            accessibleIdentityDescription: "Creature with \(cues[Int((seed / 31) % UInt64(cues.count))])",
            builtInAvatarID: BuiltInAvatar.allocatedForNewIdentity(seed: seed)?.rawValue
        )
    }

    private static func stableSeed(for uuid: UUID) -> UInt64 {
        uuid.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
