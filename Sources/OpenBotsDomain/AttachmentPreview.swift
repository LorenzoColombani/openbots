import Foundation

/// A bounded, read-only presentation of verified owned bytes. Never a file URL,
/// executable document, embedded browser or permission to modify the original.
public enum AttachmentPreview: Equatable, Sendable {
    case text(value: String, isTruncated: Bool)
    case image(png: Data, pixelWidth: Int, pixelHeight: Int)
    case pdfPage(png: Data, pixelWidth: Int, pixelHeight: Int, pageNumber: Int, pageCount: Int)
    case unavailable(AttachmentPreviewUnavailableReason)

    /// Validate a renderer receipt without decoding untrusted image data on
    /// the caller's actor. The decoder also verifies actual PNG dimensions.
    public func validate(requestedPage: Int) throws {
        guard (1...AttachmentPreviewLimits.maximumPDFPages).contains(requestedPage) else {
            throw AttachmentPreviewValidationError.invalidPayload
        }
        switch self {
        case .text(let text, _):
            guard requestedPage == 1, text.utf8.count <= AttachmentPreviewLimits.maximumTextBytes else {
                throw AttachmentPreviewValidationError.invalidPayload
            }
        case .image(let png, let width, let height):
            guard requestedPage == 1 else { throw AttachmentPreviewValidationError.invalidPayload }
            try Self.validateImage(png, width: width, height: height)
        case .pdfPage(let png, let width, let height, let page, let count):
            guard (1...AttachmentPreviewLimits.maximumPDFPages).contains(count),
                  page == requestedPage, (1...count).contains(page) else {
                throw AttachmentPreviewValidationError.invalidPayload
            }
            try Self.validateImage(png, width: width, height: height)
        case .unavailable:
            break
        }
    }

    private static func validateImage(_ png: Data, width: Int, height: Int) throws {
        guard (1...AttachmentPreviewLimits.maximumRasterEdge).contains(width),
              (1...AttachmentPreviewLimits.maximumRasterEdge).contains(height),
              png.count <= AttachmentPreviewLimits.maximumPNGBytes,
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw AttachmentPreviewValidationError.invalidPayload
        }
    }
}

public enum AttachmentPreviewLimits {
    public static let maximumInputBytes = 32 * 1_024 * 1_024
    public static let maximumTextBytes = 256 * 1_024
    public static let maximumRasterEdge = 1_600
    public static let maximumPNGBytes = 16 * 1_024 * 1_024
    public static let maximumPDFPages = 500
}

public enum AttachmentPreviewValidationError: Error, Equatable, Sendable {
    case invalidPayload
}

public enum AttachmentPreviewUnavailableReason: Equatable, Sendable {
    case unsupportedType
    case fileTooLarge
    case invalidTextEncoding
    case imageTooLarge
    case passwordProtectedPDF
    case tooManyPDFPages
}
