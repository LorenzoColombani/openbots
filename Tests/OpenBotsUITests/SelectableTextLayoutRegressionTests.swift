import AppKit
import Darwin
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Field-editor lifetime is confined to a child XCTest process. The shared
/// suite never owns a window/editor and a layout loop has a hard deadline.
@MainActor
final class SelectableTextLayoutRegressionTests: XCTestCase {
    private static let childFlag = "OPENBOTS_SELECTABLE_LAYOUT_CHILD"
    private static let receipt = "OPENBOTS_SELECTABLE_LAYOUT_CHILD_COMPLETED"

    func testIdealAlignmentWidthPreservesSingleLineMeasurementHeight() throws {
        let field = NSTextField(wrappingLabelWithString: "Local demo message is sent.")
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        let ideal = field.intrinsicContentSize
        let measured = StableSelectableText.measuredSize(proposedWidth: ideal.width, field: field)
        XCTAssertEqual(measured.width, ideal.width, accuracy: 0.5)
        XCTAssertEqual(
            measured.height, ceil(ideal.height), accuracy: 0.5,
            "Intrinsic alignment size \(ideal); remeasured at its exact ideal width \(measured); insets \(field.alignmentRectInsets)."
        )
        let withoutProposal = StableSelectableText.measuredSize(proposedWidth: nil, field: field)
        XCTAssertEqual(withoutProposal.width, ideal.width, accuracy: 0.5)
        XCTAssertEqual(withoutProposal.height, ideal.height, accuracy: 0.5)
    }

    func testMeasurementNormalizesUnboundedProposalsWithoutMutatingLiveField() {
        let field = NSTextField(wrappingLabelWithString: SelectableLayoutFixture.expandedOutput)
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.isEditable = false
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.frame = NSRect(x: 11, y: 13, width: 244, height: 80)
        let originalFrame = field.frame
        let originalBounds = field.bounds
        let originalFont = field.font
        let originalText = field.stringValue
        let ideal = field.intrinsicContentSize
        for width: CGFloat? in [nil, 0, -1, .infinity, .nan] {
            let measured = StableSelectableText.measuredSize(proposedWidth: width, field: field)
            XCTAssertEqual(measured, ideal)
            XCTAssertTrue(measured.width.isFinite && measured.height.isFinite)
        }
        let narrow = StableSelectableText.measuredSize(proposedWidth: 180, field: field)
        let wide = StableSelectableText.measuredSize(proposedWidth: 620, field: field)
        XCTAssertEqual(narrow.width, 180)
        XCTAssertEqual(wide.width, 620)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertGreaterThan(wide.height, 0)
        for _ in 0..<10 {
            XCTAssertEqual(StableSelectableText.measuredSize(proposedWidth: 180, field: field), narrow)
            XCTAssertEqual(StableSelectableText.measuredSize(proposedWidth: 620, field: field), wide)
        }
        XCTAssertEqual(field.frame, originalFrame)
        XCTAssertEqual(field.bounds, originalBounds)
        XCTAssertEqual(field.stringValue, originalText)
        XCTAssertEqual(field.font, originalFont)
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isEditable)
    }

    func testRenderedFocusSelectionAndDynamicTextHaveBoundedLayout() throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try exerciseSelectableTextLayout()
            print(Self.receipt)
            return
        }

        try runBoundedChild(testMethod: "testRenderedFocusSelectionAndDynamicTextHaveBoundedLayout")
    }

    func testActualLazyTranscriptSendStreamAndCardUpdatesHaveBoundedLayout() throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try exerciseActualLazyTranscript()
            print(Self.receipt)
            return
        }
        try runBoundedChild(testMethod: "testActualLazyTranscriptSendStreamAndCardUpdatesHaveBoundedLayout")
    }

    private func runBoundedChild(testMethod: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "OpenBotsUITests.SelectableTextLayoutRegressionTests/\(testMethod)",
            Bundle(for: Self.self).bundleURL.path
        ]
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment[Self.childFlag] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try output.fileHandleForWriting.close()
        let childLog = SelectableChildLog(reader: output.fileHandleForReading)
        childLog.start()

        let deadline = Date(timeIntervalSinceNow: 15)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date(timeIntervalSinceNow: 1)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                // This is only the exact child launched above, never Preview
                // or another process discovered on the user's Mac.
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let log = childLog.finish()
        XCTAssertFalse(timedOut, "Rendered layout exceeded its 15-second deadline. \(log)")
        XCTAssertEqual(process.terminationStatus, 0, log)
        XCTAssertTrue(log.contains(Self.receipt), "The child did not finish all layout/focus assertions. \(log)")
    }
}

