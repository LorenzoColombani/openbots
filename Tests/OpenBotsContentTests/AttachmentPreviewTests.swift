import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import OpenBotsDomain
import UniformTypeIdentifiers
import XCTest
@testable import OpenBotsContent

final class AttachmentPreviewTests: XCTestCase {
    func testOwnedTextPreservesExactBytesAndQuarantineWithoutCreatingFiles() async throws {
        let text = "  e\u{301}\n<script>nothing executes</script>\0 %PDF- is text\n"
        let fixture = try AttachmentPreviewFixture(Data(text.utf8), name: "notes.md", type: "net.daringfireball.markdown")
        let quarantine = Data("0081;66d0abcd;OpenBotsPreviewTest;fixture".utf8)
        try previewSetQuarantine(fixture.source, quarantine)
        try previewSetQuarantine(fixture.blob, quarantine)
        let sourceBefore = try previewStat(fixture.source)
        let blobBefore = try previewStat(fixture.blob)
        let filesBefore = try fixture.files()
        let result = try await fixture.preview()
        XCTAssertEqual(result, .text(value: text, isTruncated: false))
        XCTAssertEqual(try fixture.files(), filesBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data(text.utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.blob), Data(text.utf8))
        XCTAssertEqual(try previewStat(fixture.source).st_ino, sourceBefore.st_ino)
        XCTAssertEqual(try previewStat(fixture.source).st_mtimespec.tv_nsec, sourceBefore.st_mtimespec.tv_nsec)
        XCTAssertEqual(try previewStat(fixture.blob).st_ino, blobBefore.st_ino)
        XCTAssertEqual(try previewStat(fixture.blob).st_mtimespec.tv_nsec, blobBefore.st_mtimespec.tv_nsec)
        let fd = open(fixture.blob.path, O_RDONLY | O_NOFOLLOW)
        defer { close(fd) }
        XCTAssertEqual(try AttachmentQuarantine.read(fd), quarantine)
    }

    func testStrictUTF8TruncatesOnlyAtSafeBoundaryAndValidatesBeyondPrefix() throws {
        let prefix = String(repeating: "a", count: AttachmentPreviewLimits.maximumTextBytes - 1)
        let text = prefix + "🐦suffix"
        let result = try render(Data(text.utf8), name: "text.txt", type: "public.plain-text")
        XCTAssertEqual(result, .text(value: prefix, isTruncated: true))
        let exact = String(repeating: "a", count: AttachmentPreviewLimits.maximumTextBytes)
        XCTAssertEqual(try render(Data(exact.utf8)), .text(value: exact, isTruncated: false))
        XCTAssertEqual(try render(Data()), .text(value: "", isTruncated: false))
        var invalid = Data(text.utf8)
        invalid.append(0xFF)
        XCTAssertEqual(try render(invalid), .unavailable(.invalidTextEncoding))
        for invalid in [Data([0xC0, 0xAF]), Data([0xF0, 0x9F]), Data([0xFF, 0xFE, 0x41, 0x00])] {
            XCTAssertEqual(try render(invalid), .unavailable(.invalidTextEncoding))
        }
    }

    func testUnsupportedAndFalseFormatHintsDoNotEstablishValidity() throws {
        XCTAssertEqual(try render(Data([0x50, 0x4B, 0x03, 0x04, 0x00]), name: "archive.zip", type: "public.zip-archive"), .unavailable(.unsupportedType))
        XCTAssertEqual(try render(Data("<svg><script>ignored</script></svg>".utf8), name: "art.svg", type: "public.svg-image"), .unavailable(.unsupportedType))
        XCTAssertThrowsError(try render(Data("not an image".utf8), name: "forged.png", type: "public.png")) {
            XCTAssertEqual($0 as? AttachmentPreviewRenderingError, .malformedImage)
        }
        XCTAssertThrowsError(try render(Data("not a PDF".utf8), name: "forged.pdf", type: "com.adobe.pdf")) {
            XCTAssertEqual($0 as? AttachmentPreviewRenderingError, .malformedPDF)
        }
        XCTAssertThrowsError(try render(Data("%PDF-1.7\ninvalid".utf8), name: "forged.txt", type: "public.plain-text"))
    }

