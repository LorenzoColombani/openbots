import Foundation
import OpenBotsDomain

extension SQLiteStore: ProjectRepository {
    public func project(id: ProjectID) async throws -> Project? {
        try projectRows(whereClause: "id=?", bindings: [.text(id.persistedValue)]).first
    }

    public func listProjects(includingArchived: Bool) async throws -> [Project] {
        try projectRows(
            whereClause: includingArchived ? "1=1" : "lifecycle='active'",
            bindings: []
        )
    }

    public func insert(_ project: Project) async throws {
        try insertProjectRow(project)
    }

    /// Inserts only the project row. A caller that needs initial memberships
    /// must own a surrounding transaction and use the dedicated provisioning
    /// repository rather than publishing a partial aggregate.
    func insertProjectRow(_ project: Project) throws {
        _ = try execute(
            sql: "INSERT INTO projects(id,name,summary,lifecycle,created_at,updated_at) VALUES (?,?,?,?,?,?);",
            bindings: [
                .text(project.id.persistedValue), .text(project.name),
                project.summary.map(SQLiteBinding.text) ?? .null, .text(project.lifecycle.rawValue),
                .real(project.createdAt.timeIntervalSince1970), .real(project.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func update(_ project: Project) async throws {
        let changes = try execute(
            sql: "UPDATE projects SET name=?,summary=?,lifecycle=?,updated_at=? WHERE id=?;",
            bindings: [
                .text(project.name), project.summary.map(SQLiteBinding.text) ?? .null,
                .text(project.lifecycle.rawValue), .real(project.updatedAt.timeIntervalSince1970),
                .text(project.id.persistedValue)
            ]
        )
        guard changes == 1 else {
            throw RepositoryError.notFound(entity: "project", id: project.id.persistedValue)
        }
    }

    public func setMembership(_ membership: ProjectMembership) async throws {
        try transaction {
            if membership.revokedAt == nil {
                let active = try query(
                    sql: "SELECT joined_at FROM project_memberships WHERE project_id=? AND teammate_id=? AND revoked_at IS NULL;",
                    bindings: [.text(membership.projectID.persistedValue), .text(membership.teammateID.persistedValue)]
                )
                guard active.isEmpty else { return }
                _ = try execute(
                    sql: "INSERT INTO project_memberships(project_id,teammate_id,joined_at,revoked_at) VALUES (?,?,?,NULL);",
                    bindings: [
                        .text(membership.projectID.persistedValue), .text(membership.teammateID.persistedValue),
                        .real(membership.joinedAt.timeIntervalSince1970)
                    ]
                )
            } else {
                let changes = try execute(
                    sql: "UPDATE project_memberships SET revoked_at=? WHERE project_id=? AND teammate_id=? AND revoked_at IS NULL;",
                    bindings: [
                        .real(membership.revokedAt!.timeIntervalSince1970), .text(membership.projectID.persistedValue),
                        .text(membership.teammateID.persistedValue)
                    ]
                )
                guard changes == 1 else {
                    throw RepositoryError.notFound(
                        entity: "active project membership",
                        id: "\(membership.projectID.persistedValue)/\(membership.teammateID.persistedValue)"
                    )
                }
            }
        }
    }

    public func activeMemberIDs(projectID: ProjectID) async throws -> Set<TeammateID> {
        let rows = try query(
            sql: "SELECT teammate_id FROM project_memberships WHERE project_id=? AND revoked_at IS NULL;",
            bindings: [.text(projectID.persistedValue)]
        )
        return try Set(rows.map { try parseID(TeammateID.self, $0.text("teammate_id")) })
    }

    private func projectRows(whereClause: String, bindings: [SQLiteBinding]) throws -> [Project] {
        try query(
            sql: "SELECT * FROM projects WHERE \(whereClause) ORDER BY updated_at DESC,id;",
            bindings: bindings
        ).map { row in
            guard let lifecycle = DurableEntityLifecycle(rawValue: try row.text("lifecycle")) else {
                throw SQLiteStoreError.invalidRow(reason: "unknown project lifecycle")
            }
            return try Project(
                id: parseID(ProjectID.self, row.text("id")),
                name: row.text("name"),
                summary: row.optionalText("summary"),
                lifecycle: lifecycle,
                createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
            )
        }
    }
}

extension SQLiteStore: MemoryRepository {
    public func authorityContract() async throws -> MemoryAuthorityContract {
        let rows = try query(
            sql: """
            SELECT key,value FROM app_metadata
            WHERE key IN (
                'memory_authority_kind',
                'memory_authority_format_version',
                'memory_authority_relative_root'
            );
            """
        )
        let values = try Dictionary(
            uniqueKeysWithValues: rows.map { (try $0.text("key"), try $0.text("value")) }
        )
        let expected = MemoryAuthorityContract.appOwnedMarkdownV1
        guard values["memory_authority_kind"] == expected.kind.rawValue,
              values["memory_authority_format_version"] == String(expected.formatVersion),
              values["memory_authority_relative_root"] == expected.relativeRoot else {
            throw RepositoryError.unavailable(
                reason: "Memory authority metadata does not match the app-owned Markdown contract."
            )
        }
        return expected
    }

    public func document(id: MemoryDocumentID) async throws -> MemoryDocument? {
        try memoryRows(whereClause: "id=?", bindings: [.text(id.persistedValue)]).first
    }

    public func allDocuments() async throws -> [MemoryDocument] {
        try memoryRows(whereClause: "1=1", bindings: [])
    }

    public func documents(scope: MemoryScope) async throws -> [MemoryDocument] {
        let columns = memoryScopeColumns(scope)
        if let scopeID = columns.id {
            return try memoryRows(
                whereClause: "scope_kind=? AND scope_id=?",
                bindings: [.text(columns.kind), .text(scopeID)]
            )
        }
        return try memoryRows(
            whereClause: "scope_kind=? AND scope_id IS NULL",
            bindings: [.text(columns.kind)]
        )
    }

    public func insert(_ document: MemoryDocument) async throws {
        try insertRevisionRow(document, expectedPredecessorID: document.supersedes)
    }

    public func insertRevision(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) async throws {
        try insertRevisionRow(document, expectedPredecessorID: expectedPredecessorID)
    }

    private func insertRevisionRow(
        _ document: MemoryDocument,
        expectedPredecessorID: MemoryDocumentID?
    ) throws {
        guard document.supersedes == expectedPredecessorID else {
            throw RepositoryError.optimisticLockFailed(
                entity: "memory predecessor",
                id: expectedPredecessorID?.persistedValue ?? "initial"
            )
        }

        try transaction {
            if let expectedPredecessorID {
                guard let predecessor = try memoryRows(
                    whereClause: "id=?",
                    bindings: [.text(expectedPredecessorID.persistedValue)]
                ).first else {
                    throw RepositoryError.notFound(
                        entity: "memory predecessor",
                        id: expectedPredecessorID.persistedValue
                    )
                }
                guard predecessor.scope == document.scope else {
                    throw RepositoryError.unavailable(
                        reason: "A memory successor must retain its predecessor's scope."
                    )
                }
                guard predecessor.revision < UInt64.max,
                      document.revision == predecessor.revision + 1 else {
                    throw RepositoryError.optimisticLockFailed(
                        entity: "memory revision",
                        id: expectedPredecessorID.persistedValue
                    )
                }
                guard predecessor.createdAt == document.createdAt else {
                    throw RepositoryError.unavailable(
                        reason: "A memory successor must retain its logical document creation time."
                    )
                }
                let existingSuccessor = try query(
                    sql: "SELECT id FROM memory_documents WHERE supersedes_id=? LIMIT 1;",
                    bindings: [.text(expectedPredecessorID.persistedValue)]
                ).first
                guard existingSuccessor == nil else {
                    throw RepositoryError.optimisticLockFailed(
                        entity: "memory successor",
                        id: expectedPredecessorID.persistedValue
                    )
                }
            } else {
                guard document.revision == 1 else {
                    throw RepositoryError.optimisticLockFailed(
                        entity: "memory revision",
                        id: document.id.persistedValue
                    )
                }
            }
            try insertMemoryRow(document)
        }
    }

    private func insertMemoryRow(_ document: MemoryDocument) throws {
        let scope = memoryScopeColumns(document.scope)
        let author = memoryAuthorColumns(document.author)
        _ = try execute(
            sql: """
            INSERT INTO memory_documents(id,scope_kind,scope_id,author_kind,author_teammate_id,title,relative_path,
                revision,content_digest,supersedes_id,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """,
            bindings: [
                .text(document.id.persistedValue), .text(scope.kind), scope.id.map(SQLiteBinding.text) ?? .null,
                .text(author.kind), author.id.map(SQLiteBinding.text) ?? .null, .text(document.title),
                .text(document.relativePath), .integer(try checkedInt64(document.revision, field: "memory revision")),
                .text(document.contentDigest), document.supersedes.map { .text($0.persistedValue) } ?? .null,
                .real(document.createdAt.timeIntervalSince1970), .real(document.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private func memoryRows(whereClause: String, bindings: [SQLiteBinding]) throws -> [MemoryDocument] {
        try query(
            sql: "SELECT * FROM memory_documents WHERE \(whereClause) ORDER BY updated_at DESC,id;",
            bindings: bindings
        ).map { row in
            let scopeKind = try row.text("scope_kind")
            let scopeID = try row.optionalText("scope_id")
            let scope: MemoryScope
            switch (scopeKind, scopeID) {
            case ("user", nil): scope = .user
            case let ("teammate", .some(id)): scope = .teammate(try parseID(TeammateID.self, id))
            case let ("project", .some(id)): scope = .project(try parseID(ProjectID.self, id))
            default: throw SQLiteStoreError.invalidRow(reason: "memory scope is inconsistent")
            }
            let authorKind = try row.text("author_kind")
            let authorID = try row.optionalText("author_teammate_id")
            let author: MemoryAuthor
            switch (authorKind, authorID) {
            case ("user", nil): author = .user
            case ("system", nil): author = .system
            case let ("teammate", .some(id)): author = .teammate(try parseID(TeammateID.self, id))
            default: throw SQLiteStoreError.invalidRow(reason: "memory author is inconsistent")
            }
            return try MemoryDocument(
                id: parseID(MemoryDocumentID.self, row.text("id")),
                scope: scope,
                author: author,
                title: row.text("title"),
                relativePath: row.text("relative_path"),
                revision: try checkedUInt64(row.integer("revision"), field: "memory revision"),
                contentDigest: row.text("content_digest"),
                supersedes: try row.optionalText("supersedes_id").map { try parseID(MemoryDocumentID.self, $0) },
                createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
            )
        }
    }

    private func memoryScopeColumns(_ scope: MemoryScope) -> (kind: String, id: String?) {
        switch scope {
        case .user: ("user", nil)
        case let .teammate(id): ("teammate", id.persistedValue)
        case let .project(id): ("project", id.persistedValue)
        }
    }

    private func memoryAuthorColumns(_ author: MemoryAuthor) -> (kind: String, id: String?) {
        switch author {
        case .user: ("user", nil)
        case let .teammate(id): ("teammate", id.persistedValue)
        case .system: ("system", nil)
        }
    }
}
