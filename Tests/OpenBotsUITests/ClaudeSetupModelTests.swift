import AppKit
import Foundation
import OpenBotsServices
import SwiftUI
import Testing
@testable import OpenBotsUI

private enum SetupOperation: Hashable, Sendable { case local, subscription, signIn }

private actor SetupServiceSpy: ClaudeSetupServicing {
    private let reports: [SetupOperation: ClaudeSetupReport]
    private let suspended: Set<SetupOperation>
    private(set) var calls: [SetupOperation] = []
    private var pending: [SetupOperation: CheckedContinuation<ClaudeSetupReport, Never>] = [:]
    private var callWaiters: [SetupOperation: [CheckedContinuation<Void, Never>]] = [:]

    init(reports: [SetupOperation: ClaudeSetupReport] = [:], suspended: Set<SetupOperation> = []) {
        self.reports = reports
        self.suspended = suspended
    }

    func checkThisMac() async -> ClaudeSetupReport { await perform(.local) }
    func checkSubscription() async -> ClaudeSetupReport { await perform(.subscription) }
    func beginOfficialSignIn() async -> ClaudeSetupReport { await perform(.signIn) }

    func waitForCall(_ operation: SetupOperation) async {
        guard !calls.contains(operation) else { return }
        await withCheckedContinuation { callWaiters[operation, default: []].append($0) }
    }

    /// Ignores cancellation deliberately so a late service response exercises
    /// the model fence rather than depending on a cooperative adapter.
    func resolve(_ operation: SetupOperation, report: ClaudeSetupReport) {
        pending.removeValue(forKey: operation)?.resume(returning: report)
    }

    private func perform(_ operation: SetupOperation) async -> ClaudeSetupReport {
        calls.append(operation)
        if suspended.contains(operation) {
            return await withCheckedContinuation { continuation in
                pending[operation] = continuation
                for waiter in callWaiters.removeValue(forKey: operation) ?? [] { waiter.resume() }
            }
        }
        for waiter in callWaiters.removeValue(forKey: operation) ?? [] { waiter.resume() }
        return reports[operation] ?? .init(outcome: .problem(.connectionCheckInconclusive))
    }
}

private actor SetupOfflineInspectorSpy: ClaudeOfflineSetupInspecting {
    private(set) var calls = 0
    let snapshot: ClaudeOfflineSetupSnapshot
    init(snapshot: ClaudeOfflineSetupSnapshot) { self.snapshot = snapshot }
    func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        calls += 1
        return snapshot
    }
}

private let checkedSetupMetadata = ClaudeOfflineSetupSnapshot(
    installation: .verified, profile: .metadataVerified,
    details: [.init(label: "CLI version", value: "test-metadata-only")]
)

private func setupSubscriptionEvidence() throws -> ClaudeVerifiedSubscription {
    try #require(ClaudeVerifiedSubscription(
        exitCode: 0, loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty",
        subscriptionType: "max", checkedAt: Date(timeIntervalSince1970: 1_788_000_000)
    ))
}

@Test("Claude setup construction and a rendered Settings pane perform no service operation")
@MainActor
func claudeSetupPaneIsInert() async throws {
    let service = SetupServiceSpy()
    let model = ClaudeSetupModel(service: service)
    #expect(model.state == .notChecked)
    #expect(model.localFindings == nil)
    #expect(model.actionTask == nil)
    #expect(await service.calls.isEmpty)

    let controller = NSHostingController(rootView: ClaudeSetupView(model: model))
    controller.view.frame = CGRect(x: 0, y: 0, width: 520, height: 720)
    controller.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(10))
    #expect(controller.view.window == nil)
    #expect(model.state == .notChecked)
    #expect(await service.calls.isEmpty)
}

@Test("Check Installation publishes local readiness without inferring authentication or starting sign-in")
@MainActor
func claudeSetupConnectChecksOnlyThisMac() async throws {
    let service = SetupServiceSpy(suspended: [.local])
    let model = ClaudeSetupModel(service: service)
    model.connectClaude()
    #expect(model.state == .checking)
    #expect(model.isBusy)
    let task = try #require(model.actionTask)
    await service.waitForCall(.local)
    await service.resolve(.local, report: .init(
        local: checkedSetupMetadata, outcome: .readyToConnect
    ))
    await task.value
    #expect(model.state == .readyToConnect)
    #expect(model.localFindings == checkedSetupMetadata)
    #expect(model.localInstallationChecked)
    #expect(model.hasVerifiedLocalSetup)
    #expect(!model.isBusy)
    #expect(await service.calls == [.local])
}

