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
        /// What this row is showing, for the label to declare. Set beside the
        /// parse, so it always describes the value actually installed rather
        /// than the body font of the moment.
        private(set) var declaration: TranscriptTextDeclaration?
        private(set) var digest: TranscriptTextDigest?

        func value(for content: String) -> NSAttributedString {
            guard source?.utf8.elementsEqual(content.utf8) != true else { return formatted }
            // Whether this row's text is still arriving. A reply is delivered in
            // chunks appended to what is already there, so a snapshot that
            // extends the last one is an intermediate state of one reply rather
            // than a different reply: two hundred of them for a long answer, each
            // with its own digest, its own parse and its own height. The
            // equal-length case cannot reach here — the guard above returned on
            // identical bytes.
            let isStillArriving = source.map {
                content.utf8.count > $0.utf8.count && content.utf8.starts(with: $0.utf8)
            } ?? false
            source = content
            let font = NSFont.preferredFont(forTextStyle: .body)
            let digest = TranscriptTextDigest.make(TranscriptTextDeclaration(
                kind: .markdown, tone: 0, font: font, content: content
            ))
            // A rebuilt row is a brand-new coordinator with an empty parse, so
            // scrolling back to a reply already read used to re-parse the whole
            // thing. The parse depends on the source and the body font alone,
            // both of which the digest covers.
            if let shared = SharedTranscriptTextCaches.parsedMarkdown(for: digest) {
                LayoutStormCounters.hit("markdown.parseShared")
                formatted = shared
            } else {
                LayoutStormCounters.hit("markdown.parse")
                // Immutable, and copied once: one instance now answers for every
                // row showing this reply, and `attributedText` builds a mutable
                // string that a caller could still hold a reference to.
                let parsed = NSAttributedString(attributedString: SafeReplyMarkdown.attributedText(content))
                if !isStillArriving { SharedTranscriptTextCaches.rememberParsedMarkdown(parsed, for: digest) }
                formatted = parsed
            }
            // A row whose text is still arriving says nothing about what it is
            // showing, so its label neither reads from nor writes to the stores
            // shared with every other row. It pays its own parse and its own
            // layout, which it was going to pay anyway because its text really
            // did change; what it no longer does is push two hundred answers
            // nothing will ask for again through stores holding a few dozen, and
            // evict the answers the rows above it were read at. The finished
            // reply is declared by the next row built to show it.
            //
            // The markers are gone by the time the label holds this, so the
            // declaration carries the rendered length the label can check itself
            // against, not the length of the source.
            self.digest = isStillArriving ? nil : digest
            declaration = isStillArriving ? nil : TranscriptTextDeclaration(
                kind: .markdown, tone: 0, font: font, content: content, renderedLength: formatted.length
            )
            return formatted
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        // The same wrapping label as plain transcript text, so its intrinsic
        // size follows the frame it is given instead of its widest line (a
        // formatted reply can hold lines over a thousand points wide).
        let field = StableSelectableText.makeField("")
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        apply(to: field, coordinator: context.coordinator)
    }

    /// The write SwiftUI performs on every update pass, without a `Context`, so a
    /// benchmark can build the row AppKit actually receives.
    func apply(to field: NSTextField, coordinator: Coordinator) {
        LayoutStormCounters.hit("markdown.update")
        let value = coordinator.value(for: content)
        if !field.attributedStringValue.isEqual(to: value) { field.attributedStringValue = value }
        // Last, after the write that would drop it, and with the digest the
        // coordinator already computed rather than a second hash of the reply.
        if let declaration = coordinator.declaration, let digest = coordinator.digest {
            (field as? StableWrappingLabel)?.declare(declaration, digest: digest)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        StableSelectableText.measuredSize(proposedWidth: proposal.width, field: field)
    }
}
