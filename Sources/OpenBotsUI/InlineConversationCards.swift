import SwiftUI

struct InlineQuestionCardView: View {
    let snapshot: ChatQuestionCardSnapshot
    var interaction: QuestionCardInteractionModel?

    var body: some View {
        ConversationCardShell(
            id: snapshot.id,
            title: "Question",
            symbolName: "questionmark.bubble.fill",
            accessibilityLabel: "Question card"
        ) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                Text(snapshot.prompt)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                if !snapshot.hasValidChoiceContract {
                    InlineCardStateLabel(
                        text: "This question is unavailable because its choices are invalid.",
                        symbolName: "exclamationmark.triangle.fill",
                        role: .failure
                    )
                } else if let interaction {
                    QuestionCardControls(model: interaction)
                } else {
                    readOnlyState
                }
            }
        }
    }

    @ViewBuilder
    private var readOnlyState: some View {
        switch snapshot.resolution {
        case .pending:
            InlineCardReadOnlyNotice()
        case .answered:
            InlineCardStateLabel(
                text: "Answer recorded",
                symbolName: "checkmark.circle.fill",
                role: .success
            )
        case .declined:
            InlineCardStateLabel(
                text: "Question declined",
                symbolName: "minus.circle.fill",
                role: .neutral
            )
        }
    }
}

private struct QuestionCardControls: View {
    @ObservedObject var model: QuestionCardInteractionModel

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            stateNotice
            if !model.state.isTerminal {
                answerControls
            }
        }
    }

    @ViewBuilder
    private var stateNotice: some View {
        switch model.state {
        case .ready:
            EmptyView()
        case .submitting:
            InlineCardStateLabel(
                text: "Recording response…",
                symbolName: "clock.arrow.circlepath",
                role: .neutral
            )
        case .answered:
            InlineCardStateLabel(
                text: "Answer recorded",
                symbolName: "checkmark.circle.fill",
                role: .success
            )
        case .declined:
            InlineCardStateLabel(
                text: "Question declined",
                symbolName: "minus.circle.fill",
                role: .neutral
            )
        case .failed:
            InlineCardStateLabel(
                text: "The response wasn’t recorded. Try again or decline.",
                symbolName: "exclamationmark.triangle.fill",
                role: .failure
            )
        }
    }

    private var answerControls: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            ForEach(model.snapshot.choices) { choice in
                Button {
                    model.answer(choiceID: choice.id)
                } label: {
                    VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                        Text(choice.title)
                            .font(.callout.weight(.semibold))
                        if let detail = choice.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.canInteract)
                .accessibilityHint("Records this answer once")
            }

            if model.snapshot.allowsFreeText {
                Divider()
                    .accessibilityHidden(true)
                Text("Write another answer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                writtenAnswerField
                sendAnswerButton
            }

            Button("Decline") {
                model.decline()
            }
            .buttonStyle(.borderless)
            .disabled(!model.canInteract)
            .accessibilityHint("Declines this question without choosing an answer")
            .accessibilityIdentifier("question-decline-\(model.snapshot.id.uuidString)")
        }
    }

    private var writtenAnswerField: some View {
        TextField(
            "Write another answer",
            text: $model.freeText
        )
        .textFieldStyle(.roundedBorder)
        .disabled(!model.canInteract)
        .onSubmit { model.answerFreeText() }
        .accessibilityLabel("Written answer")
        .accessibilityIdentifier("question-written-answer-\(model.snapshot.id.uuidString)")
    }

    private var sendAnswerButton: some View {
        Button("Send Answer") {
            model.answerFreeText()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSubmitFreeText)
        .accessibilityHint("Records the written answer once")
        .accessibilityIdentifier("question-send-answer-\(model.snapshot.id.uuidString)")
    }
}

struct InlineConnectorSetupCardView: View {
    let snapshot: ChatConnectorSetupCardSnapshot
    var interaction: ConnectorSetupCardInteractionModel?

    var body: some View {
        ConversationCardShell(
            id: snapshot.id,
            title: snapshot.connectorName,
            symbolName: "point.3.connected.trianglepath.dotted",
            accessibilityLabel: "Connector setup: \(snapshot.connectorName)"
        ) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                Text("Setup stages remain separate. One stage never authorizes another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    ConnectorAxisRow(
                        title: "Installation",
                        value: snapshot.installation.visibleLabel,
                        symbolName: snapshot.installation.symbolName
                    )
                    ConnectorAxisRow(
                        title: "Account authentication",
                        value: authenticationLabel,
                        symbolName: authenticationSymbol
                    )
                    ConnectorAxisRow(
                        title: "Teammate grant",
                        value: snapshot.botGrant.visibleLabel,
                        symbolName: snapshot.botGrant.symbolName
                    )
                    ConnectorAxisRow(
                        title: "Action approval",
                        value: snapshot.actionApproval.visibleLabel,
                        symbolName: snapshot.actionApproval.symbolName
                    )
                }

