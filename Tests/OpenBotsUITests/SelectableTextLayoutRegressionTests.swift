import AppKit
import Darwin
import OpenBotsDomain
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

    /// The mechanism behind the transcript freezes: AppKit's intrinsic width for a
    /// line with a 200-character token was 5,594 pt regardless of the frame, and its
    /// intrinsic height followed the previous frame, so intrinsic and measured sizes
    /// never agreed after the transcript column changed width.
    func testIntrinsicSizeFollowsTheFrameWidthForUnbreakableTokens() {
        let field = StableSelectableText.makeField(longTokenReportBody)
        field.font = NSFont.preferredFont(forTextStyle: .body)
        for width: CGFloat in [420, 500.5, 640, 420] {
            let measured = StableSelectableText.measuredSize(proposedWidth: width, field: field)
            field.setFrameSize(NSSize(width: width, height: measured.height))
            let intrinsic = field.intrinsicContentSize
            XCTAssertLessThanOrEqual(intrinsic.width, width + 0.5, "intrinsic width must not exceed the frame at \(width): \(intrinsic)")
            XCTAssertEqual(intrinsic.height, measured.height, accuracy: 1, "intrinsic height must match the measured wrap at \(width): \(intrinsic) vs \(measured)")
        }
        let short = StableSelectableText.makeField("Local demo message is sent.")
        short.font = NSFont.preferredFont(forTextStyle: .body)
        let natural = short.intrinsicContentSize
        short.setFrameSize(NSSize(width: 420, height: natural.height))
        XCTAssertEqual(short.intrinsicContentSize.height, natural.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(short.intrinsicContentSize.width, 420.5)
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

    /// The installed app once froze twice (main thread at 100 %, window gone)
    /// with a transcript message whose lines hold ~200-character unbreakable tokens,
    /// as soon as the transcript column changed width (details pane opened).
    func testLongUnbreakableTokensSettleAcrossColumnWidthChanges() throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try exerciseLongTokenTranscriptResize()
            print(Self.receipt)
            return
        }
        try runBoundedChild(testMethod: "testLongUnbreakableTokensSettleAcrossColumnWidthChanges")
    }

    /// The installed app once hung (main thread at 100 %, memory
    /// climbing) as soon as the details pane opened over a bot's ordinary
    /// conversation: short user lines, formatted replies and status parts, no long
    /// tokens. Both samples show the transcript's lazy stack re-measuring the
    /// native labels without end. Same message shape here, synthetic words.
    func testOrdinaryConversationSurvivesDetailsPaneOpening() throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try exerciseOrdinaryConversationDetailsToggle()
            print(Self.receipt)
            return
        }
        try runBoundedChild(testMethod: "testOrdinaryConversationSurvivesDetailsPaneOpening")
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

/// A worker report (sandbox refusals), public-safe:
/// error codes and system paths only, no account or machine-specific values.
private let longTokenReportBody: String = {
    let tls = "step 1 exit=1 out= err=Auto configuration failed 8528781696:error:02FFF001:system library:func(4095):"
        + "Operation not permitted:/AppleInternal/Library/BuildRoots/4~CVR0ugD7d_x9KkNiDhb6ZUdowAfhsgliSKtR7QU/Library/Caches/"
        + "com.apple.xbs/TemporaryDirectory.kapob0/Sources/libressl/libressl-3.3/crypto/bio/bss_file.c:122:fopen('/private/etc/ssl/openssl.cnf', 'rb') "
        + "8528781696:error:20FFF002:BIO routines:CRYPTO_internal:system lib:/AppleInternal/Library/BuildRoots/4~CVR0ugD7d_x9KkNiDhb6ZUdowAfhsgliSKtR7QU/Library/Caches/"
        + "com.apple.xbs/TemporaryDirectory.kapob0/Sources/libressl/libressl-3.3/crypto/bio/bss_file.c:127: 8528781696:error:0EFFF002:configuration file routines:CRYPTO_internal:system lib"
    let shim = "step 2 exit=1 out= err=xcode-select: error: unable to read data link at '/var/select/developer_dir', expected symbolic link (Operation not permitted)"
    return [tls, shim, shim.replacingOccurrences(of: "step 2", with: "step 3"),
            "step 4 exit=1 out= err=cat: /private/tmp/OpenBotsJob-canary-sibling.noindex/secret.txt: Operation not permitted",
            "step 5 exit=1 out= err=touch: /private/tmp/OpenBotsJob-canary-sibling.noindex/written.txt: Operation not permitted",
            "step 6 exit=1 out= err=touch: /private/tmp/canary-parent.txt: Operation not permitted",
            "step 7 exit=1 out= err=ls: /private/tmp: Operation not permitted"].joined(separator: "\n")
}()

