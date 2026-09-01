import AppKit
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class TrustAuthorizationWorkspaceTests: XCTestCase {
    func testConstructionIsInertAndFixtureCacheIsBoundToExactConversation() async {
        var constructed: [TrustFixtureContext] = []
        let model = TrustAuthorizationWorkspaceModel { context in
            constructed.append(context)
            return TrustAuthorizationFixtureService(context: context)
        }
        let first = trustContext(1)
        let second = TrustFixtureContext(teammateID: first.teammateID, conversationID: ConversationID(trustUUID(2)))
        XCTAssertTrue(constructed.isEmpty)
        model.activateContext(first, teammateName: "Ada")
        XCTAssertTrue(constructed.isEmpty)
        await model.load()
        XCTAssertEqual(constructed, [first])
        XCTAssertEqual(model.snapshot?.macOSPermission, .notDetermined)
        XCTAssertTrue(model.snapshot?.grants.isEmpty == true)

        await model.prepareGrant(.readReferenceFolder)
        await model.confirmPendingGrant()
        XCTAssertNotNil(model.snapshot?.activeGrant(for: .readReferenceFolder))
        await model.prepareGrant(.createCompletedArtifact)
        XCTAssertNotNil(model.pendingGrantReview)

        model.activateContext(second, teammateName: "Ada")
        XCTAssertNil(model.pendingGrantReview)
        XCTAssertNil(model.snapshot)
        await model.load()
        XCTAssertTrue(model.snapshot?.grants.isEmpty == true)
        XCTAssertEqual(constructed, [first, second])

        model.activateContext(first, teammateName: "Ada renamed")
        await model.load()
        XCTAssertNotNil(model.snapshot?.activeGrant(for: .readReferenceFolder))
        XCTAssertNil(model.pendingGrantReview)
        XCTAssertEqual(model.teammateName, "Ada renamed")
        XCTAssertEqual(constructed, [first, second])

        let relaunched = trustModel()
        relaunched.activateContext(first, teammateName: "Ada")
        await relaunched.load()
        XCTAssertTrue(relaunched.snapshot?.grants.isEmpty == true)
    }

    func testExactApprovalRequiresSeparateApproveAndSimulateThenCannotReplay() async {
        let model = trustModel()
        model.activateContext(trustContext(10), teammateName: "Mira")
        await model.load()
        await model.prepareGrant(.createCompletedArtifact)
        XCTAssertNil(model.snapshot?.activeGrant(for: .createCompletedArtifact))
        await model.confirmPendingGrant()
        XCTAssertNil(model.pendingGrantReview)
        await model.setMacOSPermission(.granted)
        await model.prepareApproval(.sampleArtifact)
        XCTAssertEqual(model.approvalReview?.proposal, .sampleArtifact)
        XCTAssertEqual(model.approvalState, .pending)

        await model.simulateOnce()
        XCTAssertEqual(model.approvalState, .pending)
        await model.approveOnce()
        XCTAssertEqual(model.approvalState, .approved)
        await model.simulateOnce()
        XCTAssertEqual(model.approvalState, .simulated)
        let evidenceCount = model.snapshot?.evidence.count
        await model.simulateOnce()
        XCTAssertEqual(model.snapshot?.evidence.count, evidenceCount)

        await model.prepareApproval(.sampleArtifact)
        await model.deny()
        XCTAssertEqual(model.approvalState, .denied)
        await model.simulateOnce()
        XCTAssertEqual(model.approvalState, .denied)
    }

    func testRevocationInvalidatesPreparedApprovalAndAxesRemainIndependent() async {
        let model = trustModel()
        model.activateContext(trustContext(20), teammateName: "Mira")
        await model.load()
        await model.setConnectorInstallation(.installed)
        XCTAssertEqual(model.snapshot?.connector.accountAuthentication, .notAuthenticated)
        XCTAssertEqual(model.snapshot?.connector.perBotGrant, .notGranted)
        XCTAssertEqual(model.snapshot?.macOSPermission, .notDetermined)
        await model.setConnectorAuthentication(.authenticated)
        await model.setMacOSPermission(.granted)
        XCTAssertNil(model.snapshot?.activeGrant(for: .connectorUse))

        await model.prepareGrant(.connectorUse)
        await model.confirmPendingGrant()
        await model.prepareApproval(.sampleConnectorSend)
        await model.approveOnce()
        XCTAssertEqual(model.approvalState, .approved)
        await model.revoke(.connectorUse)
        XCTAssertNil(model.snapshot?.activeGrant(for: .connectorUse))
        XCTAssertEqual(model.approvalState, .invalidated)
        XCTAssertEqual(model.snapshot?.connector.accountAuthentication, .authenticated)
        XCTAssertEqual(model.snapshot?.connector.installation, .installed)
        await model.simulateOnce()
        XCTAssertEqual(model.approvalState, .invalidated)
    }

    func testCancelAndExpiryLeaveNoActiveGrantOrAction() async {
        let clock = TrustTestClock()
        let model = TrustAuthorizationWorkspaceModel { context in
            TrustAuthorizationFixtureService(context: context, clock: clock)
        }
        model.activateContext(trustContext(30), teammateName: "Mira")
        await model.load()
        await model.prepareGrant(.readReferenceFolder)
        await model.cancelPendingGrant()
        XCTAssertNil(model.pendingGrantReview)
        XCTAssertNil(model.snapshot?.activeGrant(for: .readReferenceFolder))
        await model.prepareGrant(.createCompletedArtifact)
        await model.confirmPendingGrant()
        await model.setMacOSPermission(.granted)
        await model.prepareApproval(.sampleArtifact)
        clock.advance(301)
        await model.approveOnce()
        XCTAssertEqual(model.approvalState, .expired)
        XCTAssertTrue(model.failure?.contains("expired") == true)
        await model.simulateOnce()
        XCTAssertEqual(model.approvalState, .expired)
    }

    func testLateLoadCannotReplaceNewConversation() async {
        let first = trustContext(40)
        let second = trustContext(41)
        let gate = TrustTestGate()
        let delayed = DelayedTrustFixture(context: first, gate: gate, delay: .snapshot)
        let model = TrustAuthorizationWorkspaceModel { context in
            if context == first { return delayed }
            return TrustAuthorizationFixtureService(context: context)
        }
        model.activateContext(first, teammateName: "Mira")
        let load = Task { await model.load() }
        for _ in 0..<100 where await !gate.hasStarted() { await Task.yield() }
        let loadStarted = await gate.hasStarted()
        XCTAssertTrue(loadStarted)
        model.activateContext(second, teammateName: "Ada")
        await model.load()
        await gate.release()
        await load.value
        XCTAssertEqual(model.context, second)
        XCTAssertEqual(model.snapshot?.context, second)
        XCTAssertEqual(model.teammateName, "Ada")
        XCTAssertFalse(model.isBusy)
    }

    func testLateConfirmationDoesNotLeakAcrossSwitchOrReopenAReview() async {
        let first = trustContext(50)
        let second = trustContext(51)
        let gate = TrustTestGate()
        let delayed = DelayedTrustFixture(context: first, gate: gate, delay: .confirmation)
        let model = TrustAuthorizationWorkspaceModel { context in
            if context == first { return delayed }
            return TrustAuthorizationFixtureService(context: context)
        }
        model.activateContext(first, teammateName: "Mira")
        await model.load()
        await model.prepareGrant(.readReferenceFolder)
        let confirm = Task { await model.confirmPendingGrant() }
        for _ in 0..<100 where await !gate.hasStarted() { await Task.yield() }
        let confirmationStarted = await gate.hasStarted()
        XCTAssertTrue(confirmationStarted)
        model.activateContext(second, teammateName: "Ada")
        await model.load()
        await gate.release()
        await confirm.value
        XCTAssertEqual(model.snapshot?.context, second)
        XCTAssertTrue(model.snapshot?.grants.isEmpty == true)
        XCTAssertNil(model.pendingGrantReview)
        model.activateContext(first, teammateName: "Mira")
        await model.load()
        XCTAssertNotNil(model.snapshot?.activeGrant(for: .readReferenceFolder))
        XCTAssertNil(model.pendingGrantReview)
    }

    func testRenderedFixtureFitsNarrowAndWideInspectorWithoutEditableOrSelectionArtifacts() async {
        let model = trustModel()
        model.activateContext(trustContext(60), teammateName: "Ada Durable")
        await model.load()
        await model.prepareGrant(.createCompletedArtifact)
        let host = NSHostingView(rootView: TrustAuthorizationWorkspaceView(model: model))
        for width in [CGFloat(270), CGFloat(420)] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 4_000)
            settleTrustHost(host)
            assertStableTrustHost(host)
            XCTAssertEqual(model.grantReviewState, .pending)
        }
        await model.confirmPendingGrant()
        await model.setMacOSPermission(.granted)
        await model.prepareApproval(.sampleArtifact)
        for width in [CGFloat(270), CGFloat(420)] {
            host.frame.size.width = width
            settleTrustHost(host)
            assertStableTrustHost(host)
            XCTAssertEqual(model.approvalState, .pending)
        }
    }

    func testFixtureCopySeparatesDemoAuthorityFromRealAccess() {
        XCTAssertTrue(TrustAuthorizationPresentation.fixtureDisclosure.contains("No real access"))
        XCTAssertTrue(TrustAuthorizationPresentation.fixtureDisclosure.contains("resets"))
        XCTAssertTrue(TrustAuthorizationPresentation.readChangeBoundary.contains("never allows"))
        XCTAssertTrue(TrustAuthorizationPresentation.shellWarning.contains("not be a hard"))
        XCTAssertTrue(TrustAuthorizationPresentation.readinessDisclosure.contains("do not install"))
        XCTAssertTrue(TrustAuthorizationPresentation.reviewDisclosure.contains("does not execute"))
    }

    func testApprovalSurfaceHasNoModalDefaultActionOrAlternateLayoutTree() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/TrustAuthorizationWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in [
            ".sheet(", ".alert(", ".defaultAction", "ViewThatFits",
            "TextEditor(", "SecureField(", "StableSelectableText(", ".textSelection(",
            "NSOpenPanel", "NSSavePanel", "NSWorkspace", "onSubmit"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Unexpected UI path: \(forbidden)")
        }
        XCTAssertTrue(source.contains("Confirm Demo Grant"))
        XCTAssertTrue(source.contains("Approve Once"))
        XCTAssertTrue(source.contains("Simulate Once"))
        XCTAssertTrue(source.contains("Deny"))
        XCTAssertTrue(source.contains("accessibilityLabel"))
    }
}

