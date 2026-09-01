import Foundation
import Testing
@testable import OpenBotsDomain

@Test("Memory scope access requires the exact teammate, selected project, and active membership")
func memoryScopeAccessMatrix() {
    let mira = TeammateID(memoryDomainUUID(1))
    let ada = TeammateID(memoryDomainUUID(2))
    let atlas = ProjectID(memoryDomainUUID(3))
    let borealis = ProjectID(memoryDomainUUID(4))

    #expect(
        MemoryScope.user.isReadable(
            by: mira,
            selectedProjectID: nil,
            activeProjectMemberships: []
        )
    )
    #expect(
        MemoryScope.teammate(mira).isReadable(
            by: mira,
            selectedProjectID: nil,
            activeProjectMemberships: []
        )
    )
    #expect(
        !MemoryScope.teammate(ada).isReadable(
            by: mira,
            selectedProjectID: nil,
            activeProjectMemberships: []
        )
    )
    #expect(
        MemoryScope.project(atlas).isReadable(
            by: mira,
            selectedProjectID: atlas,
            activeProjectMemberships: [atlas, borealis]
        )
    )
    #expect(
        !MemoryScope.project(atlas).isReadable(
            by: mira,
            selectedProjectID: borealis,
            activeProjectMemberships: [atlas, borealis]
        )
    )
    #expect(
        !MemoryScope.project(atlas).isReadable(
            by: mira,
            selectedProjectID: atlas,
            activeProjectMemberships: []
        )
    )
    #expect(
        !MemoryScope.project(atlas).isReadable(
            by: mira,
            selectedProjectID: nil,
            activeProjectMemberships: [atlas]
        )
    )
}

@Test("A memory manifest cannot contain duplicate included identities or empty exclusion buckets")
func memoryContextManifestValidation() throws {
    let documentID = MemoryDocumentID(memoryDomainUUID(10))

    #expect(throws: DomainValidationError.self) {
        _ = try MemoryContextManifest(
            includedDocumentIDs: [documentID, documentID],
            exclusionCounts: [:]
        )
    }
    #expect(throws: DomainValidationError.self) {
        _ = try MemoryContextManifest(
            includedDocumentIDs: [],
            exclusionCounts: [.otherTeammate: 0]
        )
    }

    let valid = try MemoryContextManifest(
        includedDocumentIDs: [documentID],
        exclusionCounts: [.differentProject: 2]
    )
    #expect(valid.totalExcludedCount == 2)
}

private func memoryDomainUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a4100000-0000-0000-0000-%012llu", value))!
}
