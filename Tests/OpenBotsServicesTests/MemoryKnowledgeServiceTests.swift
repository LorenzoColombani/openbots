import Foundation
import OpenBotsContent
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private let knowledgeTestLocation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "knowledge-test-volume"
)

private struct KnowledgeTestAdmission: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        knowledgeTestLocation
    }
}

private enum KnowledgeRepositoryFailure: Error {
    case rejected
}

private actor KnowledgeMemoryRepository: MemoryRepository {
    private var stored: [MemoryDocumentID: MemoryDocument] = [:]
    private let rejectsInsert: Bool

    init(rejectsInsert: Bool = false) {
        self.rejectsInsert = rejectsInsert
    }

    func authorityContract() async throws -> MemoryAuthorityContract {
        .appOwnedMarkdownV1
    }

    func document(id: MemoryDocumentID) async throws -> MemoryDocument? {
        stored[id]
    }

    func allDocuments() async throws -> [MemoryDocument] {
        Array(stored.values)
    }

    func documents(scope: MemoryScope) async throws -> [MemoryDocument] {
        stored.values.filter { $0.scope == scope }
    }

    func insert(_ document: MemoryDocument) async throws {
        try await insertRevision(document, expectedPredecessorID: document.supersedes)
    }

    func insertRevision(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) async throws {
        if rejectsInsert { throw KnowledgeRepositoryFailure.rejected }
        guard document.supersedes == expectedPredecessorID else {
            throw RepositoryError.optimisticLockFailed(
                entity: "memory predecessor",
                id: expectedPredecessorID?.persistedValue ?? "initial"
            )
        }
        if let expectedPredecessorID {
            guard let predecessor = stored[expectedPredecessorID],
                  predecessor.scope == document.scope,
                  predecessor.revision + 1 == document.revision,
                  !stored.values.contains(where: { $0.supersedes == expectedPredecessorID }) else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "memory successor",
                    id: expectedPredecessorID.persistedValue
                )
            }
        }
        stored[document.id] = document
    }
}

private final class MemoryKnowledgeFixture: @unchecked Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let plan: PreviewRootCreationPlan

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextMemoryKnowledge-\(UUID().uuidString).noindex",
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
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        layout = PreviewStorageLayout(
            homeDirectory: home,
            systemTemporaryDirectory: temporary
        )
        plan = try PreviewRootCreationPlan(
            layout: layout,
            installationID: UUID(),
            rootIDs: [
                .applicationSupport: UUID(),
                .caches: UUID(),
                .temporary: UUID()
            ]
        )
    }

    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let receipt = try await StorageBootstrapService(
            layout: layout,
            locationAdmission: KnowledgeTestAdmission()
        ).bootstrap(using: plan)
        let applicationSupport = try #require(
            receipt.verifiedRoots.first(where: { $0.kind == .applicationSupport })
        )
        return try AuthoritativeMarkdownRootVerifier().verify(
            layout.internalMemoryRoot,
            inside: applicationSupport
        )
    }

    func markdownFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: layout.internalMemoryRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "md" else { return nil }
            return url
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test("Knowledge service reads only scope-admitted current Markdown and renders a non-authoritative snapshot")
func knowledgeServiceSelectsBeforeReading() async throws {
    let fixture = try MemoryKnowledgeFixture()
    defer { fixture.cleanUp() }
    let repository = KnowledgeMemoryRepository()
    let sourceUpdatedAt = Date(timeIntervalSince1970: 1_780_100_000.25)
    let service = MemoryKnowledgeService(
        repository: repository,
        authority: try await fixture.authority(),
        clock: { sourceUpdatedAt }
    )
    let teammateID = TeammateID(UUID())
    let otherTeammateID = TeammateID(UUID())
    let projectID = ProjectID(UUID())
    let otherProjectID = ProjectID(UUID())

    let user = try await service.publishRevision(
        title: "Working preferences",
        scope: .user,
        author: .user,
        markdown: "# Working preferences\n\nPrefer concise checkpoints.\n"
    )
    let teammate = try await service.publishRevision(
        title: "Research habits",
        scope: .teammate(teammateID),
        author: .teammate(teammateID),
        markdown: "# Research habits\n\nVerify primary sources.\n"
    )
    let project = try await service.publishRevision(
        title: "Atlas brief",
        scope: .project(projectID),
        author: .user,
        markdown: "# Atlas brief\n\nPrepare a traceable report.\n"
    )
    let excludedTeammate = try await service.publishRevision(
        title: "Private note",
        scope: .teammate(otherTeammateID),
        author: .teammate(otherTeammateID),
        markdown: "EXCLUDED-TEAMMATE-SENTINEL"
    )
    _ = try await service.publishRevision(
        title: "Other project",
        scope: .project(otherProjectID),
        author: .user,
        markdown: "EXCLUDED-PROJECT-SENTINEL"
    )

    // Corrupt an excluded file. A successful workspace proves excluded content
    // was not opened as a side effect of selection.
    let excludedURL = fixture.layout.internalMemoryRoot.appending(
        path: excludedTeammate.relativePath,
        directoryHint: .notDirectory
    )
    try Data("corrupt excluded bytes".utf8).write(to: excludedURL)

    let workspace = try await service.workspace(
        request: MemoryContextRequest(
            teammateID: teammateID,
            selectedProjectID: projectID,
            activeProjectMemberships: [projectID]
        )
    )
    #expect(Set(workspace.documents.map(\.document.id)) == [user.id, teammate.id, project.id])
    #expect(workspace.excludedDocumentCount == 2)
    #expect(!workspace.documents.map(\.markdown).joined().contains("EXCLUDED"))

    let reveal = try await service.validatedRevealURL(
        workspaceSnapshotID: workspace.id,
        documentID: teammate.id
    )
    #expect(reveal.lastPathComponent.contains(teammate.id.persistedValue))

    do {
        _ = try await service.validatedRevealURL(
            workspaceSnapshotID: workspace.id,
            documentID: excludedTeammate.id
        )
        Issue.record("An excluded document received a Reveal URL")
    } catch let error as MemoryKnowledgeError {
        #expect(error == .documentNotInWorkspace)
    }

    let snapshot = try await service.renderSnapshot(
        workspaceSnapshotID: workspace.id,
        generatedAt: Date(timeIntervalSince1970: 1_780_000_000)
    )
    #expect(snapshot.sourceCount == 3)
    #expect(snapshot.purpose == .ownerInspection)
    #expect(snapshot.isAuthoritative == false)
    #expect(snapshot.supportsWriteBack == false)
    #expect(snapshot.markdown.contains("Non-authoritative snapshot"))
    #expect(snapshot.markdown.contains("Edits to this snapshot do not flow back"))
    #expect(snapshot.markdown.contains("- Author/provenance: User"))
    #expect(snapshot.markdown.contains("- Author/provenance: Teammate \(teammateID.persistedValue)"))
    #expect(snapshot.markdown.contains("- Source updated: 2026-05-30T00:13:20.250Z"))
    #expect(snapshot.markdown.contains("- Revision status: Current authoritative revision"))
    #expect(snapshot.markdown.contains("- Last-known-good sources: 0"))
    #expect(!snapshot.markdown.contains(fixture.root.path))
}

