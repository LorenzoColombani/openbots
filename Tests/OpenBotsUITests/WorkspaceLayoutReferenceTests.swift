import AppKit
import Darwin
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Native view geometry in an owned, never-ordered window. This does not
/// exercise physical input, toolbar clicks, VoiceOver, or the installed app.
@MainActor
final class ReferenceWorkspaceLayoutTests: XCTestCase {
    private static let childFlag = "OPENBOTS_REFERENCE_LAYOUT_CHILD"
    private static let completed = "OPENBOTS_REFERENCE_LAYOUT_COMPLETED"

    func testLocalWorkspaceComposerAndDetailsFitAndPreserveNativeEditing() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            for scheme: ColorScheme in [.light, .dark] { try await exerciseLayout(scheme: scheme) }
            referenceLayoutLog(Self.completed)
            return
        }
        try await runBoundedChild(method: "testLocalWorkspaceComposerAndDetailsFitAndPreserveNativeEditing")
    }

    func testMessageBubblesAndAttachmentCardFitNarrowAndWideChat() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try await exerciseMessageLayout()
            referenceLayoutLog(Self.completed)
            return
        }
        try await runBoundedChild(method: "testMessageBubblesAndAttachmentCardFitNarrowAndWideChat")
    }

    func testLongNameConversationHeaderFitsWithoutChangingChatState() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            for scheme: ColorScheme in [.light, .dark] { try await exerciseHeaderLayout(scheme: scheme) }
            referenceLayoutLog(Self.completed)
            return
        }
        try await runBoundedChild(method: "testLongNameConversationHeaderFitsWithoutChangingChatState")
    }

    func testActualSidebarHoverFillsRowInsetsWithoutExpandingInteraction() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            for scheme: ColorScheme in [.light, .dark] { try await exerciseSidebarHoverLayout(scheme: scheme) }
            referenceLayoutLog(Self.completed)
            return
        }
        try await runBoundedChild(method: "testActualSidebarHoverFillsRowInsetsWithoutExpandingInteraction")
    }

    private func runBoundedChild(method: String) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest",
            "OpenBotsUITests.ReferenceWorkspaceLayoutTests/\(method)",
            Bundle(for: Self.self).bundleURL.path]
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment[Self.childFlag] = "1"
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        try output.fileHandleForWriting.close()
        let log = ReferenceLayoutChildLog(reader: output.fileHandleForReading)
        log.start()
        let deadline = Date(timeIntervalSinceNow: 20)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let timedOut = child.isRunning
        if timedOut {
            child.terminate()
            let grace = Date(timeIntervalSinceNow: 1)
            while child.isRunning, Date() < grace { try await Task.sleep(for: .milliseconds(10)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let receipt = log.finish()
        let receiptURL = try referenceLayoutEvidenceDirectory().appendingPathComponent("native-\(UUID()).log")
        try receipt.write(to: receiptURL, atomically: true, encoding: .utf8)
        referenceLayoutLog("receipt: \(receiptURL.path)")
        XCTAssertFalse(timedOut, "Native Reference layout exceeded its child deadline. \(receipt)")
        XCTAssertEqual(child.terminationStatus, 0, receipt)
        XCTAssertTrue(receipt.contains(Self.completed), "Missing complete layout exercise. \(receipt)")
    }

    private func exerciseMessageLayout() async throws {
        _ = NSApplication.shared
        let timestamp = Date(timeIntervalSince1970: 1_788_000_000)
        let roster = ["Ada Research", "Mira Writing", "Rook Review"].enumerated().map { index, name in
            TeammateRowSnapshot(id: UUID(), name: name, role: "Explicit local render fixture", activity: .idle,
                                identitySeed: UInt64(index + 21), unreadCount: index == 2 ? 2 : 0,
                                lastActivityAt: timestamp.addingTimeInterval(Double(index * 60)))
        }
        let sidebar = SidebarModel(rows: roster, selection: roster[0].id)
        let incoming = "I compared the source notes and kept the original wording where it matters. The summary separates confirmed observations from open questions, so you can review the evidence before deciding what to do next. Nothing has been sent or published."
        let outgoing = "Please check this summary and flag anything that needs a better source."
        let fileName = "Research-summary-local-fixture.pdf"
        let attachment = ChatAttachmentSnapshot(id: UUID(), displayName: fileName,
                                                detail: "Render fixture only · no file imported")
        let messages = [
            ChatMessageSnapshot(id: UUID(), author: .teammate(roster[0].identity), body: incoming,
                                delivery: .sent, timestamp: timestamp),
            ChatMessageSnapshot(id: UUID(), author: .user, parts: [
                ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: .text(outgoing)),
                ChatMessagePartSnapshot(id: UUID(), ordinal: 1, content: .attachment(attachment))
            ], delivery: .sent, timestamp: timestamp.addingTimeInterval(60))
        ]
        let draft = "Add a source note"
        let submissions = ReferenceRenderSubmissionCounter()
        let conversationID = UUID()
        // Metadata-only adapter: no file is imported, opened or revealed. This
        // mounts the real card's guarded native controls for observation.
        let asset = try AttachmentAsset(id: AttachmentID(attachment.id), conversationID: ConversationID(conversationID),
                                        displayName: fileName, typeIdentifier: "com.adobe.pdf", byteCount: 2048,
                                        sha256: String(repeating: "a", count: 64), createdAt: timestamp)
        let attachmentUI = AttachmentPresentation(resolve: { messageID, partID, attachmentID in
            guard messageID == messages[1].id, partID == messages[1].parts[1].id,
                  attachmentID == attachment.id else { return nil }
            return asset
        }, reveal: { _, _, _ in
            XCTFail("A hidden accessibility observation must not reveal any file")
        }, preview: { _, _, _, _ in
            XCTFail("A hidden accessibility observation must not preview any file")
            throw CancellationError()
        })
        let conversation = ConversationModel(
            conversationID: conversationID, title: roster[0].name, messages: messages, composerText: draft,
            readyDeliveryDescription: "Explicit render fixtures only; no provider or file operation.",
            isLocalOnly: true, inputAvailability: .ready,
            submit: { _, _, _ in await submissions.record() }
        )
        var unintendedActions = 0
        let root = OpenBotsRootView(
            sidebar: sidebar, conversation: conversation,
            createTeammate: { unintendedActions += 1 }, openSettings: { unintendedActions += 1 },
            openSearch: { unintendedActions += 1 }
        ).environment(\.colorScheme, .dark)
            .environment(\.attachmentPresentation, attachmentUI)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .minSize
        let window = ReferenceLayoutWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        configureReferenceIntegratedTitlebar(window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        for width: CGFloat in [720, 1_080] {
            window.setContentSize(CGSize(width: width, height: 720))
            controller.view.frame.size = CGSize(width: width, height: 720)
            try await settleReferenceLayout(controller.view)
            let content = try XCTUnwrap(window.contentView)
            let descendants = content.referenceLayoutDescendants
            let rosterTable = try XCTUnwrap(descendants.compactMap { $0 as? NSTableView }.first)
            XCTAssertEqual(rosterTable.numberOfRows, 3)
            XCTAssertEqual(rosterTable.selectedRow, 0, "The native List retains its actual selected row")
            assertContained(try XCTUnwrap(rosterTable.enclosingScrollView), in: content)
            for value in [incoming, outgoing] {
                let text = try XCTUnwrap(descendants.compactMap { $0 as? NSTextField }.first {
                    !$0.isEditable && $0.isSelectable && $0.stringValue.utf8.elementsEqual(value.utf8)
                }, "The actual selectable incoming and outgoing bubble text must render")
                assertContained(text, in: content)
                XCTAssertGreaterThanOrEqual(text.convert(text.bounds, to: content).minX, 281)
            }
            assertContained(referenceEditorViewport(try XCTUnwrap(referenceNativeEditor(in: content, text: draft))), in: content)
            // SwiftUI's card labels may be virtual rather than NSTextFields in
            // a hidden host. In that case the required PNG carries the card's
            // appearance evidence; no physical/AX or asset-success claim follows.
            let nativeCardLabels = descendants.compactMap { $0 as? NSTextField }.filter { $0.stringValue == fileName }
            for label in nativeCardLabels { assertContained(label, in: content) }
            referenceLayoutLog("message layout width=\(width), roster=\(rosterTable.numberOfRows), native file labels=\(nativeCardLabels.count)")
            XCTAssertEqual(conversation.messages, messages)
            XCTAssertTrue(conversation.composerText.utf8.elementsEqual(draft.utf8))
            XCTAssertEqual(sidebar.selection, roster[0].id)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertTrue(window.sheets.isEmpty)
            XCTAssertEqual(content.bounds.width, width, accuracy: 1)
            try captureReferenceLayout(content, name: "reference-messages-dark-\(Int(width)).png")
        }
        XCTAssertEqual(unintendedActions, 0)
        let submissionCount = await submissions.count
        XCTAssertEqual(submissionCount, 0)
        // The first bounded run omitted SwiftUI's conversation tree at both
        // 720 and 1080 points. Preserve those receipts; do not repeat that
        // unchanged probe in a geometry regression or count it as a tree pass.
        referenceLayoutLog("AX UNVERIFIED: message/attachment reachability was not tested here; later native full-tree/read/control acceptance is required")
    }

    private func exerciseSidebarHoverLayout(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let selected = TeammateRowSnapshot(id: UUID(), name: "Ada", role: "Synthetic fixture",
                                          activity: .idle, identitySeed: 21)
        let target = TeammateRowSnapshot(id: UUID(), name: "Mira", role: "Synthetic fixture",
                                        activity: .idle, identitySeed: 22)
        let sidebar = SidebarModel(rows: [selected, target], selection: selected.id)
        let message = ChatMessageSnapshot(id: UUID(), author: .user, body: "Keep this saved conversation.",
                                         delivery: .sent, timestamp: Date(timeIntervalSince1970: 1_788_000_000))
        let draft = "  Preserve this unsent draft — e\u{301}.  "
        let conversation = ConversationModel(conversationID: UUID(), title: selected.name,
            messages: [message], composerText: draft, isLocalOnly: true, inputAvailability: .ready,
            submit: { _, _, _ in XCTFail("Hover cannot submit a message") })
        let conversationID = conversation.conversationID
        let messageRows = conversation.messageRows.map(ObjectIdentifier.init)
        var actions = 0
        let root = OpenBotsRootView(sidebar: sidebar, conversation: conversation,
            createTeammate: { actions += 1 }, openSettings: { actions += 1 },
            openBotSettings: { _ in actions += 1 }, archiveBot: { _ in actions += 1 })
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .minSize
        let window = ReferenceLayoutWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        configureReferenceIntegratedTitlebar(window)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        window.setContentSize(CGSize(width: 720, height: 720))
        controller.view.frame.size = CGSize(width: 720, height: 720)
        try await settleReferenceLayout(controller.view)
        let content = try XCTUnwrap(window.contentView)
        let views = content.referenceLayoutDescendants
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 0)
        let source = try XCTUnwrap(views.compactMap { $0 as? BotSidebarDragSourceView }.first { $0.rowID == target.id })
        let row = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: false))
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: false))
        let avatar = try XCTUnwrap(row.referenceLayoutDescendants.compactMap { $0 as? CharacterMotionVisibilityView }.first)
        let editor = try XCTUnwrap(referenceNativeEditor(in: content, text: draft))
        let firstResponder = window.firstResponder
        let editorSelection = (editor as? NSTextView)?.selectedRange()
        let interaction = source.convert(source.interactionBounds, to: content)
        let visual = source.convert(source.bounds, to: content)
        let rowRect = table.convert(table.rect(ofRow: 1), to: content)
        let cellRect = cell.convert(cell.bounds, to: content)
        let avatarRect = avatar.convert(avatar.bounds, to: content)
        referenceLayoutLog("actual hover \(scheme): row=\(rowRect), cell=\(cellRect), visual=\(visual), interaction=\(interaction), avatar=\(avatarRect), native visible=\(source.visibleRect)")
        XCTAssertEqual(source.horizontalVisualOutset, 20)
        XCTAssertEqual(source.interactionBounds, source.bounds.insetBy(dx: 20, dy: 0))
        XCTAssertEqual(interaction.minX, avatarRect.minX, "The original row content remains the input allocation")
        // Native sidebar styling adds eight points outside the cell on each
        // side. Compensate only the paint allocation, retaining the original
        // twelve-point cell insets and all native input/menu geometry.
        XCTAssertEqual(visual.minX, cellRect.minX - 8, "The leading sidebar gutter must not narrow the broad hover")
        XCTAssertEqual(visual.maxX, cellRect.maxX + 8, "The trailing sidebar gutter must not narrow the broad hover")
        XCTAssertEqual(visual.minX, interaction.minX - 20)
        XCTAssertEqual(visual.maxX, interaction.maxX + 20)
        XCTAssertEqual(source.visibleRect.intersection(source.bounds), source.bounds,
                       "Actual SwiftUI/List ancestors must not clip either added paint margin")
        assertContained(source, in: content)
        assertContained(referenceEditorViewport(editor), in: content)
        XCTAssertNil(source.hitTest(source.convert(NSPoint(x: source.bounds.minX + 4, y: source.bounds.midY), to: source.superview)))
        XCTAssertNil(source.hitTest(source.convert(NSPoint(x: source.bounds.maxX - 4, y: source.bounds.midY), to: source.superview)))
        XCTAssertFalse(source.acceptsFirstResponder, "The decorative/input bridge must leave keyboard focus to the native List")
        XCTAssertFalse(source.isAccessibilityElement(), "The bridge must not duplicate the native accessible row")
        XCTAssertTrue(table.acceptsFirstResponder)

        // Only suppress the entrance fade in this synthetic endpoint check; do
        // not change the SwiftUI allocation, padding, clipping or native frame.
        source.reduceMotion = true
        let location = source.convert(NSPoint(x: source.interactionBounds.midX, y: source.interactionBounds.midY), to: nil)
        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5))
        let menuBefore = try XCTUnwrap(source.menu(for: right))
        let before = try captureReferenceHoverRow(content, rect: visual, name: "actual-list-hover-\(scheme)-before")
        let rowBefore = try captureReferenceHoverRow(content, rect: rowRect, name: "actual-list-shape-\(scheme)-before")
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: location,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
        source.mouseEntered(with: entered)
        XCTAssertEqual(source.hoveredRowID, target.id)
        let hover = try captureReferenceHoverRow(content, rect: visual, name: "actual-list-hover-\(scheme)-during")
        let rowHover = try captureReferenceHoverRow(content, rect: rowRect, name: "actual-list-shape-\(scheme)-hover")
        let hoverShape = try assertReferenceRoundedRowPaint(before: rowBefore, after: rowHover,
            size: rowRect.size, name: "actual-list-shape-\(scheme)-hover")
        try captureReferenceLayout(content, name: "reference-actual-list-hover-\(scheme)-720.png")
        XCTAssertEqual(source.hoveredRowID, target.id)
        let menuAfter = try XCTUnwrap(source.menu(for: right))
        XCTAssertEqual(menuBefore.items.map(\.title), [target.name, "Open Settings", "Archive Bot"])
        XCTAssertEqual(menuAfter.items.map(\.title), menuBefore.items.map(\.title))
        XCTAssertEqual(menuAfter.items.map(\.isEnabled), menuBefore.items.map(\.isEnabled))
        XCTAssertNil(source.contextMenuTargetID, "Constructing a menu does not open it")
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: location,
            modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, trackingNumber: 0, userData: nil))
        source.mouseExited(with: exited)
        let after = try captureReferenceHoverRow(content, rect: visual, name: "actual-list-hover-\(scheme)-after")
        // Sample well inside both twenty-point paint-only bands, at the flat
        // vertical center rather than the rounded/antialiased corners. These
        // pixels come from the parent-composited row, not the overlay in isolation.
        for x in [CGFloat(4), visual.width - 4] {
            let initial = try referenceHoverPixel(before, x: x, width: visual.width)
            XCTAssertNotEqual(try referenceHoverPixel(hover, x: x, width: visual.width), initial,
                              "The expanded hover must visibly reach each real list-row inset")
            XCTAssertEqual(try referenceHoverPixel(after, x: x, width: visual.width), initial,
                           "Leaving the row restores the same inset pixels")
        }
        XCTAssertNil(source.hoveredRowID)
        XCTAssertEqual(source.convert(source.interactionBounds, to: content), interaction)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertTrue(window.firstResponder === firstResponder, "Hover must not steal the existing editor focus")

        // This hidden window exercises native keyboard dispatch and the actual
        // List's selected-row paint. It is not a physical keyboard/VoiceOver pass.
        // Compare the same row with focus held constant so text, background and
        // focus changes cannot masquerade as selection's rounded outer corners.
        XCTAssertTrue(window.makeFirstResponder(table))
        try await settleReferenceLayout(controller.view)
        XCTAssertTrue(window.firstResponder === table, "Native keyboard navigation intentionally focuses the List")
        let keyboardBefore = try captureReferenceHoverRow(content, rect: rowRect,
            name: "actual-list-shape-\(scheme)-keyboard-before")
        table.keyDown(with: try referenceArrowKey(.down, in: window))
        try await settleReferenceLayout(controller.view)
        XCTAssertEqual(table.selectedRow, 1, "The native down-arrow must select the next bot")
        XCTAssertEqual(sidebar.selection, target.id)
        let selectedPaint = try captureReferenceHoverRow(content, rect: rowRect,
            name: "actual-list-shape-\(scheme)-selected")
        let selectionShape = try assertReferenceRoundedRowPaint(before: keyboardBefore, after: selectedPaint,
            size: rowRect.size, name: "actual-list-shape-\(scheme)-selection")
        referenceLayoutLog("rounded row shapes \(scheme): hover=\(hoverShape), native selection=\(selectionShape); sizes and system colors intentionally independent")
        if let accessibleSelection = table.accessibilitySelectedRows() {
            XCTAssertEqual(accessibleSelection.count, 1, "Native AX selection must describe one selected bot")
            referenceLayoutLog("native table AX selection \(scheme): one row; full hidden-host tree and physical VoiceOver remain UNVERIFIED")
        } else {
            referenceLayoutLog("AX UNVERIFIED \(scheme): hidden native List did not expose selected rows; no accessibility pass is inferred")
        }
        table.keyDown(with: try referenceArrowKey(.up, in: window))
        try await settleReferenceLayout(controller.view)
        XCTAssertEqual(table.selectedRow, 0, "The native up-arrow must restore the original bot")
        XCTAssertEqual(sidebar.rows, [selected, target])
        XCTAssertEqual(sidebar.selection, selected.id)
        XCTAssertNil(sidebar.sidebarDrag)
        XCTAssertNil(sidebar.sidebarInsertion)
        XCTAssertNil(source.sourceToken)
        XCTAssertTrue(window.firstResponder === table, "Arrow navigation must leave keyboard ownership with the native List")
        XCTAssertTrue(referenceNativeEditor(in: content, text: draft) === editor)
        XCTAssertEqual((editor as? NSTextView)?.selectedRange(), editorSelection)
        XCTAssertEqual(conversation.conversationID, conversationID)
        XCTAssertEqual(conversation.messages, [message])
        XCTAssertEqual(conversation.messageRows.map(ObjectIdentifier.init), messageRows)
        XCTAssertTrue(conversation.composerText.utf8.elementsEqual(draft.utf8))
        XCTAssertEqual(actions, 0)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(window.sheets.isEmpty)
        referenceLayoutLog("SYNTHETIC ONLY: rounded selection/hover paint and native arrow dispatch; physical pointer enter/exit, fade timing and VoiceOver are not exercised")
    }

    private func exerciseHeaderLayout(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let name = "Alexandria Research and Source Verification Partner With a Deliberately Long Name"
        let selected = TeammateRowSnapshot(id: UUID(), name: name, role: "Synthetic layout fixture",
                                          activity: .idle, identitySeed: 21)
        let other = TeammateRowSnapshot(id: UUID(), name: "Mira", role: "Synthetic layout fixture",
                                       activity: .idle, identitySeed: 22)
        let sidebar = SidebarModel(rows: [selected, other], selection: selected.id)
        let body = "Keep this saved message and its identity while the conversation header resizes."
        let message = ChatMessageSnapshot(id: UUID(), author: .user, body: body, delivery: .sent,
                                         timestamp: Date(timeIntervalSince1970: 1_788_000_000))
        let draft = "  Keep this unsent draft — café e\u{301}.  "
        let conversationID = UUID()
        let submissions = ReferenceRenderSubmissionCounter()
        let conversation = ConversationModel(
            conversationID: conversationID, title: name, messages: [message], composerText: draft,
            readyDeliveryDescription: "Synthetic layout fixture only.", isLocalOnly: true,
            inputAvailability: .ready, submit: { _, _, _ in await submissions.record() }
        )
        let rowIdentities = conversation.messageRows.map(ObjectIdentifier.init)
        var actions = 0
        let root = OpenBotsRootView(sidebar: sidebar, conversation: conversation,
            createTeammate: { actions += 1 }, openSettings: { actions += 1 },
            toggleDetails: { actions += 1 })
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .minSize
        let window = ReferenceLayoutWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        configureReferenceIntegratedTitlebar(window)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        var originalComposer: NSView?

        for width: CGFloat in [720, 1_080] {
            window.setContentSize(CGSize(width: width, height: 720))
            controller.view.frame.size = CGSize(width: width, height: 720)
            try await settleReferenceLayout(controller.view)
            let content = try XCTUnwrap(window.contentView)
            let descendants = content.referenceLayoutDescendants
            let roster = try XCTUnwrap(descendants.compactMap { $0 as? NSTableView }.first)
            XCTAssertEqual(roster.numberOfRows, 2)
            XCTAssertEqual(roster.selectedRow, 0)
            assertContained(try XCTUnwrap(roster.enclosingScrollView), in: content)
            let editor = try XCTUnwrap(referenceNativeEditor(in: content, text: draft))
            if let originalComposer { XCTAssertTrue(editor === originalComposer) }
            else { originalComposer = editor }
            assertContained(referenceEditorViewport(editor), in: content)
            let savedText = try XCTUnwrap(descendants.compactMap { $0 as? NSTextField }.first {
                !$0.isEditable && $0.isSelectable && $0.stringValue == body
            })
            assertContained(savedText, in: content)

            // The existing native artwork probe exposes its actual frame without
            // adding test-only layout instrumentation. The only chat-side avatar
            // in this user-message fixture belongs to the selected header.
            let headerAvatars = descendants.compactMap { $0 as? CharacterMotionVisibilityView }.filter {
                $0.convert($0.bounds, to: content).minX >= 281
            }
            XCTAssertEqual(headerAvatars.count, 1)
            let avatar = try XCTUnwrap(headerAvatars.first)
            assertContained(avatar, in: content)
            XCTAssertEqual(avatar.bounds.width, 42)
            XCTAssertEqual(avatar.bounds.height, 42)
            let avatarFrame = avatar.convert(avatar.bounds, to: content)
            let windowLayout = content.convert(window.contentLayoutRect, from: nil)
            XCTAssertLessThan(windowLayout.height, content.bounds.height,
                              "The owned window must actually reserve native titlebar space")
            XCTAssertTrue(windowLayout.insetBy(dx: -1, dy: -1).contains(avatarFrame),
                          "The enlarged header identity must remain below the reserved native controls")
            let buttons = descendants.compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            for button in buttons { assertContained(button, in: content) }
            let details = buttons.filter { $0.accessibilityLabel() == "Show bot details" }
            for button in details {
                XCTAssertGreaterThan(button.convert(button.bounds, to: content).minX, avatarFrame.maxX)
                XCTAssertTrue(button.isEnabled)
            }
            referenceLayoutLog("header \(scheme) width=\(width), avatar=\(avatarFrame), reserved native layout=\(windowLayout), native buttons=\(buttons.count), native Details buttons=\(details.count)")
            if details.isEmpty {
                referenceLayoutLog("AX UNVERIFIED: hidden host exposes no native Details button bounds; required PNG retains its visual layout for separate review")
            }
            try captureReferenceLayout(content, name: "reference-header-long-name-\(scheme)-\(Int(width)).png")
            XCTAssertEqual(content.bounds.width, width, accuracy: 1)
            XCTAssertEqual(sidebar.selection, selected.id)
            XCTAssertEqual(sidebar.rows, [selected, other])
            XCTAssertEqual(conversation.conversationID, conversationID)
            XCTAssertEqual(conversation.title, name)
            XCTAssertEqual(conversation.messages, [message])
            XCTAssertEqual(conversation.messageRows.map(ObjectIdentifier.init), rowIdentities)
            XCTAssertTrue(conversation.composerText.utf8.elementsEqual(draft.utf8))
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertTrue(window.sheets.isEmpty)
        }
        XCTAssertEqual(actions, 0)
        let submissionCount = await submissions.count
        XCTAssertEqual(submissionCount, 0)
    }

    private func exerciseLayout(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try fixture.open()
        let model = fixture.workspace(store: store)
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        await model.createTeammateImmediately()
        try await referenceWaitUntil { model.draftCoordinator?.activeDraft?.status == .saved }
        model.editSelectedProfile()
        let profile = try XCTUnwrap(model.profileEditor)
        await profile.load()
        let profileMarker = "Native Layout Bot"
        profile.displayName = profileMarker
        let teammateID = model.sidebar.selection
        let conversationID = model.conversation.conversationID
        let root = DurableWorkspaceView(model: model, openSettings: {})
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .minSize
        let window = ReferenceLayoutWindow(
            contentRect: CGRect(x: 0, y: 0, width: 942, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        configureReferenceIntegratedTitlebar(window)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        let owner = NSWindowController(window: window)
        defer { window.contentViewController = nil; owner.close() }
        var originalComposer: NSView?
        for width: CGFloat in [942, 1_400] {
            window.setContentSize(CGSize(width: width, height: 720))
            controller.view.frame.size = CGSize(width: width, height: 720)
            var heights: [Int: CGFloat] = [:]
            for lineCount in [1, 5, 25, 1] {
                let draft = (1...lineCount).map { "Draft line \($0)" }.joined(separator: "\n")
                model.conversation.composerText = draft
                try await settleReferenceLayout(controller.view)
                let content = try XCTUnwrap(window.contentView)
                let editor = try XCTUnwrap(referenceNativeEditor(in: content, text: draft), "The real native chat editor must mount")
                if let originalComposer {
                    XCTAssertTrue(originalComposer === editor, "Editing and resize must preserve the native composer")
                } else { originalComposer = editor }
                let viewport = referenceEditorViewport(editor)
                assertContained(viewport, in: content)
                let name = try XCTUnwrap(referenceNativeEditor(in: content, text: profileMarker))
                let detailsScroll = try XCTUnwrap(name.enclosingScrollView)
                assertContained(detailsScroll, in: content)
                assertContained(name, in: content)
                XCTAssertEqual(detailsScroll.bounds.width, 320, accuracy: 1)
                XCTAssertGreaterThan(viewport.bounds.width, 100)
                XCTAssertLessThan(viewport.convert(viewport.bounds, to: content).maxX,
                                  detailsScroll.convert(detailsScroll.bounds, to: content).minX)
                if lineCount == 1, let initialHeight = heights[1] {
                    XCTAssertEqual(viewport.bounds.height, initialHeight, accuracy: 2, "Deleting extra lines must shrink the composer")
                }
                heights[lineCount] = viewport.bounds.height
                if lineCount == 25 {
                    XCTAssertLessThanOrEqual(viewport.bounds.height, 240, "Long drafts must scroll inside a capped editor")
                    if let textView = editor as? NSTextView {
                        XCTAssertGreaterThan(textView.bounds.height, viewport.bounds.height,
                                             "The long draft must remain in the scrollable document")
                    }
                }
                XCTAssertTrue(model.conversation.composerText.utf8.elementsEqual(draft.utf8))
                XCTAssertEqual(model.sidebar.selection, teammateID)
                XCTAssertEqual(model.conversation.conversationID, conversationID)
                XCTAssertTrue(model.conversation.messages.isEmpty, "Typing never sends or invents a reply")
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertTrue(window.sheets.isEmpty)
                XCTAssertEqual(content.bounds.width, width, accuracy: 1)
                referenceLayoutLog("\(scheme) width=\(width) lines=\(lineCount) editor=\(viewport.bounds.size) details=\(detailsScroll.bounds.width)")
                if lineCount == 5 {
                    try captureReferenceLayout(content, name: "reference-\(scheme)-\(Int(width))-5lines.png")
                }
            }
            XCTAssertGreaterThan(try XCTUnwrap(heights[5]), try XCTUnwrap(heights[1]) + 20)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(heights[25]), try XCTUnwrap(heights[5]))
            XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 942)
            XCTAssertLessThanOrEqual(window.contentMinSize.width, 942 + 1)

            let draft = "  Keep leading spaces\nSecond line — e\u{301} and \u{e9}\n\nTrailing line  "
            model.conversation.composerText = draft
            try await settleReferenceLayout(controller.view)
            let content = try XCTUnwrap(window.contentView)
            let before = try XCTUnwrap(referenceNativeEditor(in: content, text: draft))
            let beforeWidth = referenceEditorViewport(before).bounds.width
            model.closeBotDetails()
            try await settleReferenceLayout(controller.view)
            XCTAssertNil(referenceNativeEditor(in: content, text: profileMarker))
            let closed = try XCTUnwrap(referenceNativeEditor(in: content, text: draft))
            XCTAssertTrue(closed === before)
            if width == 942 {
                XCTAssertGreaterThan(referenceEditorViewport(closed).bounds.width, beforeWidth + 100)
            } else {
                XCTAssertGreaterThanOrEqual(referenceEditorViewport(closed).bounds.width, beforeWidth)
            }
            XCTAssertLessThanOrEqual(window.contentMinSize.width, 720 + 1)
            model.showBotDetails()
            model.editSelectedProfile()
            try await settleReferenceLayout(controller.view)
            XCTAssertTrue(model.profileEditor === profile)
            XCTAssertNotNil(referenceNativeEditor(in: content, text: profileMarker))
            let restored = try XCTUnwrap(referenceNativeEditor(in: content, text: draft))
            XCTAssertTrue(restored === before, "Returning from details/settings must preserve the original native editor")
            XCTAssertEqual(referenceEditorViewport(restored).bounds.width, beforeWidth, accuracy: 1)
            XCTAssertTrue(model.conversation.composerText.utf8.elementsEqual(draft.utf8))
            let search = try XCTUnwrap(model.searchCoordinator)
            search.present()
            try await settleReferenceLayout(controller.view)
            XCTAssertTrue(model.conversation.composerText.utf8.elementsEqual(draft.utf8))
            search.close()
            try await settleReferenceLayout(controller.view)
            XCTAssertTrue(referenceNativeEditor(in: content, text: draft) === before,
                          "Search dismissal preserves the same multiline composer")
            XCTAssertTrue(model.conversation.composerText.utf8.elementsEqual(draft.utf8))
            XCTAssertEqual(model.sidebar.selection, teammateID)
            XCTAssertEqual(model.conversation.conversationID, conversationID)
        }
    }

    private func assertContained(_ view: NSView, in root: NSView) {
        let rect = view.convert(view.bounds, to: root)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        XCTAssertGreaterThanOrEqual(rect.minY, -1)
        XCTAssertLessThanOrEqual(rect.maxX, root.bounds.width + 1)
        XCTAssertLessThanOrEqual(rect.maxY, root.bounds.height + 1)
    }
}

private actor ReferenceRenderSubmissionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
private final class ReferenceLayoutWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private func configureReferenceIntegratedTitlebar(_ window: NSWindow) {
    window.isReleasedWhenClosed = false
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    referenceLayoutLog("Owned-window analogue: full-size content with hidden, transparent native titlebar; not the installed SwiftUI scene or physical traffic-light verification")
}

@MainActor
private func settleReferenceLayout(_ host: NSView) async throws {
    for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func referenceNativeEditor(in root: NSView, text: String) -> NSView? {
    ([root] + root.referenceLayoutDescendants).first {
        if let field = $0 as? NSTextField { return field.isEditable && field.stringValue.utf8.elementsEqual(text.utf8) }
        if let editor = $0 as? NSTextView { return editor.isEditable && editor.string.utf8.elementsEqual(text.utf8) }
        return false
    }
}

@MainActor
private func referenceEditorViewport(_ editor: NSView) -> NSView {
    // NSTextView is the scrolling document; its enclosing scroll view is the
    // visible editor. A single-line NSTextField has no internal scroll view.
    if editor is NSTextView, let scroll = editor.enclosingScrollView { return scroll }
    return editor
}

private extension NSView {
    var referenceLayoutDescendants: [NSView] { subviews + subviews.flatMap(\.referenceLayoutDescendants) }
}

private func referenceLayoutLog(_ text: String) {
    FileHandle.standardError.write(Data(("[reference-layout-test] \(text)\n").utf8))
}

private func referenceLayoutEvidenceDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build.noindex/reference-accessibility-evidence-20260830/layout", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    return directory
}

