import Foundation
import XCTest
import OpenBotsDomain
@testable import OpenBotsContent

final class KnowledgeSnapshotTests: XCTestCase {
    func testSnapshotIsDeterministicExplicitlyNonAuthoritativeAndTraceable() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_787_856_123.456)
        let userUpdatedAt = Date(timeIntervalSince1970: 1_787_800_000.125)
        let projectUpdatedAt = Date(timeIntervalSince1970: 1_787_810_000.5)
        let authorID = TeammateID(UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        let user = try KnowledgeSnapshotSource(
            documentID: MemoryDocumentID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            title: "User knowledge",
            scope: .user,
            author: .user,
            revision: 4,
            contentDigest: String(repeating: "a", count: 64),
            updatedAt: userUpdatedAt,
            revisionStatus: .current,
            markdown: "A user-authored note."
        )
        let project = try KnowledgeSnapshotSource(
            documentID: MemoryDocumentID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            title: "Project\nbrief",
            scope: .project(ProjectID(UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)),
            author: .teammate(authorID),
            revision: 2,
            contentDigest: String(repeating: "b", count: 64),
            updatedAt: projectUpdatedAt,
            revisionStatus: .lastKnownGood(unavailableNewerRevision: 3),
            markdown: "# Brief\n\nA project fact."
        )
        let renderer = KnowledgeSnapshotRenderer()
        let first = try renderer.render(sources: [user, project], generatedAt: generatedAt)
        let reordered = try renderer.render(sources: [project, user], generatedAt: generatedAt)

        XCTAssertEqual(first, reordered)
        XCTAssertFalse(first.isAuthoritative)
        XCTAssertFalse(first.supportsWriteBack)
        XCTAssertEqual(first.sourceCount, 2)
        XCTAssertTrue(first.markdown.contains("**Non-authoritative snapshot.**"))
        XCTAssertTrue(first.markdown.contains("Edits to this snapshot do not flow back to OpenBots."))
        XCTAssertTrue(first.markdown.contains("11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(first.markdown.contains("- Revision: 2"))
        XCTAssertTrue(first.markdown.contains(String(repeating: "b", count: 64)))
        XCTAssertTrue(first.markdown.contains("## Project brief"))
        XCTAssertTrue(first.markdown.contains("- Author/provenance: User"))
        XCTAssertTrue(
            first.markdown.contains(
                "- Author/provenance: Teammate 44444444-4444-4444-4444-444444444444"
            )
        )
        XCTAssertTrue(first.markdown.contains("- Source updated: 2026-08-27T03:06:40.125Z"))
        XCTAssertTrue(first.markdown.contains("- Source updated: 2026-08-27T05:53:20.500Z"))
        XCTAssertTrue(first.markdown.contains("- Revision status: Current authoritative revision"))
        XCTAssertTrue(
            first.markdown.contains(
                "- Revision status: Last known good; newer revision 3 is unavailable"
            )
        )
        XCTAssertTrue(first.markdown.contains("- Last-known-good sources: 1"))
        XCTAssertFalse(first.markdown.contains("/Users/"))
        XCTAssertTrue(first.suggestedFileName.hasPrefix("OpenBots-Knowledge-Snapshot-"))
        XCTAssertTrue(first.suggestedFileName.hasSuffix(".md"))
        XCTAssertEqual(first.contentDigest.count, 64)
        XCTAssertEqual(first.data, Data(first.markdown.utf8))
    }

    func testSnapshotRendererIsPureAndDoesNotCreateAFile() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsSnapshotPurity-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try KnowledgeSnapshotSource(
            documentID: MemoryDocumentID(UUID()),
            title: "Knowledge",
            scope: .user,
            author: .system,
            revision: 1,
            contentDigest: String(repeating: "c", count: 64),
            updatedAt: Date(timeIntervalSince1970: 0),
            revisionStatus: .current,
            markdown: "Readable Markdown"
        )
        _ = try KnowledgeSnapshotRenderer().render(sources: [source], generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testSnapshotRejectsMissingOrUntraceableSources() throws {
        XCTAssertThrowsError(
            try KnowledgeSnapshotRenderer().render(sources: [], generatedAt: Date())
        ) { error in
            XCTAssertEqual(error as? KnowledgeSnapshotError, .noSources)
        }
        XCTAssertThrowsError(
            try KnowledgeSnapshotSource(
                documentID: MemoryDocumentID(UUID()),
                title: "Knowledge",
                scope: .user,
                author: .user,
                revision: 1,
                contentDigest: "invalid",
                updatedAt: Date(timeIntervalSince1970: 0),
                revisionStatus: .current,
                markdown: "body"
            )
        ) { error in
            XCTAssertEqual(error as? KnowledgeSnapshotError, .invalidDigest)
        }

        XCTAssertThrowsError(
            try KnowledgeSnapshotSource(
                documentID: MemoryDocumentID(UUID()),
                title: "Recovered knowledge",
                scope: .user,
                author: .system,
                revision: 3,
                contentDigest: String(repeating: "d", count: 64),
                updatedAt: Date(timeIntervalSince1970: 0),
                revisionStatus: .lastKnownGood(unavailableNewerRevision: 3),
                markdown: "body"
            )
        ) { error in
            XCTAssertEqual(error as? KnowledgeSnapshotError, .invalidRecoveryStatus)
        }
    }
}
