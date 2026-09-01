import Darwin
import Foundation

public enum OpenBotsPreviewIdentity {
    public static let applicationName = "OpenBots Next Preview"
    public static let bundleIdentifier = "com.lorenzocolombani.openbotsnext.preview"
    public static let contentDirectoryName = "OpenBots Next Preview Content"
    /// Repository-relative; build tooling resolves this against its checked-out source root.
    public static let previewBuildRelativePath = ".build.noindex/preview"
}

public enum OwnedRootKind: String, Codable, CaseIterable, Sendable {
    case applicationSupport
    case caches
    case temporary
    case visibleContent
}

public struct OwnedRootDescriptor: Hashable, Sendable {
    public let kind: OwnedRootKind
    public let url: URL

    public var ownershipMarkerURL: URL {
        url.appending(path: ".openbots-root.json", directoryHint: .notDirectory)
    }

    init(kind: OwnedRootKind, url: URL) {
        self.kind = kind
        self.url = FileURLNormalization.lexical(url)
    }
}

/// Pure path derivation. Constructing this value never creates a directory.
public struct PreviewStorageLayout: Hashable, Sendable {
    public static let installationReceiptFileName = ".openbots-installation.json"

    public let homeDirectory: URL
    public let systemTemporaryDirectory: URL

    public let applicationSupportRoot: OwnedRootDescriptor
    public let cacheRoot: OwnedRootDescriptor
    public let temporaryRoot: OwnedRootDescriptor
    public let contentRoot: OwnedRootDescriptor

