import CoreGraphics
import Foundation
import ImageIO
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
import OpenBotsSecurity
import Testing
import UniformTypeIdentifiers
@testable import OpenBotsServices

@Suite("SprintThreeIntegrationTests")
struct SprintThreeIntegrationTests {
    @Test("A normalized photo and saved profile survive reopening the composed SQLite workspace")
    func profilePhotoRoundTrip() async throws {
        let fixture = try SprintThreeStorageFixture()
        defer { fixture.remove() }
        let source = fixture.root.appending(path: "explicit-picked-photo.png")
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try #require(CGContext(data: nil, width: 4, height: 2,
            bitsPerComponent: 8, bytesPerRow: 16, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.6, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let pixels = try #require(bitmap.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
        let originalBytes = encoded as Data
        try originalBytes.write(to: source, options: .withoutOverwriting)
        let keychain = InMemoryKeychainClient()
        let saved: (Teammate, ProfilePhotoAsset) = try await {
            let context = try await StoragePersistenceCompositionService(
                layout: fixture.layout, bootstrapper: fixture.bootstrapper(),
                keychainClient: keychain, teammateExecutor: PendingArchitectureExecutor()
            ).bootstrapAndOpen(using: fixture.plan(), protection: .ordinarySQLite, decision: fixture.decision)
            let root = try ProfilePhotoRootVerifier().verify(fixture.layout.profileAssetsRoot, inside: context.applicationSupportRoot)
            let store = ProfilePhotoContentStore(root: root)
            let photos = ProfilePhotoService(repository: context.profilePhotoRepository,
                importer: { url, id in try await store.importPhoto(from: url, id: id) },
                reader: { try await store.read($0) })
            let profiles = TeammateProfileService(repository: context.teammateRepository, photoValidator: photos)
            let teammate = try await profiles.createQuickTeammate(.init(displayName: "Photo Partner", role: "Researcher"))
            let asset = try await photos.importPhoto(from: source)
            let updated = try await profiles.saveProfile(teammateID: teammate.id,
                expectedRevision: teammate.profile.revision,
                draft: .init(displayName: "Photo Partner", role: "Researcher", photoAssetID: asset.id))
            #expect(updated.appearance.mode == .photo)
            #expect(updated.appearance.deterministicSeed == teammate.appearance.deterministicSeed)
            return (updated, asset)
        }()
        let reopened = try await StoragePersistenceCompositionService(layout: fixture.layout,
            keychainClient: keychain, teammateExecutor: PendingArchitectureExecutor()).reopenExisting()
        let persisted = try #require(try await reopened.teammateRepository.teammate(id: saved.0.id))
        #expect(persisted.profile == saved.0.profile)
        #expect(persisted.appearance == saved.0.appearance)
        #expect(try await reopened.profilePhotoRepository.asset(id: saved.1.id) == saved.1)
        let root = try ProfilePhotoRootVerifier().verify(fixture.layout.profileAssetsRoot, inside: reopened.applicationSupportRoot)
        let normalized = try await ProfilePhotoContentStore(root: root).read(saved.1)
        let image = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
        #expect(CGImageSourceGetCount(image) == 1)
        #expect(saved.1.width == 4 && saved.1.height == 2)
        #expect(try Data(contentsOf: source) == originalBytes)
        #expect(await keychain.recordedOperations().isEmpty)
        #expect(reopened.teammateExecutor is PendingArchitectureExecutor)
    }

