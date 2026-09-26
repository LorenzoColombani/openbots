import Darwin
import Foundation

/// Exact, newly created directories for a first tool job. Every operation walks
/// from / using no-follow descriptors and binds every owned ancestor to its
/// original identity. File I/O is relative to the verified parent descriptor.
struct NativeAgenticJobWorkspace {
    let root: URL
    private var identities: [String: stat] = [:]

    init(root: URL) throws {
        guard root.isFileURL, root.deletingLastPathComponent().path == "/private/tmp",
              root.lastPathComponent.hasSuffix(".noindex"), Self.valid(root.path) else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        self.root = root
        let parent = try openDirectory(root.deletingLastPathComponent(), allowOutsideRoot: true)
        try parent.recheck()
        guard mkdirat(parent.fd, root.lastPathComponent, 0o700) == 0 else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        let value = try Self.entry(parent.fd, root.lastPathComponent)
        try Self.protect(value)
        identities[root.path] = value
        try parent.recheck()
        try verify()
    }

    mutating func createDirectory(_ url: URL) throws {
        try requireDescendant(url)
        let parent = try openDirectory(url.deletingLastPathComponent())
        try parent.recheck()
        guard mkdirat(parent.fd, url.lastPathComponent, 0o700) == 0 else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        let value = try Self.entry(parent.fd, url.lastPathComponent)
        try Self.protect(value)
        identities[url.path] = value
        try parent.recheck()
        try openDirectory(url).recheck()
    }

    func verify() throws {
        for path in identities.keys {
            try openDirectory(URL(fileURLWithPath: path)).recheck()
        }
    }

    func writeNew(_ data: Data, to url: URL) throws {
        try requireDescendant(url)
        guard data.count <= 131_072 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        let parent = try openDirectory(url.deletingLastPathComponent())
        try parent.recheck()
        let fd = openat(parent.fd, url.lastPathComponent,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        defer { close(fd) }
        let before = try Self.identity(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
              before.st_mode & 0o7777 == 0o600, before.st_nlink == 1 else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: written), data.count - written) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
            written += count
        }
        guard fsync(fd) == 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        let after = try Self.identity(fd)
        guard Self.same(before, after), after.st_nlink == 1,
              Self.same(after, try Self.entry(parent.fd, url.lastPathComponent)) else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        try parent.recheck()
    }

    func readRegular(_ url: URL, maximum: Int) throws -> Data {
        try requireDescendant(url)
        guard maximum >= 0, maximum <= 131_072 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        let parent = try openDirectory(url.deletingLastPathComponent())
        try parent.recheck()
        let fd = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NativeAgenticJobFailure.noCompletedReport }
        defer { close(fd) }
        let before = try Self.identity(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximum else { throw NativeAgenticJobFailure.unsafeWorkspace }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + max(0, count) <= maximum else { throw NativeAgenticJobFailure.unsafeWorkspace }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let after = try Self.identity(fd)
        guard Self.same(before, after), after.st_nlink == 1, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Self.same(after, try Self.entry(parent.fd, url.lastPathComponent)) else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        try parent.recheck()
        return data
    }

    private func requireDescendant(_ url: URL) throws {
        guard url.isFileURL, Self.valid(url.path), url.path.hasPrefix(root.path + "/") else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
    }

    private func openDirectory(_ url: URL, allowOutsideRoot: Bool = false) throws -> DirectoryChain {
        guard url.isFileURL, Self.valid(url.path),
              allowOutsideRoot || url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
        let first = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard first >= 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        let chain = DirectoryChain()
        do { chain.entries.append(.init(fd: first, parent: nil, name: nil, value: try Self.identity(first))) }
        catch { close(first); throw error }
        var path = ""
        for name in url.pathComponents.dropFirst() {
            path += "/" + name
            let parent = chain.fd
            let before = try Self.entry(parent, name)
            guard before.st_mode & S_IFMT == S_IFDIR else { throw NativeAgenticJobFailure.unsafeWorkspace }
            if path == root.path || path.hasPrefix(root.path + "/") {
                guard let expected = identities[path], Self.same(expected, before) else {
                    throw NativeAgenticJobFailure.unsafeWorkspace
                }
                try Self.protect(before)
            }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
            do {
                let after = try Self.identity(fd)
                guard Self.same(before, after) else { throw NativeAgenticJobFailure.unsafeWorkspace }
                chain.entries.append(.init(fd: fd, parent: parent, name: name, value: after))
            } catch { close(fd); throw error }
        }
        try chain.recheck()
        return chain
    }

    private static func valid(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 16_384
            && !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            && path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func protect(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o7777 == 0o700 else {
            throw NativeAgenticJobFailure.unsafeWorkspace
        }
    }
    private static func identity(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        return value
    }
    private static func entry(_ fd: Int32, _ name: String) throws -> stat {
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeAgenticJobFailure.unsafeWorkspace }
        return value
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_gid == b.st_gid
    }
    private final class DirectoryChain {
        struct Entry { let fd: Int32; let parent: Int32?; let name: String?; let value: stat }
        var entries: [Entry] = []
        var fd: Int32 { entries.last!.fd }
        deinit { for entry in entries.reversed() { close(entry.fd) } }
        func recheck() throws {
            for entry in entries {
                guard NativeAgenticJobWorkspace.same(entry.value, try NativeAgenticJobWorkspace.identity(entry.fd)) else {
                    throw NativeAgenticJobFailure.unsafeWorkspace
                }
                if let parent = entry.parent, let name = entry.name {
                    guard NativeAgenticJobWorkspace.same(entry.value, try NativeAgenticJobWorkspace.entry(parent, name)) else {
                        throw NativeAgenticJobFailure.unsafeWorkspace
                    }
                }
            }
        }
    }
}
