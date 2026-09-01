import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class CharacterMotionVisibilityTests: XCTestCase {
    func testEligibilityRequiresEveryNativeVisibilityConditionAndFiniteViewport() {
        let eligible = eligibleSnapshot
        XCTAssertTrue(eligible.permitsMotion)
        let exclusions: [(inout CharacterMotionVisibilitySnapshot) -> Void] = [
            { $0.isAttached = false },
            { $0.windowIsVisible = false },
            { $0.windowIsUnoccluded = false },
            { $0.windowIsMiniaturized = true },
            { $0.windowIsKey = false },
            { $0.applicationIsActive = false },
            { $0.hasHiddenAncestor = true },
            { $0.visibleRect = .zero },
            { $0.visibleRect = CGRect(x: 0, y: 0, width: 0, height: 20) },
            { $0.visibleRect = CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20) },
            { $0.visibleRect = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20) },
            { $0.visibleRect = CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20) }
        ]
        for exclude in exclusions {
            var snapshot = eligible
            exclude(&snapshot)
            XCTAssertFalse(snapshot.permitsMotion)
        }
        var partiallyClipped = eligible
        partiallyClipped.visibleRect = CGRect(x: 0, y: 0, width: 1, height: 20)
        XCTAssertTrue(partiallyClipped.permitsMotion)

        var environment = EnvironmentValues()
        XCTAssertTrue(environment.characterMotionAllowed)
        environment.characterMotionAllowed = false
        XCTAssertFalse(environment.characterMotionAllowed)
    }

    func testDeferredAssessmentCoalescesChangesAndPublishesOnlyNewValues() async throws {
        // Synthetic state tests the callback contract, not a physically active window.
        let view = RecordingMotionVisibilityView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        defer { view.stopObserving() }
        view.syntheticSnapshot = eligibleSnapshot
        var published: [Bool] = []
        view.onVisibilityChange = { published.append($0) }
        for _ in 0..<20 { view.requestVisibilityAssessment() }
        XCTAssertEqual(view.assessmentCount, 0)
        XCTAssertTrue(published.isEmpty, "Never publish synchronously during native layout.")
        try await waitForAssessment { view.assessmentCount == 1 }
        XCTAssertEqual(published, [true])

        for _ in 0..<20 { view.requestVisibilityAssessment() }
        try await waitForAssessment { view.assessmentCount == 2 }
        XCTAssertEqual(published, [true], "Unchanged visibility cannot restart motion.")

        view.syntheticSnapshot?.windowIsKey = false
        view.requestVisibilityAssessment()
        view.syntheticSnapshot?.windowIsKey = true
        view.requestVisibilityAssessment()
        try await waitForAssessment { view.assessmentCount == 3 }
        XCTAssertEqual(published, [true], "Use the current state, not an earlier queued snapshot.")

        view.syntheticSnapshot?.applicationIsActive = false
        view.requestVisibilityAssessment()
        try await waitForAssessment { view.assessmentCount == 4 }
        XCTAssertEqual(published, [true, false])
    }

    func testNeverVisibleNativeWindowAndAncestorClippingStayStatic() async throws {
        let fixture = MotionVisibilityFixture()
        defer { fixture.dispose() }
        var published: [Bool] = []
        fixture.view.onVisibilityChange = { published.append($0) }
        try await waitForAssessment { fixture.view.assessmentCount > 0 }
        let initial = fixture.view.lastSnapshot
        XCTAssertEqual(initial?.isAttached, true)
        XCTAssertEqual(initial?.windowIsVisible, false)
        XCTAssertEqual(initial?.windowIsKey, false)
        XCTAssertEqual(initial?.permitsMotion, false)
        XCTAssertFalse(try XCTUnwrap(initial).visibleRect.isEmpty)
        XCTAssertTrue(published.isEmpty, "Initial false requires no binding publication.")
        XCTAssertNil(fixture.view.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(fixture.view.acceptsFirstResponder)
        XCTAssertFalse(fixture.view.isAccessibilityElement())

        let beforeGeometry = fixture.geometryDescription
        let beforeScroll = fixture.view.assessmentCount
        fixture.clip.bounds.origin = NSPoint(x: 0, y: 180)
        let immediateGeometry = fixture.geometryDescription
        try await waitForAssessment { fixture.view.assessmentCount > beforeScroll }
        let settledGeometry = fixture.geometryDescription
        XCTAssertTrue(
            try XCTUnwrap(fixture.view.lastSnapshot).visibleRect.isEmpty,
            "Before: \(beforeGeometry)\nImmediate: \(immediateGeometry)\nAssessed: \(settledGeometry)"
        )
        XCTAssertTrue(published.isEmpty)

        fixture.document.isHidden = true
        XCTAssertTrue(fixture.view.currentVisibilitySnapshot().hasHiddenAncestor)
        fixture.document.isHidden = false
        XCTAssertFalse(fixture.view.currentVisibilitySnapshot().hasHiddenAncestor)
        fixture.view.removeFromSuperview()
        XCTAssertFalse(fixture.view.currentVisibilitySnapshot().isAttached)
        XCTAssertTrue(published.isEmpty)
    }

    func testWindowSubscriptionsFollowOnlyTheOwningWindow() async throws {
        let first = MotionVisibilityFixture()
        let second = MotionVisibilityFixture()
        defer { first.dispose(); second.dispose() }
        try await waitForAssessment { first.view.assessmentCount > 0 && second.view.assessmentCount > 0 }
        let initial = first.view.assessmentCount
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: second.window)
        await drainNativeCallbacks()
        XCTAssertEqual(first.view.assessmentCount, initial)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first.window)
        try await waitForAssessment { first.view.assessmentCount > initial }

        let beforeMove = first.view.assessmentCount
        second.document.addSubview(first.view)
        try await waitForAssessment { first.view.assessmentCount > beforeMove }
        let afterMove = first.view.assessmentCount
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first.window)
        await drainNativeCallbacks()
        XCTAssertEqual(first.view.assessmentCount, afterMove, "Old window subscriptions are removed.")
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: second.window)
        try await waitForAssessment { first.view.assessmentCount > afterMove }
        XCTAssertEqual(first.view.lastSnapshot?.permitsMotion, false)
    }

    func testDismantleCancelsPendingAssessmentAndRemovesNativeSubscriptions() async throws {
        let fixture = MotionVisibilityFixture()
        defer { fixture.dispose() }
        try await waitForAssessment { fixture.view.assessmentCount > 0 }
        var published: [Bool] = []
        fixture.view.onVisibilityChange = { published.append($0) }
        fixture.view.syntheticSnapshot = eligibleSnapshot
        let beforeStop = fixture.view.assessmentCount
        fixture.view.requestVisibilityAssessment()
        CharacterMotionVisibilityObserver.dismantleNSView(fixture.view, coordinator: ())
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        fixture.clip.bounds.origin = NSPoint(x: 0, y: 120)
        fixture.view.requestVisibilityAssessment()
        await drainNativeCallbacks()
        XCTAssertEqual(fixture.view.assessmentCount, beforeStop)
        XCTAssertTrue(published.isEmpty)
        XCTAssertNil(fixture.view.onVisibilityChange)
    }

    func testQueuedAssessmentDoesNotRetainRemovedNativeProbe() async {
        var view: RecordingMotionVisibilityView? = RecordingMotionVisibilityView(frame: .zero)
        weak var releasedView = view
        var published: [Bool] = []
        view?.onVisibilityChange = { published.append($0) }
        view?.syntheticSnapshot = eligibleSnapshot
        view?.requestVisibilityAssessment()
        view = nil
        XCTAssertNil(releasedView)
        await drainNativeCallbacks()
        XCTAssertTrue(published.isEmpty)
    }

    private var eligibleSnapshot: CharacterMotionVisibilitySnapshot {
        CharacterMotionVisibilitySnapshot(
            isAttached: true, windowIsVisible: true, windowIsUnoccluded: true,
            windowIsMiniaturized: false, windowIsKey: true, applicationIsActive: true,
            hasHiddenAncestor: false, visibleRect: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
    }

    private func waitForAssessment(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "Deferred native visibility assessment did not arrive.")
    }

    private func drainNativeCallbacks() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

