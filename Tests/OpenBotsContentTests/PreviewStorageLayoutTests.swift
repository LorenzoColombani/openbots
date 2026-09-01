import Darwin
import Foundation
import XCTest
@testable import OpenBotsContent

final class PreviewStorageLayoutTests: XCTestCase {
    func testLiveLayoutResolvesTheSystemTemporaryDirectoryAlias() {
        let layout = PreviewStorageLayout.live()

        XCTAssertEqual(
            layout.systemTemporaryDirectory,
            PreviewStorageLayout.physicalSystemTemporaryDirectory(
                FileManager.default.temporaryDirectory
            )
        )
        XCTAssertEqual(
            layout.temporaryRoot.url.deletingLastPathComponent(),
            layout.systemTemporaryDirectory
        )

        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in layout.systemTemporaryDirectory.pathComponents.dropFirst() {
            ancestor.append(path: component, directoryHint: .isDirectory)
            var information = stat()
            XCTAssertEqual(lstat(ancestor.path, &information), 0, ancestor.path)
            XCTAssertNotEqual(information.st_mode & S_IFMT, S_IFLNK, ancestor.path)
        }
    }

    func testPreviewIdentityAndLayoutAreFreshAndExact() throws {
        let fixture = try ContentTemporaryFixture()
        let layout = fixture.layout

        XCTAssertEqual(OpenBotsPreviewIdentity.applicationName, "OpenBots Next Preview")
        XCTAssertEqual(OpenBotsPreviewIdentity.bundleIdentifier, "com.lorenzocolombani.openbotsnext.preview")
        XCTAssertEqual(OpenBotsPreviewIdentity.previewBuildRelativePath, ".build.noindex/preview")
        XCTAssertFalse(OpenBotsPreviewIdentity.previewBuildRelativePath.hasPrefix("/"))
        XCTAssertEqual(
            layout.applicationSupportRoot.url.path,
            fixture.home.path + "/Library/Application Support/com.lorenzocolombani.openbotsnext.preview"
        )
        XCTAssertEqual(layout.highChurnRoot.lastPathComponent, "HighChurn.noindex")
        XCTAssertEqual(layout.databaseURL.lastPathComponent, "OpenBots.sqlite")
        XCTAssertEqual(layout.databaseWALURL.lastPathComponent, "OpenBots.sqlite-wal")
        XCTAssertEqual(layout.databaseSHMURL.lastPathComponent, "OpenBots.sqlite-shm")
        XCTAssertEqual(
            layout.cacheRoot.url.lastPathComponent,
            "com.lorenzocolombani.openbotsnext.preview.noindex"
        )
        XCTAssertEqual(layout.visibleWorkingRoot.lastPathComponent, "Working.noindex")
        XCTAssertEqual(layout.contentRoot.url.lastPathComponent, "OpenBots Next Preview Content")
        XCTAssertFalse(layout.contentRoot.url.path.contains("/OpenBots/"))
    }

    func testRootCreationPlanIsSideEffectFreeAndDoesNotBootstrapClaudeProfile() throws {
        let fixture = try ContentTemporaryFixture()
        let installationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let internalKinds: [OwnedRootKind] = [.applicationSupport, .caches, .temporary]
        let ids = Dictionary(uniqueKeysWithValues: internalKinds.enumerated().map {
            ($0.element, UUID(uuidString: String(format: "22222222-2222-2222-2222-%012d", $0.offset + 1))!)
        })

        let plan = try PreviewRootCreationPlan(
            layout: fixture.layout,
            installationID: installationID,
            rootIDs: ids
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.applicationSupportRoot.url.path))
        XCTAssertFalse(plan.steps.contains(where: { $0.url == fixture.layout.claudeCLIProfileRoot }))
        XCTAssertFalse(plan.steps.contains(where: { $0.url == fixture.layout.contentRoot.url }))
        XCTAssertFalse(plan.steps.contains(where: { $0.url == fixture.layout.visibleWorkingRoot }))
        XCTAssertTrue(plan.steps.contains(where: { $0.url == fixture.layout.highChurnRoot }))
        XCTAssertTrue(plan.steps.contains(where: { $0.url == fixture.layout.runtimeRoot }))
        XCTAssertLessThan(
            try XCTUnwrap(plan.steps.firstIndex(where: { $0.url == fixture.layout.runtimeRoot })),
            try XCTUnwrap(plan.steps.firstIndex(where: { $0.url == fixture.layout.queueRoot }))
        )
        XCTAssertEqual(plan.rootIDs, ids)

        let markerSteps = plan.steps.filter {
            if case .exclusiveOwnershipMarker = $0.kind { return true }
            return false
        }
        XCTAssertEqual(markerSteps.count, internalKinds.count)
        for step in markerSteps {
            guard case let .exclusiveOwnershipMarker(data, mode) = step.kind else {
                return XCTFail("Expected marker step")
            }
            XCTAssertEqual(mode, 0o600)
            let marker = try JSONDecoder().decode(OwnedRootMarker.self, from: data)
            XCTAssertEqual(marker.bundleIdentifier, OpenBotsPreviewIdentity.bundleIdentifier)
            XCTAssertEqual(marker.installationID, installationID)
        }
    }

    func testVisibleContentCreationRequiresExplicitValidatedSelection() throws {
        let fixture = try ContentTemporaryFixture()
        let selectionID = UUID()
        let selection = try SelectedVisibleContentRoot.validate(
            selectionID: selectionID,
            layout: fixture.layout,
            locationChecker: StaticLocationChecker(value: safeLocalObservation)
        )
        let plan = try PreviewVisibleContentRootCreationPlan(
            selection: selection,
            layout: fixture.layout,
            installationID: UUID(),
            rootID: UUID()
        )
        XCTAssertEqual(selection.selectionID, selectionID)
        XCTAssertTrue(plan.steps.contains(where: { $0.url == fixture.layout.contentRoot.url }))
        XCTAssertTrue(plan.steps.contains(where: { $0.url == fixture.layout.visibleWorkingRoot }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))

        let unsafe = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: true,
            fileProviderStatus: .managed(providerIdentifier: "fixture")
        )
        XCTAssertThrowsError(
            try SelectedVisibleContentRoot.validate(
                selectionID: UUID(),
                layout: fixture.layout,
                locationChecker: StaticLocationChecker(value: unsafe)
            )
        ) { XCTAssertEqual($0 as? HighChurnLocationViolation, .ubiquitousItem) }
    }

    func testEveryAutomatedHighChurnPathHasNoIndexAncestor() throws {
        let fixture = try ContentTemporaryFixture()
        let layout = fixture.layout
        let highChurnPaths = [
            layout.databaseURL,
            layout.databaseWALURL,
            layout.databaseSHMURL,
            layout.queueRoot,
            layout.leaseRoot,
            layout.checkpointRoot,
            layout.generatedConfigurationRoot,
            layout.logsRoot,
            layout.internalWorkspacesRoot,
            layout.internalMemoryRoot,
            layout.internalProjectsRoot,
            layout.cacheIndexesRoot,
            layout.attachmentIngestRoot,
            layout.avatarIngestRoot,
            layout.perRunRuntimeRoot,
            layout.visibleWorkingRoot
        ]
        for url in highChurnPaths {
            XCTAssertTrue(
                url.pathComponents.contains(where: { $0.hasSuffix(".noindex") }),
                "Missing .noindex boundary for \(url.path)"
            )
        }
    }
}
