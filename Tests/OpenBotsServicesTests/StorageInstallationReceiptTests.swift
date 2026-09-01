import Darwin
import Foundation
import OpenBotsContent
import OpenBotsPersistence
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private let installationReceiptAdmittedLocation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "installation-receipt-test-volume"
)

private struct InstallationReceiptAdmission: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        installationReceiptAdmittedLocation
    }
}

private enum ReceiptIdentityMismatch: CaseIterable, Sendable {
    case installationID
    case applicationSupportRootID
}

private final class StorageInstallationReceiptFixture: @unchecked Sendable {
    let scratchRoot: URL
    let layout: PreviewStorageLayout
    let installationID = UUID()
    let rootIDs: [OwnedRootKind: UUID] = [
        .applicationSupport: UUID(),
        .caches: UUID(),
        .temporary: UUID()
    ]

    init() throws {
        scratchRoot = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextInstallationReceiptTests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = scratchRoot.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = scratchRoot.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scratchRoot.path
        )
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
    }

    deinit {
        let path = scratchRoot.path
        guard path.hasPrefix("/private/tmp/OpenBotsNextInstallationReceiptTests-"),
              path.hasSuffix(".noindex")
        else { return }
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    func plan() throws -> PreviewRootCreationPlan {
        try PreviewRootCreationPlan(
            layout: layout,
            installationID: installationID,
            rootIDs: rootIDs
        )
    }

    func receipt(
        installationID: UUID? = nil,
        rootIDs: [OwnedRootKind: UUID]? = nil
    ) throws -> StorageInstallationReceipt {
        try StorageInstallationReceipt(
            installationID: installationID ?? self.installationID,
            rootIDs: rootIDs ?? self.rootIDs,
            protectionSelection: .ordinarySQLite,
            protectionDecision: ProtectionDecisionReceipt(
                decisionID: UUID(uuidString: "88000000-0000-0000-0000-000000000001")!,
                selectedAt: Date(timeIntervalSince1970: 880),
                rationaleVersion: 1
            )
        )
    }

    func bootstrap() async throws -> StorageBootstrapReceipt {
        try await StorageBootstrapService(
            layout: layout,
            locationAdmission: InstallationReceiptAdmission()
        ).bootstrap(using: plan())
    }

    func writeFinal(_ data: Data, mode: UInt16 = 0o600) throws {
        try data.write(to: layout.installationReceiptURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: layout.installationReceiptURL.path
        )
    }

    func stagingItems() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: layout.applicationSupportRoot.url.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: layout.applicationSupportRoot.url,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".openbots-installation.staging-") }
    }
}

@Test("Installation receipt and store construction are side-effect free")
func installationReceiptConstructionIsInert() throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try fixture.receipt()
    _ = POSIXStorageInstallationReceiptStore()

    #expect(!FileManager.default.fileExists(atPath: fixture.layout.applicationSupportRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.installationReceiptURL.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("Receipt derives exactly the three internal roots and the canonical fixed URL")
func installationReceiptDerivesExactAuthority() throws {
    let fixture = try StorageInstallationReceiptFixture()
    let receipt = try fixture.receipt()

    #expect(receipt.installationID == fixture.installationID)
    #expect(receipt.rootIDs == fixture.rootIDs)
    #expect(receipt.roots.map(\.kind) == [.applicationSupport, .caches, .temporary])
    #expect(receipt.rootID(for: .visibleContent) == nil)
    #expect(
        StorageInstallationReceipt.fileURL(in: fixture.layout.applicationSupportRoot)
            == fixture.layout.installationReceiptURL
    )
    #expect(
        fixture.layout.installationReceiptURL
            == fixture.layout.applicationSupportRoot.url.appending(
                path: PreviewStorageLayout.installationReceiptFileName,
                directoryHint: .notDirectory
            )
    )
}

@Test("Receipt publication is exclusive, protected, durable, and readable")
func installationReceiptPublishesAndReadsBack() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    let receipt = try fixture.receipt()
    let store = POSIXStorageInstallationReceiptStore()

    try store.create(receipt, in: fixture.layout.applicationSupportRoot)

    let attributes = try FileManager.default.attributesOfItem(
        atPath: fixture.layout.installationReceiptURL.path
    )
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(mode.uint16Value & 0o777 == 0o600)
    #expect(try store.read(from: fixture.layout.applicationSupportRoot) == receipt)
    #expect(try fixture.stagingItems().isEmpty)

    let canonicalRoot = try PathSafety().canonicalExistingDirectory(
        fixture.layout.applicationSupportRoot.url
    )
    let canonicalReceipt = try PathSafety().canonicalExistingItem(
        fixture.layout.installationReceiptURL,
        containedIn: canonicalRoot
    )
    #expect(canonicalReceipt.url == fixture.layout.installationReceiptURL)
}

