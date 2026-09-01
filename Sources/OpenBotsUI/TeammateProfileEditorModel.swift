import Foundation
import Combine
import OpenBotsDomain
import OpenBotsServices

/// Reviewed 2026-08-31 against Anthropic's model overview and Claude Code model
/// configuration. Pinned versions avoid automatically moving a user's choice.
enum ClaudeModelCatalog {
    struct Option: Identifiable {
        let id: String
        let name: String
        let menuLabel: String
        let detail: String
    }
    static let options: [Option] = [
        .init(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5",
              menuLabel: "Haiku 4.5 · Quick tasks · 200K",
              detail: "Fast, lighter reasoning. 200,000-token model context."),
        .init(id: "claude-sonnet-5", name: "Sonnet 5",
              menuLabel: "Sonnet 5 · Balanced · 1M",
              detail: "Everyday work. 1,000,000-token model context."),
        .init(id: "claude-opus-5", name: "Opus 5",
              menuLabel: "Opus 5 · Complex reasoning · 1M · Max",
              detail: "Higher intensity. 1,000,000-token model context, included with Max."),
        .init(id: "claude-fable-5", name: "Fable 5",
              menuLabel: "Fable 5 · Highest capability · 1M · Max",
              detail: "Highest intensity. 1,000,000-token model context. Included in Max within its Fable allowance; uses the shared weekly limit faster."),
        .init(id: "claude-opus-4-8", name: "Opus 4.8",
              menuLabel: "Opus 4.8 · Complex reasoning · 1M · Max", detail: "Earlier Opus version. 1M context on Max."),
        .init(id: "claude-opus-4-7", name: "Opus 4.7",
              menuLabel: "Opus 4.7 · Complex reasoning · 1M · Max", detail: "Earlier Opus version. 1M context on Max."),
        .init(id: "claude-opus-4-6", name: "Opus 4.6",
              menuLabel: "Opus 4.6 · Complex reasoning · 1M · Max", detail: "Earlier Opus version. 1M context on Max."),
        .init(id: "claude-sonnet-4-6", name: "Sonnet 4.6",
              menuLabel: "Sonnet 4.6 · Balanced · 200K", detail: "Earlier Sonnet version. Ordinary 200K context; the separate 1M option requires usage credits."),
        .init(id: "claude-opus-4-5-20251101", name: "Opus 4.5",
              menuLabel: "Opus 4.5 · Complex reasoning · 200K", detail: "Earlier Opus version. 200K context."),
        .init(id: "claude-sonnet-4-5-20250929", name: "Sonnet 4.5",
              menuLabel: "Sonnet 4.5 · Balanced · 200K", detail: "Earlier Sonnet version. 200K context.")
    ]
    static let availabilityNote = "Catalog reference, reviewed August 31, 2026. Availability and limits depend on your Claude account. Provider use beyond included limits may consume enabled usage credits. Saving a preference does not verify access, change account settings, or enable or purchase credits."

    static func option(for id: String) -> Option? { options.first { $0.id == id } }
    static func label(for id: String) -> String {
        id == "sonnet" ? "Sonnet (existing default)" : option(for: id)?.name ?? id
    }
    static func matches(requested: String, observed: String) -> Bool {
        let resolved = ["claude-opus-4-6[1m]", "claude-sonnet-4-6[1m]"].contains(observed)
            ? String(observed.dropLast(4)) : observed
        return requested == resolved || (requested == "sonnet" && resolved == "claude-sonnet-5")
    }
    static func effortLabel(_ value: String, model: String) -> String {
        guard value == "default" else {
            guard ClaudeEffortPolicy.supportedValues(for: model).contains(value) else {
                return "Saved: \(value) (not in catalog)"
            }
            return value == "xhigh" ? "Extra high" : value.capitalized
        }
        return "Model default preference"
    }
    static func contextLabel(_ value: String, model: String) -> String {
        guard ClaudeContextWindowPolicy.supportedValues(for: model).contains(value) else {
            return "Saved: \(value) (not in catalog)"
        }
        switch value {
        case "standard": return "Standard · 200K preference"
        case "long": return "Long · 1M preference"
        case "default": return "Model default preference"
        default: return "Saved: \(value) (not in catalog)"
        }
    }
}

enum ProfileEditorFocusDestination: Hashable {
    case back, avatar, photo, creature
}

