import Foundation

/// The exact chat/work-context inputs used to request a knowledge view.
///
/// This is presentation state rather than repository authority. The injected
/// knowledge boundary independently applies the domain scope rules before it
/// returns any document content.
public struct KnowledgeWorkspaceContext: Equatable, Sendable {
    public let conversationID: UUID
    public let teammateID: UUID
    public let teammateName: String
    public let selectedProjectID: UUID?
    public let selectedProjectName: String?
    public let activeProjectMembershipIDs: Set<UUID>

    public init(
        conversationID: UUID,
        teammateID: UUID,
        teammateName: String,
        selectedProjectID: UUID?,
        selectedProjectName: String?,
        activeProjectMembershipIDs: Set<UUID>
    ) {
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.teammateName = teammateName
        self.selectedProjectID = selectedProjectID
        self.selectedProjectName = selectedProjectName
        self.activeProjectMembershipIDs = activeProjectMembershipIDs
    }
}

public enum KnowledgeDocumentScopePresentation: Equatable, Hashable, Sendable {
    case user
    case teammate(id: UUID, name: String)
    case project(id: UUID, name: String)

    public var visibleLabel: String {
        switch self {
        case .user:
            "User memory"
        case .teammate(_, let name):
            "\(name)’s memory"
        case .project(_, let name):
            "\(name) project memory"
        }
    }

    public var compactLabel: String {
        switch self {
        case .user: "User"
        case .teammate: "Teammate"
        case .project: "Project"
        }
    }
}

public enum KnowledgeDocumentAuthorPresentation: Equatable, Hashable, Sendable {
    case user(displayName: String)
    case teammate(id: UUID, name: String)
    case system(label: String)

    public var visibleLabel: String {
        switch self {
        case .user(let displayName): displayName
        case .teammate(_, let name): name
        case .system(let label): label
        }
    }

    public var provenanceLabel: String {
        switch self {
        case .user:
            "Written by you"
        case .teammate(_, let name):
            "Written by \(name)"
        case .system(let label):
            "Written by \(label)"
        }
    }
}

/// Recovery is explicit rather than silently presenting an older revision as
/// current authority.
public enum KnowledgeDocumentRecoveryPresentation: Equatable, Sendable {
    case current
    case lastKnownGood(unavailableRevision: UInt64?, explanation: String)

    public var visibleLabel: String? {
        switch self {
        case .current:
            return nil
        case .lastKnownGood(let unavailableRevision, let explanation):
            let revision = unavailableRevision.map { "Revision \($0) could not be verified. " } ?? ""
            return revision + "Showing the last known good revision. " + explanation
        }
    }
}

/// Path-free, display-only content returned after the Services layer has
/// selected scope and validated the authoritative Markdown revision.
public struct KnowledgeDocumentPresentation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let scope: KnowledgeDocumentScopePresentation
    public let author: KnowledgeDocumentAuthorPresentation
    public let revision: UInt64
    public let updatedAt: Date
    public let markdown: String
    public let recovery: KnowledgeDocumentRecoveryPresentation
    public let canRevealInFinder: Bool

    public init(
        id: UUID,
        title: String,
        scope: KnowledgeDocumentScopePresentation,
        author: KnowledgeDocumentAuthorPresentation,
        revision: UInt64,
        updatedAt: Date,
        markdown: String,
        recovery: KnowledgeDocumentRecoveryPresentation = .current,
        canRevealInFinder: Bool = true
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.author = author
        self.revision = revision
        self.updatedAt = updatedAt
        self.markdown = markdown
        self.recovery = recovery
        self.canRevealInFinder = canRevealInFinder
    }

    public var accessibilityDescription: String {
        let recoveryDescription = recovery.visibleLabel.map { " \($0)" } ?? " Current verified revision."
        return "\(title). \(scope.visibleLabel). \(author.provenanceLabel). "
            + "Revision \(revision). Updated \(freshnessLabel). Authoritative OpenBots Markdown."
            + recoveryDescription
    }

    public var freshnessLabel: String {
        updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One scope-filtered read result. `id` identifies this exact assembled view
/// so a snapshot action cannot silently follow a later conversation switch.
public struct KnowledgeWorkspaceSnapshot: Identifiable, Equatable, Sendable {
    public static let defaultAuthorityLabel = "OpenBots authoritative Markdown"
    public static let defaultAuthorityDisclosure =
        "This app-owned Markdown is the source of truth. Obsidian snapshots are separate non-authoritative copies."

    public let id: UUID
    public let context: KnowledgeWorkspaceContext
    public let documents: [KnowledgeDocumentPresentation]
    public let authorityLabel: String
    public let authorityDisclosure: String
    public let excludedDocumentCount: Int

    public init(
        id: UUID,
        context: KnowledgeWorkspaceContext,
        documents: [KnowledgeDocumentPresentation],
        excludedDocumentCount: Int = 0
    ) {
        self.id = id
        self.context = context
        self.documents = documents
        authorityLabel = Self.defaultAuthorityLabel
        authorityDisclosure = Self.defaultAuthorityDisclosure
        self.excludedDocumentCount = excludedDocumentCount
    }

    public var containsRecoveredDocument: Bool {
        documents.contains { document in
            if case .lastKnownGood = document.recovery { return true }
            return false
        }
    }
}

public enum KnowledgeWorkspaceLoadState: Equatable, Sendable {
    case unavailable(reason: String)
    case idle
    case loading
    case ready(KnowledgeWorkspaceSnapshot)
    case failed(reason: String)
}

/// Opaque UI receipt for an exact destination already frozen by the injected
/// native-picker/capability boundary. The display path is intentionally shown
/// for confirmation; the token grants no filesystem authority by itself.
public struct KnowledgeSnapshotDestination: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let exactDisplayPath: String

    public init(id: UUID, exactDisplayPath: String) {
        self.id = id
        self.exactDisplayPath = exactDisplayPath
    }
}

public struct PendingKnowledgeSnapshot: Equatable, Sendable {
    public let workspaceSnapshotID: UUID
    public let destination: KnowledgeSnapshotDestination

    public init(
        workspaceSnapshotID: UUID,
        destination: KnowledgeSnapshotDestination
    ) {
        self.workspaceSnapshotID = workspaceSnapshotID
        self.destination = destination
    }
}

public struct KnowledgeSnapshotReceipt: Equatable, Sendable {
    public static let nonAuthoritativeDisclosure =
        "Snapshot created as a non-authoritative copy. Edits there do not flow back to OpenBots."

    public let exactDisplayPath: String
    public let documentCount: Int
    public let createdAt: Date
    public let disclosure: String

    public init(
        exactDisplayPath: String,
        documentCount: Int,
        createdAt: Date
    ) {
        self.exactDisplayPath = exactDisplayPath
        self.documentCount = documentCount
        self.createdAt = createdAt
        disclosure = Self.nonAuthoritativeDisclosure
    }
}
