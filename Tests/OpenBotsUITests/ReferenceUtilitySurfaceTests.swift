import AppKit
import Foundation
import OpenBotsServices
import SwiftUI
import Vision
import XCTest
@testable import OpenBotsUI

/// Actual utility views in never-ordered fixture windows. These tests do not
/// inspect the installed app, call accessibility APIs or use a real setup
/// inspector; the one pixel read is offline Vision over this fixture's own
/// render, as NormalAppPresentationTests does. The captured images need a
/// person's look; passing layout checks is not visual acceptance.
@MainActor
final class ReferenceUtilitySurfaceTests: XCTestCase {
    /// A row that says a feature isn't available is removed
    /// until the feature exists. Two things can see the workspace in this
    /// never-ordered host: the rendered pixels, which carry the sidebar's rows
    /// and the composer, and the source. SwiftUI menus reach neither the native
    /// tree nor the pixels until they are opened (measured: the native tree of
    /// this render holds only the field values and four "New" titles), and a
    /// symbol-only plain button has no words to read, so the menu rows and the
    /// microphone are swept in the source itself.
    func testTheAccountMenuOffersNothingThatDoesNotWork() async throws {
        let teammate = TeammateRowSnapshot(id: utilitySurfaceID(201), name: "Ada", role: "Research partner",
                                           activity: .idle, identitySeed: 14)
        let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
        let draft = "Ask about the source notes."
        let conversation = ConversationModel(
            conversationID: utilitySurfaceID(202), title: teammate.name, composerText: draft,
            readyDeliveryDescription: DurableWorkspaceModel.textReplyDeliveryDescription,
            isLocalOnly: false, textRepliesEnabled: true, inputAvailability: .ready,
            submit: { _, _, _ in XCTFail("Rendering must not submit work") }
        )
        var unrelatedActions = 0
        let root = OpenBotsRootView(
            sidebar: sidebar, conversation: conversation,
            createTeammate: { unrelatedActions += 1 },
            openSettings: { unrelatedActions += 1 },
            openClaudeSetup: { unrelatedActions += 1 }
        )
        let host = UtilitySurfaceHost(view: root, size: CGSize(width: 1_080, height: 720))
        defer { host.close() }
        try await host.settle()

        let views = host.content.utilitySurfaceDescendants.filter { !$0.isHiddenOrHasHiddenAncestor }
        let composer = try XCTUnwrap(views.first { view in
            if let field = view as? NSTextField { return field.isEditable && field.stringValue == draft }
            if let text = view as? NSTextView { return text.isEditable && text.string == draft }
            return false
        }, "A blank root render is not evidence of the workspace")
        host.assertContained(composer)

        let pixels = try recognisedText(in: host.content, filename: "workspace-no-dead-rows-1080x720.png")
        XCTAssertTrue(pixelsContain(pixels, "OpenBots Next"), "The sidebar footer must render: \(pixels)")
        XCTAssertTrue(pixelsContain(pixels, draft), "The composer draft must render: \(pixels)")
        // "Preview" stays out of the displayed name, and the account button
        // is where the name is displayed. In this 720-point host the button's
        // second line fell below the bottom edge (seen in the red run's
        // render), so the pixels are a guard here and the source sweep below
        // is the proof.
        for dead in ["Plugins", "unavailable", "no account connected", "Preview"] {
            XCTAssertFalse(pixelsContain(pixels, dead), "Rendered pixels still show \(dead): \(pixels)")
        }

        // The account menu's rows, the composer menu's rows and the microphone
        // are SwiftUI-drawn and never reach the native tree or, unopened, the
        // pixels, so the source itself is swept for their wording. The header
        // must be true in every state: this view holds a closure that opens
        // Claude setup and cannot see whether anyone is signed in (that lives
        // in ClaudeSetupModel), so it may not say so.
        let rootSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/OpenBotsRootView.swift"), encoding: .utf8)
        XCTAssertTrue(rootSource.contains("Text(\"Runs on this Mac.\")"),
                      "The account menu's header says what is true in every state")
        XCTAssertTrue(rootSource.contains(".accessibilityHint(\"Runs on this Mac\")"),
                      "The account menu's hint repeats the header")
        for dead in ["— unavailable", "no account connected", "Voice input", "Teach a task",
                     "isShowingPlugins", "PluginsCatalogView", "puzzlepiece", "Signed in", "Local Preview"] {
            XCTAssertFalse(rootSource.contains(dead), "OpenBotsRootView.swift still carries \"\(dead)\"")
        }

        XCTAssertEqual(unrelatedActions, 0)
        XCTAssertEqual(conversation.composerText, draft)
        host.assertNeverPresented()
    }

