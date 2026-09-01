import Foundation
import OpenBotsContent
import Testing
@testable import OpenBotsServices

private struct StubLocationResources: MacOSLocationResourceReading {
    let snapshotValue: MacOSLocationResourceSnapshot

    func snapshot(for url: URL) throws -> MacOSLocationResourceSnapshot { snapshotValue }
}

private actor LookupRecorder {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

private struct RecordingProviderLookup: FileProviderIdentifierLookingUp {
    let value: FileProviderStatus
    let recorder: LookupRecorder

    func status(forExistingURL url: URL) async -> FileProviderStatus {
        await recorder.append(url)
        return value
    }
}

private struct FixedMacOSAdmission: MacOSLocationAdmissionChecking {
    let observation: LocationObservation

    func observation(for url: URL) async throws -> LocationObservation { observation }
}

@Test("Only the documented Cocoa no-such-file result proves a URL is not provider managed")
func fileProviderNoSuchFileClassification() {
    let documented = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    #expect(
        SystemFileProviderIdentifierLookup.classify(
            hasItemIdentifier: false,
            domainIdentifier: nil,
            error: documented
        ) == .notManaged
    )

    let sameCodeWrongDomain = NSError(domain: "example.test", code: NSFileNoSuchFileError)
    guard case .uncertain = SystemFileProviderIdentifierLookup.classify(
        hasItemIdentifier: false,
        domainIdentifier: nil,
        error: sameCodeWrongDomain
    ) else {
        Issue.record("A non-Cocoa error must remain uncertain")
        return
    }

    let permissionFailure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    guard case .uncertain = SystemFileProviderIdentifierLookup.classify(
        hasItemIdentifier: false,
        domainIdentifier: nil,
        error: permissionFailure
    ) else {
        Issue.record("A permission error must remain uncertain")
        return
    }
}

@Test("A successful identifier lookup reports provider management")
func fileProviderManagedClassification() {
    #expect(
        SystemFileProviderIdentifierLookup.classify(
            hasItemIdentifier: true,
            domainIdentifier: "provider-domain",
            error: nil
        ) == .managed(providerIdentifier: "provider-domain")
    )
    guard case .uncertain = SystemFileProviderIdentifierLookup.classify(
        hasItemIdentifier: false,
        domainIdentifier: nil,
        error: nil
    ) else {
        Issue.record("An empty callback must remain uncertain")
        return
    }
}

@Test("Admission combines Foundation volume facts with File Provider ownership of the inspected ancestor")
func admissionCombinesPlatformEvidence() async throws {
    let requested = URL(fileURLWithPath: "/private/tmp/new-root.noindex/child")
    let inspected = URL(fileURLWithPath: "/private/tmp")
    let resources = StubLocationResources(
        snapshotValue: MacOSLocationResourceSnapshot(
            inspectedURL: inspected,
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            volumeIdentifier: "volume-test"
        )
    )
    let recorder = LookupRecorder()
    let admission = MacOSLocationAdmission(
        resources: resources,
        fileProvider: RecordingProviderLookup(
            value: .managed(providerIdentifier: "provider-test"),
            recorder: recorder
        )
    )

    let observation = try await admission.observation(for: requested)

    #expect(observation.isLocalVolume)
    #expect(!observation.isReadOnlyVolume)
    #expect(!observation.isUbiquitousItem)
    #expect(observation.fileProviderStatus == .managed(providerIdentifier: "provider-test"))
    #expect(observation.volumeIdentifier == "volume-test")
    #expect(await recorder.urls == [inspected])
}

@Test("Only exact fixed preview roots may recover from the observed unavailable provider service")
func fixedPreviewRootProviderFallbackIsNarrow() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/OpenBotsLocationFallbackTests", isDirectory: true)
    let layout = PreviewStorageLayout(
        homeDirectory: root.appending(path: "Home", directoryHint: .isDirectory),
        systemTemporaryDirectory: root.appending(path: "Temporary", directoryHint: .isDirectory)
    )
    let unavailable = LocationObservation(
        isLocalVolume: true,
        isReadOnlyVolume: false,
        isUbiquitousItem: false,
        fileProviderStatus: .uncertain(
            reason: "File Provider lookup failed (NSCocoaErrorDomain:4099)"
        ),
        volumeIdentifier: "local-volume"
    )
    let admission = PreviewAppOwnedLocationAdmission(
        layout: layout,
        base: FixedMacOSAdmission(observation: unavailable)
    )

    for exact in [layout.highChurnRoot, layout.cacheRoot.url, layout.temporaryRoot.url] {
        let recovered = try await admission.observation(for: exact)
        #expect(recovered.fileProviderStatus == .notManaged)
        #expect(recovered.volumeIdentifier == "local-volume")
    }

    let arbitrary = try await admission.observation(
        for: root.appending(path: "User Selected.noindex", directoryHint: .isDirectory)
    )
    #expect(arbitrary == unavailable)
}

@Test("Fixed-root fallback never hides provider ownership or a different uncertainty")
func fixedPreviewRootProviderFallbackPreservesUnsafeEvidence() async throws {
    let layout = PreviewStorageLayout(
        homeDirectory: URL(fileURLWithPath: "/private/tmp/Home", isDirectory: true),
        systemTemporaryDirectory: URL(fileURLWithPath: "/private/tmp/SystemTemporary", isDirectory: true)
    )
    let managed = LocationObservation(
        isLocalVolume: true,
        isReadOnlyVolume: false,
        isUbiquitousItem: false,
        fileProviderStatus: .managed(providerIdentifier: "provider")
    )
    let managedResult = try await PreviewAppOwnedLocationAdmission(
        layout: layout,
        base: FixedMacOSAdmission(observation: managed)
    ).observation(for: layout.highChurnRoot)
    #expect(managedResult == managed)

    let otherFailure = LocationObservation(
        isLocalVolume: true,
        isReadOnlyVolume: false,
        isUbiquitousItem: false,
        fileProviderStatus: .uncertain(reason: "permission denied")
    )
    let uncertainResult = try await PreviewAppOwnedLocationAdmission(
        layout: layout,
        base: FixedMacOSAdmission(observation: otherFailure)
    ).observation(for: layout.highChurnRoot)
    #expect(uncertainResult == otherFailure)
}
