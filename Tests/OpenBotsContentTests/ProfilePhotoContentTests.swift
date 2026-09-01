import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import OpenBotsDomain
import UniformTypeIdentifiers
import XCTest
@testable import OpenBotsContent

final class ProfilePhotoContentTests: XCTestCase {
    func testGeneratedFixtureImageIOSourceReadiness() throws {
        let data = try imageData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
        let type = CGImageSourceGetType(source) as String?
        XCTAssertEqual(type, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertTrue(ProfilePhotoContentStore.supportedSourceTypeIdentifiers.contains(try XCTUnwrap(type)))
    }

    func testNormalizationOrientsDownsamplesStripsMetadataAndPreservesSource() async throws {
        let context = try PhotoContentFixture()
        let data = try imageData(width: 1_200, height: 600, type: UTType.jpeg.identifier, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private photo comment"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "private camera owner"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLongitude: 42.5]
        ])
        let source = try context.source(data, name: "portrait.jpg")
        let before = try snapshot(source)
        let store = ProfilePhotoContentStore(root: context.verified)
        XCTAssertTrue(try context.assetNames().isEmpty, "Construction does not write.")
        let id = ProfileAssetID(UUID())
        let asset = try await store.importPhoto(from: source, id: id)
        let normalized = try await store.read(asset)
        XCTAssertEqual(asset.id, id)
        XCTAssertEqual(asset.width, 256)
        XCTAssertEqual(asset.height, 512)
        XCTAssertEqual(asset.byteCount, normalized.count)
        XCTAssertEqual(asset.sha256, digest(normalized))
        XCTAssertEqual(try context.assetNames(), [id.persistedValue + ".png"])
        XCTAssertEqual(try Data(contentsOf: source), data)
        let after = try snapshot(source)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try snapshot(context.assetURL(asset)).st_mode & 0o7777, 0o600)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        // ImageIO reports generated color-space/pixel dimensions under EXIF
        // even for the fresh bitmap. Only those technical values may remain;
        // no source EXIF, GPS, camera identity, or comments may survive.
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let generatedExifKeys: Set<CFString> = [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension]
        XCTAssertTrue(Set(exif.keys).isSubset(of: generatedExifKeys))
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
        XCTAssertFalse(String(decoding: normalized, as: UTF8.self).contains("private photo comment"))
        XCTAssertFalse(String(decoding: normalized, as: UTF8.self).contains("private camera owner"))
    }

    func testImportAndReadWorkOffMainActor() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "photo.png")
        let observation = PhotoThreadObservation()
        let store = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(
            beforeDecode: { observation.record(Thread.isMainThread) },
            beforeReadRevalidation: { observation.record(Thread.isMainThread) }
        ))
        let task = await MainActor.run {
            Task { @MainActor in
                let asset = try await store.importPhoto(from: source, id: ProfileAssetID(UUID()))
                _ = try await store.read(asset)
            }
        }
        try await task.value
        XCTAssertEqual(observation.values, [false, false, false])
    }

    func testVerifierRequiresExactExistingProtectedRoot() throws {
        let context = try PhotoContentFixture()
        XCTAssertThrowsError(try ProfilePhotoRootVerifier().verify(context.fixture.root, inside: context.owned)) {
            XCTAssertEqual($0 as? ProfilePhotoContentError, .rootMismatch)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: context.photoRoot.path)
        XCTAssertThrowsError(try ProfilePhotoRootVerifier().verify(context.photoRoot, inside: context.owned)) {
            XCTAssertEqual($0 as? ProfilePhotoContentError, .rootProtectionInvalid)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: context.photoRoot.path)
        try FileManager.default.removeItem(at: context.photoRoot)
        XCTAssertThrowsError(try ProfilePhotoRootVerifier().verify(context.photoRoot, inside: context.owned))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.photoRoot.path))
    }

    func testSymlinkParentsHardLinksAliasesAndNonregularSourcesFailWithoutPublication() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "actual.png")
        let store = ProfilePhotoContentStore(root: context.verified)
        let symbolic = context.fixture.root.appending(path: "symbolic.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
        await expectError(.symbolicLink) { try await store.importPhoto(from: symbolic, id: ProfileAssetID(UUID())) }
        let linkedParent = context.fixture.root.appending(path: "linked-parent", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: source.deletingLastPathComponent())
        await expectError(.symbolicLink) {
            try await store.importPhoto(from: linkedParent.appending(path: source.lastPathComponent), id: ProfileAssetID(UUID()))
        }
        let hardLink = context.fixture.root.appending(path: "hard.png")
        XCTAssertEqual(link(source.path, hardLink.path), 0)
        await expectError(.unexpectedHardLinks) { try await store.importPhoto(from: hardLink, id: ProfileAssetID(UUID())) }
        try FileManager.default.removeItem(at: hardLink)

        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x80
        XCTAssertEqual(finderInfo.withUnsafeBytes { setxattr(source.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0) }, 0)
        await expectError(.finderAlias) { try await store.importPhoto(from: source, id: ProfileAssetID(UUID())) }
        await expectError(.sourceNotRegular) { try await store.importPhoto(from: context.fixture.home, id: ProfileAssetID(UUID())) }
        XCTAssertTrue(try context.assetNames().isEmpty)
    }

    func testCorruptMultipageAndOversizedInputsFailBeforePublication() async throws {
        let context = try PhotoContentFixture()
        let store = ProfilePhotoContentStore(root: context.verified)
        let corrupt = try context.source(Data("not an image".utf8), name: "corrupt.png")
        await expectError(.invalidImage) { try await store.importPhoto(from: corrupt, id: ProfileAssetID(UUID())) }
        let multipage = try context.source(imageData(type: UTType.tiff.identifier, frameCount: 2), name: "two.tiff")
        await expectError(.multipleImages) { try await store.importPhoto(from: multipage, id: ProfileAssetID(UUID())) }
        let oversized = try context.source(Data(), name: "oversized.png")
        let fd = open(oversized.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(ProfilePhotoContentStore.maximumSourceByteCount + 1)), 0)
        close(fd)
        await expectError(.sourceTooLarge) { try await store.importPhoto(from: oversized, id: ProfileAssetID(UUID())) }
        let giantPixels = try context.source(oversizedPNGHeader(try imageData()), name: "giant-pixels.png")
        await expectError(.excessivePixelCount) { try await store.importPhoto(from: giantPixels, id: ProfileAssetID(UUID())) }
        XCTAssertTrue(try context.assetNames().isEmpty)
    }

    func testExclusiveCollisionLeavesExistingAssetAndSourceUntouched() async throws {
        let context = try PhotoContentFixture()
        let store = ProfilePhotoContentStore(root: context.verified)
        let source = try context.source(imageData(), name: "photo.png")
        let id = ProfileAssetID(UUID())
        let first = try await store.importPhoto(from: source, id: id)
        let original = try await store.read(first)
        await expectError(.collision) { try await store.importPhoto(from: source, id: id) }
        let after = try await store.read(first)
        XCTAssertEqual(after, original)
        XCTAssertEqual(try context.assetNames(), [id.persistedValue + ".png"])
    }

    func testReadRejectsMissingCorruptMismatchedUnprotectedAndLinkedAssets() async throws {
        let context = try PhotoContentFixture()
        let store = ProfilePhotoContentStore(root: context.verified)
        let source = try context.source(imageData(), name: "photo.png")
        let asset = try await store.importPhoto(from: source, id: ProfileAssetID(UUID()))
        let location = context.assetURL(asset)
        let original = try await store.read(asset)
        let wrongDimensions = try ProfilePhotoAsset(id: asset.id, width: asset.width + 1, height: asset.height, byteCount: asset.byteCount, sha256: asset.sha256)
        await expectError(.assetMismatch) { try await store.read(wrongDimensions) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: location.path)
        await expectError(.assetProtectionInvalid) { try await store.read(asset) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
        let hardLink = context.fixture.root.appending(path: "linked-asset.png")
        XCTAssertEqual(link(location.path, hardLink.path), 0)
        await expectError(.unexpectedHardLinks) { try await store.read(asset) }
        try FileManager.default.removeItem(at: hardLink)
        var altered = original
        altered[altered.count / 2] ^= 0x01
        try altered.write(to: location)
        await expectError(.assetMismatch) { try await store.read(asset) }
        try FileManager.default.removeItem(at: location)
        await expectError(.assetMissing) { try await store.read(asset) }
        try FileManager.default.createSymbolicLink(at: location, withDestinationURL: source)
        await expectError(.symbolicLink) { try await store.read(asset) }
    }

    func testReplacingAnyVerifiedOwnedDirectoryInvalidatesRoot() async throws {
        for level in 0..<3 {
            let context = try PhotoContentFixture()
            let store = ProfilePhotoContentStore(root: context.verified)
            let source = try context.source(imageData(), name: "photo.png")
            let asset = try await store.importPhoto(from: source, id: ProfileAssetID(UUID()))
            let target = [context.photoRoot, context.fixture.layout.highChurnRoot, context.owned.url][level]
            try FileManager.default.moveItem(at: target, to: target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".preserved"))
            try FileManager.default.createDirectory(at: context.photoRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            await expectError(.rootIdentityChanged) { try await store.read(asset) }
            await expectError(.rootIdentityChanged) { try await store.importPhoto(from: source, id: ProfileAssetID(UUID())) }
            XCTAssertTrue(try context.assetNames().isEmpty)
        }
    }

    func testChangedSourceIsRejectedBeforeDecodeOrScratch() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "photo.png")
        let store = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(beforeSourceRevalidation: {
            try Data("changed".utf8).write(to: source)
        }))
        await expectError(.sourceChanged) { try await store.importPhoto(from: source, id: ProfileAssetID(UUID())) }
        XCTAssertTrue(try context.assetNames().isEmpty)
    }

    func testFailedPublicationCleansOnlyExactOwnedScratchAndPreservesSwappedFile() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "photo.png")
        let savedScratch = context.photoRoot.appending(path: "owned-scratch-preserved")
        let store = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(beforePublication: { scratch in
            try FileManager.default.moveItem(at: scratch, to: savedScratch)
            try Data("foreign replacement".utf8).write(to: scratch, options: .withoutOverwriting)
        }))
        await expectError(.cleanupRefused) { try await store.importPhoto(from: source, id: ProfileAssetID(UUID())) }
        let names = try context.assetNames()
        XCTAssertEqual(names.count, 2)
        let replacementName = try XCTUnwrap(names.first { $0.hasPrefix(".import-") })
        XCTAssertEqual(try Data(contentsOf: context.photoRoot.appending(path: replacementName)), Data("foreign replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedScratch.path))
    }

    func testRootChangeBeforePublishCannotWriteIntoReplacementRoot() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "photo.png")
        let oldRoot = context.photoRoot.deletingLastPathComponent().appending(path: "old-photo-root", directoryHint: .isDirectory)
        let store = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(beforePublication: { _ in
            try FileManager.default.moveItem(at: context.photoRoot, to: oldRoot)
            try FileManager.default.createDirectory(at: context.photoRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }))
        await expectError(.rootIdentityChanged) { try await store.importPhoto(from: source, id: ProfileAssetID(UUID())) }
        XCTAssertTrue(try context.assetNames().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: oldRoot.path).isEmpty)
    }

    func testReadPathSwapFailsAndDoesNotRemoveReplacement() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "photo.png")
        let store = ProfilePhotoContentStore(root: context.verified)
        let asset = try await store.importPhoto(from: source, id: ProfileAssetID(UUID()))
        let location = context.assetURL(asset)
        let moved = context.photoRoot.appending(path: "preserved.png")
        let reader = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(beforeReadRevalidation: {
            try FileManager.default.moveItem(at: location, to: moved)
            try Data("replacement".utf8).write(to: location, options: .withoutOverwriting)
        }))
        await expectError(.assetChanged) { try await reader.read(asset) }
        XCTAssertEqual(try Data(contentsOf: location), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testPickedSourceScopeIsExactAndBalancedOnSuccessAndFailure() async throws {
        let context = try PhotoContentFixture()
        let source = try context.source(imageData(), name: "photo.png")
        let invalid = try context.source(Data("invalid".utf8), name: "invalid.png")
        let access = PhotoScopeObservation()
        let store = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(
            startSourceAccess: { url in access.record("start", url: url); return true },
            stopSourceAccess: { access.record("stop", url: $0) }
        ))
        let asset = try await store.importPhoto(from: source, id: ProfileAssetID(UUID()))
        _ = try await store.read(asset)
        await expectError(.invalidImage) { try await store.importPhoto(from: invalid, id: ProfileAssetID(UUID())) }
        XCTAssertEqual(access.entries, ["start:" + source.path, "stop:" + source.path, "start:" + invalid.path, "stop:" + invalid.path])

        let ordinary = ProfilePhotoContentStore(root: context.verified, hooks: ProfilePhotoContentTestHooks(
            startSourceAccess: { _ in false },
            stopSourceAccess: { access.record("unexpected stop", url: $0) }
        ))
        _ = try await ordinary.importPhoto(from: source, id: ProfileAssetID(UUID()))
        XCTAssertEqual(access.entries.count, 4, "A false start does not prevent an ordinary local read or get an unmatched stop.")
    }

    private func expectError<T>(_ expected: ProfilePhotoContentError, operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ProfilePhotoContentError, expected)
        }
    }

    private func snapshot(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func imageData(width: Int = 16, height: Int = 8, type: String = UTType.png.identifier, frameCount: Int = 1, properties: [CFString: Any] = [:]) throws -> Data {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.5, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(bitmap.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frameCount, nil))
        for _ in 0..<frameCount { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func oversizedPNGHeader(_ original: Data) -> Data {
        var data = original
        let width: UInt32 = 100_000
        let height: UInt32 = 100_000
        for (start, number) in [(16, width), (20, height)] {
            for offset in 0..<4 { data[start + offset] = UInt8((number >> (24 - offset * 8)) & 0xff) }
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        crc ^= 0xffff_ffff
        for offset in 0..<4 { data[29 + offset] = UInt8((crc >> (24 - offset * 8)) & 0xff) }
        return data
    }
}

private final class PhotoContentFixture: @unchecked Sendable {
    let fixture: ContentTemporaryFixture
    let owned: VerifiedOwnedRoot
    let verified: VerifiedProfilePhotoRoot
    var photoRoot: URL { fixture.layout.profileAssetsRoot }

    init() throws {
        fixture = try ContentTemporaryFixture()
        let installationID = UUID()
        let rootID = UUID()
        try fixture.materializeOwnedRoot(fixture.layout.applicationSupportRoot, installationID: installationID, rootID: rootID)
        try FileManager.default.createDirectory(at: fixture.layout.profileAssetsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        owned = try OwnedRootVerifier().verify(fixture.layout.applicationSupportRoot, expectedInstallationID: installationID, expectedRootID: rootID)
        verified = try ProfilePhotoRootVerifier().verify(fixture.layout.profileAssetsRoot, inside: owned)
    }

    func source(_ data: Data, name: String) throws -> URL {
        let url = fixture.home.appending(path: name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    func assetURL(_ asset: ProfilePhotoAsset) -> URL { photoRoot.appending(path: asset.id.persistedValue + ".png") }
    func assetNames() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: photoRoot.path).sorted() }
}

private final class PhotoThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Bool] = []
    func record(_ value: Bool) { lock.withLock { captured.append(value) } }
    var values: [Bool] { lock.withLock { captured } }
}

private final class PhotoScopeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    func record(_ event: String, url: URL) { lock.withLock { captured.append(event + ":" + url.path) } }
    var entries: [String] { lock.withLock { captured } }
}
