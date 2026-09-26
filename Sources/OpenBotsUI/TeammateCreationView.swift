import Combine
import OpenBotsDomain
import SwiftUI

/// Process-local presentation state for the New Bot sheet: a name, what the
/// bot does in one paragraph, and the creature already allocated for it.
/// Construction is inert: no repository, Keychain, runtime, or filesystem work
/// occurs until the injected submission closure is explicitly invoked.
@MainActor
public final class TeammateCreationModel: ObservableObject, Identifiable {
    public typealias Submission =
        @MainActor @Sendable (TeammateIdentitySnapshot) async throws -> Void

    public static let maximumNameLength = 80
    public static let maximumRoleLength = 240

    public nonisolated let id: UUID
    public let appearance: CharacterAppearanceSnapshot

    @Published public var name = ""
    /// What this bot does, in one paragraph. Saved as the bot's role.
    @Published public var role = ""
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var submissionError: String?
    @Published public private(set) var hasAttemptedSubmit = false
    /// Names Create was refused for because another bot took them between
    /// the sheet opening and the press, each with the name that bot carries.
    /// The live check below cannot see a race the boundary saw, so the
    /// refusal is kept here until the typed name changes.
    @Published private var namesRefusedAtSubmit: [(typed: String, existing: String)] = []

    private let submitAction: Submission
    /// The name an active bot already carries for the typed one, if any.
    /// Compared without case, as the handoff fence routes `@Name`.
    private let takenName: @MainActor (String) -> String?
    private var hasSubmittedSuccessfully = false

    public init(
        identityID: UUID,
        appearance: CharacterAppearanceSnapshot,
        takenName: @escaping @MainActor (String) -> String? = { _ in nil },
        submit: @escaping Submission
    ) {
        self.id = identityID
        self.appearance = appearance
        self.takenName = takenName
        self.submitAction = submit
    }

    public var previewIdentity: TeammateIdentitySnapshot {
        TeammateIdentitySnapshot(
            id: id,
            name: trimmedName.isEmpty ? "New Bot" : trimmedName,
            role: trimmedRole,
            appearance: appearance
        )
    }

    /// The active bot whose name the typed one would collide with, if any:
    /// what the roster says now, or what the boundary said at the last press.
    public var conflictingName: String? {
        guard !trimmedName.isEmpty else { return nil }
        return takenName(trimmedName)
            ?? namesRefusedAtSubmit.first { TeammateProfile.namesMatch($0.typed, trimmedName) }?.existing
    }

    public var nameValidationMessage: String? {
        if hasAttemptedSubmit, trimmedName.isEmpty {
            return "Enter a name for this bot."
        }
        if trimmedName.count > Self.maximumNameLength {
            return "Keep the name to \(Self.maximumNameLength) characters or fewer."
        }
        if let existing = conflictingName {
            return "There is already a bot called \(existing)."
        }
        return nil
    }

    public var roleValidationMessage: String? {
        if hasAttemptedSubmit, trimmedRole.isEmpty {
            return "Say what this bot does."
        }
        if trimmedRole.count > Self.maximumRoleLength {
            return "Keep it to \(Self.maximumRoleLength) characters or fewer."
        }
        return nil
    }

    public var canSubmit: Bool {
        !isSubmitting
            && !hasSubmittedSuccessfully
            && !trimmedName.isEmpty
            && !trimmedRole.isEmpty
            && trimmedName.count <= Self.maximumNameLength
            && trimmedRole.count <= Self.maximumRoleLength
            && conflictingName == nil
    }

    /// Returns `true` only after the injected boundary accepts one valid
    /// identity. Concurrent or repeated submissions are ignored.
    @discardableResult
    public func submit() async -> Bool {
        hasAttemptedSubmit = true
        submissionError = nil
        guard canSubmit else { return false }

        isSubmitting = true
        defer { isSubmitting = false }

        let identity = TeammateIdentitySnapshot(
            id: id,
            name: trimmedName,
            role: trimmedRole,
            appearance: appearance
        )

        do {
            try await submitAction(identity)
            hasSubmittedSuccessfully = true
            return true
        } catch let taken as TeammateNameTakenError {
            // The same inline sentence as the live check, under the field it
            // concerns; the sheet stays open for another name.
            namesRefusedAtSubmit.append((typed: identity.name, existing: taken.existingName))
            return false
        } catch {
            // Submission failures may carry paths, provider details, or other
            // sensitive diagnostics. The sheet presents a stable local message;
            // a conversation-scoped recovery surface can expose reviewed detail.
            submissionError = "Couldn’t create the bot. Nothing was saved."
            return false
        }
    }

    public func reset() {
        guard !isSubmitting else { return }
        name = ""
        role = ""
        submissionError = nil
        hasAttemptedSubmit = false
        hasSubmittedSuccessfully = false
        namesRefusedAtSubmit = []
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedRole: String {
        role.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TeammateCreationView: View {
    private enum Field: Hashable {
        case name
        case role
    }

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var model: TeammateCreationModel
    private let onCancel: @MainActor () -> Void
    @FocusState private var focusedField: Field?

    public init(model: TeammateCreationModel, onCancel: @escaping @MainActor () -> Void) {
        self.model = model
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            identityPreview
            form

            if let submissionError = model.submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Creation failed. \(submissionError)")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSubmitting)
                    .accessibilityIdentifier("bot-cancel")
                    .help("Cancel")

                Button {
                    Task { await model.submit() }
                } label: {
                    if model.isSubmitting {
                        Label("Creating…", systemImage: "person.badge.plus")
                    } else {
                        Text("Create Bot")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSubmitting)
                .accessibilityIdentifier("bot-create")
                .help("Create Bot")
                .accessibilityHint(
                    model.canSubmit
                        ? "Create this bot with the name and description shown."
                        : "Give the bot a name and say what it does; any problem appears under its field."
                )
            }
        }
        .padding(28)
        .frame(width: 500)
        .background(OpenBotsVisualStyle.canvas(for: colorScheme))
        .onAppear { focusedField = .name }
        .interactiveDismissDisabled(model.isSubmitting)
    }

    private var identityPreview: some View {
        HStack(spacing: 16) {
            CharacterIdentityView(
                teammate: TeammateRowSnapshot(
                    identity: model.previewIdentity,
                    activity: .idle
                ),
                size: 72
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("New Bot")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !model.trimmedName.isEmpty {
                    Text(model.trimmedName)
                        .font(.headline)
                }
                if !model.trimmedRole.isEmpty {
                    Text(model.trimmedRole)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(previewAccessibilityLabel)
    }

    private var previewAccessibilityLabel: String {
        var label = "New Bot"
        if !model.trimmedName.isEmpty { label += ". \(model.trimmedName)" }
        if !model.trimmedRole.isEmpty { label += ". \(model.trimmedRole)" }
        return label
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.callout.weight(.semibold))
                TextField("For example, Ada", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("bot-name")
                validation(model.nameValidationMessage, for: "Name")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What this bot does")
                    .font(.callout.weight(.semibold))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.role)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .frame(minHeight: 88, maxHeight: 132)
                        .focused($focusedField, equals: .role)
                        .accessibilityLabel("What this bot does")
                        .accessibilityIdentifier("bot-role")
                    if model.role.isEmpty {
                        Text("One paragraph. For example: reads the mail each morning and drafts the replies for me to send.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(OpenBotsVisualStyle.surface(for: colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                validation(model.roleValidationMessage, for: "What this bot does")
            }
        }
        .disabled(model.isSubmitting)
    }

    @ViewBuilder
    private func validation(_ message: String?, for label: String) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("\(label) error. \(message)")
        }
    }
}
