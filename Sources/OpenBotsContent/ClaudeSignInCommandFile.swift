import Darwin
import Foundation

public enum ClaudeSignInCommandFileError: Error, Equatable, Sendable {
    case invalidScript
    case rootMismatch
    case missingParent
    case collision
    case rejected(ClaudeProfileInspectionIssue)
    case unavailable
}

/// Stores a nonsecret command built by the typed connection service. This does not launch
/// Terminal or Claude, inspect CLI state, or grant authentication/execution authority.
public struct ClaudeSignInCommandFileStore: Sendable {
    public static let maximumScriptBytes = 32 * 1_024

    private let identifier: UUID?
    private let beforePublication: (@Sendable () throws -> Void)?

    public init() {
        identifier = nil
        beforePublication = nil
    }

    // Deterministic collision/replacement tests; production has no mutation hook.
    init(identifier: UUID, beforePublication: (@Sendable () throws -> Void)? = nil) {
        self.identifier = identifier
        self.beforePublication = beforePublication
    }

    /// Creates exactly one UUID.command, never overwriting or deleting an entry. Failure may
    /// retain a private incomplete file; cleanup is deliberately outside this narrow authority.
    public func create(
        script: String,
        applicationSupportRoot: VerifiedOwnedRoot,
        layout: PreviewStorageLayout
    ) throws -> URL {
        let bytes = Data(script.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumScriptBytes, !bytes.contains(0) else {
            throw ClaudeSignInCommandFileError.invalidScript
        }
        guard applicationSupportRoot.kind == .applicationSupport,
              applicationSupportRoot.url == layout.applicationSupportRoot.url,
              applicationSupportRoot.url.isFileURL,
              applicationSupportRoot.url.path.hasPrefix("/"),
              !applicationSupportRoot.url.path.contains("\0"),
              !applicationSupportRoot.url.pathComponents.contains(".."),
              applicationSupportRoot.url.pathComponents.count <= 128 else {
            throw ClaudeSignInCommandFileError.rootMismatch
        }

        var directories: [OpenedDirectory] = []
        defer { for directory in directories.reversed() { close(directory.fd) } }
        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard rootFD >= 0 else { throw ClaudeSignInCommandFileError.unavailable }
        do {
            directories.append(OpenedDirectory(
                fd: rootFD, parentFD: nil, name: nil, metadata: try metadata(rootFD)
            ))
        } catch {
            close(rootFD)
            throw error
        }
        let components = Array(applicationSupportRoot.url.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            try appendDirectory(component, protected: index == components.count - 1, to: &directories)
        }
        guard let applicationSupportFD = directories.last?.fd else {
            throw ClaudeSignInCommandFileError.unavailable
        }
        let marker = try openRootMarker(parentFD: applicationSupportFD)
        defer { close(marker.fd) }
        let expected = OwnedRootMarker(
            installationID: applicationSupportRoot.installationID,
            rootID: applicationSupportRoot.rootID,
            kind: .applicationSupport
        )
        guard let decoded = try? JSONDecoder().decode(OwnedRootMarker.self, from: marker.data),
              decoded == expected else { throw ClaudeSignInCommandFileError.rootMismatch }

        // All these ancestors must already exist. CLIProfile is a sibling and stays opaque.
        for component in ["HighChurn.noindex", "Runtime", "Claude"] {
            try appendDirectory(component, protected: true, to: &directories)
        }
        try verifyDirectories(directories)
        try verifyMarker(marker)
        guard let claudeFD = directories.last?.fd else {
            throw ClaudeSignInCommandFileError.unavailable
        }
        var existing = stat()
        if fstatat(claudeFD, "SignInHandoffs", &existing, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw failure(errno) }
            // Only this exact final directory may be created; never mkdir -p or repair.
            guard mkdirat(claudeFD, "SignInHandoffs", S_IRWXU) == 0 else {
                if errno == EEXIST { throw ClaudeSignInCommandFileError.collision }
                throw failure(errno)
            }
        }
        try appendDirectory("SignInHandoffs", protected: true, to: &directories)
        try verifyDirectories(directories)
        try verifyMarker(marker)
        guard let handoffsFD = directories.last?.fd else {
            throw ClaudeSignInCommandFileError.unavailable
        }

        let filename = "\((identifier ?? UUID()).uuidString).command"
        let fd = openat(
            handoffsFD, filename,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            if errno == EEXIST { throw ClaudeSignInCommandFileError.collision }
            throw failure(errno)
        }
        defer { close(fd) }
        let initial = try metadata(fd)
        try validateCommand(initial, mode: 0o600)
        guard initial.st_size == 0,
              sameIdentity(initial, try entry(handoffsFD, filename)) else {
            throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
        }
        try write(bytes, to: fd)
        guard fsync(fd) == 0 else { throw ClaudeSignInCommandFileError.unavailable }
        let written = try metadata(fd)
        try validateCommand(written, mode: 0o600)
        guard sameIdentity(initial, written), written.st_size == bytes.count else {
            throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
        }
        try beforePublication?()
        try verifyDirectories(directories)
        try verifyMarker(marker)
        try verifyCommand(fd, parentFD: handoffsFD, name: filename, snapshot: written, bytes: bytes)

        // An incomplete command is not executable. Terminal receives only the completed file.
        guard fchmod(fd, S_IRWXU) == 0, fsync(fd) == 0 else {
            throw ClaudeSignInCommandFileError.unavailable
        }
        let published = try metadata(fd)
        try validateCommand(published, mode: 0o700)
        guard written.st_dev == published.st_dev, written.st_ino == published.st_ino else {
            throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
        }
        try verifyCommand(fd, parentFD: handoffsFD, name: filename, snapshot: published, bytes: bytes)
        try verifyDirectories(directories)
        try verifyMarker(marker)
        return layout.runtimeRoot.appending(path: "Claude/SignInHandoffs", directoryHint: .isDirectory)
            .appending(path: filename, directoryHint: .notDirectory)
    }

