import AppKit
import OpenBotsDomain
import OpenBotsRuntime
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// The words on an approval card sit in a box of 140 points, nine lines of
/// its type and fewer under a heading, and on a trackpad the scroller is
/// hidden. Approve used to be live the moment the card appeared, so a text
/// whose second paragraph sat below the fold could be approved with only its
/// first line ever on screen. Approve now waits
/// while the end of the words is known to be past the box; Deny never waits.
@MainActor
final class ApprovalCardReadingTests: XCTestCase {
    /// A card once said "Waits until 3:42 PM", a clock time to subtract in
    /// the user's head, and its buttons only
    /// greyed when something else redrew the card. It now says how long is left,
    /// ticking every 30 seconds, with one tick landing on the deadline itself.
    func testCardDeadlinesSayHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func left(_ seconds: TimeInterval) -> String {
            CardDeadlineWording.timeLeft(until: now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(left(300), "About 5 minutes left")
        XCTAssertEqual(left(270), "About 5 minutes left")
        XCTAssertEqual(left(240), "About 4 minutes left")
        XCTAssertEqual(left(89), "About a minute left")
        XCTAssertEqual(left(60), "About a minute left")
        XCTAssertEqual(left(59), "Less than a minute left")
        XCTAssertEqual(left(1), "Less than a minute left")
        XCTAssertEqual(left(3_600), "About an hour left")
        XCTAssertEqual(left(7_200), "About 2 hours left")
        XCTAssertEqual(left(0), "Time is up")
        XCTAssertEqual(left(-5), "Time is up")

        let expires = now.addingTimeInterval(300)
        XCTAssertEqual(CardDeadlineWording.line(.action, expiresAt: expires, now: now),
                       "About 5 minutes left. Then the action is not done.")
        XCTAssertEqual(CardDeadlineWording.line(.handOver, expiresAt: expires, now: now),
                       "Nothing of Control this Mac runs until you hand the screen back. About 5 minutes left. Then the bot is told you did not finish.")
        XCTAssertEqual(CardDeadlineWording.line(.missingFile, expiresAt: expires, now: now),
                       "About 5 minutes left. Then the reply does not run, and the results wait for your next message.")
        XCTAssertEqual(CardDeadlineWording.line(.question, expiresAt: expires, now: now),
                       "About 5 minutes left. Then the bot goes on without an answer.")
        XCTAssertEqual(CardDeadlineWording.line(.action, expiresAt: now, now: now),
                       "Time is up, so the action is not done.")
        XCTAssertEqual(CardDeadlineWording.line(.question, expiresAt: now, now: now),
                       "Time is up, so the bot goes on without an answer.")
        for kind in [CardDeadlineWording.Kind.action, .handOver, .missingFile, .question] {
            XCTAssertFalse(CardDeadlineWording.line(kind, expiresAt: expires, now: now).contains("Waits until"))
        }

        // The tick schedule starts no later than now and lands on the deadline.
        for remaining in [300.0, 299, 31, 30, 1] {
            let deadline = now.addingTimeInterval(remaining)
            let start = CardDeadlineWording.tickStart(expiresAt: deadline, now: now)
            XCTAssertLessThanOrEqual(start, now)
            XCTAssertGreaterThan(start, now.addingTimeInterval(-30))
            let steps = deadline.timeIntervalSince(start) / CardDeadlineWording.tick
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-6, "\(remaining)")
        }
        XCTAssertEqual(CardDeadlineWording.tickStart(expiresAt: now.addingTimeInterval(-10), now: now), now)
    }

    func testWordsThatFitTheBoxAreSeenWhole() throws {
        let seen = EndSeenRecord()
        let (window, host) = hosted(ApprovalDetailBox(detail: "It goes out from your own number.\n\nSee you at 8.",
                                                      endSeen: seen.binding))
        defer { window.close() }
        settle(host)
        XCTAssertEqual(seen.value, true)
    }

