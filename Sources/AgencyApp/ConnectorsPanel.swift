import SwiftUI
import AgencyKit

/// The app-wide connector catalog (his ruling 2026-08-13): a visibility and
/// enablement panel — "it does not give access to agents, it just helps me
/// see which connectors I have enabled." Grants happen per agent, in the
/// profile sheet, from the enabled subset shown here.
struct ConnectorsPanel: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connectors").font(.title2.bold())
            Text("Enabling here only lists a connector as available — no agent can use it until you grant it in that agent's profile.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(Connector.catalog) { c in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(
                        get: { enabled.contains(c.id) },
                        set: { on in
                            do {
                                try state.catalog.setEnabled(c.id, on)
                                if on { enabled.insert(c.id) } else { enabled.remove(c.id) }
                            } catch { self.error = "\(error)" }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.displayName).font(.headline)
                                if c.requiresSetup {
                                    Text("needs setup")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.yellow.opacity(0.25), in: Capsule())
                                }
                            }
                            Text(c.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 4)
            }

            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 440)
        .onAppear { enabled = state.catalog.enabledIDs() }
    }
}
