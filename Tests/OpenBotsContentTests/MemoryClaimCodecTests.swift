import Foundation
import Testing
import OpenBotsDomain
@testable import OpenBotsContent

@Test("Claim codec binds multiple complete claims without rewriting exact statement bytes")
func memoryClaimCodecRoundTripsCompleteUnits() throws {
    let codec = MemoryClaimCodec()
    let artifact = memoryCodecArtifact(bodies: ["  Cafe\u{301}\nNot every day.\n", "A second claim with ``` and \"quotes\"."])
    let bytes = try codec.encode(artifact)
    let result = codec.decode(bytes)
    #expect(result.status == .claims)
    #expect(result.originalBytes == bytes)
    #expect(result.artifact == artifact)
    let reopened = try #require(result.artifact)
    #expect(reopened.claims[0].body.utf8.elementsEqual(artifact.claims[0].body.utf8))
    let reference = try codec.reference(for: artifact.claims[0].id, in: result)
    #expect(reference.contentDigest == MemoryClaimDigests.bytes(bytes))
    #expect(reference.claimDigest == (try MemoryClaimDigests.claim(artifact.claims[0])))
    #expect(reference.subjectDigest == (try MemoryClaimDigests.subject(artifact.claims[0], scope: artifact.scope)))
    #expect(reference.contentDigest.count == 64)
}

@Test("Legacy Markdown retains all bytes and never infers confirmation from prose")
func memoryClaimCodecLegacyIsUnassessed() {
    let codec = MemoryClaimCodec()
    let bytes = Data("  # CONFIRMED\r\n\r\nconfidence: 100%\nThe user confirmed this.  \n".utf8)
    let result = codec.decode(bytes)
    #expect(result.status == .legacy)
    #expect(result.originalBytes == bytes)
    #expect(result.artifact == nil)
    #expect(result.unrecognizedAssessment == .unassessed)
}

@Test("Future versions, unknown assessment and provenance remain exact and nonpermissive")
func memoryClaimCodecRetainsUnknownSemantics() throws {
    let codec = MemoryClaimCodec()
    let original = try codec.encode(memoryCodecArtifact())
    let text = try #require(String(data: original, encoding: .utf8))
    let future = Data(text.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2").utf8)
    let unknown = Data(text.replacingOccurrences(of: "\"level\":\"uncertain\"", with: "\"level\":\"absolute-truth\"").utf8)
    let unknownSource = Data(text.replacingOccurrences(of: "\"kind\":\"model-inference\"", with: "\"kind\":\"future-source\"").utf8)
    for bytes in [future, unknown, unknownSource] {
        let result = codec.decode(bytes)
        #expect(result.status == .unsupported)
        #expect(result.originalBytes == bytes)
        #expect(result.artifact == nil)
    }
}

@Test("Missing, extra, duplicate and trailing metadata cannot be silently ignored")
func memoryClaimCodecRejectsAmbiguousOrIncompleteFraming() throws {
    let codec = MemoryClaimCodec()
    let artifact = memoryCodecArtifact()
    let bytes = try codec.encode(artifact)
    let canonical = try #require(String(data: MemoryClaimDigests.canonicalData(artifact), encoding: .utf8))
    let extra = "{\"unrecognizedRestriction\":\"never use this\"," + canonical.dropFirst()
    let duplicate = "{\"formatVersion\":1," + canonical.dropFirst()
    var object = try #require(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
    var claims = try #require(object["claims"] as? [[String: Any]])
    claims[0].removeValue(forKey: "provenance")
    object["claims"] = claims
    let missing = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let inputs = [Data((MemoryClaimCodec.header + extra + MemoryClaimCodec.footer).utf8),
                  Data((MemoryClaimCodec.header + duplicate + MemoryClaimCodec.footer).utf8),
                  Data(MemoryClaimCodec.header.utf8) + missing + Data(MemoryClaimCodec.footer.utf8),
                  bytes + Data("A detached unqualified statement".utf8), Data(bytes.dropLast(5))]
    for input in inputs {
        let result = codec.decode(input)
        #expect(result.status == .malformed)
        #expect(result.originalBytes == input)
        #expect(result.artifact == nil)
    }
}

@Test("Codec bounds include metadata and preserve invalid UTF8 without exposing claims")
func memoryClaimCodecBoundsAndMalformedBytes() throws {
    let artifact = memoryCodecArtifact(bodies: [String(repeating: "é", count: 100)])
    let bytes = try MemoryClaimCodec().encode(artifact)
    #expect(throws: MemoryClaimCodecError.self) { _ = try MemoryClaimCodec(maximumBytes: bytes.count - 1).encode(artifact) }
    let oversized = MemoryClaimCodec(maximumBytes: bytes.count - 1).decode(bytes)
    #expect(oversized.status == .oversized)
    #expect(oversized.originalBytes == bytes)
    let invalid = Data([0xff, 0xfe, 0x80])
    #expect(MemoryClaimCodec().decode(invalid).status == .malformed)
    #expect(MemoryClaimCodec().decode(invalid).originalBytes == invalid)
}

@Test("Catalog binding rejects wrong scope or document identity even when file digest matches")
func memoryClaimCodecRequiresExactCatalogBinding() throws {
    let codec = MemoryClaimCodec()
    let artifact = memoryCodecArtifact()
    let bytes = try codec.encode(artifact)
    let digest = MemoryClaimDigests.bytes(bytes)
    func document(_ scope: MemoryScope, _ id: MemoryDocumentID) throws -> MemoryDocument {
        try MemoryDocument(id: id, scope: scope, author: .user, title: "Claim fixture",
            relativePath: "Documents/fixture.md", revision: 1, contentDigest: digest,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    #expect(codec.decode(bytes, expecting: try document(artifact.scope, artifact.documentID)).status == .claims)
    #expect(codec.decode(bytes, expecting: try document(.user, artifact.documentID)).status == .malformed)
    #expect(codec.decode(bytes, expecting: try document(artifact.scope, MemoryDocumentID(UUID()))).status == .malformed)
    #expect(throws: MemoryClaimCodecError.self) {
        _ = try codec.reference(for: artifact.claims[0], in: artifact, contentDigest: String(repeating: "0", count: 64))
    }
}

private func memoryCodecArtifact(bodies: [String] = ["Might prefer quiet places."]) -> MemoryClaimArtifact {
    let scope = MemoryScope.teammate(TeammateID(UUID()))
    let time = Date(timeIntervalSince1970: 1_780_000_000)
    let claims = bodies.map { body in
        MemoryClaim(id: MemoryClaimID(UUID()), body: body,
            assessment: MemoryClaimAssessment(level: .uncertain, basis: "An inference, not verified evidence",
                                               assessor: .init(kind: .app, identity: "fixture"), assessedAt: time),
            provenance: [MemoryClaimSourceReference(id: UUID(), kind: .modelInference, sourceID: "synthetic-run",
                                                    contentDigest: String(repeating: "a", count: 64),
                                                    observedAt: time, scope: scope)],
            observedAt: time, conditions: "Only where relevant")
    }
    return MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: 1, scope: scope, claims: claims)
}
