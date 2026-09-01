import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import OpenBotsDomain
import UniformTypeIdentifiers

public enum ProfilePhotoContentError: Error, Equatable, Sendable {
    case wrongOwnedRoot
    case rootMismatch
    case rootUnavailable
    case rootIdentityChanged
    case rootProtectionInvalid
    case invalidSourceURL
    case sourceUnavailable
    case sourceNotRegular
    case symbolicLink
    case finderAlias
    case unexpectedHardLinks
    case nonLocalVolume
    case sourceTooLarge
    case sourceChanged
    case invalidImage
    case multipleImages
    case excessivePixelCount
    case normalizationFailed
    case outputTooLarge
    case collision
    case stagingFailed
    case publicationFailed
    case cleanupRefused
    case assetMissing
    case assetProtectionInvalid
    case assetChanged
    case assetMismatch
}

fileprivate struct PhotoFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
    }
}

/// Evidence only: verification never creates or repairs a root. Import/read
/// revalidate all three app-owned directory identities before using this root.
public struct VerifiedProfilePhotoRoot: Hashable, Sendable {
    public let url: URL
    public let applicationSupportRootID: UUID
    fileprivate let applicationSupportURL: URL
    fileprivate let identities: [PhotoFileIdentity]

    fileprivate init(url: URL, applicationSupportRoot: VerifiedOwnedRoot, identities: [PhotoFileIdentity]) {
        self.url = url
        applicationSupportRootID = applicationSupportRoot.rootID
        applicationSupportURL = applicationSupportRoot.url
        self.identities = identities
    }
}

public struct ProfilePhotoRootVerifier: Sendable {
    public init() {}

    public func verify(_ url: URL, inside applicationSupportRoot: VerifiedOwnedRoot) throws -> VerifiedProfilePhotoRoot {
        guard applicationSupportRoot.kind == .applicationSupport else { throw ProfilePhotoContentError.wrongOwnedRoot }
        let expected = applicationSupportRoot.url.appending(path: "HighChurn.noindex/ProfileAssets", directoryHint: .isDirectory)
        guard url.isFileURL, FileURLNormalization.lexical(url) == FileURLNormalization.lexical(expected) else {
            throw ProfilePhotoContentError.rootMismatch
        }
        let opened = try PhotoDescriptors.openRoot(applicationSupportURL: applicationSupportRoot.url)
        defer { close(opened.fd) }
        return VerifiedProfilePhotoRoot(url: expected, applicationSupportRoot: applicationSupportRoot, identities: opened.identities)
    }
}

struct ProfilePhotoContentTestHooks: Sendable {
    var startSourceAccess: (@Sendable (URL) -> Bool)?
    var stopSourceAccess: (@Sendable (URL) -> Void)?
    var beforeDecode: (@Sendable () throws -> Void)?
    var beforeSourceRevalidation: (@Sendable () throws -> Void)?
    var beforePublication: (@Sendable (URL) throws -> Void)?
    var beforeReadRevalidation: (@Sendable () throws -> Void)?
}

/// Explicit, immutable local image import. Construction is inert. There is no
/// external cleanup, metadata mutation, URL fetch, provider or credential API.
public struct ProfilePhotoContentStore: Sendable {
    public static let maximumSourceByteCount = 20 * 1_024 * 1_024
    public static let maximumSourcePixelCount = 40_000_000
    /// ImageIO reports the decoded format. Do not depend on the caller's file
    /// extension or a process-local Launch Services type-conformance registry.
    public static let supportedSourceTypeIdentifiers: Set<String> = [
        "public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff",
        "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp"
    ]

    private let root: VerifiedProfilePhotoRoot
    private let hooks: ProfilePhotoContentTestHooks

    public init(root: VerifiedProfilePhotoRoot) {
        self.root = root
        hooks = ProfilePhotoContentTestHooks()
    }

