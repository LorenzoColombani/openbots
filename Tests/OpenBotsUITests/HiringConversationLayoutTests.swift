import AppKit
import Darwin
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class HiringConversationLayoutTests: XCTestCase {
    private static let childFlag = "OPENBOTS_HIRING_LAYOUT_CHILD"
    private static let completed = "OPENBOTS_HIRING_LAYOUT_COMPLETED"

    func testFixedReviewAndFlexibleComposerStayInsideNativeWindow() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            for scheme: ColorScheme in [.light, .dark] { try await exerciseLayout(scheme: scheme) }
            hiringLayoutLog(Self.completed)
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest", "-XCTest",
            "OpenBotsUITests.HiringConversationLayoutTests/testFixedReviewAndFlexibleComposerStayInsideNativeWindow",
            Bundle(for: Self.self).bundleURL.path
        ]
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment[Self.childFlag] = "1"
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        try output.fileHandleForWriting.close()
        let log = HiringLayoutChildLog(reader: output.fileHandleForReading)
        log.start()
        let deadline = Date(timeIntervalSinceNow: 20)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let timedOut = child.isRunning
        if timedOut {
            child.terminate()
            let grace = Date(timeIntervalSinceNow: 1)
            while child.isRunning, Date() < grace { try await Task.sleep(for: .milliseconds(10)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let receipt = log.finish()
        let receiptURL = try hiringLayoutEvidenceDirectory().appendingPathComponent("native-" + UUID().uuidString + ".log")
        try receipt.write(to: receiptURL, atomically: true, encoding: .utf8)
        hiringLayoutLog("receipt: \(receiptURL.path)")
        XCTAssertFalse(timedOut, "Native hiring layout exceeded its child deadline. \(receipt)")
        XCTAssertEqual(child.terminationStatus, 0, receipt)
        XCTAssertTrue(receipt.contains(Self.completed), "Missing completed native layout exercise. \(receipt)")
    }

    private func exerciseLayout(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let marker = "Ada Candidate Layout"
        let draft = "Unsent candidate notes — exact Unicode e\u{301}.\nKeep the second line visible."
        let timestamp = Date(timeIntervalSince1970: 1_788_000_000)
        let draftID = HiringDraftID(hiringLayoutID(1))
        let snapshot = HiringConversationSnapshot(
            persisted: try HiringDraftSnapshot(
                draft: HiringDraft(
                    id: draftID, phase: .collecting, displayName: marker,
                    role: "Source reviewer", revision: 1, createdAt: timestamp, updatedAt: timestamp
                ),
                turns: [HiringTurn(
                    id: HiringTurnID(hiringLayoutID(2)), draftID: draftID, sequence: 1,
                    author: .guide, text: "Describe the work this teammate should help with.", createdAt: timestamp
                )]
            ), focusedField: .responsibilities
        )
        let service = HiringLayoutService(snapshot: snapshot)
        let model = HiringConversationModel(service: service)
        await model.load()
        model.composerText = draft
        let originalModelID = model.id
        let originalRows = model.displayRows
        let originalReview = model.reviewItems
        let teammate = TeammateRowSnapshot(
            id: hiringLayoutID(3), name: "Existing teammate", role: "Local fixture", activity: .idle, identitySeed: 14
        )
        let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
        let conversation = ConversationModel(
            conversationID: hiringLayoutID(4), title: teammate.name, composerText: "Existing chat draft",
            readyDeliveryDescription: "Synthetic local test. No runtime or storage.", inputAvailability: .ready
        )
        let root = OpenBotsRootView(
            sidebar: sidebar, conversation: conversation, createTeammate: {}, openSettings: {},
            detailOverride: AnyView(HiringConversationView(model: model))
        ).environment(\.colorScheme, scheme)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .minSize
        let window = HiringLayoutWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_050, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        // This fixture window is never ordered, made key, or activated. It
        // exercises real native controls without touching the installed app.
        var previousComposer: NSView?
        var narrowComposerWidth: CGFloat = 0
        for width: CGFloat in [1_050, 1_080, 1_400] {
            window.setContentSize(CGSize(width: width, height: 720))
            controller.view.frame.size = CGSize(width: width, height: 720)
            try await settleHiringLayout(controller.view)
            // No input is driven into this never-ordered fixture. Resign the
            // transient field editor before capturing the underlying control;
            // its initial hidden-window geometry can lag the resized field.
            window.makeFirstResponder(nil)
            try await settleHiringLayout(controller.view)
            let content = try XCTUnwrap(window.contentView)
            let field = try XCTUnwrap(content.hiringLayoutDescendants.compactMap { $0 as? NSTextField }.first {
                !$0.isEditable && $0.isSelectable && $0.stringValue == marker
            }, "The review must contain the actual selectable candidate value")
            let review = try XCTUnwrap(field.enclosingScrollView, "Candidate value must be inside the review's native scroll view")
            let composer = try XCTUnwrap(hiringLayoutEditor(in: content, text: draft))
            hiringLayoutLog("review rect \(review.convert(review.bounds, to: content)), composer rect \(composer.convert(composer.bounds, to: content))")
            assertContained(review, in: content)
            assertContained(field, in: content)
            assertContained(composer, in: content)
            XCTAssertGreaterThanOrEqual(composer.bounds.height, 28, "A multiline hiring draft must not be clipped to one line")
            if let field = composer as? NSTextField {
                let measured = field.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: field.bounds.width, height: 10_000)) ?? .zero
                hiringLayoutLog("composer field \(field.bounds), cell \(measured), maxLines \(field.maximumNumberOfLines)")
                XCTAssertGreaterThanOrEqual(field.bounds.height + 1, measured.height, "The complete multiline field must fit")
            }
            XCTAssertEqual(review.bounds.width, 340, accuracy: 1)
            if let previousComposer { XCTAssertTrue(previousComposer === composer, "Resize must retain the native draft editor") }
            previousComposer = composer
            if width == 1_050 { narrowComposerWidth = composer.bounds.width }
            if width == 1_400 { XCTAssertGreaterThan(composer.bounds.width, narrowComposerWidth + 200) }
            XCTAssertEqual(model.composerText, draft)
            XCTAssertTrue(model.composerText.utf8.elementsEqual(draft.utf8))
            XCTAssertEqual(model.id, originalModelID)
            XCTAssertEqual(model.previewIdentity.id, draftID.rawValue)
            XCTAssertEqual(model.displayRows, originalRows)
            XCTAssertEqual(model.reviewItems, originalReview)
            XCTAssertEqual(sidebar.selection, teammate.id)
            XCTAssertEqual(conversation.conversationID, hiringLayoutID(4))
            XCTAssertEqual(conversation.composerText, "Existing chat draft")
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertTrue(window.sheets.isEmpty)
            XCTAssertEqual(content.bounds.width, width, accuracy: 1)
            hiringLayoutLog("\(scheme) \(width): review=\(review.bounds.width), composer=\(composer.bounds.width), native minimum=\(window.contentMinSize.width)")
            if width == 1_050 { try captureHiringLayout(content, name: "hiring-\(scheme)-1050.png") }
        }
        XCTAssertEqual(window.contentMinSize.width, 1_050, accuracy: 1)
        XCTAssertLessThanOrEqual(window.contentMinSize.width, 1_050, "The native minimum must still fit the requested three-column viewport")
        let calls = await service.calls()
        XCTAssertEqual(calls.loads, 1)
        XCTAssertEqual(calls.mutations, 0)
        // SwiftUI virtual toolbar/close buttons are not necessarily NSButtons
        // in a hidden host. This test does not claim physical toggle coverage.
    }

    private func assertContained(_ view: NSView, in root: NSView) {
        let rect = view.convert(view.bounds, to: root)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        XCTAssertLessThanOrEqual(rect.maxX, root.bounds.width + 1)
        XCTAssertGreaterThanOrEqual(rect.minY, -1)
        XCTAssertLessThanOrEqual(rect.maxY, root.bounds.height + 1)
    }
}