    private func appendDirectory(
        _ name: String, protected: Bool, to directories: inout [OpenedDirectory]
    ) throws {
        guard let parentFD = directories.last?.fd else { throw ClaudeSignInCommandFileError.unavailable }
        let before = try entry(parentFD, name)
        if before.st_mode & S_IFMT == S_IFLNK { throw ClaudeSignInCommandFileError.rejected(.symbolicLink) }
        guard before.st_mode & S_IFMT == S_IFDIR else {
            throw ClaudeSignInCommandFileError.rejected(.wrongFileType)
        }
        if protected, let issue = ClaudeProfileMetadataPolicy.directoryIssue(before) {
            throw ClaudeSignInCommandFileError.rejected(issue)
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        do {
            let opened = try metadata(fd)
            guard sameIdentity(before, opened) else {
                throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
            }
            directories.append(OpenedDirectory(fd: fd, parentFD: parentFD, name: name, metadata: opened))
        } catch {
            close(fd)
            throw error
        }
    }

    private func openRootMarker(parentFD: Int32) throws -> OpenedMarker {
        let name = ".openbots-root.json"
        let before = try entry(parentFD, name)
        if let issue = ClaudeProfileMetadataPolicy.markerIssue(before) {
            throw ClaudeSignInCommandFileError.rejected(issue)
        }
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        do {
            guard sameSnapshot(before, try metadata(fd)) else {
                throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
            }
            let marker = OpenedMarker(
                fd: fd, parentFD: parentFD, metadata: before,
                data: try read(fd, maximumBytes: ClaudeProfileInspector.maximumMarkerBytes)
            )
            try verifyMarker(marker)
            return marker
        } catch {
            close(fd)
            throw error
        }
    }

    private func verifyMarker(_ marker: OpenedMarker) throws {
        guard sameSnapshot(marker.metadata, try metadata(marker.fd)),
              sameSnapshot(marker.metadata, try recheckedEntry(marker.parentFD, ".openbots-root.json")),
              marker.data.count == marker.metadata.st_size else {
            throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
        }
    }

    private func verifyDirectories(_ directories: [OpenedDirectory]) throws {
        for directory in directories.reversed() {
            guard sameIdentity(directory.metadata, try metadata(directory.fd)) else {
                throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
            }
            if let parentFD = directory.parentFD, let name = directory.name {
                guard sameIdentity(directory.metadata, try recheckedEntry(parentFD, name)) else {
                    throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
                }
            }
        }
    }

    private func verifyCommand(
        _ fd: Int32, parentFD: Int32, name: String, snapshot: stat, bytes: Data
    ) throws {
        guard sameSnapshot(snapshot, try metadata(fd)),
              sameSnapshot(snapshot, try recheckedEntry(parentFD, name)),
              try read(fd, maximumBytes: Self.maximumScriptBytes) == bytes,
              sameSnapshot(snapshot, try metadata(fd)) else {
            throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
        }
    }

    private func validateCommand(_ value: stat, mode: mode_t) throws {
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw ClaudeSignInCommandFileError.rejected(.wrongFileType)
        }
        guard value.st_uid == geteuid() else { throw ClaudeSignInCommandFileError.rejected(.wrongOwner) }
        guard value.st_mode & 0o7777 == mode else {
            throw ClaudeSignInCommandFileError.rejected(.unsafePermissions)
        }
        guard value.st_nlink == 1 else { throw ClaudeSignInCommandFileError.rejected(.unexpectedHardLinks) }
    }

    private func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            for _ in 0..<64 {
                if offset == bytes.count { return }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ClaudeSignInCommandFileError.unavailable }
                offset += count
            }
            throw ClaudeSignInCommandFileError.unavailable
        }
    }

    private func read(_ fd: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress, maximumBytes + 1 - data.count, off_t(data.count))
            }
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClaudeSignInCommandFileError.unavailable }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else {
                throw ClaudeSignInCommandFileError.rejected(.changedIdentity)
            }
        }
        throw ClaudeSignInCommandFileError.unavailable
    }

    private func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ClaudeSignInCommandFileError.unavailable }
        return value
    }

    private func entry(_ parentFD: Int32, _ name: String) throws -> stat {
        var value = stat()
        guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(errno) }
        return value
    }

    private func recheckedEntry(_ parentFD: Int32, _ name: String) throws -> stat {
        do { return try entry(parentFD, name) }
        catch { throw ClaudeSignInCommandFileError.rejected(.changedIdentity) }
    }

    private func failure(_ code: Int32) -> ClaudeSignInCommandFileError {
        switch code {
        case ENOENT: .missingParent
        case ELOOP: .rejected(.symbolicLink)
        case ENOTDIR: .rejected(.wrongFileType)
        default: .unavailable
        }
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
    }

    private func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_size == rhs.st_size && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
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
        let metadata: stat
        let data: Data
    }
}
