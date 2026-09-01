import Foundation
import OpenBotsContent
import Testing
@testable import OpenBotsServices

private let admittedLocalLocation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "storage-test-volume"
)

private struct FixedAdmission: MacOSLocationAdmissionChecking {
    let value: LocationObservation
    func observation(for url: URL) async throws -> LocationObservation { value }
}

private struct InjectedStageFailure: Error {}

private struct InjectedRecoveryPreflightFailure: Error {}
private struct InjectedRecoveryPublicationFailure: Error {}
private struct UnexpectedRecoveryFileSystemCall: Error {}

private struct FailOnCacheStageFileSystem: StorageBootstrapFileSystem {
    let base = POSIXStorageBootstrapFileSystem()

    func preflight(_ specification: StorageRootSpecification) throws {
        try base.preflight(specification)
    }

    func stage(_ specification: StorageRootSpecification) throws -> StagedStorageRoot {
        if specification.descriptor.kind == .caches { throw InjectedStageFailure() }
        return try base.stage(specification)
    }

    func publish(_ stagedRoot: StagedStorageRoot) throws { try base.publish(stagedRoot) }
    func discard(_ stagedRoot: StagedStorageRoot) throws { try base.discard(stagedRoot) }
}

private struct FailOnTemporaryRecoveryPreflightFileSystem: StorageBootstrapFileSystem {
    let base = POSIXStorageBootstrapFileSystem()

    func preflight(_ specification: StorageRootSpecification) throws {
        if specification.descriptor.kind == .temporary {
            throw InjectedRecoveryPreflightFailure()
        }
        try base.preflight(specification)
    }

    func stage(_ specification: StorageRootSpecification) throws -> StagedStorageRoot {
        try base.stage(specification)
    }

    func publish(_ stagedRoot: StagedStorageRoot) throws { try base.publish(stagedRoot) }
    func discard(_ stagedRoot: StagedStorageRoot) throws { try base.discard(stagedRoot) }
}

private struct FailOnTemporaryRecoveryPublicationFileSystem: StorageBootstrapFileSystem {
    let base = POSIXStorageBootstrapFileSystem()

    func preflight(_ specification: StorageRootSpecification) throws {
        try base.preflight(specification)
    }

    func stage(_ specification: StorageRootSpecification) throws -> StagedStorageRoot {
        try base.stage(specification)
    }

    func publish(_ stagedRoot: StagedStorageRoot) throws {
        if stagedRoot.kind == .temporary {
            throw InjectedRecoveryPublicationFailure()
        }
        try base.publish(stagedRoot)
    }

    func discard(_ stagedRoot: StagedStorageRoot) throws { try base.discard(stagedRoot) }
}

private struct MutationForbiddenRecoveryFileSystem: StorageBootstrapFileSystem {
    func preflight(_ specification: StorageRootSpecification) throws {
        throw UnexpectedRecoveryFileSystemCall()
    }

    func stage(_ specification: StorageRootSpecification) throws -> StagedStorageRoot {
        throw UnexpectedRecoveryFileSystemCall()
    }

    func publish(_ stagedRoot: StagedStorageRoot) throws {
        throw UnexpectedRecoveryFileSystemCall()
    }

    func discard(_ stagedRoot: StagedStorageRoot) throws {
        throw UnexpectedRecoveryFileSystemCall()
    }
}

private final class StorageBootstrapFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let temporary: URL
    let layout: PreviewStorageLayout

    init(useSymlinkedHome: Bool = false) throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextStorageServiceTests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        let realHome = root.appending(path: "RealHome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: realHome
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: realHome
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        if useSymlinkedHome {
            home = root.appending(path: "LinkedHome", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: home, withDestinationURL: realHome)
        } else {
            home = realHome
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    deinit {
        let path = root.path
        guard path.hasPrefix("/private/tmp/OpenBotsNextStorageServiceTests-"),
              path.hasSuffix(".noindex")
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func plan() throws -> PreviewRootCreationPlan {
        try PreviewRootCreationPlan(
            layout: layout,
            installationID: UUID(),
            rootIDs: [
                .applicationSupport: UUID(),
                .caches: UUID(),
                .temporary: UUID()
            ]
        )
    }

    func descriptor(for kind: OwnedRootKind) -> OwnedRootDescriptor {
        switch kind {
        case .applicationSupport:
            layout.applicationSupportRoot
        case .caches:
            layout.cacheRoot
        case .temporary:
            layout.temporaryRoot
        case .visibleContent:
            layout.contentRoot
        }
    }

    func removeRoot(_ kind: OwnedRootKind) throws {
        try FileManager.default.removeItem(at: descriptor(for: kind).url)
    }

    func markerData(for kind: OwnedRootKind) throws -> Data {
        try Data(contentsOf: descriptor(for: kind).ownershipMarkerURL)
    }

    func tamperMarker(for kind: OwnedRootKind, plan: PreviewRootCreationPlan) throws -> Data {
        let marker = OwnedRootMarker(
            installationID: plan.installationID,
            rootID: UUID(),
            kind: kind
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: descriptor(for: kind).ownershipMarkerURL)
        return data
    }

    func stagingItems() throws -> [URL] {
        let parents = [
            layout.applicationSupportRoot.url.deletingLastPathComponent(),
            layout.cacheRoot.url.deletingLastPathComponent(),
            layout.temporaryRoot.url.deletingLastPathComponent()
        ]
        return try parents.flatMap { parent in
            try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".openbots-bootstrap-") }
        }
    }
}

