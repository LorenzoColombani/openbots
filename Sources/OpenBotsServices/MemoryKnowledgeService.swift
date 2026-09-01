import Foundation
import OpenBotsContent
import OpenBotsDomain

public enum MemoryKnowledgeError: Error, Equatable, Sendable {
    case authorityContractMismatch
    case predecessorUnavailable
    case invalidRevisionGraph
    case contentUnavailable
    case workspaceSnapshotExpired
    case documentNotInWorkspace
    case catalogCommitFailedAndRollbackFailed
    case sharingUnavailable
}

/// One validated revision returned through the scope boundary. Filesystem paths
/// stay inside this service; callers receive a separately revalidated Reveal URL
/// only for a document already admitted to the exact workspace snapshot.
public struct MemoryKnowledgeDocumentSnapshot: Equatable, Sendable {
    public let document: MemoryDocument
    public let markdown: String
    public let unavailableNewerRevision: UInt64?

    public init(
        document: MemoryDocument,
        markdown: String,
        unavailableNewerRevision: UInt64? = nil
    ) {
        self.document = document
        self.markdown = markdown
        self.unavailableNewerRevision = unavailableNewerRevision
    }
}

/// The exact scope-filtered, content-validated read result cached for Reveal
/// and one-shot snapshot delivery. Excluded identities never cross this value.
public struct MemoryKnowledgeWorkspaceSnapshot: Equatable, Sendable {
    public let id: UUID
    public let documents: [MemoryKnowledgeDocumentSnapshot]
    public let exclusionCounts: [MemoryContextExclusionReason: Int]

    public var excludedDocumentCount: Int {
        exclusionCounts.values.reduce(0, +)
    }

    public init(
        id: UUID,
        documents: [MemoryKnowledgeDocumentSnapshot],
        exclusionCounts: [MemoryContextExclusionReason: Int]
    ) {
        self.id = id
        self.documents = documents
        self.exclusionCounts = exclusionCounts
    }
}