/// Drain concurrently so diagnostic output cannot fill the pipe and resemble
/// an AppKit hang. Retain only a bounded tail for a failed-test receipt.
private final class SelectableChildLog: @unchecked Sendable {
    private let reader: FileHandle
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var tail = Data()

    init(reader: FileHandle) { self.reader = reader }

    func start() {
        Thread.detachNewThread { [self] in
            defer { completed.signal() }
            while let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                lock.withLock {
                    tail.append(bytes)
                    if tail.count > 131_072 { tail.removeFirst(tail.count - 131_072) }
                }
            }
        }
    }

    func finish() -> String {
        _ = completed.wait(timeout: .now() + 1)
        return lock.withLock { String(decoding: tail, as: UTF8.self) }
    }
}

@MainActor
private func exerciseActualLazyTranscript() throws {
    let fixture = try LazyTranscriptLayoutFixture()
    let host = SelectableLayoutCountingHost(rootView: OpenBotsRootView(
        sidebar: fixture.sidebar,
        conversation: fixture.conversation,
        cardInteractions: fixture.interactions,
        createTeammate: {},
        openSettings: {}
    ))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }
    host.frame = NSRect(x: 0, y: 0, width: 1_080, height: 720)
    try settleSelectableHost(host, phase: "100-message lazy transcript initial render")
    XCTAssertEqual(fixture.conversation.messageRows.count, 100)
    let renderedLabels = host.selectableLayoutDescendants.compactMap { $0 as? NSTextField }
        .filter { !$0.isEditable && $0.isSelectable }
    XCTAssertFalse(renderedLabels.isEmpty, "The real root must render selectable transcript/card content")

    if let transcript = renderedLabels.first(where: { $0.enclosingScrollView != nil })?.enclosingScrollView,
       let document = transcript.documentView {
        let bottom = max(0, document.bounds.height - transcript.contentView.bounds.height)
        transcript.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
        transcript.reflectScrolledClipView(transcript.contentView)
    }
    try settleSelectableHost(host, phase: "lazy transcript bottom viewport")

    let firstRow = fixture.conversation.messageRows[0]
    let cardRow = fixture.conversation.messageRows[98]
    fixture.conversation.composerText = "Local lazy-layout regression message — no runtime."
    try settleSelectableHost(host, phase: "composer draft before send")
    let sentID = lazyLayoutUUID(500)
    fixture.conversation.sendCurrentText(now: Date(timeIntervalSince1970: 500), messageID: sentID)
    XCTAssertEqual(fixture.conversation.messageRows.count, 101)
    XCTAssertEqual(fixture.conversation.messageRows.last?.snapshot.delivery, .pending)
    XCTAssertEqual(fixture.conversation.composerText, "")
    try settleSelectableHost(host, phase: "pending send appended to real lazy transcript")

    fixture.conversation.replaceMessage(ChatMessageSnapshot(
        id: sentID, author: .user,
        body: "Local lazy-layout regression message — no runtime.",
        delivery: .sent, timestamp: Date(timeIntervalSince1970: 500)
    ))
    try settleSelectableHost(host, phase: "pending send changed to sent")
    let replyID = lazyLayoutUUID(501)
    let reply = fixture.conversation.beginStreamingMessage(ChatMessageSnapshot(
        id: replyID, author: .system(label: "Local layout fixture"),
        body: "", delivery: .pending, timestamp: Date(timeIntervalSince1970: 501)
    ))
    var expectedReply = ""
    for index in 0..<12 {
        let delta = "\nFixture streaming paragraph \(index): a completed local reply expands the transcript without a runtime. "
        expectedReply += delta
        XCTAssertTrue(fixture.conversation.appendStreamingDelta(messageID: replyID, delta: delta))
        try settleSelectableHost(host, phase: "row-local streamed growth \(index)")
    }
    XCTAssertTrue(fixture.conversation.completeStreamingMessage(id: replyID))
    try settleSelectableHost(host, phase: "stream completion")
    XCTAssertEqual(reply.snapshot.body, expectedReply)
    XCTAssertEqual(reply.snapshot.delivery, .sent)
    XCTAssertTrue(fixture.conversation.messageRows[0] === firstRow)
    XCTAssertTrue(fixture.conversation.messageRows[98] === cardRow)

    fixture.question.freeText = "A working local prototype"
    fixture.question.answerFreeText()
    try settleSelectableHost(host, phase: "inline question submission")
    fixture.replaceHandoffWithRecovery()
    try settleSelectableHost(host, phase: "handoff recovery row update")
    for width in [CGFloat(960), CGFloat(1_080)] {
        host.frame.size.width = width
        try settleSelectableHost(host, phase: "actual lazy transcript resize \(width)")
    }
    XCTAssertEqual(fixture.conversation.messageRows.count, 102)
    XCTAssertTrue(fixture.conversation.messageRows.last === reply)
    XCTAssertEqual(fixture.conversation.composerText, "")
    XCTAssertEqual(fixture.secret.transientInput, "")
}

