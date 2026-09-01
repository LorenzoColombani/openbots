import SwiftUI

/// Compact, read-only knowledge surface intended for the Work Context
/// inspector. It exposes validated OpenBots Markdown and an explicit
/// non-authoritative snapshot flow without presenting an editor.
public struct KnowledgeWorkspaceView: View {
    @ObservedObject private var model: KnowledgeWorkspaceModel

    public init(model: KnowledgeWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            header
            stateContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Knowledge")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label("Knowledge", systemImage: "books.vertical")
                .font(.headline)
            Text("Scoped memory for the active teammate and project")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.loadState {
        case .unavailable(let reason):
            statusLabel(reason, symbol: "person.crop.circle.badge.questionmark")
        case .idle:
            statusLabel("Knowledge is ready to load for this context.", symbol: "book.closed")
        case .loading:
            statusLabel("Loading verified local knowledge", symbol: "clock")
        case .failed(let reason):
            statusLabel(reason, symbol: "exclamationmark.triangle", isFailure: true)
        case .ready(let snapshot):
            readyContent(snapshot)
        }
    }

    private func statusLabel(
        _ text: String,
        symbol: String,
        isFailure: Bool = false
    ) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func readyContent(_ snapshot: KnowledgeWorkspaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            authorityHeader(snapshot)

            if snapshot.documents.isEmpty {
                statusLabel(
                    "No authoritative Markdown is available in this scope yet.",
                    symbol: "doc.text"
                )
            } else {
                ForEach(snapshot.documents) { document in
                    documentCard(document)
                }
                snapshotActions(snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func authorityHeader(_ snapshot: KnowledgeWorkspaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label(snapshot.authorityLabel, systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
            Text(snapshot.authorityDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.excludedDocumentCount > 0 {
                Text("\(snapshot.excludedDocumentCount) out-of-scope document(s) were excluded before content was read.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func documentCard(_ document: KnowledgeDocumentPresentation) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(document.scope.visibleLabel) • Revision \(document.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(document.author.provenanceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Updated " + document.freshnessLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(document.accessibilityDescription)

            if let recovery = document.recovery.visibleLabel {
                Label(recovery, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Recovered knowledge. " + recovery)
            }

            Divider()

            StableSelectableText(document.markdown, style: .callout)
                .accessibilityLabel("Markdown content for " + document.title)

            Button {
                Task { await model.revealInFinder(documentID: document.id) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.link)
            .disabled(
                !document.canRevealInFinder
                    || model.revealingDocumentID != nil
            )
            .accessibilityLabel("Reveal \(document.title) in Finder")
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusSmall))
    }

    private func snapshotActions(_ snapshot: KnowledgeWorkspaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Divider()

            if let revealFailure = model.revealFailure {
                statusLabel(revealFailure, symbol: "exclamationmark.triangle", isFailure: true)
            }

            if let pending = model.pendingSnapshot {
                snapshotConfirmation(pending)
            } else if model.isCreatingSnapshot {
                statusLabel("Creating the approved snapshot", symbol: "clock")
            } else {
                Button {
                    Task { await model.selectSnapshotDestination() }
                } label: {
                    Label("Create Obsidian Snapshot…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canChooseSnapshotDestination)
                .accessibilityHint(
                    "Choose one exact local destination. Choosing alone does not create a file."
                )
            }

            if model.isChoosingSnapshotDestination {
                statusLabel("Waiting for an exact destination", symbol: "folder.badge.questionmark")
            }

            if let snapshotFailure = model.snapshotFailure {
                statusLabel(snapshotFailure, symbol: "exclamationmark.triangle", isFailure: true)
            }

            if let receipt = model.snapshotReceipt {
                snapshotReceipt(receipt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Obsidian snapshot actions for \(snapshot.documents.count) documents")
    }

    private func snapshotConfirmation(_ pending: PendingKnowledgeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Label("Confirm exact snapshot target", systemImage: "doc.badge.plus")
                .font(.caption.weight(.semibold))
            Text("Exact target")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            StableSelectableText(
                pending.destination.exactDisplayPath,
                style: .caption,
                tone: .secondary
            )
            Text("Create-new only. This copy is non-authoritative, and edits do not flow back to OpenBots.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                Button("Cancel") {
                    Task { await model.cancelPendingSnapshot() }
                }
                .keyboardShortcut(.cancelAction)

                Button("Create Snapshot") {
                    Task { await model.confirmSnapshotCreation() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Confirm snapshot creation at \(pending.destination.exactDisplayPath)"
        )
    }

    private func snapshotReceipt(_ receipt: KnowledgeSnapshotReceipt) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label("Snapshot created", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            StableSelectableText(
                receipt.exactDisplayPath,
                style: .caption,
                tone: .secondary
            )
            Text(receipt.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Snapshot created at \(receipt.exactDisplayPath). \(receipt.disclosure)"
        )
    }
}
