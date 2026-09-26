import Darwin
import Foundation
import Testing
@testable import ClaudeRuntimeProbeCore

private struct PreviewProfileFixture {
    let root: URL
    let applicationSupport: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(
                path: "OpenBotsPreviewProfile-\(UUID().uuidString).noindex",
                directoryHint: .isDirectory
            )
        applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        try Self.createPrivateDirectory(root)
        try Self.createPrivateDirectory(applicationSupport)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}

private func permissions(at url: URL) -> mode_t? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return nil }
    return metadata.st_mode & 0o777
}

private func profileDirectory(in applicationSupport: URL) -> URL {
    applicationSupport
        .appending(
            path: ClaudeConfigurationPolicy.previewBundleIdentifier,
            directoryHint: .isDirectory
        )
        .appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
        .appending(path: "Runtime", directoryHint: .isDirectory)
        .appending(path: "Claude", directoryHint: .isDirectory)
        .appending(path: "CLIProfile", directoryHint: .isDirectory)
}

@Test("Plan is inert and exposes only the exact path and planned classes")
func previewProfilePlan() throws {
    let fixture = try PreviewProfileFixture()
    defer { fixture.remove() }
    let bootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: fixture.applicationSupport
    )

    let plan = bootstrap.plan
    #expect(plan.profilePath == profileDirectory(in: fixture.applicationSupport).path)
    #expect(plan.plannedClasses == PreviewProfileBootstrap.plannedClasses)
    #expect(!FileManager.default.fileExists(atPath: plan.profilePath))

    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
    )
    #expect(Set(object.keys) == ["profilePath", "plannedClasses"])
}

@Test("Preparation creates only the exact private hierarchy and is idempotent")
func exactIdempotentPreparation() throws {
    let fixture = try PreviewProfileFixture()
    defer { fixture.remove() }
    let bootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: fixture.applicationSupport
    )

    let first = try bootstrap.prepare()
    let second = try bootstrap.prepare()
    #expect(first == second)

    let profile = profileDirectory(in: fixture.applicationSupport)
    let expectedDirectories = [
        fixture.applicationSupport.appending(
            path: ClaudeConfigurationPolicy.previewBundleIdentifier,
            directoryHint: .isDirectory
        ),
        profile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        profile.deletingLastPathComponent().deletingLastPathComponent(),
        profile.deletingLastPathComponent(),
        profile,
        profile.appending(path: "backups", directoryHint: .isDirectory)
    ]
    for directory in expectedDirectories {
        #expect(permissions(at: directory) == 0o700)
    }

    let marker = profile.appending(path: ClaudeConfigurationPolicy.markerFilename)
    #expect(permissions(at: marker) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted() == [
        ClaudeConfigurationPolicy.markerFilename,
        "backups"
    ].sorted())
    #expect(try FileManager.default.contentsOfDirectory(
        atPath: profile.appending(path: "backups").path
    ).isEmpty)
}

@Test("Concurrent preparation publishes one exact complete profile")
func concurrentPreparation() async throws {
    let fixture = try PreviewProfileFixture()
    defer { fixture.remove() }
    let bootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: fixture.applicationSupport
    )

    let receipts = try await withThrowingTaskGroup(
        of: PreviewProfilePreparationReceipt.self,
        returning: [PreviewProfilePreparationReceipt].self
    ) { group in
        for _ in 0..<24 {
            group.addTask { try bootstrap.prepare() }
        }
        var values: [PreviewProfilePreparationReceipt] = []
        for try await value in group { values.append(value) }
        return values
    }

    #expect(receipts.count == 24)
    #expect(Set(receipts.map(\.profilePath)).count == 1)
    let profile = profileDirectory(in: fixture.applicationSupport)
    let marker = profile.appending(path: ClaudeConfigurationPolicy.markerFilename)
    #expect(permissions(at: marker) == 0o600)
    #expect(try Data(contentsOf: marker) == Data(
        "{\"bundleIdentifier\":\"com.lorenzocolombani.openbotsnext.preview\",\"role\":\"preview\",\"schemaVersion\":1}".utf8
    ))
    #expect(try FileManager.default.contentsOfDirectory(atPath: profile.path).sorted() == [
        ClaudeConfigurationPolicy.markerFilename,
        "backups"
    ].sorted())
}

