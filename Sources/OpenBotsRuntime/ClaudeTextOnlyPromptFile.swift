import Darwin
import Foundation

enum ClaudeTextOnlyPromptFileError: Error {
    case unavailable
}

/// Owns one newly created file in the already admitted run temp directory.
/// No directory creation, profile access, enumeration or recursive cleanup.
/// This protects normal transport/cleanup, not against a hostile same-UID process.
final class ClaudeTextOnlyPromptFile {
    private struct Directory {
        let descriptor: Int32
        let parent: Int32?
        let name: String?
        let identity: stat
    }

    private let directories: [Directory]
    private let descriptor: Int32
    private let name: String
    private let identity: stat
    private var removed = false

    private init(directories: [Directory], descriptor: Int32, name: String, identity: stat) {
        self.directories = directories
        self.descriptor = descriptor
        self.name = name
        self.identity = identity
    }

    deinit {
        close(descriptor)
        for directory in directories.reversed() { close(directory.descriptor) }
    }

    static func create(for request: ClaudeTextOnlyRequest,
                       shouldContinue: () -> Bool = { true }) throws -> ClaudeTextOnlyPromptFile {
        let data = Data(request.systemPrompt.utf8)
        let target = request.target
        let url = ClaudeTextOnlyCommandBuilder.systemPromptFileURL(for: request)
        let tempComponents = target.temporaryDirectoryURL.pathComponents
        let profileComponents = target.profileURL.pathComponents
        guard shouldContinue(), !data.isEmpty,
              data.count <= ClaudeTextOnlyRequest.maximumSystemPromptBytes,
              !data.contains(0), url.path.utf8.count <= 4_096,
              target.temporaryDirectoryURL != target.homeDirectoryURL,
              !tempComponents.starts(with: profileComponents),
              !profileComponents.starts(with: tempComponents) else {
            throw ClaudeTextOnlyPromptFileError.unavailable
        }
        var directories = try openDirectories(target.temporaryDirectoryURL)
        var descriptor: Int32 = -1
        var createdIdentity: stat?
        var transferred = false
        let name = url.lastPathComponent
        defer {
            if !transferred {
                // Failure may leave a partial file, but never remove a preexisting
                // entry or a replacement installed at the same name.
                if let original = createdIdentity, let parent = directories.last?.descriptor,
                   recheck(directories), let entry = try? metadata(parent: parent, name: name),
                   sameIdentity(original, entry) {
                    _ = unlinkat(parent, name, 0)
                }
                if descriptor >= 0 { close(descriptor) }
                for directory in directories.reversed() { close(directory.descriptor) }
            }
        }
        guard shouldContinue(), recheck(directories), let parent = directories.last?.descriptor else {
            throw ClaudeTextOnlyPromptFileError.unavailable
        }
        descriptor = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeTextOnlyPromptFileError.unavailable }
        createdIdentity = try metadata(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw ClaudeTextOnlyPromptFileError.unavailable }
        var written = 0
        while written < data.count {
            guard shouldContinue() else { throw ClaudeTextOnlyPromptFileError.unavailable }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), min(16_384, data.count - written))
            }
            if count > 0 { written += count }
            else if count < 0, errno == EINTR { continue }
            else { throw ClaudeTextOnlyPromptFileError.unavailable }
        }
        guard fsync(descriptor) == 0 else { throw ClaudeTextOnlyPromptFileError.unavailable }
        let identity = try metadata(descriptor)
        guard identity.st_mode & S_IFMT == S_IFREG, identity.st_uid == geteuid(),
              identity.st_mode & 0o7777 == 0o600, identity.st_nlink == 1,
              identity.st_size == data.count, recheck(directories),
              sameFile(identity, try metadata(parent: parent, name: name)), shouldContinue() else {
            throw ClaudeTextOnlyPromptFileError.unavailable
        }
        let result = ClaudeTextOnlyPromptFile(directories: directories, descriptor: descriptor,
                                             name: name, identity: identity)
        transferred = true
        directories.removeAll()
        return result
    }

    /// Recheck both the lexical path and retained descriptors before CLI launch.
    func isUnchanged() -> Bool {
        guard !removed, Self.recheck(directories), let parent = directories.last?.descriptor,
              let opened = try? Self.metadata(descriptor),
              let entry = try? Self.metadata(parent: parent, name: name) else { return false }
        return Self.sameFile(identity, opened) && Self.sameFile(identity, entry)
    }

    /// Called after the owned child is reaped, including failure/cancellation.
    /// A changed path/file is preserved; failure is reported instead of widened cleanup.
    @discardableResult
    func removeIfUnchanged() -> Bool {
        if removed { return true }
        guard isUnchanged(), let parent = directories.last?.descriptor,
              unlinkat(parent, name, 0) == 0 else { return false }
        removed = true
        return fsync(parent) == 0
    }

    private static func openDirectories(_ url: URL) throws -> [Directory] {
        var result: [Directory] = []
        do {
            let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ClaudeTextOnlyPromptFileError.unavailable }
            do { result.append(Directory(descriptor: root, parent: nil, name: nil, identity: try metadata(root))) }
            catch { close(root); throw error }
            var protected = false
            for component in url.pathComponents.dropFirst() {
                guard let parent = result.last?.descriptor else { throw ClaudeTextOnlyPromptFileError.unavailable }
                protected = protected || component.hasSuffix(".noindex")
                let before = try metadata(parent: parent, name: component)
                guard before.st_mode & S_IFMT == S_IFDIR,
                      !protected || (before.st_uid == geteuid() && before.st_mode & 0o7777 == 0o700) else {
                    throw ClaudeTextOnlyPromptFileError.unavailable
                }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ClaudeTextOnlyPromptFileError.unavailable }
                do {
                    let after = try metadata(next)
                    guard sameDirectory(before, after) else { throw ClaudeTextOnlyPromptFileError.unavailable }
                    result.append(Directory(descriptor: next, parent: parent, name: component, identity: after))
                } catch { close(next); throw error }
            }
            guard protected, recheck(result) else { throw ClaudeTextOnlyPromptFileError.unavailable }
            return result
        } catch {
            for directory in result.reversed() { close(directory.descriptor) }
            throw error
        }
    }

    private static func recheck(_ directories: [Directory]) -> Bool {
        for directory in directories {
            guard let current = try? metadata(directory.descriptor),
                  sameDirectory(directory.identity, current) else { return false }
            if let parent = directory.parent, let name = directory.name {
                guard let entry = try? metadata(parent: parent, name: name),
                      sameDirectory(directory.identity, entry) else { return false }
            }
        }
        return true
    }

    private static func metadata(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ClaudeTextOnlyPromptFileError.unavailable }
        return value
    }

    private static func metadata(parent: Int32, name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ClaudeTextOnlyPromptFileError.unavailable
        }
        return value
    }

    private static func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && b.st_mode & S_IFMT == S_IFREG
            && a.st_uid == b.st_uid
    }

    private static func sameDirectory(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_gid == b.st_gid
    }

    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        sameIdentity(a, b) && a.st_mode == b.st_mode && a.st_gid == b.st_gid
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
