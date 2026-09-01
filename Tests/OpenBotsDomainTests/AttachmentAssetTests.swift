import Foundation
import OpenBotsDomain
import Testing

@Suite("Immutable attachment metadata")
struct AttachmentAssetTests {
    @Test("Names and identifiers are bounded and path-free without silently rewriting text")
    func labels() throws {
        let valid = try asset(name: "  readable file 🐙.txt  ")
        #expect(valid.displayName == "  readable file 🐙.txt  ")
        #expect(try asset(name: "file\\name:revision.txt").displayName == "file\\name:revision.txt")
        for name in ["", " \n", ".", "..", "/tmp/file", "folder/file", "file\0tail", "a\nfile", String(repeating: "x", count: 256)] {
            #expect(throws: DomainValidationError.self) { try asset(name: name) }
        }
        for type in ["", "public data", "/public.data", "public.☁️", String(repeating: "x", count: 256)] {
            #expect(throws: DomainValidationError.self) { try asset(type: type) }
        }
    }

    @Test("Empty files and the provisional size limit are allowed; invalid sizes, hashes and clocks are not")
    func bounds() throws {
        #expect(try asset(bytes: 0).byteCount == 0)
        #expect(try asset(bytes: AttachmentAsset.provisionalMaximumByteCount).byteCount == 104_857_600)
        for bytes in [-1, AttachmentAsset.provisionalMaximumByteCount + 1, Int64.max] {
            #expect(throws: DomainValidationError.self) { try asset(bytes: bytes) }
        }
        for digest in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 64) + "\0x", String(repeating: "g", count: 64)] {
            #expect(throws: DomainValidationError.self) { try asset(digest: digest) }
        }
        for time in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(throws: DomainValidationError.self) { try asset(date: Date(timeIntervalSince1970: time)) }
        }
    }

    @Test("Decoding cannot bypass metadata validation and equality preserves exact filename bytes")
    func decoding() throws {
        let original = try asset()
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AttachmentAsset.self, from: encoded) == original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["displayName"] = "../escape"
        #expect(throws: DomainValidationError.self) {
            try JSONDecoder().decode(AttachmentAsset.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let decomposed = try AttachmentAsset(id: original.id, conversationID: original.conversationID, displayName: "e\u{301}.txt", typeIdentifier: original.typeIdentifier, byteCount: original.byteCount, sha256: original.sha256, createdAt: original.createdAt)
        let composed = try AttachmentAsset(id: original.id, conversationID: original.conversationID, displayName: "é.txt", typeIdentifier: original.typeIdentifier, byteCount: original.byteCount, sha256: original.sha256, createdAt: original.createdAt)
        #expect(decomposed != composed)
    }

    private func asset(name: String = "notes.txt", type: String = "public.plain-text", bytes: Int64 = 12, digest: String = String(repeating: "a", count: 64), date: Date = Date(timeIntervalSince1970: 100)) throws -> AttachmentAsset {
        try AttachmentAsset(id: AttachmentID(UUID()), conversationID: ConversationID(UUID()), displayName: name, typeIdentifier: type, byteCount: bytes, sha256: digest, createdAt: date)
    }
}
