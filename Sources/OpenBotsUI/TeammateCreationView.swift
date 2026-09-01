import Combine
import SwiftUI

/// Process-local presentation state for the bounded teammate creation sheet.
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
    @Published public var shortRole = ""
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var submissionError: String?
    @Published public private(set) var hasAttemptedSubmit = false

    private let submitAction: Submission
    private var hasSubmittedSuccessfully = false

    public init(
        identityID: UUID,
        appearance: CharacterAppearanceSnapshot,
        submit: @escaping Submission
    ) {
        self.id = identityID
        self.appearance = appearance
        self.submitAction = submit
    }

    public var previewIdentity: TeammateIdentitySnapshot {
        TeammateIdentitySnapshot(
            id: id,
            name: trimmedName.isEmpty ? "New teammate" : trimmedName,
            role: trimmedRole.isEmpty ? "Short role" : trimmedRole,
            appearance: appearance
        )
    }

    public var nameValidationMessage: String? {
        if hasAttemptedSubmit, trimmedName.isEmpty {
            return "Enter a name for this teammate."
        }
        if trimmedName.count > Self.maximumNameLength {
            return "Keep the name to \(Self.maximumNameLength) characters or fewer."
        }
        return nil
    }

    public var roleValidationMessage: String? {
        if hasAttemptedSubmit, trimmedRole.isEmpty {
            return "Add a short role so this teammate is easy to recognize."
        }
        if trimmedRole.count > Self.maximumRoleLength {
            return "Keep the role to \(Self.maximumRoleLength) characters or fewer."
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
        } catch {
            // Submission failures may carry paths, provider details, or other
            // sensitive diagnostics. The sheet presents a stable local message;
            // a conversation-scoped recovery surface can expose reviewed detail.
            submissionError = "OpenBots couldn’t create this teammate. Nothing was saved."
            return false
        }
    }

    public func reset() {
        guard !isSubmitting else { return }
        name = ""
        shortRole = ""
        submissionError = nil
        hasAttemptedSubmit = false
        hasSubmittedSuccessfully = false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRole: String {
        shortRole.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TeammateCreationView: View {
    private enum Field: Hashable {
        case name
        case role
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var model: TeammateCreationModel
    @FocusState private var focusedField: Field?

    public init(model: TeammateCreationModel) {
        self.model = model
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
                Button("Cancel") {
                    model.reset()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSubmitting)

                Button {
                    Task {
                        if await model.submit() {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isSubmitting {
                        Label("Creating…", systemImage: "person.badge.plus")
                    } else {
                        Text("Create Teammate")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSubmitting)
                .accessibilityHint(
                    model.canSubmit
                        ? "Create this teammate with the displayed identity."
                        : "Review the name and short role; any problem appears inline."
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
                Text("Create a teammate")
                    .font(.title2.weight(.semibold))
                Text(model.previewIdentity.name)
                    .font(.headline)
                Text(model.previewIdentity.role)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Idle", systemImage: TeammateActivityState.idle.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Identity preview. \(model.previewIdentity.name), \(model.previewIdentity.role), Idle"
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(
                label: "Name",
                prompt: "For example, Ada",
                text: $model.name,
                validationMessage: model.nameValidationMessage,
                field: .name
            )
            field(
                label: "Short role",
                prompt: "For example, Research and synthesis",
                text: $model.shortRole,
                validationMessage: model.roleValidationMessage,
                field: .role
            )
        }
        .disabled(model.isSubmitting)
    }

    private func field(
        label: String,
        prompt: String,
        text: Binding<String>,
        validationMessage: String?,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.semibold))
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
                .accessibilityLabel(label)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(label) error. \(validationMessage)")
            }
        }
    }
}
