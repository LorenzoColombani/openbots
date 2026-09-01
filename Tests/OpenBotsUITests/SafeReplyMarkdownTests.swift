import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class SafeReplyMarkdownTests: XCTestCase {
    func testReadableEmphasisParagraphsHeadingsAndLists() throws {
        let source = "# Summary\n\nA **bold** and *quiet* reply with `code`.\n- First item\n- Second item\n\n1. Numbered item"
        let rendered = SafeReplyMarkdown.attributedText(source)
        XCTAssertEqual(rendered.string, "Summary\n\nA bold and quiet reply with code.\n• First item\n• Second item\n\n1. Numbered item")
        XCTAssertTrue(try fontTraits(in: rendered, word: "Summary").contains(.boldFontMask))
        XCTAssertTrue(try fontTraits(in: rendered, word: "bold").contains(.boldFontMask))
        XCTAssertTrue(try fontTraits(in: rendered, word: "quiet").contains(.italicFontMask))
        let listPosition = (rendered.string as NSString).range(of: "First item").location
        let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: listPosition, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(paragraph.headIndent, paragraph.firstLineHeadIndent)
    }

    func testFencedCodeRemainsVerbatimWhileSurroundingProseFormats() {
        let source = "**Before**\n```swift\nlet value = \"**literal**\"\n  <tag> stays literal\n```\n*After*"
        let rendered = SafeReplyMarkdown.attributedText(source)
        XCTAssertEqual(rendered.string, "Before\nlet value = \"**literal**\"\n  <tag> stays literal\nAfter")
    }

    func testLinksImagesAndHTMLCannotProduceInteractiveOrExternalContentAttributes() {
        let rendered = SafeReplyMarkdown.attributedText(
            "[A source](https://example.invalid/private) ![Diagram](https://example.invalid/image.png)\n<script>untrusted()</script>"
        )
        XCTAssertTrue(rendered.string.contains("A source"))
        let allowed: Set<NSAttributedString.Key> = [.font, .foregroundColor, .paragraphStyle]
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertTrue(Set(attributes.keys).isSubset(of: allowed))
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
        }
    }

    func testOverLimitTextFallsBackVerbatimAndIncompleteStreamingMarkdownStaysReadable() {
        let oversized = String(repeating: "x", count: SafeReplyMarkdown.maximumUTF8Bytes + 1) + " **literal**"
        XCTAssertEqual(SafeReplyMarkdown.attributedText(oversized).string, oversized)
        XCTAssertFalse(SafeReplyMarkdown.attributedText("A **streaming").string.isEmpty)
        XCTAssertEqual(SafeReplyMarkdown.attributedText("A **streaming reply**").string, "A streaming reply")
    }

    func testOnlyTeammateReplyTextUsesMarkdownAndRemainsNativeSelectableText() async throws {
        let identity = TeammateRowSnapshot(id: UUID(), name: "Ada", role: "Local fixture", activity: .idle, identitySeed: 1).identity
        let source = "A **formatted** reply\n\n- One item"
        let cases: [(ChatAuthorSnapshot, ChatMessagePartContentSnapshot, String)] = [
            (.teammate(identity), .text(source), "A formatted reply\n\n• One item"),
            (.user, .text(source), source),
            (.system(label: "OpenBots"), .status(source), source)
        ]
        for (author, content, expected) in cases {
            let snapshot = ChatMessageSnapshot(id: UUID(), author: author,
                parts: [ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: content)],
                delivery: .sent, timestamp: Date(timeIntervalSince1970: 1_788_000_000))
            let controller = NSHostingController(rootView: TranscriptMessagePartsView(message: snapshot))
            for width: CGFloat in [260, 620] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 300)
                for _ in 0..<3 {
                    controller.view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                let views = descendants(controller.view)
                let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == expected })
                XCTAssertTrue(field.isSelectable)
                XCTAssertFalse(field.isEditable)
                XCTAssertFalse(field.isBezeled)
                XCTAssertFalse(field.drawsBackground)
                XCTAssertNil(field.action)
                XCTAssertFalse(views.contains { $0 is NSButton })
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 300))
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width, width + 1)
                XCTAssertLessThanOrEqual(size.height, 300)
                XCTAssertEqual(snapshot.parts.first?.content, content, "Formatting must never rewrite saved message parts.")
                XCTAssertNil(controller.view.window)
            }
        }
    }

    private func fontTraits(in text: NSAttributedString, word: String) throws -> NSFontTraitMask {
        let location = (text.string as NSString).range(of: word).location
        XCTAssertNotEqual(location, NSNotFound)
        let font = try XCTUnwrap(text.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        return NSFontManager.shared.traits(of: font)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