    public init(homeDirectory: URL, systemTemporaryDirectory: URL) {
        let home = FileURLNormalization.lexical(homeDirectory)
        let temporary = FileURLNormalization.lexical(systemTemporaryDirectory)
        self.homeDirectory = home
        self.systemTemporaryDirectory = temporary

        applicationSupportRoot = OwnedRootDescriptor(
            kind: .applicationSupport,
            url: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory)
                .appending(path: OpenBotsPreviewIdentity.bundleIdentifier, directoryHint: .isDirectory)
        )
        cacheRoot = OwnedRootDescriptor(
            kind: .caches,
            url: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory)
                .appending(
                    path: "\(OpenBotsPreviewIdentity.bundleIdentifier).noindex",
                    directoryHint: .isDirectory
                )
        )
        temporaryRoot = OwnedRootDescriptor(
            kind: .temporary,
            url: temporary.appending(
                path: "\(OpenBotsPreviewIdentity.bundleIdentifier).noindex",
                directoryHint: .isDirectory
            )
        )
        contentRoot = OwnedRootDescriptor(
            kind: .visibleContent,
            url: home.appending(path: OpenBotsPreviewIdentity.contentDirectoryName, directoryHint: .isDirectory)
        )
    }

    public static func live(fileManager: FileManager = .default) -> PreviewStorageLayout {
        PreviewStorageLayout(
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            // macOS commonly exposes this trusted system location through the
            // `/var` compatibility symlink. Foundation intentionally preserves
            // that spelling, so resolve this already-existing OS-provided base
            // with realpath once. The bootstrapper still rejects symlinks in
            // every app-owned descendant it subsequently opens.
            systemTemporaryDirectory: physicalSystemTemporaryDirectory(
                fileManager.temporaryDirectory
            )
        )
    }

    static func physicalSystemTemporaryDirectory(_ url: URL) -> URL {
        let resolved: UnsafeMutablePointer<CChar>? = url.withUnsafeFileSystemRepresentation {
            guard let path = $0 else { return nil }
            return realpath(path, nil)
        }
        guard let resolved else { return url }
        defer { free(resolved) }
        return URL(
            fileURLWithFileSystemRepresentation: resolved,
            isDirectory: true,
            relativeTo: nil
        )
    }

    public var highChurnRoot: URL {
        applicationSupportRoot.url.appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
    }

    /// Immutable, nonsecret bootstrap authority used to revalidate a preview
    /// installation before reopening its control database. It is deliberately
    /// outside the high-churn subtree and is never rewritten in place.
    public var installationReceiptURL: URL {
        applicationSupportRoot.url.appending(
            path: Self.installationReceiptFileName,
            directoryHint: .notDirectory
        )
    }

    public var databaseDirectory: URL {
        highChurnRoot.appending(path: "State", directoryHint: .isDirectory)
    }

    public var databaseURL: URL {
        databaseDirectory.appending(path: "OpenBots.sqlite", directoryHint: .notDirectory)
    }

    public var databaseWALURL: URL {
        databaseDirectory.appending(path: "OpenBots.sqlite-wal", directoryHint: .notDirectory)
    }

    public var databaseSHMURL: URL {
        databaseDirectory.appending(path: "OpenBots.sqlite-shm", directoryHint: .notDirectory)
    }

    public var databaseBackupsRoot: URL {
        highChurnRoot.appending(path: "DatabaseBackups", directoryHint: .isDirectory)
    }

    public var runtimeRoot: URL {
        highChurnRoot.appending(path: "Runtime", directoryHint: .isDirectory)
    }

    public var queueRoot: URL { runtimeRoot.appending(path: "Queues", directoryHint: .isDirectory) }
    public var leaseRoot: URL { runtimeRoot.appending(path: "Leases", directoryHint: .isDirectory) }
    public var checkpointRoot: URL { runtimeRoot.appending(path: "Checkpoints", directoryHint: .isDirectory) }
    public var runtimeMetadataRoot: URL { runtimeRoot.appending(path: "Metadata", directoryHint: .isDirectory) }

    public var claudeCLIProfileRoot: URL {
        runtimeRoot
            .appending(path: "Claude", directoryHint: .isDirectory)
            .appending(path: "CLIProfile", directoryHint: .isDirectory)
    }

    public var generatedConfigurationRoot: URL {
        highChurnRoot.appending(path: "GeneratedConfig", directoryHint: .isDirectory)
    }

    public var logsRoot: URL { highChurnRoot.appending(path: "Logs", directoryHint: .isDirectory) }
    public var profileAssetsRoot: URL { highChurnRoot.appending(path: "ProfileAssets", directoryHint: .isDirectory) }
    public var internalAttachmentsRoot: URL { highChurnRoot.appending(path: "Attachments", directoryHint: .isDirectory) }
    public var internalWorkspacesRoot: URL { highChurnRoot.appending(path: "Workspaces", directoryHint: .isDirectory) }
    public var internalMemoryRoot: URL { highChurnRoot.appending(path: "Memory", directoryHint: .isDirectory) }
    public var internalProjectsRoot: URL { highChurnRoot.appending(path: "Projects", directoryHint: .isDirectory) }

    public var cacheIndexesRoot: URL { cacheRoot.url.appending(path: "Indexes", directoryHint: .isDirectory) }
    public var cacheSearchRoot: URL { cacheRoot.url.appending(path: "Search", directoryHint: .isDirectory) }
    public var cacheThumbnailsRoot: URL { cacheRoot.url.appending(path: "Thumbnails", directoryHint: .isDirectory) }
    public var cacheRenderingRoot: URL { cacheRoot.url.appending(path: "Rendering", directoryHint: .isDirectory) }
    public var cacheDownloadsRoot: URL { cacheRoot.url.appending(path: "Downloads", directoryHint: .isDirectory) }
    public var cacheDerivedMetadataRoot: URL { cacheRoot.url.appending(path: "DerivedMetadata", directoryHint: .isDirectory) }
    public var attachmentIngestRoot: URL { cacheRoot.url.appending(path: "AttachmentIngest", directoryHint: .isDirectory) }
    public var avatarIngestRoot: URL { cacheRoot.url.appending(path: "AvatarIngest", directoryHint: .isDirectory) }
    public var avatarRendersRoot: URL { cacheRoot.url.appending(path: "AvatarRenders", directoryHint: .isDirectory) }
    public var perRunRuntimeRoot: URL { cacheRoot.url.appending(path: "Runtime", directoryHint: .isDirectory) }
    public var skillStagingRoot: URL { cacheRoot.url.appending(path: "SkillStaging", directoryHint: .isDirectory) }

    public var visibleWorkingRoot: URL {
        contentRoot.url.appending(path: "Working.noindex", directoryHint: .isDirectory)
    }

    public var stableAttachmentsRoot: URL {
        contentRoot.url.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    public var stableProjectsRoot: URL {
        contentRoot.url.appending(path: "Projects", directoryHint: .isDirectory)
    }

    public var knowledgeSnapshotsRoot: URL {
        contentRoot.url.appending(path: "Knowledge Snapshots", directoryHint: .isDirectory)
    }

    public var skillsRoot: URL {
        contentRoot.url.appending(path: "Skills", directoryHint: .isDirectory)
    }

    public var exportsRoot: URL {
        contentRoot.url.appending(path: "Exports", directoryHint: .isDirectory)
    }

    public var internalRequiredDirectoryURLs: [URL] {
        // `claudeCLIProfileRoot` is intentionally not materialized here. The separate
        // authenticated Claude bootstrap owns that exact, disclosed side effect.
        [
            highChurnRoot,
            databaseDirectory,
            databaseBackupsRoot,
            runtimeRoot,
            queueRoot,
            leaseRoot,
            checkpointRoot,
            runtimeMetadataRoot,
            generatedConfigurationRoot,
            logsRoot,
            profileAssetsRoot,
            internalAttachmentsRoot,
            internalWorkspacesRoot,
            internalMemoryRoot,
            internalProjectsRoot,
            cacheIndexesRoot,
            cacheSearchRoot,
            cacheThumbnailsRoot,
            cacheRenderingRoot,
            cacheDownloadsRoot,
            cacheDerivedMetadataRoot,
            attachmentIngestRoot,
            avatarIngestRoot,
            avatarRendersRoot,
            perRunRuntimeRoot,
            skillStagingRoot
        ]
    }

    public var visibleContentRequiredDirectoryURLs: [URL] {
        [
            visibleWorkingRoot,
            stableAttachmentsRoot,
            stableProjectsRoot,
            knowledgeSnapshotsRoot,
            skillsRoot,
            exportsRoot
        ]
    }

    public var requiredDirectoryURLs: [URL] {
        internalRequiredDirectoryURLs + visibleContentRequiredDirectoryURLs
    }
}
