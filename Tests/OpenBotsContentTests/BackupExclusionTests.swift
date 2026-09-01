import Foundation
import XCTest
@testable import OpenBotsContent

private final class RecordingBackupExclusionAccess: BackupExclusionResourceAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var excluded: Set<URL> = []
    private var writes: [URL] = []

    func setExcludedFromBackup(at url: URL) throws {
        lock.withLock {
            writes.append(url)
            excluded.insert(url)
        }
    }

    func isExcludedFromBackup(at url: URL) throws -> Bool? {
        lock.withLock { excluded.contains(url) }
    }

    func recordedWrites() -> [URL] {
        lock.withLock { writes }
    }
}

final class BackupExclusionTests: XCTestCase {
    func testPlansOnlyExplicitEligibleClassesForEachVerifiedRoot() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)

        let support = try makeVerifiedRoot(fixture, descriptor: fixture.layout.applicationSupportRoot)
        let supportPlan = try BackupExclusionPlanner().plan(for: support, inventory: inventory)
        XCTAssertEqual(supportPlan.targets.map(\.dataClass), [.redactedLogs])

        let cache = try makeVerifiedRoot(fixture, descriptor: fixture.layout.cacheRoot)
        let cachePlan = try BackupExclusionPlanner().plan(for: cache, inventory: inventory)
        XCTAssertTrue(cachePlan.targets.contains(where: { $0.dataClass == .cacheContainer }))
        XCTAssertTrue(cachePlan.targets.contains(where: { $0.dataClass == .skillImportStaging }))
        XCTAssertFalse(cachePlan.targets.contains(where: { $0.dataClass == .generatedConfiguration }))

        let temporary = try makeVerifiedRoot(fixture, descriptor: fixture.layout.temporaryRoot)
        let temporaryPlan = try BackupExclusionPlanner().plan(for: temporary, inventory: inventory)
        XCTAssertEqual(temporaryPlan.targets.map(\.dataClass), [.temporaryMaterial])
    }

    func testVisibleContentRootHasNoBackupExclusionPlan() throws {
        let fixture = try ContentTemporaryFixture()
        let visible = try makeVerifiedRoot(fixture, descriptor: fixture.layout.contentRoot)
        XCTAssertThrowsError(
            try BackupExclusionPlanner().plan(
                for: visible,
                inventory: PreviewStoragePolicyInventory(layout: fixture.layout)
            )
        ) { XCTAssertEqual($0 as? BackupExclusionError, .noEligibleTargets) }
    }

    func testInjectedExecutorTouchesOnlyFrozenCacheTargets() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)
        let cache = try makeVerifiedRoot(fixture, descriptor: fixture.layout.cacheRoot)
        let plan = try BackupExclusionPlanner().plan(for: cache, inventory: inventory)
        try materialize(plan.targets)
        let access = RecordingBackupExclusionAccess()

        let receipt = try BackupExclusionExecutor(resourceAccess: access).execute(plan)
        XCTAssertEqual(Set(access.recordedWrites()), Set(plan.targets.map(\.exactURL)))
        XCTAssertEqual(Set(receipt.verifiedDataClasses), Set(plan.targets.map(\.dataClass)))
        XCTAssertNoThrow(try BackupExclusionVerifier(resourceAccess: access).verify(plan))
    }

    func testSupportedFoundationSetterIsBoundedToTemporaryNoIndexFixture() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)
        let temporary = try makeVerifiedRoot(fixture, descriptor: fixture.layout.temporaryRoot)
        let plan = try BackupExclusionPlanner().plan(for: temporary, inventory: inventory)
        let access = FoundationBackupExclusionResourceAccess()

        XCTAssertNoThrow(try access.setExcludedFromBackup(at: fixture.layout.temporaryRoot.url))
        let physicalReadback = try access.isExcludedFromBackup(at: fixture.layout.temporaryRoot.url)
        if physicalReadback == true {
            XCTAssertNoThrow(try BackupExclusionVerifier(resourceAccess: access).verify(plan))
        } else {
            XCTAssertThrowsError(try BackupExclusionVerifier(resourceAccess: access).verify(plan)) {
                XCTAssertEqual(
                    $0 as? BackupExclusionError,
                    .resourceValueNotTrue(.temporaryMaterial)
                )
            }
        }

        let unset = RecordingBackupExclusionAccess()
        XCTAssertThrowsError(try BackupExclusionVerifier(resourceAccess: unset).verify(plan)) {
            XCTAssertEqual(
                $0 as? BackupExclusionError,
                .resourceValueNotTrue(.temporaryMaterial)
            )
        }
    }

    private func makeVerifiedRoot(
        _ fixture: ContentTemporaryFixture,
        descriptor: OwnedRootDescriptor
    ) throws -> VerifiedOwnedRoot {
        let installationID = UUID()
        let rootID = UUID()
        try fixture.materializeOwnedRoot(
            descriptor,
            installationID: installationID,
            rootID: rootID
        )
        return try OwnedRootVerifier().verify(
            descriptor,
            expectedInstallationID: installationID,
            expectedRootID: rootID
        )
    }

    private func materialize(_ targets: [BackupExclusionTarget]) throws {
        for target in targets where !FileManager.default.fileExists(atPath: target.exactURL.path) {
            try FileManager.default.createDirectory(
                at: target.exactURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
