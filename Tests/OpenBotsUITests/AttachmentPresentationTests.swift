import AppKit
import Foundation
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class AttachmentPresentationTests: XCTestCase {
    func testNoAdapterPreservesInertPreviewPresentation() async {
        let model = AttachmentPartPresentationModel()
        await model.load(route: attachmentRoute(1), presentation: nil)
        XCTAssertNil(model.asset)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canReveal)
        await model.reveal()
        XCTAssertFalse(model.isRevealing)
    }

    func testMetadataLoadsOnceAndOnlyExplicitRevealUsesExactThreeIDs() async throws {
        let route = attachmentRoute(2)
        let asset = try presentationAttachmentAsset(route)
        let recorder = AttachmentPresentationRecorder(assets: [route: asset])
        let model = AttachmentPartPresentationModel()
        let adapter = attachmentAdapter(recorder)
        await model.load(route: route, presentation: adapter)
        await model.load(route: route, presentation: adapter)
        XCTAssertEqual(model.asset, asset)
        XCTAssertTrue(model.canReveal)
        let before = await recorder.receipt()
        XCTAssertEqual(before.resolves, [route])
        XCTAssertTrue(before.reveals.isEmpty)
        await model.reveal()
        let after = await recorder.receipt()
        XCTAssertEqual(after.reveals, [route])
        XCTAssertNil(model.errorMessage)
    }

    func testLateMetadataCannotRetargetAnotherMessagePart() async throws {
        let first = attachmentRoute(3)
        let second = attachmentRoute(4)
        let gate = AttachmentPresentationGate()
        let secondAsset = try presentationAttachmentAsset(second)
        let recorder = AttachmentPresentationRecorder(
            assets: [first: try presentationAttachmentAsset(first), second: secondAsset], loadGates: [first: gate]
        )
        let model = AttachmentPartPresentationModel()
        let adapter = attachmentAdapter(recorder)
        let slow = Task { await model.load(route: first, presentation: adapter) }
        await waitPresentationGate(gate)
        await model.load(route: second, presentation: adapter)
        await gate.release()
        await slow.value
        XCTAssertEqual(model.asset, secondAsset)
        await model.reveal()
        let calls = await recorder.receipt()
        XCTAssertEqual(calls.reveals, [second])
    }

    func testWrongAssetAndMissingMetadataDisableRevealAndAllowExplicitReload() async throws {
        let requested = attachmentRoute(5)
        let wrong = try presentationAttachmentAsset(attachmentRoute(6))
        let recorder = AttachmentPresentationRecorder(assets: [requested: wrong])
        let model = AttachmentPartPresentationModel()
        let adapter = attachmentAdapter(recorder)
        await model.load(route: requested, presentation: adapter)
        XCTAssertNil(model.asset)
        XCTAssertFalse(model.canReveal)
        XCTAssertNotNil(model.errorMessage)
        await model.reveal()
        let before = await recorder.receipt()
        XCTAssertTrue(before.reveals.isEmpty)
        let repaired = try presentationAttachmentAsset(requested)
        await recorder.setAsset(repaired, route: requested)
        await model.load(route: requested, presentation: adapter, force: true)
        XCTAssertEqual(model.asset, repaired)
        XCTAssertNil(model.errorMessage)
    }

    func testRevealIsOneAtATimeAndFailureStaysLocalWithoutExposingPaths() async throws {
        let route = attachmentRoute(7)
        let gate = AttachmentPresentationGate()
        let recorder = AttachmentPresentationRecorder(assets: [route: try presentationAttachmentAsset(route)],
                                                        revealGate: gate, failReveal: true)
        let model = AttachmentPartPresentationModel()
        await model.load(route: route, presentation: attachmentAdapter(recorder))
        let first = Task { await model.reveal() }
        await waitPresentationGate(gate)
        XCTAssertTrue(model.isRevealing)
        XCTAssertFalse(model.canReveal)
        await model.reveal()
        await gate.release()
        await first.value
        XCTAssertFalse(model.isRevealing)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.errorMessage?.contains("/Users/") ?? true)
        XCTAssertNotNil(model.asset)
        let calls = await recorder.receipt()
        XCTAssertEqual(calls.reveals, [route])
    }

    func testSavedAttachmentChipRendersAtNarrowAndWideWidthsWithoutRevealing() async throws {
        let route = attachmentRoute(8)
        let gate = AttachmentPresentationGate()
        let recorder = AttachmentPresentationRecorder(assets: [route: try presentationAttachmentAsset(route)], loadGates: [route: gate])
        let message = ChatMessageSnapshot(
            id: route.messageID, author: .user,
            parts: [ChatMessagePartSnapshot(id: route.partID, ordinal: 0,
                content: .attachment(ChatAttachmentSnapshot(id: route.attachmentID, displayName: "Attachment",
                                                            detail: "Saved local attachment reference")))],
            delivery: .sent, timestamp: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let controller = NSHostingController(rootView: TranscriptMessagePartsView(message: message)
            .environment(\.attachmentPresentation, attachmentAdapter(recorder)))
        controller.view.frame = CGRect(x: 0, y: 0, width: 270, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        await waitPresentationGate(gate)
        for _ in 0..<3 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let loadingSize = controller.sizeThatFits(in: CGSize(width: 270, height: 400))
        XCTAssertTrue(loadingSize.width.isFinite && loadingSize.height.isFinite)
        XCTAssertGreaterThan(loadingSize.height, 0)
        XCTAssertLessThanOrEqual(loadingSize.width, 270.5)
        XCTAssertLessThanOrEqual(loadingSize.height, 400)
        await gate.release()
        for width: CGFloat in [270, 640] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
            for _ in 0..<4 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 400))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThanOrEqual(size.width, width + 0.5)
            XCTAssertLessThanOrEqual(size.height, 400)
        }
        let calls = await recorder.receipt()
        XCTAssertEqual(calls.resolves, [route], "The actual chip must execute its bounded metadata task")
        XCTAssertTrue(calls.reveals.isEmpty)
        // Rendered geometry and metadata loading only, not physical keyboard,
        // VoiceOver, Finder, or accessibility-helper verification.
    }

    func testSourceKeepsExplicitRevealAndAccessibleChildControlsWithoutOpen() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: directory.appendingPathComponent("Sources/OpenBotsUI/TranscriptMessagePartsView.swift"), encoding: .utf8)
        let attachmentSection = try XCTUnwrap(source.components(separatedBy: "private struct AttachmentPartChip: View {").last)
            .components(separatedBy: "private struct ArtifactPartCard: View {")[0]
        XCTAssertTrue(attachmentSection.contains("Button(\"Reveal in Finder\")"))
        XCTAssertTrue(attachmentSection.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(attachmentSection.contains("Button(\"Reload Attachment\")"))
        XCTAssertFalse(attachmentSection.contains("NSWorkspace"))
        XCTAssertFalse(attachmentSection.contains("URL("))
        XCTAssertFalse(attachmentSection.contains("Button(\"Open"))
    }
}

