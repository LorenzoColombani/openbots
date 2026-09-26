import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// One handoff card on the record, with the leg it belongs to so its control
/// keeps the route the interaction registry knows.
public struct WorkRecordHandoffCard: Identifiable, Equatable, Sendable {
    public let card: ChatHandoffCardSnapshot
    public let legID: UUID
    public var id: UUID { card.id }
    public init(card: ChatHandoffCardSnapshot, legID: UUID) { self.card = card; self.legID = legID }
}

/// The "what happened" record of the open conversation: the briefs
/// between bots with their controls, each member's report, the cards the user
/// answered and what each bot did on the Mac. Never the answer bubble.
struct ConversationWorkRecordView: View {
    @ObservedObject var model: DurableWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("What happened")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { model.closeWorkRecord() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("work-record.done")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isEmpty {
                        Text("Nothing on the record yet. Briefs between bots, the cards you answer and what a bot does on the Mac show up here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.handoffCards.isEmpty {
                        RecordSection(title: "Handoffs") {
                            ForEach(model.handoffCards) { entry in
                                RecordHandoffEntry(entry: entry, model: model)
                            }
                        }
                    }
                    if let approvals = model.workRecord?.approvals, !approvals.isEmpty {
                        RecordSection(title: "Cards you answered") {
                            ForEach(approvals, id: \.id.rawValue) { approval in
                                RecordApprovalRow(approval: approval)
                            }
                        }
                    }
                    if let lines = model.workRecord?.lines, !lines.isEmpty {
                        RecordSection(title: "What the bots did") {
                            ForEach(lines) { line in
                                RecordActivityRow(line: line)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 660, minHeight: 420, idealHeight: 580)
        .background(OpenBotsVisualStyle.canvas(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work-record")
    }

    private var isEmpty: Bool {
        model.handoffCards.isEmpty && (model.workRecord?.isEmpty ?? true)
    }
}

private struct RecordSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct RecordHandoffEntry: View {
    let entry: WorkRecordHandoffCard
    @ObservedObject var model: DurableWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme

    private var report: (name: String, text: String)? {
        guard let handoff = model.workRecord?.handoffs.first(where: { $0.id.rawValue == entry.id }),
              let text = handoff.reportText, !text.isEmpty else { return nil }
        return (handoff.receiverName, text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineHandoffCardView(
                snapshot: entry.card,
                interaction: model.cardInteractions?.handoff(messageID: entry.id, partID: entry.legID, cardID: entry.id)
            )
            if let report {
                DisclosureGroup("Report from \(report.name)") {
                    Text(report.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
                .accessibilityIdentifier("work-record.report-\(entry.id.uuidString)")
            }
        }
        .padding(12)
        .background(OpenBotsVisualStyle.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
    }
}

private let recordTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

private struct RecordApprovalRow: View {
    let approval: ApprovalRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(recordTimeFormatter.string(from: approval.requestedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(approval.consequenceSummary).font(.callout)
                Text(approval.exactTargetSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(verdict)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var verdict: String {
        switch approval.state {
        case .pending: "Waiting"
        case .approved, .executing, .succeeded: "Approved"
        case .denied: "Denied"
        case .expired: "Expired"
        default: approval.state.rawValue.capitalized
        }
    }
}

private struct RecordActivityRow: View {
    let line: ConversationWorkRecord.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(recordTimeFormatter.string(from: line.at))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(line.botName).font(.callout.weight(.semibold))
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