    func testWordsBelowTheFoldAreSeenOnlyOnceTheEndHasBeenInTheBox() throws {
        let seen = EndSeenRecord()
        let detail = "It goes out from your own number.\n\n" + (1...60).map { "Line \($0)" }.joined(separator: "\n")
        let (window, host) = hosted(ApprovalDetailBox(detail: detail, endSeen: seen.binding))
        defer { window.close() }
        settle(host)
        XCTAssertEqual(seen.value, false, "the end of sixty lines is below the fold, and the card must know it")

        let scrollView = try XCTUnwrap(host.approvalDescendants.compactMap { $0 as? NSScrollView }.first)
        let clip = scrollView.contentView
        let document = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThan(document.bounds.height, clip.bounds.height + 100,
                             "document \(document.bounds.height) pt in a \(clip.bounds.height) pt box")
        // Halfway is not the end.
        scroll(scrollView, toFraction: 0.5)
        settle(host)
        XCTAssertEqual(seen.value, false)
        scroll(scrollView, toFraction: 1)
        settle(host)
        XCTAssertEqual(seen.value, true)
        // Once seen, scrolling back up does not take Approve away again.
        scroll(scrollView, toFraction: 0)
        settle(host)
        XCTAssertEqual(seen.value, true)
    }

    /// Before SwiftUI lays the words out, the probe finds a document of no
    /// height in a box of 140 points, and "no taller than the box" read as
    /// seen: sixty lines latched Approve on for good before one of them had
    /// been laid out. Words not yet laid out now count for nothing, and the
    /// first real measurement decides.
    func testWordsNotYetLaidOutAreNeverCountedAsSeen() throws {
        let seen = EndSeenRecord()
        let detail = "It goes out from your own number.\n\n" + (1...60).map { "Line \($0)" }.joined(separator: "\n")
        let host = NSHostingView(rootView: ApprovalDetailBox(detail: detail, endSeen: seen.binding))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        settle(host)
        let scrollView = try XCTUnwrap(host.approvalDescendants.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scrollView.documentView?.bounds.height, 0, "outside a window the words are never laid out")
        XCTAssertNil(seen.value, "words not yet laid out were counted as seen whole")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        settle(host)
        XCTAssertEqual(seen.value, false, "once laid out, the end of sixty lines is below the fold")
    }

    func testApproveWaitsForTheEndAndDenyNeverDoes() {
        // Unmeasured is not overflowing: a box the probe never reached must not
        // leave Approve dead, on this card or on any other kind of card.
        let unknown = ApprovalCardButtons(expired: false, endSeen: nil)
        XCTAssertTrue(unknown.approveEnabled)
        XCTAssertTrue(unknown.denyEnabled)
        XCTAssertFalse(unknown.showsScrollHint, "no hint flashes before the box has been measured")
        let below = ApprovalCardButtons(expired: false, endSeen: false)
        XCTAssertFalse(below.approveEnabled)
        XCTAssertTrue(below.denyEnabled)
        XCTAssertTrue(below.showsScrollHint)
        let seen = ApprovalCardButtons(expired: false, endSeen: true)
        XCTAssertTrue(seen.approveEnabled)
        XCTAssertFalse(seen.showsScrollHint)
        let expired = ApprovalCardButtons(expired: true, endSeen: true)
        XCTAssertFalse(expired.approveEnabled)
        XCTAssertFalse(expired.denyEnabled)
    }

    /// The whole card in the composer at its narrowest, not the box alone.
    /// SwiftUI draws neither its buttons nor its text as views, and builds no
    /// accessibility tree for an unattended test, so the scroll hint, which
    /// shows exactly while Approve waits (above), is read from the card's
    /// height.
    func testTheWholeCardWaitsOnlyWhileItsWordsRunPastTheBox() throws {
        let long = composerCard(detail: "It goes out from your own number.\n\n"
                                + (1...60).map { "Line \($0)" }.joined(separator: "\n"))
        defer { long.window.close() }
        settle(long.host)
        let waiting = long.host.fittingSize.height
        let longBox = try XCTUnwrap(long.host.approvalDescendants.compactMap { $0 as? NSScrollView }.first)
        scroll(longBox, toFraction: 1)
        settle(long.host)
        let released = long.host.fittingSize.height
        XCTAssertGreaterThan(waiting - released, 10,
                             "the hint must show until the end has been in the box, then go (\(waiting) → \(released))")

        let short = composerCard(detail: "It goes out from your own number.\n\nSee you at 8.")
        defer { short.window.close() }
        settle(short.host)
        let shortBox = try XCTUnwrap(short.host.approvalDescendants.compactMap { $0 as? NSScrollView }.first)
        let shortWords = try XCTUnwrap(shortBox.documentView)
        XCTAssertGreaterThan(shortWords.bounds.height, 0)
        XCTAssertLessThanOrEqual(shortWords.bounds.height, shortBox.contentView.bounds.height,
                                 "a two-line card fits its box in the composer, so nothing waits")
    }

