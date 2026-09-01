import OpenBotsDomain
import SwiftUI

/// Explicit inspection only. Mounting this view never reads saved history.
public struct SavedOutcomeHistoryView: View {
    @ObservedObject private var model: SavedOutcomeHistoryModel

    public init(model: SavedOutcomeHistoryModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Label("Saved outcomes", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if model.isClosing {
                note("OpenBots is closing. Saved-outcome reads have stopped.")
            } else if model.request == nil {
                note("Choose a teammate conversation to inspect its saved outcomes.")
            } else if !model.hasRequested {
                note("Review saved results and decisions for this conversation when you need them.")
                Button("Show Saved Outcomes") { Task { await model.load() } }
                    .disabled(!model.canLoad)
            } else {
                controls
                if model.isLoading {
                    note("Reading saved outcomes for this conversation…")
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = model.summary {
                    note(summary.notice)
                    ForEach(summary.outcomes, id: \.reference) { outcome in
                        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                            Text(outcome.text)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: OpenBotsVisualStyle.spacing4) {
                                Text(outcome.recordedAt, style: .date)
                                Text(outcome.recordedAt, style: .time)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved outcomes for this conversation")
        .onDisappear { model.dismiss() }
    }

    private var controls: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing8) {
            if model.errorMessage != nil {
                Button("Retry Saved Outcomes") { Task { await model.load() } }
                    .disabled(!model.canLoad)
            } else {
                Button("Refresh") { Task { await model.load() } }
                    .disabled(!model.canLoad)
            }
            Button("Hide") { model.dismiss() }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
