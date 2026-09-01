import AppKit
import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Replaces the withdrawn pane requirements, not their historical failures.
/// These injected, non-key windows are native composition/render evidence;
/// they do not establish physical keyboard, VoiceOver, or helper behavior.
@MainActor
final class ChatOnlyWorkspacePresentationTests: XCTestCase {
    private static let childFlag = "OPENBOTS_CHAT_ONLY_PRESENTATION_CHILD"
    private static let completed = "CHAT_ONLY_PRESENTATION_COMPLETED"

    func testChatControlsSurviveDormantContextAndTeammateNavigation() async throws {
        guard ProcessInfo.processInfo.environment[Self.childFlag] == "1" else {
            try runBoundedChild(method: #function)
            return
        }
        for mode in [LocalChatMode.localOnly, .reviewFixture] {
            let fixture = try await ChatOnlyFixture.make(mode: mode)
            let harness = ChatOnlyWindowHarness(model: fixture.model, scheme: .light)
            defer { harness.close(); fixture.model.finishShutdown() }
            try await harness.requireChat(transcript: fixture.firstText, draft: fixture.firstDraft)
            let initialIDs = fixture.model.conversation.messageRows.map(\.id)
            let originalComposer = try XCTUnwrap(harness.editableText(fixture.firstDraft))
            let originalFrame = originalComposer.convert(originalComposer.bounds, to: harness.background)

            for kind in [CollaborationCreationKind.project, .team] {
                fixture.collaboration.beginCreation(kind)
                fixture.collaboration.draftName = ChatOnlyFixture.dormantDraft
                fixture.collaboration.showInspector()
                try await harness.settle()
                try await harness.requireChat(transcript: fixture.firstText, draft: fixture.firstDraft)
                harness.assertNoWorkContext()
                let composer = try XCTUnwrap(harness.editableText(fixture.firstDraft))
                XCTAssertTrue(composer === originalComposer, "Dormant context state must not remount the composer.")
                XCTAssertEqual(composer.convert(composer.bounds, to: harness.background).width,
                               originalFrame.width, accuracy: 1)
                XCTAssertEqual(fixture.model.conversation.messageRows.map(\.id), initialIDs)
                XCTAssertEqual(fixture.model.conversation.composerText, fixture.firstDraft)
            }

            fixture.model.sidebar.selection = fixture.chats[1].teammate.id.rawValue
            await fixture.model.selectionTask?.value
            fixture.model.conversation.composerText = fixture.secondDraft
            try await harness.requireChat(transcript: fixture.secondText, draft: fixture.secondDraft)
            XCTAssertEqual(fixture.model.conversation.conversationID, fixture.chats[1].conversation.id.rawValue)

            fixture.model.sidebar.selection = fixture.chats[0].teammate.id.rawValue
            await fixture.model.selectionTask?.value
            try await harness.requireChat(transcript: fixture.firstText, draft: fixture.firstDraft)
            XCTAssertEqual(fixture.model.conversation.messageRows.map(\.id), initialIDs)

            // Exercise the retained hiring fixture detail and cancellation
            // return. Normal local New Bot now creates an empty chat directly.
            fixture.model.beginHiringFixture()
            let hiring = try XCTUnwrap(fixture.model.hiringModel)
            await hiring.load()
            hiring.composerText = ChatOnlyFixture.hiringDraft
            try await harness.waitFor("native hiring transcript and composer") {
                harness.selectableText(ChatOnlyFixture.hiringGuide) != nil &&
                    harness.editableText(ChatOnlyFixture.hiringDraft) != nil
            }
            harness.assertNoWorkContext()
            let cancelled = await hiring.cancel()
            XCTAssertTrue(cancelled)
            fixture.model.completeHiringCancellation(from: hiring)
            try await harness.requireChat(transcript: fixture.firstText, draft: fixture.firstDraft)
            XCTAssertNil(fixture.model.hiringModel)
            XCTAssertEqual(fixture.model.sidebar.selection, fixture.chats[0].teammate.id.rawValue)
            XCTAssertEqual(fixture.model.conversation.messageRows.map(\.id), initialIDs)
            let creations = await fixture.directory.recordedProjectDrafts().count
            let teams = await fixture.directory.recordedTeamDrafts().count
            XCTAssertEqual(creations, 0)
            XCTAssertEqual(teams, 0)
        }
        chatOnlyPhase(Self.completed)
    }

    func testLightAndDarkChatOnlyWindowsRender() async throws {
        guard ProcessInfo.processInfo.environment[Self.childFlag] == "1" else {
            try runBoundedChild(method: #function)
            return
        }
        let directory = try chatOnlyEvidenceDirectory("rendered")
        for scheme in [ColorScheme.light, .dark] {
            let fixture = try await ChatOnlyFixture.make(mode: .localOnly)
            fixture.collaboration.beginCreation(.team)
            fixture.collaboration.draftName = ChatOnlyFixture.dormantDraft
            let harness = ChatOnlyWindowHarness(model: fixture.model, scheme: scheme)
            defer { harness.close(); fixture.model.finishShutdown() }
            try await harness.requireChat(transcript: fixture.firstText, draft: fixture.firstDraft)
            harness.assertNoWorkContext()
            let destination = directory.appendingPathComponent(
                "chat-only-1080x720-\(scheme == .dark ? "dark" : "light").png"
            )
            try harness.capture(to: destination)
            chatOnlyPhase("render: \(destination.path)")
        }
        chatOnlyPhase(Self.completed)
    }

    private func runBoundedChild(method: String) throws {
        let methodName = String(method.prefix { $0 != "(" })
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest",
            "OpenBotsUITests.ChatOnlyWorkspacePresentationTests/\(methodName)",
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
        let log = ChatOnlyChildLog(reader: output.fileHandleForReading)
        log.start()
        let deadline = Date(timeIntervalSinceNow: 20)
        while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let timedOut = child.isRunning
        if timedOut {
            child.terminate()
            let terminationDeadline = Date(timeIntervalSinceNow: 1)
            while child.isRunning, Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let receipt = log.finish()
        let destination = try chatOnlyEvidenceDirectory("native").appendingPathComponent(methodName + ".log")
        try Data(receipt.utf8).write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        chatOnlyPhase("native receipt: \(destination.path)")
        XCTAssertFalse(timedOut, "Chat composition exceeded its 20-second child bound. \(receipt)")
        XCTAssertEqual(child.terminationStatus, 0, receipt)
        XCTAssertTrue(receipt.contains(Self.completed), "The positive native exercise did not finish. \(receipt)")
    }
}

@MainActor
private final class ChatOnlyWindowHarness {
    let background: ChatOnlyBackgroundView
    private let controller: NSHostingController<AnyView>
    private let containerController: NSViewController
    private let window: ChatOnlyTestWindow
    private let appearance: NSAppearance

    init(model: DurableWorkspaceModel, scheme: ColorScheme) {
        _ = NSApplication.shared
        appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        let rect = NSRect(x: 0, y: 0, width: 1_080, height: 720)
        background = ChatOnlyBackgroundView(frame: rect)
        background.appearance = appearance
        controller = NSHostingController(rootView: AnyView(
            DurableWorkspaceView(model: model, openSettings: {})
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)))
        controller.sizingOptions = []
        containerController = NSViewController()
        containerController.view = background
        containerController.addChild(controller)
        window = ChatOnlyTestWindow(contentRect: rect,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OpenBots chat-only composition test — injected data"
        window.appearance = appearance
        window.contentMinSize = rect.size
        window.contentMaxSize = rect.size
        appearance.performAsCurrentDrawingAppearance {
            controller.view.appearance = appearance
            controller.view.frame = background.bounds
            controller.view.autoresizingMask = [.width, .height]
            background.addSubview(controller.view)
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.contentViewController = containerController
            window.setContentSize(rect.size)
            // Runs only the child-owned presentation lifecycle. Never key,
            // front, active, or controlled through external desktop APIs.
            window.orderBack(nil)
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    func settle() async throws {
        for _ in 0..<6 {
            appearance.performAsCurrentDrawingAppearance { background.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitFor(_ phase: String, condition: () -> Bool) async throws {
        for _ in 0..<150 {
            appearance.performAsCurrentDrawingAppearance { background.layoutSubtreeIfNeeded() }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChatOnlyFixtureError.missingNativeControl(phase)
    }

    func requireChat(transcript: String, draft: String) async throws {
        try await waitFor("native roster, saved transcript and composer") {
            visibleViews.compactMap { $0 as? NSTableView }.contains { $0.numberOfRows >= 2 } &&
                selectableText(transcript) != nil && editableText(draft) != nil
        }
        let roster = try XCTUnwrap(visibleViews.compactMap { $0 as? NSTableView }.first { $0.numberOfRows >= 2 })
        let text = try XCTUnwrap(selectableText(transcript))
        let composer = try XCTUnwrap(editableText(draft))
        XCTAssertGreaterThanOrEqual(roster.selectedRow, 0, "The saved teammate selection must reach the native roster.")
        XCTAssertEqual(text.accessibilityValue(), transcript)
        for view in [roster, text, composer] {
            let rect = view.convert(view.bounds, to: background)
            XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertTrue(rect.intersects(background.bounds), "A materialized control must intersect the viewport.")
            XCTAssertTrue(view.window === window)
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertEqual(window.contentLayoutRect.width, 1_080, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 720, accuracy: 1)
        assertNoWorkContext()
    }

    func assertNoWorkContext() {
        let views = visibleViews
        XCTAssertFalse(views.isEmpty)
        XCTAssertNil(editableText(ChatOnlyFixture.dormantDraft))
        XCTAssertFalse(views.contains { $0.accessibilityIdentifier().hasPrefix("work-context-") })
        let labels = views.flatMap { view -> [String] in
            var values = [view.accessibilityLabel() ?? ""]
            if let field = view as? NSTextField { values.append(field.stringValue) }
            if let button = view as? NSButton { values.append(button.title) }
            if let popup = view as? NSPopUpButton { values.append(contentsOf: popup.itemTitles) }
            return values
        }
        for withdrawn in ["Work Context", "Show Work Context", "Hide Work Context", "New Project", "New Team", "No Project", "No Team"] {
            XCTAssertFalse(labels.contains(withdrawn), "Withdrawn native control remains: \(withdrawn)")
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        // SwiftUI virtual labels need visual inspection of the saved images;
        // a missing virtual AX subtree is deliberately not queried or claimed.
    }

    func editableText(_ value: String) -> NSView? {
        visibleViews.first {
            if let field = $0 as? NSTextField { return field.isEditable && field.stringValue == value }
            if let text = $0 as? NSTextView { return text.isEditable && text.string == value }
            return false
        }
    }

    func selectableText(_ value: String) -> NSTextField? {
        visibleViews.compactMap { $0 as? NSTextField }.first {
            $0.isSelectable && !$0.isEditable && $0.stringValue == value
        }
    }

    func capture(to destination: URL) throws {
        var captured: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            background.layoutSubtreeIfNeeded()
            captured = background.bitmapImageRepForCachingDisplay(in: background.bounds)
            if let captured { background.cacheDisplay(in: background.bounds, to: captured) }
        }
        let bitmap = try XCTUnwrap(captured)
        for (x, y) in [(0, 0), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.99)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)
        try data.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private var visibleViews: [NSView] {
        descendants(background).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor
private final class ChatOnlyTestWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class ChatOnlyBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}

@MainActor
private struct ChatOnlyFixture {
    static let dormantDraft = "DORMANT-WORK-CONTEXT-DRAFT"
    static let hiringDraft = "A careful source reviewer"
    static let hiringGuide = "Describe the teammate you need. These are injected local test records."
    let model: DurableWorkspaceModel
    let collaboration: CollaborationWorkspaceModel
    let directory: S3AProjectTeamDirectoryFake
    let chats: [DurableDirectChatSnapshot]
    let firstText = "Please compare the two source notes before drafting the summary."
    let secondText = "Keep the document review separate from the research conversation."
    let firstDraft = "Keep this draft while I review the sources."
    let secondDraft = "The second conversation keeps its own draft."

    static func make(mode: LocalChatMode) async throws -> Self {
        let teammates = try [s3ATeammate(81, name: "Mira", role: "Research lead"),
                            s3ATeammate(82, name: "Ada", role: "Document reviewer")]
        let now = Date(timeIntervalSince1970: 1_781_000_000)
        let chats = try teammates.enumerated().map { index, teammate in
            DurableDirectChatSnapshot(teammate: teammate, conversation: try Conversation(
                id: ConversationID(chatOnlyUUID(index + 1)), kind: .direct(teammateID: teammate.id),
                title: teammate.profile.displayName, createdAt: now, updatedAt: now))
        }
        let directory = S3AProjectTeamDirectoryFake(teammates: teammates,
            projects: [try s3AProject(81, name: "Saved project", members: teammates)],
            teams: [try s3ATeam(81, name: "Saved team", members: teammates, lead: teammates[0])])
        let collaboration = CollaborationWorkspaceModel(directoryService: directory)
        let texts = ["Please compare the two source notes before drafting the summary.",
                     "Keep the document review separate from the research conversation."]
        let messages = try Dictionary(uniqueKeysWithValues: chats.enumerated().map { index, chat in
            (chat.conversation.id, [try Message(id: MessageID(chatOnlyUUID(index + 11)),
                conversationID: chat.conversation.id, sequence: 1, author: .user, deliveryState: .completed,
                parts: [try MessagePart(id: MessagePartID(chatOnlyUUID(index + 21)), ordinal: 0,
                                        content: .text(texts[index]))], createdAt: now, updatedAt: now)])
        })
        let hiringDraftID = HiringDraftID(chatOnlyUUID(31))
        let hiring = HiringConversationSnapshot(persisted: try HiringDraftSnapshot(
            draft: HiringDraft(id: hiringDraftID, phase: .collecting, revision: 1,
                               createdAt: now, updatedAt: now),
            turns: [HiringTurn(id: HiringTurnID(chatOnlyUUID(32)), draftID: hiringDraftID,
                               sequence: 1, author: .guide, text: hiringGuide, createdAt: now)]),
            focusedField: .displayName)
        let model = DurableWorkspaceModel(mode: mode,
            service: ChatOnlyChatService(chats: chats, messages: messages),
            hiringService: ChatOnlyHiringService(snapshot: hiring), collaborationModel: collaboration)
        try await model.loadInitialWorkspace()
        let fixture = Self(model: model, collaboration: collaboration, directory: directory, chats: chats)
        model.conversation.composerText = fixture.firstDraft
        return fixture
    }
}

private actor ChatOnlyChatService: DurableTeammateChatServing {
    let chats: [DurableDirectChatSnapshot]
    let messages: [ConversationID: [Message]]
    var selected: DurableChatSelectionSnapshot?
    init(chats: [DurableDirectChatSnapshot], messages: [ConversationID: [Message]]) {
        self.chats = chats
        self.messages = messages
        selected = chats.first.map { .init(teammate: $0.teammate, conversation: $0.conversation) }
    }
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { chats }
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? { selected }
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        guard let chat = chats.first(where: { $0.teammate.id == teammateID && $0.conversation.id == conversationID }) else {
            throw ChatOnlyFixtureError.unavailable
        }
        selected = .init(teammate: chat.teammate, conversation: chat.conversation)
    }
    func clearSelection() async throws { selected = nil }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft) async throws -> DurableTeammateChatCreationSnapshot {
        throw ChatOnlyFixtureError.unavailable
    }
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        let rows = (messages[conversationID] ?? []).filter { message in
            beforeSequence.map { message.sequence < $0 } ?? true
        }
        return .init(conversationID: conversationID, messages: Array(rows.suffix(limit)), hasMore: false, nextBeforeSequence: nil)
    }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        throw ChatOnlyFixtureError.unavailable
    }
}

private actor ChatOnlyHiringService: HiringConversationServing {
    let snapshot: HiringConversationSnapshot
    init(snapshot: HiringConversationSnapshot) { self.snapshot = snapshot }
    func loadOrStart() async throws -> HiringConversationSnapshot { snapshot }
    func submit(text: String) async throws -> HiringConversationSnapshot { throw ChatOnlyFixtureError.unavailable }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot { throw ChatOnlyFixtureError.unavailable }
    func cancel() async throws {}
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot { throw ChatOnlyFixtureError.unavailable }
}

private enum ChatOnlyFixtureError: Error {
    case unavailable
    case missingNativeControl(String)
}

private func chatOnlyUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "b5c00000-0000-0000-0000-%012d", value))!
}

private func chatOnlyPhase(_ value: String) {
    FileHandle.standardError.write(Data(("[chat-only-test] \(value)\n").utf8))
}

private func chatOnlyEvidenceDirectory(_ kind: String) throws -> URL {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build.noindex/chat-only-evidence-20260830/\(kind)", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return directory
}

private final class ChatOnlyChildLog: @unchecked Sendable {
    private let reader: FileHandle
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var tail = Data()
    init(reader: FileHandle) { self.reader = reader }
    func start() {
        Thread.detachNewThread { [self] in
            defer { finished.signal() }
            while let bytes = try? reader.read(upToCount: 4_096), !bytes.isEmpty {
                lock.withLock {
                    tail.append(bytes)
                    if tail.count > 131_072 { tail.removeFirst(tail.count - 131_072) }
                }
            }
        }
    }
    func finish() -> String {
        _ = finished.wait(timeout: .now() + 1)
        return lock.withLock { String(decoding: tail, as: UTF8.self) }
    }
}