@MainActor
private final class RecordingMotionVisibilityView: CharacterMotionVisibilityView {
    var syntheticSnapshot: CharacterMotionVisibilitySnapshot?
    private(set) var assessmentCount = 0
    private(set) var lastSnapshot: CharacterMotionVisibilitySnapshot?

    override func currentVisibilitySnapshot() -> CharacterMotionVisibilitySnapshot {
        assessmentCount += 1
        let snapshot = syntheticSnapshot ?? super.currentVisibilitySnapshot()
        lastSnapshot = snapshot
        return snapshot
    }
}

@MainActor
private final class MotionVisibilityFixture {
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.borderless], backing: .buffered, defer: true
    )
    let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let document = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 400))
    let view = RecordingMotionVisibilityView(frame: CGRect(x: 10, y: 20, width: 40, height: 40))

    init() {
        window.isReleasedWhenClosed = false
        window.contentView = clip
        clip.documentView = document
        document.addSubview(view)
        // Never order or activate this window: these are native geometry/lifecycle
        // negative checks, not a substitute for installed active-window motion QA.
    }

    var geometryDescription: String {
        "clip.frame=\(clip.frame), bounds=\(clip.bounds), clipsToBounds=\(clip.clipsToBounds), "
            + "documentVisibleRect=\(clip.documentVisibleRect), document.frame=\(document.frame), "
            + "document.bounds=\(document.bounds), probe.frame=\(view.frame), "
            + "probe.visibleRect=\(view.visibleRect), assessed.visibleRect=\(String(describing: view.lastSnapshot?.visibleRect))"
    }

    func dispose() {
        view.stopObserving()
        view.removeFromSuperview()
        window.close()
    }
}