    /// The sealed sample-folder job runner was retired, and its switches lived
    /// on: an app-wide
    /// "Allow sample-folder jobs" in Settings, a per-bot toggle in a control
    /// nothing has shown since the Access sheet replaced it, and a banner
    /// under the composer while the switch was on. Three reads: the
    /// Permissions pane's pixels with a live switch store, the workspace's
    /// pixels with the jobs switch mirrored on for its bot, and the source of
    /// the two files that drew them, because the per-bot control was already
    /// off every screen and only its source can show it is gone.
    func testNothingOffersTheRetiredSampleFolderJobs() async throws {
        let inspector = UtilityOfflineInspector()
        let setup = ClaudeSetupModel(service: GuardedClaudeSetupService(inspector: inspector))
        let navigation = WorkspaceSettingsNavigation(selection: .permissions)
        let settings = UtilitySurfaceHost(
            view: WorkspaceSettingsView(navigation: navigation, model: setup, usesReviewFixtures: false,
                                        agenticJobAccess: AgenticJobAccessStore()),
            size: CGSize(width: 800, height: 620)
        )
        defer { settings.close() }
        try await settings.settle()
        let pane = try recognisedText(in: settings.content, filename: "settings-permissions-no-sample-folder-800x620.png")
        XCTAssertTrue(pixelsContain(pane, "Allow web search"), "The Permissions card must render its masters: \(pane)")
        XCTAssertTrue(pixelsContain(pane, "work on this Mac"), "The Permissions card must render its masters: \(pane)")
        XCTAssertFalse(pixelsContain(pane, "sample"), "Settings still offers the retired sample-folder jobs: \(pane)")
        XCTAssertFalse(pixelsContain(pane, "jobs"), "Settings still speaks of the retired jobs: \(pane)")
        XCTAssertEqual(setup.state, .notChecked)
        let calls = await inspector.calls
        XCTAssertEqual(calls, 0, "Rendering Permissions must not start even the injected local check")

        // The workspace with the jobs switch on for its bot, as the workspace
        // model mirrors it into the conversation: nothing under the composer
        // may announce the retired feature.
        let teammate = TeammateRowSnapshot(id: utilitySurfaceID(211), name: "Ada", role: "Research partner",
                                           activity: .idle, identitySeed: 14)
        let sidebar = SidebarModel(rows: [teammate], selection: teammate.id)
        let draft = "Count the rows in the source notes."
        let conversation = ConversationModel(
            conversationID: utilitySurfaceID(212), title: teammate.name, composerText: draft,
            readyDeliveryDescription: DurableWorkspaceModel.textReplyDeliveryDescription,
            isLocalOnly: false, textRepliesEnabled: true, inputAvailability: .ready,
            submit: { _, _, _ in XCTFail("Rendering must not submit work") }
        )
        conversation.setAgenticJob(enabled: true, presentation: nil)
        var unrelatedActions = 0
        let workspace = UtilitySurfaceHost(
            view: OpenBotsRootView(sidebar: sidebar, conversation: conversation,
                                   createTeammate: { unrelatedActions += 1 },
                                   openSettings: { unrelatedActions += 1 }),
            size: CGSize(width: 1_080, height: 720)
        )
        defer { workspace.close() }
        try await workspace.settle()
        let views = workspace.content.utilitySurfaceDescendants.filter { !$0.isHiddenOrHasHiddenAncestor }
        let composer = try XCTUnwrap(views.first { view in
            if let field = view as? NSTextField { return field.isEditable && field.stringValue == draft }
            if let text = view as? NSTextView { return text.isEditable && text.string == draft }
            return false
        }, "A blank root render is not evidence of the workspace")
        workspace.assertContained(composer)
        let pixels = try recognisedText(in: workspace.content, filename: "workspace-jobs-switch-on-no-banner-1080x720.png")
        XCTAssertTrue(pixelsContain(pixels, draft), "The composer draft must render: \(pixels)")
        XCTAssertFalse(pixelsContain(pixels, "jobs are on"), "The retired banner still renders: \(pixels)")
        XCTAssertFalse(pixelsContain(pixels, "sample"), "The workspace still speaks of the retired feature: \(pixels)")
        XCTAssertEqual(unrelatedActions, 0)
        workspace.assertNeverPresented()

        // The per-bot control and the Settings switch, in the source: gone,
        // not merely unreferenced.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI", isDirectory: true)
        let sweep: [(file: String, dead: [String])] = [
            ("WorkspaceSettingsView.swift", ["sample-folder", "agentic.app.enabled", "settingsJobsCaption"]),
            ("AgenticJobCoordinator.swift", ["AgenticJobBotControl", "Use sample-folder jobs", "agentic.bot.enabled",
                                             "Sample-folder jobs are on", "agenticJobWebSummary"]),
            ("AgenticWebCopy.swift", ["sample-folder", "jobs switch"]),
        ]
        for (file, dead) in sweep {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for phrase in dead {
                XCTAssertFalse(source.contains(phrase), "\(file) still carries \"\(phrase)\"")
            }
        }
    }

