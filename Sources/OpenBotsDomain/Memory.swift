import Foundation

public enum MemoryScope: Codable, Equatable, Sendable {
    case user
    case teammate(TeammateID)
    case project(ProjectID)

    public func isReadable(
        by teammateID: TeammateID,
        selectedProjectID: ProjectID?,
        activeProjectMemberships: Set<ProjectID>
    ) -> Bool {
        switch self {
        case .user:
            true
        case let .teammate(ownerID):
            ownerID == teammateID
        case let .project(projectID):
            projectID == selectedProjectID && activeProjectMemberships.contains(projectID)
        }
    }
}

public enum MemoryAuthor: Codable, Equatable, Sendable {
    case user
    case teammate(TeammateID)
    case system
}

public enum MemoryAuthorityKind: String, Codable, Equatable, Sendable {
    case appOwnedMarkdownTree = "app-owned-markdown-tree"
}

/// The structured receipt that binds SQLite metadata to the one authoritative
/// Markdown tree. The root is relative to the verified Application Support
/// root; persisting an absolute path would couple durable state to one Mac.
public struct MemoryAuthorityContract: Codable, Equatable, Sendable {
    public static let appOwnedMarkdownV1 = MemoryAuthorityContract(
        kind: .appOwnedMarkdownTree,
        formatVersion: 1,
        relativeRoot: "HighChurn.noindex/Memory"
    )

    public let kind: MemoryAuthorityKind
    public let formatVersion: UInt16
    public let relativeRoot: String

    private init(kind: MemoryAuthorityKind, formatVersion: UInt16, relativeRoot: String) {
        self.kind = kind
        self.formatVersion = formatVersion
        self.relativeRoot = relativeRoot
    }
}

public struct MemoryDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: MemoryDocumentID
    public let scope: MemoryScope
    public let author: MemoryAuthor
    public var title: String
    /// A UUID-owned relative content path. Absolute/local-user paths are never database authority.
    public let relativePath: String
    public let revision: UInt64
    public let contentDigest: String
    public let supersedes: MemoryDocumentID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: MemoryDocumentID,
        scope: MemoryScope,
        author: MemoryAuthor,
        title: String,
        relativePath: String,
        revision: UInt64,
        contentDigest: String,
        supersedes: MemoryDocumentID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard revision > 0 else {
            throw DomainValidationError.invalid(field: "memory revision", reason: "must be positive")
        }
        guard (revision == 1 && supersedes == nil) || (revision > 1 && supersedes != nil) else {
            throw DomainValidationError.invalid(
                field: "memory revision chain",
                reason: "revision 1 has no predecessor and every later revision has one"
            )
        }
        guard updatedAt >= createdAt else {
            throw DomainValidationError.invalid(field: "memory timestamps", reason: "updatedAt cannot precede createdAt")
        }
        let path = try DomainText.required(relativePath, field: "memory relative path", maximum: 1_024)
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw DomainValidationError.invalid(
                field: "memory relative path",
                reason: "must remain relative and traversal-free"
            )
        }
        self.id = id
        self.scope = scope
        self.author = author
        self.title = try DomainText.required(title, field: "memory title", maximum: 200)
        self.relativePath = path
        self.revision = revision
        self.contentDigest = try DomainText.required(contentDigest, field: "memory content digest", maximum: 128)
        self.supersedes = supersedes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
