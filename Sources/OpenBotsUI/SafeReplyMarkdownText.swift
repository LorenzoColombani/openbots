import AppKit
import SwiftUI

/// Text-only Markdown presentation. Only native fonts, colors and paragraph
/// metrics are copied from the parsed text; links, images and HTML have no
/// renderer or action. The stored reply remains unchanged.
@MainActor
enum SafeReplyMarkdown {
    static let maximumUTF8Bytes = 262_144

    static func attributedText(_ source: String) -> NSAttributedString {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let plain: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        guard source.utf8.count <= maximumUTF8Bytes else {
            return NSAttributedString(string: source, attributes: plain)
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let output = NSMutableAttributedString(string: "")
        var fence: Character?
        var fenceLength = 0
        var hasLine = false
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let first = trimmed.first, first == "`" || first == "~" {
                let markers = trimmed.prefix(while: { $0 == first })
                if markers.count >= 3 {
                    if fence == nil {
                        fence = first; fenceLength = markers.count
                        continue
                    } else if fence == first, markers.count >= fenceLength,
                              trimmed.dropFirst(markers.count).allSatisfy({ $0.isWhitespace }) {
                        fence = nil
                        continue
                    }
                }
            }
            if hasLine { output.append(NSAttributedString(string: "\n", attributes: plain)) }
            hasLine = true
            if fence != nil {
                output.append(NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]))
                continue
            }

            var content = line
            var heading = false
            var isList = false
            let headingMarks = trimmed.prefix(while: { $0 == "#" })
            if (1...6).contains(headingMarks.count), trimmed.dropFirst(headingMarks.count).first == " " {
                content = String(trimmed.dropFirst(headingMarks.count + 1))
                heading = true
            } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
                content = String(line.prefix(line.count - trimmed.count)) + "• " + String(trimmed.dropFirst(2))
                isList = true
            } else {
                let number = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
                let suffix = trimmed.dropFirst(number.count)
                isList = (1...9).contains(number.count) && (suffix.hasPrefix(". ") || suffix.hasPrefix(") "))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = isList ? 2 : 5
            paragraph.headIndent = isList ? bodyFont.pointSize * 1.3 : 0
            let parsed = (try? AttributedString(markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent
                let baseFont = intent?.contains(.code) == true
                    ? NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular) : bodyFont
                var traits: NSFontTraitMask = []
                if heading || intent?.contains(.stronglyEmphasized) == true { traits.insert(.boldFontMask) }
                if intent?.contains(.emphasized) == true { traits.insert(.italicFontMask) }
                let font = traits.isEmpty ? baseFont : NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                ]))
            }
        }
        return output
    }
}

/// Uses the same stable native wrapping label as plain transcript text, without
/// SwiftUI's SelectionOverlay or an HTML/web view. Formatting is cached per row
/// and unchanged attributes never invalidate the native layout again.
@MainActor
struct SafeReplyMarkdownText: NSViewRepresentable {
    let content: String

    @MainActor
    final class Coordinator {
        var source: String?
        var formatted = NSAttributedString(string: "")

        func value(for content: String) -> NSAttributedString {
            if source?.utf8.elementsEqual(content.utf8) != true {
                source = content
                formatted = SafeReplyMarkdown.attributedText(content)
            }
            return formatted
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let value = context.coordinator.value(for: content)
        if !field.attributedStringValue.isEqual(to: value) { field.attributedStringValue = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        StableSelectableText.measuredSize(proposedWidth: proposal.width, field: field)
    }
}