private func makeBootstrapService(
    fixture: StorageBootstrapFixture,
    admission: LocationObservation = admittedLocalLocation,
    fileSystem: any StorageBootstrapFileSystem = POSIXStorageBootstrapFileSystem()
) -> StorageBootstrapService {
    StorageBootstrapService(
        layout: fixture.layout,
        locationAdmission: FixedAdmission(value: admission),
        fileSystem: fileSystem
    )
}

private func receiptRootIDs(_ receipt: StorageBootstrapReceipt) -> [OwnedRootKind: UUID] {
    Dictionary(uniqueKeysWithValues: receipt.verifiedRoots.map { ($0.kind, $0.rootID) })
}

@Test("Internal bootstrap atomically publishes marker-owned roots and nothing user-visible or authenticated")
func bootstrapInternalRoots() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = StorageBootstrapService(
        layout: fixture.layout,
        locationAdmission: FixedAdmission(value: admittedLocalLocation)
    )

    let receipt = try await service.bootstrap(using: plan)

    #expect(receipt.installationID == plan.installationID)
    #expect(Set(receipt.verifiedRoots.map(\.kind)) == Set([.applicationSupport, .caches, .temporary]))
    for root in receipt.verifiedRoots {
        let rootMode = try #require(
            FileManager.default.attributesOfItem(atPath: root.url.path)[.posixPermissions] as? NSNumber
        )
        let markerMode = try #require(
            FileManager.default.attributesOfItem(
                atPath: root.url.appending(path: ".openbots-root.json").path
            )[.posixPermissions] as? NSNumber
        )
        #expect(rootMode.uint16Value & 0o777 == 0o700)
        #expect(markerMode.uint16Value & 0o777 == 0o600)
    }
    for directory in fixture.layout.internalRequiredDirectoryURLs {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeCLIProfileRoot.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("A pre-existing destination is never merged, replaced, or followed")
func bootstrapRejectsCollisionWithoutMerge() async throws {
    let fixture = try StorageBootstrapFixture()
    let sentinel = fixture.layout.applicationSupportRoot.url.appending(path: "sentinel.txt")
    try FileManager.default.createDirectory(
        at: fixture.layout.applicationSupportRoot.url,
        withIntermediateDirectories: false
    )
    try Data("keep".utf8).write(to: sentinel)
    let service = StorageBootstrapService(
        layout: fixture.layout,
        locationAdmission: FixedAdmission(value: admittedLocalLocation)
    )

    do {
        _ = try await service.bootstrap(using: fixture.plan())
        Issue.record("Expected collision to fail closed")
    } catch let error as StorageBootstrapError {
        guard case .filesystemPreflightFailed(kind: .applicationSupport, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.cacheRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("A symlink in an internal root path is rejected before any write")
func bootstrapRejectsSymlinkedParent() async throws {
    let fixture = try StorageBootstrapFixture(useSymlinkedHome: true)
    let service = StorageBootstrapService(
        layout: fixture.layout,
        locationAdmission: FixedAdmission(value: admittedLocalLocation)
    )

    do {
        _ = try await service.bootstrap(using: fixture.plan())
        Issue.record("Expected symlinked ancestry to fail closed")
    } catch let error as StorageBootstrapError {
        guard case .filesystemPreflightFailed(kind: .applicationSupport, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.applicationSupportRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("A staging failure rolls back only call-owned staging and publishes no partial roots")
func bootstrapRollsBackStagingFailure() async throws {
    let fixture = try StorageBootstrapFixture()
    let service = StorageBootstrapService(
        layout: fixture.layout,
        locationAdmission: FixedAdmission(value: admittedLocalLocation),
        fileSystem: FailOnCacheStageFileSystem()
    )

    do {
        _ = try await service.bootstrap(using: fixture.plan())
        Issue.record("Expected injected staging failure")
    } catch let error as StorageBootstrapError {
        guard case .stagingFailed(kind: .caches, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.applicationSupportRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.cacheRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test(
    "Managed or uncertain high-churn placement is rejected before filesystem writes",
    arguments: [
        FileProviderStatus.managed(providerIdentifier: "provider"),
        FileProviderStatus.uncertain(reason: "lookup unavailable")
    ]
)
func bootstrapRejectsUnsafeProviderStatus(status: FileProviderStatus) async throws {
    let fixture = try StorageBootstrapFixture()
    let observation = LocationObservation(
        isLocalVolume: true,
        isReadOnlyVolume: false,
        isUbiquitousItem: false,
        fileProviderStatus: status,
        volumeIdentifier: "storage-test-volume"
    )
    let service = StorageBootstrapService(
        layout: fixture.layout,
        locationAdmission: FixedAdmission(value: observation)
    )

    do {
        _ = try await service.bootstrap(using: fixture.plan())
        Issue.record("Expected unsafe provider status to fail closed")
    } catch let error as StorageBootstrapError {
        guard case .unsafeHighChurnLocation(kind: .applicationSupport, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.applicationSupportRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery recreates a missing temporary root with its original installation identity")
func recoveryRecreatesMissingTemporaryRoot() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = makeBootstrapService(fixture: fixture)
    _ = try await service.bootstrap(using: plan)
    try fixture.removeRoot(.temporary)

    let receipt = try await service.recoverMissingDisposableRoots(using: plan)

    #expect(receipt.installationID == plan.installationID)
    #expect(receiptRootIDs(receipt) == plan.rootIDs)
    #expect(
        receipt.verifiedRoots.first(where: { $0.kind == .temporary })?.rootID
            == plan.rootIDs[.temporary]
    )
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery recreates a missing cache root with its original installation identity")
func recoveryRecreatesMissingCacheRoot() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = makeBootstrapService(fixture: fixture)
    _ = try await service.bootstrap(using: plan)
    try fixture.removeRoot(.caches)

    let receipt = try await service.recoverMissingDisposableRoots(using: plan)

    #expect(receipt.installationID == plan.installationID)
    #expect(receiptRootIDs(receipt) == plan.rootIDs)
    #expect(
        receipt.verifiedRoots.first(where: { $0.kind == .caches })?.rootID
            == plan.rootIDs[.caches]
    )
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery recreates both missing disposable roots and preserves every original identity")
func recoveryRecreatesBothDisposableRoots() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = makeBootstrapService(fixture: fixture)
    _ = try await service.bootstrap(using: plan)
    try fixture.removeRoot(.caches)
    try fixture.removeRoot(.temporary)

    let receipt = try await service.recoverMissingDisposableRoots(using: plan)

    #expect(receipt.installationID == plan.installationID)
    #expect(receiptRootIDs(receipt) == plan.rootIDs)
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery is inert when all three roots already verify")
func recoveryIsInertWhenRootsAlreadyVerify() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    _ = try await makeBootstrapService(fixture: fixture).bootstrap(using: plan)
    let service = makeBootstrapService(
        fixture: fixture,
        fileSystem: MutationForbiddenRecoveryFileSystem()
    )

    let receipt = try await service.recoverMissingDisposableRoots(using: plan)

    #expect(receiptRootIDs(receipt) == plan.rootIDs)
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery never recreates a missing Application Support authority root")
func recoveryRejectsMissingApplicationSupport() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = makeBootstrapService(fixture: fixture)
    _ = try await service.bootstrap(using: plan)
    let cacheMarker = try fixture.markerData(for: .caches)
    let temporaryMarker = try fixture.markerData(for: .temporary)
    try fixture.removeRoot(.applicationSupport)

    do {
        _ = try await service.recoverMissingDisposableRoots(using: plan)
        Issue.record("Expected missing Application Support to fail closed")
    } catch let error as StorageBootstrapError {
        guard case .verificationFailed(kind: .applicationSupport, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.layout.applicationSupportRoot.url.path))
    #expect(try fixture.markerData(for: .caches) == cacheMarker)
    #expect(try fixture.markerData(for: .temporary) == temporaryMarker)
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery refuses tampered Application Support without changing any root")
func recoveryRejectsTamperedApplicationSupport() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = makeBootstrapService(fixture: fixture)
    _ = try await service.bootstrap(using: plan)
    let cacheMarker = try fixture.markerData(for: .caches)
    let temporaryMarker = try fixture.markerData(for: .temporary)
    let tamperedMarker = try fixture.tamperMarker(for: .applicationSupport, plan: plan)

    do {
        _ = try await service.recoverMissingDisposableRoots(using: plan)
        Issue.record("Expected tampered Application Support to fail closed")
    } catch let error as StorageBootstrapError {
        guard case .verificationFailed(kind: .applicationSupport, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    #expect(try fixture.markerData(for: .applicationSupport) == tamperedMarker)
    #expect(try fixture.markerData(for: .caches) == cacheMarker)
    #expect(try fixture.markerData(for: .temporary) == temporaryMarker)
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery refuses an existing tampered disposable root and does not recover another missing root")
func recoveryRejectsTamperedDisposableWithoutReplacement() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    let service = makeBootstrapService(fixture: fixture)
    _ = try await service.bootstrap(using: plan)
    let tamperedMarker = try fixture.tamperMarker(for: .caches, plan: plan)
    try fixture.removeRoot(.temporary)

    do {
        _ = try await service.recoverMissingDisposableRoots(using: plan)
        Issue.record("Expected the tampered cache root to fail closed")
    } catch let error as StorageBootstrapError {
        guard case .verificationFailed(kind: .caches, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    #expect(try fixture.markerData(for: .caches) == tamperedMarker)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery plan validation fails before any missing root is recreated")
func recoveryValidationFailureDoesNotMutate() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    _ = try await makeBootstrapService(fixture: fixture).bootstrap(using: plan)
    try fixture.removeRoot(.caches)
    try fixture.removeRoot(.temporary)
    let foreignFixture = try StorageBootstrapFixture()
    let foreignPlan = try foreignFixture.plan()

    do {
        _ = try await makeBootstrapService(fixture: fixture)
            .recoverMissingDisposableRoots(using: foreignPlan)
        Issue.record("Expected mismatched plan validation to fail")
    } catch let error as StorageBootstrapError {
        #expect(error == .invalidPlan)
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.layout.cacheRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery admission failure occurs before any missing root is recreated")
func recoveryAdmissionFailureDoesNotMutate() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    _ = try await makeBootstrapService(fixture: fixture).bootstrap(using: plan)
    try fixture.removeRoot(.caches)
    try fixture.removeRoot(.temporary)
    let deniedObservation = LocationObservation(
        isLocalVolume: true,
        isReadOnlyVolume: false,
        isUbiquitousItem: false,
        fileProviderStatus: .managed(providerIdentifier: "provider"),
        volumeIdentifier: "storage-test-volume"
    )

    do {
        _ = try await makeBootstrapService(fixture: fixture, admission: deniedObservation)
            .recoverMissingDisposableRoots(using: plan)
        Issue.record("Expected unsafe admission to fail")
    } catch let error as StorageBootstrapError {
        guard case .unsafeHighChurnLocation(kind: .applicationSupport, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.layout.cacheRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery preflights every missing root before creating any staging state")
func recoveryPreflightFailureDoesNotMutate() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    _ = try await makeBootstrapService(fixture: fixture).bootstrap(using: plan)
    try fixture.removeRoot(.caches)
    try fixture.removeRoot(.temporary)
    let service = makeBootstrapService(
        fixture: fixture,
        fileSystem: FailOnTemporaryRecoveryPreflightFileSystem()
    )

    do {
        _ = try await service.recoverMissingDisposableRoots(using: plan)
        Issue.record("Expected injected preflight failure")
    } catch let error as StorageBootstrapError {
        guard case .filesystemPreflightFailed(kind: .temporary, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.layout.cacheRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Recovery preserves partial publication evidence and a retry finishes the same installation")
func recoveryRetryAfterPartialPublication() async throws {
    let fixture = try StorageBootstrapFixture()
    let plan = try fixture.plan()
    _ = try await makeBootstrapService(fixture: fixture).bootstrap(using: plan)
    let evidenceURL = fixture.layout.applicationSupportRoot.url.appending(path: "immutable-receipt-evidence")
    let evidence = Data("preserve".utf8)
    try evidence.write(to: evidenceURL)
    try fixture.removeRoot(.caches)
    try fixture.removeRoot(.temporary)
    let failingService = makeBootstrapService(
        fixture: fixture,
        fileSystem: FailOnTemporaryRecoveryPublicationFileSystem()
    )

    do {
        _ = try await failingService.recoverMissingDisposableRoots(using: plan)
        Issue.record("Expected injected publication failure")
    } catch let error as StorageBootstrapError {
        guard case let .publicationFailed(failedKind, publishedRoots, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(failedKind == .temporary)
        #expect(publishedRoots == [fixture.layout.cacheRoot.url])
    }

    #expect(FileManager.default.fileExists(atPath: fixture.layout.cacheRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.temporaryRoot.url.path))
    #expect(try Data(contentsOf: evidenceURL) == evidence)
    #expect(try fixture.stagingItems().isEmpty)

    let receipt = try await makeBootstrapService(fixture: fixture)
        .recoverMissingDisposableRoots(using: plan)

    #expect(receipt.installationID == plan.installationID)
    #expect(receiptRootIDs(receipt) == plan.rootIDs)
    #expect(try Data(contentsOf: evidenceURL) == evidence)
    #expect(try fixture.stagingItems().isEmpty)
}
