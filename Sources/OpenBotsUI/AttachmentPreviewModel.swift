import Combine
import Foundation
import ImageIO
import OpenBotsDomain

/// One explicitly opened, read-only preview. A route is a reference to verify,
/// never file authority; no URL, repository or document framework enters here.
@MainActor
final class AttachmentPreviewModel: ObservableObject {
    enum Phase: Equatable { case closed, loading, ready, unavailable, failed }

    @Published private(set) var isPresented = false
    @Published private(set) var phase = Phase.closed
    @Published private(set) var displayName = ""
    @Published private(set) var content: AttachmentPreviewContent?
    @Published private(set) var requestedPage = 1
    @Published private(set) var pageCount: Int?
    @Published private(set) var errorMessage: String?

    private(set) var route: AttachmentPresentationRoute?
    private var previewer: AttachmentPresentation.Previewer?
    private let decoder = AttachmentPreviewDecoder()
    private var generation: UInt64 = 0
    private var requestTask: Task<Void, Never>?

    var isLoading: Bool { phase == .loading }
    var canPreviousPage: Bool { !isLoading && pageCount != nil && requestedPage > 1 }
    var canNextPage: Bool { !isLoading && requestedPage < (pageCount ?? 1) }

    @discardableResult
    func open(
        route: AttachmentPresentationRoute, displayName: String,
        previewer: AttachmentPresentation.Previewer?
    ) -> Bool {
        guard let previewer else { return false }
        guard !isPresented || self.route != route else { return false }
        close()
        self.route = route
        self.displayName = displayName
        self.previewer = previewer
        isPresented = true
        startRequest(page: 1)
        return true
    }

    func close() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        isPresented = false
        phase = .closed
        content = nil
        route = nil
        previewer = nil
        displayName = ""
        requestedPage = 1
        pageCount = nil
        errorMessage = nil
    }

    func requestPage(_ page: Int) {
        guard isPresented, let pageCount, (1...pageCount).contains(page),
              requestedPage != page else { return }
        startRequest(page: page)
    }

    func retry() {
        guard isPresented, phase == .failed else { return }
        startRequest(page: requestedPage)
    }

    private func startRequest(page: Int) {
        guard let route, let previewer else { return }
        generation &+= 1
        let request = generation
        requestTask?.cancel()
        requestedPage = page
        phase = .loading
        content = nil
        errorMessage = nil
        let decoder = decoder
        requestTask = Task { [weak self] in
            do {
                let receipt = try await previewer(route.messageID, route.partID, route.attachmentID, page)
                try Task.checkCancellation()
                let prepared = try await decoder.prepare(receipt, requestedPage: page)
                try Task.checkCancellation()
                guard let self, self.generation == request, self.isPresented else { return }
                self.content = prepared
                if case .pdfPage(_, _, let pageCount) = prepared { self.pageCount = pageCount }
                else { self.pageCount = nil }
                if case .unavailable = prepared { self.phase = .unavailable }
                else { self.phase = .ready }
                self.requestTask = nil
            } catch {
                guard let self, self.generation == request, self.isPresented else { return }
                self.phase = .failed
                self.requestTask = nil
                // Provider errors may contain private paths. Never surface
                // their raw descriptions in the transcript or preview.
                self.errorMessage = "OpenBots couldn’t preview this saved file. Retry or close the preview. Your files were not changed."
            }
        }
    }
}

enum AttachmentPreviewContent: Sendable {
    case text(String, isTruncated: Bool)
    case image(AttachmentPreviewImage)
    case pdfPage(AttachmentPreviewImage, pageNumber: Int, pageCount: Int)
    case unavailable(AttachmentPreviewUnavailableReason)
}

/// The immutable image has been eagerly decoded on a non-main actor before it
/// reaches SwiftUI. No decoding or document parsing occurs during body updates.
struct AttachmentPreviewImage: @unchecked Sendable {
    let cgImage: CGImage
}

private enum AttachmentPreviewReceiptError: Error { case invalid }

private actor AttachmentPreviewDecoder {
    func prepare(_ receipt: AttachmentPreview, requestedPage: Int) throws -> AttachmentPreviewContent {
        try Task.checkCancellation()
        try receipt.validate(requestedPage: requestedPage)
        switch receipt {
        case .text(let value, let truncated):
            return .text(value, isTruncated: truncated)
        case .image(let png, let width, let height):
            return .image(try decode(png, width: width, height: height))
        case .pdfPage(let png, let width, let height, let pageNumber, let pageCount):
            return .pdfPage(try decode(png, width: width, height: height), pageNumber: pageNumber, pageCount: pageCount)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    private func decode(_ data: Data, width: Int, height: Int) throws -> AttachmentPreviewImage {
        guard !data.isEmpty, data.count <= AttachmentPreviewLimits.maximumPNGBytes,
              (1...AttachmentPreviewLimits.maximumRasterEdge).contains(width),
              (1...AttachmentPreviewLimits.maximumRasterEdge).contains(height),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width == width, image.height == height else {
            throw AttachmentPreviewReceiptError.invalid
        }
        try Task.checkCancellation()
        return AttachmentPreviewImage(cgImage: image)
    }
}