    /// Seen live on a Gmail send card: in a window 652
    /// points tall the words' box was squeezed to no height beside the
    /// transcript, the words ran past it, nothing could scroll, and Approve
    /// stayed grey until the user made the window taller. The box now keeps the
    /// height of its words, up to its cap; the transcript above gives way.
    func testTheBoxKeepsItsWordsHeightWhenTheWindowIsShort() throws {
        let detail = "Sends as soon as you approve, from bot@example.com to owner@example.com.\n"
            + "Subject: OpenBots Next: Gmail send test\n\nHello Alex, this is Mailcheck."
        let approval = ClaudeTextApproval(id: UUID(), runID: RunID(UUID()), requestID: "req-1",
                                          toolName: "mcp__\(messagesServerKey)__send_gmail_message",
                                          title: "Send a Gmail message", detail: detail,
                                          target: "owner@example.com", expiresAt: Date().addingTimeInterval(600))
        let conversation = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        // A transcript that would take every point it is given, above the card.
        let column = VStack(alignment: .leading, spacing: 8) {
            ScrollView { Text((1...200).map { "Earlier line \($0)" }.joined(separator: "\n")) }
            TextReplyApprovalCard(approval: approval, conversation: conversation)
        }
        .padding(.horizontal, 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: column)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 260)
        settle(host)
        let boxes = host.approvalDescendants.compactMap { $0 as? NSScrollView }
            .filter { $0.documentView.map { $0.bounds.height < 400 } ?? false }
        let box = try XCTUnwrap(boxes.first, "the card's words box")
        let words = try XCTUnwrap(box.documentView).bounds.height
        XCTAssertGreaterThan(words, 0)
        XCTAssertGreaterThanOrEqual(box.contentView.bounds.height + 0.5, min(words, 140),
            "the box holds its words (\(box.contentView.bounds.height) for \(words)), so nothing waits on a scroll it cannot give")
    }

    /// The Messages card counts a text's lines only past the most that fit
    /// whole under its heading, and that is a claim about this box. Rendered
    /// in the composer at its narrowest, the longest text without a count must
    /// fit, heading and all: there the heading's two sentences wrap to three
    /// lines, and a six-line text, which the card took to fit, ran past the
    /// fold with no count.
    func testTheLongestUncountedTextFitsTheNarrowestCardWhole() throws {
        for service in ["iMessage", "RCS"] {
            var uncounted: ClaudeTextWorkCard?
            for lines in 1...20 {
                let card = try messagesSendCard(service: service,
                                                text: (1...lines).map { "Line \($0)" }.joined(separator: "\n"))
                if card.detail.contains("lines long") { break }
                uncounted = card
            }
            let card = try XCTUnwrap(uncounted)
            let hosted = composerCard(detail: card.detail)
            defer { hosted.window.close() }
            settle(hosted.host)
            let box = try XCTUnwrap(hosted.host.approvalDescendants.compactMap { $0 as? NSScrollView }.first)
            let words = try XCTUnwrap(box.documentView)
            XCTAssertGreaterThan(words.bounds.height, 0)
            XCTAssertLessThanOrEqual(words.bounds.height, box.contentView.bounds.height,
                                     "\(service): \(words.bounds.height) pt of words in a \(box.contentView.bounds.height) pt box:\n\(card.detail)")
        }
    }

    /// A web card after a look draws what the bot saw, small, and a
    /// picture the card cannot read draws nothing.
    func testAWebCardAfterALookDrawsTheScreenshot() throws {
        let image = NSImage(size: NSSize(width: 800, height: 500))
        image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 800, height: 500).fill(); image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let plain = composerCard(detail: "It looked at your screen earlier in this chat.")
        defer { plain.window.close() }
        settle(plain.host)
        let shown = composerCard(detail: "It looked at your screen earlier in this chat.", screenPicture: png)
        defer { shown.window.close() }
        settle(shown.host)
        let growth = shown.host.fittingSize.height - plain.host.fittingSize.height
        XCTAssertGreaterThan(growth, 60, "the screenshot added \(growth) pt")
        XCTAssertLessThanOrEqual(growth, 150, "the screenshot must stay small on the card: \(growth) pt")
        let broken = composerCard(detail: "It looked at your screen earlier in this chat.", screenPicture: Data("not a picture".utf8))
        defer { broken.window.close() }
        settle(broken.host)
        XCTAssertEqual(broken.host.fittingSize.height, plain.host.fittingSize.height, accuracy: 0.5)
    }

    /// Seen live: beside a transcript in a real window the screenshot once got
    /// no height at all; only its caption
    /// showed. The picture keeps its own height, as the words' box does.
    func testTheScreenshotKeepsItsHeightBesideATranscript() throws {
        let image = NSImage(size: NSSize(width: 800, height: 500))
        image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 800, height: 500).fill(); image.unlockFocus()
        final class Measured { var height: CGFloat = -1 }
        let measured = Measured()
        let column = VStack(alignment: .leading, spacing: 8) {
            ScrollView { Text((1...200).map { "Earlier line \($0)" }.joined(separator: "\n")) }
            ApprovalScreenPicture(picture: image)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { measured.height = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, value in measured.height = value }
                })
        }
        .padding(.horizontal, 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: column)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 260)
        settle(host)
        XCTAssertGreaterThanOrEqual(measured.height, 100, "the screenshot and its caption got \(measured.height) pt")
    }

    /// The target line sat under the words' box as a plain line with no clamp,
    /// so a target the bot shaped could push Approve and Deny off the card
    /// while the words above it were held to 140 points. The target takes the
    /// same clamp.
    func testTheTargetLineTakesTheWordsClamp() throws {
        let short = composerCard(detail: "It goes out from your own number.", target: "one line")
        defer { short.window.close() }
        settle(short.host)
        let tall = composerCard(detail: "It goes out from your own number.",
                                target: (1...60).map { "Target line \($0)" }.joined(separator: "\n"))
        defer { tall.window.close() }
        settle(tall.host)
        let growth = tall.host.fittingSize.height - short.host.fittingSize.height
        XCTAssertLessThanOrEqual(growth, ApprovalDetailBox.maximumHeight,
                                 "sixty target lines grew the card by \(growth) pt")
        // And the box holds a short target whole, so an ordinary one is not
        // squeezed to nothing beside the transcript.
        let boxes = short.host.approvalDescendants.compactMap { $0 as? NSScrollView }
        XCTAssertEqual(boxes.count, 2, "the words and the target each have their box")
        for box in boxes {
            let words = try XCTUnwrap(box.documentView).bounds.height
            XCTAssertGreaterThan(words, 0)
            XCTAssertGreaterThanOrEqual(box.contentView.bounds.height + 0.5, words)
        }
    }

    /// SwiftUI on macOS 26 and later draws its buttons without NSButton
    /// children, so a rendered card cannot be clicked from here. The two
    /// halves above are proved on their own; this holds the card to using them.
    func testTheCardTakesItsButtonsFromTheReadingState() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/OpenBotsRootView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct TextReplyApprovalCard: View {"))
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.upperBound])
        XCTAssertTrue(card.contains("ApprovalDetailBox(detail: approval.detail, endSeen: $detailEndSeen,"))
        XCTAssertTrue(card.contains(".disabled(!buttons.approveEnabled)"))
        XCTAssertTrue(card.contains(".disabled(!buttons.denyEnabled)"))
        XCTAssertEqual(card.components(separatedBy: ".disabled(!buttons.approveEnabled)").count - 1, 3,
                       "Approve, Allow for this turn and a handoff's Hand back all wait for the end of the words")
        XCTAssertEqual(card.components(separatedBy: ".disabled(!buttons.denyEnabled)").count - 1, 4,
                       "Deny, a handoff's I couldn't do it, and a missing file's two answers follow the same reading state; "
                       + "the missing-file card shows no scroll hint, so neither of its answers waits for the end of the words")
        XCTAssertFalse(card.contains("ScrollView {"), "the words are drawn by ApprovalDetailBox alone")
    }

    /// Control this Mac shares one turn scope across every card of the
    /// connector, and its "folder" is the words "your Mac": the button's help
    /// read "Lets this bot do this in your Mac", beside a comment saying a
    /// connector call asks every time, when the allowance covers every
    /// reviewed Control this Mac action until the reply ends.
    func testAllowForThisTurnSaysWhatItAllows() throws {
        let mac = ClaudeTextMacControlApprovalPolicy.turnScope.folderName
        let control = TurnAllowanceWording.help(toolName: "mcp__openbots_\(String(repeating: "c", count: 64))__click",
                                                folder: mac)
        XCTAssertFalse(control.contains("in your Mac"), control)
        XCTAssertTrue(control.contains("until this reply ends"), control)
        XCTAssertTrue(control.contains("clicking") && control.contains("typing"), control)
        // The old line promised that quitting or opening still asks,
        // while the card beside it and the policy both say a click or a shortcut can still do either.
        XCTAssertTrue(control.contains("its own quit and open still ask"), control)
        XCTAssertTrue(control.contains("a click or a shortcut can still close or quit things, or open a link"), control)
        XCTAssertFalse(control.contains("quitting an app or opening a link or a file still asks"), control)
        XCTAssertTrue(control.contains("Stop"), control)
        // A folder card keeps its folder, even a folder that happens to share the name.
        XCTAssertEqual(TurnAllowanceWording.help(toolName: "Edit", folder: "Invoices"),
                       "Lets this bot do this in Invoices for the rest of this turn without asking again.")
        XCTAssertEqual(TurnAllowanceWording.help(toolName: "Write", folder: mac),
                       "Lets this bot do this in \(mac) for the rest of this turn without asking again.")

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/OpenBotsRootView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct TextReplyApprovalCard: View {"))
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.upperBound])
        XCTAssertTrue(card.contains(".help(TurnAllowanceWording.help(toolName: approval.toolName, folder: folder))"))
        XCTAssertFalse(card.contains("a connector call ask every time"), "the comment beside the button must be true")
    }

    private func scroll(_ scrollView: NSScrollView, toFraction fraction: CGFloat) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let travel = max(0, document.bounds.height - clip.bounds.height)
        let offset = document.isFlipped ? travel * fraction : travel * (1 - fraction)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offset))
        scrollView.reflectScrolledClipView(clip)
    }

    /// In a window, never shown: without one SwiftUI leaves the scroll view's
    /// document view at zero size, and there is nothing to measure.
    private func hosted(_ view: ApprovalDetailBox) -> (NSWindow, NSHostingView<ApprovalDetailBox>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        return (window, host)
    }

    /// The card as the composer holds it when the window is as narrow as it
    /// goes: the conversation column is at least 340 points wide
    /// (`OpenBotsRootView`), and the composer pads its content by 20 on each
    /// side, so the card is 300 points wide and its box 280. The host keeps its
    /// height: left to size the window to the card, it shrank it to the card
    /// without its hint, and the hint then squeezed the box to 121 points,
    /// which the transcript above the composer never lets happen.
    private func composerCard(detail: String, target: String = "+33612345678 on SMS",
                              screenPicture: Data? = nil) -> (window: NSWindow, host: NSView) {
        let approval = ClaudeTextApproval(id: UUID(), runID: RunID(UUID()), requestID: "req-1",
                                          toolName: "mcp__\(messagesServerKey)__send_message",
                                          title: "Send a text as you", detail: detail,
                                          target: target, expiresAt: Date().addingTimeInterval(600),
                                          screenPicture: screenPicture)
        let conversation = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        let column = VStack(alignment: .leading, spacing: 8) {
            TextReplyApprovalCard(approval: approval, conversation: conversation)
        }
        .padding(.horizontal, 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: column)
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 600)
        return (window, host)
    }

    private func messagesSendCard(service: String, text: String) throws -> ClaudeTextWorkCard {
        let input: [String: Any] = ["recipient": "+33612345678", "service": service, "text": text]
        let request = ClaudeTextPermissionRequest(requestID: "req-1", toolUseID: "toolu_01",
                                                  toolName: "mcp__\(messagesServerKey)__send_message",
                                                  inputJSON: try JSONSerialization.data(withJSONObject: input))
        let decision = ClaudeTextConnectorApprovalPolicy.decide(request, botName: "Kite", role: .appleMessages)
        guard case .ask(let card) = decision else {
            XCTFail("expected a card for a \(service) text, got \(decision)")
            throw CancellationError()
        }
        return card
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
        }
    }
}