@Test("Status and official sign-in remain distinct explicit operations")
@MainActor
func claudeSetupProviderActionsStaySeparate() async throws {
    let service = SetupServiceSpy(suspended: [.subscription, .signIn])
    let model = ClaudeSetupModel(service: service)
    model.checkSubscription()
    #expect(model.state == .checkingSubscription)
    let statusTask = try #require(model.actionTask)
    await service.waitForCall(.subscription)
    await service.resolve(.subscription, report: .init(outcome: .needsSignIn))
    await statusTask.value
    #expect(model.state == .needsSignIn)
    #expect(await service.calls == [.subscription])

    model.beginOfficialSignIn()
    #expect(model.state == .signingIn)
    let signInTask = try #require(model.actionTask)
    await service.waitForCall(.signIn)
    await service.resolve(.signIn, report: .init(outcome: .signedInNeedsVerification))
    await signInTask.value
    #expect(model.state == .signedInNeedsVerification)
    #expect(!model.isBusy)
    #expect(await service.calls == [.subscription, .signIn])
    #expect(model.localFindings == nil)
}

@Test("Provider controls require both local checks but metadata does not imply subscription access")
@MainActor
func claudeSetupProviderControlsRequireInstallationAndProfile() async {
    let cases: [(ClaudeInstallationFinding, ClaudeProfileFinding, Bool)] = [
        (.notChecked, .notChecked, false),
        (.verified, .missing, false),
        (.verified, .rejected, false),
        (.verified, .unavailable, false),
        (.missing, .metadataVerified, false),
        (.rejected, .metadataVerified, false),
        (.verified, .metadataVerified, true)
    ]
    for (installation, profile, expected) in cases {
        let service = SetupServiceSpy(reports: [
            .local: .init(
                local: .init(installation: installation, profile: profile),
                outcome: .actionRequired(.correctedStatusCheckApproval)
            )
        ])
        let model = ClaudeSetupModel(service: service)
        #expect(!model.hasVerifiedLocalSetup)
        model.connectClaude()
        await model.actionTask?.value
        #expect(model.hasVerifiedLocalSetup == expected)
        #expect(model.state == .actionRequired(.correctedStatusCheckApproval))
        #expect(await service.calls == [.local])
    }
}

@Test("Terminal handoff is not completed sign-in and waits for a separate subscription action")
@MainActor
func claudeSetupTerminalHandoffRequiresExplicitVerification() async throws {
    let evidence = try setupSubscriptionEvidence()
    let service = SetupServiceSpy(reports: [
        .local: .init(local: checkedSetupMetadata, outcome: .readyToConnect),
        .signIn: .init(outcome: .handedOffNeedsVerification),
        .subscription: .init(outcome: .verified(evidence))
    ])
    let model = ClaudeSetupModel(service: service)
    model.connectClaude()
    await model.actionTask?.value
    #expect(model.state == .readyToConnect)
    #expect(await service.calls == [.local])
    model.beginOfficialSignIn()
    await model.actionTask?.value
    #expect(model.state == .handedOffNeedsVerification)
    #expect(model.state != .signedInNeedsVerification)
    #expect(model.localFindings == checkedSetupMetadata)
    #expect(!model.isBusy)
    #expect(await service.calls == [.local, .signIn])

    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.state == .verified(evidence))
    #expect(await service.calls == [.local, .signIn, .subscription])
}

@Test("Stopping a pending handoff rejects its late acceptance without checking the account")
@MainActor
func claudeSetupCancelledHandoffCannotPublishLateAcceptance() async throws {
    let service = SetupServiceSpy(suspended: [.signIn])
    let model = ClaudeSetupModel(service: service)
    model.beginOfficialSignIn()
    let task = try #require(model.actionTask)
    await service.waitForCall(.signIn)
    model.cancelCurrentAction()
    await service.resolve(.signIn, report: .init(outcome: .handedOffNeedsVerification))
    await task.value
    #expect(model.state == .cancelled)
    #expect(model.actionTask == nil)
    #expect(await service.calls == [.signIn])
}

@Test("Unknown status, explicit sign-in need and verified evidence stay distinct")
@MainActor
func claudeSetupDoesNotTreatUnknownStatusAsLoggedOutOrConnected() async throws {
    let evidence = try setupSubscriptionEvidence()
    let cases: [(ClaudeSetupOutcome, ClaudeSetupState)] = [
        (.problem(.connectionCheckInconclusive), .problem(.connectionCheckInconclusive)),
        (.needsSignIn, .needsSignIn),
        (.verified(evidence), .verified(evidence)),
        (.cancelled, .cancelled)
    ]
    for (outcome, state) in cases {
        let service = SetupServiceSpy(reports: [.subscription: .init(outcome: outcome)])
        let model = ClaudeSetupModel(service: service)
        model.checkSubscription()
        await model.actionTask?.value
        #expect(model.state == state)
        #expect(await service.calls == [.subscription])
        #expect(model.localFindings == nil)
    }
    #expect(ClaudeVerifiedSubscription(
        exitCode: 1, loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty",
        subscriptionType: "max", checkedAt: evidence.checkedAt
    ) == nil)
}

