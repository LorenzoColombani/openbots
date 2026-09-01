import Darwin
import Foundation

public enum ClaudeTextRunDirectoryError: Error, Equatable, Sendable {
    case rootMismatch, unsafeDirectory, changedIdentity, collision, unavailable
}

public struct ClaudeTextRunDirectories: Equatable, Sendable {
    public let workingDirectory: URL
    public let temporaryDirectory: URL
}

/// Creates only a fresh UUID's empty working/temp children inside the verified
/// Preview runtime root. It never reads, enumerates or repairs Claude's profile.
public struct ClaudeTextRunDirectoryStore: Sendable {
    public init() {}

    public func create(runID: UUID, applicationSupportRoot root: VerifiedOwnedRoot,
                       layout: PreviewStorageLayout) throws -> ClaudeTextRunDirectories {
        guard root.kind == .applicationSupport, root.url == layout.applicationSupportRoot.url else {
            throw ClaudeTextRunDirectoryError.rootMismatch
        }
        let verified = try OwnedRootVerifier().verify(layout.applicationSupportRoot,
            expectedInstallationID: root.installationID, expectedRootID: root.rootID)
        guard verified == root else { throw ClaudeTextRunDirectoryError.rootMismatch }
        var opened: [Directory] = []
        var leaves: [Directory] = []
        defer { for directory in (opened + leaves).reversed() { close(directory.fd) } }
        let first = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard first >= 0 else { throw ClaudeTextRunDirectoryError.unavailable }
        do { opened.append(Directory(fd: first, parent: nil, name: nil, identity: try identity(first))) }
        catch { close(first); throw error }
        let components = Array(root.url.pathComponents.dropFirst())
        for (index, name) in components.enumerated() {
            try append(name, protected: index == components.count - 1, to: &opened)
        }
        for name in ["HighChurn.noindex", "Runtime", "Claude"] {
            try append(name, protected: true, to: &opened)
        }
        try recheck(opened)
        try createChild("TextTurns", exclusive: false, in: opened.last!.fd)
        try append("TextTurns", protected: true, to: &opened)
        let runName = runID.uuidString
        try createChild(runName, exclusive: true, in: opened.last!.fd)
        try append(runName, protected: true, to: &opened)
        let runFD = opened.last!.fd
        for name in ["Work.noindex", "Temp.noindex"] {
            try createChild(name, exclusive: true, in: runFD)
            try append(name, protected: true, to: &opened)
            // Both leaves share the run parent; retain descriptors through publication.
            leaves.append(opened.removeLast())
        }
        try recheck(opened + leaves)
        let verifiedAfter = try OwnedRootVerifier().verify(layout.applicationSupportRoot,
            expectedInstallationID: root.installationID, expectedRootID: root.rootID)
        guard verifiedAfter == root else { throw ClaudeTextRunDirectoryError.rootMismatch }
        try recheck(opened + leaves)
        let base = layout.runtimeRoot.appending(path: "Claude/TextTurns/\(runName)", directoryHint: .isDirectory)
        return ClaudeTextRunDirectories(
            workingDirectory: base.appending(path: "Work.noindex", directoryHint: .isDirectory),
            temporaryDirectory: base.appending(path: "Temp.noindex", directoryHint: .isDirectory))
    }

    private struct Directory {
        let fd: Int32
        let parent: Int32?
        let name: String?
        let identity: stat
    }

    private func createChild(_ name: String, exclusive: Bool, in parent: Int32) throws {
        if mkdirat(parent, name, S_IRWXU) == 0 {
            guard fsync(parent) == 0 else { throw ClaudeTextRunDirectoryError.unavailable }
            return
        }
        guard !exclusive, errno == EEXIST else {
            throw errno == EEXIST ? ClaudeTextRunDirectoryError.collision : .unavailable
        }
    }

    private func append(_ name: String, protected: Bool, to opened: inout [Directory]) throws {
        guard let parent = opened.last?.fd else { throw ClaudeTextRunDirectoryError.unavailable }
        let before = try entry(parent, name)
        guard before.st_mode & S_IFMT == S_IFDIR else { throw ClaudeTextRunDirectoryError.unsafeDirectory }
        if protected { try protect(before) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeTextRunDirectoryError.unsafeDirectory }
        do {
            let after = try identity(fd)
            guard same(before, after) else { throw ClaudeTextRunDirectoryError.changedIdentity }
            opened.append(Directory(fd: fd, parent: parent, name: name, identity: after))
        } catch { close(fd); throw error }
    }

    private func protect(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(),
              value.st_mode & 0o7777 == 0o700 else { throw ClaudeTextRunDirectoryError.unsafeDirectory }
    }

    private func identity(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ClaudeTextRunDirectoryError.unavailable }
        return value
    }

    private func entry(_ parent: Int32, _ name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ClaudeTextRunDirectoryError.unavailable
        }
        return value
    }

    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_gid == b.st_gid
    }

    private func recheck(_ opened: [Directory]) throws {
        for directory in opened {
            guard same(directory.identity, try identity(directory.fd)) else {
                throw ClaudeTextRunDirectoryError.changedIdentity
            }
            if let parent = directory.parent, let name = directory.name {
                guard same(directory.identity, try entry(parent, name)) else {
                    throw ClaudeTextRunDirectoryError.changedIdentity
                }
            }
        }
    }
}