/// One explicit editor session for one immutable teammate identity. It cannot
/// grant capabilities, start a runtime, or retarget a draft. Photo imports are
/// explicit single-file requests through the optional injected service only.
@MainActor
public final class TeammateProfileEditorModel: ObservableObject {
    public let teammateID: TeammateID
    @Published public var displayName = ""
    @Published public var title = ""
    @Published public var role = ""
    @Published public var detailedInstructions = ""
    @Published public var claudeModel = "sonnet"
    @Published public var claudeEffort = "default"
    @Published public var claudeContextWindow = "default"
    @Published public var isAdvancedExpanded = false
    @Published public var isAppearanceExpanded = false
    @Published public var editsCreature = false {
        didSet {
            if editsCreature {
                pendingPhotoAsset = nil
                pendingBuiltInAvatar = nil
            }
        }
    }
    @Published public var silhouette = TeammateCreatureDraft.silhouettes[0]
    @Published public var paletteToken = TeammateCreatureDraft.paletteTokens[0]
    @Published public var eyeDialect = TeammateCreatureDraft.eyeDialects[0]
    @Published public var nonColorIdentityCue = TeammateCreatureDraft.nonColorIdentityCues[0]

    @Published public private(set) var originalTeammate: Teammate?
    @Published public private(set) var savedTeammate: Teammate?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var isImportingPhoto = false
    @Published public private(set) var pendingPhotoAsset: ProfilePhotoAsset?
    @Published public private(set) var pendingBuiltInAvatar: BuiltInAvatar?
    @Published public private(set) var isCancelled = false
    @Published public private(set) var requiresReopen = false
    @Published public private(set) var inlineError: String?