@Test("A provider report without local metadata retains the previous local findings")
@MainActor
func claudeSetupRetainsMetadataAcrossSeparateSteps() async {
    let service = SetupServiceSpy(reports: [
        .local: .init(local: checkedSetupMetadata, outcome: .actionRequired(.correctedStatusCheckApproval)),
        .subscription: .init(outcome: .problem(.connectionCheckInconclusive))
    ])
    let model = ClaudeSetupModel(service: service)
    model.connectClaude()
    await model.actionTask?.value
    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.state == .problem(.connectionCheckInconclusive))
    #expect(model.localFindings == checkedSetupMetadata)
    #expect(await service.calls == [.local, .subscription])
}

@Test("Cancel rejects an uncooperative late verified result without claiming a connection")
@MainActor
func claudeSetupCancelFencesLateResult() async throws {
    let service = SetupServiceSpy(suspended: [.subscription])
    let model = ClaudeSetupModel(service: service)
    model.checkSubscription()
    let task = try #require(model.actionTask)
    await service.waitForCall(.subscription)
    model.cancelCurrentAction()
    #expect(model.state == .cancelled)
    #expect(!model.isBusy)
    await service.resolve(.subscription, report: .init(
        local: checkedSetupMetadata, outcome: .verified(try setupSubscriptionEvidence())
    ))
    await task.value
    #expect(model.state == .cancelled)
    #expect(model.localFindings == nil)
    #expect(model.actionTask == nil)
    #expect(model.subscriptionFeedback == nil)
}

@Test("A newer setup action supersedes an older delayed result")
@MainActor
func claudeSetupNewActionRejectsOldCompletion() async throws {
    let evidence = try setupSubscriptionEvidence()
    let service = SetupServiceSpy(
        reports: [.subscription: .init(outcome: .verified(evidence))], suspended: [.local]
    )
    let model = ClaudeSetupModel(service: service)
    model.connectClaude()
    let oldTask = try #require(model.actionTask)
    await service.waitForCall(.local)
    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.state == .verified(evidence))
    await service.resolve(.local, report: .init(
        local: checkedSetupMetadata, outcome: .problem(.installationRejected)
    ))
    await oldTask.value
    #expect(model.state == .verified(evidence))
    #expect(model.subscriptionFeedback == .verified)
    #expect(model.localFindings == nil)
    #expect(await service.calls == [.local, .subscription])
}

@Test("Shutdown rejects late findings and prevents every subsequent setup operation")
@MainActor
func claudeSetupShutdownClosesAdmission() async throws {
    let service = SetupServiceSpy(suspended: [.local])
    let model = ClaudeSetupModel(service: service)
    model.connectClaude()
    let task = try #require(model.actionTask)
    await service.waitForCall(.local)
    model.beginShutdown()
    model.connectClaude()
    model.checkSubscription()
    model.beginOfficialSignIn()
    await service.resolve(.local, report: .init(
        local: checkedSetupMetadata, outcome: .actionRequired(.correctedStatusCheckApproval)
    ))
    await task.value
    #expect(model.isShuttingDown)
    #expect(model.state == .cancelled)
    #expect(model.localFindings == nil)
    #expect(model.subscriptionFeedback == nil)
    #expect(await service.calls == [.local])
}

@Test("Only an explicit subscription check acknowledges completion; dismissal preserves its result")
@MainActor
func claudeSubscriptionFeedbackFollowsExplicitAction() async throws {
    let proof = try setupSubscriptionEvidence()
    let service = SetupServiceSpy(reports: [
        .local: .init(local: checkedSetupMetadata, outcome: .readyToConnect),
        .signIn: .init(outcome: .handedOffNeedsVerification),
        .subscription: .init(outcome: .verified(proof))
    ])
    let model = ClaudeSetupModel(service: service)
    #expect(model.subscriptionFeedback == nil)
    model.connectClaude()
    await model.actionTask?.value
    #expect(model.subscriptionFeedback == nil)
    model.beginOfficialSignIn()
    await model.actionTask?.value
    #expect(model.subscriptionFeedback == nil)

    model.checkSubscription()
    #expect(model.state == .checkingSubscription)
    #expect(model.isBusy)
    #expect(model.subscriptionFeedback == nil)
    await model.actionTask?.value
    #expect(model.subscriptionFeedback == .verified)
    model.dismissSubscriptionFeedback()
    #expect(model.subscriptionFeedback == nil)
    #expect(model.state == .verified(proof))
    #expect(model.localFindings == checkedSetupMetadata)

    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.subscriptionFeedback == .verified)
    #expect(await service.calls == [.local, .signIn, .subscription, .subscription])
    model.beginShutdown()
    #expect(model.subscriptionFeedback == nil)
    #expect(model.state == .verified(proof))
}

