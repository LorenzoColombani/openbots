import CryptoKit
import Foundation
import OpenBotsDomain

public enum KnowledgeSnapshotError: Error, Equatable, Sendable {
    case noSources
    case invalidTitle
    case invalidRevision
    case invalidDigest
    case invalidRecoveryStatus
    case sharingDenied
    case boundsExceeded
}

public enum KnowledgeSnapshotPurpose: Equatable, Sendable { case ownerInspection, qualifiedSharing }

public enum KnowledgeSnapshotRevisionStatus: Equatable, Sendable {
    case current
    case lastKnownGood(unavailableNewerRevision: UInt64)
}

public struct KnowledgeSnapshotSource: Equatable, Sendable {
    public let documentID: MemoryDocumentID
    public let title: String
    public let scope: MemoryScope
    public let author: MemoryAuthor
    public let revision: UInt64
    public let contentDigest: String
    public let updatedAt: Date
    public let revisionStatus: KnowledgeSnapshotRevisionStatus
    public let markdown: String

    public init(
        documentID: MemoryDocumentID,
        title: String,
        scope: MemoryScope,
        author: MemoryAuthor,
        revision: UInt64,
        contentDigest: String,
        updatedAt: Date,
        revisionStatus: KnowledgeSnapshotRevisionStatus,
        markdown: String
    ) throws {
        let normalizedTitle = title
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !normalizedTitle.isEmpty else { throw KnowledgeSnapshotError.invalidTitle }
        guard revision > 0 else { throw KnowledgeSnapshotError.invalidRevision }
        guard Self.isSHA256(contentDigest) else { throw KnowledgeSnapshotError.invalidDigest }
        if case let .lastKnownGood(unavailableNewerRevision) = revisionStatus {
            guard unavailableNewerRevision > revision else {
                throw KnowledgeSnapshotError.invalidRecoveryStatus
            }
        }
        self.documentID = documentID
        self.title = normalizedTitle
        self.scope = scope
        self.author = author
        self.revision = revision
        self.contentDigest = contentDigest
        self.updatedAt = updatedAt
        self.revisionStatus = revisionStatus
        self.markdown = markdown
    }

    fileprivate var sortKey: String {
        "\(scopeLabel)|\(documentID.persistedValue)|\(String(format: "%020llu", revision))"
    }

    fileprivate var scopeLabel: String {
        switch scope {
        case .user:
            "User"
        case let .teammate(teammateID):
            "Teammate \(teammateID.persistedValue)"
        case let .project(projectID):
            "Project \(projectID.persistedValue)"
        }
    }

    fileprivate var authorProvenanceLabel: String {
        switch author {
        case .user:
            "User"
        case let .teammate(teammateID):
            "Teammate \(teammateID.persistedValue)"
        case .system:
            "OpenBots system"
        }
    }

