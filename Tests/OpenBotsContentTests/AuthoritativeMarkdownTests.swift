import Darwin
import Foundation
import XCTest
import OpenBotsDomain
@testable import OpenBotsContent

final class AuthoritativeMarkdownTests: XCTestCase {
    func testIntentRecoveryPublishesOnlyItsExactStagingFileAndIsIdempotent() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let operationID = UUID()
        let request = try AuthoritativeMarkdownPublicationRequest(documentID: MemoryDocumentID(UUID()),
            scope: .teammate(TeammateID(UUID())), revision: 1, markdown: "A complete qualified claim.",
            authority: fixture.authority, operationID: operationID)
        let store = AuthoritativeMarkdownStore()
        let publication = try await store.publish(request)
        let staging = fixture.authority.url.appending(path: try AuthoritativeMarkdownPath.stagingRelativePath(
            documentID: request.documentID, scope: request.scope, revision: request.revision,
            operationID: operationID))
        // Disposable fixture simulates a process ending after fsync, before rename.
        try FileManager.default.moveItem(at: publication.exactFileURL, to: staging)
        let recovered = try await store.recoverPublication(reference: publication.reference,
            operationID: operationID, expectedByteCount: publication.byteCount, inside: fixture.authority)
        XCTAssertEqual(recovered.markdown, request.markdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let retry = try await store.recoverPublication(reference: publication.reference,
            operationID: operationID, expectedByteCount: publication.byteCount, inside: fixture.authority)
        XCTAssertEqual(retry.markdown, request.markdown)
    }

