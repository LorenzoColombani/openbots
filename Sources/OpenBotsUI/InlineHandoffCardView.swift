import SwiftUI

/// A handoff is a record, not a console. A lead delegating to a member of its
/// own team dispatches itself, so the transcript shows one quiet line — who
/// asked whom, for what, and where it got to — and the brief only when the
/// reader opens it. Collapsed is the default in every state, including the
/// ones that failed: the line already says so.
///
/// At most one control, and only on the two records nothing else will move: a
/// brief left staged by an earlier session, and one stalled at `accepted`. It
/// has no keyboard equivalent for the same reason the old Send had none: a
/// stray Return with the composer unfocused, or two cards competing for the
/// window's default button, must never be able to run a member.
struct InlineHandoffCardView: View {
    let snapshot: ChatHandoffCardSnapshot
    let interaction: HandoffCardInteractionModel?

    @State private var isShowingBrief = false

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            HStack(alignment: .firstTextBaseline, spacing: OpenBotsVisualStyle.spacing8) {
                summary
                Spacer(minLength: OpenBotsVisualStyle.spacing8)
                Button(isShowingBrief ? "Hide brief" : "Show brief") {
                    isShowingBrief.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(isShowingBrief ? "Hide what the lead asked for" : "Show what the lead asked for")
                .accessibilityIdentifier("handoff-disclosure-\(snapshot.id.uuidString)")
            }
            if isShowingBrief {
                HandoffTrailView(snapshot: snapshot.trail, showsStatusHeader: false)
            }
            if let label = snapshot.controlLabel, let interaction {
                HandoffCardControls(model: interaction, label: label, receiverName: snapshot.receiverName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-card-\(snapshot.id.uuidString)")
    }

    private var summary: some View {
        Label {
            Text(snapshot.summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: snapshot.trail.state.symbolName)
                .font(.caption)
                .foregroundStyle(snapshot.trail.state == .needsRecovery ? .red : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.collapsedAccessibilityLabel)
    }
}

/// The single button a stalled brief carries. Its words come from the card,
/// which is the only thing that knows why this one needs a person.
private struct HandoffCardControls: View {
    @ObservedObject var model: HandoffCardInteractionModel
    let label: String
    let receiverName: String

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            switch model.state {
            case .ready, .failed:
                Button(label) { model.send() }
                    .help("Send this brief to \(receiverName)")
                    .accessibilityIdentifier("handoff-send-\(model.snapshot.id.uuidString)")
                if case .failed(let message) = model.state {
                    InlineCardStateLabel(text: message, symbolName: "exclamationmark.triangle", role: .failure)
                }
            case .sending:
                InlineCardStateLabel(text: "Sending to \(receiverName)…", symbolName: "paperplane", role: .neutral)
            case .sent:
                InlineCardStateLabel(text: "Sent to \(receiverName)", symbolName: "checkmark.circle", role: .success)
            case .declining, .declined:
                // Nothing declines a handoff any more. The states remain on the
                // interaction model, which this view does not reshape.
                EmptyView()
            }
        }
    }
}