    @Test(
        "Composed SQLite directory and collaboration fixtures preserve the Sprint 3 boundary"
    )
    func composedDirectoryAndCollaborationRoundTrip() async throws {
        let fixture = try SprintThreeStorageFixture()
        defer { fixture.remove() }

        let timestamp = Date(timeIntervalSince1970: 9_500)
        let firstTeammateID = TeammateID(sprintThreeUUID(1))
        let secondTeammateID = TeammateID(sprintThreeUUID(2))
        let projectID = ProjectID(sprintThreeUUID(100))
        let teamID = TeamID(sprintThreeUUID(101))
        let initialKeychain = InMemoryKeychainClient()
        let initialExecutor = PendingArchitectureExecutor()

        let durable = try await {
            let context = try await StoragePersistenceCompositionService(
                layout: fixture.layout,
                bootstrapper: fixture.bootstrapper(),
                keychainClient: initialKeychain,
                teammateExecutor: initialExecutor
            ).bootstrapAndOpen(
                using: fixture.plan(),
                protection: .ordinarySQLite,
                decision: fixture.decision
            )

            #expect(context.databaseFacts.protectionMode == .ordinarySQLite)
            #expect(
                context.databaseFacts.migrationCount
                    == StoragePersistenceCompositionService.expectedMigrationCount
            )

            let profileService = TeammateProfileService(
                repository: context.teammateRepository,
                clock: SprintThreeFixedClock(value: timestamp),
                uuidGenerator: SprintThreeSequenceUUIDGenerator([
                    firstTeammateID.rawValue,
                    secondTeammateID.rawValue,
                ])
            )
            let first = try await profileService.createQuickTeammate(
                QuickTeammateDraft(displayName: "Mika", role: "Research lead")
            )
            let second = try await profileService.createQuickTeammate(
                QuickTeammateDraft(displayName: "Rook", role: "Source verifier")
            )
            #expect(first.id == firstTeammateID)
            #expect(second.id == secondTeammateID)
            #expect(first.lifecycle == .active)
            #expect(second.lifecycle == .active)

            let directory = ProjectTeamDirectoryService(
                teammateRepository: context.teammateRepository,
                projectRepository: context.projectRepository,
                projectProvisioningRepository: context.projectProvisioningRepository,
                teamRepository: context.teamRepository,
                clock: SprintThreeFixedClock(value: timestamp),
                uuidGenerator: SprintThreeSequenceUUIDGenerator([
                    projectID.rawValue,
                    teamID.rawValue,
                ])
            )
            let project = try await directory.createProject(
                ProjectDirectoryDraft(
                    name: "Atlas",
                    summary: "Shared research",
                    memberIDs: [first.id, second.id]
                )
            )
            let team = try await directory.createTeam(
                TeamDirectoryDraft(
                    name: "Research Studio",
                    summary: "Persistent teammate identities",
                    leadID: second.id,
                    memberIDs: [first.id, second.id]
                )
            )

            #expect(project.project.id == projectID)
            #expect(project.members == [first, second])
            #expect(team.team.id == teamID)
            #expect(team.team.leadID == second.id)
            #expect(team.team.memberIDs == [first.id, second.id])
            #expect(team.members == [first, second])
            #expect(await initialKeychain.recordedOperations().isEmpty)
            #expect(context.teammateExecutor is PendingArchitectureExecutor)

            return (teammates: [first, second], project: project, team: team)
        }()

        #expect(await initialKeychain.recordedOperations().isEmpty)

        let reopenedKeychain = InMemoryKeychainClient()
        let reopenedExecutor = PendingArchitectureExecutor()
        let reopened = try await StoragePersistenceCompositionService(
            layout: fixture.layout,
            keychainClient: reopenedKeychain,
            teammateExecutor: reopenedExecutor
        ).reopenExisting()
        let reopenedDirectory = ProjectTeamDirectoryService(
            teammateRepository: reopened.teammateRepository,
            projectRepository: reopened.projectRepository,
            projectProvisioningRepository: reopened.projectProvisioningRepository,
            teamRepository: reopened.teamRepository
        )
        let reopenedProfiles = TeammateProfileService(repository: reopened.teammateRepository)

