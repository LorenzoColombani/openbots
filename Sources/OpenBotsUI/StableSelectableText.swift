import AppKit
import SwiftUI

/// Selectable, wrapping transcript text without SwiftUI's private
/// `SelectionOverlay` bridge.
///
/// On macOS 26.6.2 that bridge can reapply its backing text field's font while
/// a lazy transcript is replacing rows and moving focus. The font write
/// invalidates intrinsic size during AppKit's constraint pass and can create an
/// unbounded display-cycle feedback loop. A native wrapping label preserves
/// selection and accessibility while keeping one stable AppKit control.
struct StableSelectableText: NSViewRepresentable {
    enum Style {
        case body
        case callout
        case caption

        var font: NSFont {
            switch self {
            case .body:
                NSFont.preferredFont(forTextStyle: .body)
            case .callout:
                NSFont.preferredFont(forTextStyle: .callout)
            case .caption:
                NSFont.preferredFont(forTextStyle: .caption1)
            }
        }
    }

    enum Tone {
        case primary
        case secondary

        var color: NSColor {
            switch self {
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            }
        }
    }

    let content: String
    let style: Style
    let tone: Tone

    init(
        _ content: String,
        style: Style = .body,
        tone: Tone = .primary
    ) {
        self.content = content
        self.style = style
        self.tone = tone
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: content)
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
        applyStablePresentation(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Avoid unconditional AppKit writes from SwiftUI update passes. Font
        // and text changes legitimately invalidate intrinsic size; identical
        // values must not restart a constraint pass.
        applyStablePresentation(to: field)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView field: NSTextField,
        context: Context
    ) -> CGSize? {
        Self.measuredSize(proposedWidth: proposal.width, field: field)
    }

    static func measuredSize(proposedWidth: CGFloat?, field: NSTextField) -> CGSize {
        guard let width = proposedWidth, width.isFinite, width > 0 else {
            return field.intrinsicContentSize
        }
        // SwiftUI proposes the alignment rectangle, while NSTextFieldCell
        // measures the full frame including its text margins. Passing the
        // alignment width straight to the cell subtracts those margins twice:
        // a one-line intrinsic size can remeasure as two lines at its own width.
        // Use AppKit's inverse geometry conversions without mutating the view.
        let frameWidth = field.frame(forAlignmentRect: NSRect(
            x: 0, y: 0, width: width, height: 1
        )).width
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: frameWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let height: CGFloat
        if let cell = field.cell {
            let measuredFrame = NSRect(origin: .zero, size: cell.cellSize(forBounds: bounds))
            height = field.alignmentRect(forFrame: measuredFrame).height
        } else {
            height = field.intrinsicContentSize.height
        }
        return CGSize(width: width, height: ceil(height))
    }

    private func applyStablePresentation(to field: NSTextField) {
        if field.stringValue != content {
            field.stringValue = content
        }
        let targetFont = style.font
        if field.font?.isEqual(targetFont) != true {
            field.font = targetFont
        }
        let targetColor = tone.color
        if field.textColor?.isEqual(targetColor) != true {
            field.textColor = targetColor
        }
    }
}