@MainActor
private func captureReferenceLayout(_ host: NSView, name: String) throws {
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 1_000)
    try data.write(to: referenceLayoutEvidenceDirectory().appendingPathComponent(name), options: .atomic)
}

@MainActor
private func captureReferenceHoverRow(_ host: NSView, rect: NSRect, name: String) throws -> NSBitmapImageRep {
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
    let pixels = try XCTUnwrap(bitmap.bitmapData)
    pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    host.cacheDisplay(in: rect, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let destination = try referenceLayoutEvidenceDirectory().appendingPathComponent(name + ".png")
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return bitmap
}

@MainActor
private func referenceHoverPixel(_ bitmap: NSBitmapImageRep, x: CGFloat, width: CGFloat) throws -> [CGFloat] {
    XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    let pixelX = min(bitmap.pixelsWide - 1, max(0, Int(x * CGFloat(bitmap.pixelsWide) / width)))
    let color = try XCTUnwrap(bitmap.colorAt(x: pixelX, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}

private enum ReferenceArrowDirection { case up, down }

@MainActor
private func referenceArrowKey(_ direction: ReferenceArrowDirection, in window: NSWindow) throws -> NSEvent {
    let isDown = direction == .down
    let character = isDown ? "\u{F701}" : "\u{F700}"
    return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
        characters: character, charactersIgnoringModifiers: character, isARepeat: false,
        keyCode: isDown ? 125 : 126))
}

/// Derive an outline from a same-row raster difference rather than assuming
/// selection is a particular blue/gray or that AppKit keeps a fixed radius.
/// Both appearances must have four cut-out corners and straight long sides;
/// selection and hover may retain independent bounds, colors and exact radii.
@MainActor
private func assertReferenceRoundedRowPaint(before: NSBitmapImageRep, after: NSBitmapImageRep,
                                       size: NSSize, name: String) throws -> String {
    XCTAssertEqual(before.pixelsWide, after.pixelsWide)
    XCTAssertEqual(before.pixelsHigh, after.pixelsHigh)
    let width = after.pixelsWide
    let height = after.pixelsHigh
    XCTAssertGreaterThan(width, 0)
    XCTAssertGreaterThan(height, 0)
    let scale = NSSize(width: CGFloat(width) / size.width, height: CGFloat(height) / size.height)
    var scanlines: [ClosedRange<Int>?] = Array(repeating: nil, count: height)
    let mask = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
        hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let paintedMaskColor = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
    let unchangedMaskColor = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
    for y in 0..<height {
        for x in 0..<width {
            let old = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let new = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let delta = zip([old.redComponent, old.greenComponent, old.blueComponent, old.alphaComponent],
                            [new.redComponent, new.greenComponent, new.blueComponent, new.alphaComponent])
                .map { abs($0 - $1) }.max() ?? 0
            // One 8-bit step tolerates conversion round-off without depending
            // on a theme's hue, highlight alpha or contrast preference.
            let changed = delta >= 1 / CGFloat(255)
            mask.setColor(changed ? paintedMaskColor : unchangedMaskColor, atX: x, y: y)
            if changed {
                scanlines[y] = scanlines[y].map { min($0.lowerBound, x)...max($0.upperBound, x) } ?? x...x
            }
        }
    }
    let maskURL = try referenceLayoutEvidenceDirectory().appendingPathComponent(name + "-outline-mask.png")
    try XCTUnwrap(mask.representation(using: .png, properties: [:])).write(to: maskURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: maskURL.path)
    let top = try XCTUnwrap(scanlines.firstIndex { $0 != nil }, "\(name): no visible paint difference")
    let bottom = try XCTUnwrap(scanlines.lastIndex { $0 != nil })
    let middle = try XCTUnwrap(scanlines[(top + bottom) / 2])
    let upper = try XCTUnwrap(scanlines[top])
    let lower = try XCTUnwrap(scanlines[bottom])
    let insets = [upper.lowerBound - middle.lowerBound, middle.upperBound - upper.upperBound,
                  lower.lowerBound - middle.lowerBound, middle.upperBound - lower.upperBound]
        .map { CGFloat($0) / scale.width }
    XCTAssertGreaterThan(CGFloat(middle.count) / scale.width, size.width / 2,
                         "\(name): the outline must be the full row treatment, not changed text or artwork")
    for (corner, inset) in zip(["top left", "top right", "bottom left", "bottom right"], insets) {
        XCTAssertGreaterThan(inset, 0, "\(name): \(corner) must visibly cut away from a rectangular highlight")
    }
    for y in [top + (bottom - top) / 4, bottom - (bottom - top) / 4] {
        let side = try XCTUnwrap(scanlines[y])
        XCTAssertEqual(CGFloat(side.lowerBound), CGFloat(middle.lowerBound), accuracy: 1,
                       "\(name): a rounded rectangle retains a straight leading side")
        XCTAssertEqual(CGFloat(side.upperBound), CGFloat(middle.upperBound), accuracy: 1,
                       "\(name): a rounded rectangle retains a straight trailing side")
    }
    let bounds = NSRect(x: CGFloat(middle.lowerBound) / scale.width, y: CGFloat(top) / scale.height,
                        width: CGFloat(middle.count) / scale.width, height: CGFloat(bottom - top + 1) / scale.height)
    return "bounds=\(bounds), corner cutouts in points=\(insets)"
}

private final class ReferenceLayoutChildLog: @unchecked Sendable {
    private let reader: FileHandle
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var tail = Data()
    init(reader: FileHandle) { self.reader = reader }
    func start() {
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            while let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                lock.withLock {
                    tail.append(bytes)
                    if tail.count > 131_072 { tail.removeFirst(tail.count - 131_072) }
                }
            }
        }
    }
    func finish() -> String {
        _ = done.wait(timeout: .now() + 1)
        return lock.withLock { String(decoding: tail, as: UTF8.self) }
    }
}
