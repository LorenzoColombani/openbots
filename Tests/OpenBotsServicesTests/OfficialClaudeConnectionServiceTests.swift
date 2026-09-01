import Foundation
import OpenBotsRuntime
import Testing
@testable import OpenBotsServices

private struct ConnectionOfflineFixture: ClaudeOfflineSetupInspecting {
    func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        .init(installation: .verified, profile: .metadataVerified)
    }
}

private actor ConnectionPreparationFixture: ClaudeConnectionPreparing {
    var calls = 0
    let result: ClaudeConnectionPreparation
    init(_ result: ClaudeConnectionPreparation) { self.result = result }
    func prepareConnection() async -> ClaudeConnectionPreparation { calls += 1; return result }
}

private actor ConnectionTransportFixture: ClaudeStatusChecking, ClaudeConnectionSignInHandingOff {
    var statusTargets: [ClaudeConnectionTarget] = []
    var handoffTargets: [ClaudeConnectionTarget] = []
    let status: ClaudeConnectionStatusResult
    let acceptsHandoff: Bool
    init(status: ClaudeConnectionStatusResult = .eligible(.max), acceptsHandoff: Bool = true) {
        self.status = status
        self.acceptsHandoff = acceptsHandoff
    }
    func checkStatus(target: ClaudeConnectionTarget) async -> ClaudeConnectionStatusResult {
        statusTargets.append(target)
        return status
    }
    func handOffOfficialSignIn(target: ClaudeConnectionTarget) async -> Bool {
        handoffTargets.append(target)
        return acceptsHandoff
    }
}

/// Test-only admission. No production allow-all implementation exists.
private struct ConnectionTestAdmission: ClaudeConnectionAdmitting {
    func unmetRequirement(for operation: ClaudeConnectionOperation, target: ClaudeConnectionTarget) async -> ClaudeSetupRequirement? { nil }
}

private actor ConnectionSuspendedAdmission: ClaudeConnectionAdmitting {
    private var pending: CheckedContinuation<ClaudeSetupRequirement?, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var entered = false
    func unmetRequirement(for operation: ClaudeConnectionOperation, target: ClaudeConnectionTarget) async -> ClaudeSetupRequirement? {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
        pending?.resume(returning: nil)
        pending = nil
    }
}

private func connectionTargetFixture() throws -> ClaudeConnectionTarget {
    try .init(
        executableURL: URL(fileURLWithPath: "/fixture/claude"),
        expectedExecutableSHA256: String(repeating: "a", count: 64),
        profileURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/CLIProfile"),
        workingDirectoryURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/CLIProfile"),
        temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/CLIProfile"),
        homeDirectoryURL: URL(fileURLWithPath: "/fixture")
    )
}

@Test("Connection construction, offline checks and default admission never invoke a provider")
func connectionDefaultRetainsLiveGates() async throws {
    let target = try connectionTargetFixture()
    let prepare = ConnectionPreparationFixture(.ready(
        local: .init(installation: .verified, profile: .metadataVerified), target: target
    ))
    let transport = ConnectionTransportFixture()
    let service = OfficialClaudeConnectionService(
        inspector: ConnectionOfflineFixture(), preparer: prepare,
        statusChecker: transport, signInHandoff: transport
    )
    #expect(await prepare.calls == 0)
    #expect(await service.checkThisMac().outcome == .readyToConnect)
    #expect(await prepare.calls == 0)
    #expect(await service.checkSubscription().outcome == .actionRequired(.correctedStatusCheckApproval))
    #expect(await service.beginOfficialSignIn().outcome == .actionRequired(.tracedOfficialSignIn))
    #expect(await prepare.calls == 2)
    #expect(await transport.statusTargets.isEmpty)
    #expect(await transport.handoffTargets.isEmpty)
}

