import AppKit
import CryptoKit
import OpenBotsDomain
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class BuiltInAvatarTests: XCTestCase {
    func testNewCreationAllocationKeepsLegacyFamilyAndAllFiveModelsEligible() {
        var observed: Set<String> = []
        for seed in UInt64(0)..<100 {
            let choice = CharacterAppearanceSnapshot.newlyAllocated(seed: seed)
            let fallback = CharacterAppearanceSnapshot.fixture(seed: seed)
            observed.insert(choice.builtInAvatarID ?? "legacy")
            XCTAssertEqual(choice.deterministicSeed, fallback.deterministicSeed)
            XCTAssertEqual(choice.grammarVersion, fallback.grammarVersion)
            XCTAssertEqual(choice.silhouette, fallback.silhouette)
            XCTAssertEqual(choice.paletteToken, fallback.paletteToken)
            XCTAssertEqual(choice.eyeDialect, fallback.eyeDialect)
            XCTAssertEqual(choice.nonColorIdentityCue, fallback.nonColorIdentityCue)
            XCTAssertEqual(choice.accessibleIdentityDescription, fallback.accessibleIdentityDescription)
            XCTAssertEqual(choice, CharacterAppearanceSnapshot.newlyAllocated(seed: seed))
            XCTAssertNil(fallback.builtInAvatarID)
        }
        XCTAssertEqual(observed, Set(["pillow", "fin", "kite", "bean", "guide", "legacy"]))
    }

    func testOldCodableAppearanceAndFutureChoiceKeepGeneratedFallback() throws {
        let original = try appearance()
        let encoded = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("builtInAvatarID"))
        XCTAssertEqual(try JSONDecoder().decode(AgentAppearance.self, from: encoded), original)
        let future = try appearance(builtIn: "future-avatar")
        let baseline = CharacterIdentityDescriptor(appearance: CharacterAppearanceSnapshot(original))
        let fallback = CharacterIdentityDescriptor(appearance: CharacterAppearanceSnapshot(future))
        XCTAssertEqual(fallback, baseline)
        XCTAssertNil(fallback.builtInAvatar)
        for avatar in BuiltInAvatar.allCases {
            let saved = try appearance(builtIn: avatar.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(AgentAppearance.self, from: JSONEncoder().encode(saved)), saved)
            let descriptor = CharacterIdentityDescriptor(appearance: CharacterAppearanceSnapshot(saved))
            XCTAssertEqual(descriptor.builtInAvatar, avatar)
            XCTAssertEqual(descriptor.silhouette, baseline.silhouette)
            XCTAssertEqual(descriptor.palette, baseline.palette)
            XCTAssertEqual(descriptor.eyes, baseline.eyes)
            XCTAssertEqual(descriptor.mark, baseline.mark)
        }
    }

    func testBundledCutoutsHaveApprovedBytesAndRealTransparency() throws {
        let hashes: [BuiltInAvatar: String] = [
            .guide: "d4f77b6f9376f6f4ef2a823f3ad507d5be17554bd005056067e20c715f3bb2dd",
            .fin: "cd07757eb49027c09ccb93ba2804133d321812e2f7a273ed196bec79508a0a9b"
        ]
        for (avatar, expectedHash) in hashes {
            let url = try XCTUnwrap(BuiltInAvatarResources.url(for: avatar))
            let data = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expectedHash)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertTrue(bitmap.hasAlpha)
            XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
            XCTAssertTrue(BuiltInAvatarResources.isAvailable(avatar))
        }
        XCTAssertEqual(BuiltInAvatar.allCases.map(\.displayName), ["Pillow", "Yogurt", "Kite", "Bean", "Canobi"])
    }

    func testAllFiveModelsRenderDistinctlyInSharedRendererAtNativeSizes() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build.noindex/avatar-integration/rendered", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            var hashes: Set<String> = []
            for avatar in BuiltInAvatar.allCases {
                let identity = TeammateIdentitySnapshot(
                    id: UUID(), name: avatar.displayName, role: "Synthetic avatar verification",
                    appearance: CharacterAppearanceSnapshot(try appearance(builtIn: avatar.rawValue))
                )
                let content = HStack(spacing: 24) {
                    ForEach([CGFloat(32), 42, 64], id: \.self) { size in
                        CharacterIdentityView(identity: identity, activity: .idle, size: size)
                    }
                    CharacterIdentityView(identity: identity, activity: .idle, size: 42)
                        .scaleEffect(3).frame(width: 138, height: 138)
                }
                .padding(24)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                XCTAssertTrue(hashes.insert(hash).inserted, "Each model must render different artwork")
                try png.write(to: output.appendingPathComponent("\(avatar.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
            }
            XCTAssertEqual(hashes.count, 5)
        }
        print("Built-in avatar render evidence: \(output.path)")
    }

    private func appearance(builtIn: String? = nil) throws -> AgentAppearance {
        try AgentAppearance(mode: .creature, grammarVersion: 99, deterministicSeed: 8_811,
            silhouette: "future silhouette", paletteToken: "future palette",
            eyeDialect: "future eyes", nonColorIdentityCue: "future mark",
            accessibleIdentityDescription: "Saved unknown creature", builtInAvatarID: builtIn, revision: 2)
    }
}
