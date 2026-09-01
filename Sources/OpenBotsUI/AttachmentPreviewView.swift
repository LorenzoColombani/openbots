import AppKit
import OpenBotsDomain
import SwiftUI

/// A short, explicit inspection task. Closing never saves, edits, opens or
/// exports a document, and the underlying conversation remains mounted.
struct AttachmentPreviewView: View {
    @ObservedObject var model: AttachmentPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Label("Read-only preview · Saved local copy", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if let count = model.pageCount {
                VStack(spacing: OpenBotsVisualStyle.spacing8) {
                    Text("Page \(model.requestedPage) of \(count)")
                        .font(.callout.monospacedDigit())
                        .accessibilityLabel("PDF page \(model.requestedPage) of \(count)")
                    HStack {
                        Button("Previous Page") { model.requestPage(model.requestedPage - 1) }
                            .disabled(!model.canPreviousPage)
                        Button("Next Page") { model.requestPage(model.requestedPage + 1) }
                            .disabled(!model.canNextPage)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close Preview") { model.close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(OpenBotsVisualStyle.spacing16)
        .frame(minWidth: 340, idealWidth: 640, maxWidth: 860,
               minHeight: 320, idealHeight: 520, maxHeight: 760)
        .background(.background)
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var previewContent: some View {
        if model.isLoading {
            VStack(spacing: OpenBotsVisualStyle.spacing12) {
                ProgressView().controlSize(.small)
                Text(model.pageCount == nil ? "Preparing read-only preview…" : "Preparing page \(model.requestedPage)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("You can close this preview while it loads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Preview") { model.retry() }
            }
        } else if let content = model.content {
            switch content {
            case .text(let text, let truncated):
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    if truncated {
                        Label("Showing the first 256 KiB of text. The saved file is unchanged.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AttachmentPreviewPlainText(text: text)
                        .accessibilityLabel("Read-only text from \(model.displayName)")
                }
            case .image(let image):
                previewImage(image, label: "Image preview of \(model.displayName). No image description is available.")
            case .pdfPage(let image, let number, _):
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    Text("Static page image only. Text isn’t extracted or searchable; forms and links aren’t interactive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    previewImage(image, label: "Static image of PDF page \(number), \(model.displayName). Page text is not accessible in this preview.")
                }
            case .unavailable(let reason):
                Label(unavailableDescription(reason), systemImage: "doc.questionmark")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewImage(_ image: AttachmentPreviewImage, label: String) -> some View {
        Image(image.cgImage, scale: 1, label: Text(label))
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableDescription(_ reason: AttachmentPreviewUnavailableReason) -> String {
        switch reason {
        case .unsupportedType:
            "This file type doesn’t have a read-only preview. The saved copy is unchanged."
        case .fileTooLarge:
            "This file is too large for a bounded preview. The saved copy is unchanged."
        case .invalidTextEncoding:
            "This file couldn’t be read as supported plain text. The saved copy is unchanged."
        case .imageTooLarge:
            "This image exceeds the preview limits. The saved copy is unchanged."
        case .passwordProtectedPDF:
            "Password-protected PDFs aren’t previewed. The saved copy is unchanged."
        case .tooManyPDFPages:
            "This PDF exceeds the 500-page preview limit. The saved copy is unchanged."
        }
    }
}

/// A fixed-viewport native reader, not an editor or document-opening surface.
/// Its scrolling text never feeds content-height estimates back into the sheet.
struct AttachmentPreviewPlainText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = CGSize(width: OpenBotsVisualStyle.spacing8, height: OpenBotsVisualStyle.spacing8)
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text }
        let font = NSFont.preferredFont(forTextStyle: .body)
        if view.font?.isEqual(font) != true { view.font = font }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: finite(proposal.width, fallback: 320), height: finite(proposal.height, fallback: 300))
    }

    private func finite(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite else { return fallback }
        return max(0, value)
    }
}