/// Coordinates the SQLite catalog and the one app-owned Markdown authority.
/// The actor serializes revision publication and keeps only a small number of
/// path-free workspace receipts for subsequent Reveal/snapshot actions.
public actor MemoryKnowledgeService {
    public typealias Clock = @Sendable () -> Date
    public typealias UUIDGenerator = @Sendable () -> UUID

    private struct CachedWorkspace: Sendable {
        let snapshot: MemoryKnowledgeWorkspaceSnapshot
        let referencesByDocumentID: [MemoryDocumentID: AuthoritativeMarkdownReference]
    }

    private static let maximumCachedWorkspaces = 16

    private let repository: any MemoryRepository
    private let authority: VerifiedAuthoritativeMarkdownRoot
    private let store: AuthoritativeMarkdownStore
    private let selector: MemoryContextSelectionService
    private let renderer: KnowledgeSnapshotRenderer
    private let sharing: MemoryClaimSnapshotSharingService?
    private let clock: Clock
    private let uuid: UUIDGenerator
    private var cachedWorkspaces: [UUID: CachedWorkspace] = [:]
    private var cacheOrder: [UUID] = []

    public init(
        repository: any MemoryRepository,
        authority: VerifiedAuthoritativeMarkdownRoot,
        store: AuthoritativeMarkdownStore = AuthoritativeMarkdownStore(),
        selector: MemoryContextSelectionService = MemoryContextSelectionService(),
        renderer: KnowledgeSnapshotRenderer = KnowledgeSnapshotRenderer(),
        sharing: MemoryClaimSnapshotSharingService? = nil,
        clock: @escaping Clock = Date.init,
        uuid: @escaping UUIDGenerator = UUID.init
    ) {
        self.repository = repository
        self.authority = authority
        self.store = store
        self.selector = selector
        self.renderer = renderer
        self.sharing = sharing
        self.clock = clock
        self.uuid = uuid
    }

    /// Publishes one immutable revision, then commits its structured catalog
    /// row. If catalog insertion fails, only that exact publication receipt may
    /// be rolled back; no directory cleanup or external path is reachable.
    @discardableResult
    public func publishRevision(
        title: String,
        scope: MemoryScope,
        author: MemoryAuthor,
        markdown: String,
        superseding predecessorID: MemoryDocumentID? = nil
    ) async throws -> MemoryDocument {
        try await verifyAuthorityContract()

        let predecessor: MemoryDocument?
        if let predecessorID {
            guard let found = try await repository.document(id: predecessorID) else {
                throw MemoryKnowledgeError.predecessorUnavailable
            }
            guard found.scope == scope, found.revision < UInt64.max else {
                throw MemoryKnowledgeError.invalidRevisionGraph
            }
            predecessor = found
        } else {
            predecessor = nil
        }

        let documentID = MemoryDocumentID(uuid())
        let revision = predecessor.map { $0.revision + 1 } ?? 1
        let now = clock()
        let request = try AuthoritativeMarkdownPublicationRequest(
            documentID: documentID,
            scope: scope,
            revision: revision,
            markdown: markdown,
            authority: authority
        )
        let publication = try await store.publish(request)
        do {
            let document = try MemoryDocument(
                id: documentID,
                scope: scope,
                author: author,
                title: title,
                relativePath: publication.reference.relativePath,
                revision: revision,
                contentDigest: publication.reference.contentDigest,
                supersedes: predecessorID,
                createdAt: predecessor?.createdAt ?? now,
                updatedAt: now
            )
            try await repository.insertRevision(
                document,
                expectedPredecessorID: predecessorID
            )
            invalidateWorkspaceCache()
            return document
        } catch {
            do {
                try await store.rollback(publication, inside: authority)
            } catch {
                throw MemoryKnowledgeError.catalogCommitFailedAndRollbackFailed
            }
            throw error
        }
    }

    /// Selects only current chain heads by scope before opening any Markdown.
    /// If a selected head is malformed or missing, older immutable revisions
    /// are tried in-order and the degraded result is explicit.
    public func workspace(
        request: MemoryContextRequest
    ) async throws -> MemoryKnowledgeWorkspaceSnapshot {
        try await verifyAuthorityContract()
        let documents = try await repository.allDocuments()
        let documentsByID = try indexedDocuments(documents)
        let heads = try currentHeads(documents, documentsByID: documentsByID)
        let manifest = try selector.manifest(
            candidates: heads.map {
                MemoryContextCandidate(documentID: $0.id, scope: $0.scope)
            },
            request: request
        )

        let headByID = Dictionary(uniqueKeysWithValues: heads.map { ($0.id, $0) })
        var loaded: [MemoryKnowledgeDocumentSnapshot] = []
        var references: [MemoryDocumentID: AuthoritativeMarkdownReference] = [:]
        loaded.reserveCapacity(manifest.includedDocumentIDs.count)

        for includedID in manifest.includedDocumentIDs {
            guard let head = headByID[includedID] else {
                throw MemoryKnowledgeError.invalidRevisionGraph
            }
            let result = try await readLastKnownGood(
                startingAt: head,
                documentsByID: documentsByID
            )
            loaded.append(result.snapshot)
            references[result.snapshot.document.id] = result.reference
        }

        loaded.sort { lhs, rhs in
            if lhs.document.updatedAt != rhs.document.updatedAt {
                return lhs.document.updatedAt > rhs.document.updatedAt
            }
            return lhs.document.id.persistedValue < rhs.document.id.persistedValue
        }
        let snapshot = MemoryKnowledgeWorkspaceSnapshot(
            id: uuid(),
            documents: loaded,
            exclusionCounts: manifest.exclusionCounts
        )
        cache(CachedWorkspace(snapshot: snapshot, referencesByDocumentID: references))
        return snapshot
    }

    /// Returns a URL only after the cached scope admission and a fresh exact
    /// filesystem validation both succeed.
    public func validatedRevealURL(
        workspaceSnapshotID: UUID,
        documentID: MemoryDocumentID
    ) async throws -> URL {
        guard let workspace = cachedWorkspaces[workspaceSnapshotID] else {
            throw MemoryKnowledgeError.workspaceSnapshotExpired
        }
        guard let reference = workspace.referencesByDocumentID[documentID] else {
            throw MemoryKnowledgeError.documentNotInWorkspace
        }
        return try await store.validatedRevealURL(for: reference, inside: authority)
    }

    /// Renders the exact admitted revisions into a completed, path-free,
    /// explicitly non-authoritative snapshot. Destination selection and the
    /// exclusive write remain separate app/UI responsibilities.
    public func renderSnapshot(
        workspaceSnapshotID: UUID,
        generatedAt: Date? = nil,
        purpose: KnowledgeSnapshotPurpose = .ownerInspection
    ) async throws -> NonAuthoritativeKnowledgeSnapshot {
        guard let workspace = cachedWorkspaces[workspaceSnapshotID] else {
            throw MemoryKnowledgeError.workspaceSnapshotExpired
        }
        let sources = try workspace.snapshot.documents.map { item in
            try KnowledgeSnapshotSource(
                documentID: item.document.id,
                title: item.document.title,
                scope: item.document.scope,
                author: item.document.author,
                revision: item.document.revision,
                contentDigest: item.document.contentDigest,
                updatedAt: item.document.updatedAt,
                revisionStatus: item.unavailableNewerRevision.map {
                    .lastKnownGood(unavailableNewerRevision: $0)
                } ?? .current,
                markdown: item.markdown
            )
        }
        if purpose == .qualifiedSharing {
            guard let sharing else { throw MemoryKnowledgeError.sharingUnavailable }
            return try await sharing.render(workspaceSnapshotID: workspaceSnapshotID,
                sources: sources, generatedAt: generatedAt ?? clock())
        }
        return try renderer.render(sources: sources, generatedAt: generatedAt ?? clock())
    }

    private func verifyAuthorityContract() async throws {
        guard try await repository.authorityContract() == .appOwnedMarkdownV1 else {
            throw MemoryKnowledgeError.authorityContractMismatch
        }
    }

    private func indexedDocuments(
        _ documents: [MemoryDocument]
    ) throws -> [MemoryDocumentID: MemoryDocument] {
        let indexed = Dictionary(grouping: documents, by: \.id)
        guard indexed.values.allSatisfy({ $0.count == 1 }) else {
            throw MemoryKnowledgeError.invalidRevisionGraph
        }
        return indexed.mapValues { $0[0] }
    }

    private func currentHeads(
        _ documents: [MemoryDocument],
        documentsByID: [MemoryDocumentID: MemoryDocument]
    ) throws -> [MemoryDocument] {
        let supersededIDs = Set(documents.compactMap(\.supersedes))
        for document in documents {
            if let predecessorID = document.supersedes {
                guard let predecessor = documentsByID[predecessorID],
                      predecessor.scope == document.scope,
                      predecessor.revision < UInt64.max,
                      document.revision == predecessor.revision + 1,
                      predecessor.createdAt == document.createdAt else {
                    throw MemoryKnowledgeError.invalidRevisionGraph
                }
            }
        }
        return documents.filter { !supersededIDs.contains($0.id) }
    }

    private func readLastKnownGood(
        startingAt head: MemoryDocument,
        documentsByID: [MemoryDocumentID: MemoryDocument]
    ) async throws -> (
        snapshot: MemoryKnowledgeDocumentSnapshot,
        reference: AuthoritativeMarkdownReference
    ) {
        var current = head
        var unavailableRevision: UInt64?
        var visited: Set<MemoryDocumentID> = []

        while visited.insert(current.id).inserted {
            let reference = try AuthoritativeMarkdownReference(document: current)
            do {
                let validated = try await store.read(reference, inside: authority)
                return (
                    MemoryKnowledgeDocumentSnapshot(
                        document: current,
                        markdown: validated.markdown,
                        unavailableNewerRevision: unavailableRevision
                    ),
                    reference
                )
            } catch {
                unavailableRevision = unavailableRevision ?? head.revision
                // Quarantine is bounded to a proven-malformed, exact app-owned
                // authority file. Missing, raced, or otherwise unproven items
                // are left untouched and still fall back honestly.
                _ = try? await store.quarantine(reference, inside: authority)
                guard let predecessorID = current.supersedes,
                      let predecessor = documentsByID[predecessorID],
                      predecessor.scope == head.scope,
                      predecessor.revision < current.revision else {
                    throw MemoryKnowledgeError.contentUnavailable
                }
                current = predecessor
            }
        }
        throw MemoryKnowledgeError.invalidRevisionGraph
    }

    private func cache(_ workspace: CachedWorkspace) {
        let id = workspace.snapshot.id
        cachedWorkspaces[id] = workspace
        cacheOrder.removeAll(where: { $0 == id })
        cacheOrder.append(id)
        while cacheOrder.count > Self.maximumCachedWorkspaces {
            cachedWorkspaces.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func invalidateWorkspaceCache() {
        cachedWorkspaces.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }
}
