import Foundation
import Testing
@testable import OpenBotsDomain

@Test("Memory revision one is an initial document and later revisions name a predecessor")
func memoryRevisionShapeValidation() throws {
    let createdAt = Date(timeIntervalSince1970: 1_760_000_000)
    let rootID = MemoryDocumentID(memoryRevisionUUID(1))

    let root = try makeMemoryDocument(
        id: rootID,
        revision: 1,
        supersedes: nil,
        createdAt: createdAt
    )
    #expect(root.revision == 1)
    #expect(root.supersedes == nil)

    let successor = try makeMemoryDocument(
        id: MemoryDocumentID(memoryRevisionUUID(2)),
        revision: 2,
        supersedes: rootID,
        createdAt: createdAt
    )
    #expect(successor.supersedes == rootID)

    #expect(throws: DomainValidationError.self) {
        _ = try makeMemoryDocument(
            id: MemoryDocumentID(memoryRevisionUUID(3)),
            revision: 1,
            supersedes: rootID,
            createdAt: createdAt
        )
    }
    #expect(throws: DomainValidationError.self) {
        _ = try makeMemoryDocument(
            id: MemoryDocumentID(memoryRevisionUUID(4)),
            revision: 2,
            supersedes: nil,
            createdAt: createdAt
        )
    }
}

@Test("The app-owned memory authority is relative, stable, and versioned")
func appOwnedMemoryAuthorityContract() {
    let contract = MemoryAuthorityContract.appOwnedMarkdownV1
    #expect(contract.kind == .appOwnedMarkdownTree)
    #expect(contract.formatVersion == 1)
    #expect(contract.relativeRoot == "HighChurn.noindex/Memory")
    #expect(!contract.relativeRoot.hasPrefix("/"))
    #expect(!contract.relativeRoot.split(separator: "/").contains(".."))
}

private func makeMemoryDocument(
    id: MemoryDocumentID,
    revision: UInt64,
    supersedes: MemoryDocumentID?,
    createdAt: Date
) throws -> MemoryDocument {
    try MemoryDocument(
        id: id,
        scope: .user,
        author: .user,
        title: "Working agreement",
        relativePath: "Documents/User/\(id.persistedValue)-r\(revision).md",
        revision: revision,
        contentDigest: "sha256:\(revision)",
        supersedes: supersedes,
        createdAt: createdAt,
        updatedAt: createdAt.addingTimeInterval(TimeInterval(revision - 1))
    )
}

private func memoryRevisionUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a4200000-0000-0000-0000-%012llu", value))!
}
