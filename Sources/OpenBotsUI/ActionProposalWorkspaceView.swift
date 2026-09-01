import OpenBotsDomain
import SwiftUI

public struct ActionProposalWorkspaceView: View {
    public enum Mode: Equatable, Sendable {
        case savedRecords
        case developmentDemo
    }

    @ObservedObject private var model: ActionProposalWorkspaceModel
    private let mode: Mode

    public init(model: ActionProposalWorkspaceModel, mode: Mode = .savedRecords) {
        self.model = model
        self.mode = mode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            Label(mode == .savedRecords ? "Saved proposals" : "Action proposals", systemImage: "checkmark.shield").font(.headline)
            Text(mode == .savedRecords
                 ? "Saved local demonstration records. Viewing them never grants access or performs an action."
                 : ActionProposalWorkspaceModel.disclosure)
                .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if model.conversationID == nil {
                note("Choose a teammate conversation to review its local proposals.")
            } else {
                if mode == .developmentDemo {
                    preparationControls
                }
                Button("Refresh Proposals") { Task { await model.load() } }
                    .disabled(!model.canRefresh)
                if model.isBusy { note(model.loadState == .loading ? "Loading saved proposals…" : "Recording local proposal change…") }
                if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true) }
                if let status = model.statusMessage { note(status) }
                if let review = model.selectedReview { reviewCard(review) }
                else if model.loadState == .ready { note("No saved demo proposal in this conversation yet.") }
                if !model.records.isEmpty { history }
                if mode == .developmentDemo {
                    note("Preparing freezes one exact review. A decision records only local state; it never sends, changes files, grants access, or performs the proposed action.")
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .savedRecords
                            ? "Saved proposals. Read-only local demonstration records."
                            : "Action proposals. Local demo decisions only, no execution.")
        .task(id: model.conversationID) { await model.load() }
    }

    private var preparationControls: some View {
        Group {
            Picker("Demo action", selection: $model.selectedAction) {
                ForEach(ConsequentialActionKind.allCases, id: \.self) { action in
                    Text(actionLabel(action)).tag(action)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isBusy)
            Button("Prepare Demo Proposal") { Task { await model.prepareDemoProposal() } }
                .disabled(!model.canPrepare)
        }
    }

    private func reviewCard(_ record: ActionProposalRecord) -> some View {
        let summary = self.summary(record)
        let content = ApprovalReviewContent(record)
        return VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            OutcomeSummaryView(summary: summary)
            if !model.teammateName.isEmpty { field("Teammate", model.teammateName) }
            field("Action", actionLabel(record.proposal.action))
            field("Exact target", content.target)
            Text("Exact payload").font(.caption.weight(.semibold))
            AttachmentPreviewPlainText(text: content.payload)
                .frame(height: 120)
                .accessibilityLabel("Exact immutable proposal payload")
            field("Consequence", content.consequence)
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text("Review expires").font(.caption.weight(.semibold))
                Text(content.expiresAt, style: .date)
                Text(content.expiresAt, style: .time)
            }
            .font(.caption)
            if mode == .developmentDemo {
                developmentReviewControls(record)
            }
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Demo proposal, \(actionLabel(record.proposal.action)). \(summary.title)")
    }

    @ViewBuilder
    private func developmentReviewControls(_ record: ActionProposalRecord) -> some View {
        if record.state == .pending {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                Button("Approve Demo Proposal") { Task { await model.decide(record, decision: .approve) } }
                    .disabled(!model.canDecide(record, decision: .approve))
                Button("Deny Demo Proposal") { Task { await model.decide(record, decision: .deny) } }
                    .disabled(!model.canDecide(record, decision: .deny))
                Button("Cancel Demo Proposal") { Task { await model.decide(record, decision: .cancel) } }
                    .disabled(!model.canDecide(record, decision: .cancel))
            }
            note("Expiry and the exact review are checked again when the decision is recorded. There is no execute step in this demo.")
        } else if record.state == .approved {
            Button("Cancel Demo Approval") { Task { await model.decide(record, decision: .cancel) } }
                .disabled(!model.canDecide(record, decision: .cancel))
            note("Approval is saved locally and can be cancelled. It has not executed anything or granted access.")
        } else {
            note("This decision is final for this review. Prepare a new proposal for another decision. Nothing was executed.")
        }
        if (record.state == .pending || record.state == .approved) && model.isExpired(record) {
            Button("Record Expiry") { Task { await model.decide(record, decision: .expire) } }
                .disabled(!model.canDecide(record, decision: .expire))
            note("The deadline has passed. Recording expiry is an explicit local state change; it does not undo or execute an action.")
        }
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                note("These details identify the saved review. They do not grant access or prove that an action ran.")
                field("Teammate identity", record.proposal.teammateID.rawValue.uuidString)
                field("Review identity", record.id.rawValue.uuidString)
                field("Conversation identity", record.proposal.conversationID.rawValue.uuidString)
                if let runID = record.proposal.runID { field("Run identity", runID.rawValue.uuidString) }
                field("Frozen fingerprint", record.fingerprint)
                Text(record.proposal.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption2).accessibilityLabel("Proposal creation time")
                Text("Profile revision \(record.proposal.profileRevision) · Context revision \(record.proposal.contextRevision) · Review revision \(record.revision)")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, OpenBotsVisualStyle.spacing8)
        }
        .font(.caption)
    }

    private var history: some View {
        DisclosureGroup("Saved Proposal History (\(model.records.count))") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                ForEach(model.records) { record in
                    Button { model.selectReview(record.id) } label: {
                        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                            Text("\(actionLabel(record.proposal.action)) — \(summary(record).title)")
                                .fixedSize(horizontal: false, vertical: true)
                            Text(record.updatedAt, style: .time).font(.caption2)
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel("Inspect \(actionLabel(record.proposal.action)) proposal. \(summary(record).title)")
                }
            }
            .padding(.top, OpenBotsVisualStyle.spacing8)
        }
        .font(.caption)
    }

    private func summary(_ record: ActionProposalRecord) -> OutcomeSummaryPresentation {
        mode == .developmentDemo
            ? OutcomeSummaryPresentation.proposal(record, isExpired: model.isExpired(record))
            : Self.savedRecordSummary(record, isExpired: model.isExpired(record))
    }

    /// A saved deadline does not mutate the stored decision or offer demo
    /// controls. Keep the historical state separate from its present expiry.
    static func savedRecordSummary(_ record: ActionProposalRecord, isExpired: Bool) -> OutcomeSummaryPresentation {
        let saved = OutcomeSummaryPresentation.proposal(record, isExpired: false)
        let deadlinePassed = (record.state == .pending || record.state == .approved) && isExpired
        return .init(
            title: record.state == .pending ? "Saved proposal awaiting a decision" : saved.title,
            result: saved.result,
            attention: deadlinePassed
                ? "Its review deadline has passed. The saved decision has not been changed."
                : saved.attention,
            nextStep: "Review the saved details below. Nothing will be executed.",
            symbol: saved.symbol
        )
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(label).font(.caption.weight(.semibold))
            StableSelectableText(value, style: .caption)
                .accessibilityLabel("\(label): \(value)")
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func actionLabel(_ action: ConsequentialActionKind) -> String {
        switch action {
        case .send: "Send"; case .publish: "Publish"; case .delete: "Delete"; case .overwrite: "Overwrite"
        case .move: "Move"; case .rename: "Rename"; case .metadataMutation: "Change metadata"
        case .purchase: "Purchase"; case .packageInstall: "Install a package"; case .calendarChange: "Change calendar"
        case .productionChange: "Change production"; case .deployment: "Deploy"; case .credentialAccess: "Access credentials"
        case .permissionChange: "Change permissions"
        }
    }
}
