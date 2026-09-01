import Foundation
import OpenBotsDomain
import Testing

@Test("Preview receipts enforce bounded text, declared raster size and exact PDF page")
func previewReceiptValidation() throws {
    try AttachmentPreview.text(value: "Read-only", isTruncated: false).validate(requestedPage: 1)
    #expect(throws: AttachmentPreviewValidationError.invalidPayload) {
        try AttachmentPreview.text(value: String(repeating: "x", count: 262_145), isTruncated: true)
            .validate(requestedPage: 1)
    }
    let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    for value in [
        AttachmentPreview.image(png: signature, pixelWidth: 0, pixelHeight: 1),
        .image(png: signature, pixelWidth: 1, pixelHeight: 1_601),
        .image(png: Data(), pixelWidth: 1, pixelHeight: 1),
        .pdfPage(png: signature, pixelWidth: 1, pixelHeight: 1, pageNumber: 2, pageCount: 2),
        .pdfPage(png: signature, pixelWidth: 1, pixelHeight: 1, pageNumber: 1, pageCount: 501),
        .pdfPage(png: signature, pixelWidth: 1, pixelHeight: 1, pageNumber: 1, pageCount: 0)
    ] {
        #expect(throws: AttachmentPreviewValidationError.invalidPayload) {
            try value.validate(requestedPage: 1)
        }
    }
    #expect(throws: AttachmentPreviewValidationError.invalidPayload) {
        try AttachmentPreview.text(value: "wrong page", isTruncated: false).validate(requestedPage: 2)
    }
    #expect(throws: AttachmentPreviewValidationError.invalidPayload) {
        try AttachmentPreview.unavailable(.unsupportedType).validate(requestedPage: Int.max)
    }
}
