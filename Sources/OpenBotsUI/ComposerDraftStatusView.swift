import AppKit
import SwiftUI

@MainActor
struct ComposerDraftStatusContainer: View {
    @ObservedObject var coordinator: WorkspaceDraftCoordinator

    var body: some View {
        if let draft = coordinator.activeDraft {
            ComposerDraftStatusView(model: draft)
        }
    }
}

@MainActor
struct ComposerDraftStatusView: View {
    @ObservedObject var model: ConversationComposerDraftModel

    var body: some View {
        if Self.needsAttention(model.status) {
            attentionContent
        }
    }

    static func needsAttention(_ status: ConversationComposerDraftStatus) -> Bool {
        switch status {
        case .failed, .conflict, .recovery: true
        case .loading, .unsaved, .saving, .saved, .waitingForMessage: false
        }
    }

    private var attentionContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Local draft. \(model.statusText)")
            if let notice = model.notice {
                Text(notice).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasConflict {
                if let saved = model.conflictingSavedText {
                    Text("Saved draft preview: \(String(saved.prefix(500)))")
                        .font(.caption)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Reload Saved Draft") { Task { _ = await model.reloadSavedDraft() } }
                    Button("Keep This Draft") { Task { _ = await model.keepThisDraft() } }
                }
                .controlSize(.small)
            } else if model.recoverableFailedText != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Restore Earlier Message") { _ = model.restoreFailedText() }
                        .disabled(!model.text.isEmpty)
                    Button("Copy Earlier Message and Keep New Draft") {
                        guard let text = model.recoverableFailedText else { return }
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(text, forType: .string) {
                            model.acknowledgeFailedTextRecovery()
                        }
                    }
                    Text("Copy places the earlier text on your Mac’s clipboard and allows the newer draft to save.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .controlSize(.small)
            } else if model.status == .failed {
                Button("Retry Saving Draft") { Task { _ = await model.flush() } }
                    .controlSize(.small)
            }
        }
    }
}