@MainActor
private final class LazyTranscriptLayoutFixture {
    let conversationID = lazyLayoutUUID(1_000)
    let sidebar: SidebarModel
    let conversation: ConversationModel
    let interactions: ConversationCardInteractionModel
    let question: QuestionCardInteractionModel
    let secret: SecretCardInteractionModel
    private let handoffMessageID = lazyLayoutUUID(100)
    private let handoffPartID = lazyLayoutUUID(4_004)
    private let recoveryHandoff: ChatHandoffTrailSnapshot

    init() throws {
        let teammate = TeammateRowSnapshot(
            id: lazyLayoutUUID(1_001), name: "Ada Layout", role: "Local review fixture", activity: .idle, identitySeed: 44
        )
        sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
        interactions = ConversationCardInteractionModel(conversationID: conversationID)
        let cardMessageID = lazyLayoutUUID(99)
        let questionPartID = lazyLayoutUUID(4_001)
        let secretPartID = lazyLayoutUUID(4_002)
        let connectorPartID = lazyLayoutUUID(4_003)
        let questionSnapshot = ChatQuestionCardSnapshot(
            id: lazyLayoutUUID(2_001), prompt: "Which local fixture should I prepare?",
            choices: [ChatQuestionChoiceSnapshot(id: lazyLayoutUUID(2_011), title: "A working prototype")],
            allowsFreeText: true
        )
        question = QuestionCardInteractionModel(
            route: ConversationCardInteractionRoute(
                conversationID: conversationID, messageID: cardMessageID,
                messagePartID: questionPartID, cardID: questionSnapshot.id, actionRouteID: lazyLayoutUUID(3_001)
            ), snapshot: questionSnapshot,
            submit: { route, attemptID, _ in
                ConversationCardActionResult(route: route, attemptID: attemptID, outcome: .succeeded(receiptID: nil))
            }
        )
        let secretSnapshot = ChatSecretCardSnapshot(
            id: lazyLayoutUUID(2_002), label: "Local test secret", purpose: "No credentials or Keychain", presence: .absent
        )
        secret = SecretCardInteractionModel(
            route: ConversationCardInteractionRoute(
                conversationID: conversationID, messageID: cardMessageID,
                messagePartID: secretPartID, cardID: secretSnapshot.id, actionRouteID: lazyLayoutUUID(3_002)
            ), snapshot: secretSnapshot,
            submit: { route, attemptID, _ in
                ConversationCardActionResult(route: route, attemptID: attemptID, outcome: .succeeded(receiptID: nil))
            }
        )
        XCTAssertTrue(interactions.register(question))
        XCTAssertTrue(interactions.register(secret))
        let connector = ChatConnectorSetupCardSnapshot(
            id: lazyLayoutUUID(2_003), connectorName: "Fixture connector", installation: .installed,
            authentication: .notAuthenticated, botGrant: .notGranted, actionApproval: .notRequested
        )
        let collaboration = try CollaborationReviewFixtureService()
        let handoff = try CollaborationReviewPresentation(collaboration.snapshot(variant: .successfulFanIn)).handoff
        recoveryHandoff = try CollaborationReviewPresentation(collaboration.snapshot(variant: .needsRecovery)).handoff
        var messages = (1...98).map { index in
            ChatMessageSnapshot(
                id: lazyLayoutUUID(UInt64(index)),
                author: index.isMultiple(of: 2) ? .user : .system(label: "Local layout fixture"),
                body: "Lazy transcript fixture message \(index). "
                    + String(repeating: "Readable multiline local content. ", count: index % 5 + 1),
                delivery: .sent, timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        messages.append(ChatMessageSnapshot(
            id: cardMessageID, author: .system(label: "Local layout fixture"), parts: [
                ChatMessagePartSnapshot(id: lazyLayoutUUID(4_000), ordinal: 0, content: .text("Local interactive fixture cards")),
                ChatMessagePartSnapshot(id: questionPartID, ordinal: 1, content: .question(questionSnapshot)),
                ChatMessagePartSnapshot(id: secretPartID, ordinal: 2, content: .secret(secretSnapshot)),
                ChatMessagePartSnapshot(id: connectorPartID, ordinal: 3, content: .connectorSetup(connector))
            ], delivery: .sent, timestamp: Date(timeIntervalSince1970: 99)
        ))
        messages.append(ChatMessageSnapshot(
            id: handoffMessageID, author: .system(label: "Local layout fixture"), parts: [
                ChatMessagePartSnapshot(id: handoffPartID, ordinal: 0, content: .handoff(handoff))
            ], delivery: .sent, timestamp: Date(timeIntervalSince1970: 100)
        ))
        conversation = ConversationModel(
            conversationID: conversationID, title: "Ada Layout", messages: messages,
            readyDeliveryDescription: "Bounded rendered layout fixture; no runtime or repository.",
            inputAvailability: .ready, submit: { _, _, _ in }
        )
    }

    func replaceHandoffWithRecovery() {
        conversation.replaceMessage(ChatMessageSnapshot(
            id: handoffMessageID, author: .system(label: "Local layout fixture"), parts: [
                ChatMessagePartSnapshot(id: handoffPartID, ordinal: 0, content: .handoff(recoveryHandoff))
            ], delivery: .sent, timestamp: Date(timeIntervalSince1970: 100)
        ))
    }
}

private func lazyLayoutUUID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "B4F00000-0000-0000-0000-%012llx", suffix))!
}