@Test("User-initiated policy hands off only on explicit action and separately checks the same profile")
func connectionHandoffThenExplicitStatus() async throws {
    let target = try connectionTargetFixture()
    let prepare = ConnectionPreparationFixture(.ready(
        local: .init(installation: .verified, profile: .metadataVerified), target: target
    ))
    let transport = ConnectionTransportFixture()
    let checkedAt = Date(timeIntervalSince1970: 123)
    let service = OfficialClaudeConnectionService(
        inspector: ConnectionOfflineFixture(), preparer: prepare,
        admission: UserInitiatedClaudeConnectionAdmission(), statusChecker: transport,
        signInHandoff: transport, now: { checkedAt }
    )
    #expect(await service.checkThisMac().outcome == .readyToConnect)
    #expect(await prepare.calls == 0)
    #expect(await transport.statusTargets.isEmpty)
    #expect(await transport.handoffTargets.isEmpty)
    #expect(await service.beginOfficialSignIn().outcome == .handedOffNeedsVerification)
    #expect(await transport.statusTargets.isEmpty)
    #expect(await transport.handoffTargets == [target])
    let verified = await service.checkSubscription()
    guard case .verified(let proof) = verified.outcome else { Issue.record("No verified fixture result"); return }
    #expect(proof.tier == .max)
    #expect(proof.checkedAt == checkedAt)
    #expect(await prepare.calls == 2)
    #expect(await transport.statusTargets == [target])
}

@Test("Status never signs in automatically and noneligible outcomes never verify", arguments: [
    ClaudeConnectionStatusResult.signedOut, .inconclusive, .cancelled
])
func connectionNoneligibleStatus(_ result: ClaudeConnectionStatusResult) async throws {
    let target = try connectionTargetFixture()
    let transport = ConnectionTransportFixture(status: result)
    let service = OfficialClaudeConnectionService(
        inspector: ConnectionOfflineFixture(),
        preparer: ConnectionPreparationFixture(.ready(
            local: .init(installation: .verified, profile: .metadataVerified), target: target
        )),
        admission: ConnectionTestAdmission(), statusChecker: transport, signInHandoff: transport
    )
    let report = await service.checkSubscription()
    switch result {
    case .signedOut: #expect(report.outcome == .needsSignIn)
    case .inconclusive: #expect(report.outcome == .problem(.connectionCheckInconclusive))
    case .cancelled: #expect(report.outcome == .cancelled)
    case .eligible: Issue.record("Invalid test case")
    }
    #expect(await transport.statusTargets.count == 1)
    #expect(await transport.handoffTargets.isEmpty)
}

@Test("Failed fresh preflight refuses even with test admission")
func connectionFailedPreflightCannotLaunch() async {
    let transport = ConnectionTransportFixture()
    let service = OfficialClaudeConnectionService(
        inspector: ConnectionOfflineFixture(),
        preparer: ConnectionPreparationFixture(.refused(.init(outcome: .problem(.profileRejected)))),
        admission: ConnectionTestAdmission(), statusChecker: transport, signInHandoff: transport
    )
    #expect(await service.beginOfficialSignIn().outcome == .problem(.profileRejected))
    #expect(await service.checkSubscription().outcome == .problem(.profileRejected))
    #expect(await transport.statusTargets.isEmpty)
    #expect(await transport.handoffTargets.isEmpty)
}

@Test("Terminal refusing handoff never becomes a verified subscription")
func connectionHandoffRejection() async throws {
    let target = try connectionTargetFixture()
    let transport = ConnectionTransportFixture(acceptsHandoff: false)
    let service = OfficialClaudeConnectionService(
        inspector: ConnectionOfflineFixture(),
        preparer: ConnectionPreparationFixture(.ready(
            local: .init(installation: .verified, profile: .metadataVerified), target: target
        )),
        admission: ConnectionTestAdmission(), statusChecker: transport, signInHandoff: transport
    )
    #expect(await service.beginOfficialSignIn().outcome == .problem(.signInIncomplete))
    #expect(await transport.statusTargets.isEmpty)
}

@Test("Cancellation during admission prevents provider dispatch and refuses overlapping actions")
func connectionCancellationDuringAdmission() async throws {
    let target = try connectionTargetFixture()
    let transport = ConnectionTransportFixture()
    let admission = ConnectionSuspendedAdmission()
    let service = OfficialClaudeConnectionService(
        inspector: ConnectionOfflineFixture(),
        preparer: ConnectionPreparationFixture(.ready(
            local: .init(installation: .verified, profile: .metadataVerified), target: target
        )),
        admission: admission, statusChecker: transport, signInHandoff: transport
    )
    let action = Task { await service.checkSubscription() }
    await admission.waitForEntry()
    #expect(await service.beginOfficialSignIn().outcome == .problem(.connectionCheckInconclusive))
    action.cancel()
    await admission.release()
    #expect(await action.value.outcome == .cancelled)
    #expect(await transport.statusTargets.isEmpty)
    #expect(await transport.handoffTargets.isEmpty)
}
