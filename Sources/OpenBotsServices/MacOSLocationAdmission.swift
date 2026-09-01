import Foundation
@preconcurrency import FileProvider
import OpenBotsContent

/// Async location inspection used at application-service boundaries. This is
/// intentionally separate from the synchronous content-domain test seam because
/// File Provider ownership is reported by a callback-based macOS API.
public protocol MacOSLocationAdmissionChecking: Sendable {
    func observation(for url: URL) async throws -> LocationObservation
}

public struct MacOSLocationResourceSnapshot: Hashable, Sendable {
    public let inspectedURL: URL
    public let isLocalVolume: Bool
    public let isReadOnlyVolume: Bool
    public let isUbiquitousItem: Bool
    public let volumeIdentifier: String?

    public init(
        inspectedURL: URL,
        isLocalVolume: Bool,
        isReadOnlyVolume: Bool,
        isUbiquitousItem: Bool,
        volumeIdentifier: String?
    ) {
        self.inspectedURL = inspectedURL
        self.isLocalVolume = isLocalVolume
        self.isReadOnlyVolume = isReadOnlyVolume
        self.isUbiquitousItem = isUbiquitousItem
        self.volumeIdentifier = volumeIdentifier
    }
}

public protocol MacOSLocationResourceReading: Sendable {
    /// Reads the nearest existing ancestor when `url` has not been created yet.
    /// The returned URL is the exact item inspected by the File Provider lookup.
    func snapshot(for url: URL) throws -> MacOSLocationResourceSnapshot
}

public struct FoundationMacOSLocationResourceReader: MacOSLocationResourceReading {
    public init() {}

    public func snapshot(for url: URL) throws -> MacOSLocationResourceSnapshot {
        // `standardizedFileURL` may rewrite an existing physical `/private/tmp`
        // path through the `/tmp` convenience symlink. Keep this lexical so the
        // later no-symlink filesystem gate inspects the same physical ancestry.
        var inspectedURL = ServiceFileURLNormalization.lexical(url)
        while !FileManager.default.fileExists(atPath: inspectedURL.path), inspectedURL.path != "/" {
            inspectedURL.deleteLastPathComponent()
        }

        let values = try inspectedURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIdentifierKey
        ])
        return MacOSLocationResourceSnapshot(
            inspectedURL: inspectedURL,
            isLocalVolume: values.volumeIsLocal ?? false,
            isReadOnlyVolume: values.volumeIsReadOnly ?? true,
            isUbiquitousItem: values.isUbiquitousItem ?? false,
            volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) }
        )
    }
}

enum ServiceFileURLNormalization {
    static func lexical(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        var components: [String] = []
        for component in url.pathComponents {
            switch component {
            case "/", ".", "":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: url.hasDirectoryPath
        )
    }
}

public protocol FileProviderIdentifierLookingUp: Sendable {
    func status(forExistingURL url: URL) async -> FileProviderStatus
}

/// Read-only adapter over Apple's supported user-visible-file identifier lookup.
/// It neither asks a provider to materialize content nor sets File Provider state.
public struct SystemFileProviderIdentifierLookup: FileProviderIdentifierLookingUp {
    public init() {}

    public func status(forExistingURL url: URL) async -> FileProviderStatus {
        await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                itemIdentifier,
                domainIdentifier,
                error in
                continuation.resume(
                    returning: Self.classify(
                        hasItemIdentifier: itemIdentifier != nil,
                        domainIdentifier: domainIdentifier.map { String(describing: $0) },
                        error: error
                    )
                )
            }
        }
    }

    /// Apple's header documents `NSFileNoSuchFileError` as the result when a URL
    /// is not in a provider/domain (or has no provider identifier yet). No other
    /// failure is treated as proof that a location is unmanaged.
    static func classify(
        hasItemIdentifier: Bool,
        domainIdentifier: String?,
        error: (any Error)?
    ) -> FileProviderStatus {
        if let error {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileNoSuchFileError
            {
                return .notManaged
            }
            return .uncertain(
                reason: "File Provider lookup failed (\(cocoaError.domain):\(cocoaError.code))"
            )
        }

        guard hasItemIdentifier else {
            return .uncertain(reason: "File Provider lookup returned no identifier and no error")
        }
        return .managed(providerIdentifier: domainIdentifier)
    }
}

public struct MacOSLocationAdmission: MacOSLocationAdmissionChecking {
    private let resources: any MacOSLocationResourceReading
    private let fileProvider: any FileProviderIdentifierLookingUp

    public init(
        resources: any MacOSLocationResourceReading = FoundationMacOSLocationResourceReader(),
        fileProvider: any FileProviderIdentifierLookingUp = SystemFileProviderIdentifierLookup()
    ) {
        self.resources = resources
        self.fileProvider = fileProvider
    }

    public func observation(for url: URL) async throws -> LocationObservation {
        let snapshot = try resources.snapshot(for: url)
        let providerStatus = await fileProvider.status(forExistingURL: snapshot.inspectedURL)
        return LocationObservation(
            isLocalVolume: snapshot.isLocalVolume,
            isReadOnlyVolume: snapshot.isReadOnlyVolume,
            isUbiquitousItem: snapshot.isUbiquitousItem,
            fileProviderStatus: providerStatus,
            volumeIdentifier: snapshot.volumeIdentifier
        )
    }
}

/// Narrow physical-Mac fallback for the three fixed app-owned preview roots.
///
/// On the current unsigned preview, File Provider's supported identifier API
/// can fail with Cocoa 4099 because its XPC service is unavailable even for
/// ordinary local Application Support, Caches, and system-temporary ancestry.
/// That absence is not generally proof that an arbitrary user path is safe.
/// This adapter therefore accepts only the exact paths derived by
/// `PreviewStorageLayout`, only on a writable non-ubiquitous local volume, and
/// only for that one observed service-unavailable result. The subsequent POSIX
/// bootstrap still rejects every symlink or changed ancestor before writing.
public struct PreviewAppOwnedLocationAdmission: MacOSLocationAdmissionChecking {
    private static let unavailableProviderServiceReason =
        "File Provider lookup failed (NSCocoaErrorDomain:4099)"

    private let layout: PreviewStorageLayout
    private let base: any MacOSLocationAdmissionChecking

    public init(
        layout: PreviewStorageLayout,
        base: any MacOSLocationAdmissionChecking = MacOSLocationAdmission()
    ) {
        self.layout = layout
        self.base = base
    }

    public func observation(for url: URL) async throws -> LocationObservation {
        let observation = try await base.observation(for: url)
        guard
            Self.isExactAppOwnedBoundary(url, layout: layout),
            observation.isLocalVolume,
            !observation.isReadOnlyVolume,
            !observation.isUbiquitousItem,
            case let .uncertain(reason) = observation.fileProviderStatus,
            reason == Self.unavailableProviderServiceReason
        else { return observation }

        return LocationObservation(
            isLocalVolume: observation.isLocalVolume,
            isReadOnlyVolume: observation.isReadOnlyVolume,
            isUbiquitousItem: observation.isUbiquitousItem,
            fileProviderStatus: .notManaged,
            volumeIdentifier: observation.volumeIdentifier
        )
    }

    private static func isExactAppOwnedBoundary(
        _ url: URL,
        layout: PreviewStorageLayout
    ) -> Bool {
        let exact = ServiceFileURLNormalization.lexical(url)
        return [
            layout.highChurnRoot,
            layout.cacheRoot.url,
            layout.temporaryRoot.url
        ].map(ServiceFileURLNormalization.lexical).contains(exact)
    }
}
