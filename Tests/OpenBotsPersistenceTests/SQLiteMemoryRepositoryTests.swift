import Foundation
import OpenBotsDomain
import XCTest
@testable import OpenBotsPersistence

final class SQLiteMemoryRepositoryTests: XCTestCase {
    private let receipt = try! ProtectionDecisionReceipt(
        decisionID: UUID(uuidString: "a4300000-0000-0000-0000-000000000001")!,
        selectedAt: Date(timeIntervalSince1970: 1_760_000_000),
        rationaleVersion: 1
    )

    func testAuthorityMetadataEnumerationAndDocumentsSurviveIdempotentReopen() async throws {
        let fixture = try MemoryStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 1_760_000_100)
        let userDocument = try makeDocument(value: 1, scope: .user, createdAt: createdAt)
        let projectDocument = try makeDocument(
            value: 2,
            scope: .project(ProjectID(memoryUUID(100))),
            createdAt: createdAt.addingTimeInterval(1)
        )

        do {
            let store = try fixture.open()
            let contract = try await store.authorityContract()
            let facts = try await store.runtimeFacts()
            XCTAssertEqual(contract, .appOwnedMarkdownV1)
            XCTAssertEqual(facts.migrationCount, 20)
            try await store.insert(userDocument)
            try await store.insert(projectDocument)
            let allDocumentIDs = Set(try await store.allDocuments().map(\.id))
            let userDocuments = try await store.documents(scope: .user)
            XCTAssertEqual(
                allDocumentIDs,
                [userDocument.id, projectDocument.id]
            )
            XCTAssertEqual(userDocuments, [userDocument])
        }