                if snapshot.authenticationAttemptCount > 0 {
                    Label(
                        "Authentication reopen requested \(snapshot.authenticationAttemptCount) time(s)",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let interaction {
                    connectorAction(interaction)
                } else {
                    InlineCardReadOnlyNotice()
                }
            }
        }
    }

    private var authenticationLabel: String {
        guard let interaction else { return snapshot.authentication.visibleLabel }
        return switch interaction.state {
        case .ready:
            snapshot.authentication.visibleLabel
        case .reopening:
            "Opening provider authentication…"
        case .reopened:
            "Provider authentication reopened"
        case .failed:
            "Couldn’t reopen provider authentication"
        }
    }

    private var authenticationSymbol: String {
        guard let interaction else { return snapshot.authentication.symbolName }
        return switch interaction.state {
        case .ready:
            snapshot.authentication.symbolName
        case .reopening:
            "clock.arrow.circlepath"
        case .reopened:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private func connectorAction(
        _ interaction: ConnectorSetupCardInteractionModel
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            connectorStateNotice(interaction)
            Button("Reopen Authentication…") {
                interaction.reopen()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!interaction.canReopenAuthentication)
            .accessibilityHint(
                "Reopens only provider authentication; it does not install, grant, or approve actions"
            )
            .accessibilityIdentifier("connector-reopen-\(snapshot.id.uuidString)")
        }
    }

    @ViewBuilder
    private func connectorStateNotice(
        _ interaction: ConnectorSetupCardInteractionModel
    ) -> some View {
        switch interaction.state {
        case .reopened:
            InlineCardStateLabel(
                text: "Provider authentication was reopened. No account or grant was changed.",
                symbolName: "checkmark.circle.fill",
                role: .success
            )
        case .reopening:
            InlineCardStateLabel(
                text: "Reopening the provider-owned authentication fixture…",
                symbolName: "clock.arrow.circlepath",
                role: .neutral
            )
        case .failed:
            InlineCardStateLabel(
                text: "The authentication fixture didn’t reopen. No other setup state changed.",
                symbolName: "exclamationmark.triangle.fill",
                role: .failure
            )
        case .ready:
            EmptyView()
        }
    }
}

private struct ConnectorAxisRow: View {
    let title: String
    let value: String
    let symbolName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenBotsVisualStyle.spacing8) {
            Image(systemName: symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct InlineSecretCardView: View {
    let snapshot: ChatSecretCardSnapshot
    var interaction: SecretCardInteractionModel?

    var body: some View {
        ConversationCardShell(
            id: snapshot.id,
            title: snapshot.label,
            symbolName: "key.horizontal.fill",
            accessibilityLabel: "Secret entry: \(snapshot.label)"
        ) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                Text(snapshot.purpose)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The value is sent only through the injected secret boundary and is never shown in chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let interaction {
                    SecretCardControls(model: interaction)
                } else {
                    SecretPresenceRow(presence: snapshot.presence)
                    InlineCardReadOnlyNotice()
                }
            }
        }
    }
}

private struct SecretCardControls: View {
    @ObservedObject var model: SecretCardInteractionModel

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            stateNotice
            if !model.state.isTerminal {
                secretInput
            }
        }
    }

    @ViewBuilder
    private var stateNotice: some View {
        switch model.state {
        case .awaitingInput:
            EmptyView()
        case .submitting:
            InlineCardStateLabel(
                text: "Saving through the protected secret boundary…",
                symbolName: "clock.arrow.circlepath",
                role: .neutral
            )
        case .present:
            InlineCardStateLabel(
                text: "Secret present. The value is hidden.",
                symbolName: "checkmark.circle.fill",
                role: .success
            )
        case .failed:
            InlineCardStateLabel(
                text: "The secret wasn’t saved. The entered value was cleared.",
                symbolName: "exclamationmark.triangle.fill",
                role: .failure
            )
        }
    }

    private var secretInput: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            SecureField("Enter secret", text: $model.transientInput)
                .textFieldStyle(.roundedBorder)
                .disabled(!acceptsInput)
                .onSubmit { model.submitSecret() }
                .accessibilityLabel("Secret value")
                .accessibilityValue("Hidden")
                .accessibilityHint("The entered value will be cleared immediately after submission")
                .accessibilityIdentifier("secret-value-\(model.snapshot.id.uuidString)")

            Button("Save Secret") {
                model.submitSecret()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)
            .accessibilityHint("Sends the value once through the protected secret boundary")
            .accessibilityIdentifier("secret-save-\(model.snapshot.id.uuidString)")
        }
    }

    private var acceptsInput: Bool {
        switch model.state {
        case .awaitingInput, .failed:
            true
        case .submitting, .present:
            false
        }
    }
}

private struct SecretPresenceRow: View {
    let presence: SecretPresenceSnapshot

    var body: some View {
        Label(presence.visibleLabel, systemImage: presence.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Secret status: \(presence.visibleLabel). Value hidden.")
    }
}

private struct ConversationCardShell<Content: View>: View {
    let id: UUID
    let title: String
    let symbolName: String
    let accessibilityLabel: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            Label(title, systemImage: symbolName)
                .font(.callout.weight(.semibold))
                .accessibilityHidden(true)
            Divider()
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .background(
            .quaternary,
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
            .stroke(.separator, lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("conversation-card-\(id.uuidString)")
    }
}

private struct InlineCardReadOnlyNotice: View {
    var body: some View {
        Label("Actions unavailable in this read-only view", systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHint("Open the original conversation to use this card")
    }
}

private struct InlineCardStateLabel: View {
    enum Role {
        case neutral
        case success
        case failure
    }

    let text: String
    let symbolName: String
    let role: Role

    var body: some View {
        Label(text, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(foregroundStyle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foregroundStyle: Color {
        switch role {
        case .neutral: .secondary
        case .success: .green
        case .failure: .red
        }
    }
}
