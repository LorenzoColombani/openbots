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

@Test("Startup checks status once without signing in, retrying, or presenting explicit-check feedback")
@MainActor
func claudeSetupStartupCheckRunsOnce() async throws {
    let outcomes: [ClaudeSetupOutcome] = [
        .needsSignIn, .verified(try setupSubscriptionEvidence()),
        .problem(.connectionCheckInconclusive), .cancelled
    ]
    for outcome in outcomes {
        let service = SetupServiceSpy(reports: [.subscription: .init(outcome: outcome)])
        let model = ClaudeSetupModel(service: service)
        #expect(await service.calls.isEmpty)
        model.checkOnStartupOnce()
        model.checkOnStartupOnce()
        await model.actionTask?.value
        model.checkOnStartupOnce()
        model.appBecameActive()
        #expect(await service.calls == [.subscription])
        #expect(model.subscriptionFeedback == nil)
        #expect(model.actionTask == nil)
    }
}

@Test("A stopped startup check cannot publish late evidence or retry automatically")
@MainActor
func claudeSetupStartupCancellationStaysStopped() async throws {
    let service = SetupServiceSpy(suspended: [.subscription])
    let model = ClaudeSetupModel(service: service)
    model.checkOnStartupOnce()
    let task = try #require(model.actionTask)
    await service.waitForCall(.subscription)
    #expect(!model.offersSignIn)
    model.beginOfficialSignIn()
    model.cancelCurrentAction()
    model.checkOnStartupOnce()
    await service.resolve(.subscription, report: .init(outcome: .verified(try setupSubscriptionEvidence())))
    await task.value
    #expect(model.state == .cancelled)
    #expect(model.subscriptionFeedback == nil)
    #expect(await service.calls == [.subscription])
}

@Test("Startup never replaces a sign-in already requested from Settings")
@MainActor
func claudeSetupStartupPreservesAnExplicitAction() async throws {
    let service = SetupServiceSpy(suspended: [.signIn])
    let model = ClaudeSetupModel(service: service)
    #expect(model.offersSignIn)
    model.beginOfficialSignIn()
    let task = try #require(model.actionTask)
    await service.waitForCall(.signIn)
    model.checkOnStartupOnce()
    #expect(model.state == .signingIn)
    await service.resolve(.signIn, report: .init(outcome: .handedOffNeedsVerification))
    await task.value
    model.checkOnStartupOnce()
    #expect(model.state == .handedOffNeedsVerification)
    #expect(await service.calls == [.signIn])
}

@Test("A stale sign-in action cannot sign in an already verified profile")
@MainActor
func claudeSetupVerifiedStateRejectsStaleSignIn() async throws {
    let evidence = try setupSubscriptionEvidence()
    let service = SetupServiceSpy(reports: [.subscription: .init(outcome: .verified(evidence))])
    let model = ClaudeSetupModel(service: service)
    #expect(model.offersSignIn)
    model.checkSubscription()
    await model.actionTask?.value
    #expect(!model.offersSignIn)
    model.beginOfficialSignIn()
    #expect(model.state == .verified(evidence))
    #expect(await service.calls == [.subscription])
}

@Test("A terminal authentication failure invalidates pending status and offers explicit sign-in")
@MainActor
func claudeSetupAuthenticationFailureInvalidatesPendingStatus() async throws {
    for operation in [SetupOperation.local, .subscription] {
        let service = SetupServiceSpy(suspended: [operation])
        let model = ClaudeSetupModel(service: service)
        if operation == .local { model.connectClaude() } else { model.checkSubscription() }
        let pending = try #require(model.actionTask)
        await service.waitForCall(operation)
        model.requireSignInAfterTurnFailure(observedEpoch: model.authenticationEpoch)
        #expect(model.state == .needsSignIn)
        #expect(model.offersSignIn)
        #expect(model.actionTask == nil)
        await service.resolve(operation, report: .init(local: checkedSetupMetadata,
            outcome: .verified(try setupSubscriptionEvidence())))
        await pending.value
        model.checkOnStartupOnce()
        model.appBecameActive()
        #expect(model.state == .needsSignIn)
        #expect(model.localFindings == nil)
        #expect(model.subscriptionFeedback == nil)
        #expect(await service.calls == [operation])
    }
}