@MainActor
private final class HiringLayoutWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private actor HiringLayoutService: HiringConversationServing {
    let snapshot: HiringConversationSnapshot
    private var loads = 0
    private var mutations = 0
    init(snapshot: HiringConversationSnapshot) { self.snapshot = snapshot }
    func loadOrStart() async throws -> HiringConversationSnapshot { loads += 1; return snapshot }
    func submit(text: String) async throws -> HiringConversationSnapshot { mutations += 1; return snapshot }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot { mutations += 1; return snapshot }
    func cancel() async throws { mutations += 1 }
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot {
        mutations += 1
        throw CocoaError(.featureUnsupported)
    }
    func calls() -> (loads: Int, mutations: Int) { (loads, mutations) }
}

@MainActor
private func settleHiringLayout(_ host: NSView) async throws {
    for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func hiringLayoutEditor(in root: NSView, text: String) -> NSView? {
    root.hiringLayoutDescendants.first {
        if let field = $0 as? NSTextField { return field.isEditable && field.stringValue == text }
        if let editor = $0 as? NSTextView { return editor.isEditable && editor.string == text }
        return false
    }
}

private extension NSView {
    var hiringLayoutDescendants: [NSView] { [self] + subviews.flatMap(\.hiringLayoutDescendants) }
}

private func hiringLayoutID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "AA930000-0000-0000-0000-%012llx", suffix))!
}

private func hiringLayoutLog(_ text: String) {
    FileHandle.standardError.write(Data(("[hiring-layout-test] \(text)\n").utf8))
}

private func hiringLayoutEvidenceDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build.noindex/candidate-review-evidence-20260830", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
}

@MainActor
private func captureHiringLayout(_ host: NSView, name: String) throws {
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 1_000, "An empty bitmap is not render evidence")
    try data.write(to: hiringLayoutEvidenceDirectory().appendingPathComponent(name), options: .atomic)
}

private final class HiringLayoutChildLog: @unchecked Sendable {
    private let reader: FileHandle
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var tail = Data()
    init(reader: FileHandle) { self.reader = reader }
    func start() {
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            while let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                lock.withLock {
                    tail.append(bytes)
                    if tail.count > 131_072 { tail.removeFirst(tail.count - 131_072) }
                }
            }
        }
    }
    func finish() -> String {
        _ = done.wait(timeout: .now() + 1)
        return lock.withLock { String(decoding: tail, as: UTF8.self) }
    }
}
