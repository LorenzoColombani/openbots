import CryptoKit
import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("ProfilePhotoServiceTests")
struct ProfilePhotoServiceTests {
    @Test("Construction is inert; import verifies published bytes before inserting metadata")
    func importOrdering() async throws {
        let tape = PhotoServiceTape()
        let repository = PhotoServiceRepository(tape: tape)
        let bytes = Data("normalized image fixture".utf8)
        let id = ProfileAssetID(UUID())
        let asset = try photoServiceAsset(id: id, data: bytes)
        let source = URL(fileURLWithPath: "/explicit-picker/photo.png")
        let service = ProfilePhotoService(
            repository: repository,
            importer: { url, receivedID in
                #expect(url == source)
                #expect(receivedID == id)
                await tape.append("publish")
                return asset
            },
            reader: { received in
                #expect(received == asset)
                await tape.append("verify bytes")
                return bytes
            },
            uuidGenerator: PhotoServiceUUID(value: id.rawValue)
        )
        #expect(await tape.events.isEmpty)
        #expect(try await service.importPhoto(from: source) == asset)
        #expect(await tape.events == ["publish", "verify bytes", "insert metadata"])
        #expect(try await service.imageData(id: id) == bytes)
        try await service.validatePhoto(id: id)
        #expect(await repository.insertCount == 1)
    }

    @Test("Wrong receipt identity never reads bytes or writes metadata")
    func wrongReceiptIdentity() async throws {
        let tape = PhotoServiceTape()
        let repository = PhotoServiceRepository(tape: tape)
        let bytes = Data([1, 2, 3])
        let wrongAsset = try photoServiceAsset(id: ProfileAssetID(UUID()), data: bytes)
        let service = ProfilePhotoService(repository: repository, importer: { _, _ in wrongAsset }, reader: { _ in
            await tape.append("unexpected read")
            return bytes
        })
        await #expect(throws: ProfilePhotoServiceError.invalidReceipt) {
            try await service.importPhoto(from: URL(fileURLWithPath: "/picked.png"))
        }
        #expect(await tape.events.isEmpty)
        #expect(await repository.insertCount == 0)
    }

    @Test("Byte count and same-length digest mismatch both reject a published receipt")
    func corruptedPublishedBytes() async throws {
        let expected = Data([1, 2, 3])
        for corrupted in [Data([1]), Data([3, 2, 1])] {
            let repository = PhotoServiceRepository(tape: PhotoServiceTape())
            let service = ProfilePhotoService(repository: repository, importer: { _, id in
                try photoServiceAsset(id: id, data: expected)
            }, reader: { _ in corrupted })
            await #expect(throws: ProfilePhotoServiceError.contentMismatch) {
                try await service.importPhoto(from: URL(fileURLWithPath: "/picked.png"))
            }
            #expect(await repository.insertCount == 0)
        }
    }

    @Test("Metadata failure is surfaced without retry or destructive rollback")
    func insertFailure() async throws {
        let tape = PhotoServiceTape()
        let repository = PhotoServiceRepository(tape: tape, failInsert: true)
        let bytes = Data([1])
        let service = ProfilePhotoService(repository: repository, importer: { _, id in
            await tape.append("publish")
            return try photoServiceAsset(id: id, data: bytes)
        }, reader: { _ in bytes })
        await #expect(throws: PhotoServiceTestError.rejected) {
            try await service.importPhoto(from: URL(fileURLWithPath: "/picked.png"))
        }
        #expect(await repository.insertCount == 1)
        #expect(await tape.events == ["publish", "insert metadata"])
        // There is deliberately no external deletion/rollback capability in
        // this service. The unreferenced owned immutable image can remain.
    }

    @Test("Missing metadata, mismatched identity and corrupted reads cannot become profile images")
    func invalidRead() async throws {
        let bytes = Data([1, 2])
        let id = ProfileAssetID(UUID())
        let asset = try photoServiceAsset(id: id, data: bytes)
        for stored in [nil, try photoServiceAsset(id: ProfileAssetID(UUID()), data: bytes)] {
            let tape = PhotoServiceTape()
            let repository = PhotoServiceRepository(tape: tape, value: stored)
            let service = ProfilePhotoService(repository: repository, importer: { _, _ in asset }, reader: { _ in
                await tape.append("unexpected read")
                return bytes
            })
            await #expect(throws: ProfilePhotoServiceError.unavailable) { try await service.imageData(id: id) }
            #expect(await tape.events.isEmpty)
        }
        let repository = PhotoServiceRepository(tape: PhotoServiceTape(), value: asset)
        let service = ProfilePhotoService(repository: repository, importer: { _, _ in asset }, reader: { _ in Data([2, 1]) })
        await #expect(throws: ProfilePhotoServiceError.contentMismatch) { try await service.validatePhoto(id: id) }
    }

    @Test("Cancellation after publication does not link metadata or clean up the picked source")
    func cancelledBeforeMetadata() async throws {
        let tape = PhotoServiceTape()
        let repository = PhotoServiceRepository(tape: tape)
        let bytes = Data([1])
        let gate = PhotoServiceGate()
        let service = ProfilePhotoService(repository: repository, importer: { _, id in
            await gate.wait()
            return try photoServiceAsset(id: id, data: bytes)
        }, reader: { _ in bytes })
        let task = Task { try await service.importPhoto(from: URL(fileURLWithPath: "/picked.png")) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await repository.insertCount == 0)
    }
}

private struct PhotoServiceUUID: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private actor PhotoServiceTape {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private enum PhotoServiceTestError: Error { case rejected }

private actor PhotoServiceRepository: ProfilePhotoRepository {
    let tape: PhotoServiceTape
    let failInsert: Bool
    var value: ProfilePhotoAsset?
    private(set) var insertCount = 0
    init(tape: PhotoServiceTape, failInsert: Bool = false, value: ProfilePhotoAsset? = nil) {
        self.tape = tape; self.failInsert = failInsert; self.value = value
    }
    func asset(id: ProfileAssetID) async throws -> ProfilePhotoAsset? { value }
    func insertAsset(_ asset: ProfilePhotoAsset) async throws {
        insertCount += 1
        await tape.append("insert metadata")
        if failInsert { throw PhotoServiceTestError.rejected }
        value = asset
    }
}

private actor PhotoServiceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entryWaiters.forEach { $0.resume() }; entryWaiters = []
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func photoServiceAsset(id: ProfileAssetID, data: Data) throws -> ProfilePhotoAsset {
    try ProfilePhotoAsset(id: id, width: 1, height: 1, byteCount: data.count,
                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
}