@Test("A turn's auth failure never replaces an explicit sign-in, its handoff, or its verification")
@MainActor
func claudeSetupAuthenticationFailurePreservesSignIn() async throws {
    for outcome in [ClaudeSetupOutcome.handedOffNeedsVerification, .signedInNeedsVerification] {
        let service = SetupServiceSpy(suspended: [.signIn, .subscription])
        let model = ClaudeSetupModel(service: service)
        let oldEpoch = model.authenticationEpoch
        model.beginOfficialSignIn()
        let signIn = try #require(model.actionTask)
        await service.waitForCall(.signIn)
        model.requireSignInAfterTurnFailure(observedEpoch: oldEpoch)
        #expect(model.state == .signingIn)
        await service.resolve(.signIn, report: .init(outcome: outcome))
        await signIn.value
        let handoffState = model.state
        model.requireSignInAfterTurnFailure(observedEpoch: oldEpoch)
        #expect(model.state == handoffState)
        model.appBecameActive()
        let verification = try #require(model.actionTask)
        await service.waitForCall(.subscription)
        model.requireSignInAfterTurnFailure(observedEpoch: oldEpoch)
        #expect(model.state == .checkingSubscription)
        let evidence = try setupSubscriptionEvidence()
        await service.resolve(.subscription, report: .init(outcome: .verified(evidence)))
        await verification.value
        #expect(model.state == .verified(evidence))
        #expect(model.authenticationEpoch == oldEpoch + 1)
        // An older turn may still be saving its failure after verification.
        model.requireSignInAfterTurnFailure(observedEpoch: oldEpoch)
        #expect(model.state == .verified(evidence))
        model.requireSignInAfterTurnFailure(observedEpoch: model.authenticationEpoch)
        #expect(model.state == .needsSignIn)
        #expect(model.subscriptionFeedback == nil)
        #expect(await service.calls == [.signIn, .subscription])
    }
}

@Test("A terminal authentication failure cannot revive setup during shutdown")
@MainActor
func claudeSetupAuthenticationFailureRespectsShutdown() async {
    let service = SetupServiceSpy()
    let model = ClaudeSetupModel(service: service)
    model.beginShutdown()
    let state = model.state
    model.requireSignInAfterTurnFailure(observedEpoch: model.authenticationEpoch)
    #expect(model.state == state)
    #expect(!model.offersSignIn)
    #expect(await service.calls.isEmpty)
}

@Test("An ordinary successful status check cannot suppress a turn's authentication failure")
@MainActor
func claudeSetupAuthenticationFailureAfterOrdinaryStatusStillReports() async throws {
    let evidence = try setupSubscriptionEvidence()
    let service = SetupServiceSpy(reports: [.subscription: .init(outcome: .verified(evidence))])
    let model = ClaudeSetupModel(service: service)
    let turnEpoch = model.authenticationEpoch
    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.state == .verified(evidence))
    #expect(model.authenticationEpoch == turnEpoch)
    model.requireSignInAfterTurnFailure(observedEpoch: turnEpoch)
    #expect(model.state == .needsSignIn)
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
    #expect(model.state == .actionRequired(.correctedStatusCheckApproval), "An unavailable action stays guarded")
    #expect(model.localFindings == checkedSetupMetadata)
    let signInModel = ClaudeSetupModel(service: GuardedClaudeSetupService(inspector: inspector))
    signInModel.beginOfficialSignIn()
    await signInModel.actionTask?.value
    #expect(signInModel.state == .actionRequired(.tracedOfficialSignIn))
    #expect(await inspector.calls == 1)
}

// Setup describes problems in user-facing terms. The not-installed state
// offers the installation command and page.
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

// L6-3: sign-in finishes in Terminal and the browser, and nothing noticed it.
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

// A first install signs in twice, and the screen
// said "Connected" after the first and "may have expired" before the second.
@Test("Each setup step speaks in the app's own words and only the bots' sign-in says Connected")
@MainActor
func setupStepsSayWhatIsTrue() throws {
    let evidence = try setupSubscriptionEvidence()
    let stages: [ClaudeRuntimeTestProgress.Stage] = [.running, .waiting, .failed]
    let progress = stages.map { ClaudeRuntimeTestProgress(stage: $0, version: "2.1.300") }
        + [ClaudeRuntimeTestProgress(stage: .running, version: nil)]
    let steps: [ClaudeSetupStep] = [.bots, .signInForTesting, .noVersionToTest, .signInForBots]
        + progress.map { .testing($0) }
    let states: [ClaudeSetupState] = [.notChecked, .checking, .readyToConnect, .needsSignIn, .signingIn,
        .signedInNeedsVerification, .handedOffNeedsVerification, .checkingSubscription, .verified(evidence),
        .cancelled, .actionRequired(.correctedStatusCheckApproval), .actionRequired(.tracedOfficialSignIn)]
        + ClaudeSetupProblem.allCases.map { .problem($0) }
    for step in steps {
        for state in states {
            let title = ClaudeSetupWording.title(for: state, step: step, localInstallationChecked: true)
            for sentence in [title, ClaudeSetupWording.status(for: state, step: step),
                             ClaudeSetupWording.status(for: state, step: step, previouslyVerified: true)] {
                #expect(!sentence.isEmpty)
                for word in ClaudeSetupWording.bannedWords {
                    #expect(!sentence.localizedCaseInsensitiveContains(word), "\(word): \(sentence)")
                }
            }
            if !step.isForBots {
                #expect(title != "Connected to Claude", "\(step) \(state)")
            }
        }
    }
    #expect(ClaudeSetupWording.title(for: .verified(evidence), step: .bots, localInstallationChecked: true)
        == "Connected to Claude")
    #expect(ClaudeSetupWording.title(for: .verified(evidence), step: .signInForBots, localInstallationChecked: true)
        == "Connected to Claude")
    // Problems keep their own explanation on every step: a missing Claude Code
    // still names the install, whichever sign-in it blocked.
    for step in steps {
        #expect(ClaudeSetupWording.status(for: .problem(.installationMissing), step: step)
            == ClaudeSetupWording.explanation(.installationMissing))
    }
    #expect(!ClaudeSetupWording.status(for: .needsSignIn).contains("expired"))
    #expect(ClaudeSetupWording.status(for: .needsSignIn, previouslyVerified: true).contains("may have expired"))
    #expect(ClaudeSetupWording.title(for: .notChecked, step: .signInForTesting, localInstallationChecked: false)
        .hasPrefix("Step 1 of 2"))
    #expect(ClaudeSetupWording.title(for: .needsSignIn, step: .signInForBots, localInstallationChecked: true)
        .hasPrefix("Step 2 of 2"))
    #expect(ClaudeSetupWording.status(for: .verified(evidence), step: .testing(progress[0])).contains("Claude plan"))
}