@Test("Knowledge service rolls back its exact Markdown publication when catalog insertion fails")
func knowledgeServiceRollsBackRejectedCatalogInsert() async throws {
    let fixture = try MemoryKnowledgeFixture()
    defer { fixture.cleanUp() }
    let service = MemoryKnowledgeService(
        repository: KnowledgeMemoryRepository(rejectsInsert: true),
        authority: try await fixture.authority()
    )

    do {
        _ = try await service.publishRevision(
            title: "Rejected",
            scope: .user,
            author: .user,
            markdown: "# Rejected\n"
        )
        Issue.record("The injected repository failure was not returned")
    } catch KnowledgeRepositoryFailure.rejected {
        // Expected.
    }
    #expect(fixture.markdownFiles().isEmpty)
}

@Test("Knowledge service reports and serves the last known good immutable revision")
func knowledgeServiceRecoversLastKnownGoodRevision() async throws {
    let fixture = try MemoryKnowledgeFixture()
    defer { fixture.cleanUp() }
    let repository = KnowledgeMemoryRepository()
    let knownGoodUpdatedAt = Date(timeIntervalSince1970: 1_780_200_000.75)
    let service = MemoryKnowledgeService(
        repository: repository,
        authority: try await fixture.authority(),
        clock: { knownGoodUpdatedAt }
    )
    let teammateID = TeammateID(UUID())
    let first = try await service.publishRevision(
        title: "Working note",
        scope: .teammate(teammateID),
        author: .teammate(teammateID),
        markdown: "# Working note\n\nKnown good.\n"
    )
    let second = try await service.publishRevision(
        title: "Working note",
        scope: .teammate(teammateID),
        author: .teammate(teammateID),
        markdown: "# Working note\n\nNew revision.\n",
        superseding: first.id
    )
    let latestURL = fixture.layout.internalMemoryRoot.appending(
        path: second.relativePath,
        directoryHint: .notDirectory
    )
    try Data("tampered".utf8).write(to: latestURL)

    let workspace = try await service.workspace(
        request: MemoryContextRequest(
            teammateID: teammateID,
            selectedProjectID: nil,
            activeProjectMemberships: []
        )
    )
    let recovered = try #require(workspace.documents.first)
    #expect(recovered.document.id == first.id)
    #expect(recovered.document.revision == 1)
    #expect(recovered.unavailableNewerRevision == 2)
    #expect(recovered.markdown.contains("Known good"))
    #expect(!FileManager.default.fileExists(atPath: latestURL.path))
    let quarantineURL = fixture.layout.internalMemoryRoot.appending(
        path: "Quarantine",
        directoryHint: .isDirectory
    )
    let quarantined = try FileManager.default.contentsOfDirectory(
        at: quarantineURL,
        includingPropertiesForKeys: nil
    )
    #expect(quarantined.count == 1)
    #expect(quarantined[0].lastPathComponent.contains(second.id.persistedValue))

    let snapshot = try await service.renderSnapshot(
        workspaceSnapshotID: workspace.id,
        generatedAt: Date(timeIntervalSince1970: 1_780_300_000)
    )
    #expect(snapshot.markdown.contains("- Author/provenance: Teammate \(teammateID.persistedValue)"))
    #expect(snapshot.markdown.contains("- Source updated: 2026-05-31T04:00:00.750Z"))
    #expect(
        snapshot.markdown.contains(
            "- Revision status: Last known good; newer revision 2 is unavailable"
        )
    )
    #expect(snapshot.markdown.contains("- Last-known-good sources: 1"))
    #expect(snapshot.purpose == .ownerInspection)
    await #expect(throws: MemoryKnowledgeError.sharingUnavailable) {
        _ = try await service.renderSnapshot(workspaceSnapshotID: workspace.id, purpose: .qualifiedSharing)
    }
    #expect(!snapshot.markdown.contains("- Revision status: Current authoritative revision"))
}
