import Foundation
import OpenBotsContent
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private actor ClaudeSetupInspectorSpy: ClaudeOfflineSetupInspecting {
    var calls = 0
    let snapshot: ClaudeOfflineSetupSnapshot

    init(_ snapshot: ClaudeOfflineSetupSnapshot) { self.snapshot = snapshot }

    func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        calls += 1
        return snapshot
    }
}

private struct FixedClaudeInstallationInspector: ClaudeInstallationInspecting {
    let state: ClaudeInstallationState
    func inspectInstallation() async -> ClaudeInstallationInspection {
        .init(state: state, details: .init(requestedPath: "/fixture/.local/bin/claude"))
    }
}

private actor ClaudeSetupRootLookupSpy {
    var calls = 0
    func lookup() -> VerifiedOwnedRoot? { calls += 1; return nil }
}

@Test("Claude offline composition does not inspect profile after installation rejection")
func claudeSetupRejectedInstallationDoesNotReadProfile() async {
    let root = ClaudeSetupRootLookupSpy()
    let inspector = NativeClaudeOfflineSetupInspector(
        layout: .init(homeDirectory: URL(fileURLWithPath: "/fixture"), systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp")),
        installationInspector: FixedClaudeInstallationInspector(state: .rejected(.unexpectedSigner)),
        applicationSupportRoot: { await root.lookup() }
    )
    #expect(await root.calls == 0)
    let result = await inspector.inspectOffline()
    #expect(result.installation == .rejected)
    #expect(result.profile == .notChecked)
    #expect(await root.calls == 0)
}

@Test("Claude profile inspection cannot manufacture app storage ownership")
func claudeSetupMissingVerifiedStorageRemainsUnavailable() async {
    let root = ClaudeSetupRootLookupSpy()
    let inspector = NativeClaudeOfflineSetupInspector(
        layout: .init(homeDirectory: URL(fileURLWithPath: "/fixture"), systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp")),
        installationInspector: FixedClaudeInstallationInspector(state: .verified),
        applicationSupportRoot: { await root.lookup() }
    )
    let result = await inspector.inspectOffline()
    #expect(result.installation == .verified)
    #expect(result.profile == .unavailable)
    #expect(await root.calls == 1)
}

@Test("Claude setup construction and gated provider actions do not inspect or launch anything")
func claudeSetupProviderActionsRetainTheirSpecificGates() async {
    let inspector = ClaudeSetupInspectorSpy(.init(installation: .verified, profile: .metadataVerified))
    let service = GuardedClaudeSetupService(inspector: inspector)
    #expect(await inspector.calls == 0)
    #expect(await service.checkSubscription().outcome == .actionRequired(.correctedStatusCheckApproval))
    #expect(await service.beginOfficialSignIn().outcome == .actionRequired(.tracedOfficialSignIn))
    #expect(await inspector.calls == 0)
}

@Test("Offline Claude success remains unverified and never enables provider work")
func claudeSetupOfflineSuccessDoesNotEstablishConnection() async {
    let snapshot = ClaudeOfflineSetupSnapshot(
        installation: .verified, profile: .metadataVerified,
        details: [.init(label: "Signature", value: "Checked locally")]
    )
    let inspector = ClaudeSetupInspectorSpy(snapshot)
    let service = GuardedClaudeSetupService(inspector: inspector)
    let report = await service.checkThisMac()
    #expect(report.local == snapshot)
    #expect(report.outcome == .actionRequired(.correctedStatusCheckApproval))
    #expect(await inspector.calls == 1)
}

private let localClaudeFailures: [(ClaudeOfflineSetupSnapshot, ClaudeSetupProblem)] = [
    (.init(installation: .notChecked, profile: .notChecked), .installationUnavailable),
    (.init(installation: .missing, profile: .notChecked), .installationMissing),
    (.init(installation: .rejected, profile: .metadataVerified), .installationRejected),
    (.init(installation: .unavailable, profile: .metadataVerified), .installationUnavailable),
    (.init(installation: .verified, profile: .notChecked), .profileUnavailable),
    (.init(installation: .verified, profile: .missing), .profileMissing),
    (.init(installation: .verified, profile: .rejected), .profileRejected),
    (.init(installation: .verified, profile: .unavailable), .profileUnavailable)
]

@Test("Claude installation/profile failures stay distinct from sign-in state", arguments: localClaudeFailures)
func claudeSetupPreservesLocalFailure(_ snapshot: ClaudeOfflineSetupSnapshot, _ expected: ClaudeSetupProblem) async {
    let service = GuardedClaudeSetupService(inspector: ClaudeSetupInspectorSpy(snapshot))
    let report = await service.checkThisMac()
    #expect(report.local == snapshot)
    #expect(report.outcome == .problem(expected))
}

@Test("Only successful official first-party Pro/Max status can construct verified subscription evidence")
func claudeSetupSubscriptionEvidenceRejectsAlternateOrUncertainAuthentication() {
    let date = Date(timeIntervalSince1970: 1_788_110_000)
    let accepted = ClaudeVerifiedSubscription(
        exitCode: 0, loggedIn: true, authMethod: "Claude.AI",
        apiProvider: "FirstParty", subscriptionType: "MAX", checkedAt: date
    )
    #expect(accepted?.tier == .max)
    #expect(accepted?.checkedAt == date)
    #expect(ClaudeVerifiedSubscription(
        exitCode: 0, loggedIn: true, authMethod: "claude.ai",
        apiProvider: "firstParty", subscriptionType: "pro", checkedAt: date
    )?.tier == .pro)
    for exit: Int32 in [-1, 1, 2] {
        #expect(ClaudeVerifiedSubscription(
            exitCode: exit, loggedIn: true, authMethod: "claude.ai",
            apiProvider: "firstParty", subscriptionType: "max", checkedAt: date
        ) == nil)
    }
    for auth in ["api_key", "console", "", "claude.ai "] {
        #expect(ClaudeVerifiedSubscription(
            exitCode: 0, loggedIn: true, authMethod: auth,
            apiProvider: "firstParty", subscriptionType: "max", checkedAt: date
        ) == nil)
    }
    for provider: String? in [nil, "", "bedrock", "vertex", "foundry"] {
        #expect(ClaudeVerifiedSubscription(
            exitCode: 0, loggedIn: true, authMethod: "claude.ai",
            apiProvider: provider, subscriptionType: "max", checkedAt: date
        ) == nil)
    }
    for tier: String? in [nil, "", "free", "team", "enterprise"] {
        #expect(ClaudeVerifiedSubscription(
            exitCode: 0, loggedIn: true, authMethod: "claude.ai",
            apiProvider: "firstParty", subscriptionType: tier, checkedAt: date
        ) == nil)
    }
    #expect(ClaudeVerifiedSubscription(
        exitCode: 0, loggedIn: false, authMethod: "claude.ai",
        apiProvider: "firstParty", subscriptionType: "max", checkedAt: date
    ) == nil)
}