private let messagesServerKey = "openbots_" + String(repeating: "e", count: 64)

@MainActor
private final class EndSeenRecord {
    var value: Bool?
    var binding: Binding<Bool?> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

private extension NSView {
    var approvalDescendants: [NSView] { subviews + subviews.flatMap(\.approvalDescendants) }
}

/// Seen live: a card whose words were three short lines showed
/// "Scroll to the end of the words above to approve." with Approve dead and
/// nothing to scroll. The probe had answered while its box had no height yet —
/// a document taller than a zero-height clip reads as "not at the end", and the
/// card remembers that answer until a real scroll clears it, which a card with
/// nothing to scroll can never give.
final class ApprovalCardScrollProbeTests: XCTestCase {
    @MainActor
    func testTheProbeSaysNothingWhileItsBoxHasNoHeightAndSaysSeenOnceItFits() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 0))
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        scrollView.documentView = document
        let probe = TranscriptScrollProbeView()
        probe.threshold = 1
        document.addSubview(probe)
        var answers: [Bool] = []
        probe.onNearBottomChange = { answers.append($0) }

        // The box has no height yet: the words are taller than nothing, which is
        // not an answer about whether the user has read them.
        probe.assessForTests()
        XCTAssertEqual(answers, [], "a box of no height gives no verdict")

        // Laid out: the words fit the box, so their end has been in view.
        scrollView.setFrameSize(NSSize(width: 280, height: 140))
        scrollView.layoutSubtreeIfNeeded()
        probe.assessForTests()
        XCTAssertEqual(answers, [true], "words that fit their box have been read to the end")
    }
}

