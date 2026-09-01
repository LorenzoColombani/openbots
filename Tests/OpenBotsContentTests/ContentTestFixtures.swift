import Foundation
@testable import OpenBotsContent

struct StaticLocationChecker: LocationEnvironmentChecking {
    let value: LocationObservation

    func observation(for url: URL) throws -> LocationObservation { value }
}

let safeLocalObservation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "test-volume"
)

final class ContentTemporaryFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let systemTemporary: URL
    let layout: PreviewStorageLayout

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextContentTests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        home = root.appending(path: "Home", directoryHint: .isDirectory)
        systemTemporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: systemTemporary)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemTemporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    deinit {
        let path = root.path
        guard path.hasPrefix("/private/tmp/OpenBotsNextContentTests-"), path.hasSuffix(".noindex") else {
            return
        }
        try? FileManager.default.removeItem(at: root)
    }

    func materializeOwnedRoot(
        _ descriptor: OwnedRootDescriptor,
        installationID: UUID,
        rootID: UUID
    ) throws {
        try FileManager.default.createDirectory(at: descriptor.url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: descriptor.url.path)
        let marker = OwnedRootMarker(
            installationID: installationID,
            rootID: rootID,
            kind: descriptor.kind
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: descriptor.ownershipMarkerURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: descriptor.ownershipMarkerURL.path
        )
    }
}
