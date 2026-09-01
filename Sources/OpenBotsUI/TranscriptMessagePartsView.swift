import SwiftUI

extension ChatMessageSnapshot {
    /// App-authored status text has no action. Mixed messages keep their card
    /// presentation so this treatment never changes an embedded approval.
    var isInformationalSystemStatus: Bool {
        guard case .system = author, !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            if case .status = part.content { return true }
            return false
        }
    }
}

/// Renders the ordered presentation parts already resolved by the conversation
/// boundary. Resource cards are deliberately non-interactive until a brokered
/// open/reveal action is injected; their presence never implies ambient access.
struct TranscriptMessagePartsView: View {
    enum TextStyle {
        case regular
        case system
    }

    let message: ChatMessageSnapshot
    var textStyle: TextStyle = .regular
    var cardInteractions: ConversationCardInteractionModel?

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            if message.parts.isEmpty {
                emptyContent
            } else {
                ForEach(message.parts) { part in
                    partView(part)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyContent: some View {
        if message.streamState == .streaming {
            Label("Receiving response", systemImage: "waveform")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !message.body.isEmpty {
            text(message.body)
        }
    }

    @ViewBuilder
    private func partView(_ part: ChatMessagePartSnapshot) -> some View {
        switch part.content {
        case .text(let content):
            text(content)
        case .status(let status):
            if message.isInformationalSystemStatus {
                StableSelectableText(status, style: .callout, tone: .secondary)
                    .accessibilityLabel("Status: \(status)")
            } else {
                Label(status, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, OpenBotsVisualStyle.spacing8)
                    .padding(.vertical, OpenBotsVisualStyle.spacing4)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(
                            cornerRadius: OpenBotsVisualStyle.radiusSmall,
                            style: .continuous
                        )
                    )
                    .accessibilityLabel("Status: \(status)")
            }
        case .attachment(let attachment):
            AttachmentPartChip(messageID: message.id, partID: part.id, attachment: attachment)
        case .artifact(let artifact):
            ArtifactPartCard(artifact: artifact)
        case .question(let question):
            InlineQuestionCardView(
                snapshot: question,
                interaction: cardInteractions?.question(
                    messageID: message.id,
                    partID: part.id,
                    cardID: question.id
                )
            )
        case .connectorSetup(let connector):
            InlineConnectorSetupCardView(
                snapshot: connector,
                interaction: cardInteractions?.connector(
                    messageID: message.id,
                    partID: part.id,
                    cardID: connector.id
                )
            )
        case .secret(let secret):
            InlineSecretCardView(
                snapshot: secret,
                interaction: cardInteractions?.secret(
                    messageID: message.id,
                    partID: part.id,
                    cardID: secret.id
                )
            )
        case .handoff(let handoff):
            HandoffTrailView(snapshot: handoff)
        }
    }

    @ViewBuilder
    private func text(_ content: String) -> some View {
        if case .teammate = message.author, textStyle == .regular {
            SafeReplyMarkdownText(content: content)
        } else {
            StableSelectableText(
                content,
                style: textStyle == .regular ? .body : .callout,
                tone: textStyle == .regular ? .primary : .secondary
            )
        }
    }
}

private struct AttachmentPartChip: View {
    @Environment(\.attachmentPresentation) private var presentation
    @StateObject private var model = AttachmentPartPresentationModel()
    @StateObject private var previewModel = AttachmentPreviewModel()
    let messageID: UUID
    let partID: UUID
    let attachment: ChatAttachmentSnapshot

    private var route: AttachmentPresentationRoute {
        AttachmentPresentationRoute(messageID: messageID, partID: partID, attachmentID: attachment.id)
    }

    private var displayName: String { model.asset?.displayName ?? attachment.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                    Text(displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let asset = model.asset {
                        Text("\(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file)) · Saved local copy")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let detail = attachment.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if presentation != nil {
                HStack(spacing: OpenBotsVisualStyle.spacing8) {
                    if let previewer = presentation?.preview {
                        Button("Preview") {
                            guard let asset = model.asset else { return }
                            previewModel.open(route: route, displayName: asset.displayName, previewer: previewer)
                        }
                        .disabled(model.asset == nil || model.isLoading || model.isRevealing)
                        .accessibilityLabel("Preview \(displayName)")
                        .accessibilityIdentifier("attachment-preview-\(messageID)-\(partID)")
                        .help("Inspect a bounded read-only preview of the saved local copy")
                    }
                    Button("Reveal in Finder") { Task { await model.reveal() } }
                        .disabled(!model.canReveal)
                        .accessibilityLabel("Reveal \(displayName) in Finder")
                        .accessibilityIdentifier("attachment-reveal-\(messageID)-\(partID)")
                        .help("Show the saved local copy without opening or executing it")
                }
                if model.isLoading || model.isRevealing {
                    HStack(spacing: OpenBotsVisualStyle.spacing8) {
                        ProgressView().controlSize(.small)
                        Text(model.isLoading ? "Loading attachment…" : "Revealing attachment…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reload Attachment") {
                        Task { await model.load(route: route, presentation: presentation, force: true) }
                    }
                    .disabled(model.isLoading || model.isRevealing)
                    .accessibilityLabel("Reload \(displayName)")
                    .accessibilityIdentifier("attachment-reload-\(messageID)-\(partID)")
                }
            }
        }
        .padding(.horizontal, OpenBotsVisualStyle.spacing12)
        .padding(.vertical, OpenBotsVisualStyle.spacing8)
        .background(
            .quaternary,
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusLarge,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("attachment-\(messageID)-\(partID)")
        .task(id: route) { await model.load(route: route, presentation: presentation) }
        .sheet(isPresented: Binding(
            get: { previewModel.isPresented },
            set: { if !$0 { previewModel.close() } }
        )) {
            AttachmentPreviewView(model: previewModel)
        }
        .onChange(of: route) { _, _ in previewModel.close() }
        .onDisappear { previewModel.close() }
    }

    private var accessibilityLabel: String {
        ["Attachment: \(displayName)", attachment.detail]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

private struct ArtifactPartCard: View {
    let artifact: ChatArtifactSnapshot

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: OpenBotsVisualStyle.spacing12) {
                Image(systemName: "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                    Text(artifact.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if let detail = artifact.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: OpenBotsVisualStyle.spacing8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Artifact", systemImage: "sparkles.rectangle.stack")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        ["Artifact: \(artifact.title)", artifact.detail]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