@MainActor
private func exerciseLongTokenTranscriptResize() throws {
    let fixture = LongTokenLayoutFixture()
    let host = SelectableLayoutCountingHost(rootView: LongTokenLayoutHarness(fixture: fixture))
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
    try settleSelectableHost(host, phase: "long-token transcript initial render")
    let rendered = try findSelectableFieldContaining(in: host, token: "bss_file.c:122")
    XCTAssertTrue(rendered.frame.height.isFinite && rendered.frame.height > 0)
    // Width changes like the details pane opening/closing and window resizes.
    for (step, width) in [CGFloat(960), CGFloat(763), CGFloat(900), CGFloat(1_080), CGFloat(700), CGFloat(1_080)].enumerated() {
        if step.isMultiple(of: 2) { fixture.detailsOpen.toggle() } else { host.frame.size.width = width }
        try settleSelectableHost(host, phase: "long-token transcript step \(step) width \(width) details \(fixture.detailsOpen)")
        let field = try findSelectableFieldContaining(in: host, token: "bss_file.c:122")
        XCTAssertTrue(field.frame.width.isFinite && field.frame.width <= host.frame.width, "field wider than the window at step \(step): \(field.frame)")
        XCTAssertTrue(field.frame.height.isFinite && field.frame.height > 0 && field.frame.height < 4_000, "runaway height at step \(step): \(field.frame)")
    }
}

@MainActor
private final class LongTokenLayoutFixture: ObservableObject {
    @Published var detailsOpen = false
}