@MainActor
private func exerciseSelectableTextLayout() throws {
    let fixture = SelectableLayoutFixture()
    let host = SelectableLayoutCountingHost(rootView: SelectableLayoutHarness(fixture: fixture))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 900),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    // This is an offscreen rendered window, not a desktop-control route.
    // It is deliberately never ordered front or made key.
    defer {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }
    host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
    try settleSelectableHost(host, phase: "initial render")
    let secret = try XCTUnwrap(host.selectableLayoutDescendants.compactMap { $0 as? NSSecureTextField }.first)
    let composer = try XCTUnwrap(host.selectableLayoutDescendants.first { view in
        if let field = view as? NSTextField {
            return !(field is NSSecureTextField) && field.isEditable && field.stringValue == fixture.composer
        }
        if let text = view as? NSTextView {
            return text.isEditable && text.string == fixture.composer
        }
        return false
    })
    let selectable = try findSelectableField(in: host, text: fixture.output)
    assertSelectableContract(selectable, expected: fixture.output)

    // Use a deterministic native key-view loop around the same rendered
    // SwiftUI composer/secure field and real selectable representable. This
    // exercises Tab/Shift-Tab AppKit commands, not packaged-app focus policy.
    window.autorecalculatesKeyViewLoop = false
    composer.nextKeyView = secret
    secret.nextKeyView = selectable
    selectable.nextKeyView = composer
    XCTAssertTrue(window.makeFirstResponder(composer))
    try settleSelectableHost(host, phase: "composer focus")
    XCTAssertTrue(isFocused(composer, in: window))
    window.selectKeyView(following: composer)
    try settleSelectableHost(host, phase: "Tab composer to secret")
    XCTAssertTrue(isFocused(secret, in: window), focusDescription(window, expected: secret))
    let forwardTarget = try XCTUnwrap(secret.nextValidKeyView)
    // macOS may omit noneditable labels from Tab traversal under its current
    // keyboard policy. Assert the resolved native target, then select output
    // explicitly; do not claim this offscreen test proves FKA/VoiceOver reach.
    XCTAssertTrue(forwardTarget === selectable || forwardTarget === composer)
    window.selectKeyView(following: secret)
    try settleSelectableHost(host, phase: "Tab secret to next eligible control")
    XCTAssertTrue(isFocused(forwardTarget, in: window), focusDescription(window, expected: forwardTarget))
    selectable.selectText(nil)
    let editor = try XCTUnwrap(selectable.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 0, length: min(24, fixture.output.utf16.count)))
    XCTAssertEqual(editor.selectedRange().length, min(24, fixture.output.utf16.count))
    try settleSelectableHost(host, phase: "selected output")

    let stableIdentity = ObjectIdentifier(selectable)
    fixture.output = SelectableLayoutFixture.expandedOutput
    try settleSelectableHost(host, phase: "dynamic message while selected")
    let updated = try findSelectableField(in: host, text: fixture.output)
    XCTAssertEqual(ObjectIdentifier(updated), stableIdentity, "A content update must retain the native text control")
    assertSelectableContract(updated, expected: fixture.output)

    window.selectKeyView(preceding: selectable)
    try settleSelectableHost(host, phase: "Shift-Tab output to secret")
    XCTAssertTrue(isFocused(secret, in: window), focusDescription(window, expected: secret))
    window.selectKeyView(preceding: secret)
    try settleSelectableHost(host, phase: "Shift-Tab secret to composer")
    XCTAssertTrue(isFocused(composer, in: window), focusDescription(window, expected: composer))

    host.frame.size.width = 270
    try settleSelectableHost(host, phase: "narrow wrapping")
    let narrow = try findSelectableField(in: host, text: fixture.output).frame.height
    host.frame.size.width = 620
    try settleSelectableHost(host, phase: "wide wrapping")
    let wide = try findSelectableField(in: host, text: fixture.output).frame.height
    XCTAssertTrue(narrow.isFinite && wide.isFinite)
    XCTAssertGreaterThan(narrow, wide, "The same multiline output must wrap taller at the narrow width")
    XCTAssertGreaterThan(wide, 0)
    let unchangedHeight = updated.frame.height
    for index in 0..<6 {
        fixture.unrelatedRevision += 1
        try settleSelectableHost(host, phase: "unchanged text update \(index)")
        XCTAssertEqual(updated.frame.height, unchangedHeight, accuracy: 0.5)
        assertSelectableContract(updated, expected: fixture.output)
    }
    XCTAssertEqual(fixture.composer, SelectableLayoutFixture.initialComposer)
    XCTAssertEqual(fixture.secret, "")
}

