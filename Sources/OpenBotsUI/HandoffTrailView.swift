import SwiftUI

/// A static, provenance-first handoff trail. S3A deliberately adds no motion:
/// Reduce Motion therefore preserves exactly the same identities, chronology,
/// recovery, and fan-in result rather than substituting a weaker state.
struct HandoffTrailView: View {
    let snapshot: ChatHandoffTrailSnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                participantRoute
                brief
                Divider()
                timeline
                if let recoveryMessage = snapshot.recoveryMessage {
                    recovery(message: recoveryMessage)
                }
                if let resultSummary = snapshot.resultSummary {
                    returnedResult(summary: resultSummary)
                }
                Text(snapshot.fixtureDisclosure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Fixture disclosure. \(snapshot.fixtureDisclosure)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Local handoff fixture", systemImage: snapshot.state.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(snapshot.state == .needsRecovery ? .red : .secondary)
                .accessibilityLabel(
                    "Local handoff fixture. Status: \(snapshot.state.visibleLabel)."
                )
        }
    }

    private var participantRoute: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OpenBotsVisualStyle.spacing12) {
                participant(snapshot.sender, label: "Sender")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                participant(snapshot.receiver, label: "Receiver")
                Spacer(minLength: OpenBotsVisualStyle.spacing8)
            }
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                participant(snapshot.sender, label: "Sender")
                Label("Handed to", systemImage: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                participant(snapshot.receiver, label: "Receiver")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Handoff from \(snapshot.sender.name), \(snapshot.sender.role), "
                + "to \(snapshot.receiver.name), \(snapshot.receiver.role)."
        )
    }

    private func participant(
        _ identity: TeammateIdentitySnapshot,
        label: String
    ) -> some View {
        HStack(spacing: OpenBotsVisualStyle.spacing8) {
            CharacterIdentityView(
                teammate: TeammateRowSnapshot(identity: identity, activity: .idle),
                size: 30
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(identity.name)
                    .font(.callout.weight(.semibold))
                    .fontDesign(.rounded)
                Text(identity.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var brief: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            LabeledContent("Goal") {
                StableSelectableText(snapshot.goal, style: .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledContent("Requested result") {
                StableSelectableText(snapshot.requestedOutput, style: .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledContent("Stop boundary") {
                StableSelectableText(snapshot.stopOrApprovalBoundary, style: .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            Text("Activity trail")
                .font(.callout.weight(.semibold))
            ForEach(snapshot.timeline) { entry in
                HStack(alignment: .top, spacing: OpenBotsVisualStyle.spacing8) {
                    Image(systemName: entry.state.symbolName)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(entry.state == .needsRecovery ? .red : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                        HStack(alignment: .firstTextBaseline, spacing: OpenBotsVisualStyle.spacing8) {
                            Text(entry.actor.name)
                                .font(.caption.weight(.semibold))
                            Text(entry.state.visibleLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: OpenBotsVisualStyle.spacing4)
                            Text(entry.timestamp, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.summary)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(entry.actor.name). \(entry.state.visibleLabel). "
                        + "\(entry.summary). \(entry.timestamp.formatted(date: .omitted, time: .shortened))."
                )
            }
        }
    }

    private func recovery(message: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text("Recovery required")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding(OpenBotsVisualStyle.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func returnedResult(summary: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text("Result returned to \(snapshot.sender.name)")
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle.fill")
        }
        .padding(OpenBotsVisualStyle.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
