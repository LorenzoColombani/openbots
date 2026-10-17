import OpenBotsServices
import OpenBotsUI
import SwiftUI

@MainActor
struct ClaudeRuntimeSettings: View {
    @ObservedObject var model: ClaudeRuntimeModel
    @ObservedObject var authentication: ClaudeSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Working version", value: model.snapshot.active?.version ?? "Not checked yet")
                .accessibilityIdentifier("settings.runtime.active")
            if let candidate = model.snapshot.candidate {
                LabeledContent("Candidate", value: candidate.version)
                    .accessibilityIdentifier("settings.runtime.candidate")
            }
            if let previous = model.snapshot.previous {
                LabeledContent("Previous version kept", value: previous.version)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.notice ?? model.snapshot.message ?? defaultMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.runtime.status")
            if model.needsAuthentication {
                Text("Sign in once for compatibility checks. New versions use this separate setup until they pass; your working setup stays untouched.")
                    .fixedSize(horizontal: false, vertical: true)
                if authentication.offersSignIn {
                    Button("Sign in for compatibility checks", action: authentication.beginOfficialSignIn)
                        .accessibilityIdentifier("settings.runtime.signIn")
                }
                Button(authentication.preventsApplicationUpdate ? "Check sign-in" : "Check compatibility sign-in",
                       action: authentication.checkSubscription)
                    .disabled(authentication.isBusy)
                    .accessibilityIdentifier("settings.runtime.checkSignIn")
                if authentication.isBusy { ProgressView("Checking sign-in…") }
            }
            HStack {
                if model.isBusy {
                    Button("Cancel check", action: model.cancel)
                        .disabled(model.isCancelingForQuit)
                        .accessibilityIdentifier("settings.runtime.cancel")
                } else {
                    Button(requiresRetry ? "Retry compatibility checks" : "Check for a new Claude version") {
                        if requiresRetry { model.retry() } else { model.check() }
                    }
                    .disabled(!model.canCheck || authentication.preventsApplicationUpdate)
                    .accessibilityIdentifier("settings.runtime.check")
                }
            }
            Text("Checks use up to six short requests from your Claude plan with synthetic data and inert tools. A failed check keeps the working version. Nothing runs while OpenBots is closed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("What is checked") {
                Text("Haiku and Sonnet replies, tool approval and refusal, stopping a process, and continuing a synthetic session. A passing check covers these paths; it cannot guarantee every model, tool or future server change.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.runtime")
    }

    private var requiresRetry: Bool {
        [.failed, .cancelled, .needsAuthentication].contains(model.snapshot.phase)
    }
    private var defaultMessage: String {
        model.hasActiveRuntime
            ? "OpenBots uses its retained, checked Claude version. Your separate Claude Code installation can update independently."
            : "OpenBots must finish compatibility checks before using its first retained Claude version."
    }
}

@MainActor
struct ClaudeRuntimeInteractionGuard: ViewModifier {
    @ObservedObject var model: ClaudeRuntimeModel
    func body(content: Content) -> some View { content.disabled(model.isCancelingForQuit) }
}
