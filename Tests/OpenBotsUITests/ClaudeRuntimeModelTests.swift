import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import Testing
@testable import OpenBotsUI

private actor RuntimePresentationService: ManagedClaudeRuntimeServing {
    private var current: ManagedClaudeRuntimeSnapshot
    private var stream: AsyncStream<ManagedClaudeRuntimeSnapshot>.Continuation?
    private var cancellation: CheckedContinuation<Void, Never>?
    private(set) var cancelEntered = false
    private(set) var checks = 0
    init(phase: ManagedClaudeRuntimeSnapshot.Phase = .ready) {
        let artifact = ClaudeRuntimeArtifact(version: "2.1.300", sha256: String(repeating: "a", count: 64),
            signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW",
            codeDirectoryHash: String(repeating: "b", count: 40))
        current = .init(selection: .init(active: artifact), phase: phase)
    }
    func snapshot() -> ManagedClaudeRuntimeSnapshot { current }
    func updates() -> AsyncStream<ManagedClaudeRuntimeSnapshot> {
        AsyncStream { continuation in stream = continuation; continuation.yield(current) }
    }
    func prepare() -> ManagedClaudeRuntimeSnapshot { current }
    func checkForUpdates() -> ManagedClaudeRuntimeSnapshot { checks += 1; return current }
    func retry() -> ManagedClaudeRuntimeSnapshot { current }
    func cancel() async {
        cancelEntered = true
        await withCheckedContinuation { cancellation = $0 }
        emit(.cancelled)
    }
    func releaseCancellation() { cancellation?.resume(); cancellation = nil }
    func shutdown() { stream?.finish(); stream = nil }
    func emit(_ phase: ManagedClaudeRuntimeSnapshot.Phase) {
        current = .init(selection: current.selection, phase: phase)
        stream?.yield(current)
    }
}

private func flowArtifact(_ version: String, _ fill: Character) -> ClaudeRuntimeArtifact {
    ClaudeRuntimeArtifact(version: version, sha256: String(repeating: fill, count: 64),
        signatureIdentifier: "com.anthropic.claude-code", teamIdentifier: "Q6L2SF6YDW",
        codeDirectoryHash: String(repeating: "b", count: 40))
}

/// Counts the two runtime requests that matter here: the ordinary check, which
/// never reruns a stored result, and the explicit retry, which runs the suite.
private actor FlowRuntimeService: ManagedClaudeRuntimeServing {
    private var current: ManagedClaudeRuntimeSnapshot
    private var stream: AsyncStream<ManagedClaudeRuntimeSnapshot>.Continuation?
    private(set) var checks = 0
    private(set) var retries = 0
    init(_ snapshot: ManagedClaudeRuntimeSnapshot) { current = snapshot }
    func snapshot() -> ManagedClaudeRuntimeSnapshot { current }
    func updates() -> AsyncStream<ManagedClaudeRuntimeSnapshot> {
        AsyncStream { continuation in stream = continuation; continuation.yield(current) }
    }
    func prepare() -> ManagedClaudeRuntimeSnapshot { current }
    func checkForUpdates() -> ManagedClaudeRuntimeSnapshot { checks += 1; return current }
    func retry() -> ManagedClaudeRuntimeSnapshot { retries += 1; return current }
    func cancel() async {}
    func shutdown() { stream?.finish(); stream = nil }
    func emit(_ snapshot: ManagedClaudeRuntimeSnapshot) {
        current = snapshot
        stream?.yield(snapshot)
    }
}

private actor FlowSetupService: ClaudeSetupServicing {
    private(set) var subscriptionCalls = 0
    private(set) var signInCalls = 0
    private var subscriptionOutcome: ClaudeSetupOutcome
    init(subscription: ClaudeSetupOutcome) { subscriptionOutcome = subscription }
    func answer(_ outcome: ClaudeSetupOutcome) { subscriptionOutcome = outcome }
    func checkThisMac() async -> ClaudeSetupReport { .init(outcome: .readyToConnect) }
    func checkSubscription() async -> ClaudeSetupReport {
        subscriptionCalls += 1
        return .init(outcome: subscriptionOutcome)
    }
    func beginOfficialSignIn() async -> ClaudeSetupReport {
        signInCalls += 1
        return .init(outcome: .handedOffNeedsVerification)
    }
}

private func flowEvidence() throws -> ClaudeVerifiedSubscription {
    try #require(ClaudeVerifiedSubscription(exitCode: 0, loggedIn: true, authMethod: "claude.ai",
        apiProvider: "firstParty", subscriptionType: "max", checkedAt: Date(timeIntervalSince1970: 1_788_000_000)))
}

