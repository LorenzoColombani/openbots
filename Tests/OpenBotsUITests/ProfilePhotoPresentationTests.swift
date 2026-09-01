import CoreGraphics
import Foundation
import ImageIO
import OpenBotsDomain
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import OpenBotsUI

@MainActor
final class ProfilePhotoPresentationTests: XCTestCase {
    func testPhotoModeNeverReceivesAnActivityPoseOrTransitionTransform() {
        for activity in TeammateActivityState.allCases {
            for phase in CharacterTransitionPhase.allCases {
                for reduceMotion in [false, true] {
                    for sceneIsActive in [false, true] {
                        XCTAssertFalse(CharacterTransitionMotion.isEnabled(
                            mode: .photo, reduceMotion: reduceMotion, sceneIsActive: sceneIsActive
                        ))
                        XCTAssertEqual(CharacterTransitionMotion.transform(
                            activity: activity, mode: .photo, phase: phase,
                            reduceMotion: reduceMotion, sceneIsActive: sceneIsActive
                        ), .identity)
                    }
                }
            }
        }
    }

    func testUnavailablePhotoArtworkStaysStillAcrossActivityChanges() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/mvp-visual-polish-20260831/photo-fallback-rendered", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Photo fallback render evidence: \(output.path)")
        let identity = TeammateIdentitySnapshot(
            id: photoID(10).rawValue, name: "Photo fixture", role: "Assistant",
            appearance: CharacterAppearanceSnapshot(
                mode: .photo, grammarVersion: 1, deterministicSeed: 12,
                silhouette: "round", paletteToken: "sky", eyeDialect: "round",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Profile photo",
                profileAssetID: photoID(1).rawValue, revision: 1
            )
        )
        var reference: Data?
        var referenceActivity: String?
        for activity in TeammateActivityState.allCases {
            // macOS exposes Reduce Motion read-only. The policy test above
            // covers both values; this render uses the actual system setting.
            let renderer = ImageRenderer(content: CharacterIdentityView(
                identity: identity, activity: activity, size: 64
            )
                .environment(\.colorScheme, .light)
                .environment(\.scenePhase, .active))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 64)
            try writePhotoRenderPNG(image, to: output.appendingPathComponent("\(activity.rawValue)-full.png"))
            // Compare artwork away from the bottom-right status badge. That
            // badge must still convey the real state while the photo is still.
            let artwork = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 32, height: 64)))
            try writePhotoRenderPNG(artwork, to: output.appendingPathComponent("\(activity.rawValue)-compared-artwork.png"))
            let pixels = try photoArtworkPixels(artwork)
            XCTAssertTrue(pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element != 0 },
                          "The comparison must contain nontransparent artwork")
            if let reference {
                XCTAssertEqual(pixels.count, reference.count)
                let difference = photoArtworkDifference(pixels, reference)
                let comparison = "\(activity.rawValue) vs \(referenceActivity ?? "reference"): max RGB delta \(difference.maximumRGBDelta), alpha differences \(difference.alphaDifferences). PNGs: \(output.path)"
                // The isolated renderer diagnostic reproduced identical alpha
                // geometry with RGB variation of one 8-bit quantization step.
                // Keep geometry exact; permit only that observed color rounding.
                XCTAssertEqual(difference.alphaDifferences, 0, comparison)
                XCTAssertLessThanOrEqual(difference.maximumRGBDelta, 1, comparison)
            } else {
                reference = pixels
                referenceActivity = activity.rawValue
            }
        }
    }

    func testEnvironmentDefaultsToNoLoaderAndNilRequestsKeepFallback() async {
        XCTAssertNil(EnvironmentValues().profilePhotoPresentation)
        let source = PhotoPresentationSource(data: Data())
        let presentation = ProfilePhotoPresentation(loader: { try await source.load($0) })
        let model = ProfilePhotoViewModel()
        await model.load(assetID: nil, presentation: presentation)
        XCTAssertNil(model.image)
        await model.load(assetID: photoID(1).rawValue, presentation: nil)
        XCTAssertNil(model.image)
        XCTAssertTrue(model.isUnavailable(for: photoID(1).rawValue, presentation: nil))
        XCTAssertFalse(model.isUnavailable(for: nil, presentation: nil))
        let count = await source.calls
        XCTAssertEqual(count, 0)
    }

    func testFiftyConcurrentAvatarsShareOneVerifiedDecodedImage() async throws {
        let source = PhotoPresentationSource(data: try photoData(width: 2, height: 3))
        let presentation = ProfilePhotoPresentation(loader: { try await source.load($0) })
        let asset = photoID(1)
        let sizes = await withTaskGroup(of: CGSize?.self, returning: [CGSize?].self) { group in
            for _ in 0..<50 {
                group.addTask {
                    guard let image = await presentation.image(for: asset) else { return nil }
                    return CGSize(width: image.cgImage.width, height: image.cgImage.height)
                }
            }
            var values: [CGSize?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(sizes.count, 50)
        XCTAssertTrue(sizes.allSatisfy { $0 == CGSize(width: 2, height: 3) })
        let count = await source.calls
        XCTAssertEqual(count, 1)
        let receipt = await presentation.cacheReceipt()
        XCTAssertEqual(receipt.entries, 1)
        XCTAssertGreaterThan(receipt.decodedBytes, 0)
        XCTAssertLessThanOrEqual(receipt.decodedBytes, 16 * 1_024 * 1_024)
    }

    func testCorruptOversizeAndNonPNGImagesFailClosedAndAreNotRetriedPerRedraw() async throws {
        let candidates = [
            Data("not an image".utf8),
            Data(repeating: 0, count: ProfilePhotoAsset.maximumByteCount + 1),
            try photoData(width: ProfilePhotoAsset.maximumDimension + 1, height: 1),
            try photoData(width: 2, height: 2, type: .jpeg)
        ]
        for data in candidates {
            let source = PhotoPresentationSource(data: data)
            let presentation = ProfilePhotoPresentation(loader: { try await source.load($0) })
            let first = await presentation.image(for: photoID(1))
            let again = await presentation.image(for: photoID(1))
            XCTAssertNil(first)
            XCTAssertNil(again)
            let count = await source.calls
            let receipt = await presentation.cacheReceipt()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(receipt.decodedBytes, 0)
        }
    }

    func testThrownReadErrorReturnsFallbackWithoutExposingFailure() async {
        let source = PhotoPresentationSource(data: Data(), fails: true)
        let presentation = ProfilePhotoPresentation(loader: { try await source.load($0) })
        let model = ProfilePhotoViewModel()
        await model.load(assetID: photoID(1).rawValue, presentation: presentation)
        XCTAssertNil(model.image)
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertTrue(model.isUnavailable(for: photoID(1).rawValue, presentation: presentation))
        XCTAssertFalse(model.isUnavailable(for: photoID(2).rawValue, presentation: presentation))
        await model.load(assetID: photoID(1).rawValue, presentation: presentation)
        let count = await source.calls
        XCTAssertEqual(count, 1)
    }

    func testDecodedCacheEnforcesByteAndEntryLimitsWithLRUEviction() async throws {
        let data = try photoData(width: 2, height: 2)
        let probe = ProfilePhotoPresentation(loader: { _ in data })
        let probeImage = await probe.image(for: photoID(1))
        let image = try XCTUnwrap(probeImage)
        let source = PhotoPresentationSource(data: data)
        let presentation = ProfilePhotoPresentation(
            loader: { try await source.load($0) },
            cacheByteLimit: image.byteCount * 2, cacheEntryLimit: 2
        )
        for index in 1...3 {
            let result = await presentation.image(for: photoID(index))
            XCTAssertNotNil(result)
            let receipt = await presentation.cacheReceipt()
            XCTAssertLessThanOrEqual(receipt.entries, 2)
            XCTAssertLessThanOrEqual(receipt.decodedBytes, image.byteCount * 2)
        }
        _ = await presentation.image(for: photoID(1))
        let count = await source.calls
        XCTAssertEqual(count, 4, "The oldest image must be reloaded after bounded eviction")
    }

    func testStaleImageCannotReplaceNewAssetOrDifferentLoaderScope() async throws {
        let slow = PhotoPresentationGate()
        let firstData = try photoData(width: 1, height: 1)
        let secondData = try photoData(width: 2, height: 2)
        let firstID = photoID(1)
        let secondID = photoID(2)
        let presentation = ProfilePhotoPresentation(loader: { id in
            if id == firstID { await slow.wait(); return firstData }
            return secondData
        })
        let model = ProfilePhotoViewModel()
        let oldLoad = Task { await model.load(assetID: firstID.rawValue, presentation: presentation) }
        await waitForPhotoGate(slow)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.isUnavailable(for: firstID.rawValue, presentation: presentation))
        await model.load(assetID: secondID.rawValue, presentation: presentation)
        XCTAssertEqual(model.image?.cgImage.width, 2)
        XCTAssertEqual(model.phase, .available)
        XCTAssertNil(model.image(for: firstID.rawValue, presentation: presentation))
        await slow.release()
        await oldLoad.value
        XCTAssertEqual(model.image?.cgImage.width, 2)

        let replacement = ProfilePhotoPresentation(loader: { _ in firstData })
        XCTAssertNil(model.image(for: secondID.rawValue, presentation: replacement))
        await model.load(assetID: secondID.rawValue, presentation: replacement)
        XCTAssertEqual(model.image?.cgImage.width, 1)
    }

    func testCancelledDisplayRequestCannotPublishButSharedCacheCanBeReused() async throws {
        let gate = PhotoPresentationGate()
        let data = try photoData(width: 2, height: 2)
        let source = PhotoPresentationSource(data: data, gate: gate)
        let presentation = ProfilePhotoPresentation(loader: { try await source.load($0) })
        let model = ProfilePhotoViewModel()
        let load = Task { await model.load(assetID: photoID(1).rawValue, presentation: presentation) }
        await waitForPhotoGate(gate)
        load.cancel()
        await gate.release()
        await load.value
        XCTAssertNil(model.image)
        await model.load(assetID: photoID(1).rawValue, presentation: presentation)
        XCTAssertEqual(model.image?.cgImage.width, 2)
        let count = await source.calls
        XCTAssertEqual(count, 1)
    }
}