@MainActor
private final class SelectableLayoutFixture: ObservableObject {
    static let initialComposer = "Local layout test draft"
    static let initialOutput = "Selectable output keeps its text and selection across focus changes. "
        + "It wraps into multiple lines at the narrow inspector width.\nThis second paragraph remains readable."
    static let expandedOutput = initialOutput + "\nA completed local fixture reply is appended during selection. "
        + "Additional verified text makes the narrow and wide measurements distinct without any live runtime."
    @Published var output = initialOutput
    @Published var composer = initialComposer
    @Published var secret = ""
    @Published var unrelatedRevision = 0
}

private struct SelectableLayoutHarness: View {
    @ObservedObject var fixture: SelectableLayoutFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Fixture secret", text: $fixture.secret)
                .textFieldStyle(.roundedBorder)
            StableSelectableText(fixture.output)
            TextField("Message", text: $fixture.composer, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
            Text("Unrelated fixture revision \(fixture.unrelatedRevision)")
                .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private final class SelectableLayoutCountingHost<Content: View>: NSHostingView<Content> {
    private(set) var constraintPasses = 0
    private(set) var layoutPasses = 0
    override func updateConstraints() {
        constraintPasses += 1
        super.updateConstraints()
    }
    override func layout() {
        layoutPasses += 1
        super.layout()
    }
    func resetPasses() {
        constraintPasses = 0
        layoutPasses = 0
    }
}

@MainActor
private func settleSelectableHost<Content: View>(
    _ host: SelectableLayoutCountingHost<Content>, phase: String
) throws {
    host.resetPasses()
    var sentinelCompleted = false
    DispatchQueue.main.async { sentinelCompleted = true }
    for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.003))
    }
    XCTAssertTrue(sentinelCompleted, "Main-queue sentinel did not complete: \(phase)")
    XCTAssertLessThan(host.constraintPasses, 40, "Unbounded constraints: \(phase)")
    XCTAssertLessThan(host.layoutPasses, 40, "Unbounded layout: \(phase)")
    XCTAssertTrue(host.fittingSize.height.isFinite, "Non-finite host height: \(phase)")
}