    func testIntentRecoveryCannotAdoptAnotherOperationOrReplaceChangedFinalBytes() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let operationID = UUID()
        let request = try fixture.request(markdown: "Original qualified claim.")
        let store = AuthoritativeMarkdownStore()
        let publication = try await store.publish(request)
        let staging = fixture.authority.url.appending(path: try AuthoritativeMarkdownPath.stagingRelativePath(
            documentID: request.documentID, scope: request.scope, revision: request.revision,
            operationID: operationID))
        try FileManager.default.moveItem(at: publication.exactFileURL, to: staging)
        do {
            _ = try await store.recoverPublication(reference: publication.reference, operationID: UUID(),
                expectedByteCount: publication.byteCount, inside: fixture.authority)
            XCTFail("A different intent cannot adopt staging bytes")
        } catch { XCTAssertEqual(error as? AuthoritativeMarkdownError, .documentMissing) }
        try Data("changed".utf8).write(to: publication.exactFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: publication.exactFileURL.path)
        do {
            _ = try await store.recoverPublication(reference: publication.reference, operationID: operationID,
                expectedByteCount: publication.byteCount, inside: fixture.authority)
            XCTFail("An invalid final artifact cannot be replaced with staging bytes")
        } catch {
            guard case .digestMismatch = error as? AuthoritativeMarkdownError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: staging, encoding: .utf8), request.markdown)
        XCTAssertEqual(try String(contentsOf: publication.exactFileURL, encoding: .utf8), "changed")
    }

    func testVerifierAcceptsOnlyExactProtectedAuthority() throws {
        let fixture = try MarkdownAuthorityFixture()
        XCTAssertEqual(fixture.authority.url, fixture.container.layout.internalMemoryRoot)
        XCTAssertEqual(fixture.mode(of: fixture.authority.url), 0o700)
        XCTAssertTrue(fixture.authority.url.pathComponents.contains("HighChurn.noindex"))

        let sibling = fixture.container.layout.internalWorkspacesRoot
        try fixture.makeDirectory(sibling)
        XCTAssertThrowsError(
            try AuthoritativeMarkdownRootVerifier().verify(
                sibling,
                inside: fixture.applicationSupportRoot
            )
        ) { error in
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .rootMismatch)
        }
    }

    func testPublishReadAndRevealUseImmutableScopeDerivedPathAndProtectedModes() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let documentID = MemoryDocumentID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let projectID = ProjectID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let request = try AuthoritativeMarkdownPublicationRequest(
            documentID: documentID,
            scope: .project(projectID),
            revision: 3,
            markdown: "# Project memory\n\nA durable fact.\n",
            authority: fixture.authority
        )
        let documentsRoot = fixture.authority.url.appending(path: "Documents", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentsRoot.path))

        let store = AuthoritativeMarkdownStore()
        let receipt = try await store.publish(request)
        XCTAssertEqual(
            receipt.reference.relativePath,
            "Documents/Projects/\(projectID.persistedValue)/\(documentID.persistedValue)-r3.md"
        )
        XCTAssertEqual(receipt.exactFileURL.path, fixture.authority.url.path + "/" + receipt.reference.relativePath)
        XCTAssertEqual(receipt.byteCount, Data(request.markdown.utf8).count)
        XCTAssertEqual(fixture.mode(of: receipt.exactFileURL), 0o600)
        XCTAssertEqual(fixture.mode(of: documentsRoot), 0o700)
        XCTAssertEqual(
            fixture.mode(of: documentsRoot.appending(path: "Projects", directoryHint: .isDirectory)),
            0o700
        )

        let read = try await store.read(receipt.reference, inside: fixture.authority)
        XCTAssertEqual(read.markdown, request.markdown)
        XCTAssertEqual(read.validatedFileURL, receipt.exactFileURL)
        let revealURL = try await store.validatedRevealURL(
            for: receipt.reference,
            inside: fixture.authority
        )
        XCTAssertEqual(revealURL, receipt.exactFileURL)
    }

    func testPathsAreDerivedFromScopeAndUUIDsNotDisplayText() throws {
        let documentID = MemoryDocumentID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let teammateID = TeammateID(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
        let projectID = ProjectID(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!)

        XCTAssertEqual(
            try AuthoritativeMarkdownPath.relativePath(documentID: documentID, scope: .user, revision: 1),
            "Documents/User/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-r1.md"
        )
        XCTAssertEqual(
            try AuthoritativeMarkdownPath.relativePath(
                documentID: documentID,
                scope: .teammate(teammateID),
                revision: 2
            ),
            "Documents/Teammates/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-r2.md"
        )
        XCTAssertEqual(
            try AuthoritativeMarkdownPath.relativePath(
                documentID: documentID,
                scope: .project(projectID),
                revision: 9
            ),
            "Documents/Projects/cccccccc-cccc-cccc-cccc-cccccccccccc/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-r9.md"
        )
    }

    func testReferenceRejectsTraversalOrNonDerivedPathAndInvalidDigest() throws {
        let documentID = MemoryDocumentID(UUID())
        XCTAssertThrowsError(
            try AuthoritativeMarkdownReference(
                documentID: documentID,
                scope: .user,
                revision: 1,
                relativePath: "../../outside.md",
                contentDigest: String(repeating: "a", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .invalidRelativePath)
        }
        let expectedPath = try AuthoritativeMarkdownPath.relativePath(
            documentID: documentID,
            scope: .user,
            revision: 1
        )
        XCTAssertThrowsError(
            try AuthoritativeMarkdownReference(
                documentID: documentID,
                scope: .user,
                revision: 1,
                relativePath: expectedPath,
                contentDigest: "not-a-digest"
            )
        ) { error in
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .invalidDigest)
        }
    }

    func testExclusiveCollisionPreservesExistingAuthority() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let store = AuthoritativeMarkdownStore()
        let documentID = MemoryDocumentID(UUID())
        let first = try AuthoritativeMarkdownPublicationRequest(
            documentID: documentID,
            scope: .user,
            revision: 1,
            markdown: "first",
            authority: fixture.authority
        )
        let receipt = try await store.publish(first)
        let second = try AuthoritativeMarkdownPublicationRequest(
            documentID: documentID,
            scope: .user,
            revision: 1,
            markdown: "second",
            authority: fixture.authority
        )
        do {
            _ = try await store.publish(second)
            XCTFail("Expected exclusive collision")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .collision)
        }
        XCTAssertEqual(try String(contentsOf: receipt.exactFileURL, encoding: .utf8), "first")
        let preserved = try await store.read(receipt.reference, inside: fixture.authority)
        XCTAssertEqual(preserved.markdown, "first")
    }

    func testFailureBeforeExclusivePublishNeverExposesFinalDocument() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let request = try fixture.request(markdown: "not published")
        let expectedRelative = try AuthoritativeMarkdownPath.relativePath(
            documentID: request.documentID,
            scope: request.scope,
            revision: request.revision
        )
        let expectedFinal = fixture.authority.url.appending(path: expectedRelative)
        let store = AuthoritativeMarkdownStore(
            maximumBytes: AuthoritativeMarkdownStore.defaultMaximumBytes,
            hooks: AuthoritativeMarkdownTestHooks(beforeExclusivePublish: { throw HookFailure.stop })
        )
        do {
            _ = try await store.publish(request)
            XCTFail("Expected injected interruption")
        } catch HookFailure.stop {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedFinal.path))
        let parent = expectedFinal.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertFalse(entries.contains(where: { $0.hasPrefix(".openbots-stage-") }))
    }

    func testPublishRefusesSymlinkedScopeDirectoryWithoutEscaping() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let outside = fixture.container.root.appending(path: "Outside", directoryHint: .isDirectory)
        try fixture.makeDirectory(outside)
        let documents = fixture.authority.url.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: outside)

        do {
            _ = try await AuthoritativeMarkdownStore().publish(fixture.request(markdown: "escape"))
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .directoryUnavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testReadRejectsDigestMismatchUnsafeModeAndSymlinkReplacement() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let store = AuthoritativeMarkdownStore()

        let digestReceipt = try await store.publish(fixture.request(revision: 1, markdown: "original"))
        try Data("tampered".utf8).write(to: digestReceipt.exactFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: digestReceipt.exactFileURL.path
        )
        do {
            _ = try await store.read(digestReceipt.reference, inside: fixture.authority)
            XCTFail("Expected digest mismatch")
        } catch let error as AuthoritativeMarkdownError {
            guard case .digestMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let modeReceipt = try await store.publish(fixture.request(revision: 2, markdown: "protected"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: modeReceipt.exactFileURL.path
        )
        do {
            _ = try await store.read(modeReceipt.reference, inside: fixture.authority)
            XCTFail("Expected unsafe mode rejection")
        } catch {
            XCTAssertEqual(
                error as? AuthoritativeMarkdownError,
                .documentPermissionsUnsafe(actual: 0o644)
            )
        }

        let linkReceipt = try await store.publish(fixture.request(revision: 3, markdown: "inside"))
        let outside = fixture.container.root.appending(path: "outside.md")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: linkReceipt.exactFileURL)
        try FileManager.default.createSymbolicLink(at: linkReceipt.exactFileURL, withDestinationURL: outside)
        do {
            _ = try await store.read(linkReceipt.reference, inside: fixture.authority)
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .documentIsNotRegularFile)
        }
    }

    func testReadRejectsPathReplacementAfterContentValidation() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let baselineStore = AuthoritativeMarkdownStore()
        let receipt = try await baselineStore.publish(fixture.request(markdown: "same bytes"))
        let target = receipt.exactFileURL
        let store = AuthoritativeMarkdownStore(
            maximumBytes: AuthoritativeMarkdownStore.defaultMaximumBytes,
            hooks: AuthoritativeMarkdownTestHooks(beforeFinalPathRevalidation: {
                try FileManager.default.removeItem(at: target)
                try Data("same bytes".utf8).write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            })
        )
        do {
            _ = try await store.read(receipt.reference, inside: fixture.authority)
            XCTFail("Expected identity replacement rejection")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .documentIdentityChanged)
        }
    }

    func testRollbackRemovesOnlyExactUnchangedPublication() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let store = AuthoritativeMarkdownStore()
        let receipt = try await store.publish(fixture.request(markdown: "rollback"))
        try await store.rollback(receipt, inside: fixture.authority)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.exactFileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: receipt.exactFileURL.deletingLastPathComponent().path),
            "Rollback must not traverse or prune parent directories"
        )

        let replaced = try await store.publish(fixture.request(revision: 2, markdown: "preserve replacement"))
        try FileManager.default.removeItem(at: replaced.exactFileURL)
        try Data("preserve replacement".utf8).write(to: replaced.exactFileURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replaced.exactFileURL.path)
        do {
            try await store.rollback(replaced, inside: fixture.authority)
            XCTFail("Expected rollback refusal")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .rollbackRefused)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.exactFileURL.path))
    }

    func testQuarantineMovesOnlyProvenMalformedFileIntoProtectedOwnedDirectory() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let store = AuthoritativeMarkdownStore()
        let receipt = try await store.publish(fixture.request(markdown: "trusted"))

        do {
            _ = try await store.quarantine(receipt.reference, inside: fixture.authority)
            XCTFail("A healthy authoritative document must not be quarantined")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .quarantineRefused)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.exactFileURL.path))

        try Data("malformed".utf8).write(to: receipt.exactFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.exactFileURL.path)
        let quarantine = try await store.quarantine(receipt.reference, inside: fixture.authority)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.exactFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.quarantinedFileURL.path))
        XCTAssertEqual(fixture.mode(of: quarantine.quarantinedFileURL), 0o600)
        XCTAssertEqual(fixture.mode(of: quarantine.quarantinedFileURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(quarantine.originalFileURL, receipt.exactFileURL)
        XCTAssertEqual(quarantine.byteCount, Data("malformed".utf8).count)
        guard case let .digestMismatch(expected, actual) = quarantine.malformation else {
            return XCTFail("Expected digest mismatch evidence")
        }
        XCTAssertEqual(expected, receipt.reference.contentDigest)
        XCTAssertNotEqual(actual, expected)
    }

    func testQuarantineCollisionAndIdentityReplacementFailClosed() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let baselineStore = AuthoritativeMarkdownStore()
        let collisionReceipt = try await baselineStore.publish(
            fixture.request(revision: 1, markdown: "first authority")
        )
        try Data("tampered authority".utf8).write(to: collisionReceipt.exactFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: collisionReceipt.exactFileURL.path
        )
        let quarantineDirectory = fixture.authority.url.appending(
            path: "Quarantine",
            directoryHint: .isDirectory
        )
        try fixture.makeDirectory(quarantineDirectory)
        let collisionTarget = quarantineDirectory.appending(
            path: "\(collisionReceipt.reference.documentID.persistedValue)-r1-\(collisionReceipt.reference.contentDigest).md",
            directoryHint: .notDirectory
        )
        try Data("existing evidence".utf8).write(to: collisionTarget, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: collisionTarget.path)

        do {
            _ = try await baselineStore.quarantine(collisionReceipt.reference, inside: fixture.authority)
            XCTFail("Expected exclusive quarantine collision")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .quarantineCollision)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: collisionReceipt.exactFileURL.path))
        XCTAssertEqual(try String(contentsOf: collisionTarget, encoding: .utf8), "existing evidence")

        let replacedReceipt = try await baselineStore.publish(
            fixture.request(revision: 2, markdown: "second authority")
        )
        try Data("second malformed".utf8).write(to: replacedReceipt.exactFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacedReceipt.exactFileURL.path
        )
        let exactTarget = replacedReceipt.exactFileURL
        let hookedStore = AuthoritativeMarkdownStore(
            maximumBytes: AuthoritativeMarkdownStore.defaultMaximumBytes,
            hooks: AuthoritativeMarkdownTestHooks(beforeFinalPathRevalidation: {
                try FileManager.default.removeItem(at: exactTarget)
                try Data("second malformed".utf8).write(to: exactTarget, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exactTarget.path)
            })
        )
        do {
            _ = try await hookedStore.quarantine(replacedReceipt.reference, inside: fixture.authority)
            XCTFail("Expected replacement rejection")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .documentIdentityChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactTarget.path))
    }

    func testQuarantineRejectsUnsafeModeAndSymlinkWithoutMovingExternalContent() async throws {
        let fixture = try MarkdownAuthorityFixture()
        let store = AuthoritativeMarkdownStore()
        let unsafe = try await store.publish(fixture.request(revision: 1, markdown: "mode"))
        try Data("tampered".utf8).write(to: unsafe.exactFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unsafe.exactFileURL.path)
        do {
            _ = try await store.quarantine(unsafe.reference, inside: fixture.authority)
            XCTFail("Expected unsafe mode rejection")
        } catch {
            XCTAssertEqual(
                error as? AuthoritativeMarkdownError,
                .documentPermissionsUnsafe(actual: 0o644)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafe.exactFileURL.path))

        let linked = try await store.publish(fixture.request(revision: 2, markdown: "linked"))
        let outside = fixture.container.root.appending(path: "outside-quarantine.md")
        try Data("external data".utf8).write(to: outside)
        try FileManager.default.removeItem(at: linked.exactFileURL)
        try FileManager.default.createSymbolicLink(at: linked.exactFileURL, withDestinationURL: outside)
        do {
            _ = try await store.quarantine(linked.reference, inside: fixture.authority)
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMarkdownError, .documentIsNotRegularFile)
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "external data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.exactFileURL.path))
    }

    private enum HookFailure: Error {
        case stop
    }
}

