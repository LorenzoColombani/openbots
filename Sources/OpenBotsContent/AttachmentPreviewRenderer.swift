import CoreGraphics
import Foundation
import ImageIO
import OpenBotsDomain
import UniformTypeIdentifiers

public enum AttachmentPreviewRenderingError: Error, Equatable, Sendable {
    case invalidPageNumber
    case malformedImage
    case malformedPDF
    case renderingFailed
}

/// Data-only renderer. Neither this type nor the system decoders receive a file
/// URL, external-resource resolver, view, script context or launch mechanism.
/// Cancellation is checked around synchronous system decoders; those decoders
/// are not claimed to be preemptible or contained in a separate process.
enum AttachmentPreviewRenderer {
    static let maximumImagePixelCount = ProfilePhotoContentStore.maximumSourcePixelCount
    static let rasterTypes: Set<String> = [
        "public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff",
        "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp"
    ]

    private static let textTypes: Set<String> = [
        "public.text", "public.plain-text", "public.utf8-plain-text", "public.source-code",
        "public.json", "public.xml", "public.html", "public.comma-separated-values-text",
        "public.tab-separated-values-text", "public.shell-script", "public.python-script",
        "public.javascript", "com.netscape.javascript-source", "net.daringfireball.markdown",
        "net.daringfireball.markdown.plain-text", "org.swift.swift-source", "public.css"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html", "htm",
        "css", "js", "ts", "jsx", "tsx", "swift", "py", "sh", "zsh", "bash", "c", "h",
        "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "yaml", "yml", "toml",
        "ini", "conf", "log", "sql", "tex", "rst"
    ]

