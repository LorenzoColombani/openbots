import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Test("Memory selection has no cross-teammate or cross-project carryover", arguments: [
    MemorySelectionCase.miraAtlas,
    .adaAtlas,
    .miraBorealis,
    .adaBorealisWithoutMembership,
    .miraUnscoped
])
func memorySelectionMatrix(testCase: MemorySelectionCase) throws {
    let fixture = MemorySelectionFixture()
    let manifest = try MemoryContextSelectionService().manifest(
        candidates: fixture.candidates,
        request: testCase.request(fixture)
    )

    #expect(Set(manifest.includedDocumentIDs) == testCase.expectedIncluded(fixture))
    #expect(manifest.totalExcludedCount == fixture.candidates.count - manifest.includedDocumentIDs.count)
}

@Test("Sequential project selections are stateless and nil selection retains no project")
func sequentialMemorySelectionHasNoCarryover() throws {
    let fixture = MemorySelectionFixture()
    let service = MemoryContextSelectionService()

    let atlas = try service.manifest(
        candidates: fixture.candidates,
        request: MemorySelectionCase.miraAtlas.request(fixture)
    )
    let borealis = try service.manifest(
        candidates: fixture.candidates,
        request: MemorySelectionCase.miraBorealis.request(fixture)
    )
    let unscoped = try service.manifest(
        candidates: fixture.candidates,
        request: MemorySelectionCase.miraUnscoped.request(fixture)
    )

    #expect(atlas.includedDocumentIDs.contains(fixture.atlasMemory))
    #expect(!atlas.includedDocumentIDs.contains(fixture.borealisMemory))
    #expect(borealis.includedDocumentIDs.contains(fixture.borealisMemory))
    #expect(!borealis.includedDocumentIDs.contains(fixture.atlasMemory))
    #expect(!unscoped.includedDocumentIDs.contains(fixture.atlasMemory))
    #expect(!unscoped.includedDocumentIDs.contains(fixture.borealisMemory))
}

@Test("Excluded identities never appear in the encoded manifest or duplicate diagnostic")
func excludedMemoryIdentityDoesNotLeak() throws {
    let fixture = MemorySelectionFixture()
    let service = MemoryContextSelectionService()
    let manifest = try service.manifest(
        candidates: fixture.candidates,
        request: MemorySelectionCase.miraAtlas.request(fixture)
    )
    let encoded = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)

    #expect(!encoded.contains(fixture.adaMemory.persistedValue))
    #expect(!encoded.contains(fixture.borealisMemory.persistedValue))
    #expect(encoded.contains(fixture.userMemory.persistedValue))

    var diagnostic = ""
    do {
        _ = try service.manifest(
            candidates: [
                MemoryContextCandidate(documentID: fixture.adaMemory, scope: .teammate(fixture.ada)),
                MemoryContextCandidate(documentID: fixture.adaMemory, scope: .project(fixture.borealis))
            ],
            request: MemorySelectionCase.miraAtlas.request(fixture)
        )
        Issue.record("Expected duplicate candidate rejection")
    } catch {
        diagnostic = String(describing: error)
    }
    #expect(diagnostic == "duplicateCandidateIdentity")
    #expect(!diagnostic.contains(fixture.adaMemory.persistedValue))
}

enum MemorySelectionCase: Sendable {
    case miraAtlas
    case adaAtlas
    case miraBorealis
    case adaBorealisWithoutMembership
    case miraUnscoped

    func request(_ fixture: MemorySelectionFixture) -> MemoryContextRequest {
        switch self {
        case .miraAtlas:
            MemoryContextRequest(
                teammateID: fixture.mira,
                selectedProjectID: fixture.atlas,
                activeProjectMemberships: [fixture.atlas, fixture.borealis]
            )
        case .adaAtlas:
            MemoryContextRequest(
                teammateID: fixture.ada,
                selectedProjectID: fixture.atlas,
                activeProjectMemberships: [fixture.atlas]
            )
        case .miraBorealis:
            MemoryContextRequest(
                teammateID: fixture.mira,
                selectedProjectID: fixture.borealis,
                activeProjectMemberships: [fixture.atlas, fixture.borealis]
            )
        case .adaBorealisWithoutMembership:
            MemoryContextRequest(
                teammateID: fixture.ada,
                selectedProjectID: fixture.borealis,
                activeProjectMemberships: [fixture.atlas]
            )
        case .miraUnscoped:
            MemoryContextRequest(
                teammateID: fixture.mira,
                selectedProjectID: nil,
                activeProjectMemberships: [fixture.atlas, fixture.borealis]
            )
        }
    }

    func expectedIncluded(_ fixture: MemorySelectionFixture) -> Set<MemoryDocumentID> {
        switch self {
        case .miraAtlas:
            [fixture.userMemory, fixture.miraMemory, fixture.atlasMemory]
        case .adaAtlas:
            [fixture.userMemory, fixture.adaMemory, fixture.atlasMemory]
        case .miraBorealis:
            [fixture.userMemory, fixture.miraMemory, fixture.borealisMemory]
        case .adaBorealisWithoutMembership:
            [fixture.userMemory, fixture.adaMemory]
        case .miraUnscoped:
            [fixture.userMemory, fixture.miraMemory]
        }
    }
}

struct MemorySelectionFixture: Sendable {
    let mira = TeammateID(memoryServiceUUID(1))
    let ada = TeammateID(memoryServiceUUID(2))
    let atlas = ProjectID(memoryServiceUUID(3))
    let borealis = ProjectID(memoryServiceUUID(4))
    let userMemory = MemoryDocumentID(memoryServiceUUID(10))
    let miraMemory = MemoryDocumentID(memoryServiceUUID(11))
    let adaMemory = MemoryDocumentID(memoryServiceUUID(12))
    let atlasMemory = MemoryDocumentID(memoryServiceUUID(13))
    let borealisMemory = MemoryDocumentID(memoryServiceUUID(14))

    var candidates: [MemoryContextCandidate] {
        [
            MemoryContextCandidate(documentID: userMemory, scope: .user),
            MemoryContextCandidate(documentID: miraMemory, scope: .teammate(mira)),
            MemoryContextCandidate(documentID: adaMemory, scope: .teammate(ada)),
            MemoryContextCandidate(documentID: atlasMemory, scope: .project(atlas)),
            MemoryContextCandidate(documentID: borealisMemory, scope: .project(borealis))
        ]
    }
}

private func memoryServiceUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a4300000-0000-0000-0000-%012llu", value))!
}