    init(root: VerifiedProfilePhotoRoot, hooks: ProfilePhotoContentTestHooks) {
        self.root = root
        self.hooks = hooks
    }

    public func importPhoto(from exactURL: URL, id: ProfileAssetID) async throws -> ProfilePhotoAsset {
        let root = root
        let hooks = hooks
        let task = Task.detached(priority: .userInitiated) {
            try PhotoContentExecutor(root: root, hooks: hooks).importPhoto(from: exactURL, id: id)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func read(_ asset: ProfilePhotoAsset) async throws -> Data {
        let root = root
        let hooks = hooks
        let task = Task.detached(priority: .userInitiated) {
            try PhotoContentExecutor(root: root, hooks: hooks).read(asset)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private struct PhotoContentExecutor {
    let root: VerifiedProfilePhotoRoot
    let hooks: ProfilePhotoContentTestHooks

    func importPhoto(from url: URL, id: ProfileAssetID) throws -> ProfilePhotoAsset {
        try Task.checkCancellation()
        let rootFD = try PhotoDescriptors.openVerifiedRoot(root)
        defer { close(rootFD) }
        try PhotoDescriptors.validateSourceURL(url)
        // The native picker may supply security-scoped access. Balance only a
        // successful start, including failures/cancellation; never persist the
        // source URL/bookmark or infer any sibling/destination capability.
        let scopedAccess = hooks.startSourceAccess?(url) ?? url.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess {
                if let stop = hooks.stopSourceAccess { stop(url) }
                else { url.stopAccessingSecurityScopedResource() }
            }
        }
        let source = try PhotoDescriptors.openSource(url)
        defer { close(source.fd) }
        guard source.snapshot.size > 0,
              source.snapshot.size <= ProfilePhotoContentStore.maximumSourceByteCount else {
            throw ProfilePhotoContentError.sourceTooLarge
        }
        let original = try PhotoDescriptors.readAll(source.fd, count: source.snapshot.size)
        try hooks.beforeSourceRevalidation?()
        try PhotoDescriptors.revalidateSource(source, url: url)
        try hooks.beforeDecode?()
        let normalized = try PhotoCodec.normalize(original)
        let asset = try ProfilePhotoAsset(
            id: id, width: normalized.width, height: normalized.height,
            byteCount: normalized.data.count, sha256: PhotoCodec.sha256(normalized.data)
        )
        // Check our own generated bytes before any filesystem publication.
        try PhotoCodec.verify(normalized.data, asset: asset)
        try Task.checkCancellation()
        let checkedFD = try PhotoDescriptors.openVerifiedRoot(root)
        close(checkedFD)
        try publish(normalized.data, id: id, rootFD: rootFD)
        // An error after publication deliberately leaves the immutable file in
        // place. The service may also fail to save its DB reference; neither
        // case authorizes deleting a finished or externally selected file.
        _ = try read(asset)
        return asset
    }

    func read(_ asset: ProfilePhotoAsset) throws -> Data {
        try Task.checkCancellation()
        let rootFD = try PhotoDescriptors.openVerifiedRoot(root)
        defer { close(rootFD) }
        let name = fileName(asset.id)
        let fd = openat(rootFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw errno == ELOOP ? ProfilePhotoContentError.symbolicLink : .assetMissing
        }
        defer { close(fd) }
        let before = try PhotoDescriptors.fileSnapshot(fd)
        try PhotoDescriptors.requireOwnedFile(before.value)
        guard before.size == asset.byteCount else { throw ProfilePhotoContentError.assetMismatch }
        let data = try PhotoDescriptors.readAll(fd, count: before.size)
        try PhotoCodec.verify(data, asset: asset)
        try hooks.beforeReadRevalidation?()
        let after = try PhotoDescriptors.fileSnapshot(fd)
        guard before == after,
              PhotoDescriptors.pathMatches(name: name, rootFD: rootFD, snapshot: after) else {
            throw ProfilePhotoContentError.assetChanged
        }
        let checkedFD = try PhotoDescriptors.openVerifiedRoot(root)
        close(checkedFD)
        return data
    }

    private func publish(_ data: Data, id: ProfileAssetID, rootFD: Int32) throws {
        let scratchName = ".import-\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(rootFD, scratchName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProfilePhotoContentError.stagingFailed }
        defer { close(fd) }
        let initial = try PhotoDescriptors.fileSnapshot(fd)
        var published = false
        do {
            guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw ProfilePhotoContentError.stagingFailed }
            try PhotoDescriptors.requireOwnedFile(try PhotoDescriptors.fileSnapshot(fd).value)
            try PhotoDescriptors.writeAll(data, fd: fd)
            guard fsync(fd) == 0 else { throw ProfilePhotoContentError.stagingFailed }
            try hooks.beforePublication?(root.url.appending(path: scratchName))
            try Task.checkCancellation()
            let current = try PhotoDescriptors.fileSnapshot(fd)
            try PhotoDescriptors.requireOwnedFile(current.value)
            guard PhotoFileIdentity(current.value) == PhotoFileIdentity(initial.value),
                  current.size == data.count,
                  PhotoDescriptors.pathMatches(name: scratchName, rootFD: rootFD, snapshot: current),
                  lseek(fd, 0, SEEK_SET) == 0,
                  try PhotoDescriptors.readAll(fd, count: data.count) == data else {
                throw ProfilePhotoContentError.stagingFailed
            }
            let checkedFD = try PhotoDescriptors.openVerifiedRoot(root)
            close(checkedFD)
            guard renameatx_np(rootFD, scratchName, rootFD, fileName(id), UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? ProfilePhotoContentError.collision : .publicationFailed
            }
            published = true
            guard fsync(rootFD) == 0 else { throw ProfilePhotoContentError.publicationFailed }
        } catch {
            if !published {
                // Never unlink a swapped pathname, even inside our own root.
                var current = stat()
                guard fstatat(rootFD, scratchName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_mode & S_IFMT == S_IFREG,
                      current.st_nlink == 1,
                      PhotoFileIdentity(current) == PhotoFileIdentity(initial.value),
                      unlinkat(rootFD, scratchName, 0) == 0 else {
                    throw ProfilePhotoContentError.cleanupRefused
                }
            }
            throw error
        }
    }

    private func fileName(_ id: ProfileAssetID) -> String { id.persistedValue + ".png" }
}

private enum PhotoCodec {
    static func normalize(_ data: Data) throws -> (data: Data, width: Int, height: Int) {
        let source = try imageSource(data)
        let size = try dimensions(source)
        guard size.width <= ProfilePhotoContentStore.maximumSourcePixelCount / size.height else {
            throw ProfilePhotoContentError.excessivePixelCount
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ProfilePhotoAsset.maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), thumbnail.width > 0, thumbnail.height > 0,
              thumbnail.width <= ProfilePhotoAsset.maximumDimension,
              thumbnail.height <= ProfilePhotoAsset.maximumDimension,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                                     bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProfilePhotoContentError.normalizationFailed
        }
        // Redraw into a fixed color space so even source ICC metadata cannot
        // travel into the new PNG. EXIF/GPS/comments never enter the encoder.
        bitmap.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        guard let sanitized = bitmap.makeImage() else { throw ProfilePhotoContentError.normalizationFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ProfilePhotoContentError.normalizationFailed
        }
        CGImageDestinationAddImage(destination, sanitized, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProfilePhotoContentError.normalizationFailed }
        guard output.length <= ProfilePhotoAsset.maximumByteCount else { throw ProfilePhotoContentError.outputTooLarge }
        return (output as Data, sanitized.width, sanitized.height)
    }

    static func verify(_ data: Data, asset: ProfilePhotoAsset) throws {
        guard data.count == asset.byteCount, data.count <= ProfilePhotoAsset.maximumByteCount,
              sha256(data) == asset.sha256 else { throw ProfilePhotoContentError.assetMismatch }
        let source = try imageSource(data)
        guard CGImageSourceGetType(source) as String? == UTType.png.identifier else {
            throw ProfilePhotoContentError.assetMismatch
        }
        let size = try dimensions(source)
        guard size.width == asset.width, size.height == asset.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == asset.width, image.height == asset.height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ProfilePhotoContentError.assetMismatch
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func imageSource(_ data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeName = CGImageSourceGetType(source) as String?,
              ProfilePhotoContentStore.supportedSourceTypeIdentifiers.contains(typeName),
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw ProfilePhotoContentError.invalidImage
        }
        guard CGImageSourceGetCount(source) == 1 else { throw ProfilePhotoContentError.multipleImages }
        return source
    }

    private static func dimensions(_ source: CGImageSource) throws -> (width: Int, height: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= Double(ProfilePhotoContentStore.maximumSourcePixelCount),
              height.doubleValue <= Double(ProfilePhotoContentStore.maximumSourcePixelCount),
              width.doubleValue.rounded(.towardZero) == width.doubleValue,
              height.doubleValue.rounded(.towardZero) == height.doubleValue else {
            throw ProfilePhotoContentError.excessivePixelCount
        }
        return (width.intValue, height.intValue)
    }
}

private enum PhotoDescriptors {
    static func openVerifiedRoot(_ root: VerifiedProfilePhotoRoot) throws -> Int32 {
        let opened = try openRoot(applicationSupportURL: root.applicationSupportURL)
        guard opened.identities == root.identities else {
            close(opened.fd)
            throw ProfilePhotoContentError.rootIdentityChanged
        }
        return opened.fd
    }

    static func openRoot(applicationSupportURL: URL) throws -> (fd: Int32, identities: [PhotoFileIdentity]) {
        var current = try directory(applicationSupportURL)
        var identities: [PhotoFileIdentity] = []
        do {
            for child in [nil, "HighChurn.noindex", "ProfileAssets"] as [String?] {
                if let child {
                    let next = openat(current, child, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    guard next >= 0 else { throw ProfilePhotoContentError.rootUnavailable }
                    close(current)
                    current = next
                }
                var value = stat()
                guard fstat(current, &value) == 0 else { throw ProfilePhotoContentError.rootUnavailable }
                guard value.st_mode & S_IFMT == S_IFDIR, value.st_mode & 0o7777 == 0o700,
                      value.st_uid == geteuid() else { throw ProfilePhotoContentError.rootProtectionInvalid }
                var filesystem = statfs()
                guard fstatfs(current, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                    throw ProfilePhotoContentError.nonLocalVolume
                }
                identities.append(PhotoFileIdentity(value))
            }
            return (current, identities)
        } catch {
            close(current)
            throw error
        }
    }

    static func openSource(_ url: URL) throws -> (fd: Int32, snapshot: PhotoFileSnapshot) {
        try validateSourceURL(url)
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ELOOP ? ProfilePhotoContentError.symbolicLink : .sourceUnavailable }
        do {
            let snapshot = try fileSnapshot(fd)
            guard snapshot.value.st_mode & S_IFMT == S_IFREG else { throw ProfilePhotoContentError.sourceNotRegular }
            guard snapshot.value.st_nlink == 1 else { throw ProfilePhotoContentError.unexpectedHardLinks }
            guard try !isAlias(fd) else { throw ProfilePhotoContentError.finderAlias }
            var filesystem = statfs()
            guard fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw ProfilePhotoContentError.nonLocalVolume
            }
            return (fd, snapshot)
        } catch {
            close(fd)
            throw error
        }
    }

    static func validateSourceURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.contains("\0"),
              !url.pathComponents.contains(".."), url.lastPathComponent != "/" else {
            throw ProfilePhotoContentError.invalidSourceURL
        }
    }

    static func revalidateSource(_ source: (fd: Int32, snapshot: PhotoFileSnapshot), url: URL) throws {
        guard try fileSnapshot(source.fd) == source.snapshot else { throw ProfilePhotoContentError.sourceChanged }
        let reopened = try openSource(url)
        defer { close(reopened.fd) }
        guard reopened.snapshot == source.snapshot else { throw ProfilePhotoContentError.sourceChanged }
    }

    static func fileSnapshot(_ fd: Int32) throws -> PhotoFileSnapshot {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size >= 0, value.st_size <= Int64(Int.max) else {
            throw ProfilePhotoContentError.sourceUnavailable
        }
        return PhotoFileSnapshot(value)
    }

    static func requireOwnedFile(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o7777 == 0o600,
              value.st_uid == geteuid() else { throw ProfilePhotoContentError.assetProtectionInvalid }
        guard value.st_nlink == 1 else { throw ProfilePhotoContentError.unexpectedHardLinks }
    }

    static func pathMatches(name: String, rootFD: Int32, snapshot: PhotoFileSnapshot) -> Bool {
        var value = stat()
        return fstatat(rootFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 && PhotoFileSnapshot(value) == snapshot
    }

    static func readAll(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try Task.checkCancellation()
                let result = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), min(count - offset, 64 * 1_024))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw ProfilePhotoContentError.sourceChanged }
                offset += result
            }
        }
        var extra: UInt8 = 0
        var result: Int
        repeat { result = Darwin.read(fd, &extra, 1) } while result < 0 && errno == EINTR
        guard result == 0 else { throw ProfilePhotoContentError.sourceChanged }
        return data
    }

    static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw ProfilePhotoContentError.stagingFailed }
                offset += result
            }
        }
    }

    private static func directory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.contains("\0"), !url.pathComponents.contains("..") else {
            throw ProfilePhotoContentError.invalidSourceURL
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw ProfilePhotoContentError.sourceUnavailable }
        for component in url.pathComponents.dropFirst() where component != "." && !component.isEmpty {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0 {
                var value = stat()
                let symlink = fstatat(current, component, &value, AT_SYMLINK_NOFOLLOW) == 0 && value.st_mode & S_IFMT == S_IFLNK
                close(current)
                throw symlink ? ProfilePhotoContentError.symbolicLink : .sourceUnavailable
            }
            close(current)
            current = next
        }
        return current
    }

    private static func isAlias(_ fd: Int32) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = bytes.withUnsafeMutableBytes { fgetxattr(fd, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0) }
        if count < 0 {
            if errno == ENOATTR { return false }
            throw ProfilePhotoContentError.sourceUnavailable
        }
        guard count >= 10 else { return false }
        return (UInt16(bytes[8]) << 8 | UInt16(bytes[9])) & 0x8000 != 0
    }
}

private struct PhotoFileSnapshot: Equatable {
    let value: stat
    var size: Int { Int(value.st_size) }

    init(_ value: stat) { self.value = value }

    static func == (lhs: Self, rhs: Self) -> Bool {
        PhotoFileIdentity(lhs.value) == PhotoFileIdentity(rhs.value) &&
        lhs.value.st_size == rhs.value.st_size && lhs.value.st_mode == rhs.value.st_mode &&
        lhs.value.st_uid == rhs.value.st_uid && lhs.value.st_nlink == rhs.value.st_nlink &&
        lhs.value.st_mtimespec.tv_sec == rhs.value.st_mtimespec.tv_sec &&
        lhs.value.st_mtimespec.tv_nsec == rhs.value.st_mtimespec.tv_nsec &&
        lhs.value.st_ctimespec.tv_sec == rhs.value.st_ctimespec.tv_sec &&
        lhs.value.st_ctimespec.tv_nsec == rhs.value.st_ctimespec.tv_nsec
    }
}