    static func render(
        _ data: Data, displayName: String, typeIdentifier: String, pageNumber: Int
    ) throws -> AttachmentPreview {
        try Task.checkCancellation()
        guard (1...AttachmentPreviewLimits.maximumPDFPages).contains(pageNumber) else {
            throw AttachmentPreviewRenderingError.invalidPageNumber
        }
        guard data.count <= AttachmentPreviewLimits.maximumInputBytes else {
            return .unavailable(.fileTooLarge)
        }
        let result: AttachmentPreview
        let suffix = (displayName as NSString).pathExtension.lowercased()
        // Hints select a parser, never establish validity. Actual PDF/image
        // structure and UTF-8 are checked by the selected bounded decoder.
        if data.starts(with: Data("%PDF-".utf8))
            || typeIdentifier == "com.adobe.pdf" || suffix == "pdf" {
            result = try pdf(data, pageNumber: pageNumber)
        } else if let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary), let actualType = CGImageSourceGetType(source) {
            guard rasterTypes.contains(actualType as String) else { return .unavailable(.unsupportedType) }
            result = try image(source)
        } else if rasterTypes.contains(typeIdentifier) {
            throw AttachmentPreviewRenderingError.malformedImage
        } else if textTypes.contains(typeIdentifier) || textExtensions.contains(suffix) {
            result = text(data)
        } else {
            result = .unavailable(.unsupportedType)
        }
        try Task.checkCancellation()
        return result
    }

    private static func text(_ data: Data) -> AttachmentPreview {
        // Validate all captured bytes, including beyond the displayed prefix;
        // never replace malformed sequences or claim unvalidated text is UTF-8.
        guard String(data: data, encoding: .utf8) != nil else { return .unavailable(.invalidTextEncoding) }
        let limit = AttachmentPreviewLimits.maximumTextBytes
        if data.count <= limit {
            return .text(value: String(data: data, encoding: .utf8)!, isTruncated: false)
        }
        var prefix = Data(data.prefix(limit))
        // UTF-8 has at most three trailing continuation bytes at this boundary.
        for _ in 0...3 {
            if let value = String(data: prefix, encoding: .utf8) { return .text(value: value, isTruncated: true) }
            prefix.removeLast()
        }
        return .unavailable(.invalidTextEncoding)
    }

    private static func image(_ source: CGImageSource) throws -> AttachmentPreview {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = integerDimension(properties[kCGImagePropertyPixelWidth]),
              let height = integerDimension(properties[kCGImagePropertyPixelHeight]) else {
            throw AttachmentPreviewRenderingError.malformedImage
        }
        guard isAllowedRasterSize(width: width, height: height) else {
            return .unavailable(.imageTooLarge)
        }
        try Task.checkCancellation()
        // Intentionally the first frame only: no animated playback or eager
        // decode of all frames in GIF/TIFF/HEIF collections.
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AttachmentPreviewLimits.maximumRasterEdge,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw AttachmentPreviewRenderingError.malformedImage
        }
        try Task.checkCancellation()
        let bitmap = try context(width: thumbnail.width, height: thumbnail.height)
        bitmap.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        return .image(png: try png(bitmap), pixelWidth: thumbnail.width, pixelHeight: thumbnail.height)
    }

    static func isAllowedRasterSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumImagePixelCount / height
    }

    private static func pdf(_ data: Data, pageNumber: Int) throws -> AttachmentPreview {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw AttachmentPreviewRenderingError.malformedPDF
        }
        // Even PDFs unlocked by an empty password remain outside this preview
        // lane: do not request passwords or bypass document protection.
        guard !document.isEncrypted, document.isUnlocked else { return .unavailable(.passwordProtectedPDF) }
        let count = document.numberOfPages
        guard count > 0 else { throw AttachmentPreviewRenderingError.malformedPDF }
        guard count <= AttachmentPreviewLimits.maximumPDFPages else { return .unavailable(.tooManyPDFPages) }
        guard pageNumber <= count, let page = document.page(at: pageNumber) else {
            throw AttachmentPreviewRenderingError.invalidPageNumber
        }
        let box = page.getBoxRect(.cropBox)
        guard box.origin.x.isFinite, box.origin.y.isFinite,
              box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            throw AttachmentPreviewRenderingError.malformedPDF
        }
        let rotated = page.rotationAngle % 180 != 0
        let pageWidth = rotated ? box.height : box.width
        let pageHeight = rotated ? box.width : box.height
        let (width, height) = try pdfRasterSize(width: pageWidth, height: pageHeight)
        let bitmap = try context(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(bounds)
        let transform = page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) else {
            throw AttachmentPreviewRenderingError.malformedPDF
        }
        bitmap.concatenate(transform)
        try Task.checkCancellation()
        // Core Graphics raster drawing only. We never enumerate/activate PDF
        // actions, hyperlinks, form controls, embedded files or JavaScript.
        bitmap.drawPDFPage(page)
        try Task.checkCancellation()
        return .pdfPage(
            png: try png(bitmap), pixelWidth: width, pixelHeight: height,
            pageNumber: pageNumber, pageCount: count
        )
    }

    static func pdfRasterSize(width: CGFloat, height: CGFloat) throws -> (width: Int, height: Int) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw AttachmentPreviewRenderingError.malformedPDF
        }
        let longEdge = max(width, height)
        let edge = CGFloat(AttachmentPreviewLimits.maximumRasterEdge)
        // Ratios are finite in 0...1 even for subnormal/very large PDF boxes;
        // computing edge/longEdge first could overflow before Int conversion.
        return (max(1, Int((width / longEdge * edge).rounded(.down))),
                max(1, Int((height / longEdge * edge).rounded(.down))))
    }

    private static func integerDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value.rounded(.down) == value, value <= Double(Int32.max) else { return nil }
        return Int(value)
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard (1...AttachmentPreviewLimits.maximumRasterEdge).contains(width),
              (1...AttachmentPreviewLimits.maximumRasterEdge).contains(height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw AttachmentPreviewRenderingError.renderingFailed }
        return context
    }

    private static func png(_ bitmap: CGContext) throws -> Data {
        try Task.checkCancellation()
        guard let image = bitmap.makeImage() else { throw AttachmentPreviewRenderingError.renderingFailed }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw AttachmentPreviewRenderingError.renderingFailed
        }
        // Encode only the redrawn pixels: no source EXIF/GPS/comments/ICC data.
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), output.length > 0,
              output.length <= AttachmentPreviewLimits.maximumPNGBytes else {
            throw AttachmentPreviewRenderingError.renderingFailed
        }
        try Task.checkCancellation()
        return output as Data
    }
}
