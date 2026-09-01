import AppKit
import Foundation
import OpenBotsServices
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// Actual utility views in never-ordered fixture windows. These tests do not
/// inspect the installed app, call accessibility APIs, run OCR, or use a real
/// setup inspector. Main must inspect the captured images separately.
@MainActor
final class ReferenceUtilitySurfaceTests: XCTestCase {
    func testPluginsMinimumRenderKeepsSearchUnavailableAndRoutesClose() async throws {
        var closeCalls = 0
        let plugins = PluginsCatalogView { closeCalls += 1 }
        let host = UtilitySurfaceHost(view: plugins, size: CGSize(width: 600, height: 460))
        defer { host.close() }
        try await host.settle()

        host.assertFitsDeclaredSize()
        let fields = host.content.utilitySurfaceDescendants.compactMap { $0 as? NSTextField }
        let search = try XCTUnwrap(fields.first { $0.placeholderString == "Search plugins" },
                                  "The real native search field must render, even while the catalog is unavailable")
        XCTAssertFalse(search.isEnabled, "No catalog service exists; Search must not imply a working query")
        XCTAssertEqual(search.stringValue, "")
        host.assertContained(search)
        XCTAssertFalse(fields.contains { $0 is NSSecureTextField })
        XCTAssertEqual(closeCalls, 0, "Opening or rendering Plugins must not dismiss it")
        try host.capture("plugins-minimum-600x460.png")

        // This exercises the same action used by Close and Escape, without
        // claiming that a hidden host verifies native pointer/key dispatch.
        plugins.dismissCatalog()
        XCTAssertEqual(closeCalls, 1)
        host.assertNeverPresented()
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
        navigation.selection = .computer
        try await host.settle()
        XCTAssertEqual(navigation.selection, .computer)
        XCTAssertEqual(model.state, .notChecked)
        let calls = await inspector.calls
        XCTAssertEqual(calls, 0)
        host.assertNeverPresented()
    }

    private func filename(for section: WorkspaceSettingsSection) -> String {
        switch section {
        case .general: "general"
        case .computer: "computer"
        case .usage: "usage"
        case .updates: "updates"
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
        // This does not identify text or replace main's visual review.
        if filename.hasPrefix("settings-") {
            XCTAssertGreaterThan(brightPixels(in: bitmap, horizontal: 0.025...0.22), 150,
                                 "Settings navigation labels must render, not just the sidebar background")
            XCTAssertGreaterThan(brightPixels(in: bitmap, horizontal: 0.29...0.95), 500,
                                 "The selected Settings content must visibly materialize")
        } else {
            XCTAssertGreaterThan(brightPixels(in: bitmap, horizontal: 0.05...0.95), 500,
                                 "Plugins must visibly render its heading and unavailable-state content")
        }
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

    private func brightPixels(in bitmap: NSBitmapImageRep, horizontal: ClosedRange<Double>) -> Int {
        let lower = Int(Double(bitmap.pixelsWide) * horizontal.lowerBound)
        let upper = Int(Double(bitmap.pixelsWide) * horizontal.upperBound)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in lower..<upper {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.55 {
                    count += 1
                }
            }
        }
        return count
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
