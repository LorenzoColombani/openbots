import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class KnowledgeWorkspaceViewTests: XCTestCase {
    func testKnowledgeReaderSourceHasNoEditingOrModalPath() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/KnowledgeWorkspaceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("TextField("))
        XCTAssertFalse(source.contains("TextEditor("))
        XCTAssertFalse(source.contains("SecureField("))
        XCTAssertFalse(source.contains(".sheet("))
        XCTAssertFalse(source.contains("ViewThatFits"))
        XCTAssertTrue(source.contains("StableSelectableText(document.markdown"))
        XCTAssertTrue(source.contains("Label(\"Reveal in Finder\""))
        XCTAssertTrue(source.contains("Label(\"Create Obsidian Snapshot…\""))
        XCTAssertTrue(source.contains("Button(\"Create Snapshot\")"))
        XCTAssertTrue(source.contains("Button(\"Cancel\")"))
        XCTAssertTrue(source.contains("Choosing alone does not create a file"))
    }

    func testRenderedReaderRemainsNonEditableAcrossNarrowAndWideWidths() async throws {
        let context = KnowledgeWorkspaceContext(
            conversationID: viewUUID(1),
            teammateID: viewUUID(2),
            teammateName: "Mira",
            selectedProjectID: viewUUID(3),
            selectedProjectName: "Atlas",
            activeProjectMembershipIDs: [viewUUID(3)]
        )
        let document = KnowledgeDocumentPresentation(
            id: viewUUID(4),
            title: "Research standards",
            scope: .project(id: viewUUID(3), name: "Atlas"),
            author: .teammate(id: viewUUID(2), name: "Mira"),
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 1_782_100_000),
            markdown: "# Research standards\n\nKeep claims traceable to local source notes.",
            recovery: .lastKnownGood(
                unavailableRevision: 3,
                explanation: "The latest revision did not pass integrity validation."
            )
        )
        let snapshot = KnowledgeWorkspaceSnapshot(
            id: viewUUID(5),
            context: context,
            documents: [document],
            excludedDocumentCount: 1
        )
        let destination = KnowledgeSnapshotDestination(
            id: viewUUID(6),
            exactDisplayPath: "/Users/lorenzo/Obsidian/OpenBots/Atlas snapshot.md"
        )
        let model = KnowledgeWorkspaceModel(
            loader: { _ in snapshot },
            revealer: { _, _ in },
            chooseSnapshotDestination: { _ in destination },
            createSnapshot: { _, chosen in
                KnowledgeSnapshotReceipt(
                    exactDisplayPath: chosen.exactDisplayPath,
                    documentCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_782_100_100)
                )
            },
            releaseSnapshotDestination: { _ in }
        )
        model.activateContext(context)
        await model.load()
        await model.selectSnapshotDestination()

        let host = NSHostingView(rootView: KnowledgeWorkspaceView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 1_400)
        settleKnowledgeHost(host)
        try assertStableReadOnlyKnowledgeSurface(
            host,
            expectedMarkdown: document.markdown,
            expectedTarget: destination.exactDisplayPath
        )
        let narrowHeight = host.fittingSize.height
        XCTAssertTrue(narrowHeight.isFinite)
        XCTAssertGreaterThan(narrowHeight, 0)

        host.frame.size.width = 760
        settleKnowledgeHost(host)
        try assertStableReadOnlyKnowledgeSurface(
            host,
            expectedMarkdown: document.markdown,
            expectedTarget: destination.exactDisplayPath
        )
        let wideHeight = host.fittingSize.height
        XCTAssertTrue(wideHeight.isFinite)
        XCTAssertGreaterThan(wideHeight, 0)
    }
}

@MainActor
private func assertStableReadOnlyKnowledgeSurface(
    _ host: NSView,
    expectedMarkdown: String,
    expectedTarget: String
) throws {
    let descendants = host.knowledgeDescendants
    let editableTextFields = descendants.compactMap { $0 as? NSTextField }.filter(\.isEditable)
    let editableTextViews = descendants.compactMap { $0 as? NSTextView }.filter(\.isEditable)
    let selectionArtifacts = descendants.map { String(describing: type(of: $0)) }.filter {
        $0.contains("SelectionOverlay")
    }
    let selectableValues = descendants.compactMap { view -> String? in
        guard let field = view as? NSTextField, field.isSelectable else { return nil }
        return field.stringValue
    }

    XCTAssertTrue(editableTextFields.isEmpty)
    XCTAssertTrue(editableTextViews.isEmpty)
    XCTAssertTrue(selectionArtifacts.isEmpty)
    XCTAssertTrue(selectableValues.contains(expectedMarkdown))
    XCTAssertTrue(selectableValues.contains(expectedTarget))

    let markdownField = try XCTUnwrap(
        descendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == expectedMarkdown }
    )
    XCTAssertTrue(markdownField.isSelectable)
    XCTAssertFalse(markdownField.isEditable)
    XCTAssertEqual(markdownField.accessibilityValue(), expectedMarkdown)
}

private extension NSView {
    var knowledgeDescendants: [NSView] {
        subviews + subviews.flatMap(\.knowledgeDescendants)
    }
}

@MainActor
private func settleKnowledgeHost(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    for _ in 0..<4 {
        _ = RunLoop.main.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.002)
        )
        host.layoutSubtreeIfNeeded()
    }
}

private func viewUUID(_ suffix: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "B3100000-0000-0000-0000-%012llx",
            suffix
        )
    )!
}
