import Testing
@testable import OpenBotsServices

private actor LaunchReadinessInspectorSpy: LaunchReadinessInspecting {
    private let state: LaunchReadinessState
    private var inspectionCount = 0

    init(state: LaunchReadinessState) {
        self.state = state
    }

    func inspectReadiness() async -> LaunchReadinessState {
        inspectionCount += 1
        return state
    }

    func calls() -> Int { inspectionCount }
}

private let fixedLaunchReadinessStates: [LaunchReadinessState] = [
    .notConfigured,
    .opening,
    .ready,
    .recovery(.installationReceiptUnavailable),
    .recovery(.ownedRootVerificationFailed),
    .recovery(.databaseProtectionUnavailable),
    .recovery(.databaseOpenFailed),
    .recovery(.databaseValidationFailed)
]

@Test("Constructing launch readiness retains its inspector without inspecting")
func launchReadinessConstructionIsInert() async {
    let inspector = LaunchReadinessInspectorSpy(state: .ready)

    _ = LaunchReadinessService(inspector: inspector)

    #expect(await inspector.calls() == 0)
}

@Test(
    "Fixed launch readiness returns the exact closed state",
    arguments: fixedLaunchReadinessStates
)
func fixedLaunchReadinessReturnsExactState(_ expected: LaunchReadinessState) async {
    let service = LaunchReadinessService(
        inspector: FixedLaunchReadinessInspector(state: expected)
    )

    #expect(await service.inspectReadiness() == expected)
}

@Test("Every closed recovery issue has a distinct stable identity and state")
func closedLaunchRecoveryIssuesAreDistinguishable() {
    let issues = LaunchRecoveryIssue.allCases
    let rawValues = issues.map(\.rawValue)
    let states = issues.map(LaunchReadinessState.recovery)

    #expect(Set(rawValues).count == issues.count)
    for firstIndex in states.indices {
        for secondIndex in states.indices where firstIndex != secondIndex {
            #expect(states[firstIndex] != states[secondIndex])
        }
    }
}