private actor AttachmentPresentationRecorder {
    private var assets: [AttachmentPresentationRoute: AttachmentAsset]
    private let loadGates: [AttachmentPresentationRoute: AttachmentPresentationGate]
    private let revealGate: AttachmentPresentationGate?
    private let failReveal: Bool
    private var resolves: [AttachmentPresentationRoute] = []
    private var reveals: [AttachmentPresentationRoute] = []
    init(assets: [AttachmentPresentationRoute: AttachmentAsset],
         loadGates: [AttachmentPresentationRoute: AttachmentPresentationGate] = [:],
         revealGate: AttachmentPresentationGate? = nil, failReveal: Bool = false) {
        self.assets = assets
        self.loadGates = loadGates
        self.revealGate = revealGate
        self.failReveal = failReveal
    }
    func resolve(_ route: AttachmentPresentationRoute) async -> AttachmentAsset? {
        resolves.append(route)
        if let gate = loadGates[route] { await gate.wait() }
        return assets[route]
    }
    func reveal(_ route: AttachmentPresentationRoute) async throws {
        reveals.append(route)
        if let revealGate { await revealGate.wait() }
        if failReveal { throw AttachmentPresentationFailure() }
    }
    func setAsset(_ asset: AttachmentAsset, route: AttachmentPresentationRoute) { assets[route] = asset }
    func receipt() -> (resolves: [AttachmentPresentationRoute], reveals: [AttachmentPresentationRoute]) { (resolves, reveals) }
}

private actor AttachmentPresentationGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct AttachmentPresentationFailure: LocalizedError {
    var errorDescription: String? { "Cannot reveal /Users/example/private/file.txt" }
}

@MainActor
private func attachmentAdapter(_ recorder: AttachmentPresentationRecorder) -> AttachmentPresentation {
    AttachmentPresentation(resolve: { messageID, partID, attachmentID in
        await recorder.resolve(AttachmentPresentationRoute(messageID: messageID, partID: partID, attachmentID: attachmentID))
    }, reveal: { messageID, partID, attachmentID in
        try await recorder.reveal(AttachmentPresentationRoute(messageID: messageID, partID: partID, attachmentID: attachmentID))
    })
}

private func attachmentRoute(_ value: UInt64) -> AttachmentPresentationRoute {
    func identifier(_ suffix: UInt64) -> UUID {
        UUID(uuidString: String(format: "AD200000-0000-0000-0000-%012llx", suffix))!
    }
    return AttachmentPresentationRoute(messageID: identifier(value * 10), partID: identifier(value * 10 + 1),
                                       attachmentID: identifier(value * 10 + 2))
}

private func presentationAttachmentAsset(_ route: AttachmentPresentationRoute) throws -> AttachmentAsset {
    try AttachmentAsset(id: AttachmentID(route.attachmentID), conversationID: ConversationID(route.messageID),
                        displayName: "Research notes and supporting sources.txt", typeIdentifier: "public.plain-text",
                        byteCount: 4096, sha256: String(repeating: "c", count: 64),
                        createdAt: Date(timeIntervalSince1970: 1_788_000_000))
}

private func waitPresentationGate(_ gate: AttachmentPresentationGate) async {
    for _ in 0..<500 {
        if await gate.started { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Attachment presentation did not reach its bounded gate")
}