private func photoArtworkPixels(_ image: CGImage) throws -> Data {
    let byteCount = image.width * image.height * 4
    let context = try XCTUnwrap(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: try XCTUnwrap(context.data), count: byteCount)
}

private func writePhotoRenderPNG(_ image: CGImage, to url: URL) throws {
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    try (data as Data).write(to: url, options: .withoutOverwriting)
}

private func photoArtworkDifference(_ actual: Data, _ expected: Data) -> (maximumRGBDelta: Int, alphaDifferences: Int) {
    var maximumRGBDelta = 0, alphaDifferences = 0
    for (offset, pair) in zip(actual, expected).enumerated() {
        let delta = abs(Int(pair.0) - Int(pair.1))
        if offset % 4 == 3 {
            if delta != 0 { alphaDifferences += 1 }
        } else { maximumRGBDelta = max(maximumRGBDelta, delta) }
    }
    return (maximumRGBDelta, alphaDifferences)
}

private actor PhotoPresentationSource {
    let data: Data
    let fails: Bool
    let gate: PhotoPresentationGate?
    var calls = 0
    init(data: Data, fails: Bool = false, gate: PhotoPresentationGate? = nil) {
        self.data = data; self.fails = fails; self.gate = gate
    }
    func load(_ id: ProfileAssetID) async throws -> Data {
        calls += 1
        if let gate { await gate.wait() }
        if fails { throw CocoaError(.fileReadNoPermission) }
        return data
    }
}

private actor PhotoPresentationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private func waitForPhotoGate(_ gate: PhotoPresentationGate) async {
    for _ in 0..<200 {
        if await gate.started { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Photo load did not reach its bounded test gate")
}

private func photoID(_ value: Int) -> ProfileAssetID {
    ProfileAssetID(UUID(uuidString: String(format: "A8000000-0000-0000-0000-%012x", value))!)
}

private func photoData(width: Int, height: Int, type: UTType = .png) throws -> Data {
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