@Test("Preparation coexists with existing app-owned siblings without reading or replacing them")
func preparationPreservesExistingAppSiblings() throws {
    let fixture = try PreviewProfileFixture()
    defer { fixture.remove() }

    let bundle = fixture.applicationSupport.appending(
        path: ClaudeConfigurationPolicy.previewBundleIdentifier,
        directoryHint: .isDirectory
    )
    let highChurn = bundle.appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
    let runtime = highChurn.appending(path: "Runtime", directoryHint: .isDirectory)
    try PreviewProfileFixture.createPrivateDirectory(bundle)
    try PreviewProfileFixture.createPrivateDirectory(highChurn)
    try PreviewProfileFixture.createPrivateDirectory(runtime)

    let rootReceipt = bundle.appending(path: ".openbots-installation.json")
    let state = highChurn.appending(path: "State", directoryHint: .isDirectory)
    let queues = runtime.appending(path: "Queues", directoryHint: .isDirectory)
    let receiptPayload = Data("existing-app-owned-receipt".utf8)
    try receiptPayload.write(to: rootReceipt, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rootReceipt.path)
    try PreviewProfileFixture.createPrivateDirectory(state)
    try PreviewProfileFixture.createPrivateDirectory(queues)

    let bootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: fixture.applicationSupport
    )
    let receipt = try bootstrap.prepare()

    #expect(receipt.profilePath == profileDirectory(in: fixture.applicationSupport).path)
    #expect(try Data(contentsOf: rootReceipt) == receiptPayload)
    #expect(permissions(at: state) == 0o700)
    #expect(permissions(at: queues) == 0o700)
}

@Test("Weak existing permissions are refused without repair")
func weakPermissionsAreRefused() throws {
    let fixture = try PreviewProfileFixture()
    defer { fixture.remove() }
    let bundle = fixture.applicationSupport.appending(
        path: ClaudeConfigurationPolicy.previewBundleIdentifier,
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: bundle,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
    let bootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: fixture.applicationSupport
    )

    #expect(throws: ProbeFailure.self) { try bootstrap.prepare() }
    #expect(permissions(at: bundle) == 0o755)
    #expect(!FileManager.default.fileExists(
        atPath: bundle.appending(path: "HighChurn.noindex").path
    ))
}

@Test("Candidate and ancestor symbolic links are refused")
func symlinksAreRefused() throws {
    let fixture = try PreviewProfileFixture()
    defer { fixture.remove() }
    let target = fixture.root.appending(path: "redirect-target", directoryHint: .isDirectory)
    try PreviewProfileFixture.createPrivateDirectory(target)
    let bundle = fixture.applicationSupport.appending(
        path: ClaudeConfigurationPolicy.previewBundleIdentifier,
        directoryHint: .isDirectory
    )
    try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: target)
    let bootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: fixture.applicationSupport
    )
    #expect(throws: ProbeFailure.self) { try bootstrap.prepare() }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

    let secondFixture = try PreviewProfileFixture()
    defer { secondFixture.remove() }
    let linkedApplicationSupport = secondFixture.root.appending(
        path: "Application Support Link",
        directoryHint: .isDirectory
    )
    try FileManager.default.createSymbolicLink(
        at: linkedApplicationSupport,
        withDestinationURL: secondFixture.applicationSupport
    )
    let ancestorBootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: linkedApplicationSupport
    )
    #expect(throws: ProbeFailure.self) { try ancestorBootstrap.prepare() }
}

@Test("Unexpected marker and hierarchy content are never overwritten")
func unexpectedContentIsRefused() throws {
    let markerFixture = try PreviewProfileFixture()
    defer { markerFixture.remove() }
    let markerBootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: markerFixture.applicationSupport
    )
    let receipt = try markerBootstrap.prepare()
    let marker = URL(fileURLWithPath: receipt.markerPath)
    let partial = Data("partial-interrupted-marker".utf8)
    try partial.write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)

    #expect(throws: ProbeFailure.self) { try markerBootstrap.prepare() }
    #expect(try Data(contentsOf: marker) == partial)

    let contentFixture = try PreviewProfileFixture()
    defer { contentFixture.remove() }
    let contentBootstrap = try PreviewProfileBootstrap(
        testApplicationSupportRoot: contentFixture.applicationSupport
    )
    let contentReceipt = try contentBootstrap.prepare()
    let unexpected = URL(fileURLWithPath: contentReceipt.backupsPath)
        .appending(path: "unexpected.txt")
    try Data("do not replace".utf8).write(to: unexpected)

    #expect(throws: ProbeFailure.self) { try contentBootstrap.prepare() }
    #expect(try Data(contentsOf: unexpected) == Data("do not replace".utf8))
}
