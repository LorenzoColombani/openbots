import Combine
import Foundation
import ImageIO
import OpenBotsDomain
import SwiftUI
import UniformTypeIdentifiers

/// One workspace-scoped loader and bounded decoded-image cache. Construct once
/// at composition, not during body rendering. The loader supplies a verified
/// immutable PNG; this UI boundary never reads a URL or opens a file itself.
public final class ProfilePhotoPresentation: Sendable {
    public let id = UUID()
    private let cache: ProfilePhotoImageCache

    public convenience init(loader: @escaping @Sendable (ProfileAssetID) async throws -> Data) {
        self.init(loader: loader, cacheByteLimit: 16 * 1_024 * 1_024, cacheEntryLimit: 64)
    }

    init(
        loader: @escaping @Sendable (ProfileAssetID) async throws -> Data,
        cacheByteLimit: Int, cacheEntryLimit: Int
    ) {
        cache = ProfilePhotoImageCache(
            loader: loader, maximumBytes: max(0, cacheByteLimit),
            maximumEntries: max(1, cacheEntryLimit)
        )
    }

    func image(for id: ProfileAssetID) async -> ProfilePhotoDecodedImage? {
        await cache.image(for: id)
    }

    func cacheReceipt() async -> ProfilePhotoCacheReceipt { await cache.receipt() }
}

private struct ProfilePhotoPresentationKey: EnvironmentKey {
    static let defaultValue: ProfilePhotoPresentation? = nil
}

public extension EnvironmentValues {
    var profilePhotoPresentation: ProfilePhotoPresentation? {
        get { self[ProfilePhotoPresentationKey.self] }
        set { self[ProfilePhotoPresentationKey.self] = newValue }
    }
}

// CGImage is immutable. Decoding is completed on the cache actor's executor
// before the image crosses to the main-actor presentation model.
struct ProfilePhotoDecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    var byteCount: Int { cgImage.bytesPerRow * cgImage.height }
}

struct ProfilePhotoCacheReceipt: Equatable, Sendable {
    let entries: Int
    let decodedBytes: Int
}

private actor ProfilePhotoImageCache {
    private enum Entry {
        case image(ProfilePhotoDecodedImage)
        case unavailable
        var image: ProfilePhotoDecodedImage? {
            if case .image(let value) = self { value } else { nil }
        }
    }

    private let loader: @Sendable (ProfileAssetID) async throws -> Data
    private let maximumBytes: Int
    private let maximumEntries: Int
    private var entries: [ProfileAssetID: Entry] = [:]
    private var recency: [ProfileAssetID] = []
    private var inFlight: [ProfileAssetID: Task<ProfilePhotoDecodedImage?, Never>] = [:]
    private var decodedBytes = 0

    init(
        loader: @escaping @Sendable (ProfileAssetID) async throws -> Data,
        maximumBytes: Int, maximumEntries: Int
    ) {
        self.loader = loader
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
    }

    func image(for id: ProfileAssetID) async -> ProfilePhotoDecodedImage? {
        if let entry = entries[id] {
            touch(id)
            return entry.image
        }
        if let pending = inFlight[id] { return await pending.value }

        // Coalesce repeated visible avatars. This task inherits this actor,
        // not MainActor; bounded eager ImageIO decoding never runs in body.
        let pending = Task { [loader] in
            do { return Self.decode(try await loader(id)) }
            catch { return nil }
        }
        inFlight[id] = pending
        let image = await pending.value
        inFlight[id] = nil
        let cost = image?.byteCount ?? 0
        if cost <= maximumBytes {
            while !recency.isEmpty && (entries.count >= maximumEntries || decodedBytes + cost > maximumBytes) {
                let oldest = recency.removeFirst()
                decodedBytes -= entries.removeValue(forKey: oldest)?.image?.byteCount ?? 0
            }
            entries[id] = image.map(Entry.image) ?? .unavailable
            decodedBytes += cost
            touch(id)
        }
        return image
    }

    func receipt() -> ProfilePhotoCacheReceipt {
        ProfilePhotoCacheReceipt(entries: entries.count, decodedBytes: decodedBytes)
    }

    private func touch(_ id: ProfileAssetID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    private static func decode(_ data: Data) -> ProfilePhotoDecodedImage? {
        guard !data.isEmpty, data.count <= ProfilePhotoAsset.maximumByteCount,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...ProfilePhotoAsset.maximumDimension).contains(width),
              (1...ProfilePhotoAsset.maximumDimension).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width == width, image.height == height else { return nil }
        return ProfilePhotoDecodedImage(cgImage: image)
    }
}

struct ProfilePhotoRequest: Equatable, Sendable {
    let assetID: UUID
    let presentationID: UUID
}

enum ProfilePhotoLoadPhase: Equatable {
    case idle, loading, available, unavailable
}

@MainActor
final class ProfilePhotoViewModel: ObservableObject {
    @Published private(set) var image: ProfilePhotoDecodedImage?
    @Published private(set) var phase = ProfilePhotoLoadPhase.idle
    private(set) var request: ProfilePhotoRequest?
    private var generation: UInt64 = 0

    func load(assetID: UUID?, presentation: ProfilePhotoPresentation?) async {
        let next = assetID.flatMap { asset in
            presentation.map { ProfilePhotoRequest(assetID: asset, presentationID: $0.id) }
        }
        if next == request, phase == .available || phase == .unavailable { return }
        generation &+= 1
        let operation = generation
        request = next
        phase = .loading
        image = nil
        guard let next, let presentation else { phase = .unavailable; return }
        let loaded = await presentation.image(for: ProfileAssetID(next.assetID))
        guard generation == operation, !Task.isCancelled else { return }
        image = loaded
        phase = loaded == nil ? .unavailable : .available
    }

    func image(for assetID: UUID?, presentation: ProfilePhotoPresentation?) -> ProfilePhotoDecodedImage? {
        guard let assetID, let presentation,
              request == ProfilePhotoRequest(assetID: assetID, presentationID: presentation.id) else { return nil }
        return image
    }

    func isUnavailable(for assetID: UUID?, presentation: ProfilePhotoPresentation?) -> Bool {
        guard let assetID, phase == .unavailable else { return false }
        guard let presentation else { return request == nil }
        return request == ProfilePhotoRequest(assetID: assetID, presentationID: presentation.id)
    }
}