private final class MarkdownAuthorityFixture: @unchecked Sendable {
    let container: ContentTemporaryFixture
    let applicationSupportRoot: VerifiedOwnedRoot
    let authority: VerifiedAuthoritativeMarkdownRoot

    private let installationID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private let rootID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let defaultDocumentID = MemoryDocumentID(
        UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    )

    init() throws {
        container = try ContentTemporaryFixture()
        try container.materializeOwnedRoot(
            container.layout.applicationSupportRoot,
            installationID: installationID,
            rootID: rootID
        )
        try Self.makeDirectory(container.layout.highChurnRoot)
        try Self.makeDirectory(container.layout.internalMemoryRoot)
        applicationSupportRoot = try OwnedRootVerifier().verify(
            container.layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: rootID
        )
        authority = try AuthoritativeMarkdownRootVerifier().verify(
            container.layout.internalMemoryRoot,
            inside: applicationSupportRoot
        )
    }

    func request(
        revision: UInt64 = 1,
        markdown: String
    ) throws -> AuthoritativeMarkdownPublicationRequest {
        try AuthoritativeMarkdownPublicationRequest(
            documentID: defaultDocumentID,
            scope: .user,
            revision: revision,
            markdown: markdown,
            authority: authority
        )
    }

    func makeDirectory(_ url: URL) throws { try Self.makeDirectory(url) }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func mode(of url: URL) -> UInt16 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? UInt16.max
    }
}