/// Sidebar + scrolling transcript + optional details pane, like the app's window:
/// the transcript column narrows when the pane opens.
private struct LongTokenLayoutHarness: View {
    @ObservedObject var fixture: LongTokenLayoutFixture

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 260)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<6, id: \.self) { index in
                        StableSelectableText("Ordinary transcript row \(index) with readable local content that wraps.")
                    }
                    StableSelectableText(longTokenReportBody)
                    StableSelectableText("Network containment check. " + longTokenReportBody, style: .callout, tone: .secondary)
                    ForEach(6..<10, id: \.self) { index in
                        StableSelectableText("Ordinary transcript row \(index).")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if fixture.detailsOpen {
                Divider()
                VStack { Text("Details"); Spacer() }.frame(width: 300)
            }
        }
    }
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
private func findSelectableFieldContaining(in host: NSView, token: String) throws -> NSTextField {
    try XCTUnwrap(host.selectableLayoutDescendants.compactMap { $0 as? NSTextField }.first {
        $0.isSelectable && !$0.isEditable && $0.stringValue.contains(token)
    }, "no selectable field containing \(token); fields: \(host.selectableLayoutDescendants.compactMap { ($0 as? NSTextField)?.stringValue.prefix(40) })")
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

@MainActor
private func exerciseOrdinaryConversationDetailsToggle() throws {
    // This exercise counts `label.update` to prove the update storm is gone.
    // The counters are off in the shipped app, and this
    // runs in a child process that inherits five named variables, so the switch
    // has to be thrown here or the assertion would compare zero against zero.
    let countersWereEnabled = LayoutStormCounters.isEnabled
    LayoutStormCounters.isEnabled = true
    defer { LayoutStormCounters.isEnabled = countersWereEnabled }
    let fixture = try OrdinaryConversationLayoutFixture()
    let host = SelectableLayoutCountingHost(rootView: OrdinaryConversationHarness(fixture: fixture))
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
    try settleSelectableHost(host, phase: "first conversation render")
    // Like clicking another bot in the sidebar: the rows are replaced in place.
    fixture.showSecondConversation()
    try settleSelectableHost(host, phase: "second conversation shown")
    XCTAssertEqual(fixture.conversation.messageRows.count, 16)
    // Opening a conversation shows its latest message: the viewport sits at the
    // bottom and every row above is only an estimate until it scrolls into view.
    let transcript = try XCTUnwrap(host.selectableLayoutDescendants.compactMap { $0 as? NSTextField }
        .first(where: { $0.enclosingScrollView != nil })?.enclosingScrollView, "transcript scroll view")
    let document = try XCTUnwrap(transcript.documentView)
    transcript.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - transcript.contentView.bounds.height) : 0))
    transcript.reflectScrolledClipView(transcript.contentView)
    try settleSelectableHost(host, phase: "second conversation scrolled to its latest message")
    try pumpMainRunLoop(for: 0.4, phase: "opening animations")
    // The real details pane opens over that conversation (the app-wide job switch
    // was already on), then its bot switches are turned on one by one, and the
    // workspace mirrors each change into the conversation's status caption.
    XCTAssertLessThanOrEqual(distanceFromEnd(of: transcript), 1, "the fixture must start at the end of the transcript")
    fixture.detailsOpen = true
    try settleSelectableHost(host, phase: "real details pane opened")
    try pumpMainRunLoop(for: 0.4, phase: "pane animation")
    try settleSelectableHost(host, phase: "real details pane after animation")
    // The rows re-wrapped and the content grew; a reader who was at the end is
    // still at the end. Before `.defaultScrollAnchor(.bottom)` the viewport was
    // left mid-transcript here, and the installed app never finished the
    // transaction at all (in Canobi's conversation).
    XCTAssertLessThanOrEqual(distanceFromEnd(of: transcript), 1,
        "a reader at the end must stay at the end when the details pane narrows the transcript: document \(document.bounds.height) visible \(transcript.documentVisibleRect)")
    // The live hang was a SwiftUI update storm: the labels' updateNSView ran
    // dozens of times a second with no AppKit layout at all, so pass counts
    // stayed low. Count the label updates themselves over a quiet half second.
    let updatesBefore = LayoutStormCounters.lifetime["label.update", default: 0]
    // The bound below is an upper bound, so it would pass on a counter that
    // never runs. Prove the switch above actually reached the labels first.
    XCTAssertGreaterThan(updatesBefore, 0, "the label counters are not recording; the assertion below would be vacuous")
    try pumpMainRunLoop(for: 0.5, phase: "quiet period with details open")
    let updatesDuringQuiet = LayoutStormCounters.lifetime["label.update", default: 0] - updatesBefore
    XCTAssertLessThan(updatesDuringQuiet, 40, "label updates kept running with the details pane open and nothing changing: \(updatesDuringQuiet) in 0.5 s")
    // With a mouse attached macOS shows legacy scroll bars, which take width. If
    // the content height sits near the viewport height, the bar appears, the
    // rows re-wrap wider, the bar disappears, and so on. Sweep window heights
    // over the whole plausible range with the bar style forced to legacy.
    transcript.scrollerStyle = .legacy
    let styleNote = "scroller=legacy autohides=\(transcript.autohidesScrollers) preferred=\(NSScroller.preferredScrollerStyle.rawValue)"
    print("[repro] \(styleNote) documentHeight=\(document.bounds.height) viewport=\(transcript.contentView.bounds.height)")
    for height in stride(from: CGFloat(560), through: 920, by: 6) {
        host.frame.size.height = height
        try settleSelectableHost(host, phase: "details open, window height \(height), \(styleNote)")
    }
    host.frame.size.height = 720
    try settleSelectableHost(host, phase: "details open, window height back to 720")
    try pumpMainRunLoop(until: { fixture.access.isReady && fixture.access.teammateID == fixture.teammate.id }, phase: "details pane selected its bot")
    try settleSelectableHost(host, phase: "details pane settled after selection")
    let bot = fixture.teammate.id
    // The jobs switch has no control on screen any more; the
    // store still carries it, and the conversation still learns it is on.
    let store = fixture.store
    Task { await store.setBotEnabled(true, teammateID: bot) }
    try pumpMainRunLoop(until: { fixture.access.isEnabled }, phase: "jobs switch on for the bot")
    fixture.mirrorAccessIntoConversation()
    try settleSelectableHost(host, phase: "jobs switch mirrored into the conversation")
    Task { await fixture.access.setWebBotEnabled(true, capability: .search, teammateID: bot) }
    try pumpMainRunLoop(until: { fixture.access.webBotEnabled(.search) }, phase: "web search grant on")
    fixture.mirrorAccessIntoConversation()
    try settleSelectableHost(host, phase: "web search grant reflected")
    Task { await fixture.access.setWebAppEnabled(true, capability: .search) }
    try pumpMainRunLoop(until: { fixture.access.webIsEnabled(.search) }, phase: "web search effective")
    fixture.mirrorAccessIntoConversation()
    try settleSelectableHost(host, phase: "web search effective reflected")
    for (step, open) in [false, true].enumerated() {
        fixture.detailsOpen = open
        try settleSelectableHost(host, phase: "details \(open ? "open" : "closed") step \(step)")
    }
    for width in [CGFloat(900), CGFloat(1_080)] {
        host.frame.size.width = width
        try settleSelectableHost(host, phase: "window width \(width) with details open")
    }
}

