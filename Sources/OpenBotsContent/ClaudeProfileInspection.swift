import Darwin
import Foundation

public enum ClaudeProfileInspectionIssue: String, Equatable, Sendable {
    case rootMismatch
    case symbolicLink
    case wrongFileType
    case unsafePermissions
    case wrongOwner
    case unexpectedHardLinks
    case invalidMarker
    case markerTooLarge
    case changedIdentity
}

/// Metadata verification is neither authentication nor permission to launch Claude.
public enum ClaudeProfileInspectionResult: Equatable, Sendable {
    case missing
    case metadataVerified
    case rejected(ClaudeProfileInspectionIssue)
    case unavailable
}

/// Reads only the exact nonsecret root and profile ownership markers. It never enumerates the
/// profile, opens Claude state, or creates or repairs any filesystem entry.
public struct ClaudeProfileInspector: Sendable {
    public static let markerFilename = ".openbots-claude-profile.json"
    public static let maximumMarkerBytes = 4_096

    private let afterMarkerRead: (@Sendable () throws -> Void)?

    public init() { afterMarkerRead = nil }

    // Deterministic replacement tests; the public inspector has no mutation hook.
    init(afterMarkerRead: @escaping @Sendable () throws -> Void) {
        self.afterMarkerRead = afterMarkerRead
    }

