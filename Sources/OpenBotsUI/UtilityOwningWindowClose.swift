import AppKit
import Combine
import SwiftUI

/// A weak, view-attached close target. Never consults the app's key/main window.
@MainActor
final class UtilityOwningWindowClose: ObservableObject {
    @Published private var attachmentRevision: UInt = 0
    var isAttached: Bool { window != nil }
    private(set) weak var window: NSWindow?
    private var attachmentID: ObjectIdentifier?

    func attach(_ window: NSWindow, from owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        guard self.window !== window || attachmentID != ownerID else { return }
        self.window = window
        attachmentID = ownerID
        publishAttachmentChange()
    }

    func detach(from owner: AnyObject) {
        guard attachmentID == ObjectIdentifier(owner) else { return }
        window = nil
        attachmentID = nil
        publishAttachmentChange()
    }

    func close() {
        // performClose honors this window's native delegate and close policy.
        // Retained Settings content stays attached when its window closes.
        // Only its actual detach or rebind changes the close target.
        window?.performClose(nil)
    }

    private func publishAttachmentChange() {
        // Native view attachment can happen during a SwiftUI graph update.
        // Keep ownership exact immediately; refresh the control afterward.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.attachmentRevision &+= 1
        }
    }
}

@MainActor
struct UtilitySettingsWindowAttachment: NSViewRepresentable {
    let closeTarget: UtilityOwningWindowClose

    func makeNSView(context: Context) -> Reporter {
        Reporter(closeTarget: closeTarget)
    }

    func updateNSView(_ nsView: Reporter, context: Context) {}

    static func dismantleNSView(_ nsView: Reporter, coordinator: ()) {
        nsView.closeTarget.detach(from: nsView)
    }

    final class Reporter: NSView {
        let closeTarget: UtilityOwningWindowClose

        init(closeTarget: UtilityOwningWindowClose) {
            self.closeTarget = closeTarget
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { closeTarget.attach(window, from: self) }
            else { closeTarget.detach(from: self) }
        }
    }
}