/// How far the viewport's end sits from the end of the transcript, in points.
@MainActor
private func distanceFromEnd(of scrollView: NSScrollView) -> CGFloat {
    guard let document = scrollView.documentView else { return .infinity }
    let visible = scrollView.documentVisibleRect
    return document.isFlipped ? max(0, document.bounds.maxY - visible.maxY) : max(0, visible.minY - document.bounds.minY)
}

/// Runs the main run loop for a fixed time so scroll and pane animations end.
@MainActor
private func pumpMainRunLoop(for seconds: TimeInterval, phase: String) throws {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
}

/// Lets main-actor continuations (the access store's actor hops) land, bounded.
@MainActor
private func pumpMainRunLoop(until condition: @MainActor () -> Bool, phase: String) throws {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    XCTAssertTrue(condition(), "Condition not reached: \(phase)")
}

@MainActor
private final class OrdinaryConversationLayoutFixture: ObservableObject {
    @Published var detailsOpen = false
    let sidebar: SidebarModel
    let conversation: ConversationModel
    let store = AgenticJobAccessStore()
    let access: AgenticJobAccessModel
    let teammate: Teammate
    private let first: TeammateRowSnapshot
    private let second: TeammateRowSnapshot

    init() throws {
        first = TeammateRowSnapshot(id: ordinaryLayoutUUID(1), name: "First Layout Bot", role: "Local fixture", activity: .idle, identitySeed: 11)
        second = TeammateRowSnapshot(id: ordinaryLayoutUUID(2), name: "Second Layout Bot", role: "Local fixture", activity: .idle, identitySeed: 12)
        sidebar = SidebarModel(rows: [first, second], selection: first.id)
        conversation = ConversationModel(
            conversationID: ordinaryLayoutUUID(100), title: first.name, messages: Self.firstMessages(first),
            readyDeliveryDescription: "Bounded rendered layout fixture; no runtime or repository.",
            inputAvailability: .ready, submit: { _, _, _ in }
        )
        teammate = try Teammate(id: TeammateID(second.id), profile: TeammateProfile(displayName: second.name, role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 12, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        access = AgenticJobAccessModel(store: store)
        let store = self.store
        Task { await store.setAppEnabled(true) }
    }

    /// What the workspace does on every access change: the conversation learns
    /// whether jobs are on for its bot.
    func mirrorAccessIntoConversation() {
        conversation.setAgenticJob(enabled: access.isEnabled, presentation: nil)
    }

    func showSecondConversation() {
        conversation.show(conversationID: ordinaryLayoutUUID(200), title: second.name, messages: Self.secondMessages(second))
    }

    /// A short job conversation: a user task, a formatted reply, the report text.
    private static func firstMessages(_ bot: TeammateRowSnapshot) -> [ChatMessageSnapshot] {
        [
            ChatMessageSnapshot(id: ordinaryLayoutUUID(1_001), author: .user, body: "Count the rows in sample.csv and write report.md.",
                                delivery: .sent, timestamp: Date(timeIntervalSince1970: 1)),
            ChatMessageSnapshot(id: ordinaryLayoutUUID(1_002), author: .teammate(bot.identity), body: longTokenReportBody,
                                delivery: .sent, timestamp: Date(timeIntervalSince1970: 2)),
            ChatMessageSnapshot(id: ordinaryLayoutUUID(1_003), author: .teammate(bot.identity),
                                body: "Job finished. Its result is saved in the conversation.",
                                delivery: .sent, timestamp: Date(timeIntervalSince1970: 3))
        ]
    }

    /// The shape of the conversation that hung the installed app: same authors,
    /// part kinds, lengths, spaces and line breaks; every letter replaced.
    private static func secondMessages(_ bot: TeammateRowSnapshot) -> [ChatMessageSnapshot] {
        let shape: [(Int, String, [ChatMessagePartContentSnapshot])] = [
        (1, "user", [.text("abcde fghij")]),
        (2, "teammate", [.text("Ab cdefg! H'i Jklmno. Pqr stu V wxyz abc defgh?")]),
        (3, "user", [.text("Abcde fghi jklmnopqrst uvw")]),
        (4, "teammate", [.status("Abcdef ghijk lmn opqrstuv wxyz abcde."), .status("AbcdEfgh ijklmnopqr: stuvwxyzabCdefghIjklm")]),
        (5, "user", [.text("abcde f ghijk")]),
        (6, "teammate", [.text("Ab cdefg hijk lmno pqrstuv wxy zab cde! Fghij klm nopqrs tuvw xyzabcd efg hij kl mnop qrst uvw xyzab cd efg? Hijkl mn opqr stuv W xyza bcd efgh ijklmnop.")]),
        (7, "user", [.text("abcdefghi jklm")]),
        (8, "teammate", [.text("Ab cdefg hijk lmnopqr stuvw xyza bcdefg hij klm nopqr! Stuvw xyz abc de fghi jklm nop'q rstu vw xyz ab cdef ghijk? L'm nopqr st uvwx yzab C defg hij klmn opqrstu.")]),
        (9, "user", [.text("Abcdefgh ijk lmnopqr stuvwxyza")]),
        (10, "teammate", [.text("A bcd'e fghi jkl mnopqrs tu vwxyza bcd efg hi jklm no pqrstuvwx yzabc def—ghij klmnopq rstuv'w xyza bcde fg hijklmno pqrstu. V wxy'z abcd efg hijk lm \"Nopqrstuv\" wx yza bcdefghijklm nopqrst uvwxyz.\n\nAb cde fgh ijkl mn opqr stuvw xyza bcd'ef ghijklm nop—qrst uvwx yzabcdef Ghijklmno pq rs, tu vwxyzabc defghij klm nopqrst uvwx—Y'z abcde fg hijklmn op qrstu vw xyza. Bcdefghijklmn, op qrs tuvw x yzabcdefghi jk lmnopqr stu'v wxyz ab cdefg, hijkl mnop qrst uvw X yza bcde fgh ijklmno pq rstuv wxyzabc defg.")]),
        (11, "user", [.text("Abc de fgh ijkl Mnopqr stuvw.")]),
        (12, "teammate", [.text("Abcde fghijklm—no pqrstuv wx yzab cde fghij kl mno pqrstuvwxyz:\n\n- **Abcdef Ghijklmnopq** (Rstuvw xy zab Cdefgh, Ijklmno pq rst Uvwx, yza bcdef Ghijkl/Mno-Pqr Stuvwx) yz abc \"defghijk\" lmno-pqrstu Vwxyza. Bcd efghijk lmnopqrstuv wxy z abc de fghijklmn op qrs tuvw (xyzab cdefghij, klmnopq rstuvwx yzabcd), efg hijk lm nopq rstuv wxy zabcdef gh Ijklmn Opqrs't uvwxyza bcd efghijklm. Nop qrstuvwxy za bcd efgh ij Klmno pq Rstuvwx YZA—bcdefghijk lmn Opqrstuv wxyz abc \"D efgh ijk!\"—lm nopqrstuv wxyzabcd, efg hij klmn opqrst uvwxyzabcde fghi jklm nopq rstuvwxy, zabcdef g hijk lmnopq rstu vw xyz abcdefghi.\n\n- **Jklm Nopqr** stuvwx yzabc Defghi jk Lmn Opqrstu Vwxyza. Bc def g hij klmno pqrstu vwxy zabcd efghijkl (mno \"pqrstu\" vwxyzab, cde.), fgh ij'k lmnop qrstuvwx yzabcde fgh ijklmnop qrst uvwx yzabcd efghijklm/nopqrstuv wxyzab.\n\n- **Cdef Ghijkl** mnopqr Stuvwx yz *Abc Defgh Ijkl* mnopqrst uvwxyz, abc de'f ghijkl mnopqrs—tuvw xyza bcdefghi jklm nop qrstuvwxyz abcd ef ghi jklmnopqr, stuvw xyz abcd efg hijk lm nopqrst Uvwxyz'a bcdefghi, jklmnop, qrs tuvwxyz abcdefg hi j klm nop qrstu vwxy'z abcd efgh ijk.\n\n- **Lmnop Qrst Uvwxy** za bcd efghi jk Lmnop Qrstu vwx'y Zabcde fghijkl, mno pq'r stuvwx yza bcd efghijklm'n opqrstuv.\n\nWx Y zab cd efgh ijk: **Lmnopq Rstuvwxyzab** cde fghi-jklmno pqrstu vwx yzabcd (efghijklmn op qrstuvwxy, zabc defghi-jklmnop qrstuv wxyzabcd), ef **Ghij Klmnop** qr stu vwxyz abcdefghi jkl mnop qrs tuvw xyza bcdefghij klmn opqrstu vwx yzabc def ghijklmnopq.\n\nRs tuv wxyz ab cdef ghijklmn op qrst uvw xyzab, cd efg hij klmnopqrs tuv wxyzabcd/EF ghijk lmn?")]),
        (13, "user", [.text("Abc de fgh ijkl Mnopqr stuvw.")]),
        (14, "teammate", [.status("Abcdef ghijk lmn opqrstuv wxyz abcde."), .status("AbcdEfgh ijklmnopqr: stuvwxyzabCdefghIjklm")]),
        (15, "user", [.text("Ab cdefg H ijklm nopq rst Uvwxy Zabc defghi")]),
        (16, "teammate", [.status("Abcdef ghijk lmn opqrstuv wxyz abcde."), .status("AbcdEfgh ijklmnopqr: stuvwxyzabCdefghIjklm")]),
        ]
        return shape.map { sequence, author, parts in
            let messageID = ordinaryLayoutUUID(UInt64(2_000 + sequence))
            // The workspace re-authors a reply that carries only status parts as an
            // OpenBots status row (native selectable status labels between two
            // spacers) and gives every row a delivery notice caption.
            let onlyStatus = parts.allSatisfy { if case .status = $0 { return true }; return false }
            let authorSnapshot: ChatAuthorSnapshot = author == "user" ? .user
                : onlyStatus ? .system(label: "OpenBots") : .teammate(bot.identity)
            var snapshot = ChatMessageSnapshot(
                id: messageID, author: authorSnapshot,
                parts: parts.enumerated().map { ordinal, content in
                    ChatMessagePartSnapshot(id: ordinaryLayoutUUID(UInt64(3_000 + sequence * 10 + ordinal)), ordinal: ordinal, content: content)
                },
                delivery: .sent, timestamp: Date(timeIntervalSince1970: Double(sequence))
            )
            snapshot.deliveryNotice = onlyStatus ? "OpenBots status · no Claude reply received"
                : "Saved on this Mac · Claude delivery not verified"
            return snapshot
        }
    }
}

/// The real root view, with the details pane injected the way the workspace does it.
private struct OrdinaryConversationHarness: View {
    @ObservedObject var fixture: OrdinaryConversationLayoutFixture

    var body: some View {
        OpenBotsRootView(
            sidebar: fixture.sidebar, conversation: fixture.conversation,
            createTeammate: {}, openSettings: {},
            detailsPanel: fixture.detailsOpen ? AnyView(BotDetailsView(
                teammate: fixture.teammate, canEdit: true, onEdit: {}, onClose: {}, agenticJobAccess: fixture.access
            )) : nil
        )
    }
}

private func ordinaryLayoutUUID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "C0B10000-0000-0000-0000-%012llx", suffix))!
}