    public func inspect(
        applicationSupportRoot: VerifiedOwnedRoot,
        layout: PreviewStorageLayout
    ) -> ClaudeProfileInspectionResult {
        guard applicationSupportRoot.kind == .applicationSupport,
              applicationSupportRoot.url == layout.applicationSupportRoot.url,
              applicationSupportRoot.url.isFileURL,
              applicationSupportRoot.url.path.hasPrefix("/"),
              !applicationSupportRoot.url.path.contains("\0"),
              !applicationSupportRoot.url.pathComponents.contains(".."),
              applicationSupportRoot.url.pathComponents.count <= 128 else {
            return .rejected(.rootMismatch)
        }

        do {
            try inspectMetadata(in: applicationSupportRoot)
            return .metadataVerified
        } catch let failure as InspectionFailure {
            switch failure {
            case .missing: return .missing
            case .rejected(let issue): return .rejected(issue)
            case .unavailable: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private func inspectMetadata(in applicationSupportRoot: VerifiedOwnedRoot) throws {
        var directories: [OpenedDirectory] = []
        defer { for directory in directories.reversed() { close(directory.fd) } }

        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard rootFD >= 0 else { throw InspectionFailure.unavailable }
        let rootMetadata: stat
        do { rootMetadata = try descriptorMetadata(rootFD) }
        catch { close(rootFD); throw error }
        directories.append(OpenedDirectory(fd: rootFD, parentFD: nil, name: nil, metadata: rootMetadata))

        let components = Array(applicationSupportRoot.url.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            try appendDirectory(
                named: component,
                protected: index == components.count - 1,
                to: &directories
            )
        }
        guard let applicationSupportFD = directories.last?.fd else { throw InspectionFailure.unavailable }
        let rootMarker = try openMarker(parentFD: applicationSupportFD, name: ".openbots-root.json")
        defer { close(rootMarker.fd) }
        let expectedRootMarker = OwnedRootMarker(
            installationID: applicationSupportRoot.installationID,
            rootID: applicationSupportRoot.rootID,
            kind: .applicationSupport
        )
        guard let actualRootMarker = try? JSONDecoder().decode(OwnedRootMarker.self, from: rootMarker.data),
              actualRootMarker == expectedRootMarker else {
            throw InspectionFailure.rejected(.rootMismatch)
        }
        for component in ["HighChurn.noindex", "Runtime", "Claude", "CLIProfile"] {
            try appendDirectory(named: component, protected: true, to: &directories)
        }
        guard let profileFD = directories.last?.fd else { throw InspectionFailure.unavailable }

        // Only metadata for backups; its children remain completely opaque.
        let backups = try entryMetadata(parentFD: profileFD, name: "backups")
        if let issue = ClaudeProfileMetadataPolicy.directoryIssue(backups) {
            throw InspectionFailure.rejected(issue)
        }

        let profileMarker = try openMarker(parentFD: profileFD, name: Self.markerFilename)
        defer { close(profileMarker.fd) }
        try afterMarkerRead?()
        try verifyUnchanged(rootMarker)
        try verifyUnchanged(profileMarker)
        guard sameIdentity(backups, try recheckedEntry(parentFD: profileFD, name: "backups")) else {
            throw InspectionFailure.rejected(.changedIdentity)
        }
        for directory in directories.reversed() {
            guard sameIdentity(directory.metadata, try descriptorMetadata(directory.fd)) else {
                throw InspectionFailure.rejected(.changedIdentity)
            }
            if let parentFD = directory.parentFD, let name = directory.name {
                guard sameIdentity(directory.metadata, try recheckedEntry(parentFD: parentFD, name: name)) else {
                    throw InspectionFailure.rejected(.changedIdentity)
                }
            }
        }

        guard let marker = try? JSONDecoder().decode(ProfileMarker.self, from: profileMarker.data),
              marker.schemaVersion == 1,
              marker.bundleIdentifier == OpenBotsPreviewIdentity.bundleIdentifier,
              marker.role == "preview" else {
            throw InspectionFailure.rejected(.invalidMarker)
        }
    }

    private func openMarker(parentFD: Int32, name: String) throws -> OpenedMarker {
        let before = try entryMetadata(parentFD: parentFD, name: name)
        if let issue = ClaudeProfileMetadataPolicy.markerIssue(before) {
            throw InspectionFailure.rejected(issue)
        }
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failureForOpen(errno) }
        do {
            let opened = try descriptorMetadata(fd)
            guard sameFileSnapshot(before, opened) else { throw InspectionFailure.rejected(.changedIdentity) }
            if let issue = ClaudeProfileMetadataPolicy.markerIssue(opened) {
                throw InspectionFailure.rejected(issue)
            }
            let marker = OpenedMarker(fd: fd, parentFD: parentFD, name: name, metadata: opened, data: try readMarker(fd))
            try verifyUnchanged(marker)
            return marker
        } catch {
            close(fd)
            throw error
        }
    }

    private func verifyUnchanged(_ marker: OpenedMarker) throws {
        guard sameFileSnapshot(marker.metadata, try descriptorMetadata(marker.fd)),
              sameFileSnapshot(marker.metadata, try recheckedEntry(parentFD: marker.parentFD, name: marker.name)),
              marker.data.count == Int(marker.metadata.st_size) else {
            throw InspectionFailure.rejected(.changedIdentity)
        }
    }

    private func appendDirectory(
        named name: String,
        protected: Bool,
        to directories: inout [OpenedDirectory]
    ) throws {
        guard let parentFD = directories.last?.fd else { throw InspectionFailure.unavailable }
        let before = try entryMetadata(parentFD: parentFD, name: name)
        if before.st_mode & S_IFMT == S_IFLNK { throw InspectionFailure.rejected(.symbolicLink) }
        guard before.st_mode & S_IFMT == S_IFDIR else {
            throw InspectionFailure.rejected(.wrongFileType)
        }
        if protected, let issue = ClaudeProfileMetadataPolicy.directoryIssue(before) {
            throw InspectionFailure.rejected(issue)
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failureForOpen(errno) }
        do {
            let opened = try descriptorMetadata(fd)
            guard sameIdentity(before, opened) else { throw InspectionFailure.rejected(.changedIdentity) }
            directories.append(OpenedDirectory(fd: fd, parentFD: parentFD, name: name, metadata: opened))
        } catch {
            close(fd)
            throw error
        }
    }

    private func readMarker(_ fd: Int32) throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: Self.maximumMarkerBytes + 1)
        // A regular file is at most 4 KiB; bound interrupted/short-read retries too.
        for _ in 0..<16 {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, min($0.count, Self.maximumMarkerBytes + 1 - data.count))
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw InspectionFailure.unavailable
            }
            data.append(contentsOf: bytes.prefix(count))
            if data.count > Self.maximumMarkerBytes { throw InspectionFailure.rejected(.markerTooLarge) }
        }
        throw InspectionFailure.unavailable
    }

    private func descriptorMetadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw InspectionFailure.unavailable }
        return value
    }

    private func entryMetadata(parentFD: Int32, name: String) throws -> stat {
        var value = stat()
        guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw failureForOpen(errno)
        }
        return value
    }

    private func recheckedEntry(parentFD: Int32, name: String) throws -> stat {
        do { return try entryMetadata(parentFD: parentFD, name: name) }
        catch { throw InspectionFailure.rejected(.changedIdentity) }
    }

    private func failureForOpen(_ code: Int32) -> InspectionFailure {
        switch code {
        case ENOENT: return .missing
        case ELOOP: return .rejected(.symbolicLink)
        case ENOTDIR: return .rejected(.wrongFileType)
        default: return .unavailable
        }
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
    }

    private func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_size == rhs.st_size && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private struct ProfileMarker: Decodable {
        let schemaVersion: Int
        let bundleIdentifier: String
        let role: String
    }

    private struct OpenedDirectory {
        let fd: Int32
        let parentFD: Int32?
        let name: String?
        let metadata: stat
    }

    private struct OpenedMarker {
        let fd: Int32
        let parentFD: Int32
        let name: String
        let metadata: stat
        let data: Data
    }

    private enum InspectionFailure: Error {
        case missing
        case rejected(ClaudeProfileInspectionIssue)
        case unavailable
    }
}

enum ClaudeProfileMetadataPolicy {
    static func directoryIssue(_ value: stat, expectedOwner: uid_t = geteuid()) -> ClaudeProfileInspectionIssue? {
        if value.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        guard value.st_mode & S_IFMT == S_IFDIR else { return .wrongFileType }
        guard value.st_uid == expectedOwner else { return .wrongOwner }
        guard value.st_mode & 0o7777 == 0o700 else { return .unsafePermissions }
        return nil
    }

    static func markerIssue(_ value: stat, expectedOwner: uid_t = geteuid()) -> ClaudeProfileInspectionIssue? {
        if value.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        guard value.st_mode & S_IFMT == S_IFREG else { return .wrongFileType }
        guard value.st_uid == expectedOwner else { return .wrongOwner }
        guard value.st_mode & 0o7777 == 0o600 else { return .unsafePermissions }
        guard value.st_nlink == 1 else { return .unexpectedHardLinks }
        guard value.st_size > 0 else { return .invalidMarker }
        guard value.st_size <= ClaudeProfileInspector.maximumMarkerBytes else { return .markerTooLarge }
        return nil
    }
}