@MainActor
private func findSelectableField(in host: NSView, text: String) throws -> NSTextField {
    try XCTUnwrap(host.selectableLayoutDescendants.compactMap { $0 as? NSTextField }.first {
        $0.isSelectable && !$0.isEditable && $0.stringValue == text
    })
}

@MainActor
private func assertSelectableContract(_ field: NSTextField, expected: String) {
    XCTAssertTrue(field.isSelectable)
    XCTAssertFalse(field.isEditable)
    XCTAssertFalse(field.usesSingleLineMode)
    XCTAssertEqual(field.maximumNumberOfLines, 0)
    XCTAssertEqual(field.lineBreakMode, .byWordWrapping)
    XCTAssertEqual(field.stringValue, expected)
    XCTAssertEqual(field.accessibilityValue(), expected)
}

@MainActor
private func isFocused(_ view: NSView, in window: NSWindow) -> Bool {
    if window.firstResponder === view { return true }
    if let field = view as? NSTextField, let editor = field.currentEditor() {
        return window.firstResponder === editor
    }
    return false
}

@MainActor
private func focusDescription(_ window: NSWindow, expected: NSView) -> String {
    let actual = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    return "Expected \(type(of: expected)); actual responder \(actual)."
}

private extension NSView {
    var selectableLayoutDescendants: [NSView] { subviews + subviews.flatMap(\.selectableLayoutDescendants) }
}
