import AppKit
import SwiftUI

/// Pure follow policy shared by the native scroll bridge and focused tests.
/// User-authored tail appends always remain visible; teammate growth follows
/// only while the reader is already near the bottom.
enum TranscriptScrollFollowPolicy {
    static func followsTailAppend(
        isNearBottom: Bool,
        lastMessageIsFromUser: Bool,
        isOpeningConversation: Bool
    ) -> Bool {
        isOpeningConversation || lastMessageIsFromUser || isNearBottom
    }

    static func followsStreamingGrowth(isNearBottom: Bool) -> Bool {
        isNearBottom
    }
}

/// Bridges the enclosing `NSScrollView` without publishing synchronously from
/// AppKit's layout/display notifications. The deferred assessment preserves the
/// legacy-proven fix for SwiftUI streaming display-cycle loops.
struct TranscriptScrollPositionObserver: NSViewRepresentable {
    @Binding var isNearBottom: Bool
    var threshold: CGFloat = 96

    func makeNSView(context: Context) -> TranscriptScrollProbeView {
        let view = TranscriptScrollProbeView()
        view.threshold = threshold
        view.onNearBottomChange = { value in
            if isNearBottom != value {
                isNearBottom = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: TranscriptScrollProbeView, context: Context) {
        nsView.threshold = threshold
        nsView.onNearBottomChange = { value in
            if isNearBottom != value {
                isNearBottom = value
            }
        }
        nsView.scheduleAttachmentAndAssessment()
    }
}

@MainActor
final class TranscriptScrollProbeView: NSView {
    var threshold: CGFloat = 96
    var onNearBottomChange: ((Bool) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private weak var observedDocumentView: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAttachmentAndAssessment()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleAttachmentAndAssessment()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    func scheduleAttachmentAndAssessment() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(attachAndAssess),
            object: nil
        )
        perform(#selector(attachAndAssess), with: nil, afterDelay: 0)
    }

    @objc private func attachAndAssess() {
        guard let scrollView = enclosingScrollView else {
            // SwiftUI may not have attached the representable to the document
            // hierarchy yet. A later update/move callback retries.
            return
        }
        if observedScrollView !== scrollView || observedDocumentView !== scrollView.documentView {
            NotificationCenter.default.removeObserver(self)
            observedScrollView = scrollView
            observedDocumentView = scrollView.documentView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollGeometryChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            if let documentView = scrollView.documentView {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(scrollGeometryChanged),
                    name: NSView.frameDidChangeNotification,
                    object: documentView
                )
            }
        }
        assessNearBottom()
    }

    @objc private func scrollGeometryChanged() {
        // Coalesce token/layout bursts and publish on a later run-loop turn.
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(assessNearBottom),
            object: nil
        )
        perform(#selector(assessNearBottom), with: nil, afterDelay: 0)
    }

    @objc private func assessNearBottom() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        let bounds = documentView.bounds
        let distance: CGFloat
        if documentView.isFlipped {
            distance = max(0, bounds.maxY - visible.maxY)
        } else {
            distance = max(0, visible.minY - bounds.minY)
        }
        onNearBottomChange?(distance <= threshold || bounds.height <= visible.height)
    }
}