@Test("Subscription feedback distinguishes sign-in need and failure without inferring authentication")
@MainActor
func claudeSubscriptionFeedbackPreservesFailureMeaning() async {
    let cases: [(ClaudeSetupOutcome, ClaudeSubscriptionFeedback?)] = [
        (.needsSignIn, .needsSignIn),
        (.problem(.connectionCheckInconclusive), .problem(.connectionCheckInconclusive)),
        (.problem(.installationRejected), .problem(.installationRejected)),
        (.actionRequired(.correctedStatusCheckApproval), .actionRequired(.correctedStatusCheckApproval)),
        (.cancelled, nil)
    ]
    for (outcome, feedback) in cases {
        let service = SetupServiceSpy(reports: [.subscription: .init(outcome: outcome)])
        let model = ClaudeSetupModel(service: service)
        model.checkSubscription()
        await model.actionTask?.value
        #expect(model.subscriptionFeedback == feedback)
        #expect(await service.calls == [.subscription])
        #expect(model.localFindings == nil)
    }
}

@Test("The production guarded service reports prerequisites and never verifies a connection")
@MainActor
func claudeSetupProductionGuardDoesNotLaunchOrInferAuthentication() async {
    let inspector = SetupOfflineInspectorSpy(snapshot: checkedSetupMetadata)
    let model = ClaudeSetupModel(service: GuardedClaudeSetupService(inspector: inspector))
    model.connectClaude()
    await model.actionTask?.value
    #expect(model.state == .actionRequired(.correctedStatusCheckApproval))
    #expect(model.localFindings == checkedSetupMetadata)
    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.state == .actionRequired(.correctedStatusCheckApproval))
    model.beginOfficialSignIn()
    await model.actionTask?.value
    #expect(model.state == .actionRequired(.tracedOfficialSignIn))
    #expect(model.localFindings == checkedSetupMetadata)
    #expect(await inspector.calls == 1)
}

// The setup screen once spoke build vocabulary
// ("the Preview-owned Claude profile is missing", "the earlier one-shot status
// exception is spent and inconclusive") and a "not installed" state that named
// no route. The words are the app's own now, and the not-installed state offers
// the command and the page.
@Test("Setup wording carries no build vocabulary and each problem names what did not happen")
func setupWordingCarriesNoBuildVocabulary() {
    for problem in ClaudeSetupProblem.allCases {
        let sentence = ClaudeSetupWording.explanation(problem)
        for word in ClaudeSetupWording.bannedWords {
            #expect(!sentence.localizedCaseInsensitiveContains(word), "\(problem): \(word)")
        }
        #expect(sentence.contains("not") || sentence.contains("Nothing"), "\(problem) must say what did not happen: \(sentence)")
    }
    let states: [ClaudeSetupState] = [.notChecked, .readyToConnect, .needsSignIn, .checking,
        .actionRequired(.correctedStatusCheckApproval), .actionRequired(.tracedOfficialSignIn)]
    for state in states {
        let details = ClaudeSetupWording.details(for: state)
        for word in ClaudeSetupWording.bannedWords {
            #expect(!details.localizedCaseInsensitiveContains(word), "\(state): \(word)")
        }
    }
    #expect(ClaudeSetupWording.explanation(.installationMissing).hasPrefix("Claude Code is not on this Mac."))
}

