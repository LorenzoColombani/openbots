import SwiftUI
import AgencyKit

/// Hiring, as a short guided conversation instead of one overloaded form
/// (structure audit R5 + the SPEC's creation-interview item). Two steps: who
/// they are, then what they're for — and the model comes from a STRUCTURED
/// answer about the work, not from keyword-matching a job description.
///
/// Deliberately NOT a live interview run: that would spend real subscription
/// usage on every hire, and every question here is one the app can ask itself.
struct CreateAgentSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var title = ""
    @State private var role = ""
    @State private var primaryJob = ""
    @State private var instructions = ""
    @State private var workKind: AgentStore.WorkKind = .everyday
    @State private var modelOverride: String?
    @State private var error: String?

    /// ONE cleaning rule, computed once (review #3 minor 9: the button guard and
    /// the create call each computed their own copy — they must never drift).
    /// ASCII-only: "José" would otherwise clean to "josé", which the validator
    /// rejects with the button silently greyed and no explanation.
    private var clean: String {
        name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    private var chosenModel: String { modelOverride ?? AgentStore.suggestModel(for: workKind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(step == 1 ? "New teammate — who are they?" : "New teammate — what are they for?")
                .font(.title2.bold())
            if step == 1 { stepOne } else { stepTwo }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if step == 2 { Button("Back") { step = 1 } }
                Spacer()
                Button("Cancel") { dismiss() }
                if step == 1 {
                    Button("Next") { step = 2 }
                        .keyboardShortcut(.defaultAction)
                        // Validate the CLEANED name: "***" cleans to "", which
                        // previously enabled Create and claimed agents/ itself
                        // (review #1 I6).
                        .disabled(!AgentStore.isValidName(clean))
                } else {
                    Button("Hire \(title.isEmpty ? clean : clean)") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(role.isEmpty && primaryJob.isEmpty)
                }
            }
        }
        .padding(20).frame(width: 420)
    }

    @ViewBuilder private var stepOne: some View {
        TextField("Name (short, lowercase — this is their @handle, forever)", text: $name)
        if !name.isEmpty && !AgentStore.isValidName(clean) {
            Text("Names use a–z and 0–9 only (1–32 characters).")
                .font(.caption).foregroundStyle(.orange)
        } else if !name.isEmpty && clean != name {
            Text("Will be created as “\(clean)”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("The handle can never change — folders, relays and their memory hang off it. The display name can.")
            .font(.caption2).foregroundStyle(.secondary)
        TextField("Emoji avatar", text: $emoji)
        Text("Title — a short label, e.g. “Correspondence”, “Research”")
            .font(.caption).foregroundStyle(.secondary)
        TextField("Title (optional)", text: $title)
    }

    @ViewBuilder private var stepTwo: some View {
        Text("Primary job — the one thing they're for")
            .font(.caption).foregroundStyle(.secondary)
        TextField("e.g. Read and triage the agency inbox", text: $primaryJob, axis: .vertical)
            .lineLimit(1...3)
        Text("Description — how you'd introduce them")
            .font(.caption).foregroundStyle(.secondary)
        TextField("e.g. Handles mail and the calendar", text: $role, axis: .vertical)
            .lineLimit(1...3)
        Text("What kind of work is it? (this picks the model)")
            .font(.caption).foregroundStyle(.secondary)
        Picker("", selection: $workKind) {
            ForEach(AgentStore.WorkKind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.radioGroup).labelsHidden()
        .onChange(of: workKind) { modelOverride = nil }
        HStack(spacing: 6) {
            Text("Model: **\(chosenModel)**\(modelOverride == nil ? " (chosen for you)" : " (your choice)")")
                .font(.caption)
            Menu("change") {
                Button("auto — \(AgentStore.suggestModel(for: workKind))") { modelOverride = nil }
                ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                    Button(m) { modelOverride = m }
                }
            }
            .fixedSize()
        }
        Text("Standing instructions — your rules for them (optional, editable later)")
            .font(.caption).foregroundStyle(.secondary)
        TextField("e.g. Draft, never send without asking.", text: $instructions, axis: .vertical)
            .lineLimit(2...5)
        Text("They start fully sealed: no shell, no web, no connectors. Grant what they need in their profile.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func create() {
        do {
            _ = try state.store.createAgent(
                name: clean, emoji: emoji,
                role: role.isEmpty ? primaryJob : role,
                model: chosenModel,
                title: title.isEmpty ? nil : title,
                primaryJob: primaryJob.isEmpty ? nil : primaryJob,
                instructions: instructions.isEmpty ? nil : instructions)
            state.reload(); state.selected = clean; dismiss()
        } catch { self.error = "\(error)" }
    }
}