@Suite("Managed Claude runtime presentation")
@MainActor
struct ClaudeRuntimeModelTests {
    @Test func foregroundCheckCannotStartDuringAppUpdateAdmission() async throws {
        let service = RuntimePresentationService()
        let admission = AppUpdateAdmission()
        let token = UUID()
        #expect(admission.acquire(token, blocker: { nil }))
        let model = ClaudeRuntimeModel(service: service, admission: admission)
        model.start()
        try await settle { model.hasActiveRuntime }
        model.check()
        await Task.yield()
        #expect(await service.checks == 0)
        admission.release(token)
        model.check()
        try await settle { await service.checks == 1 && !model.isRequesting }
        model.beginShutdown(); await model.finishShutdown()
    }

    @Test func ordinaryIdleQuitDoesNotWaitOnRuntime() async throws {
        let service = RuntimePresentationService()
        let model = ClaudeRuntimeModel(service: service)
        model.start()
        try await settle { model.hasActiveRuntime && !model.isRequesting }
        #expect(!model.cancelBeforeQuitting { _ in Issue.record("Idle runtime must not defer Quit") })
        model.beginShutdown(); await model.finishShutdown()
    }

    @Test func quitWaitsForActualCancellationCompletion() async throws {
        let service = RuntimePresentationService(phase: .checking)
        let model = ClaudeRuntimeModel(service: service)
        model.start()
        try await settle { !model.isRequesting && model.snapshot.phase == .checking }
        var result: Bool?
        #expect(model.cancelBeforeQuitting { result = $0 })
        try await settle { await service.cancelEntered }
        #expect(result == nil)
        #expect(model.isCancelingForQuit)
        await service.releaseCancellation()
        try await settle { result != nil }
        #expect(result == true)
        #expect(model.hasActiveRuntime)
        model.beginShutdown(); await model.finishShutdown()
    }

    @Test func cancellationTimeoutCancelsQuitAndKeepsWorkingRuntime() async throws {
        let service = RuntimePresentationService(phase: .checking)
        let model = ClaudeRuntimeModel(service: service, quitBudget: .milliseconds(40))
        model.start()
        try await settle { !model.isRequesting && model.snapshot.phase == .checking }
        var result: Bool?
        #expect(model.cancelBeforeQuitting { result = $0 })
        try await settle { result != nil }
        #expect(result == false)
        #expect(model.hasActiveRuntime)
        #expect(model.notice != nil)
        await service.releaseCancellation()
        model.beginShutdown(); await model.finishShutdown()
    }

    @Test func shutdownIgnoresLatePresentationUpdates() async throws {
        let service = RuntimePresentationService()
        let model = ClaudeRuntimeModel(service: service)
        model.start()
        try await settle { model.hasActiveRuntime && !model.isRequesting }
        let before = model.snapshot
        model.beginShutdown()
        await service.emit(.failed)
        await Task.yield()
        #expect(model.snapshot == before)
        #expect(!model.canCheck)
        await model.finishShutdown()
    }

    // A first install signs in twice: once
    // so OpenBots can test Claude Code, then for the bots. The test sign-in
    // hid the banner and said "Connected" while no reply could run, and the
    // bots' first sign-in was worded as an expired one.
    @Test func emptyInstallOrdersBothSignInsAndNeverSaysConnectedEarly() async throws {
        let candidate = flowArtifact("2.1.300", "c")
        let runtimeService = FlowRuntimeService(.init(selection: .init(candidate: candidate), phase: .needsAuthentication))
        let botsService = FlowSetupService(subscription: .needsSignIn)
        let testService = FlowSetupService(subscription: .verified(try flowEvidence()))
        let runtime = ClaudeRuntimeModel(service: runtimeService)
        let bots = ClaudeSetupModel(service: botsService)
        let test = ClaudeSetupModel(service: testService)
        let flow = ClaudeSetupFlow(runtime: runtime, bots: bots, compatibility: test)
        runtime.start()
        try await settle { runtime.snapshot.phase == .needsAuthentication && !runtime.isRequesting }
        #expect(flow.presented === test)
        #expect(test.step == .signInForTesting)
        #expect(ClaudeConnectionBanner(model: test, openSetup: {}).isVisible)
        #expect(ClaudeSetupWording.title(for: test.state, step: test.step, localInstallationChecked: false)
            .hasPrefix("Step 1 of 2"))
        #expect(test.offersSignIn)