@Test("An existing final receipt is never replaced or merged")
func installationReceiptCollisionPreservesExistingItem() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    let sentinel = Data("existing receipt sentinel".utf8)
    try fixture.writeFinal(sentinel)
    let store = POSIXStorageInstallationReceiptStore()

    #expect(throws: StorageInstallationReceiptError.receiptAlreadyExists) {
        try store.create(try fixture.receipt(), in: fixture.layout.applicationSupportRoot)
    }

    #expect(try Data(contentsOf: fixture.layout.installationReceiptURL) == sentinel)
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("A final symlink is rejected without reading or changing its target")
func installationReceiptRejectsFinalSymlink() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    let outside = fixture.scratchRoot.appending(path: "outside-sentinel", directoryHint: .notDirectory)
    let sentinel = Data("do not follow".utf8)
    try sentinel.write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: fixture.layout.installationReceiptURL,
        withDestinationURL: outside
    )

    #expect(throws: StorageInstallationReceiptError.receiptIsNotRegularFile) {
        try POSIXStorageInstallationReceiptStore().read(
            from: fixture.layout.applicationSupportRoot
        )
    }
    #expect(try Data(contentsOf: outside) == sentinel)
}

@Test("A non-regular final item is rejected without traversal")
func installationReceiptRejectsSpecialFinalItem() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    try FileManager.default.createDirectory(
        at: fixture.layout.installationReceiptURL,
        withIntermediateDirectories: false
    )

    #expect(throws: StorageInstallationReceiptError.receiptIsNotRegularFile) {
        try POSIXStorageInstallationReceiptStore().read(
            from: fixture.layout.applicationSupportRoot
        )
    }
}

@Test("Corrupt receipt data fails closed")
func installationReceiptRejectsCorruptData() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    try fixture.writeFinal(Data("{not valid json".utf8))

    #expect(throws: StorageInstallationReceiptError.receiptDecodingFailed) {
        try POSIXStorageInstallationReceiptStore().read(
            from: fixture.layout.applicationSupportRoot
        )
    }
}

@Test("Oversized receipt data is rejected before decoding")
func installationReceiptRejectsOversizedData() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    try fixture.writeFinal(
        Data(repeating: 0x41, count: POSIXStorageInstallationReceiptStore.maximumReceiptBytes + 1)
    )

    #expect(
        throws: StorageInstallationReceiptError.receiptTooLarge(
            maximumBytes: POSIXStorageInstallationReceiptStore.maximumReceiptBytes
        )
    ) {
        try POSIXStorageInstallationReceiptStore().read(
            from: fixture.layout.applicationSupportRoot
        )
    }
}

@Test("Unsafe receipt permissions are rejected")
func installationReceiptRejectsWrongPermissions() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    try fixture.writeFinal(try JSONEncoder().encode(fixture.receipt()), mode: 0o644)

    #expect(throws: StorageInstallationReceiptError.receiptPermissionsUnsafe(actual: 0o644)) {
        try POSIXStorageInstallationReceiptStore().read(
            from: fixture.layout.applicationSupportRoot
        )
    }
}

@Test(
    "Receipt identity must match the verified application-support marker",
    arguments: ReceiptIdentityMismatch.allCases
)
private func installationReceiptRejectsMarkerIdentityMismatch(
    mismatch: ReceiptIdentityMismatch
) async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    var receiptInstallationID = fixture.installationID
    var receiptRootIDs = fixture.rootIDs
    switch mismatch {
    case .installationID:
        receiptInstallationID = UUID()
    case .applicationSupportRootID:
        receiptRootIDs[.applicationSupport] = UUID()
    }
    let mismatched = try fixture.receipt(
        installationID: receiptInstallationID,
        rootIDs: receiptRootIDs
    )

    #expect(throws: StorageInstallationReceiptError.rootVerificationFailed(.markerMismatch)) {
        try POSIXStorageInstallationReceiptStore().create(
            mismatched,
            in: fixture.layout.applicationSupportRoot
        )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.installationReceiptURL.path))
    #expect(try fixture.stagingItems().isEmpty)
}

@Test("A crash-left staging file is never read as authority or promoted implicitly")
func installationReceiptIgnoresCrashLeftStaging() async throws {
    let fixture = try StorageInstallationReceiptFixture()
    _ = try await fixture.bootstrap()
    let receipt = try fixture.receipt()
    let staleStaging = fixture.layout.applicationSupportRoot.url.appending(
        path: ".openbots-installation.staging-crash-left",
        directoryHint: .notDirectory
    )
    let staleData = try JSONEncoder().encode(receipt)
    try staleData.write(to: staleStaging, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: staleStaging.path
    )
    let store = POSIXStorageInstallationReceiptStore()

    #expect(throws: StorageInstallationReceiptError.receiptMissing) {
        try store.read(from: fixture.layout.applicationSupportRoot)
    }

    try store.create(receipt, in: fixture.layout.applicationSupportRoot)
    #expect(try store.read(from: fixture.layout.applicationSupportRoot) == receipt)
    #expect(try Data(contentsOf: staleStaging) == staleData)
    #expect(try fixture.stagingItems() == [staleStaging])
}