extension ApprovalCardScrollProbeTests {
    /// The words' box needs a scroll bar you can see. With a trackpad
    /// macOS hides the scroller until something scrolls, so a card whose words
    /// run past its box looked complete.
    @MainActor
    func testTheWordsBoxKeepsItsScrollerDrawn() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 140))
        scrollView.documentView = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let probe = TranscriptScrollProbeView()
        probe.threshold = 1
        probe.keepsScrollerVisible = true
        scrollView.documentView?.addSubview(probe)
        probe.assessForTests()
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.autohidesScrollers, "the card's scroller stays drawn")
        XCTAssertEqual(scrollView.scrollerStyle, .legacy)

        // The transcript keeps the system's own behaviour.
        let transcript = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 140))
        transcript.documentView = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        transcript.autohidesScrollers = true
        let plain = TranscriptScrollProbeView()
        transcript.documentView?.addSubview(plain)
        plain.assessForTests()
        XCTAssertTrue(transcript.autohidesScrollers)
    }
}

extension ApprovalCardScrollProbeTests {
    /// Seen live on a Gmail send card: Approve grey, the
    /// hint asking for a scroll, and nothing to scroll; widening the window
    /// cleared it. The box was measured while it was still short, the words ran
    /// past it, and when the box then grew to hold them nothing measured again:
    /// the probe listened for the words changing size and for a scroll, not for
    /// the box itself growing. It measures again when the box changes size.
    @MainActor
    func testTheBoxGrowingToHoldTheWordsIsMeasuredAgain() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        // A plain view keeps the height it is given; a text view would size
        // itself to its (empty) text.
        let document = FlippedWords(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        scrollView.documentView = document
        let probe = TranscriptScrollProbeView()
        probe.threshold = 1
        document.addSubview(probe)
        var answers: [Bool] = []
        probe.onNearBottomChange = { answers.append($0) }
        probe.assessForTests()
        XCTAssertEqual(answers, [false], "words past a short box are not read yet")

        // Only the box changes: no scroll, no change to the words.
        scrollView.setFrameSize(NSSize(width: 280, height: 140))
        scrollView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(answers.last, true, "a box that grew to hold the words has shown their end")
    }
}

private final class FlippedWords: NSView {
    override var isFlipped: Bool { true }
}

/// Every card's words were once in code type. Only a shell command
/// or a script run reads as code; everything else is set in the body font.
final class ApprovalDetailTypeTests: XCTestCase {
    @MainActor
    func testOnlyCommandsAreInCodeType() {
        XCTAssertTrue(ApprovalDetailBox.usesCodeType(toolName: "Bash"))
        XCTAssertFalse(ApprovalDetailBox.usesCodeType(toolName: "Write"))
        XCTAssertFalse(ApprovalDetailBox.usesCodeType(toolName: "mcp__openbots_1234__send_mail"))
        XCTAssertFalse(ApprovalDetailBox.usesCodeType(toolName: "WebFetch"))
    }
}
