import OpenBotsServices
import SwiftUI

/// Opening Settings is inert. Local checks and each guarded provider step
/// have separate actions; installation evidence never implies a connection.
public struct ClaudeSetupView: View {
    @ObservedObject private var model: ClaudeSetupModel
    private let usesReviewFixtures: Bool
    private let textRepliesEnabled: Bool

    public init(model: ClaudeSetupModel, usesReviewFixtures: Bool = false, textRepliesEnabled: Bool = false) {
        self.model = model
        self.usesReviewFixtures = usesReviewFixtures
        self.textRepliesEnabled = textRepliesEnabled
    }

    /// Compatibility for isolated previews/tests. App composition supplies the
    /// actual service; this fallback neither inspects nor launches anything.
    public init(usesReviewFixtures: Bool = false) {
        self.init(
            model: ClaudeSetupModel(service: GuardedClaudeSetupService(
                inspector: UnconfiguredClaudeSetupInspector()
            )),
            usesReviewFixtures: usesReviewFixtures
        )
    }

    public var body: some View {
        Form {
            Section("Claude") {
                if model.state == .checkingSubscription {
                    ProgressView("Checking subscription…")
                        .controlSize(.small)
                        .font(.headline)
                        .accessibilityLabel("Checking Claude subscription")
                } else {
                    Label(statusTitle, systemImage: statusSymbol)
                        .font(.headline)
                }
                Text(statusExplanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Connection type", value: connectionTypeLabel)
                setupActions
                    .disabled(model.isShuttingDown)
                DisclosureGroup("Setup Details") {
                    Text(setupDetails)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(textRepliesEnabled
                     ? "New text messages can request a Claude reply after fresh connection checks. Every request is a fresh turn; tools, connectors, attachments and earlier saved history are not sent."
                     : "Live replies and tools remain unavailable in this build, even after subscription verification.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can create and select teammates, read saved conversations, and save messages with attachments locally. Saved messages are not queued for automatic sending later.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let findings = model.localFindings {
                Section("Last Local Check") {
                    LabeledContent("Claude installation", value: installationLabel(findings.installation))
                    LabeledContent("Preview profile", value: profileLabel(findings.profile))
                    Text("These local findings do not establish subscription access.")
                        .foregroundStyle(.secondary)
                    if !findings.details.isEmpty {
                        DisclosureGroup("Technical Details") {
                            ForEach(findings.details) { detail in
                                LabeledContent(detail.label) {
                                    StableSelectableText(detail.value, style: .caption)
                                }
                            }
                        }
                    }
                }
            }
            if case .verified(let evidence) = model.state {
                Section("Subscription Check") {
                    LabeledContent("Plan", value: evidence.tier.rawValue.capitalized)
                    LabeledContent("Checked") {
                        Text(evidence.checkedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    Text("Verified from an official first-party claude.ai status result. This does not enable an executor or grant tool access.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("On This Mac") {
                LabeledContent("Conversations and drafts", value: "Saved locally")
                LabeledContent("Files", value: "Protected copies of attachments")
                LabeledContent("Memory", value: "Existing local Markdown is preserved")
                Text("Existing records are preserved. Older sample messages and saved demo outcomes keep their original labels.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "OpenBots Next Preview")
                Text(textRepliesEnabled
                     ? "A development build with bounded text replies. Broader agent work and computer control remain unavailable."
                     : "A development build of the current local features. Live agent work is still unavailable.")
                    .foregroundStyle(.secondary)
                if usesReviewFixtures {
                    Label("Development review mode", systemImage: "hammer")
                    Text("Replies, cards, handoffs, run controls and access reviews in this mode are simulations. They do not run Claude or grant real access.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, idealWidth: 520, minHeight: 500)
        .alert(
            subscriptionFeedbackTitle,
            isPresented: Binding(
                get: { model.subscriptionFeedback != nil },
                set: { if !$0 { model.dismissSubscriptionFeedback() } }
            ),
            presenting: model.subscriptionFeedback
        ) { _ in
            Button("OK", action: model.dismissSubscriptionFeedback)
                .keyboardShortcut(.defaultAction)
        } message: { feedback in
            Text(subscriptionFeedbackMessage(feedback))
        }
        .onDisappear {
            model.cancelCurrentAction()
            model.dismissSubscriptionFeedback()
        }
    }

    private var connectionTypeLabel: String {
        if case .verified = model.state {
            "Claude.ai subscription (Pro/Max)"
        } else {
            "Could not be determined"
        }
    }

    private var subscriptionFeedbackTitle: String {
        switch model.subscriptionFeedback {
        case .verified: "Subscription Verified"
        case .needsSignIn: "Sign-In Needed"
        case .problem: "Subscription Not Verified"
        case .actionRequired: "Subscription Check Needs Attention"
        case nil: "Subscription Check"
        }
    }

    private func subscriptionFeedbackMessage(_ feedback: ClaudeSubscriptionFeedback) -> String {
        switch feedback {
        case .verified:
            textRepliesEnabled
                ? "Verified connection type: Claude.ai subscription (Pro/Max). You can send a new text-only message to a bot. Tools and connectors remain disabled."
                : "Verified connection type: Claude.ai subscription (Pro/Max). Live replies and tools remain unavailable in this build."
        case .needsSignIn:
            "Connection type could not be determined. The official CLI reports that sign-in is needed. Choose Connect Claude to sign in through Terminal, then check again."
        case .problem(let problem):
            "Connection type could not be determined. \(problemExplanation(problem))"
        case .actionRequired(.correctedStatusCheckApproval):
            "Connection type could not be determined. This status check needs approval before it can run. No sign-in was started."
        case .actionRequired(.tracedOfficialSignIn):
            "Connection type could not be determined. Official sign-in needs its separate safety check. No sign-in was started."
        }
    }

    @ViewBuilder
    private var setupActions: some View {
        if model.isBusy {
            Button("Stop Waiting", action: model.cancelCurrentAction)
                .help("Stop waiting for setup. This does not close Terminal, stop its sign-in flow or sign you out.")
        } else {
            switch model.state {
            case .notChecked, .cancelled:
                Button("Check Installation", action: model.connectClaude)
                    .buttonStyle(.borderedProminent)
                    .help("Check the installed CLI and Preview profile metadata. Does not sign in or run Claude.")
            case .readyToConnect, .problem, .needsSignIn, .signedInNeedsVerification, .handedOffNeedsVerification, .verified, .actionRequired:
                Button("Recheck Installation", action: model.connectClaude)
                    .help("Check installation and profile metadata only. Does not sign in or check your account.")
            case .checking, .signingIn, .checkingSubscription:
                EmptyView()
            }
            if model.hasVerifiedLocalSetup {
                Text("Connect Claude opens the installed official Claude CLI’s sign-in flow in Terminal for your own Claude Pro or Max account. Follow the CLI’s browser instructions; OpenBots does not collect passwords or copy credentials.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The CLI may retain its session on this Mac in the shared Preview profile, used by all teammates. Declining sign-in leaves your local work available. Closing this pane does not sign you out.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Claude", action: model.beginOfficialSignIn)
                    .buttonStyle(.borderedProminent)
                    .help("Open the official CLI sign-in flow in Terminal. Return here and choose Check Subscription when finished.")
                Button("Check Subscription", action: model.checkSubscription)
                    .help("Request one separate status check through the official CLI. Sign-in will not start automatically.")
            }
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .notChecked: "Subscription access not verified"
        case .checking: "Checking this Mac…"
        case .readyToConnect: "Ready to connect Claude"
        case .needsSignIn: "Official sign-in is needed"
        case .signingIn: "Preparing official sign-in…"
        case .signedInNeedsVerification: "Sign-in returned; subscription not verified"
        case .handedOffNeedsVerification: "Terminal opened; subscription not verified"
        case .checkingSubscription: "Checking subscription…"
        case .verified: "Subscription verified"
        case .problem: "Claude setup needs attention"
        case .actionRequired(.correctedStatusCheckApproval):
            model.localInstallationChecked ? "Claude Code is installed" : "Sign-in status check needs approval"
        case .actionRequired(.tracedOfficialSignIn): "Official sign-in needs a safety check"
        case .cancelled: "Setup cancelled"
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .verified: "checkmark.shield"
        case .checking, .checkingSubscription, .signingIn: "magnifyingglass"
        case .problem, .actionRequired: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        default: "person.crop.circle.badge.questionmark"
        }
    }

    private var statusExplanation: String {
        switch model.state {
        case .notChecked:
            "Check Installation checks Claude Code and this app’s local setup. It does not sign you in or send saved messages."
        case .checking:
            "Checking whether Claude Code and this app’s local setup are ready. No account check or Claude request is running."
        case .readyToConnect:
            "The official CLI and this app’s local profile are ready. Choose Connect Claude to sign in through the CLI in Terminal. Subscription access is not verified yet."
        case .needsSignIn:
            "The official CLI reported that sign-in is needed. Choose Connect Claude to use its own sign-in flow in Terminal. Your saved local work remains available."
        case .signingIn:
            "Preparing a handoff to the official Claude CLI in Terminal. Subscription access is not verified yet."
        case .signedInNeedsVerification:
            "Sign-in returned, but subscription access still needs a separate status check. No follow-up check runs automatically."
        case .handedOffNeedsVerification:
            "Terminal accepted the handoff. OpenBots has not observed a completed sign-in. Follow the official CLI’s instructions, then return here and choose Check Subscription. No follow-up check runs automatically."
        case .checkingSubscription:
            "Checking subscription status through the official CLI in this Preview profile. This does not start sign-in or send any messages."
        case .verified:
            textRepliesEnabled
                ? "An official first-party claude.ai status result verified an eligible subscription. New text-only sends are checked again before launch. Earlier saved messages are never sent automatically."
                : "An official first-party claude.ai status result verified an eligible subscription. Saved messages have not been sent, and live agent work is still disabled."
        case .actionRequired(.correctedStatusCheckApproval):
            "One sign-in status check needs approval before we can continue. Your subscription approval is already recorded."
        case .actionRequired(.tracedOfficialSignIn):
            "Official sign-in cannot start until its separate safety check is ready. Your subscription approval is already recorded; no sign-in window was opened."
        case .cancelled:
            "Stopped waiting for setup. Earlier local findings remain below. This does not close Terminal, stop a sign-in already running there or sign you out."
        case .problem(let problem):
            problemExplanation(problem)
        }
    }

    private var setupDetails: String {
        switch model.state {
        case .actionRequired(.correctedStatusCheckApproval):
            "The local check verifies the official CLI signature and Preview profile metadata only. The earlier one-shot status exception is spent and inconclusive. A corrected status-only attempt needs its own approval; no retry runs automatically. If sign-in is later needed, the separate tracing-before-sign-in requirement still applies."
        case .actionRequired(.tracedOfficialSignIn):
            "Official sign-in requires its separate tracing and isolation prerequisites before the provider flow starts. Existing subscription approval does not waive those requirements. When admitted, Terminal runs only the installed official CLI’s sign-in command in the same Preview-wide profile. OpenBots never reads or copies tokens."
        case .readyToConnect, .needsSignIn, .signedInNeedsVerification, .handedOffNeedsVerification, .verified, .checkingSubscription, .signingIn:
            "Subscription proof requires a successful official status result identifying claude.ai, the first-party provider, and an eligible Pro or Max plan. Terminal opening, a browser opening, sign-in return or exit code alone is not proof. Status and sign-in use the same Preview-wide profile and are separately admitted actions; neither grants tool or executor access."
        default:
            "Check Installation verifies the installed official Claude CLI, its signature and the Preview-owned profile metadata. This local check does not read credentials, run Claude or sign in. Connect Claude and Check Subscription are separate actions that you choose explicitly."
        }
    }

    private func problemExplanation(_ problem: ClaudeSetupProblem) -> String {
        switch problem {
        case .installationMissing: "The official Claude CLI was not found. Install it through the official Claude route, then check this Mac again; OpenBots does not install it for you."
        case .installationRejected: "The local Claude installation did not pass verification. Review the installation before continuing; nothing was launched."
        case .installationUnavailable: "The Claude installation could not be checked. No connection or sign-in state was established."
        case .profileMissing: "The Preview-owned Claude profile is missing. Its setup must be completed before a status or sign-in operation can run."
        case .profileRejected: "The Preview profile did not pass its ownership and metadata checks. No credentials were read or changed."
        case .profileUnavailable: "The Preview profile metadata could not be checked. No sign-in state was inferred."
        case .connectionCheckInconclusive: "The subscription check did not establish a verified result. This does not prove that you are signed out, and no automatic retry will run."
        case .signInIncomplete: "The official sign-in handoff could not be confirmed. This does not establish your account state or prove that Terminal stopped. No automatic retry or follow-up check will run."
        }
    }

    private func installationLabel(_ finding: ClaudeInstallationFinding) -> String {
        switch finding {
        case .notChecked: "Not checked"
        case .missing: "Not found"
        case .verified: "Signature verified"
        case .rejected: "Verification failed"
        case .unavailable: "Check unavailable"
        }
    }

    private func profileLabel(_ finding: ClaudeProfileFinding) -> String {
        switch finding {
        case .notChecked: "Not checked"
        case .missing: "Not found"
        case .metadataVerified: "Ownership and metadata verified"
        case .rejected: "Verification failed"
        case .unavailable: "Check unavailable"
        }
    }
}

private struct UnconfiguredClaudeSetupInspector: ClaudeOfflineSetupInspecting {
    func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        .init(installation: .unavailable, profile: .notChecked)
    }
}