        let reopened = try fixture.open()
        let reopenedContract = try await reopened.authorityContract()
        let reopenedFacts = try await reopened.runtimeFacts()
        let reopenedDocumentIDs = Set(try await reopened.allDocuments().map(\.id))
        XCTAssertEqual(reopenedContract, .appOwnedMarkdownV1)
        XCTAssertEqual(reopenedFacts.migrationCount, 20)
        XCTAssertEqual(
            reopenedDocumentIDs,
            [userDocument.id, projectDocument.id]
        )
        let metadata = try await reopened.query(
            sql: "SELECT key,value FROM app_metadata WHERE key LIKE 'memory_authority_%' ORDER BY key;"
        )
        XCTAssertEqual(metadata.count, 3)
        XCTAssertEqual(
            try Dictionary(uniqueKeysWithValues: metadata.map { (try $0.text("key"), try $0.text("value")) }),
            [
                "memory_authority_kind": "app-owned-markdown-tree",
                "memory_authority_format_version": "1",
                "memory_authority_relative_root": "HighChurn.noindex/Memory",
            ]
        )
        try assertMode0600(at: fixture.databaseURL)
    }

    func testValidSuccessorChainSurvivesReopen() async throws {
        let fixture = try MemoryStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 1_760_000_200)
        let root = try makeDocument(value: 10, scope: .user, createdAt: createdAt)
        let successor = try makeDocument(
            value: 11,
            scope: root.scope,
            revision: 2,
            supersedes: root.id,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(10)
        )

        do {
            let store = try fixture.open()
            try await store.insert(root)
            try await store.insertRevision(successor, expectedPredecessorID: root.id)
        }

        let reopened = try fixture.open()
        let reopenedRoot = try await reopened.document(id: root.id)
        let reopenedSuccessor = try await reopened.document(id: successor.id)
        XCTAssertEqual(reopenedRoot, root)
        XCTAssertEqual(reopenedSuccessor, successor)
    }

    func testSuccessorValidationRejectsExpectedPredecessorScopeRevisionAndLineageMismatches() async throws {
        let fixture = try MemoryStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let createdAt = Date(timeIntervalSince1970: 1_760_000_300)
        let root = try makeDocument(value: 20, scope: .user, createdAt: createdAt)
        try await store.insert(root)

        let wrongExpected = MemoryDocumentID(memoryUUID(999))
        let expectedMismatch = try makeDocument(
            value: 21,
            scope: .user,
            revision: 2,
            supersedes: root.id,
            createdAt: createdAt
        )
        await assertRepositoryError(
            .optimisticLockFailed(entity: "memory predecessor", id: wrongExpected.persistedValue)
        ) {
            try await store.insertRevision(expectedMismatch, expectedPredecessorID: wrongExpected)
        }

        let scopeMismatch = try makeDocument(
            value: 22,
            scope: .project(ProjectID(memoryUUID(200))),
            revision: 2,
            supersedes: root.id,
            createdAt: createdAt
        )
        await assertRepositoryError(
            .unavailable(reason: "A memory successor must retain its predecessor's scope.")
        ) {
            try await store.insertRevision(scopeMismatch, expectedPredecessorID: root.id)
        }

        let revisionMismatch = try makeDocument(
            value: 23,
            scope: .user,
            revision: 3,
            supersedes: root.id,
            createdAt: createdAt
        )
        await assertRepositoryError(
            .optimisticLockFailed(entity: "memory revision", id: root.id.persistedValue)
        ) {
            try await store.insertRevision(revisionMismatch, expectedPredecessorID: root.id)
        }

        let timestampMismatch = try makeDocument(
            value: 24,
            scope: .user,
            revision: 2,
            supersedes: root.id,
            createdAt: createdAt.addingTimeInterval(1)
        )
        await assertRepositoryError(
            .unavailable(reason: "A memory successor must retain its logical document creation time.")
        ) {
            try await store.insertRevision(timestampMismatch, expectedPredecessorID: root.id)
        }

        let missingID = MemoryDocumentID(memoryUUID(998))
        let missingPredecessor = try makeDocument(
            value: 25,
            scope: .user,
            revision: 2,
            supersedes: missingID,
            createdAt: createdAt
        )
        await assertRepositoryError(.notFound(entity: "memory predecessor", id: missingID.persistedValue)) {
            try await store.insertRevision(missingPredecessor, expectedPredecessorID: missingID)
        }
        let remainingDocuments = try await store.allDocuments()
        XCTAssertEqual(remainingDocuments, [root])
    }

    func testConcurrentSuccessorRacePublishesExactlyOneBranch() async throws {
        let fixture = try MemoryStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let firstStore = try fixture.open()
        let secondStore = try fixture.open()
        let createdAt = Date(timeIntervalSince1970: 1_760_000_400)
        let root = try makeDocument(value: 30, scope: .user, createdAt: createdAt)
        try await firstStore.insert(root)
        let firstCandidate = try makeDocument(
            value: 31,
            scope: .user,
            revision: 2,
            supersedes: root.id,
            createdAt: createdAt
        )
        let secondCandidate = try makeDocument(
            value: 32,
            scope: .user,
            revision: 2,
            supersedes: root.id,
            createdAt: createdAt
        )

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask {
                do {
                    try await firstStore.insertRevision(firstCandidate, expectedPredecessorID: root.id)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    try await secondStore.insertRevision(secondCandidate, expectedPredecessorID: root.id)
                    return true
                } catch {
                    return false
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 1)
        let documents = try await firstStore.allDocuments()
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(documents.filter { $0.supersedes == root.id }.count, 1)

        let indexRows = try await firstStore.query(
            sql: "SELECT name FROM sqlite_master WHERE type='index' AND name='memory_single_successor';"
        )
        XCTAssertEqual(indexRows.count, 1)
    }

    private func makeDocument(
        value: UInt64,
        scope: MemoryScope,
        revision: UInt64 = 1,
        supersedes: MemoryDocumentID? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) throws -> MemoryDocument {
        let id = MemoryDocumentID(memoryUUID(value))
        return try MemoryDocument(
            id: id,
            scope: scope,
            author: .system,
            title: "Memory \(value)",
            relativePath: "Documents/Test/\(id.persistedValue)-r\(revision).md",
            revision: revision,
            contentDigest: "sha256:\(value)-\(revision)",
            supersedes: supersedes,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt
        )
    }

    private func assertMode0600(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(mode, 0o600)
    }
}

private final class MemoryStoreFixture {
    let directory: URL
    let databaseURL: URL
    let receipt: ProtectionDecisionReceipt

    init(receipt: ProtectionDecisionReceipt) throws {
        self.receipt = receipt
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openbots-memory-repository-tests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: databaseURL,
                protection: .ordinarySQLite(decision: receipt)
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func assertRepositoryError(
    _ expected: RepositoryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected repository operation to fail with \(expected).")
    } catch let error as RepositoryError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("Expected RepositoryError, received \(error).")
    }
}

private func memoryUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a4300000-0000-0000-0000-%012llu", value))!
}
