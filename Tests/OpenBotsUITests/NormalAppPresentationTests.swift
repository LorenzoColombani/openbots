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
            XCTAssertTrue(ocrContains(text, "Keep the source notes together"), "Missing actual user body: \(text)")
            XCTAssertTrue(ocrContains(text, "The source notes are ready for review"), "Missing actual reply body: \(text)")
            XCTAssertTrue(ocrContains(text, "Ask about the source notes"), "Missing actual composer draft: \(text)")
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

    func testFailedClaudeTurnKeepsAcceptedInputAndSavedReplyProvenance() async throws {
        let teammate = TeammateRowSnapshot(id: normalAppID(131), name: "Ada", role: "Research partner",
            activity: .errorOrAttention, identitySeed: 14)
        // Production maps the terminal DB delivery state to this coarse failure
        // on both messages; separately loaded provenance says what reached Claude.
        var user = ChatMessageSnapshot(id: normalAppID(132), author: .user,
            body: "Check the helper arithmetic.", delivery: .failed("Local delivery failed."),
            timestamp: Date(timeIntervalSince1970: 1_788_000_000))
        user.deliveryNotice = "Accepted by Claude"
        var reply = ChatMessageSnapshot(id: normalAppID(133), author: .teammate(teammate.identity),
            body: "I will check the result.\n\nThe helper run could not finish.", delivery: .failed("Local delivery failed."),
            timestamp: Date(timeIntervalSince1970: 1_788_000_001))
        reply.deliveryNotice = "Claude turn failed · available reply text saved"
        let messages = [user, reply]
        let conversation = ConversationModel(conversationID: normalAppID(134), title: "Ada", messages: messages,
            composerText: "Keep this draft", isLocalOnly: false, textRepliesEnabled: true,
            inputAvailability: .ready, submit: { _, _, _ in XCTFail("Rendering must not submit work") })
        conversation.setTextReplyPhase(.failed(.runtimeUnavailable))
        for scheme in [ColorScheme.light, .dark] {
            let text = try await renderChatCleanupFixture(conversation: conversation, teammate: teammate, scheme: scheme,
                filename: "failed-turn-provenance-\(scheme == .light ? "light" : "dark").png")
            XCTAssertTrue(ocrContains(text, "Check the helper arithmetic"), "Accepted user content disappeared: \(text)")
            XCTAssertTrue(ocrContains(text, "I will check the result"), "Saved acknowledgement disappeared: \(text)")
            XCTAssertTrue(ocrContains(text, "The helper run could not finish"), "Failure content disappeared: \(text)")
            XCTAssertTrue(ocrContains(text, "Claude turn failed"), "The actual provider-run outcome disappeared: \(text)")
            XCTAssertTrue(ocrContains(text, "available reply text saved"), "Saved partial-reply provenance disappeared: \(text)")
            XCTAssertFalse(ocrContains(text, "Not sent"), "Accepted input or saved output was mislabeled as unsent: \(text)")
            XCTAssertFalse(ocrContains(text, "Local delivery failed"), "Coarse failure overrode authoritative provenance: \(text)")
            XCTAssertFalse(ocrContains(text, "Accepted by Claude"), "Routine acceptance chatter became visible: \(text)")
        }
        XCTAssertEqual(conversation.messages, messages, "Caption filtering must preserve the saved delivery metadata")
    }

    func testLocalSendFailureWithoutProvenanceKeepsItsActionableCaption() async throws {
        let teammate = TeammateRowSnapshot(id: normalAppID(135), name: "Ada", role: "Research partner",
            activity: .idle, identitySeed: 14)
        for localOnly in [true, false] {
            let message = ChatMessageSnapshot(id: normalAppID(136), author: .user,
                body: "Keep this unsaved note.", delivery: .failed("Disk is full."),
                timestamp: Date(timeIntervalSince1970: 1_788_000_000))
            let conversation = ConversationModel(conversationID: normalAppID(137), title: "Ada", messages: [message],
                composerText: "Recover this draft", isLocalOnly: localOnly,
                inputAvailability: .ready, submit: { _, _, _ in XCTFail("Rendering must not submit work") })
            let text = try await renderChatCleanupFixture(conversation: conversation, teammate: teammate, scheme: .light,
                filename: "local-failure-\(localOnly ? "saved" : "sent").png")
            XCTAssertTrue(ocrContains(text, "Keep this unsaved note"))
            XCTAssertTrue(ocrContains(text, "\(localOnly ? "Not saved" : "Not sent"): Disk is full."),
                "A real failure without provenance lost its actionable caption: \(text)")
            XCTAssertNil(conversation.messages.first?.deliveryNotice)
        }
    }

    func testPendingChatKeepsStopAndContextOmissionVisible() async throws {
        let teammate = TeammateRowSnapshot(id: normalAppID(121), name: "Ada", role: "Research partner",
            activity: .speaking, identitySeed: 14)
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
        XCTAssertTrue(ocrContains(text, "Please check the source notes"), "Missing actual pending message: \(text)")
        XCTAssertTrue(ocrContains(text, "Keep this draft while waiting"), "Missing composer content: \(text)")
        XCTAssertFalse(ocrContains(text, "Receiving response"), "Normal transport chatter should give way to the working avatar: \(text)")
        XCTAssertTrue(ocrContains(text, "Ada"), "The working bot must stay named: \(text)")
        XCTAssertTrue(text.split(separator: " ").contains("Stop"), "Stop control disappeared from pixels: \(text)")
        XCTAssertTrue(ocrContains(text, "Some earlier messages or saved memory were not included"), "Context omission warning disappeared: \(text)")
        XCTAssertEqual(conversation.messages, [message])
        XCTAssertEqual(conversation.textReplyPhase, .responding)
        XCTAssertEqual(conversation.textReplyContextDisclosure, disclosure)
        // Send stays live while a bot works; typed text is the correction.
        XCTAssertTrue(conversation.canSend)
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
        // UI automation finds Stop by this name (an offscreen render exposes no
        // accessibility tree to search); a regression once took this control away.
        XCTAssertTrue(rootSource.contains(".accessibilityIdentifier(\"reply.stop\")"))
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
                    ocrContains(renderedText, "Local only"),
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

    func testClaudeSetupOffersOneExplicitClaudeCheckWithoutAutomaticAuthentication() async throws {
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
            XCTAssertTrue(ocrContains(text, "Claude connection not checked"), "Missing honest setup state: \(text)")
            XCTAssertTrue(ocrContains(text, "Check Claude"), "Missing explicit connection check: \(text)")
            XCTAssertTrue(ocrContains(text, "It does not sign you in or send saved messages"), "Local checks must remain distinct from authentication: \(text)")
            XCTAssertTrue(ocrContains(text, "You can create and choose bots"), "Missing available local actions: \(text)")
            XCTAssertTrue(ocrContains(text, "not sent later by themselves"), "Local saves must not imply deferred sending: \(text)")
            XCTAssertTrue(ocrContains(text, "Older sample messages and saved demo outcomes keep their original labels"))
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
        XCTAssertTrue(ocrContains(text, "Try Opening Again"), "Missing normal recovery action in rendered pixels: \(text)")
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

    /// Details names the model the last saved reply reported and the preferences it was
    /// requested with, and keeps saying what Claude does not report back.
    func testDetailsNamesTheSavedResultModelAndItsRequestedPreferences() async throws {
        var status = ClaudeModelRunPresentation()
        status.requested = "claude-opus-5"
        status.observedAtStart = "claude-opus-5"
        status.confirmedRequest = "claude-opus-5"
        status.confirmedModel = "claude-opus-5"
        status.confirmedEffort = "low"
        status.confirmedContextWindow = "standard"
        status.isFromSavedRecord = true
        let controller = NSHostingController(rootView: ClaudeModelStatusView(
            savedChoice: "claude-opus-5", savedEffort: "low", savedContextWindow: "standard", status: status
        ).padding(16).frame(width: 420))
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        try await settle(controller.view)
        let text = try captureRenderedText(controller.view, filename: "normal-details-saved-model-420.png")
        XCTAssertTrue(ocrContains(text, "Last saved result reported"), "Missing the saved result line: \(text)")
        XCTAssertTrue(ocrContains(text, "Opus 5"), "Missing the model name: \(text)")
        XCTAssertTrue(ocrContains(text, "requested with Low"), "Missing the requested intensity: \(text)")
        XCTAssertTrue(ocrContains(text, "Claude reports"), "Missing the honesty line: \(text)")
    }

    /// A database that will not open offers the verified local backups; a newer workspace never does.
    func testRecoveryOffersVerifiedBackupsOnlyForOpenAndCheckFailures() async throws {
        let options = [
            LaunchRecoveryRestoreOption(id: "a", title: "Backup from Sep 6, 2026 at 22:10", detail: "schema 21 · 1.5 MB · on quit"),
            LaunchRecoveryRestoreOption(id: "b", title: "Backup from Sep 6, 2026 at 21:10", detail: "schema 21 · 1.4 MB · hourly")
        ]
        for (issue, expectsRestore) in [(LaunchRecoveryIssue.databaseOpenFailed, true),
                                         (.databaseValidationFailed, true),
                                         (.workspaceNewerThanApplication, false)] {
            let inspector = NormalAppReadinessCounter()
            let model = LaunchReadinessModel(inspector: inspector)
            model.setPreviewReviewState(.recovery(issue))
            var restored: [String] = []
            let controller = NSHostingController(rootView: LaunchStatusView(
                model: model, performsAutomaticRefresh: false, isApplicationStartup: true,
                retryAction: {}, restoreOptions: options, restoreAction: { restored.append($0.id) }, continueAction: {}
            ))
            controller.view.frame = CGRect(x: 0, y: 0, width: 620, height: 720)
            try await settle(controller.view)
            let text = try captureRenderedText(controller.view, filename: "normal-startup-recovery-restore-\(issue.rawValue)-620.png")
            XCTAssertEqual(ocrContains(text, "Restore a local backup"), expectsRestore, "\(issue): \(text)")
            XCTAssertEqual(ocrContains(text, "22:10"), expectsRestore, "\(issue): \(text)")
            XCTAssertTrue(ocrContains(text, "Try Opening Again"), "\(issue): \(text)")
            XCTAssertTrue(restored.isEmpty, "rendering must not restore anything")
            XCTAssertFalse(text.contains("Delete"))
        }
    }

    /// The one recovery case with a fix the reader can act on names it: open the newer copy.
    func testNewerWorkspaceRecoveryNamesTheNewerCopy() async throws {
        let inspector = NormalAppReadinessCounter()
        let model = LaunchReadinessModel(inspector: inspector)
        model.setPreviewReviewState(.recovery(.workspaceNewerThanApplication))
        let controller = NSHostingController(rootView: LaunchStatusView(
            model: model, performsAutomaticRefresh: false, isApplicationStartup: true,
            retryAction: {}, continueAction: {}
        ))
        controller.view.frame = CGRect(x: 0, y: 0, width: 560, height: 560)
        try await settle(controller.view)
        let text = try captureRenderedText(controller.view, filename: "normal-startup-recovery-newer-workspace-560.png")
        XCTAssertTrue(ocrContains(text, "older than your workspace"), "Missing the cause in rendered pixels: \(text)")
        XCTAssertTrue(ocrContains(text, "Applications"), "Missing the way out in rendered pixels: \(text)")
        XCTAssertFalse(text.contains("Reset"))
        XCTAssertFalse(text.contains("Delete"))
        XCTAssertEqual(model.state, .recovery(.workspaceNewerThanApplication))
        let inspectionCount = await inspector.calls
        XCTAssertEqual(inspectionCount, 0)
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

    /// Vision on 1x CI displays drops or merges spaces ("Localonly", "earller"). Phrase checks compare
    /// with all whitespace removed; word-level checks (e.g. "Stop") stay exact.
    private func ocrContains(_ rendered: String, _ phrase: String) -> Bool {
        // macOS 26's Vision reads small grey "i" as "l" ("Claude turn falled - avallable"),
        // so the three look-alike strokes count as one letter.
        func squash(_ s: String) -> String {
            String(s.filter { !$0.isWhitespace }.lowercased().map { "l1|".contains($0) ? "i" : $0 })
        }
        return squash(rendered).contains(squash(phrase))
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
        // Capture above Retina density regardless of the host display. At 1x Vision misreads
        // small UI text ("earller", "Ston"). At 2x it read macOS 27's recovery button as
        // "Try Opening Aaain": that release draws the dark bezel lighter (#4d4d4d, was #404040
        // on macOS 26), and the lower contrast turns the "g" into an "a". The glyphs are unchanged.
        let scale: CGFloat = 3
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(bitmap.pixelsWide, Int(host.bounds.width * scale))
        // A view without its own background captures on transparent pixels, and
        // macOS 26's Vision read nothing from grey text there. Lay the capture on the
        // window background of the view's own appearance, as a window would show it.
        let flattened = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        flattened.size = host.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: flattened))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: host.bounds.size).fill()
        }
        // Over, not copy: `draw(in:)` alone copies, which replaced the background
        // with the capture's own transparent pixels (seen in the macos-26 evidence).
        bitmap.draw(in: NSRect(origin: .zero, size: host.bounds.size), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(flattened.representation(using: .png, properties: [:]))
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