    func testRasterUsesActualImageTypeDownsamplesAndStripsMetadata() async throws {
        let original = try previewImageData(width: 2_000, height: 100, type: UTType.png.identifier, frames: 1)
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil)), 0, nil) as? [CFString: Any])
        let originalExif = originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(originalExif?[kCGImagePropertyExifUserComment] as? String, "synthetic private comment")
        // A misleading filename cannot prevent actual ImageIO type validation.
        let fixture = try AttachmentPreviewFixture(original, name: "claimed-text.txt", type: "public.plain-text")
        let files = try fixture.files()
        guard case let .image(png, width, height) = try await fixture.preview() else { return XCTFail("Expected image") }
        XCTAssertEqual(width, 1_600)
        XCTAssertEqual(height, 80)
        try assertPNG(png, width: width, height: height)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil)), 0, nil) as? [CFString: Any])
        // ImageIO synthesizes ColorSpace/PixelDimensions for the new PNG. Those
        // generated values are not retained private source EXIF metadata.
        let outputExif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(outputExif?[kCGImagePropertyExifUserComment])
        XCTAssertTrue(Set(outputExif?.keys.map { $0 as String } ?? []).isSubset(of: [
            kCGImagePropertyExifColorSpace as String, kCGImagePropertyExifPixelXDimension as String,
            kCGImagePropertyExifPixelYDimension as String
        ]))
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try fixture.files(), files)
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        XCTAssertEqual(try Data(contentsOf: fixture.blob), original)
    }

    func testRasterRendersOnlyFirstFrameAndRejectsOversizedMetadataBeforeDecode() throws {
        let gif = try previewImageData(width: 40, height: 20, type: UTType.gif.identifier, frames: 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        guard case let .image(png, width, height) = try render(gif, name: "animation.gif", type: UTType.gif.identifier) else { return XCTFail("Expected first frame") }
        XCTAssertEqual(width, 40)
        XCTAssertEqual(height, 20)
        try assertPNG(png, width: width, height: height)
        var bomb = try previewImageData(width: 2, height: 2, type: UTType.png.identifier, frames: 1)
        // A contradictory IHDR/IDAT is rejected by ImageIO itself before usable
        // dimensions are returned. Preserve that distinct malformed-file proof.
        bomb.replaceSubrange(16..<20, with: previewBigEndian(10_000))
        bomb.replaceSubrange(20..<24, with: previewBigEndian(5_000))
        bomb.replaceSubrange(29..<33, with: previewBigEndian(previewCRC32(Data(bomb[12..<29]))))
        XCTAssertThrowsError(try render(bomb, name: "huge.png", type: "public.png")) {
            XCTAssertEqual($0 as? AttachmentPreviewRenderingError, .malformedImage)
        }
        // Exercise the exact pre-thumbnail pixel gate without allocating an
        // oversized image merely to test the metadata admission arithmetic.
        XCTAssertTrue(AttachmentPreviewRenderer.isAllowedRasterSize(width: 10_000, height: 4_000))
        XCTAssertFalse(AttachmentPreviewRenderer.isAllowedRasterSize(width: 10_000, height: 5_000))
        XCTAssertFalse(AttachmentPreviewRenderer.isAllowedRasterSize(width: Int.max, height: Int.max))
        XCTAssertFalse(AttachmentPreviewRenderer.isAllowedRasterSize(width: 1, height: 0))
        XCTAssertFalse(AttachmentPreviewRenderer.isAllowedRasterSize(width: -1, height: 1))
    }

    func testPDFSelectedPagesAreBoundedPNGAndOriginalRemainsUntouched() async throws {
        let data = try previewPDF(pageSizes: [CGSize(width: 120, height: 200), CGSize(width: 300, height: 100)])
        let fixture = try AttachmentPreviewFixture(data, name: "report.pdf", type: "com.adobe.pdf")
        let files = try fixture.files()
        guard case let .pdfPage(first, width, height, page, count) = try await fixture.preview() else { return XCTFail("Expected PDF") }
        XCTAssertEqual(page, 1)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(width, 960)
        XCTAssertEqual(height, 1_600)
        try assertPNG(first, width: width, height: height)
        guard case let .pdfPage(second, secondWidth, secondHeight, secondPage, secondCount) = try await fixture.preview(page: 2) else { return XCTFail("Expected second page") }
        XCTAssertEqual(secondPage, 2)
        XCTAssertEqual(secondCount, 2)
        XCTAssertEqual(secondWidth, 1_600)
        XCTAssertEqual(secondHeight, 533)
        XCTAssertNotEqual(first, second)
        try assertPNG(second, width: secondWidth, height: secondHeight)
        XCTAssertEqual(try fixture.files(), files)
        XCTAssertEqual(try Data(contentsOf: fixture.source), data)
        XCTAssertEqual(try Data(contentsOf: fixture.blob), data)
    }

    func testPDFEncryptionPageCapAndInvalidPageNumbers() throws {
        let encrypted = try previewPDF(pageSizes: [CGSize(width: 100, height: 100)], encrypted: true)
        XCTAssertTrue(try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: encrypted as CFData)))).isEncrypted)
        XCTAssertEqual(try render(encrypted, name: "locked.pdf", type: "com.adobe.pdf"), .unavailable(.passwordProtectedPDF))
        let tooMany = try previewPDF(pageSizes: Array(repeating: CGSize(width: 10, height: 10), count: 501))
        XCTAssertEqual(try render(tooMany, name: "long.pdf", type: "com.adobe.pdf"), .unavailable(.tooManyPDFPages))
        let one = try previewPDF(pageSizes: [CGSize(width: 100, height: 100)])
        for page in [-1, 0, 2, 501, Int.max] {
            XCTAssertThrowsError(try AttachmentPreviewRenderer.render(one, displayName: "one.pdf", typeIdentifier: "com.adobe.pdf", pageNumber: page)) {
                XCTAssertEqual($0 as? AttachmentPreviewRenderingError, .invalidPageNumber)
            }
        }
    }

    func testPDFSizingNeverConvertsNonfiniteValuesToIntegers() throws {
        for edge in [CGFloat.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude] {
            let size = try AttachmentPreviewRenderer.pdfRasterSize(width: edge, height: edge)
            XCTAssertEqual(size.width, 1_600)
            XCTAssertEqual(size.height, 1_600)
        }
        let thin = try AttachmentPreviewRenderer.pdfRasterSize(width: .leastNonzeroMagnitude, height: .greatestFiniteMagnitude)
        XCTAssertEqual(thin.width, 1)
        XCTAssertEqual(thin.height, 1_600)
        for invalid in [CGFloat.zero, -1, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try AttachmentPreviewRenderer.pdfRasterSize(width: invalid, height: 100))
            XCTAssertThrowsError(try AttachmentPreviewRenderer.pdfRasterSize(width: 100, height: invalid))
        }
    }

    func testInputCapStillVerifiesHashAndFileProtectionBeforeUnavailable() async throws {
        let data = Data(repeating: 0x61, count: AttachmentPreviewLimits.maximumInputBytes + 1)
        let fixture = try AttachmentPreviewFixture(data)
        let result = try await fixture.preview()
        XCTAssertEqual(result, .unavailable(.fileTooLarge))
        do {
            _ = try await fixture.store.preview(id: fixture.id, byteCount: Int64(data.count), sha256: String(repeating: "0", count: 64), displayName: fixture.name, typeIdentifier: fixture.type)
            XCTFail("Size does not bypass integrity")
        } catch { XCTAssertEqual(error as? AttachmentContentError, .contentMismatch) }
        XCTAssertEqual(chmod(fixture.blob.path, 0o644), 0)
        do { _ = try await fixture.preview(); XCTFail("Size does not bypass protection") }
        catch { XCTAssertEqual(error as? AttachmentContentError, .unsafeFile) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), data)
    }

    func testMissingHashSizeModeSymlinkAndHardlinkFailuresAreNotUnavailable() async throws {
        for mutation in ["missing", "hash", "size", "mode", "symlink", "hardlink"] {
            let fixture = try AttachmentPreviewFixture(Data("saved text".utf8))
            switch mutation {
            case "missing": try FileManager.default.removeItem(at: fixture.blob)
            case "hash": try Data("other text".utf8).write(to: fixture.blob)
            case "size": try Data("short".utf8).write(to: fixture.blob)
            case "mode": XCTAssertEqual(chmod(fixture.blob.path, 0o644), 0)
            case "symlink":
                try FileManager.default.removeItem(at: fixture.blob)
                try FileManager.default.createSymbolicLink(at: fixture.blob, withDestinationURL: fixture.source)
            default: XCTAssertEqual(link(fixture.blob.path, fixture.fixture.root.appending(path: "linked").path), 0)
            }
            do { _ = try await fixture.preview(); XCTFail("Must reject \(mutation)") }
            catch { XCTAssertTrue(error is AttachmentContentError) }
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("saved text".utf8))
        }
    }

    func testReplacementAndQuarantineChangeDuringRenderingRejectCapturedResult() async throws {
        for mutation in ["file", "root", "quarantine"] {
            let fixture = try AttachmentPreviewFixture(Data("original".utf8))
            let store = AttachmentContentStore(root: fixture.verified, hooks: AttachmentContentTestHooks(afterPreviewRendering: {
                switch mutation {
                case "file":
                    try FileManager.default.moveItem(at: fixture.blob, to: fixture.blob.appendingPathExtension("preserved"))
                    try Data("original".utf8).write(to: fixture.blob)
                    guard chmod(fixture.blob.path, 0o600) == 0 else { throw POSIXError(.EIO) }
                case "root":
                    let root = fixture.verified.url
                    try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("preserved"))
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                default: try previewSetQuarantine(fixture.blob, Data("0081;fixture;changed".utf8))
                }
            }))
            do { _ = try await fixture.preview(using: store); XCTFail("Changed input during render") }
            catch { XCTAssertTrue(error is AttachmentContentError) }
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("original".utf8))
        }
    }

    func testCancellationBeforeAndAfterDecodeProducesNoPreviewOrWrites() async throws {
        let fixture = try AttachmentPreviewFixture(Data("unchanged".utf8))
        let files = try fixture.files()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.preview()
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        for after in [false, true] {
            let cancel: @Sendable () throws -> Void = { withUnsafeCurrentTask { $0?.cancel() } }
            let hooks = after ? AttachmentContentTestHooks(afterPreviewRendering: cancel) : AttachmentContentTestHooks(beforePreviewRendering: cancel)
            do { _ = try await fixture.preview(using: AttachmentContentStore(root: fixture.verified, hooks: hooks)); XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(try fixture.files(), files)
        XCTAssertEqual(try Data(contentsOf: fixture.blob), Data("unchanged".utf8))
    }

    func testReadAndDecodeRemainOffMainActor() async throws {
        let fixture = try AttachmentPreviewFixture(try previewImageData(width: 40, height: 20, type: UTType.png.identifier, frames: 1), name: "image.png", type: "public.png")
        let threads = PreviewThreadObservations()
        let store = AttachmentContentStore(root: fixture.verified, hooks: AttachmentContentTestHooks(
            beforeVerificationCompletes: { threads.record() },
            beforePreviewRendering: { threads.record() }, afterPreviewRendering: { threads.record() }
        ))
        let task = await MainActor.run { Task { @MainActor in try await fixture.preview(using: store) } }
        _ = try await task.value
        XCTAssertEqual(threads.values, [false, false, false])
    }

    private func render(_ data: Data, name: String = "text.txt", type: String = "public.plain-text") throws -> AttachmentPreview {
        try AttachmentPreviewRenderer.render(data, displayName: name, typeIdentifier: type, pageNumber: 1)
    }

    private func assertPNG(_ data: Data, width: Int, height: Int) throws {
        XCTAssertLessThanOrEqual(data.count, AttachmentPreviewLimits.maximumPNGBytes)
        XCTAssertLessThanOrEqual(max(width, height), AttachmentPreviewLimits.maximumRasterEdge)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }
}

private final class AttachmentPreviewFixture: @unchecked Sendable {
    let fixture: ContentTemporaryFixture
    let verified: VerifiedAttachmentContentRoot
    let id = AttachmentID(UUID())
    let data: Data
    let name: String
    let type: String
    let source: URL
    let blob: URL
    let store: AttachmentContentStore
    var digest: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    init(_ data: Data, name: String = "text.txt", type: String = "public.plain-text") throws {
        fixture = try ContentTemporaryFixture()
        self.data = data
        self.name = name
        self.type = type
        let installation = UUID(), root = UUID()
        try fixture.materializeOwnedRoot(fixture.layout.applicationSupportRoot, installationID: installation, rootID: root)
        try FileManager.default.createDirectory(at: fixture.layout.highChurnRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let owned = try OwnedRootVerifier().verify(fixture.layout.applicationSupportRoot, expectedInstallationID: installation, expectedRootID: root)
        verified = try AttachmentContentRootProvisioner().prepare(inside: owned)
        store = AttachmentContentStore(root: verified)
        source = fixture.root.appending(path: name)
        blob = verified.url.appending(path: id.persistedValue + ".blob")
        try data.write(to: source, options: .withoutOverwriting)
        try data.write(to: blob, options: .withoutOverwriting)
        guard chmod(blob.path, 0o600) == 0 else { throw POSIXError(.EIO) }
    }

    func preview(page: Int = 1, using store: AttachmentContentStore? = nil) async throws -> AttachmentPreview {
        try await (store ?? self.store).preview(id: id, byteCount: Int64(data.count), sha256: digest, displayName: name, typeIdentifier: type, pageNumber: page)
    }
    func files() throws -> [String] { try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() }
}

private func previewImageData(width: Int, height: Int, type: String, frames: Int) throws -> Data {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
    for frame in 0..<frames {
        context.setFillColor(CGColor(red: frame == 0 ? 1 : 0, green: frame == 0 ? 0 : 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic private comment"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0]
        ] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func previewPDF(pageSizes: [CGSize], encrypted: Bool = false) throws -> Data {
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data))
    var defaultBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    let metadata = encrypted ? [kCGPDFContextOwnerPassword: "synthetic-owner", kCGPDFContextUserPassword: "synthetic-reader"] as CFDictionary : nil
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &defaultBox, metadata))
    for (index, size) in pageSizes.enumerated() {
        var rectangle = CGRect(origin: .zero, size: size)
        let box = Data(bytes: &rectangle, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
        context.setFillColor(CGColor(gray: index % 2 == 0 ? 0.2 : 0.8, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: size.width / 2, height: size.height / 2))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

private func previewBigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
}
private func previewCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
    }
    return crc ^ 0xFFFFFFFF
}
private func previewStat(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return value
}
private func previewSetQuarantine(_ url: URL, _ value: Data) throws {
    let result = value.withUnsafeBytes { setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
    guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}
private final class PreviewThreadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func record() { lock.withLock { storage.append(Thread.isMainThread) } }
}