// The rest of the setup screen once still said "Preview", "official CLI",
// "metadata" and "teammates": those sentences sat in the view, where the sweep above could not reach them.
@Test("Every sentence on the setup screen is in the wording and carries no build vocabulary")
@MainActor
func everySetupScreenSentenceCarriesNoBuildVocabulary() throws {
    for word in ["official CLI", "Claude CLI", "teammate"] {
        #expect(ClaudeSetupWording.bannedWords.contains(word), "\(word) is not swept")
    }
    let states: [ClaudeSetupState] = [.notChecked, .checking, .readyToConnect, .needsSignIn, .signingIn,
        .signedInNeedsVerification, .handedOffNeedsVerification, .checkingSubscription,
        .verified(try setupSubscriptionEvidence()), .cancelled,
        .actionRequired(.correctedStatusCheckApproval), .actionRequired(.tracedOfficialSignIn)]
        + ClaudeSetupProblem.allCases.map { .problem($0) }
    var sentences: [String] = []
    for state in states {
        sentences.append(ClaudeSetupWording.title(for: state, localInstallationChecked: true))
        sentences.append(ClaudeSetupWording.title(for: state, localInstallationChecked: false))
        sentences.append(ClaudeSetupWording.status(for: state))
        sentences.append(ClaudeSetupWording.details(for: state))
    }
    for finding in [ClaudeInstallationFinding.notChecked, .missing, .verified, .rejected, .unavailable] {
        sentences.append(ClaudeSetupWording.installationLabel(finding))
    }
    for finding in [ClaudeProfileFinding.notChecked, .missing, .metadataVerified, .rejected, .unavailable] {
        sentences.append(ClaudeSetupWording.profileLabel(finding))
    }
    sentences += [ClaudeSetupWording.signInHelp, ClaudeSetupWording.signInNote, ClaudeSetupWording.checkHelp,
                  ClaudeSetupWording.inspectHelp, ClaudeSetupWording.findingsNote,
                  ClaudeSetupWording.textRepliesNote, ClaudeSetupWording.localWorkNote]
    for sentence in sentences {
        #expect(!sentence.isEmpty)
        for word in ClaudeSetupWording.bannedWords {
            #expect(!sentence.localizedCaseInsensitiveContains(word), "\(word): \(sentence)")
        }
    }
    #expect(ClaudeSetupWording.explanation(.installationMissing).contains("Bots are Claude Code sessions"))
    #expect(ClaudeSetupWording.localWorkNote.contains("choose bots"))
}

// Sign-in finishes in Terminal and the browser, and nothing noticed it.
// Coming back to the app now runs the same check Check Claude runs, and only
// while the screen is waiting on a sign-in.
@Test("Coming back to the app checks Claude only while a sign-in waits to be checked")
@MainActor
func comingBackToTheAppChecksAWaitingSignIn() async throws {
    for waiting in [ClaudeSetupOutcome.handedOffNeedsVerification, .signedInNeedsVerification] {
        let service = SetupServiceSpy(reports: [
            .signIn: .init(outcome: waiting),
            .subscription: .init(outcome: .verified(try setupSubscriptionEvidence()))
        ])
        let model = ClaudeSetupModel(service: service)
        model.beginOfficialSignIn()
        await model.actionTask?.value
        #expect(await service.calls == [.signIn])
        model.appBecameActive()
        await model.actionTask?.value
        #expect(await service.calls == [.signIn, .subscription], "\(waiting)")
        #expect(model.state == .verified(try setupSubscriptionEvidence()))
        model.appBecameActive()
        await model.actionTask?.value
        #expect(await service.calls == [.signIn, .subscription], "a checked result is not checked again")
    }
    for other in [ClaudeSetupOutcome.needsSignIn, .readyToConnect, .problem(.connectionCheckInconclusive),
                  .verified(try setupSubscriptionEvidence())] {
        let service = SetupServiceSpy(reports: [.subscription: .init(outcome: other)])
        let model = ClaudeSetupModel(service: service)
        model.appBecameActive()
        #expect(model.actionTask == nil, "not checked yet stays unchecked")
        model.checkSubscription()
        await model.actionTask?.value
        model.appBecameActive()
        await model.actionTask?.value
        #expect(await service.calls == [.subscription], "\(other)")
    }
}

@Test("The not-installed state offers the exact install command and the official page, and no other state does")
@MainActor func theNotInstalledStateOffersTheCommandAndThePage() {
    #expect(ClaudeSetupWording.installCommand == "curl -fsSL https://claude.ai/install.sh | bash")
    #expect(ClaudeSetupWording.installPageURL.scheme == "https")
    #expect(ClaudeSetupWording.installPageURL.host?.hasSuffix("anthropic.com") == true)
    #expect(ClaudeSetupWording.installOffer == "Paste it in Terminal, then press Check Claude.")
    #expect(ClaudeSetupView.offersInstall(for: .problem(.installationMissing)))
    for state in [ClaudeSetupState.problem(.profileMissing), .problem(.installationRejected), .needsSignIn, .notChecked, .checking] {
        #expect(!ClaudeSetupView.offersInstall(for: state), "\(state)")
    }
}
