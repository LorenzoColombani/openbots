import OpenBotsDomain
import SwiftUI

/// A bounded, local-only demonstration in Work Context. Journal status is not
/// proof of a running process, Claude acknowledgement or tool execution.
public struct RunRecoveryWorkspaceView: View {
    @ObservedObject private var model: RunRecoveryWorkspaceModel

    public init(model: RunRecoveryWorkspaceModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Label("Run history", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text(RunRecoveryWorkspaceModel.disclosure)
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Start Demo uses an already-saved user message. It doesn’t send your draft or run its instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.conversationID == nil {
                status("Choose a teammate conversation to view its run history.", symbol: "person.crop.circle")
            } else {
                actions
                if model.isBusy {
                    status(model.loadState == .loading ? "Loading local run history…" : "Recording local demo change…", symbol: "clock")
                }
                if let error = model.errorMessage { status(error, symbol: "exclamationmark.triangle") }
                if let message = model.statusMessage { status(message, symbol: "info.circle") }
                if model.loadState == .ready, model.reviews.isEmpty {
                    status("No saved runs in this conversation yet.", symbol: "tray")
                }
                ForEach(model.visibleReviews) { review in
                    runCard(review)
                }
                if model.reviews.count > model.visibleReviews.count {
                    status("Showing the latest \(model.visibleReviews.count) of \(model.reviews.count) loaded runs.", symbol: "list.bullet")
                }
                Text("An action may finish after you switch conversations. Refresh to inspect its saved history; switching does not undo a submitted demo action.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run history. Local recovery demo. No Claude or tools run.")
        .task(id: model.conversationID) { await model.load() }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                Button("Start Demo") { Task { await model.startDemo() } }
                    .disabled(!model.canStartDemo)
                Button("Refresh") { Task { await model.load() } }
                    .disabled(!model.canRefresh)
            }
            Button("Recover Expired Demos") { Task { await model.recoverExpiredDemos() } }
                .disabled(!model.canMutate)
                .help("Review demos whose time window ended. This never restarts work or resends a message.")
        }
        .controlSize(.small)
    }

    private func runCard(_ review: RunRecoveryReview) -> some View {
        let summary = OutcomeSummaryPresentation.run(review)
        return VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            OutcomeSummaryView(summary: summary)
            HStack(spacing: OpenBotsVisualStyle.spacing4) {
                Text("Updated")
                Text(review.record.updatedAt, style: .date)
                Text(review.record.updatedAt, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if review.record.origin == .localFixture {
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    Button("Record Demo Acknowledgement") {
                        Task { await model.acknowledgeDemo(runID: review.id.rawValue, expectedRevision: review.record.revision) }
                    }
                    .disabled(!model.canAcknowledge(review))
                    Button("Finish Demo") { Task { await model.finishDemo(runID: review.id.rawValue, expectedRevision: review.record.revision) } }
                        .disabled(!model.canFinish(review))
                    Button("Request Demo Stop") { Task { await model.requestStopDemo(runID: review.id.rawValue, expectedRevision: review.record.revision) } }
                        .disabled(!model.canRequestStop(review))
                    if review.record.state == .stopping {
                        Button("Finish Demo Stop") { Task { await model.interruptDemo(runID: review.id.rawValue, expectedRevision: review.record.revision) } }
                            .disabled(!model.canInterrupt(review))
                        Text("Finishing a demo stop records an interruption, not successful work.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button("Interrupt Demo") { Task { await model.interruptDemo(runID: review.id.rawValue, expectedRevision: review.record.revision) } }
                            .disabled(!model.canInterrupt(review))
                    }
                    Button("Fail Demo") { Task { await model.failDemo(runID: review.id.rawValue, expectedRevision: review.record.revision) } }
                        .disabled(!model.canFail(review))
                }
                .controlSize(.small)
            }
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    Text("These are saved local-demo records, not evidence of real execution.").font(.caption)
                    StableSelectableText("Run identity: \(review.id.rawValue.uuidString)", style: .caption)
                    Text("Revision \(review.record.revision)").font(.caption)
                    if let lease = review.record.lease {
                        Text("Local demo lease expires").font(.caption)
                        Text(lease.expiresAt, style: .date).font(.caption2)
                        Text(lease.expiresAt, style: .time).font(.caption2)
                    }
                    if review.inputs.isEmpty { Text("No input receipt recorded yet.").font(.caption) }
                    ForEach(Array(review.inputs.sorted { $0.sequence < $1.sequence }.prefix(4))) { input in
                        Text("Input \(input.sequence): \(inputLabel(input.state))").font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if review.inputs.count > 4 {
                        Text("Showing 4 of \(review.inputs.count) recorded input receipts.").font(.caption2)
                    }
                    if review.entries.isEmpty { Text("No journal entries recorded yet.").font(.caption) }
                    ForEach(Array(review.entries.sorted { $0.sequence < $1.sequence }.suffix(8))) { entry in
                        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                            Text("\(entry.sequence). \(entryLabel(entry.kind))")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.recordedAt, style: .time)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if review.entries.count > 8 {
                        Text("Showing the latest 8 of \(review.entries.count) loaded journal entries.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, OpenBotsVisualStyle.spacing8)
            }
            .font(.caption)
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local demo. \(summary.title)")
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inputLabel(_ state: RunInputState) -> String {
        switch state {
        case .queued: "Queued locally"
        case .submitted: "Submitted in demo — not acknowledged"
        case .acknowledged: "Acknowledged in demo"
        case .outcomeUnknown: "Outcome unknown — not retried"
        }
    }
    private func entryLabel(_ kind: RunJournalEntryKind) -> String {
        switch kind {
        case .enqueued: "Demo enqueued"
        case .claimed: "Local demo lease claimed"
        case .leaseRenewed: "Local demo lease renewed"
        case .stateChanged: "State recorded"
        case .inputQueued: "Input queued locally"
        case .inputSubmitted: "Demo input submission recorded"
        case .inputAcknowledged: "Demo acknowledgement recorded"
        case .recovered: "Expired demo marked interrupted"
        }
    }
}
