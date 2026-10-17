import OpenBotsServices
import AppKit
import SwiftUI

/// Opening Settings is inert. Check Claude uses the existing guarded status
/// operation, including its fresh installation preflight; sign-in stays explicit.
public struct ClaudeSetupView: View {
    @ObservedObject private var model: ClaudeSetupModel
    private let usesReviewFixtures: Bool
    private let textRepliesEnabled: Bool
    private let runtimeContent: AnyView?
    /// Set when Claude Code is newer than the last version the app was tested
    /// with: read from a link, nothing is run.
    @State private var claudeCodeWarning: String?

    public init(model: ClaudeSetupModel, usesReviewFixtures: Bool = false, textRepliesEnabled: Bool = false,
                runtimeContent: AnyView? = nil) {
        self.model = model
        self.usesReviewFixtures = usesReviewFixtures
        self.textRepliesEnabled = textRepliesEnabled
        self.runtimeContent = runtimeContent
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
            if let runtimeContent {
                Section("Claude runtime") { runtimeContent }
            }
            Section("Claude") {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .accessibilityAddTraits(.updatesFrequently)
                Text(statusExplanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let claudeCodeWarning {
                    Label(claudeCodeWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.claudeCodeNewerThanTested")
                }
                if case .verified(let evidence) = model.state, model.step.isForBots {
                    LabeledContent("Plan", value: "Claude.ai \(evidence.tier.rawValue.capitalized)")
                    LabeledContent("Last checked") {
                        Text(evidence.checkedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                setupActions
                    .disabled(model.isShuttingDown)
                DisclosureGroup("Setup Details") {
                    Text(setupDetails)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Inspect Installation", action: model.connectClaude)
                        .disabled(model.isBusy || model.isShuttingDown)
                        .help(ClaudeSetupWording.inspectHelp)
                    if let findings = model.localFindings {
                        LabeledContent("Claude Code", value: ClaudeSetupWording.installationLabel(findings.installation))
                        LabeledContent("OpenBots’ account folder", value: ClaudeSetupWording.profileLabel(findings.profile))
                        Text(ClaudeSetupWording.findingsNote)
                            .foregroundStyle(.secondary)
                        ForEach(findings.details) { detail in
                            LabeledContent(detail.label) {
                                StableSelectableText(detail.value, style: .caption)
                            }
                        }
                    }
                }
                if textRepliesEnabled {
                    Text(ClaudeSetupWording.textRepliesNote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(ClaudeSetupWording.localWorkNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("On This Mac") {
                LabeledContent("Conversations and drafts", value: "Saved locally")
                LabeledContent("Files", value: "Protected copies of attachments")
                LabeledContent("Memory", value: "Existing local Markdown is preserved")
                Text("Existing records are preserved. Older sample messages and saved demo outcomes keep their original labels.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "OpenBots Next")
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
        .task {
            guard !usesReviewFixtures, runtimeContent == nil else { return }
            claudeCodeWarning = ClaudeCodeTestedVersion.warning(installed: ClaudeCodeTestedVersion.installedVersion())
        }
        // Sign-in finishes in Terminal and the browser, so coming back to the
        // app is the moment it may be done. The model checks
        // only while a sign-in waits to be checked.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !usesReviewFixtures else { return }
            model.appBecameActive()
        }
        .onDisappear {
            model.dismissSubscriptionFeedback()
        }
    }

    @ViewBuilder
    private var setupActions: some View {
        if model.isBusy {
            Button("Stop Waiting", action: model.cancelCurrentAction)
                .help("Stop waiting for setup. This does not close Terminal, stop its sign-in flow or sign you out.")
        } else {
            if offersSignIn {
                Button("Sign in with Claude", action: signInWithClaude)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("claude.setup.signIn")
                    .help(ClaudeSetupWording.signInHelp)
                Text(ClaudeSetupWording.signInNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offersInstall {
                // Not installed is not a dead end.
                Button(ClaudeSetupWording.copyInstallCommandTitle) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ClaudeSetupWording.installCommand, forType: .string)
                }
                .accessibilityIdentifier("claude.setup.copyInstall")
                .help(ClaudeSetupWording.installCommand)
                Button(ClaudeSetupWording.openInstallPageTitle) {
                    NSWorkspace.shared.open(ClaudeSetupWording.installPageURL)
                }
                .accessibilityIdentifier("claude.setup.openInstallPage")
                .help(ClaudeSetupWording.installPageURL.absoluteString)
                Text(ClaudeSetupWording.installOffer)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(checkButtonTitle, action: checkClaude)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("claude.setup.check")
                .help(ClaudeSetupWording.checkHelp)
        }
    }

    /// Only the one state where the command and the page help: Claude Code is not on this Mac.
    var offersInstall: Bool { Self.offersInstall(for: model.state) }
    static func offersInstall(for state: ClaudeSetupState) -> Bool { state == .problem(.installationMissing) }

    var checkButtonTitle: String {
        if case .verified = model.state { "Check again" } else { "Check Claude" }
    }

    var offersSignIn: Bool { model.offersSignIn }

    /// The same explicit action is used on first check and subsequent rechecks.
    func checkClaude() { model.checkSubscription() }

    /// Revalidate the offered action at the tap, before a stale rendered button
    /// could send a now-connected profile into sign-in.
    func signInWithClaude() {
        guard offersSignIn, !model.isShuttingDown else { return }
        model.beginOfficialSignIn()
    }

    private var statusTitle: String {
        ClaudeSetupWording.title(for: model.state, step: model.step,
                                 localInstallationChecked: model.localInstallationChecked)
    }

    private var statusSymbol: String {
        if case .testing(let progress) = model.step, model.state != .needsSignIn,
           ClaudeSetupWording.stepWording(for: model.state, step: model.step) != nil {
            return progress.stage == .failed ? "exclamationmark.circle" : "hourglass"
        }
        if case .verified = model.state, !model.step.isForBots {
            return model.step == .noVersionToTest ? "exclamationmark.circle" : "hourglass"
        }
        return switch model.state {
        case .verified: "checkmark.shield"
        case .checking, .checkingSubscription, .signingIn: "magnifyingglass"
        case .problem, .actionRequired: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        default: "person.crop.circle.badge.questionmark"
        }
    }

    private var statusExplanation: String {
        ClaudeSetupWording.status(for: model.state, step: model.step, previouslyVerified: model.hasBeenVerified)
    }

    private var setupDetails: String { ClaudeSetupWording.details(for: model.state) }
}

/// The shared setup state stays visible where a new user first tries to chat.
/// Rendering this view performs no check or sign-in; composition owns startup.
public struct ClaudeConnectionBanner: View {
    @ObservedObject private var model: ClaudeSetupModel
    private let openSetup: @MainActor () -> Void

    public init(model: ClaudeSetupModel, openSetup: @escaping @MainActor () -> Void) {
        self.model = model
        self.openSetup = openSetup
    }

    /// Hidden only once the bots' own sign-in is verified: a verified test
    /// sign-in while no version works yet is not a connection.
    var isVisible: Bool {
        if case .verified = model.state, model.step.isForBots { return false }
        return true
    }

    private var isTestRunning: Bool {
        if case .testing(let progress) = model.step { return progress.stage == .running }
        return false
    }

    public var body: some View {
        Group {
            if isVisible {
                HStack(alignment: .top, spacing: 12) {
                    if model.isBusy || isTestRunning {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Waiting for Claude")
                    } else {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.title3)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ClaudeSetupWording.title(for: model.state, step: model.step,
                                                    localInstallationChecked: model.localInstallationChecked))
                            .font(.headline)
                            .accessibilityIdentifier("claude.connectionBanner.status")
                        Text(ClaudeSetupWording.status(for: model.state, step: model.step,
                                                     previouslyVerified: model.hasBeenVerified))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 6) {
                        if model.isBusy {
                            Button("Stop Waiting", action: model.cancelCurrentAction)
                                .accessibilityIdentifier("claude.connectionBanner.stopWaiting")
                        } else {
                            if model.offersSignIn {
                                Button("Sign in with Claude", action: model.beginOfficialSignIn)
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("claude.connectionBanner.signIn")
                                    .help(ClaudeSetupWording.signInHelp)
                            }
                            Button("Check Claude", action: model.checkSubscription)
                                .accessibilityIdentifier("claude.connectionBanner.check")
                                .help(ClaudeSetupWording.checkHelp)
                            if !model.offersSignIn {
                                Button("Claude setup", action: openSetup)
                                    .buttonStyle(.link)
                                    .accessibilityIdentifier("claude.connectionBanner.setup")
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(model.isShuttingDown)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("claude.connectionBanner")
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appBecameActive()
        }
    }
}

private struct UnconfiguredClaudeSetupInspector: ClaudeOfflineSetupInspecting {
    func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        .init(installation: .unavailable, profile: .notChecked)
    }
}
