import SwiftUI
import OpenBotsDomain
import OpenBotsServices
import UniformTypeIdentifiers

/// Explicit editing of an existing bot in its right-side settings panel.
/// Embedders own navigation; this view never opens a modal or switches targets.
public struct TeammateProfileEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.profilePhotoPresentation) private var photoPresentation
    @ObservedObject private var model: TeammateProfileEditorModel
    @State private var isChoosingPhoto = false
    @StateObject private var photoPreview = ProfilePhotoViewModel()
    @FocusState private var focusedControl: ProfileEditorFocusDestination?
    @State private var avatarFocusRequest: ProfileEditorFocusDestination?
    private let onSaved: @MainActor (Teammate) -> Void
    private let onCancelled: @MainActor () -> Void
    private let onBack: (@MainActor () -> Void)?
    private let onClose: (@MainActor () -> Void)?
    private let modelStatus: ClaudeModelRunPresentation?

    public init(
        model: TeammateProfileEditorModel,
        onSaved: @escaping @MainActor (Teammate) -> Void,
        onCancelled: @escaping @MainActor () -> Void,
        onBack: (@MainActor () -> Void)? = nil,
        onClose: (@MainActor () -> Void)? = nil,
        modelStatus: ClaudeModelRunPresentation? = nil
    ) {
        self.model = model
        self.onSaved = onSaved
        self.onCancelled = onCancelled
        self.onBack = onBack
        self.onClose = onClose
        self.modelStatus = modelStatus
    }

    public var body: some View {
        VStack(spacing: 0) {
            panelNavigation
            Divider()
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing16) {
                    header
                    if let original = model.originalTeammate {
                        profileFields
                            .disabled(!model.isEditingEnabled)
                        modelFields(original: original)
                        unavailableSettings
                        DisclosureGroup("Appearance", isExpanded: $model.isAppearanceExpanded) {
                            creatureFields(original: original)
                                .disabled(!model.isEditingEnabled)
                                .padding(.top, 8)
                        }
                        .id("bot-appearance-controls")
                        DisclosureGroup("Advanced", isExpanded: $model.isAdvancedExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                textField("Short role", text: $model.role, error: model.roleValidationMessage)
                                    .disabled(!model.isEditingEnabled)
                                Text("Profile revision \(original.profile.revision)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                    } else if model.isLoading {
                        ProgressView("Loading profile…")
                            .controlSize(.small)
                    }
                    if let error = model.inlineError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Profile error. \(error)")
                        if model.originalTeammate == nil, !model.isLoading, !model.isCancelled {
                            Button("Try Again") { Task { await model.load() } }
                        }
                    }
                }
                .padding(OpenBotsVisualStyle.spacing16)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .task(id: avatarFocusRequest) {
                  guard let destination = avatarFocusRequest else { return }
                  await Task.yield()
                  guard !Task.isCancelled else { return }
                  proxy.scrollTo("bot-appearance-controls", anchor: .top)
                  focusedControl = destination
                  avatarFocusRequest = nil
              }
            }
            actionBar
                .padding(OpenBotsVisualStyle.spacing16)
        }
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bot settings")
        .onAppear { focusedControl = onBack == nil ? .avatar : .back }
        .task { await model.load() }
        .task(id: photoRequest) {
            await photoPreview.load(assetID: previewPhotoID, presentation: photoPresentation)
        }
        .fileImporter(isPresented: $isChoosingPhoto, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task { await model.importPhoto(from: url) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.photoSelectionFailed()
                }
            }
        }
    }

    private var panelNavigation: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel("Back to details")
                    .help("Back to details; keep unsaved edits")
                    .focused($focusedControl, equals: .back)
            }
            Text("Settings").font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "sidebar.right")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel("Close details")
                    .help("Collapse settings; keep unsaved edits")
            }
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    private var header: some View {
        VStack(spacing: OpenBotsVisualStyle.spacing8) {
            if let previewIdentity = model.appearancePreviewIdentity {
                Button {
                    avatarFocusRequest = model.beginAvatarEditing()
                } label: {
                    CharacterIdentityView(identity: previewIdentity, activity: .idle, size: 56)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!model.isEditingEnabled)
                .accessibilityLabel("Edit Bot avatar")
                .accessibilityValue(
                    "\(model.hasAppearanceChanges ? "Unsaved appearance preview" : "Saved appearance"). \(previewIdentity.appearance.accessibleIdentityDescription)"
                )
                .accessibilityHint("Show appearance controls for this bot. Choosing a photo remains a separate action.")
                .focused($focusedControl, equals: .avatar)
            }
            if model.hasAppearanceChanges {
                Text("Unsaved appearance preview")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var profileFields: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            textField("Name", accessibilityName: "Bot name", text: $model.displayName, error: model.nameValidationMessage)
            textField("Label (optional)", accessibilityName: "Bot label", text: $model.title, error: model.titleValidationMessage)
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text("What this bot does").font(.callout.weight(.medium))
                Text("Describe its role, working style, and ongoing instructions.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.detailedInstructions)
                    .font(.body)
                    .frame(height: 100)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Bot description")
                    .accessibilityHint("Describe what this bot does, how it should work, and any ongoing instructions.")
                validation(model.instructionsValidationMessage)
            }
        }
    }

    private var unavailableSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Notifications")
                Spacer()
                Text("Unavailable").foregroundStyle(.secondary)
            }
            Text("Delivery is not connected.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Share as template") {}
                .disabled(true)
            Text("Templates unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modelFields(original: Teammate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            preferenceField("Preferred model") {
                Picker("Preferred model", selection: $model.claudeModel) {
                    if !ClaudeModelCatalog.options.contains(where: { $0.id == model.claudeModel }) {
                        Text(model.claudeModel == "sonnet" ? "Sonnet · Existing preference" : "Saved preference: \(model.claudeModel) (not in catalog)")
                            .tag(model.claudeModel)
                    }
                    ForEach(ClaudeModelCatalog.options) { option in
                        Text(option.menuLabel).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!model.isEditingEnabled)
                .accessibilityIdentifier("bot-claude-model")
            }
            effortFields
            contextWindowFields
            if ClaudeModelCatalog.option(for: model.claudeModel) == nil, model.claudeModel != "sonnet" {
                Text("This saved preference is outside the current catalog. It is preserved until you choose another.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("About these preferences") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Supported choices apply to the next reply. Unavailable choices are refused without changing saved preferences. Actual intensity and context size aren’t verified.")
                    Text("Usage beyond your plan’s allowance may consume enabled credits.")
                    if model.claudeModel == "claude-fable-5" {
                        Text("Fable uses the shared weekly allowance faster.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func preferenceField<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(title)
                .font(.callout.weight(.medium))
                .accessibilityHidden(true)
            content()
                .labelsHidden()
                .accessibilityLabel(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .foregroundStyle(.primary)
    }

    private var effortFields: some View {
        let choices = ClaudeEffortPolicy.supportedValues(for: model.claudeModel)
        return VStack(alignment: .leading, spacing: 6) {
            if choices.isEmpty {
                Text("Preferred thinking intensity: no options listed for this model")
                    .font(.callout)
                if model.claudeEffort != "default" {
                    Text("Saved intensity \(model.claudeEffort) is not listed for this model. It is preserved until you choose another.")
                    Button("Choose Model Default") { model.claudeEffort = "default" }
                        .disabled(!model.isEditingEnabled)
                }
            } else {
                preferenceField("Preferred thinking intensity") {
                    Picker("Preferred thinking intensity", selection: $model.claudeEffort) {
                        Text(ClaudeModelCatalog.effortLabel("default", model: model.claudeModel)).tag("default")
                        if model.claudeEffort != "default", !choices.contains(model.claudeEffort) {
                            Text("Saved: \(model.claudeEffort) (not in catalog)").tag(model.claudeEffort)
                        }
                        ForEach(choices, id: \.self) { value in
                            Text(value == "xhigh" ? "Extra high" : value.capitalized).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("bot-claude-effort")
                    .disabled(!model.isEditingEnabled)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var contextWindowFields: some View {
        let choices = ClaudeContextWindowPolicy.supportedValues(for: model.claudeModel)
        return VStack(alignment: .leading, spacing: 6) {
            if choices.contains("long") {
                preferenceField("Preferred context window") {
                    Picker("Preferred context window", selection: $model.claudeContextWindow) {
                        if !choices.contains(model.claudeContextWindow) {
                            Text(ClaudeModelCatalog.contextLabel(model.claudeContextWindow, model: model.claudeModel))
                                .tag(model.claudeContextWindow)
                        }
                        ForEach(choices, id: \.self) { value in
                            Text(ClaudeModelCatalog.contextLabel(value, model: model.claudeModel)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("bot-claude-context-window")
                    .disabled(!model.isEditingEnabled)
                }
                if model.claudeModel == "claude-sonnet-4-6", model.claudeContextWindow == "long" {
                    Text("Catalog reference: Sonnet 4.6 with 1M context requires usage credits, including on Max. Saving this preference does not enable or purchase credits.")
                        .foregroundStyle(.primary)
                }
            } else {
                Text(ClaudeContextWindowPolicy.defaultTokenLimit(for: model.claudeModel) == nil
                     ? "No context options are listed for this saved model."
                     : "Catalog context: 200K. No long-context option is listed.")
                if !choices.contains(model.claudeContextWindow) {
                    Text("Saved context preference \(model.claudeContextWindow) is not listed for this model.")
                }
                if model.claudeContextWindow != "default" {
                    Button("Choose Default Context") { model.claudeContextWindow = "default" }
                        .disabled(!model.isEditingEnabled)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func creatureFields(original: Teammate) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Picker("Avatar model", selection: Binding(
                get: { model.pendingBuiltInAvatar?.rawValue ?? "" },
                set: { model.chooseBuiltInAvatar(BuiltInAvatar(rawValue: $0)) }
            )) {
                Text("Keep saved appearance").tag("")
                ForEach(BuiltInAvatar.allCases, id: \.self) { avatar in
                    Text(avatar.displayName).tag(avatar.rawValue)
                }
            }
            .pickerStyle(.menu)
            Text("Save applies the appearance preview to this bot only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if photoPreview.isUnavailable(for: previewPhotoID, presentation: photoPresentation) {
                Label("Photo unavailable—choose another photo or return to a creature.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isPhotoImportAvailable {
                Button("Choose Photo…") { isChoosingPhoto = true }
                    .disabled(!model.canChoosePhoto)
                    .focused($focusedControl, equals: .photo)
                if model.isImportingPhoto {
                    ProgressView("Preparing photo…").controlSize(.small)
                } else if model.pendingPhotoAsset != nil {
                    Text("Photo ready to preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Keep Saved Appearance") { model.discardPendingPhoto() }
                }
                Text("Choose one image. OpenBots keeps a local profile copy; your source file is not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Photo import is unavailable in this workspace.", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Change creature appearance", isOn: $model.editsCreature)
                .toggleStyle(.checkbox)
                .focused($focusedControl, equals: .creature)
            if model.editsCreature {
                Text("Appearance changes apply only after Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                creaturePicker("Shape", selection: $model.silhouette, choices: TeammateCreatureDraft.silhouettes)
                creaturePicker("Color", selection: $model.paletteToken, choices: TeammateCreatureDraft.paletteTokens)
                creaturePicker("Eyes", selection: $model.eyeDialect, choices: TeammateCreatureDraft.eyeDialects)
                creaturePicker("Identity mark", selection: $model.nonColorIdentityCue, choices: TeammateCreatureDraft.nonColorIdentityCues)
                validation(model.creatureValidationMessage)
            } else if model.pendingPhotoAsset == nil, model.pendingBuiltInAvatar == nil {
                Text("Text-only saves preserve the existing appearance exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if original.appearance.mode == .photo, model.pendingPhotoAsset == nil {
                Text("Your saved photo is retained unless you explicitly choose another photo, avatar model or creature.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewPhotoID: UUID? {
        guard let appearance = model.appearancePreviewIdentity?.appearance, appearance.mode == .photo else { return nil }
        return appearance.profileAssetID
    }

    private var photoRequest: ProfilePhotoRequest? {
        guard let previewPhotoID, let photoPresentation else { return nil }
        return ProfilePhotoRequest(assetID: previewPhotoID, presentationID: photoPresentation.id)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Divider()
            Text(model.isImportingPhoto ? "Preparing photo…" : model.isSaving ? "Saving profile…" : model.hasUnsavedChanges ? "Unsaved changes" : "No unsaved changes")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Discard changes") {
                    if model.cancel() { onCancelled() }
                }
                .disabled(model.isSaving || model.isCancelled || model.savedTeammate != nil)
                Spacer(minLength: OpenBotsVisualStyle.spacing8)
                Button("Save") {
                    Task {
                        if let saved = await model.save() { onSaved(saved) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .accessibilityHint("Save the edited profile for this teammate only.")
            }
            .controlSize(.regular)
        }
    }

    private func textField(_ label: String, accessibilityName: String? = nil, text: Binding<String>, error: String?) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(label).font(.callout.weight(.medium))
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(accessibilityName ?? label)
            validation(error)
        }
    }

    private func creaturePicker(_ label: String, selection: Binding<String>, choices: [String]) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(label).font(.callout.weight(.medium))
            Picker(label, selection: selection) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice.capitalized).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private func validation(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
