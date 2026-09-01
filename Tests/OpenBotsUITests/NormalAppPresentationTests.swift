import AppKit
import Foundation
import OpenBotsServices
import SwiftUI
import Vision
import XCTest
@testable import OpenBotsUI

/// Synthetic native rendering only. The root uses an owned, never-visible
/// window so NavigationSplitView can materialize. Nothing activates an app,
/// inspects another process, opens storage, requests credentials or submits work.
/// The hidden host proves the observed conversation content and controls only;
/// it does not establish complete sidebar layout or physical accessibility.
@MainActor
final class NormalAppPresentationTests: XCTestCase {
    func testCompletedChatHidesRoutineNoticesWithoutDiscardingMetadata() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let teammate = TeammateRowSnapshot(id: normalAppID(101), name: "Ada", role: "Research partner",
                activity: .idle, identitySeed: 14)
            var user = ChatMessageSnapshot(id: normalAppID(110), author: .user,
                body: "Keep the source notes together.", delivery: .sent,
                timestamp: Date(timeIntervalSince1970: 1_788_000_000))
            user.deliveryNotice = "Accepted by Claude"
            var reply = ChatMessageSnapshot(id: normalAppID(111), author: .teammate(teammate.identity),
                body: "The source notes are ready for review.", delivery: .sent,
                timestamp: Date(timeIntervalSince1970: 1_788_000_001))
            reply.deliveryNotice = "Claude reply saved"
            let messages = [user, reply]
            let draft = "Ask about the source notes."
            let disclosure = ClaudeContextDisclosure(includedMessageCount: 2, includedMemoryDocumentCount: 1)
            let policy = DurableWorkspaceModel.textReplyDeliveryDescription
            let submissions = NormalAppSubmissionCounter()
            var stopCount = 0
            let conversation = ConversationModel(conversationID: normalAppID(102), title: teammate.name,
                messages: messages, composerText: draft, readyDeliveryDescription: policy,
                isLocalOnly: false, textRepliesEnabled: true, stopTextReply: { stopCount += 1 },
                inputAvailability: .ready, submit: { _, _, _ in await submissions.record() })
            conversation.setTextReplyPhase(.completed)
            conversation.setTextReplyContextDisclosure(disclosure)
            let rowIdentities = conversation.messageRows.map(ObjectIdentifier.init)

