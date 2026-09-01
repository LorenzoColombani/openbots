import OpenBotsServices
import Testing
@testable import OpenBotsUI

private actor UIReadinessInspectorSpy: LaunchReadinessInspecting {
    private let fixedState: LaunchReadinessState
    private var inspectionCount = 0

    init(state: LaunchReadinessState) {
        fixedState = state
    }

    func inspectReadiness() async -> LaunchReadinessState {
        inspectionCount += 1
        return fixedState
    }

    func calls() -> Int { inspectionCount }
}

private actor GatedUIReadinessInspector: LaunchReadinessInspecting {
    private var inspectionCount = 0
    private var inspectionStarted = false
    private var queuedResult: LaunchReadinessState?
    private var continuation: CheckedContinuation<LaunchReadinessState, Never>?

    func inspectReadiness() async -> LaunchReadinessState {
        inspectionCount += 1
        inspectionStarted = true
        if let queuedResult {
            self.queuedResult = nil
            return queuedResult
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool { inspectionStarted }
    func calls() -> Int { inspectionCount }

    func resolve(with state: LaunchReadinessState) {
        guard let continuation else {
            queuedResult = state
            return
        }
        self.continuation = nil
        continuation.resume(returning: state)
    }
}

private let injectedTerminalReadinessStates: [LaunchReadinessState] = [
    .ready,
    .recovery(.databaseValidationFailed)
]

@Test("Launch readiness model defaults honestly without inspecting")
@MainActor
func launchReadinessModelDefaultIsHonestAndInert() async {
    let inspector = UIReadinessInspectorSpy(state: .ready)

    let model = LaunchReadinessModel(inspector: inspector)

    #expect(model.state == .notConfigured)
    #expect(await inspector.calls() == 0)
}

@Test(
    "Refresh publishes opening before the injected terminal state",
    arguments: injectedTerminalReadinessStates
)
@MainActor
func refreshPublishesOpeningBeforeTerminalState(
    _ terminalState: LaunchReadinessState
) async {
    let inspector = GatedUIReadinessInspector()
    let model = LaunchReadinessModel(inspector: inspector)
    let refreshTask = Task { await model.refresh() }

    var started = false
    for _ in 0..<100 {
        started = await inspector.hasStarted()
        if started { break }
        await Task.yield()
    }

    guard started else {
        await inspector.resolve(with: terminalState)
        await refreshTask.value
        Issue.record("Readiness inspection did not start within the bounded yield window")
        return
    }

    #expect(model.state == .opening)
    await inspector.resolve(with: terminalState)
    await refreshTask.value

    #expect(model.state == terminalState)
    #expect(await inspector.calls() == 1)
}

@Test("Preview review-state replacement performs no readiness inspection")
@MainActor
func previewReviewStateReplacementIsNoIO() async {
    let inspector = UIReadinessInspectorSpy(state: .ready)
    let model = LaunchReadinessModel(inspector: inspector)

    model.setPreviewReviewState(.ready)
    #expect(model.state == .ready)
    model.setPreviewReviewState(.recovery(.ownedRootVerificationFailed))

    #expect(model.state == .recovery(.ownedRootVerificationFailed))
    #expect(await inspector.calls() == 0)
}

@Test("Launch status construction keeps ready and recovery behavior injected and inert")
@MainActor
func launchStatusActionsRemainInjected() async {
    let inspector = UIReadinessInspectorSpy(
        state: .recovery(.installationReceiptUnavailable)
    )
    let model = LaunchReadinessModel(inspector: inspector)
    var readyActionCalls = 0

    _ = LaunchStatusView(
        model: model,
        continueAction: { readyActionCalls += 1 }
    )

    #expect(readyActionCalls == 0)
    #expect(await inspector.calls() == 0)
}