    /// Vision on a 1x display drops or merges spaces; compare with whitespace removed.
    private func pixelsContain(_ rendered: String, _ phrase: String) -> Bool {
        func squash(_ s: String) -> String { s.filter { !$0.isWhitespace }.lowercased() }
        return squash(rendered).contains(squash(phrase))
    }

    /// Reads the rendered pixels through offline Vision, as NormalAppPresentationTests
    /// does: SwiftUI-drawn text is absent from this host's native tree.
    private func recognisedText(in host: NSView, filename: String) throws -> String {
        let scale: CGFloat = 3
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = host.bounds.size
        host.displayIfNeeded()
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000, "An empty image is not render evidence")
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/reference-accessibility-evidence-20260830/utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let recognition = VNRecognizeTextRequest()
        recognition.usesCPUOnly = true
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(data: data, options: [:]).perform([recognition])
        let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: " ").replacingOccurrences(of: "’", with: "'")
        XCTAssertFalse(text.isEmpty, "Rendered text recognition must materialise actual pixels")
        print("Reference utility hidden-window render: \(destination.path)")
        return text
    }

    func testAllSettingsSectionsRenderAtMinimumWithoutSetupOrAccountActions() async throws {
        let inspector = UtilityOfflineInspector()
        let model = ClaudeSetupModel(service: GuardedClaudeSetupService(inspector: inspector))
        let navigation = WorkspaceSettingsNavigation()
        let host = UtilitySurfaceHost(
            view: WorkspaceSettingsView(navigation: navigation, model: model, usesReviewFixtures: false),
            size: CGSize(width: 800, height: 620)
        )
        defer { host.close() }

        for section in WorkspaceSettingsSection.allCases {
            navigation.selection = section
            try await host.settle()
            XCTAssertEqual(navigation.selection, section)
            host.assertFitsDeclaredSize()
            let controls = host.content.utilitySurfaceDescendants
            let settingsAttachment = try XCTUnwrap(controls.compactMap { $0 as? UtilitySettingsWindowAttachment.Reporter }.first)
            XCTAssertTrue(settingsAttachment.closeTarget.isAttached)
            XCTAssertTrue(settingsAttachment.closeTarget.window === host.window,
                          "Close Settings must bind to this fixture's exact owning window")
            let navigationList = try XCTUnwrap(controls.compactMap { $0 as? NSTableView }.first,
                                              "The actual Settings section list must materialize")
            XCTAssertEqual(navigationList.numberOfRows, WorkspaceSettingsSection.allCases.count)
            XCTAssertEqual(navigationList.selectedRow, WorkspaceSettingsSection.allCases.firstIndex(of: section),
                           "Native selection must follow the active Settings section")
            XCTAssertFalse(controls.contains { $0 is NSSecureTextField }, "Settings never collects credentials")
            XCTAssertFalse(controls.compactMap { $0 as? NSTextField }.contains(where: \.isEditable),
                           "Unavailable account/computer/billing/update services must not expose editable values")
            XCTAssertFalse(controls.compactMap { $0 as? NSTextView }.contains(where: \.isEditable))
            XCTAssertEqual(model.state, .notChecked)
            XCTAssertNil(model.localFindings)
            XCTAssertFalse(model.isBusy)
            let calls = await inspector.calls
            XCTAssertEqual(calls, 0, "Changing Settings sections must not start even the injected local check")
            try host.capture("settings-\(filename(for: section))-minimum-800x620.png")
        }

        // Match the app's connection deep link after visiting other sections.
        navigation.selection = .general
        try await host.settle()
        XCTAssertEqual(navigation.selection, .general)
        XCTAssertEqual(model.state, .notChecked)
        let calls = await inspector.calls
        XCTAssertEqual(calls, 0)
        host.assertNeverPresented()
    }

    private func filename(for section: WorkspaceSettingsSection) -> String {
        switch section {
        case .general: "general"
        case .connectors: "connectors"
        case .permissions: "permissions"
        case .appearance: "appearance"
        case .notifications: "notifications"
        case .storage: "storage"
        case .diagnostics: "diagnostics"
        }
    }
}

@MainActor
private final class UtilitySurfaceHost {
    let controller: NSHostingController<AnyView>
    let window: UtilitySurfaceWindow
    private let container: NSViewController
    let size: CGSize

    var content: NSView { controller.view }