    private let service: any TeammateProfileEditing
    private let photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)?
    private var generation: UInt64 = 0
    public private(set) var isShuttingDown = false
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        generation &+= 1
    }

    public init(
        service: any TeammateProfileEditing,
        teammateID: TeammateID,
        photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)? = nil
    ) {
        self.service = service
        self.teammateID = teammateID
        self.photoImporter = photoImporter
    }

    public var originalIdentity: TeammateIdentitySnapshot? {
        originalTeammate.map(TeammateIdentitySnapshot.init)
    }

    /// Pure rendering data for the visible, unsaved choice. The saved identity
    /// and its revision do not change until the service returns a save receipt.
    public var appearancePreviewIdentity: TeammateIdentitySnapshot? {
        guard let original = originalTeammate else { return nil }
        if let avatar = pendingBuiltInAvatar {
            let saved = original.appearance
            return TeammateIdentitySnapshot(
                id: original.id.rawValue, name: original.profile.displayName, role: original.profile.role,
                appearance: CharacterAppearanceSnapshot(
                    mode: .creature, grammarVersion: saved.grammarVersion,
                    deterministicSeed: saved.deterministicSeed,
                    silhouette: saved.silhouette, paletteToken: saved.paletteToken,
                    eyeDialect: saved.eyeDialect, nonColorIdentityCue: saved.nonColorIdentityCue,
                    accessibleIdentityDescription: saved.accessibleIdentityDescription,
                    builtInAvatarID: avatar.rawValue, revision: saved.revision
                )
            )
        }
        if let photo = pendingPhotoAsset {
            let saved = original.appearance
            return TeammateIdentitySnapshot(
                id: original.id.rawValue, name: original.profile.displayName,
                role: original.profile.role,
                appearance: CharacterAppearanceSnapshot(
                    mode: .photo, grammarVersion: saved.grammarVersion,
                    deterministicSeed: saved.deterministicSeed,
                    silhouette: saved.silhouette, paletteToken: saved.paletteToken,
                    eyeDialect: saved.eyeDialect, nonColorIdentityCue: saved.nonColorIdentityCue,
                    accessibleIdentityDescription: "Unsaved profile photo preview",
                    profileAssetID: photo.id.rawValue, revision: saved.revision
                )
            )
        }
        guard editsCreature, creatureValidationMessage == nil else { return originalIdentity }
        return TeammateIdentitySnapshot(
            id: original.id.rawValue,
            name: original.profile.displayName,
            role: original.profile.role,
            appearance: CharacterAppearanceSnapshot(
                mode: .creature, grammarVersion: original.appearance.grammarVersion,
                deterministicSeed: original.appearance.deterministicSeed,
                silhouette: silhouette, paletteToken: paletteToken, eyeDialect: eyeDialect,
                nonColorIdentityCue: nonColorIdentityCue,
                accessibleIdentityDescription: "Unsaved preview: \(silhouette) creature with \(eyeDialect) eyes and \(nonColorIdentityCue)",
                revision: original.appearance.revision
            )
        )
    }

    public var isEditingEnabled: Bool {
        !isShuttingDown && originalTeammate != nil && !isLoading && !isSaving && !isImportingPhoto
            && !isCancelled && savedTeammate == nil
    }

    public var isPhotoImportAvailable: Bool { photoImporter != nil }
    public var canChoosePhoto: Bool { isEditingEnabled && isPhotoImportAvailable }
    public var hasAppearanceChanges: Bool { editsCreature || pendingPhotoAsset != nil || pendingBuiltInAvatar != nil }

    public func chooseBuiltInAvatar(_ avatar: BuiltInAvatar?) {
        guard isEditingEnabled else { return }
        editsCreature = false
        pendingPhotoAsset = nil
        pendingBuiltInAvatar = avatar
    }

    /// Revealing existing controls is not an appearance edit or picker grant.
    /// Prefer the available photo action, otherwise the retained creature editor.
    func beginAvatarEditing() -> ProfileEditorFocusDestination? {
        guard isEditingEnabled else { return nil }
        isAppearanceExpanded = true
        return isPhotoImportAvailable ? .photo : .creature
    }

    public var hasUnsavedChanges: Bool {
        guard let original = originalTeammate else { return false }
        return trimmed(displayName) != original.profile.displayName
            || optional(title) != original.profile.title
            || trimmed(role) != original.profile.role
            || optional(detailedInstructions) != original.profile.detailedInstructions
            || claudeModel != original.requestedClaudeModel
            || claudeEffort != original.requestedClaudeEffort
            || claudeContextWindow != original.requestedClaudeContextWindow
            || hasAppearanceChanges
    }

    public var nameValidationMessage: String? {
        requiredValidation(displayName, label: "name", maximum: 80)
    }

    public var titleValidationMessage: String? {
        optionalValidation(title, label: "title", maximum: 120)
    }

    public var roleValidationMessage: String? {
        requiredValidation(role, label: "role", maximum: 240)
    }

    public var instructionsValidationMessage: String? {
        optionalValidation(detailedInstructions, label: "instructions", maximum: 20_000)
    }

    public var creatureValidationMessage: String? {
        guard editsCreature else { return nil }
        guard TeammateCreatureDraft.silhouettes.contains(silhouette),
              TeammateCreatureDraft.paletteTokens.contains(paletteToken),
              TeammateCreatureDraft.eyeDialects.contains(eyeDialect),
              TeammateCreatureDraft.nonColorIdentityCues.contains(nonColorIdentityCue)
        else { return "Choose a listed option for each creature feature." }
        return nil
    }

    public var canSave: Bool {
        isEditingEnabled && hasUnsavedChanges && !requiresReopen
            && nameValidationMessage == nil && titleValidationMessage == nil
            && roleValidationMessage == nil && instructionsValidationMessage == nil
            && creatureValidationMessage == nil
    }

    public func load() async {
        guard !isShuttingDown, originalTeammate == nil, !isLoading, !isSaving, !isCancelled else { return }
        generation &+= 1
        let operation = generation
        isLoading = true
        inlineError = nil
        defer { if generation == operation { isLoading = false } }
        do {
            let loaded = try await service.loadProfile(teammateID: teammateID)
            guard generation == operation, !isCancelled else { return }
            guard loaded.id == teammateID else {
                inlineError = "OpenBots received a different teammate’s profile. This editor has not changed identity."
                return
            }
            apply(loaded)
        } catch {
            guard generation == operation, !isCancelled else { return }
            inlineError = "OpenBots couldn’t load this profile. Try again."
        }
    }

    /// A saved result is returned only for this session's exact target and next
    /// revision. Errors preserve the draft; conflicts are never auto-retried.
    public func save() async -> Teammate? {
        guard canSave, let original = originalTeammate else { return nil }
        let draft = TeammateProfileEditDraft(
            displayName: trimmed(displayName), title: optional(title), role: trimmed(role),
            detailedInstructions: optional(detailedInstructions),
            creature: editsCreature ? TeammateCreatureDraft(
                silhouette: silhouette, paletteToken: paletteToken,
                eyeDialect: eyeDialect, nonColorIdentityCue: nonColorIdentityCue
            ) : nil,
            photoAssetID: pendingPhotoAsset?.id,
            builtInAvatar: pendingBuiltInAvatar,
            claudeModel: claudeModel == original.requestedClaudeModel ? nil : claudeModel,
            claudeEffort: claudeEffort == original.requestedClaudeEffort ? nil : claudeEffort,
            claudeContextWindow: claudeContextWindow == original.requestedClaudeContextWindow ? nil : claudeContextWindow
        )
        generation &+= 1
        let operation = generation
        isSaving = true
        inlineError = nil
        defer { if generation == operation { isSaving = false } }
        do {
            let saved = try await service.saveProfile(
                teammateID: teammateID, expectedRevision: original.profile.revision, draft: draft
            )
            guard generation == operation, !isCancelled else { return nil }
            guard saved.id == teammateID,
                  original.profile.revision < UInt64.max,
                  saved.profile.revision == original.profile.revision + 1 else {
                requiresReopen = true
                inlineError = "OpenBots couldn’t verify the saved profile. Your edits remain here; cancel and reopen before trying again."
                return nil
            }
            apply(saved)
            savedTeammate = saved
            return saved
        } catch {
            guard generation == operation, !isCancelled else { return nil }
            if case RepositoryError.optimisticLockFailed = error {
                requiresReopen = true
                inlineError = "This profile changed elsewhere. Your edits remain here. Cancel and reopen to review the saved profile."
            } else {
                inlineError = "OpenBots couldn’t save this profile. Your edits remain here; try again."
            }
            return nil
        }
    }

    /// The selected URL is transient and never becomes profile text or state.
    /// The service owns scoped access and a protected, immutable local copy.
    public func importPhoto(from selectedURL: URL) async {
        guard canChoosePhoto, let photoImporter else { return }
        guard selectedURL.isFileURL else {
            inlineError = "Choose an image file using the photo picker. Your current appearance is unchanged."
            return
        }
        generation &+= 1
        let operation = generation
        let target = teammateID
        isImportingPhoto = true
        inlineError = nil
        defer { if generation == operation { isImportingPhoto = false } }
        do {
            let asset = try await photoImporter(selectedURL)
            guard generation == operation, !isCancelled, teammateID == target,
                  originalTeammate?.id == target else { return }
            editsCreature = false
            pendingBuiltInAvatar = nil
            pendingPhotoAsset = asset
        } catch {
            guard generation == operation, !isCancelled else { return }
            inlineError = "OpenBots couldn’t import that photo. Your previous appearance and profile edits remain here."
        }
    }

    public func photoSelectionFailed() {
        guard isEditingEnabled else { return }
        inlineError = "OpenBots couldn’t open the photo selection. Your current appearance is unchanged."
    }

    public func discardPendingPhoto() {
        guard isEditingEnabled else { return }
        pendingPhotoAsset = nil
    }

    /// An already-dispatched save cannot truthfully be cancelled as unwritten.
    /// The view disables Cancel for that short operation and waits for receipt.
    @discardableResult
    public func cancel() -> Bool {
        guard !isShuttingDown, !isSaving, savedTeammate == nil else { return false }
        generation &+= 1
        isLoading = false
        isImportingPhoto = false
        pendingPhotoAsset = nil
        isCancelled = true
        pendingBuiltInAvatar = nil
        return true
    }

    private func apply(_ teammate: Teammate) {
        originalTeammate = teammate
        displayName = teammate.profile.displayName
        title = teammate.profile.title ?? ""
        role = teammate.profile.role
        detailedInstructions = teammate.profile.detailedInstructions ?? ""
        claudeModel = teammate.requestedClaudeModel
        claudeEffort = teammate.requestedClaudeEffort
        claudeContextWindow = teammate.requestedClaudeContextWindow
        editsCreature = false
        pendingPhotoAsset = nil
        pendingBuiltInAvatar = nil
        let appearance = teammate.appearance
        silhouette = choice(appearance.silhouette, in: TeammateCreatureDraft.silhouettes)
        paletteToken = choice(appearance.paletteToken, in: TeammateCreatureDraft.paletteTokens)
        eyeDialect = choice(appearance.eyeDialect, in: TeammateCreatureDraft.eyeDialects)
        nonColorIdentityCue = choice(appearance.nonColorIdentityCue, in: TeammateCreatureDraft.nonColorIdentityCues)
    }

    private func choice(_ current: String, in choices: [String]) -> String {
        choices.contains(current) ? current : choices[0]
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optional(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private func requiredValidation(_ value: String, label: String, maximum: Int) -> String? {
        let value = trimmed(value)
        if value.isEmpty { return "Enter a \(label) for this teammate." }
        return value.count > maximum ? "Keep the \(label) to \(maximum) characters or fewer." : nil
    }

    private func optionalValidation(_ value: String, label: String, maximum: Int) -> String? {
        trimmed(value).count > maximum ? "Keep the \(label) to \(maximum) characters or fewer." : nil
    }
}