@Test("While a version is tested the banner stays up, and sign-in is offered only for a lost test sign-in")
@MainActor
func testingStepHoldsTheBannerAndOffersOnlyALostSignIn() async throws {
    let evidence = try setupSubscriptionEvidence()
    let service = SetupServiceSpy(reports: [.subscription: .init(outcome: .verified(evidence))])
    let model = ClaudeSetupModel(service: service)
    model.step = .testing(.init(stage: .failed, version: "2.1.300"))
    #expect(!model.offersSignIn, "A failed test is retried from the runtime settings, not by signing in")
    model.checkSubscription()
    await model.actionTask?.value
    #expect(model.state == .verified(evidence))
    #expect(ClaudeConnectionBanner(model: model, openSetup: {}).isVisible)
    model.step = .signInForTesting
    #expect(ClaudeConnectionBanner(model: model, openSetup: {}).isVisible, "A test sign-in is never a connection")
    model.step = .bots
    #expect(!ClaudeConnectionBanner(model: model, openSetup: {}).isVisible)
    model.requireSignInAfterTurnFailure(observedEpoch: model.authenticationEpoch)
    model.step = .testing(.init(stage: .waiting, version: nil))
    #expect(model.offersSignIn)
    #expect(model.hasBeenVerified)
}

@Test("A new working version checks the bots' sign-in without replacing one under way")
@MainActor
func newRuntimeCheckLeavesASignInAlone() async throws {
    let service = SetupServiceSpy(reports: [.signIn: .init(outcome: .handedOffNeedsVerification),
                                            .subscription: .init(outcome: .needsSignIn)])
    let model = ClaudeSetupModel(service: service)
    #expect(model.checkForNewRuntime())
    await model.actionTask?.value
    #expect(await service.calls == [.subscription])
    #expect(model.subscriptionFeedback == nil, "Not a check the user asked for")
    model.beginOfficialSignIn()
    await model.actionTask?.value
    #expect(model.state == .handedOffNeedsVerification)
    #expect(model.checkForNewRuntime(), "Its own check follows the sign-in")
    #expect(await service.calls == [.subscription, .signIn])
    model.beginShutdown()
    #expect(!model.checkForNewRuntime())
}

// A new working version replaced a running Inspect Installation.
@Test("A new working version's check waits for a running Inspect Installation and then runs")
@MainActor
func newRuntimeCheckFollowsARunningLocalCheck() async throws {
    let service = SetupServiceSpy(reports: [.subscription: .init(outcome: .needsSignIn)], suspended: [.local])
    let model = ClaudeSetupModel(service: service)
    model.connectClaude()
    let local = try #require(model.actionTask)
    await service.waitForCall(.local)
    #expect(model.checkForNewRuntime())
    #expect(model.state == .checking, "The running check is not replaced")
    #expect(await service.calls == [.local])
    await service.resolve(.local, report: .init(local: checkedSetupMetadata, outcome: .readyToConnect))
    await local.value
    await model.actionTask?.value
    #expect(await service.calls == [.local, .subscription])
    #expect(model.localFindings == checkedSetupMetadata)
    #expect(model.state == .needsSignIn)
    #expect(model.subscriptionFeedback == nil)

    let stoppedService = SetupServiceSpy(suspended: [.local])
    let stopped = ClaudeSetupModel(service: stoppedService)
    stopped.connectClaude()
    let stoppedLocal = try #require(stopped.actionTask)
    await stoppedService.waitForCall(.local)
    #expect(stopped.checkForNewRuntime())
    stopped.cancelCurrentAction()
    await stoppedService.resolve(.local, report: .init(local: checkedSetupMetadata, outcome: .readyToConnect))
    await stoppedLocal.value
    #expect(stopped.state == .cancelled)
    #expect(stopped.actionTask == nil, "Stopping the wait drops the queued check too")
    #expect(await stoppedService.calls == [.local])
}
