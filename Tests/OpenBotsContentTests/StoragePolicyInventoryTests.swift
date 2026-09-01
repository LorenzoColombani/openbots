import Foundation
import XCTest
@testable import OpenBotsContent

final class StoragePolicyInventoryTests: XCTestCase {
    func testInventoryIsExhaustiveAndHasOneRecordPerDataClass() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)

        XCTAssertEqual(inventory.records.count, PreviewStorageDataClass.allCases.count)
        XCTAssertEqual(
            Set(inventory.records.map(\.dataClass)),
            Set(PreviewStorageDataClass.allCases)
        )
        XCTAssertEqual(
            inventory.record(for: .installationProtectionReceipt).location,
            fixture.layout.installationReceiptURL
        )
        XCTAssertEqual(inventory.record(for: .sqliteControlDatabase).location, fixture.layout.databaseURL)
        XCTAssertEqual(inventory.record(for: .skillImportStaging).location, fixture.layout.skillStagingRoot)
        XCTAssertTrue(fixture.layout.internalRequiredDirectoryURLs.contains(fixture.layout.skillStagingRoot))
    }

    func testEveryHighChurnLocationHasNoIndexBoundary() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)

        for record in inventory.records where record.churn == .high {
            XCTAssertEqual(record.spotlight, .requiresNoIndexAncestor, record.dataClass.rawValue)
            XCTAssertTrue(
                record.location.pathComponents.contains(where: { $0.hasSuffix(".noindex") }),
                "Missing .noindex boundary for \(record.dataClass.rawValue): \(record.location.path)"
            )
        }
    }

    func testEveryDisposableClassHasExplicitTimeMachineExclusion() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)

        let disposable = inventory.records.filter { $0.authority == .reproducibleDerived }
        XCTAssertFalse(disposable.isEmpty)
        for record in disposable {
            XCTAssertEqual(
                record.timeMachine,
                .excludedUsingResourceValue,
                "Disposable class lacks exclusion: \(record.dataClass.rawValue)"
            )
            XCTAssertEqual(record.humanExport, .never)
        }
    }

    func testDurableAndProviderOwnedClassesCannotEnterExclusionPlanByPolicy() throws {
        let fixture = try ContentTemporaryFixture()
        let inventory = PreviewStoragePolicyInventory(layout: fixture.layout)

        XCTAssertEqual(inventory.record(for: .sqliteControlDatabase).timeMachine, .includedByDefault)
        XCTAssertEqual(
            inventory.record(for: .installationProtectionReceipt).humanExport,
            .backupArchiveOnly
        )
        XCTAssertEqual(inventory.record(for: .authoritativeMarkdownMemory).timeMachine, .includedByDefault)
        XCTAssertEqual(inventory.record(for: .stableAttachments).timeMachine, .includedByDefault)
        let attachments = inventory.record(for: .internalDurableAttachments)
        XCTAssertEqual(attachments.location, fixture.layout.internalAttachmentsRoot)
        XCTAssertEqual(attachments.authority, .durableUserContent)
        XCTAssertEqual(attachments.churn, .high)
        XCTAssertEqual(attachments.spotlight, .requiresNoIndexAncestor)
        XCTAssertEqual(attachments.timeMachine, .includedByDefault)
        XCTAssertEqual(attachments.humanExport, .backupArchiveOnly)
        XCTAssertEqual(attachments.resetOwnership, .verifiedOwnedRoot(.applicationSupport))
        XCTAssertNotEqual(attachments.location, inventory.record(for: .stableAttachments).location)
        XCTAssertEqual(
            inventory.record(for: .claudeCLIProfile).timeMachine,
            .providerOwnedNoOpenBotsMutation
        )
        XCTAssertEqual(
            inventory.record(for: .claudeCLIProfile).resetOwnership,
            .separatelyDisclosedProviderProfileReset
        )
    }
}