private actor CountingClaudeInstallationInspector: ClaudeInstallationInspecting {
    private(set) var calls = 0
    let state: ClaudeInstallationState
    init(state: ClaudeInstallationState) { self.state = state }
    func inspectInstallation() async -> ClaudeInstallationInspection {
        calls += 1
        return .init(state: state, details: .init(requestedPath: "/fixture/.local/bin/claude"))
    }
}

// With no retained runtime the selection reports
// unavailable, so a Mac without Claude Code never saw the install command.
@Test("An empty selection with no Claude Code installed reads as missing on every setup path")
func setupReportsMissingClaudeCodeWhenTheSelectionIsEmpty() async {
    let layout = PreviewStorageLayout(homeDirectory: URL(fileURLWithPath: "/fixture"),
                                      systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp"))
    let installation = SetupClaudeInstallationInspector(
        selected: FixedClaudeInstallationInspector(state: .unavailable(.invalidPolicy)),
        installed: FixedClaudeInstallationInspector(state: .missing))
    #expect(await installation.inspectInstallation().state == .missing)

    let root = ClaudeSetupRootLookupSpy()
    let offline = NativeClaudeOfflineSetupInspector(layout: layout, installationInspector: installation,
                                                    applicationSupportRoot: { await root.lookup() })
    let report = await GuardedClaudeSetupService(inspector: offline).checkThisMac()
    #expect(report.outcome == .problem(.installationMissing))
    #expect(report.local?.installation == .missing)

    let preparer = NativeClaudeConnectionPreparer(layout: layout, installationInspector: installation,
                                                  applicationSupportRoot: { await root.lookup() })
    guard case .refused(let refused) = await preparer.prepareConnection() else {
        Issue.record("A missing installation must refuse the connection")
        return
    }
    #expect(refused.outcome == .problem(.installationMissing))
    #expect(await root.calls == 0, "A missing installation never reaches the account folder")
}

@Test("The native installer location decides only an empty selection; any other answer is the selection's own")
func setupKeepsTheSelectionsOwnAnswer() async {
    for native in [ClaudeInstallationState.verified, .rejected(.unexpectedSigner), .unavailable(.invalidPolicy)] {
        let installation = SetupClaudeInstallationInspector(
            selected: FixedClaudeInstallationInspector(state: .unavailable(.invalidPolicy)),
            installed: FixedClaudeInstallationInspector(state: native))
        #expect(await installation.inspectInstallation().state == .unavailable(.invalidPolicy), "\(native)")
    }
    for selected in [ClaudeInstallationState.verified, .rejected(.unexpectedSigner)] {
        let installed = CountingClaudeInstallationInspector(state: .missing)
        let installation = SetupClaudeInstallationInspector(
            selected: FixedClaudeInstallationInspector(state: selected), installed: installed)
        #expect(await installation.inspectInstallation().state == selected)
        #expect(await installed.calls == 0, "A selection that answered is not second-guessed")
    }
}
