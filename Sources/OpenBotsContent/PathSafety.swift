import Darwin
import Foundation

public enum PathSafetyError: Error, Equatable, Sendable {
    case nonFileURL
    case rootDoesNotExist
    case candidateDoesNotExist
    case rootIsNotDirectory
    case symlinkEncountered(String)
    case escapesRoot
    case invalidFinalComponent
    case destinationAlreadyExists
    case parentIdentityChanged
    case unsupportedFileType
    case posixFailure(operation: String, code: Int32)
}

public struct CanonicalFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    init(stat value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
    }
}

public struct CanonicalPath: Hashable, Sendable {
    public let url: URL
    public let identity: CanonicalFileIdentity?

    init(url: URL, identity: CanonicalFileIdentity?) {
        self.url = url
        self.identity = identity
    }
}

public struct PathSafety: Sendable {
    public init() {}

    public func canonicalExistingDirectory(_ url: URL) throws -> CanonicalPath {
        guard url.isFileURL else { throw PathSafetyError.nonFileURL }
        let standardized = FileURLNormalization.lexical(url)
        try rejectSymlinksInAbsolutePath(standardized)
        var value = stat()
        guard lstat(standardized.path, &value) == 0 else {
            throw PathSafetyError.rootDoesNotExist
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw PathSafetyError.rootIsNotDirectory
        }
        return CanonicalPath(url: standardized, identity: CanonicalFileIdentity(stat: value))
    }

    public func canonicalExistingItem(_ url: URL, containedIn root: CanonicalPath) throws -> CanonicalPath {
        guard url.isFileURL else { throw PathSafetyError.nonFileURL }
        let standardized = FileURLNormalization.lexical(url)
        guard isComponentContained(standardized, in: root.url) else { throw PathSafetyError.escapesRoot }
        try rejectSymlinks(from: root.url, through: standardized)

        var value = stat()
        guard lstat(standardized.path, &value) == 0 else {
            throw PathSafetyError.candidateDoesNotExist
        }
        guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else {
            throw PathSafetyError.unsupportedFileType
        }
        return CanonicalPath(url: standardized, identity: CanonicalFileIdentity(stat: value))
    }

    public func exclusiveFutureChild(named name: String, of parent: CanonicalPath) throws -> URL {
        guard isSafeFinalComponent(name) else { throw PathSafetyError.invalidFinalComponent }
        let candidate = FileURLNormalization.lexical(
            parent.url.appending(path: name, directoryHint: .notDirectory)
        )
        guard isComponentContained(candidate, in: parent.url), candidate.deletingLastPathComponent() == parent.url else {
            throw PathSafetyError.escapesRoot
        }
        guard lstatExists(candidate.path) == false else { throw PathSafetyError.destinationAlreadyExists }
        return candidate
    }

    public func validateIdentity(of directory: URL, equals expected: CanonicalFileIdentity) throws {
        let current = try canonicalExistingDirectory(directory)
        guard current.identity == expected else { throw PathSafetyError.parentIdentityChanged }
    }

    public func isComponentContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = FileURLNormalization.lexical(root).pathComponents
        let candidateComponents = FileURLNormalization.lexical(candidate).pathComponents
        return candidateComponents.count >= rootComponents.count &&
            Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func isSafeFinalComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func rejectSymlinks(from root: URL, through candidate: URL) throws {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { throw PathSafetyError.escapesRoot }

        var current = root
        try rejectSymlink(at: current)
        for component in candidateComponents.dropFirst(rootComponents.count) {
            current.append(path: component)
            if lstatExists(current.path) {
                try rejectSymlink(at: current)
            }
        }
    }

    private func rejectSymlinksInAbsolutePath(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in FileURLNormalization.lexical(url).pathComponents.dropFirst() {
            current.append(path: component)
            if lstatExists(current.path) {
                try rejectSymlink(at: current)
            }
        }
    }

    private func rejectSymlink(at url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return }
        if value.st_mode & S_IFMT == S_IFLNK {
            throw PathSafetyError.symlinkEncountered(url.path)
        }
    }

    private func lstatExists(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0
    }
}