            let text = try await renderChatCleanupFixture(conversation: conversation, teammate: teammate,
                scheme: scheme, filename: "chat-cleanup-completed-\(scheme == .dark ? "dark" : "light")-1080.png")
            XCTAssertTrue(text.contains("Keep the source notes together"), "Missing actual user body: \(text)")
            XCTAssertTrue(text.contains("The source notes are ready for review"), "Missing actual reply body: \(text)")
            XCTAssertTrue(text.contains("Ask about the source notes"), "Missing actual composer draft: \(text)")
            for forbidden in ["Accepted by Claude", "Claude reply saved", "Prepared context:", "Read-only",
                              "Reply saved.", "Memory questions and explicit memory updates",
                              "Attachments, tools and connectors are not sent"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "Routine notice remains in rendered pixels: \(forbidden); \(text)")
            }
            XCTAssertEqual(conversation.messages, messages)
            XCTAssertEqual(conversation.messages.map(\.deliveryNotice), ["Accepted by Claude", "Claude reply saved"])
            XCTAssertEqual(conversation.messageRows.map(ObjectIdentifier.init), rowIdentities)
            XCTAssertEqual(conversation.textReplyPhase, .completed)
            XCTAssertEqual(conversation.textReplyContextDisclosure, disclosure)
            XCTAssertEqual(conversation.readyDeliveryDescription, policy)
            XCTAssertEqual(conversation.composerText, draft)
            XCTAssertTrue(conversation.canSend)
            let submissionCount = await submissions.count
            XCTAssertEqual(submissionCount, 0)
            XCTAssertEqual(stopCount, 0)
        }
    }

    func testPendingChatKeepsStopAndContextOmissionVisible() async throws {
        let teammate = TeammateRowSnapshot(id: normalAppID(121), name: "Ada", role: "Research partner",
            activity: .idle, identitySeed: 14)
        let message = ChatMessageSnapshot(id: normalAppID(122), author: .user,
            body: "Please check the source notes.", delivery: .pending,
            timestamp: Date(timeIntervalSince1970: 1_788_000_000))
        let submissions = NormalAppSubmissionCounter()
        var stopCount = 0
        let disclosure = ClaudeContextDisclosure(includedMessageCount: 2, includedMemoryDocumentCount: 1,
            omittedForReadLimit: true)
        let conversation = ConversationModel(conversationID: normalAppID(123), title: teammate.name,
            messages: [message], composerText: "Keep this draft while waiting.",
            readyDeliveryDescription: DurableWorkspaceModel.textReplyDeliveryDescription,
            isLocalOnly: false, textRepliesEnabled: true, stopTextReply: { stopCount += 1 },
            inputAvailability: .ready, submit: { _, _, _ in await submissions.record() })
        conversation.setTextReplyPhase(.responding)
        conversation.setTextReplyContextDisclosure(disclosure)
        let text = try await renderChatCleanupFixture(conversation: conversation, teammate: teammate,
            scheme: .light, filename: "chat-cleanup-pending-context-omitted-light-1080.png")
        XCTAssertTrue(text.contains("Please check the source notes"), "Missing actual pending message: \(text)")
        XCTAssertTrue(text.contains("Keep this draft while waiting"), "Missing composer content: \(text)")
        XCTAssertTrue(text.contains("Receiving response"), "Busy state disappeared: \(text)")
        XCTAssertTrue(text.split(separator: " ").contains("Stop"), "Stop control disappeared from pixels: \(text)")
        XCTAssertTrue(text.contains("Some earlier messages or saved memory were not included"), "Context omission warning disappeared: \(text)")
        XCTAssertEqual(conversation.messages, [message])
        XCTAssertEqual(conversation.textReplyPhase, .responding)
        XCTAssertEqual(conversation.textReplyContextDisclosure, disclosure)
        XCTAssertFalse(conversation.canSend)
        let submissionCount = await submissions.count
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(stopCount, 0)
    }

    func testLocalWorkspacePreservesSavedLabelsAndOffersOnlyLocalSubmission() async throws {
        _ = NSApplication.shared
        let rootSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/OpenBotsRootView.swift")
        let rootSource = try String(contentsOf: rootSourceURL, encoding: .utf8)
        XCTAssertTrue(rootSource.contains(".accessibilityLabel(conversation.submissionActionTitle)"))
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [840, 1_080] {
                let teammate = TeammateRowSnapshot(
                    id: normalAppID(1), name: "Ada", role: "Research partner",
                    activity: .idle, identitySeed: 14
                )
                let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
                let legacyLabel = "Earlier sample reply — local preview fixture; Claude did not run."
                let messages = [
                    ChatMessageSnapshot(
                        id: normalAppID(10), author: .user,
                        body: "Keep the source notes together for our next review.",
                        delivery: .sent, timestamp: Date(timeIntervalSince1970: 1_788_000_000)
                    ),
                    ChatMessageSnapshot(
                        id: normalAppID(11), author: .system(label: "Saved preview sample"),
                        body: legacyLabel, delivery: .sent,
                        timestamp: Date(timeIntervalSince1970: 1_788_000_001)
                    )
                ]
                let draft = "A local note to keep with Ada’s conversation."
                let submissions = NormalAppSubmissionCounter()
                var unrelatedActions = 0
                let conversation = ConversationModel(
                    conversationID: normalAppID(2), title: teammate.name, messages: messages,
                    composerText: draft,
                    readyDeliveryDescription: DurableWorkspaceModel.localDeliveryDescription,
                    isLocalOnly: true, inputAvailability: .ready,
                    submit: { _, _, _ in await submissions.record() }
                )
                let rowIdentities = conversation.messageRows.map(ObjectIdentifier.init)
                let root = OpenBotsRootView(
                    sidebar: sidebar, conversation: conversation,
                    createTeammate: { unrelatedActions += 1 },
                    openSettings: { unrelatedActions += 1 }
                )
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                let controller = NSHostingController(rootView: root)
                controller.sizingOptions = []
                let size = CGSize(width: width, height: 720)
                let window = NormalAppRenderWindow(
                    contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentViewController = controller
                let owner = NSWindowController(window: window)
                defer {
                    window.contentViewController = nil
                    owner.close()
                }
                window.setContentSize(size)
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                try await settle(controller.view)

                let visible = descendants(controller.view).filter { !$0.isHiddenOrHasHiddenAncestor }
                let composer = try XCTUnwrap(visible.first { view in
                    if let field = view as? NSTextField { return field.isEditable && field.stringValue == draft }
                    if let text = view as? NSTextView { return text.isEditable && text.string == draft }
                    return false
                }, "A blank root render is not evidence of the local workspace.")
                assertWithinViewport(composer, host: controller.view)
                let savedLabel = try XCTUnwrap(visible.compactMap { $0 as? NSTextField }.first {
                    !$0.isEditable && $0.stringValue == legacyLabel
                }, "Already-saved sample labels must stay visible and unchanged.")
                XCTAssertTrue(savedLabel.isSelectable)
                let renderedText = try captureRenderedText(
                    controller.view,
                    filename: "normal-workspace-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"
                )
                XCTAssertTrue(
                    renderedText.contains("Local only"),
                    "Missing the visible local-delivery disclosure: \(renderedText)"
                )
                XCTAssertFalse(renderedText.contains("Send message"))
                assertNoDevelopmentControls(in: controller.view, renderedText: renderedText)
                XCTAssertTrue(conversation.isLocalOnly)
                XCTAssertEqual(conversation.submissionActionTitle, "Save Message")
                XCTAssertTrue(conversation.canSend)
                XCTAssertEqual(conversation.composerText, draft)
                XCTAssertEqual(conversation.messages, messages)
                XCTAssertEqual(conversation.messageRows.map(ObjectIdentifier.init), rowIdentities)
                XCTAssertEqual(sidebar.selection, teammate.id)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertTrue(window.sheets.isEmpty)
                let submissionCount = await submissions.count
                XCTAssertEqual(submissionCount, 0)
                XCTAssertEqual(unrelatedActions, 0)
            }
        }
    }

    func testClaudeSetupOffersAnExplicitLocalCheckWithoutAutomaticAuthentication() async throws {
        for (width, scheme) in [(CGFloat(460), ColorScheme.light), (CGFloat(620), ColorScheme.dark)] {
            let controller = NSHostingController(rootView: ClaudeSetupView()
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US_POSIX")))
            controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 720)
            try await settle(controller.view)
            let fit = controller.sizeThatFits(in: CGSize(width: width, height: 720))
            XCTAssertTrue(fit.width.isFinite && fit.height.isFinite)
            XCTAssertGreaterThan(fit.height, 0)
            XCTAssertLessThanOrEqual(fit.width, width + 1)
            XCTAssertNil(controller.view.window)
            let text = try captureRenderedText(
                controller.view,
                filename: "claude-setup-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"
            )
            XCTAssertTrue(text.contains("Subscription access not verified"), "Missing honest setup state: \(text)")
            XCTAssertTrue(text.contains("Check Installation"), "Missing explicit local setup action: \(text)")
            XCTAssertTrue(text.contains("It does not sign you in or send saved messages"), "Local checks must remain distinct from authentication: \(text)")
            XCTAssertTrue(text.contains("Live replies and tools remain unavailable"), "Missing live-runtime limitation: \(text)")
            XCTAssertTrue(text.contains("not queued for automatic sending later"), "Local saves must not imply deferred sending: \(text)")
            XCTAssertTrue(text.contains("Older sample messages and saved demo outcomes keep their original labels"))
            XCTAssertFalse(text.contains("Development review mode"))
            assertNoDevelopmentControls(in: controller.view, renderedText: text)
            let controls = descendants(controller.view).compactMap { $0 as? NSControl }
            XCTAssertFalse(controls.contains { $0 is NSSecureTextField })
            let actionLabels = nativeLabels(in: controller.view)
            for forbidden in ["Sign In", "Log In", "Authenticate", "Run Claude"] {
                XCTAssertFalse(actionLabels.contains(forbidden), "This build must not offer an unimplemented credential action.")
                XCTAssertFalse(text.contains(forbidden), "This build must not render an unimplemented credential action.")
            }
        }
    }

    func testApplicationRecoveryRendersWithoutInspectingOrChangingData() async throws {
        let inspector = NormalAppReadinessCounter()
        let model = LaunchReadinessModel(inspector: inspector)
        model.setPreviewReviewState(.recovery(.databaseValidationFailed))
        var retryCount = 0
        var continueCount = 0
        let controller = NSHostingController(rootView: LaunchStatusView(
            model: model, performsAutomaticRefresh: false, isApplicationStartup: true,
            retryAction: { retryCount += 1 }, continueAction: { continueCount += 1 }
        ))
        controller.view.frame = CGRect(x: 0, y: 0, width: 560, height: 560)
        try await settle(controller.view)
        let text = try captureRenderedText(controller.view, filename: "normal-startup-recovery-560.png")
        XCTAssertTrue(text.contains("Try Opening Again"), "Missing normal recovery action in rendered pixels: \(text)")
        XCTAssertFalse(text.contains("Retry Check"))
        XCTAssertFalse(text.contains("Reset"))
        XCTAssertFalse(text.contains("Delete"))
        XCTAssertFalse(text.contains("Local preview readiness"))
        XCTAssertEqual(model.state, .recovery(.databaseValidationFailed))
        let inspectionCount = await inspector.calls
        XCTAssertEqual(inspectionCount, 0)
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(continueCount, 0)
        XCTAssertNil(controller.view.window)
    }

    private func renderChatCleanupFixture(conversation: ConversationModel, teammate: TeammateRowSnapshot,
        scheme: ColorScheme, filename: String) async throws -> String {
        _ = NSApplication.shared
        let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
        var unrelatedActions = 0
        let controller = NSHostingController(rootView: OpenBotsRootView(sidebar: sidebar, conversation: conversation,
            createTeammate: { unrelatedActions += 1 }, openSettings: { unrelatedActions += 1 })
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX")))
        controller.sizingOptions = []
        let size = CGSize(width: 1_080, height: 720)
        let window = NormalAppRenderWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        window.setContentSize(size)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        try await settle(controller.view)
        let composer = try XCTUnwrap(descendants(controller.view).first { view in
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if let field = view as? NSTextField { return field.isEditable && field.stringValue == conversation.composerText }
            if let text = view as? NSTextView { return text.isEditable && text.string == conversation.composerText }
            return false
        }, "The real composer must materialize; empty root pixels cannot pass.")
        assertWithinViewport(composer, host: controller.view)
        let text = try captureRenderedText(controller.view, filename: filename)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(window.sheets.isEmpty)
        XCTAssertEqual(sidebar.selection, teammate.id)
        XCTAssertEqual(unrelatedActions, 0)
        return text
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(view.bounds.width.isFinite && view.bounds.height.isFinite)
        XCTAssertGreaterThan(view.bounds.width, 0)
        XCTAssertGreaterThan(view.bounds.height, 0)
    }

    private func assertWithinViewport(_ view: NSView, host: NSView) {
        let rect = view.convert(view.bounds, to: host)
        XCTAssertTrue(rect.width.isFinite && rect.height.isFinite)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        XCTAssertLessThanOrEqual(rect.maxX, host.bounds.width + 1)
        XCTAssertGreaterThanOrEqual(rect.minY, -1)
        XCTAssertLessThanOrEqual(rect.maxY, host.bounds.height + 1)
    }

    private func assertNoDevelopmentControls(in host: NSView, renderedText: String) {
        let labels = nativeLabels(in: host)
        for forbidden in ["Handoff outcome", "Returned result", "Needs recovery", "Demo action",
                          "Prepare Demo Proposal", "Approve Demo Proposal", "Development review mode",
                          "Start Demo Run", "Grant Demo Access"] {
            XCTAssertFalse(labels.contains(forbidden), "Normal presentation contains development control: \(forbidden)")
            XCTAssertFalse(renderedText.contains(forbidden), "Normal pixels contain development control: \(forbidden)")
        }
        for popup in descendants(host).compactMap({ $0 as? NSPopUpButton }) {
            XCTAssertFalse(popup.itemTitles.contains("Returned result"))
            XCTAssertFalse(popup.itemTitles.contains("Needs recovery"))
        }
    }

    private func nativeLabels(in host: NSView) -> [String] {
        descendants(host).flatMap { view -> [String] in
            var values = [view.accessibilityLabel() ?? ""]
            if let button = view as? NSButton { values.append(button.title) }
            if let popup = view as? NSPopUpButton { values.append(contentsOf: popup.itemTitles) }
            return values.filter { !$0.isEmpty }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    /// SwiftUI virtual Text/Button nodes are absent from this windowless
    /// host's native accessibility children. Read the captured pixels through
    /// built-in, offline Vision instead of treating missing nodes as success.
    /// Positive required text prevents a blank render/OCR result from passing.
    private func captureRenderedText(_ host: NSView, filename: String) throws -> String {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/current-state-app-evidence-20260830/rendered", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000, "An empty image is not render evidence.")
        // Preserve the original failing observation's images as evidence.
        let destination = directory.appendingPathComponent("ocr-" + filename)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let recognition = VNRecognizeTextRequest()
        // Keep local pixel assertions independent of GPU/ANE availability
        // in the command-line test host.
        recognition.usesCPUOnly = true
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(data: data, options: [:]).perform([recognition])
        let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: " ")
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertFalse(text.isEmpty, "Rendered text recognition must materialize actual pixels.")
        let receipt = destination.deletingPathExtension().appendingPathExtension("txt")
        try lines.joined(separator: "\n").write(to: receipt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return text
    }
}

@MainActor
private final class NormalAppRenderWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private actor NormalAppSubmissionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor NormalAppReadinessCounter: LaunchReadinessInspecting {
    private(set) var calls = 0
    func inspectReadiness() async -> LaunchReadinessState {
        calls += 1
        return .ready
    }
}

private func normalAppID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "AA910000-0000-0000-0000-%012llx", suffix))!
}
