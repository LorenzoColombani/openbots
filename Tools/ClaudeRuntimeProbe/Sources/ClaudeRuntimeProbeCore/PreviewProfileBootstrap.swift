import Darwin
import Foundation

public struct PreviewProfileBootstrapPlan: Codable, Equatable, Sendable {
    public let profilePath: String
    public let plannedClasses: [String]
}

public struct PreviewProfilePreparationReceipt: Codable, Equatable, Sendable {
    public let profilePath: String
    public let backupsPath: String
    public let markerPath: String
}

/// Feasibility-only bootstrap for the preview-wide Claude Code profile.
///
/// This type intentionally knows nothing about Claude authentication or process
/// launch. It can create only the exact preview profile hierarchy, its private
/// `backups` directory, and the marker consumed by
/// `ClaudeConfigurationPolicy.validatePreviewDirectory`.
public struct PreviewProfileBootstrap: Sendable {
    public static let plannedClasses = [
        "preview-owned directory hierarchy (0700)",
        "Claude CLI backups directory (0700)",
        "preview profile identity marker (0600)"
    ]

    public let applicationSupportRoot: URL
    public let profileDirectory: URL

    private let requiresProductionValidation: Bool

    public init(fileManager: FileManager = .default) throws {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProbeFailure.unsafeConfiguration("Application Support could not be resolved")
        }
        let expected = try ClaudeConfigurationPolicy.expectedPreviewDirectory(fileManager: fileManager)
        self.init(
            applicationSupportRoot: applicationSupport,
            profileDirectory: expected,
            requiresProductionValidation: true
        )
    }

    /// Test-only injection point. The root must itself be beneath a randomized
    /// system-temporary `.noindex` boundary, so it cannot be redirected at the
    /// default Claude profile or a legacy OpenBots path.
    init(testApplicationSupportRoot: URL) throws {
        _ = try ProbePathPolicy.validateTemporaryNoIndexRoot(testApplicationSupportRoot)
        // Preserve the caller's physical `/private/tmp` spelling. Foundation's
        // `standardizedFileURL` rewrites it to the `/tmp` symlink on macOS,
        // which would turn a symlink-free physical fixture into an alias path.
        let root = URL(
            fileURLWithPath: testApplicationSupportRoot.path,
            isDirectory: true
        )
        self.init(
            applicationSupportRoot: root,
            profileDirectory: Self.profileDirectory(beneath: root),
            requiresProductionValidation: false
        )
    }

    private init(
        applicationSupportRoot: URL,
        profileDirectory: URL,
        requiresProductionValidation: Bool
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.profileDirectory = profileDirectory
        self.requiresProductionValidation = requiresProductionValidation
    }

    public var plan: PreviewProfileBootstrapPlan {
        PreviewProfileBootstrapPlan(
            profilePath: profileDirectory.path,
            plannedClasses: Self.plannedClasses
        )
    }

    public func prepare() throws -> PreviewProfilePreparationReceipt {
        let expected = Self.profileDirectory(beneath: applicationSupportRoot)
        guard normalizedPath(profileDirectory) == normalizedPath(expected) else {
            throw ProbeFailure.unsafeConfiguration(
                "preview bootstrap target does not equal the required profile hierarchy"
            )
        }

        try validateApplicationSupportBoundary()
        try preflightHierarchy()

        for directory in hierarchyDirectories {
            try createPrivateDirectoryIfNeeded(directory)
        }
        try createMarkerIfNeeded()
        try validateCompleteHierarchy()

        if requiresProductionValidation {
            let validated = try ClaudeConfigurationPolicy.validatePreviewDirectory(profileDirectory)
            guard normalizedPath(validated.url) == normalizedPath(profileDirectory),
                  validated.kind == .previewOwned,
                  validated.permitsLiveClaude else {
                throw ProbeFailure.unsafeConfiguration(
                    "configuration policy did not validate the exact preview profile"
                )
            }
        }

        return PreviewProfilePreparationReceipt(
            profilePath: profileDirectory.path,
            backupsPath: backupsDirectory.path,
            markerPath: markerURL.path
        )
    }

    private static func profileDirectory(beneath applicationSupport: URL) -> URL {
        applicationSupport
            .appending(path: ClaudeConfigurationPolicy.previewBundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
            .appending(path: "Runtime", directoryHint: .isDirectory)
            .appending(path: "Claude", directoryHint: .isDirectory)
            .appending(path: "CLIProfile", directoryHint: .isDirectory)
    }

    private var bundleDirectory: URL {
        applicationSupportRoot.appending(
            path: ClaudeConfigurationPolicy.previewBundleIdentifier,
            directoryHint: .isDirectory
        )
    }

    private var highChurnDirectory: URL {
        bundleDirectory.appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
    }

    private var runtimeDirectory: URL {
        highChurnDirectory.appending(path: "Runtime", directoryHint: .isDirectory)
    }

    private var claudeDirectory: URL {
        runtimeDirectory.appending(path: "Claude", directoryHint: .isDirectory)
    }

    private var backupsDirectory: URL {
        profileDirectory.appending(path: "backups", directoryHint: .isDirectory)
    }

    private var markerURL: URL {
        profileDirectory.appending(path: ClaudeConfigurationPolicy.markerFilename)
    }

    private var hierarchyDirectories: [URL] {
        [
            bundleDirectory,
            highChurnDirectory,
            runtimeDirectory,
            claudeDirectory,
            profileDirectory,
            backupsDirectory
        ]
    }

    private var allowedChildren: [(URL, Set<String>)] {
        [
            // The preview already owns legitimate siblings at the bundle,
            // HighChurn, and Runtime levels. This feasibility helper owns only
            // the Claude branch and must neither enumerate nor reject the
            // database, memories, queues, leases, or installation receipts.
            (claudeDirectory, ["CLIProfile"]),
            (profileDirectory, [ClaudeConfigurationPolicy.markerFilename, "backups"]),
            (backupsDirectory, [])
        ]
    }

    private func validateApplicationSupportBoundary() throws {
        let rootPath = applicationSupportRoot.path
        guard rootPath.hasPrefix("/") else {
            throw ProbeFailure.unsafeConfiguration("Application Support must be an absolute path")
        }

        for ancestor in pathPrefixes(through: applicationSupportRoot) {
            var metadata = stat()
            guard lstat(ancestor, &metadata) == 0 else {
                throw posixFailure("required ancestor does not exist", path: ancestor)
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                throw ProbeFailure.unsafeConfiguration(
                    "Application Support or an ancestor is a symbolic link: \(ancestor)"
                )
            }
        }

        var metadata = stat()
        guard lstat(rootPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw ProbeFailure.unsafeConfiguration(
                "Application Support must be a current-user-owned, nonsymlink directory"
            )
        }
    }

    private func preflightHierarchy() throws {
        for directory in hierarchyDirectories {
            var metadata = stat()
            if lstat(directory.path, &metadata) == 0 {
                try validatePrivateDirectory(directory, metadata: metadata)
            } else if errno != ENOENT {
                throw posixFailure("could not inspect candidate directory", path: directory.path)
            }
        }

        for (directory, allowed) in allowedChildren where pathExists(directory) {
            try validateContents(of: directory, allowedNames: allowed)
        }

        if pathExists(markerURL) {
            try validateMarker(waitForConcurrentWriter: true)
        }
    }

    private func validateCompleteHierarchy() throws {
        try validateApplicationSupportBoundary()
        for directory in hierarchyDirectories {
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0 else {
                throw posixFailure("required prepared directory is missing", path: directory.path)
            }
            try validatePrivateDirectory(directory, metadata: metadata)
        }
        for (directory, allowed) in allowedChildren {
            try validateContents(of: directory, allowedNames: allowed)
        }
        try validateMarker(waitForConcurrentWriter: true)
    }

    private func createPrivateDirectoryIfNeeded(_ directory: URL) throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            try validatePrivateDirectory(directory, metadata: metadata)
            return
        }
        guard errno == ENOENT else {
            throw posixFailure("could not inspect candidate directory", path: directory.path)
        }

        let result = directory.path.withCString { mkdir($0, 0o700) }
        if result != 0, errno != EEXIST {
            throw posixFailure("could not create private directory", path: directory.path)
        }

        if result == 0 {
            let descriptor = directory.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw posixFailure("could not secure newly created directory", path: directory.path)
            }
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o700) == 0 else {
                throw posixFailure("could not set private directory permissions", path: directory.path)
            }
        }

        guard lstat(directory.path, &metadata) == 0 else {
            throw posixFailure("created directory could not be revalidated", path: directory.path)
        }
        try validatePrivateDirectory(directory, metadata: metadata)
    }

    private func createMarkerIfNeeded() throws {
        var metadata = stat()
        if lstat(markerURL.path, &metadata) == 0 {
            try validateMarker(waitForConcurrentWriter: true)
            return
        }
        guard errno == ENOENT else {
            throw posixFailure("could not inspect preview marker", path: markerURL.path)
        }

        let descriptor = markerURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw posixFailure("could not create preview marker", path: markerURL.path)
            }
            try validateMarker(waitForConcurrentWriter: true)
            return
        }

        var closeNeeded = true
        defer {
            if closeNeeded { close(descriptor) }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw posixFailure("could not set preview marker permissions", path: markerURL.path)
        }
        try writeAll(markerPayload, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw posixFailure("could not synchronize preview marker", path: markerURL.path)
        }
        guard close(descriptor) == 0 else {
            closeNeeded = false
            throw posixFailure("could not close preview marker", path: markerURL.path)
        }
        closeNeeded = false
        try validateMarker(waitForConcurrentWriter: false)
    }

    private func validatePrivateDirectory(_ directory: URL, metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw ProbeFailure.unsafeConfiguration(
                "existing preview path must be a current-user-owned, nonsymlink directory with mode 0700: \(directory.path)"
            )
        }
    }

    private func validateContents(of directory: URL, allowedNames: Set<String>) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let unexpected = Set(names).subtracting(allowedNames)
        guard unexpected.isEmpty else {
            throw ProbeFailure.unsafeConfiguration(
                "unexpected existing content in preview hierarchy: \(unexpected.sorted().joined(separator: ", "))"
            )
        }
    }

    private func validateMarker(waitForConcurrentWriter: Bool) throws {
        let attempts = waitForConcurrentWriter ? 200 : 1
        for attempt in 0..<attempts {
            var metadata = stat()
            if lstat(markerURL.path, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFREG,
               metadata.st_uid == geteuid(),
               metadata.st_mode & 0o777 == 0o600,
               metadata.st_size == markerPayload.count,
               let data = try? Data(contentsOf: markerURL, options: [.uncached]),
               data == markerPayload {
                return
            }
            if attempt + 1 < attempts { usleep(1_000) }
        }
        throw ProbeFailure.unsafeConfiguration(
            "preview marker must be the exact owned regular file with mode 0600"
        )
    }

    private var markerPayload: Data {
        Data(
            "{\"bundleIdentifier\":\"\(ClaudeConfigurationPolicy.previewBundleIdentifier)\",\"role\":\"preview\",\"schemaVersion\":1}".utf8
        )
    }

    private func pathExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    private func pathPrefixes(through url: URL) -> [String] {
        var prefixes = ["/"]
        var current = ""
        for component in url.pathComponents.dropFirst() {
            current += "/\(component)"
            prefixes.append(current)
        }
        return prefixes
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw posixFailure("could not write preview marker", path: markerURL.path)
                }
                written += result
            }
        }
    }

    private func posixFailure(_ action: String, path: String) -> ProbeFailure {
        let code = errno
        let detail = String(cString: strerror(code))
        return .unsafeConfiguration("\(action) at \(path): \(detail) (errno \(code))")
    }
}