    fileprivate var revisionStatusLabel: String {
        switch revisionStatus {
        case .current:
            "Current authoritative revision"
        case let .lastKnownGood(unavailableNewerRevision):
            "Last known good; newer revision \(unavailableNewerRevision) is unavailable"
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct NonAuthoritativeKnowledgeSnapshot: Equatable, Sendable {
    public let markdown: String
    public let data: Data
    public let contentDigest: String
    public let suggestedFileName: String
    public let generatedAt: Date
    public let sourceCount: Int
    /// Inspection is not dissemination authority. The sharing broker must also
    /// revalidate these exact sources and the destination grant before writing.
    public let purpose: KnowledgeSnapshotPurpose
    public let sources: [KnowledgeSnapshotSource]
    public let claimReferences: [MemoryClaimReference]

    public let isAuthoritative = false
    public let supportsWriteBack = false
}

/// Pure rendering only. Inspection data is not dissemination authority. Sharing
/// must pass the app's source/evidence policy and exact-target delivery broker;
/// this type never opens a picker, writes a file, or grants permission.
public struct KnowledgeSnapshotRenderer: Sendable {
    public init() {}

    public func render(
        sources: [KnowledgeSnapshotSource],
        generatedAt: Date
    ) throws -> NonAuthoritativeKnowledgeSnapshot {
        try render(sources: sources, originals: sources, references: [], purpose: .ownerInspection, generatedAt: generatedAt)
    }

    /// Pure, deterministic projection, not authority. Every complete quoted
    /// unit retains its qualification; legacy/raw/low content has no share path.
    public func renderQualifiedSharing(sources: [KnowledgeSnapshotSource],
                                       generatedAt: Date) throws -> NonAuthoritativeKnowledgeSnapshot {
        guard !sources.isEmpty, sources.count <= 16, generatedAt.timeIntervalSince1970.isFinite,
              Set(sources.map(\.documentID)).count == sources.count else { throw KnowledgeSnapshotError.boundsExceeded }
        var references: [MemoryClaimReference] = []
        let projected = try sources.sorted { $0.sortKey < $1.sortKey }.map { source in
            guard source.revisionStatus == .current, source.markdown.utf8.count <= 16_384,
                  MemoryClaimDigests.bytes(Data(source.markdown.utf8)) == source.contentDigest,
                  let artifact = MemoryClaimCodec().decode(Data(source.markdown.utf8)).artifact,
                  artifact.hasKnownSemantics, artifact.documentID == source.documentID,
                  artifact.revision == source.revision, artifact.scope == source.scope else { throw KnowledgeSnapshotError.sharingDenied }
            try artifact.validate()
            let units = try artifact.claims.map { claim in
                guard claim.validity == .active,
                      claim.assessment.level == .confirmed || claim.assessment.level == .supportedInference else {
                    throw KnowledgeSnapshotError.sharingDenied
                }
                references.append(MemoryClaimReference(documentID: artifact.documentID, documentRevision: artifact.revision,
                    contentDigest: source.contentDigest, claimID: claim.id, claimDigest: try MemoryClaimDigests.claim(claim),
                    subjectDigest: try MemoryClaimDigests.subject(claim, scope: artifact.scope)))
                let origin = claim.provenance.allSatisfy { $0.kind == .userMessage } && !claim.provenance.isEmpty
                    ? "a checked user message" : "checked recorded sources"
                let statement = claim.assessment.level == .supportedInference
                    ? "From \(origin), \(try Self.quoted(claim.body)) seems plausible, but may be wrong."
                    : "Well supported for now, but still revisable: \(try Self.quoted(claim.body))."
                var unit = statement + " Recorded basis: " + (try Self.quoted(claim.assessment.basis)) + ". Source: " + origin + "."
                if let observed = claim.observedAt { unit += " Observed: " + Self.iso8601(observed) + "." }
                if let assessed = claim.assessment.assessedAt { unit += " Assessed: " + Self.iso8601(assessed) + "." }
                if let conditions = claim.conditions { unit += " Only when " + (try Self.quoted(conditions)) + "." }
                if let from = claim.validFrom { unit += " Valid from " + Self.iso8601(from) + "." }
                if let until = claim.validUntil { unit += " Valid before " + Self.iso8601(until) + "." }
                // JSON quoting escapes line/control boundaries. Indented Markdown
                // keeps HTML, links and source punctuation literal in this unit.
                return "    " + unit
            }
            return try KnowledgeSnapshotSource(documentID: source.documentID, title: source.title, scope: source.scope,
                author: source.author, revision: source.revision, contentDigest: source.contentDigest,
                updatedAt: source.updatedAt, revisionStatus: source.revisionStatus, markdown: units.joined(separator: "\n\n"))
        }
        guard references.count <= 256 else { throw KnowledgeSnapshotError.boundsExceeded }
        let result = try render(sources: projected, originals: sources, references: references,
            purpose: .qualifiedSharing, generatedAt: generatedAt)
        guard result.data.count <= 524_288 else { throw KnowledgeSnapshotError.boundsExceeded }
        return result
    }

    private func render(sources: [KnowledgeSnapshotSource], originals: [KnowledgeSnapshotSource],
                        references: [MemoryClaimReference], purpose: KnowledgeSnapshotPurpose,
                        generatedAt: Date) throws -> NonAuthoritativeKnowledgeSnapshot {
        guard !sources.isEmpty else { throw KnowledgeSnapshotError.noSources }
        let timestamp = Self.iso8601(generatedAt)
        let ordered = sources.sorted { $0.sortKey < $1.sortKey }
        let recoveredSourceCount = ordered.reduce(into: 0) { count, source in
            if case .lastKnownGood = source.revisionStatus { count += 1 }
        }
        var lines = [
            "# OpenBots Knowledge Snapshot",
            "",
            "> **Non-authoritative snapshot.** The authoritative Markdown remains inside OpenBots.",
            "> Edits to this snapshot do not flow back to OpenBots.",
            "",
            "- Generated: \(timestamp)",
            "- Sources: \(ordered.count)",
            "- Last-known-good sources: \(recoveredSourceCount)",
            ""
        ]

        for (index, source) in ordered.enumerated() {
            if index > 0 {
                lines.append(contentsOf: ["", "---", ""])
            }
            lines.append(contentsOf: [
                purpose == .qualifiedSharing ? "## Memory source \(index + 1)" : "## \(source.title)",
                ""
            ])
            if purpose == .qualifiedSharing {
                lines.append(contentsOf: ["    Source title: \(try Self.quoted(source.title))", ""])
            }
            lines.append(contentsOf: [
                "- Source document UUID: `\(source.documentID.persistedValue)`",
                "- Scope: \(source.scopeLabel)",
                "- Author/provenance: \(source.authorProvenanceLabel)",
                "- Source updated: \(Self.iso8601(source.updatedAt))",
                "- Revision: \(source.revision)",
                "- Revision status: \(source.revisionStatusLabel)",
                "- Source SHA-256: `\(source.contentDigest)`",
                "",
                source.markdown
            ])
        }
        if lines.last != "" { lines.append("") }

        let markdown = lines.joined(separator: "\n")
        let data = Data(markdown.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let safeTimestamp = timestamp.filter { $0.isNumber || $0 == "T" || $0 == "Z" }
        return NonAuthoritativeKnowledgeSnapshot(
            markdown: markdown,
            data: data,
            contentDigest: digest,
            suggestedFileName: "OpenBots-Knowledge-Snapshot-\(safeTimestamp).md",
            generatedAt: generatedAt,
            sourceCount: ordered.count,
            purpose: purpose,
            sources: originals.sorted { $0.sortKey < $1.sortKey },
            claimReferences: references
        )
    }

    private static func quoted(_ value: String) throws -> String {
        let quoted = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        var literal = ""
        for scalar in quoted.unicodeScalars {
            switch scalar.value {
            case 0x2028...0x202E, 0x2066...0x2069:
                literal += "\\u" + String(format: "%04x", scalar.value)
            default: literal.unicodeScalars.append(scalar)
            }
        }
        return literal
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