    init<V: View>(view: V, size: CGSize) {
        _ = NSApplication.shared
        self.size = size
        controller = NSHostingController(rootView: AnyView(view
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)))
        controller.sizingOptions = []
        controller.view.appearance = NSAppearance(named: .darkAqua)
        container = NSViewController()
        container.view = NSView(frame: CGRect(origin: .zero, size: size))
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.view.autoresizingMask = [.width, .height]
        window = UtilitySurfaceWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        // Keep the host a child, as in the chat presentation harness. A direct
        // window-root host adds native window padding to sizeThatFits; that is
        // not part of the utility view's declared content size.
        window.contentViewController = container
        window.setContentSize(size)
        controller.view.frame = CGRect(origin: .zero, size: size)
        // Never order, activate or make this fixture key. No live app shares it.
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }

    func settle() async throws {
        for _ in 0..<6 {
            container.view.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            content.needsDisplay = true
            content.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func assertFitsDeclaredSize(file: StaticString = #filePath, line: UInt = #line) {
        let measured = controller.sizeThatFits(in: size)
        print("Utility geometry: proposal=\(size) fitted=\(measured) host=\(content.bounds) safeArea=\(content.safeAreaInsets) windowContent=\(String(describing: window.contentView?.bounds)) layout=\(window.contentLayoutRect)")
        XCTAssertTrue(measured.width.isFinite && measured.height.isFinite, file: file, line: line)
        XCTAssertGreaterThan(measured.width, 0, file: file, line: line)
        XCTAssertGreaterThan(measured.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(measured.width, size.width + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(measured.height, size.height + 1, file: file, line: line)
        XCTAssertEqual(content.bounds.width, size.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(content.bounds.height, size.height, accuracy: 1, file: file, line: line)
        assertNeverPresented(file: file, line: line)
    }

    func assertContained(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let rect = view.convert(view.bounds, to: content)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite,
                      file: file, line: line)
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, -1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, content.bounds.width + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, content.bounds.height + 1, file: file, line: line)
    }

    func assertNeverPresented(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(window.isVisible, file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, file: file, line: line)
        XCTAssertFalse(window.isMainWindow, file: file, line: line)
        XCTAssertTrue(window.sheets.isEmpty, file: file, line: line)
    }

    func capture(_ filename: String) throws {
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.displayIfNeeded()
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000, "An empty bitmap is not render evidence")
        // Contrast ink in the real rendered regions prevents a black image
        // (or a lone divider) being accepted merely because it is a valid PNG.
        // This does not identify text or replace a person's look at the image.
        XCTAssertGreaterThan(brightPixels(in: bitmap, horizontal: 0.025...0.22), 150,
                             "Settings navigation labels must render, not just the sidebar background")
        XCTAssertGreaterThan(brightPixels(in: bitmap, horizontal: 0.29...0.95), 500,
                             "The selected Settings content must visibly materialize")
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/reference-accessibility-evidence-20260830/utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        print("Reference utility hidden-window render: \(destination.path)")
    }

    /// Counts "ink" pixels: those clearly brighter than the region's own background. An absolute
    /// 0.55 bar was tuned on macOS 26, where sidebar labels render near-white; on macOS 15 the
    /// same labels in this never-key fixture window render dimmed (min component ≈ 0.38 over a
    /// 0.10 background — see the ui-evidence-macos-15 CI artifact) and vanished from the count
    /// although they are plainly visible. Contrast against the region's median keeps the intent
    /// (a black or divider-only image still counts 0) on both systems.
    private func brightPixels(in bitmap: NSBitmapImageRep, horizontal: ClosedRange<Double>) -> Int {
        let lower = Int(Double(bitmap.pixelsWide) * horizontal.lowerBound)
        let upper = Int(Double(bitmap.pixelsWide) * horizontal.upperBound)
        var minima: [CGFloat] = []
        minima.reserveCapacity((upper - lower) * bitmap.pixelsHigh)
        for y in 0..<bitmap.pixelsHigh {
            for x in lower..<upper {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                minima.append(min(color.redComponent, color.greenComponent, color.blueComponent))
            }
        }
        guard !minima.isEmpty else { return 0 }
        let background = minima.sorted()[minima.count / 2]
        let threshold = max(background + 0.2, 0.3)
        return minima.filter { $0 > threshold }.count
    }
}

@MainActor
private final class UtilitySurfaceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private actor UtilityOfflineInspector: ClaudeOfflineSetupInspecting {
    private(set) var calls = 0

    func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        calls += 1
        return .init(installation: .verified, profile: .metadataVerified,
                     details: [.init(label: "Source", value: "Injected local test metadata")])
    }
}

private extension NSView {
    var utilitySurfaceDescendants: [NSView] { [self] + subviews.flatMap(\.utilitySurfaceDescendants) }
}

private func utilitySurfaceID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "AA920000-0000-0000-0000-%012llx", suffix))!
}
