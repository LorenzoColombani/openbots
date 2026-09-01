import Foundation
import XCTest
@testable import OpenBotsSecurity

final class KeychainPolicyTests: XCTestCase {
    func testTypedReferencesUseSeparateOpenBotsOnlyNamespaces() {
        let connectorID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let bindingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let database = KeychainItemReference.previewDatabaseEncryptionKey
        let connector = KeychainItemReference.previewConnectorSecret(
            connectorID: connectorID,
            bindingID: bindingID
        )

        XCTAssertEqual(database.purpose, .databaseEncryption)
        XCTAssertEqual(
            connector.purpose,
            .connectorSecret(connectorID: connectorID, bindingID: bindingID)
        )
        XCTAssertNotEqual(database.service, connector.service)
        XCTAssertNotEqual(database.account, connector.account)
        XCTAssertTrue(database.service.description.hasPrefix("com.lorenzocolombani.openbotsnext.preview."))
        XCTAssertTrue(connector.service.description.hasPrefix("com.lorenzocolombani.openbotsnext.preview."))
        XCTAssertFalse(database.service.description.contains("claude"))
        XCTAssertFalse(connector.service.description.contains("git"))
    }

    func testInMemoryKeychainPerformsCRUDWithoutRecordingSecretBytes() async throws {
        let reference = KeychainItemReference.previewDatabaseEncryptionKey
        let secret = Data(repeating: 0xA5, count: 32)
        let fake = InMemoryKeychainClient()

        let initial = try await fake.read(reference)
        XCTAssertNil(initial)
        try await fake.store(secret, at: reference)
        let loaded = try await fake.read(reference)
        XCTAssertEqual(loaded, secret)
        try await fake.delete(reference)
        let afterDelete = try await fake.read(reference)
        XCTAssertNil(afterDelete)

        let operations = await fake.recordedOperations()
        XCTAssertEqual(
            operations.map(\.kind),
            [.read, .store(byteCount: 32), .read, .delete, .read]
        )
        XCTAssertFalse(String(describing: operations).contains(secret.base64EncodedString()))
    }

    func testOrdinarySQLiteNeverCallsGeneratorOrKeychain() async throws {
        struct UnexpectedGeneratorCall: Error {}
        let fake = InMemoryKeychainClient()
        let coordinator = DatabaseKeyCoordinator(keychain: fake) {
            throw UnexpectedGeneratorCall()
        }

        let key = try await coordinator.loadOrCreateKey(for: .ordinarySQLite)
        XCTAssertNil(key)
        let operations = await fake.recordedOperations()
        XCTAssertEqual(operations, [])
        XCTAssertNil(DatabaseKeyPolicy().keyReference(for: .ordinarySQLite))
    }

    func testSQLCipherUsesOnlyDatabaseReferenceAndCreatesOnce() async throws {
        let generated = Data(repeating: 0x42, count: 32)
        let fake = InMemoryKeychainClient()
        let coordinator = DatabaseKeyCoordinator(keychain: fake) { generated }

        let first = try await coordinator.loadOrCreateKey(for: .sqlCipher)
        let second = try await coordinator.loadOrCreateKey(for: .sqlCipher)
        XCTAssertEqual(first, generated)
        XCTAssertEqual(second, generated)
        let operations = await fake.recordedOperations()
        XCTAssertEqual(
            operations,
            [
                KeychainOperation(reference: .previewDatabaseEncryptionKey, kind: .read),
                KeychainOperation(reference: .previewDatabaseEncryptionKey, kind: .store(byteCount: 32)),
                KeychainOperation(reference: .previewDatabaseEncryptionKey, kind: .read)
            ]
        )
    }

    func testInvalidGeneratedDatabaseKeyIsNotStored() async throws {
        let fake = InMemoryKeychainClient()
        let coordinator = DatabaseKeyCoordinator(keychain: fake) { Data(repeating: 0, count: 16) }

        do {
            _ = try await coordinator.loadOrCreateKey(for: .sqlCipher)
            XCTFail("Expected invalid key rejection")
        } catch {
            XCTAssertEqual(error as? DatabaseKeyCoordinatorError, .invalidGeneratedKeyLength(actual: 16))
        }
        let operations = await fake.recordedOperations()
        XCTAssertEqual(
            operations,
            [KeychainOperation(reference: .previewDatabaseEncryptionKey, kind: .read)]
        )
    }

    func testInvalidStoredDatabaseKeyFailsWithoutReplacement() async throws {
        let reference = KeychainItemReference.previewDatabaseEncryptionKey
        let fake = InMemoryKeychainClient(seed: [reference: Data(repeating: 0, count: 16)])
        let coordinator = DatabaseKeyCoordinator(keychain: fake) { Data(repeating: 1, count: 32) }

        do {
            _ = try await coordinator.loadOrCreateKey(for: .sqlCipher)
            XCTFail("Expected stored key rejection")
        } catch {
            XCTAssertEqual(error as? DatabaseKeyCoordinatorError, .invalidStoredKeyLength(actual: 16))
        }
        let operations = await fake.recordedOperations()
        XCTAssertEqual(operations, [KeychainOperation(reference: reference, kind: .read)])
    }
}