        #expect(
            reopened.databaseFacts.migrationCount
                == StoragePersistenceCompositionService.expectedMigrationCount
        )
        #expect(try await reopenedProfiles.activeTeammates() == durable.teammates)
        #expect(try await reopenedDirectory.activeProjects() == [durable.project])
        #expect(try await reopenedDirectory.activeTeams() == [durable.team])
        #expect(
            try await reopened.projectRepository.activeMemberIDs(
                projectID: durable.project.project.id
            ) == Set(durable.teammates.map(\.id))
        )
        #expect(
            try await reopened.teamRepository.team(id: durable.team.team.id)
                == durable.team.team
        )

        let successful = try CollaborationReviewFixtureService().snapshot(
            variant: .successfulFanIn
        )
        let recovery = try CollaborationReviewFixtureService().snapshot(
            variant: .needsRecovery
        )
        let request = successful.memoryContext.request

        #expect(successful.memoryContext == recovery.memoryContext)
        #expect(
            successful.memoryContext.includedExcerpts.map(\.scope) == [
                .user,
                .teammate(request.teammateID),
                .project(try #require(request.selectedProjectID)),
            ]
        )
        #expect(
            successful.memoryContext.includedExcerpts.allSatisfy {
                $0.scope.isReadable(
                    by: request.teammateID,
                    selectedProjectID: request.selectedProjectID,
                    activeProjectMemberships: request.activeProjectMemberships
                )
            }
        )
        #expect(
            successful.memoryContext.exclusionCounts == [
                .otherTeammate: 1,
                .differentProject: 1,
            ]
        )

        let visibleSnapshots = String(describing: successful) + String(describing: recovery)
        for excludedValue in [
            "ADA-PRIVATE-EXCLUDED-SENTINEL",
            "OTHER-PROJECT-EXCLUDED-SENTINEL",
            "Ada excluded sentinel title",
            "Other project excluded sentinel title",
        ] {
            #expect(!visibleSnapshots.contains(excludedValue))
        }
        #expect(successful.handoff.state == .returnedToOrigin)
        #expect(successful.handoff.resultForOrigin != nil)
        #expect(recovery.handoff.state == .needsRecovery)
        #expect(recovery.handoff.resultForOrigin == nil)

        let reopenedStore = try #require(reopened.memoryRepository as? SQLiteStore)
        let memoryRows = try await reopenedStore.query(
            sql: "SELECT COUNT(*) AS count FROM memory_documents;"
        )
        #expect(try #require(memoryRows.first).integer("count") == 0)
        #expect(await reopenedKeychain.recordedOperations().isEmpty)
        #expect(reopened.teammateExecutor is PendingArchitectureExecutor)
        await #expect(throws: ExecutorUnavailableError.self) {
            try await reopenedExecutor.requestStop(runID: RunID(sprintThreeUUID(900)))
        }
        #expect(await reopenedKeychain.recordedOperations().isEmpty)
    }
}

private struct SprintThreeFixedClock: OpenBotsClock {
    let value: Date

    func now() -> Date { value }
}

private final class SprintThreeSequenceUUIDGenerator: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        precondition(!values.isEmpty, "The Sprint 3 UUID sequence is exhausted.")
        return values.removeFirst()
    }
}

private struct SprintThreeFixedAdmission: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            fileProviderStatus: .notManaged,
            volumeIdentifier: "sprint-three-integration-volume"
        )
    }
}

private final class SprintThreeStorageFixture: @unchecked Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let installationID = sprintThreeUUID(700)
    let rootIDs: [OwnedRootKind: UUID] = [
        .applicationSupport: sprintThreeUUID(701),
        .caches: sprintThreeUUID(702),
        .temporary: sprintThreeUUID(703),
    ]
    let decision = try! ProtectionDecisionReceipt(
        decisionID: sprintThreeUUID(704),
        selectedAt: Date(timeIntervalSince1970: 9_500),
        rationaleVersion: 2
    )

    init() throws {
        root = URL(
            fileURLWithPath:
                "/private/tmp/OpenBotsNextSprintThreeIntegrationTests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
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
            ofItemAtPath: root.path
        )
        layout = PreviewStorageLayout(
            homeDirectory: home,
            systemTemporaryDirectory: temporary
        )
    }

    func plan() throws -> PreviewRootCreationPlan {
        try PreviewRootCreationPlan(
            layout: layout,
            installationID: installationID,
            rootIDs: rootIDs
        )
    }

    func bootstrapper() -> StorageBootstrapService {
        StorageBootstrapService(
            layout: layout,
            locationAdmission: SprintThreeFixedAdmission()
        )
    }

    func remove() {
        let path = root.path
        guard path.hasPrefix("/private/tmp/OpenBotsNextSprintThreeIntegrationTests-"),
              path.hasSuffix(".noindex")
        else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

private func sprintThreeUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "95000000-0000-0000-0000-%012d", value))!
}