        test.beginOfficialSignIn()
        await test.actionTask?.value
        test.appBecameActive()
        await test.actionTask?.value
        #expect(test.state == .verified(try flowEvidence()))
        try await settle { await runtimeService.retries == 1 }
        #expect(ClaudeConnectionBanner(model: test, openSetup: {}).isVisible, "A test sign-in is not a connection")

        await runtimeService.emit(.init(selection: .init(candidate: candidate), phase: .checking))
        try await settle { runtime.snapshot.phase == .checking }
        #expect(test.step == .testing(.init(stage: .running, version: "2.1.300")))
        #expect(ClaudeConnectionBanner(model: test, openSetup: {}).isVisible)
        let testingTitle = ClaudeSetupWording.title(for: test.state, step: test.step, localInstallationChecked: true)
        #expect(testingTitle == "Testing Claude Code 2.1.300 before your bots use it")
        #expect(ClaudeSetupWording.status(for: test.state, step: test.step).contains("six short requests from your Claude plan"))
        #expect(!test.offersSignIn)
        #expect(await botsService.subscriptionCalls == 0, "No working version, so the bots' sign-in is not checked")

        await runtimeService.emit(.init(selection: .init(active: candidate), phase: .ready))
        try await settle { flow.presented === bots && bots.state == .needsSignIn }
        #expect(bots.step == .signInForBots)
        #expect(ClaudeConnectionBanner(model: bots, openSetup: {}).isVisible)
        #expect(ClaudeSetupWording.title(for: bots.state, step: bots.step, localInstallationChecked: true)
            .hasPrefix("Step 2 of 2"))
        let botsStatus = ClaudeSetupWording.status(for: bots.state, step: bots.step,
                                                   previouslyVerified: bots.hasBeenVerified)
        #expect(!botsStatus.contains("expired"), "A first install has no earlier sign-in to lose")
        #expect(await botsService.subscriptionCalls == 1)
        #expect(await runtimeService.retries == 1)

        await botsService.answer(.verified(try flowEvidence()))
        bots.beginOfficialSignIn()
        await bots.actionTask?.value
        bots.appBecameActive()
        await bots.actionTask?.value
        #expect(!ClaudeConnectionBanner(model: bots, openSetup: {}).isVisible, "Connected only now")
        #expect(bots.step == .bots)
        bots.requireSignInAfterTurnFailure(observedEpoch: bots.authenticationEpoch)
        #expect(ClaudeSetupWording.status(for: bots.state, step: bots.step, previouslyVerified: bots.hasBeenVerified)
            .contains("may have expired"), "A sign-in that passed and was lost says so")
        flow.close(); runtime.beginShutdown(); await runtime.finishShutdown()
    }

    // With no working version the main Check Claude was the test's
    // own, and every press that ended verified re-ran the paid suite.
    @Test func checkClaudeAndRepeatSignInsNeverRerunATestedCandidate() async throws {
        let candidate = flowArtifact("2.1.300", "c")
        let phases: [ManagedClaudeRuntimeSnapshot.Phase] = [.needsAuthentication, .failed, .waitingForIdle, .cancelled]
        for phase in phases {
            let runtimeService = FlowRuntimeService(.init(selection: .init(candidate: candidate), phase: phase))
            let testService = FlowSetupService(subscription: .verified(try flowEvidence()))
            let runtime = ClaudeRuntimeModel(service: runtimeService)
            let test = ClaudeSetupModel(service: testService)
            let flow = ClaudeSetupFlow(runtime: runtime, bots: ClaudeSetupModel(service: FlowSetupService(subscription: .needsSignIn)),
                                       compatibility: test)
            runtime.start()
            try await settle { runtime.snapshot.phase == phase && !runtime.isRequesting }
            test.checkSubscription()
            await test.actionTask?.value
            test.checkSubscription()
            await test.actionTask?.value
            #expect(test.state == .verified(try flowEvidence()))
            try await Task.sleep(for: .milliseconds(30))
            #expect(await runtimeService.retries == 0, "Check Claude never starts the suite (\(phase))")
            #expect(await runtimeService.checks == 1, "\(phase)")

            // A real sign-in: lost, signed in again, verified on return.
            await testService.answer(.needsSignIn)
            test.checkSubscription()
            await test.actionTask?.value
            #expect(test.offersSignIn, "A lost test sign-in is offered again (\(phase))")
            await testService.answer(.verified(try flowEvidence()))
            test.beginOfficialSignIn()
            await test.actionTask?.value
            test.appBecameActive()
            await test.actionTask?.value
            #expect(test.state == .verified(try flowEvidence()))
            if phase == .needsAuthentication {
                try await settle { await runtimeService.retries == 1 }
            } else {
                try await Task.sleep(for: .milliseconds(30))
                #expect(await runtimeService.retries == 0, "A tested candidate waits for the disclosed retry (\(phase))")
            }
            #expect(await runtimeService.checks == 1, "\(phase)")
            flow.close(); runtime.beginShutdown(); await runtime.finishShutdown()
        }
    }

    // Discovery ran only when the phase was ready, so a waiting or
    // failed candidate left a working version on the bundled model list.
    @Test func workingVersionChecksTheBotsSignInOnceWhateverTheCandidateDoes() async throws {
        let active = flowArtifact("2.1.300", "a")
        let candidate = flowArtifact("2.1.301", "c")
        let runtimeService = FlowRuntimeService(.init(selection: .init(active: active, candidate: candidate),
                                                      phase: .needsAuthentication))
        let evidence = try flowEvidence()
        let botsService = FlowSetupService(subscription: .verified(evidence))
        let runtime = ClaudeRuntimeModel(service: runtimeService)
        let bots = ClaudeSetupModel(service: botsService)
        let flow = ClaudeSetupFlow(runtime: runtime, bots: bots,
                                   compatibility: ClaudeSetupModel(service: FlowSetupService(subscription: .needsSignIn)))
        runtime.start()
        try await settle { await botsService.subscriptionCalls == 1 && bots.state == .verified(evidence) }
        #expect(flow.presented === bots)
        #expect(bots.step == .bots)
        #expect(!ClaudeConnectionBanner(model: bots, openSetup: {}).isVisible)
        for phase in [ManagedClaudeRuntimeSnapshot.Phase.waitingForIdle, .checking, .failed] {
            await runtimeService.emit(.init(selection: .init(active: active, candidate: candidate), phase: phase))
            try await settle { runtime.snapshot.phase == phase }
        }
        #expect(await botsService.subscriptionCalls == 1, "Once per working version")
        await runtimeService.emit(.init(selection: .init(active: candidate, previous: active), phase: .ready))
        try await settle { await botsService.subscriptionCalls == 2 }
        #expect(bots.step == .bots, "Switching versions on a set-up Mac is not a first install")
        flow.close(); runtime.beginShutdown(); await runtime.finishShutdown()
    }

    // Coming back from Terminal checks the test sign-in and the
    // runtime together. The sign-in verified while the runtime was discovering,
    // the follow-up was dropped, and the suite never started.
    @Test func aSignInThatLandsMidDiscoveryStartsTheSuiteOnceTheRuntimeSettles() async throws {
        let candidate = flowArtifact("2.1.300", "c")
        let waiting = ManagedClaudeRuntimeSnapshot(selection: .init(candidate: candidate), phase: .needsAuthentication)
        let runtimeService = FlowRuntimeService(waiting)
        let test = ClaudeSetupModel(service: FlowSetupService(subscription: .verified(try flowEvidence())))
        let runtime = ClaudeRuntimeModel(service: runtimeService)
        let flow = ClaudeSetupFlow(runtime: runtime, bots: ClaudeSetupModel(service: FlowSetupService(subscription: .needsSignIn)),
                                   compatibility: test)
        runtime.start()
        try await settle { runtime.snapshot.phase == .needsAuthentication && !runtime.isRequesting }
        await runtimeService.emit(.init(selection: .init(candidate: candidate), phase: .discovering))
        try await settle { runtime.snapshot.phase == .discovering }
        test.beginOfficialSignIn()
        await test.actionTask?.value
        test.appBecameActive()
        await test.actionTask?.value
        #expect(test.state == .verified(try flowEvidence()))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await runtimeService.retries == 0, "Nothing is decided while the runtime is discovering")
        await runtimeService.emit(waiting)
        try await settle { await runtimeService.retries == 1 }
        await runtimeService.emit(.init(selection: .init(candidate: candidate), phase: .checking))
        await runtimeService.emit(waiting)
        try await settle { runtime.snapshot.phase == .needsAuthentication }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await runtimeService.retries == 1, "One sign-in starts the suite once")
        flow.close(); runtime.beginShutdown(); await runtime.finishShutdown()
    }

    @Test func aSignInThatLandsMidCheckWaitsAndIsDroppedWhenTheCandidateFails() async throws {
        let candidate = flowArtifact("2.1.300", "c")
        let runtimeService = FlowRuntimeService(.init(selection: .init(candidate: candidate), phase: .checking))
        let testService = FlowSetupService(subscription: .needsSignIn)
        let test = ClaudeSetupModel(service: testService)
        let runtime = ClaudeRuntimeModel(service: runtimeService)
        let flow = ClaudeSetupFlow(runtime: runtime, bots: ClaudeSetupModel(service: FlowSetupService(subscription: .needsSignIn)),
                                   compatibility: test)
        runtime.start()
        try await settle { runtime.snapshot.phase == .checking && !runtime.isRequesting }
        // While a version is tested, sign-in is offered only for a lost test sign-in.
        test.checkSubscription()
        await test.actionTask?.value
        #expect(test.offersSignIn)
        await testService.answer(.verified(try flowEvidence()))
        test.beginOfficialSignIn()
        await test.actionTask?.value
        test.appBecameActive()
        await test.actionTask?.value
        #expect(test.state == .verified(try flowEvidence()))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await runtimeService.retries == 0, "Nothing is decided while the runtime is checking")
        await runtimeService.emit(.init(selection: .init(candidate: candidate), phase: .failed))
        try await settle { runtime.snapshot.phase == .failed }
        await runtimeService.emit(.init(selection: .init(candidate: candidate), phase: .needsAuthentication))
        try await settle { runtime.snapshot.phase == .needsAuthentication }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await runtimeService.retries == 0, "A candidate that failed after the sign-in waits for the disclosed retry")
        flow.close(); runtime.beginShutdown(); await runtime.finishShutdown()
    }

    @Test func stepFollowsTheCandidateWhileNoVersionWorks() throws {
        let candidate = flowArtifact("2.1.300", "c")
        let verified = ClaudeSetupState.verified(try flowEvidence())
        let withCandidate = ClaudeRuntimeState(candidate: candidate)
        func step(_ phase: ManagedClaudeRuntimeSnapshot.Phase, _ state: ClaudeSetupState = .notChecked,
                  selection: ClaudeRuntimeState?) -> ClaudeSetupStep {
            ClaudeSetupFlow.step(runtime: .init(selection: selection, phase: phase), compatibility: state,
                                 sawNoActiveRuntime: false)
        }
        #expect(step(.needsAuthentication, verified, selection: withCandidate) == .signInForTesting)
        #expect(step(.checking, selection: withCandidate) == .testing(.init(stage: .running, version: "2.1.300")))
        #expect(step(.waitingForIdle, selection: withCandidate) == .testing(.init(stage: .waiting, version: "2.1.300")))
        #expect(step(.failed, selection: withCandidate) == .testing(.init(stage: .failed, version: "2.1.300")))
        #expect(step(.cancelled, selection: withCandidate) == .testing(.init(stage: .failed, version: "2.1.300")))
        #expect(step(.idle, selection: withCandidate) == .signInForTesting)
        #expect(step(.idle, verified, selection: withCandidate) == .testing(.init(stage: .waiting, version: "2.1.300")))
        #expect(step(.unavailable, selection: .init()) == .signInForTesting)
        // Signed in for testing with nothing to test is not "press Retry".
        #expect(step(.unavailable, verified, selection: .init()) == .noVersionToTest)
        #expect(step(.idle, verified, selection: .init()) == .noVersionToTest)
        #expect(ClaudeSetupWording.title(for: verified, step: .noVersionToTest, localInstallationChecked: true)
            == "No Claude Code to test yet")
        let nothingToTest = ClaudeSetupWording.status(for: verified, step: .noVersionToTest)
        #expect(nothingToTest.contains("Check Claude") && !nothingToTest.contains("Retry"))
        #expect(step(.discovering, selection: nil) == .bots, "Before the selection is read, nothing claims a first install")
        #expect(!ClaudeSetupFlow.awaitsFirstVersion(.init(phase: .unavailable)))
        #expect(ClaudeSetupFlow.awaitsFirstVersion(.init(phase: .failed)), "Unreadable storage still has no working version")
        #expect(ClaudeSetupFlow.step(runtime: .init(selection: .init(active: candidate), phase: .ready),
                                     compatibility: .notChecked, sawNoActiveRuntime: true) == .signInForBots)
        #expect(ClaudeSetupFlow.followUp(afterSignInAt: .needsAuthentication) == .retry)
        for phase in [ManagedClaudeRuntimeSnapshot.Phase.failed, .ready, .waitingForIdle, .cancelled, .stopped] {
            #expect(ClaudeSetupFlow.followUp(afterSignInAt: phase) == .none, "\(phase)")
        }
        for phase in [ManagedClaudeRuntimeSnapshot.Phase.discovering, .checking] {
            #expect(ClaudeSetupFlow.followUp(afterSignInAt: phase) == .wait, "\(phase)")
        }
    }

    private func settle(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await predicate())
    }
}
