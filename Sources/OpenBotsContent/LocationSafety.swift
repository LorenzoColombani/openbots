import Foundation

public enum FileProviderStatus: Hashable, Sendable {
    case notManaged
    case managed(providerIdentifier: String?)
    case uncertain(reason: String)
}

public struct LocationObservation: Hashable, Sendable {
    public let isLocalVolume: Bool
    public let isReadOnlyVolume: Bool
    public let isUbiquitousItem: Bool
    public let fileProviderStatus: FileProviderStatus
    public let volumeIdentifier: String?

    public init(
        isLocalVolume: Bool,
        isReadOnlyVolume: Bool,
        isUbiquitousItem: Bool,
        fileProviderStatus: FileProviderStatus,
        volumeIdentifier: String? = nil
    ) {
        self.isLocalVolume = isLocalVolume
        self.isReadOnlyVolume = isReadOnlyVolume
        self.isUbiquitousItem = isUbiquitousItem
        self.fileProviderStatus = fileProviderStatus
        self.volumeIdentifier = volumeIdentifier
    }
}

public protocol LocationEnvironmentChecking: Sendable {
    func observation(for url: URL) throws -> LocationObservation
}

public protocol FileProviderLocationDetecting: Sendable {
    func status(for url: URL) -> FileProviderStatus
}

/// A conservative, read-only ancestry detector. It can positively identify common
/// managed ancestors, but absence of those names is not proof that an arbitrary URL
/// is unmanaged. A supported File Provider lookup adapter must supply that proof.
public struct KnownFileProviderAncestryDetector: FileProviderLocationDetecting {
    public init() {}

    public func status(for url: URL) -> FileProviderStatus {
        let components = FileURLNormalization.lexical(url).pathComponents
        if containsSubsequence(["Library", "Mobile Documents"], in: components) {
            return .managed(providerIdentifier: "iCloud Drive")
        }
        if containsSubsequence(["Library", "CloudStorage"], in: components) {
            return .managed(providerIdentifier: nil)
        }
        return .uncertain(reason: "No supported File Provider ownership lookup was performed")
    }

    private func containsSubsequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}

public struct FoundationLocationEnvironmentChecker: LocationEnvironmentChecking {
    private let providerDetector: any FileProviderLocationDetecting

    public init(providerDetector: any FileProviderLocationDetecting = KnownFileProviderAncestryDetector()) {
        self.providerDetector = providerDetector
    }

    public func observation(for url: URL) throws -> LocationObservation {
        let inspectedURL = nearestExistingAncestor(of: FileURLNormalization.lexical(url))
        let values = try inspectedURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIdentifierKey
        ])
        return LocationObservation(
            isLocalVolume: values.volumeIsLocal ?? false,
            isReadOnlyVolume: values.volumeIsReadOnly ?? true,
            isUbiquitousItem: values.isUbiquitousItem ?? false,
            fileProviderStatus: providerDetector.status(for: inspectedURL),
            volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) }
        )
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}

public enum HighChurnLocationViolation: Error, Equatable, Sendable {
    case missingNoIndexBoundary
    case nonLocalVolume
    case readOnlyVolume
    case ubiquitousItem
    case fileProviderManaged
    case fileProviderUnknown
}

public struct HighChurnLocationValidator: Sendable {
    public init() {}

    public func validate(_ url: URL, observation: LocationObservation) throws {
        guard FileURLNormalization.lexical(url).pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            throw HighChurnLocationViolation.missingNoIndexBoundary
        }
        guard observation.isLocalVolume else { throw HighChurnLocationViolation.nonLocalVolume }
        guard !observation.isReadOnlyVolume else { throw HighChurnLocationViolation.readOnlyVolume }
        guard !observation.isUbiquitousItem else { throw HighChurnLocationViolation.ubiquitousItem }
        switch observation.fileProviderStatus {
        case .notManaged:
            return
        case .managed:
            throw HighChurnLocationViolation.fileProviderManaged
        case .uncertain:
            throw HighChurnLocationViolation.fileProviderUnknown
        }
    }
}