@MainActor
private func trustModel() -> TrustAuthorizationWorkspaceModel {
    TrustAuthorizationWorkspaceModel { TrustAuthorizationFixtureService(context: $0) }
}

private func trustContext(_ suffix: UInt64) -> TrustFixtureContext {
    TrustFixtureContext(teammateID: TeammateID(trustUUID(suffix + 1000)), conversationID: ConversationID(trustUUID(suffix)))
}

private func trustUUID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "B4000000-0000-0000-0000-%012llx", suffix))!
}

@MainActor
private func settleTrustHost(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    for _ in 0..<4 {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private func assertStableTrustHost(_ host: NSView) {
    let size = host.fittingSize
    XCTAssertTrue(size.height.isFinite)
    XCTAssertGreaterThan(size.height, 0)
    XCTAssertLessThan(size.height, 20_000)
    let descendants = host.trustDescendants
    XCTAssertTrue(descendants.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable })
    XCTAssertTrue(descendants.compactMap { $0 as? NSTextView }.allSatisfy { !$0.isEditable })
    XCTAssertFalse(descendants.contains { String(describing: type(of: $0)).contains("SelectionOverlay") })
}

private extension NSView {
    var trustDescendants: [NSView] { subviews + subviews.flatMap(\.trustDescendants) }
}

private final class TrustTestClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_783_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor TrustTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var released = false
    func hasStarted() -> Bool { started }
    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DelayedTrustFixture: TrustAuthorizationFixtureServicing {
    enum Delay { case snapshot, confirmation }
    let base: TrustAuthorizationFixtureService
    let gate: TrustTestGate
    let delay: Delay
    private var didDelaySnapshot = false

    init(context: TrustFixtureContext, gate: TrustTestGate, delay: Delay) {
        base = TrustAuthorizationFixtureService(context: context)
        self.gate = gate
        self.delay = delay
    }

    func snapshot(context: TrustFixtureContext) async throws -> TrustFixtureSnapshot {
        let snapshot = try await base.snapshot(context: context)
        if delay == .snapshot, !didDelaySnapshot {
            didDelaySnapshot = true
            await gate.wait()
        }
        return snapshot
    }
    func prepareGrant(context: TrustFixtureContext, capability: FixtureCapability) async throws -> FixtureGrantReview {
        try await base.prepareGrant(context: context, capability: capability)
    }
    func confirmGrant(context: TrustFixtureContext, review: FixtureGrantReview) async throws -> TrustFixtureSnapshot {
        let snapshot = try await base.confirmGrant(context: context, review: review)
        if delay == .confirmation { await gate.wait() }
        return snapshot
    }
    func declineGrant(context: TrustFixtureContext, review: FixtureGrantReview) async throws -> TrustFixtureSnapshot {
        try await base.declineGrant(context: context, review: review)
    }
    func revoke(context: TrustFixtureContext, grantID: CapabilityGrantID) async throws -> TrustFixtureSnapshot {
        try await base.revoke(context: context, grantID: grantID)
    }
    func prepareApproval(context: TrustFixtureContext, proposal: FixtureActionProposal) async throws -> FixtureApprovalReview {
        try await base.prepareApproval(context: context, proposal: proposal)
    }
    func resolveApproval(context: TrustFixtureContext, review: FixtureApprovalReview, decision: ApprovalDecision) async throws -> TrustFixtureSnapshot {
        try await base.resolveApproval(context: context, review: review, decision: decision)
    }
    func consumeApprovedPreview(context: TrustFixtureContext, review: FixtureApprovalReview) async throws -> TrustFixtureSnapshot {
        try await base.consumeApprovedPreview(context: context, review: review)
    }
    func setMacOSPermission(context: TrustFixtureContext, value: FixtureMacOSPermission) async throws -> TrustFixtureSnapshot {
        try await base.setMacOSPermission(context: context, value: value)
    }
    func setConnectorInstallation(context: TrustFixtureContext, value: ConnectorInstallationState) async throws -> TrustFixtureSnapshot {
        try await base.setConnectorInstallation(context: context, value: value)
    }
    func setConnectorAuthentication(context: TrustFixtureContext, value: ConnectorAccountAuthenticationState) async throws -> TrustFixtureSnapshot {
        try await base.setConnectorAuthentication(context: context, value: value)
    }
}
