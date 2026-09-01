import AppKit
import ImageIO
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class AttachmentPreviewPresentationTests: XCTestCase {
    func testAbsentCallbackKeepsPreviewInertAndExistingAdapterCompatible() {
        let adapter = AttachmentPresentation(resolve: { _, _, _ in nil }, reveal: { _, _, _ in })
        XCTAssertNil(adapter.preview)
        let model = AttachmentPreviewModel()
        XCTAssertFalse(model.open(route: previewRoute(1), displayName: "notes.txt", previewer: adapter.preview))
        XCTAssertEqual(model.phase, .closed)
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.content)
    }

    func testExplicitOpenStartsImmediatelyAndDuplicateOpenDoesNotRepeatWork() async throws {
        let gate = PreviewTestGate()
        let source = PreviewTestSource([.init(.text(value: "Saved text", isTruncated: false), gate: gate)])
        let model = AttachmentPreviewModel()
        let route = previewRoute(2)
        XCTAssertTrue(model.open(route: route, displayName: "notes.txt", previewer: previewCallback(source)))
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(model.content)
        try await waitPreviewGate(gate)
        XCTAssertFalse(model.open(route: route, displayName: "changed title", previewer: previewCallback(source)))
        XCTAssertEqual(model.displayName, "notes.txt")
        await gate.release()
        try await waitPreviewSettled(model)
        XCTAssertEqual(previewText(model), "Saved text")
        let requests = await source.requests
        XCTAssertEqual(requests, [.init(route: route, page: 1)])
        model.close()
        XCTAssertNil(model.content)
        XCTAssertNil(model.route)
        XCTAssertTrue(model.displayName.isEmpty)
    }

    func testCloseCancelsAndLateOldResponseCannotReplaceReopenedSameRoute() async throws {
        let gate = PreviewTestGate()
        let source = PreviewTestSource([
            .init(.text(value: "Old closed preview", isTruncated: false), gate: gate),
            .init(.text(value: "Fresh reopened preview", isTruncated: false))
        ])
        let model = AttachmentPreviewModel()
        let route = previewRoute(3)
        model.open(route: route, displayName: "notes.txt", previewer: previewCallback(source))
        try await waitPreviewGate(gate)
        model.close()
        XCTAssertEqual(model.phase, .closed)
        XCTAssertNil(model.content)
        model.open(route: route, displayName: "notes.txt", previewer: previewCallback(source))
        try await waitPreviewSettled(model)
        await gate.release()
        try await waitPreviewCompleted(source, count: 2)
        XCTAssertEqual(previewText(model), "Fresh reopened preview")
        let cancellations = await source.cancelledCompletions
        XCTAssertEqual(cancellations, 1, "Closing must cancel its actual callback task, not merely hide results")
        model.close()
    }

    func testLateRouteCannotReplaceNewAttachmentPreview() async throws {
        let gate = PreviewTestGate()
        let source = PreviewTestSource([
            .init(.text(value: "First route", isTruncated: false), gate: gate),
            .init(.text(value: "Second route", isTruncated: false))
        ])
        let model = AttachmentPreviewModel()
        model.open(route: previewRoute(4), displayName: "first.txt", previewer: previewCallback(source))
        try await waitPreviewGate(gate)
        model.open(route: previewRoute(5), displayName: "second.txt", previewer: previewCallback(source))
        try await waitPreviewSettled(model)
        await gate.release()
        try await waitPreviewCompleted(source, count: 2)
        XCTAssertEqual(model.route, previewRoute(5))
        XCTAssertEqual(model.displayName, "second.txt")
        XCTAssertEqual(previewText(model), "Second route")
        model.close()
    }

    func testPageRequestsAreExactBoundedAndLatePageCannotReplaceNewerPage() async throws {
        let png = try previewPNG(width: 3, height: 4)
        let gate = PreviewTestGate()
        let source = PreviewTestSource([
            .init(.pdfPage(png: png, pixelWidth: 3, pixelHeight: 4, pageNumber: 1, pageCount: 3)),
            .init(.pdfPage(png: png, pixelWidth: 3, pixelHeight: 4, pageNumber: 2, pageCount: 3), gate: gate),
            .init(.pdfPage(png: png, pixelWidth: 3, pixelHeight: 4, pageNumber: 3, pageCount: 3))
        ])
        let model = AttachmentPreviewModel()
        let route = previewRoute(6)
        model.open(route: route, displayName: "report.pdf", previewer: previewCallback(source))
        try await waitPreviewSettled(model)
        XCTAssertFalse(model.canPreviousPage)
        XCTAssertTrue(model.canNextPage)
        model.requestPage(0)
        model.requestPage(4)
        model.requestPage(2)
        try await waitPreviewGate(gate)
        model.requestPage(2)
        model.requestPage(3)
        try await waitPreviewSettled(model)
        await gate.release()
        try await waitPreviewCompleted(source, count: 3)
        XCTAssertEqual(model.requestedPage, 3)
        XCTAssertTrue(model.canPreviousPage)
        XCTAssertFalse(model.canNextPage)
        guard case .pdfPage(let image, let page, let count) = model.content else { return XCTFail("Missing PDF page") }
        XCTAssertEqual(page, 3)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(image.cgImage.width, 3)
        let requests = await source.requests
        XCTAssertEqual(requests, [1, 2, 3].map { .init(route: route, page: $0) })
        model.close()
    }

    func testFailureIsSanitizedAndRetryKeepsExactRouteAndPage() async throws {
        let png = try previewPNG(width: 2, height: 3)
        let source = PreviewTestSource([
            .init(.pdfPage(png: png, pixelWidth: 2, pixelHeight: 3, pageNumber: 1, pageCount: 2)),
            .failure,
            .init(.pdfPage(png: png, pixelWidth: 2, pixelHeight: 3, pageNumber: 2, pageCount: 2))
        ])
        let model = AttachmentPreviewModel()
        let route = previewRoute(7)
        model.open(route: route, displayName: "report.pdf", previewer: previewCallback(source))
        try await waitPreviewSettled(model)
        model.requestPage(2)
        try await waitPreviewSettled(model)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.errorMessage?.contains("/Users/") ?? true)
        XCTAssertNil(model.content)
        XCTAssertEqual(model.requestedPage, 2)
        XCTAssertEqual(model.pageCount, 2)
        model.retry()
        try await waitPreviewSettled(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.errorMessage)
        let requests = await source.requests
        XCTAssertEqual(requests, [1, 2, 2].map { .init(route: route, page: $0) })
        model.close()
    }

    func testUnavailableIsTruthfulAndDoesNotAutomaticallyRetry() async throws {
        let source = PreviewTestSource([.init(.unavailable(.passwordProtectedPDF))])
        let model = AttachmentPreviewModel()
        model.open(route: previewRoute(8), displayName: "protected.pdf", previewer: previewCallback(source))
        try await waitPreviewSettled(model)
        XCTAssertEqual(model.phase, .unavailable)
        model.retry()
        let requests = await source.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(model.errorMessage)
        model.close()
    }

    func testInvalidAndUndeclaredLargePayloadsFailBeforePresentation() async throws {
        let validPNG = try previewPNG(width: 2, height: 3)
        let oversizedActualPNG = try previewPNG(width: AttachmentPreviewLimits.maximumRasterEdge + 1, height: 1)
        let candidates: [AttachmentPreview] = [
            .text(value: String(repeating: "a", count: AttachmentPreviewLimits.maximumTextBytes + 1), isTruncated: false),
            .image(png: validPNG, pixelWidth: 3, pixelHeight: 2),
            .image(png: oversizedActualPNG, pixelWidth: 2, pixelHeight: 1),
            .image(png: Data([137, 80, 78, 71, 13, 10, 26, 10]), pixelWidth: 2, pixelHeight: 3),
            .image(png: Data(repeating: 0, count: AttachmentPreviewLimits.maximumPNGBytes + 1), pixelWidth: 2, pixelHeight: 3),
            .pdfPage(png: validPNG, pixelWidth: 2, pixelHeight: 3, pageNumber: 2, pageCount: 2),
            .pdfPage(png: validPNG, pixelWidth: 2, pixelHeight: 3, pageNumber: 1, pageCount: 501)
        ]
        for candidate in candidates {
            let source = PreviewTestSource([.init(candidate)])
            let model = AttachmentPreviewModel()
            model.open(route: previewRoute(9), displayName: "untrusted.bin", previewer: previewCallback(source))
            try await waitPreviewSettled(model)
            XCTAssertEqual(model.phase, .failed)
            XCTAssertNil(model.content)
            model.close()
        }
    }

    func testPlainTextIsSelectableNotEditableOrLinkEnabledWithFiniteViewport() async throws {
        let text = "Plain text <script>no execution</script> https://example.invalid\n" + String(repeating: "bounded text\n", count: 1_000)
        for scheme in [ColorScheme.light, .dark] {
            // Each preview owns its request lifetime. Removing the previous
            // host legitimately closes it; never reuse that closed model as
            // evidence for a second presentation.
            let source = PreviewTestSource([.init(.text(value: text, isTruncated: true))])
            let model = AttachmentPreviewModel()
            model.open(route: previewRoute(10), displayName: "research.txt", previewer: previewCallback(source))
            try await waitPreviewSettled(model)
            let controller = NSHostingController(rootView: AttachmentPreviewView(model: model).environment(\.colorScheme, scheme))
            controller.view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for width: CGFloat in [360, 760] {
                try await assertPreviewLayout(controller, width: width)
                try capturePreview(controller.view, name: "text-\(scheme)-\(Int(width))")
                let textViews = controller.view.previewDescendants.compactMap { $0 as? NSTextView }
                let reader = try XCTUnwrap(textViews.first)
                XCTAssertEqual(textViews.count, 1)
                XCTAssertEqual(reader.string, text)
                XCTAssertTrue(reader.isSelectable)
                XCTAssertFalse(reader.isEditable)
                XCTAssertFalse(reader.isRichText)
                XCTAssertFalse(reader.importsGraphics)
                XCTAssertFalse(reader.isAutomaticLinkDetectionEnabled)
                XCTAssertFalse(reader.isAutomaticDataDetectionEnabled)
                XCTAssertNil(reader.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
                XCTAssertNotNil(reader.enclosingScrollView)
            }
            model.close()
        }
    }

    func testPDFImageAndFailureViewsHaveFiniteNarrowAndWideBounds() async throws {
        let png = try previewPNG(width: 24, height: 32)
        for (index, reply) in [
            PreviewTestReply(.image(png: png, pixelWidth: 24, pixelHeight: 32)),
            .init(.pdfPage(png: png, pixelWidth: 24, pixelHeight: 32, pageNumber: 1, pageCount: 2)),
            .init(.unavailable(.unsupportedType)), .failure
        ].enumerated() {
            let source = PreviewTestSource([reply])
            let model = AttachmentPreviewModel()
            model.open(route: previewRoute(11), displayName: "Research and supporting evidence.pdf", previewer: previewCallback(source))
            try await waitPreviewSettled(model)
            let controller = NSHostingController(rootView: AttachmentPreviewView(model: model))
            for width: CGFloat in [360, 760] {
                try await assertPreviewLayout(controller, width: width)
                if index < 2 { try capturePreview(controller.view, name: "\(index == 0 ? "image" : "pdf")-\(Int(width))") }
            }
            model.close()
        }
    }

    func testLoadingIsCancellableAndRenderingNeverStartsAnotherRequest() async throws {
        let gate = PreviewTestGate()
        let source = PreviewTestSource([.init(.text(value: "not yet visible", isTruncated: false), gate: gate)])
        let model = AttachmentPreviewModel()
        model.open(route: previewRoute(12), displayName: "notes.txt", previewer: previewCallback(source))
        try await waitPreviewGate(gate)
        let controller = NSHostingController(rootView: AttachmentPreviewView(model: model))
        for width: CGFloat in [360, 760] { try await assertPreviewLayout(controller, width: width) }
        let requests = await source.requests
        XCTAssertEqual(requests.count, 1)
        model.close()
        await gate.release()
        try await waitPreviewCompleted(source, count: 1)
        XCTAssertNil(model.content)
        XCTAssertEqual(model.phase, .closed)
    }

    func testChipMetadataRenderingDoesNotInvokeConfiguredPreview() async throws {
        let route = previewRoute(13)
        let source = PreviewTestSource([])
        let asset = try AttachmentAsset(
            id: AttachmentID(route.attachmentID), conversationID: ConversationID(route.messageID),
            displayName: "Research.txt", typeIdentifier: "public.plain-text", byteCount: 4,
            sha256: String(repeating: "a", count: 64), createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let adapter = AttachmentPresentation(resolve: { _, _, _ in asset }, reveal: { _, _, _ in }, preview: previewCallback(source))
        let message = ChatMessageSnapshot(
            id: route.messageID, author: .user,
            parts: [.init(id: route.partID, ordinal: 0, content: .attachment(.init(id: route.attachmentID, displayName: "Attachment")))],
            delivery: .sent, timestamp: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let controller = NSHostingController(rootView: TranscriptMessagePartsView(message: message).environment(\.attachmentPresentation, adapter))
        controller.view.frame = CGRect(x: 0, y: 0, width: 270, height: 300)
        for _ in 0..<4 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let size = controller.sizeThatFits(in: CGSize(width: 270, height: 300))
        XCTAssertLessThanOrEqual(size.width, 270.5)
        let requests = await source.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSourceKeepsExactScopedActionAndNativeCloseWithoutDocumentAuthority() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chip = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/TranscriptMessagePartsView.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("Sources/OpenBotsUI/AttachmentPreviewView.swift"), encoding: .utf8)
        XCTAssertTrue(chip.contains("if let previewer = presentation?.preview"))
        XCTAssertTrue(chip.contains("Button(\"Preview\")"))
        XCTAssertTrue(chip.contains(".onChange(of: route) { _, _ in previewModel.close() }"))
        XCTAssertTrue(view.contains("Button(\"Close Preview\")"))
        XCTAssertTrue(view.contains("Button(\"Previous Page\")"))
        XCTAssertTrue(view.contains("Button(\"Next Page\")"))
        XCTAssertTrue(view.contains(".disabled(!model.canPreviousPage)"))
        XCTAssertTrue(view.contains(".disabled(!model.canNextPage)"))
        XCTAssertTrue(view.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(view.contains("Text isn’t extracted or searchable; forms and links aren’t interactive."))
        for forbidden in ["WKWebView", "QLPreview", "PDFView", "NSWorkspace", "URL(", "Button(\"Save", "Button(\"Open", "textSelection("] {
            XCTAssertFalse(view.contains(forbidden), "Unexpected preview authority: \(forbidden)")
        }
    }

    private func assertPreviewLayout<Content: View>(_ controller: NSHostingController<Content>, width: CGFloat) async throws {
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: width, height: 520)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        let measured = controller.sizeThatFits(in: CGSize(width: width, height: 520))
        XCTAssertTrue(measured.width.isFinite && measured.height.isFinite)
        XCTAssertGreaterThan(measured.width, 0)
        XCTAssertGreaterThan(measured.height, 0)
        XCTAssertLessThanOrEqual(measured.width, width + 0.5)
        XCTAssertLessThanOrEqual(measured.height, 520.5)
        let buttons = host.previewDescendants.compactMap { $0 as? NSButton }
        for button in buttons {
            let frame = button.convert(button.bounds, to: host)
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            XCTAssertEqual(button.accessibilityRole(), .button)
        }
        print("Attachment preview rendered at \(width)x520: \(measured), raw NSButton descendants \(buttons.count)")
        // Owned, offscreen rendered content only. Sheet presentation, Escape,
        // Tab, VoiceOver and coordinator physical inspection are not proven.
        // SwiftUI can draw native-styled buttons without raw NSButton children.
        // Their labels/bindings are source-asserted and visible in the captured
        // bitmap; only actually exposed NSButton metadata is asserted here.
    }

    private func capturePreview(_ host: NSView, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/shutdown-ui-tests/file-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private struct PreviewTestRequest: Equatable, Sendable {
    let route: AttachmentPresentationRoute
    let page: Int
}

private struct PreviewTestReply: Sendable {
    let value: AttachmentPreview?
    let gate: PreviewTestGate?
    init(_ value: AttachmentPreview, gate: PreviewTestGate? = nil) { self.value = value; self.gate = gate }
    private init() { value = nil; gate = nil }
    static let failure = Self()
}

private actor PreviewTestSource {
    private let replies: [PreviewTestReply]
    private(set) var requests: [PreviewTestRequest] = []
    private(set) var completed = 0
    private(set) var cancelledCompletions = 0
    init(_ replies: [PreviewTestReply]) { self.replies = replies }
    func load(route: AttachmentPresentationRoute, page: Int) async throws -> AttachmentPreview {
        let index = requests.count
        requests.append(.init(route: route, page: page))
        guard replies.indices.contains(index) else { throw PreviewTestFailure() }
        let reply = replies[index]
        if let gate = reply.gate { await gate.wait() }
        completed += 1
        if Task.isCancelled { cancelledCompletions += 1 }
        guard let value = reply.value else { throw PreviewTestFailure() }
        return value
    }
}

private actor PreviewTestGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct PreviewTestFailure: LocalizedError {
    var errorDescription: String? { "Cannot read /Users/example/private/research.txt" }
}

@MainActor
private func previewCallback(_ source: PreviewTestSource) -> AttachmentPresentation.Previewer {
    { message, part, attachment, page in
        try await source.load(route: .init(messageID: message, partID: part, attachmentID: attachment), page: page)
    }
}

@MainActor
private func previewText(_ model: AttachmentPreviewModel) -> String? {
    if case .text(let text, _) = model.content { return text }
    return nil
}

@MainActor
private func waitPreviewSettled(_ model: AttachmentPreviewModel) async throws {
    for _ in 0..<500 {
        if !model.isLoading { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PreviewTestTimeout()
}

private func waitPreviewGate(_ gate: PreviewTestGate) async throws {
    for _ in 0..<500 {
        if await gate.started { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PreviewTestTimeout()
}

private func waitPreviewCompleted(_ source: PreviewTestSource, count: Int) async throws {
    for _ in 0..<500 {
        if await source.completed == count { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PreviewTestTimeout()
}

private struct PreviewTestTimeout: Error {}

private func previewRoute(_ value: UInt64) -> AttachmentPresentationRoute {
    func id(_ suffix: UInt64) -> UUID { UUID(uuidString: String(format: "AD900000-0000-0000-0000-%012llx", suffix))! }
    return .init(messageID: id(value * 10), partID: id(value * 10 + 1), attachmentID: id(value * 10 + 2))
}

private func previewPNG(width: Int, height: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private extension NSView {
    var previewDescendants: [NSView] { subviews + subviews.flatMap(\.previewDescendants) }
}
