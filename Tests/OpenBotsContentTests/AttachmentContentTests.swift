import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain
import XCTest
@testable import OpenBotsContent

final class AttachmentContentTests: XCTestCase {
    func testConstructionAndVerificationAreInertButExplicitProvisionCreatesOnlyExactChild() throws {
        let context = try AttachmentContentFixture(createContent: false)
        let path = context.fixture.layout.internalAttachmentsRoot
        _ = AttachmentContentRootProvisioner()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertThrowsError(try AttachmentContentRootVerifier().verify(path, inside: context.owned))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let root = try AttachmentContentRootProvisioner().prepare(inside: context.owned)
        XCTAssertEqual(root.url, path)
        XCTAssertEqual(try attachmentStat(path).st_mode & 0o7777, 0o700)
        XCTAssertEqual(try AttachmentContentRootProvisioner().prepare(inside: context.owned), root)
        _ = AttachmentContentStore(root: root)
        XCTAssertTrue(try context.contentNames().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.fixture.layout.contentRoot.url.path))
        XCTAssertTrue(context.fixture.layout.internalRequiredDirectoryURLs.contains(path))
        XCTAssertThrowsError(try AttachmentContentRootVerifier().verify(context.fixture.root, inside: context.owned))
        XCTAssertThrowsError(try AttachmentContentRootProvisioner().prepare(inside: context.cacheOwned))
    }

    func testProvisionerRefusesExistingSymlinkFileModeAndChangedMarkerWithoutRepair() throws {
        for kind in ["symlink", "file", "mode", "marker"] {
            let context = try AttachmentContentFixture(createContent: false)
            let path = context.fixture.layout.internalAttachmentsRoot
            let sentinel = context.fixture.root.appending(path: "sentinel")
            try Data("keep".utf8).write(to: sentinel)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
            case "file": try Data("keep".utf8).write(to: path)
            case "mode": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            default: try Data("wrong-marker".utf8).write(to: context.fixture.layout.applicationSupportRoot.ownershipMarkerURL)
            }
            XCTAssertThrowsError(try AttachmentContentRootProvisioner().prepare(inside: context.owned))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            if kind == "mode" { XCTAssertEqual(try attachmentStat(path).st_mode & 0o7777, 0o755) }
            if kind == "file" { XCTAssertEqual(try Data(contentsOf: path), Data("keep".utf8)) }
            if kind == "marker" { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)) }
        }
    }

    func testImmutablePublicationPreservesBytesQuarantineAndSourceButNeverExecuteBits() async throws {
        let context = try AttachmentContentFixture()
        let data = Data("#!/bin/sh\nprivate local attachment\0bytes".utf8)
        let source = try context.source(data, name: "research:notes\\draft.sh")
        XCTAssertEqual(chmod(source.path, 0o755), 0)
        let quarantine = Data("0081;66d0abcd;OpenBotsAttachmentTest;01234567-89AB-CDEF-0123-456789ABCDEF".utf8)
        try attachmentSetQuarantine(source, quarantine)
        let before = try attachmentStat(source)
        let receipt = try await context.ingest(source)
        XCTAssertEqual(try attachmentReadQuarantine(receipt.stagedFileURL), quarantine)
        let id = AttachmentID(UUID())
        let store = try context.store()
        let content = try await store.publish(receipt: receipt, from: context.ingestRoot, id: id)
        XCTAssertEqual(content.id, id)
        XCTAssertEqual(content.byteCount, Int64(data.count))
        XCTAssertEqual(content.sha256, attachmentDigest(data))
        XCTAssertEqual(content.displayName, "research:notes\\draft.sh")
        let url = try await store.verifiedURL(id: id, byteCount: content.byteCount, sha256: content.sha256)
        XCTAssertEqual(url, context.assetURL(id))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try attachmentReadQuarantine(url), quarantine)
        XCTAssertEqual(try attachmentStat(url).st_mode & 0o7777, 0o600)
        XCTAssertEqual(try context.contentNames(), [id.persistedValue + ".blob"])
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try attachmentReadQuarantine(source), quarantine)
        let after = try attachmentStat(source)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mode, before.st_mode)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        // Publication does not consume the process-local receipt. Only this
        // exact explicit discard cleans scratch after a caller's DB outcome.
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.stagedFileURL.path))
        try await AttachmentIngestor().discard(receipt, inside: context.ingestRoot)
        try await store.verify(id: id, byteCount: content.byteCount, sha256: content.sha256)
    }

    func testZeroBytesAndSanitizedDisplayLabelDoNotChangeSourceNameOrPayload() async throws {
        let context = try AttachmentContentFixture()
        let source = try context.source(Data(), name: " \tblank\nfile.unknown-openbots ")
        let receipt = try await context.ingest(source)
        let content = try await context.store().publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID()))
        XCTAssertEqual(content.byteCount, 0)
        XCTAssertEqual(content.sha256, attachmentDigest(Data()))
        XCTAssertEqual(content.displayName, "blank file.unknown-openbots")
        XCTAssertFalse(content.typeIdentifier.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: source), Data())
        let root = try context.verifiedRoot()
        try await AttachmentContentStore(root: root).verify(id: content.id, byteCount: 0, sha256: content.sha256)
    }

    func testExclusiveCollisionKeepsPublishedAndStagedFiles() async throws {
        let context = try AttachmentContentFixture()
        let first = try await context.ingest(context.source(Data("first".utf8), name: "first.txt"))
        let second = try await context.ingest(context.source(Data("second".utf8), name: "second.txt"))
        let id = AttachmentID(UUID())
        let store = try context.store()
        _ = try await store.publish(receipt: first, from: context.ingestRoot, id: id)
        do {
            _ = try await store.publish(receipt: second, from: context.ingestRoot, id: id)
            XCTFail("Expected collision")
        } catch { XCTAssertEqual(error as? AttachmentContentError, .collision) }
        XCTAssertEqual(try Data(contentsOf: context.assetURL(id)), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.stagedFileURL), Data("second".utf8))
        XCTAssertEqual(try context.contentNames(), [id.persistedValue + ".blob"])
    }

    func testPublicationRejectsAlteredReceiptPayloadIdentityBytesProtectionLinksAndQuarantine() async throws {
        for mutation in ["bytes", "mode", "hardlink", "quarantine", "replace", "directory"] {
            let context = try AttachmentContentFixture()
            let source = try context.source(Data("original".utf8))
            try attachmentSetQuarantine(source, Data("0081;66d0abcd;Test;fixture".utf8))
            let receipt = try await context.ingest(source)
            let path = receipt.stagedFileURL
            switch mutation {
            case "bytes": try Data("modified".utf8).write(to: path)
            case "mode": XCTAssertEqual(chmod(path.path, 0o644), 0)
            case "hardlink": XCTAssertEqual(link(path.path, context.fixture.root.appending(path: "linked").path), 0)
            case "quarantine": XCTAssertEqual(removexattr(path.path, "com.apple.quarantine", 0), 0)
            case "replace":
                try FileManager.default.moveItem(at: path, to: path.deletingLastPathComponent().appending(path: "original"))
                try Data("original".utf8).write(to: path)
                XCTAssertEqual(chmod(path.path, 0o600), 0)
            default:
                let directory = path.deletingLastPathComponent()
                try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("original"))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("original".utf8).write(to: path)
                XCTAssertEqual(chmod(path.path, 0o600), 0)
            }
            do {
                _ = try await context.store().publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID()))
                XCTFail("Expected altered receipt rejection: \(mutation)")
            } catch { XCTAssertTrue(error is AttachmentContentError || error is AttachmentIngestionError) }
            XCTAssertTrue(try context.contentNames().isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "Failed publication must not discard caller scratch")
        }
    }

    func testVerifyRejectsMissingCorruptLinkedUnprotectedAndNonregularBlobs() async throws {
        for mutation in ["missing", "bytes", "size", "mode", "hardlink", "symlink", "fifo", "directory"] {
            let context = try AttachmentContentFixture()
            let source = try context.source(Data("payload".utf8))
            let receipt = try await context.ingest(source)
            let store = try context.store()
            let content = try await store.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID()))
            let path = context.assetURL(content.id)
            switch mutation {
            case "bytes": try Data("changed".utf8).write(to: path)
            case "size": try Data("longer content".utf8).write(to: path)
            case "mode": XCTAssertEqual(chmod(path.path, 0o700), 0)
            case "hardlink": XCTAssertEqual(link(path.path, context.fixture.root.appending(path: "linked").path), 0)
            default:
                try FileManager.default.removeItem(at: path)
                if mutation == "symlink" { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: source) }
                if mutation == "fifo" { XCTAssertEqual(mkfifo(path.path, 0o600), 0) }
                if mutation == "directory" { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            }
            do {
                try await store.verify(id: content.id, byteCount: content.byteCount, sha256: content.sha256)
                XCTFail("Expected invalid blob rejection: \(mutation)")
            } catch { XCTAssertTrue(error is AttachmentContentError) }
            XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
        }
    }

    func testInvalidMetadataFailsBeforeReadingOrWriting() async throws {
        let context = try AttachmentContentFixture()
        let store = try context.store()
        for count in [Int64(-1), Int64(AttachmentIngestionPolicy.provisionalMaximumBytes) + 1] {
            do { try await store.verify(id: AttachmentID(UUID()), byteCount: count, sha256: String(repeating: "a", count: 64)); XCTFail("Invalid size") }
            catch { XCTAssertEqual(error as? AttachmentContentError, .invalidMetadata) }
        }
        for hash in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
            do { try await store.verify(id: AttachmentID(UUID()), byteCount: 0, sha256: hash); XCTFail("Invalid digest") }
            catch { XCTAssertEqual(error as? AttachmentContentError, .invalidMetadata) }
        }
        XCTAssertTrue(try context.contentNames().isEmpty)
    }

    func testReplacingAnyOwnedDirectoryInvalidatesPreviouslyVerifiedRoot() async throws {
        for depth in 0...2 {
            let context = try AttachmentContentFixture()
            let receipt = try await context.ingest(context.source(Data("payload".utf8)))
            let store = try context.store()
            let content = try await store.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID()))
            let paths = [context.owned.url, context.fixture.layout.highChurnRoot, context.fixture.layout.internalAttachmentsRoot]
            let replaced = paths[depth]
            let preserved = replaced.appendingPathExtension("preserved")
            try FileManager.default.moveItem(at: replaced, to: preserved)
            for path in paths[depth...] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            do { try await store.verify(id: content.id, byteCount: content.byteCount, sha256: content.sha256); XCTFail("Changed root") }
            catch { XCTAssertEqual(error as? AttachmentContentError, .rootIdentityChanged) }
            do { _ = try await store.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID())); XCTFail("Changed publish root") }
            catch { XCTAssertEqual(error as? AttachmentContentError, .rootIdentityChanged) }
            XCTAssertTrue(try context.contentNames().isEmpty)
        }
    }

    func testCancellationBeforeAndDuringPublicationCleansOnlyOwnScratch() async throws {
        let context = try AttachmentContentFixture()
        let source = try context.source(Data("payload".utf8))
        let receipt = try await context.ingest(source)
        let store = try context.store()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID()))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelling = AttachmentContentStore(root: try context.verifiedRoot(), hooks: AttachmentContentTestHooks(
            beforePublication: { _ in withUnsafeCurrentTask { $0?.cancel() } }
        ))
        do { _ = try await cancelling.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID())); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try context.contentNames().isEmpty)
        XCTAssertEqual(try Data(contentsOf: receipt.stagedFileURL), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
    }

    func testSwappedPublicationScratchIsPreservedRatherThanCleaned() async throws {
        let context = try AttachmentContentFixture()
        let receipt = try await context.ingest(context.source(Data("payload".utf8)))
        let store = AttachmentContentStore(root: try context.verifiedRoot(), hooks: AttachmentContentTestHooks(beforePublication: { path in
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("preserved"))
            try Data("foreign".utf8).write(to: path, options: .withoutOverwriting)
        }))
        do { _ = try await store.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID())); XCTFail("Expected swap failure") }
        catch { XCTAssertEqual(error as? AttachmentContentError, .cleanupRefused) }
        XCTAssertEqual(try context.contentNames().count, 2)
        XCTAssertEqual(try Data(contentsOf: receipt.stagedFileURL), Data("payload".utf8))
    }

    func testPublicationAndVerificationDetectLateRootAndBlobReplacement() async throws {
        let context = try AttachmentContentFixture()
        let receipt = try await context.ingest(context.source(Data("payload".utf8)))
        let rootURL = context.fixture.layout.internalAttachmentsRoot
        let lateRootSwap = AttachmentContentStore(root: try context.verifiedRoot(), hooks: AttachmentContentTestHooks(beforePublication: { _ in
            try FileManager.default.moveItem(at: rootURL, to: rootURL.appendingPathExtension("preserved"))
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }))
        do { _ = try await lateRootSwap.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID())); XCTFail("Expected root failure") }
        catch { XCTAssertEqual(error as? AttachmentContentError, .rootIdentityChanged) }
        XCTAssertTrue(try context.contentNames().isEmpty)

        let other = try AttachmentContentFixture()
        let otherReceipt = try await other.ingest(other.source(Data("payload".utf8)))
        let content = try await other.store().publish(receipt: otherReceipt, from: other.ingestRoot, id: AttachmentID(UUID()))
        let path = other.assetURL(content.id)
        let reader = AttachmentContentStore(root: try other.verifiedRoot(), hooks: AttachmentContentTestHooks(beforeVerificationCompletes: {
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("preserved"))
            try Data("payload".utf8).write(to: path, options: .withoutOverwriting)
        }))
        do { try await reader.verify(id: content.id, byteCount: content.byteCount, sha256: content.sha256); XCTFail("Expected blob swap failure") }
        catch { XCTAssertEqual(error as? AttachmentContentError, .contentMismatch) }
        XCTAssertEqual(try Data(contentsOf: path), Data("payload".utf8))
        XCTAssertEqual(try other.contentNames().count, 2)
    }

    func testIngestionRejectsHardlinksBalancesScopeAndPropagatesParentCancellation() async throws {
        let context = try AttachmentContentFixture()
        let source = try context.source(Data(repeating: 0x41, count: 128 * 1_024))
        let alias = context.fixture.root.appending(path: "hardlink")
        XCTAssertEqual(link(source.path, alias.path), 0)
        do { _ = try await context.ingest(source); XCTFail("Expected hardlink refusal") }
        catch { XCTAssertEqual(error as? AttachmentIngestionError, .sourceHasUnexpectedHardLinks) }
        XCTAssertEqual(unlink(alias.path), 0)
        let hook = AttachmentBlockingHook()
        let scope = AttachmentScopeObservation()
        let ingestor = AttachmentIngestor(policy: AttachmentIngestionPolicy(), testHooks: AttachmentIngestionTestHooks(
            startSourceAccess: { scope.record("start", $0); return true },
            stopSourceAccess: { scope.record("stop", $0) },
            afterScratchDirectoryCreated: { _ in hook.wait() }
        ))
        let task = Task { try await ingestor.ingest(AttachmentIngestionRequest(sourceFileURL: source, ingestRoot: context.ingestRoot)) }
        for _ in 0..<200 {
            if hook.hasEntered { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(hook.hasEntered)
        task.cancel()
        hook.release()
        do { _ = try await task.value; XCTFail("Expected forwarded cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(scope.events, ["start:" + source.path, "stop:" + source.path])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: context.ingestRoot.url.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source).count, 128 * 1_024)
    }

    func testPublicationAndVerificationStayOffMainActor() async throws {
        let context = try AttachmentContentFixture()
        let receipt = try await context.ingest(context.source(Data("payload".utf8)))
        let observation = AttachmentThreadObservation()
        let store = AttachmentContentStore(root: try context.verifiedRoot(), hooks: AttachmentContentTestHooks(
            beforePublication: { _ in observation.record(Thread.isMainThread) },
            beforeVerificationCompletes: { observation.record(Thread.isMainThread) }
        ))
        let task = await MainActor.run { Task { @MainActor in
            let content = try await store.publish(receipt: receipt, from: context.ingestRoot, id: AttachmentID(UUID()))
            try await store.verify(id: content.id, byteCount: content.byteCount, sha256: content.sha256)
        } }
        try await task.value
        XCTAssertEqual(observation.values, [false, false, false])
    }
}

private final class AttachmentContentFixture: @unchecked Sendable {
    let fixture: ContentTemporaryFixture
    let owned: VerifiedOwnedRoot
    let cacheOwned: VerifiedOwnedRoot
    let ingestRoot: VerifiedAttachmentIngestRoot

    init(createContent: Bool = true) throws {
        let fixture = try ContentTemporaryFixture()
        self.fixture = fixture
        let installationID = UUID(), supportID = UUID(), cacheID = UUID()
        try fixture.materializeOwnedRoot(fixture.layout.applicationSupportRoot, installationID: installationID, rootID: supportID)
        try fixture.materializeOwnedRoot(fixture.layout.cacheRoot, installationID: installationID, rootID: cacheID)
        for path in [fixture.layout.highChurnRoot, fixture.layout.attachmentIngestRoot, fixture.root.appending(path: "Sources")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        owned = try OwnedRootVerifier().verify(fixture.layout.applicationSupportRoot, expectedInstallationID: installationID, expectedRootID: supportID)
        cacheOwned = try OwnedRootVerifier().verify(fixture.layout.cacheRoot, expectedInstallationID: installationID, expectedRootID: cacheID)
        ingestRoot = try AttachmentIngestRootVerifier().verify(fixture.layout.attachmentIngestRoot, inside: cacheOwned)
        if createContent { _ = try AttachmentContentRootProvisioner().prepare(inside: owned) }
    }

    func source(_ data: Data, name: String = "source.txt") throws -> URL {
        let url = fixture.root.appending(path: "Sources").appending(path: name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
    func ingest(_ source: URL) async throws -> PreviewAttachmentIngestionReceipt {
        try await AttachmentIngestor().ingest(AttachmentIngestionRequest(sourceFileURL: source, ingestRoot: ingestRoot))
    }
    func verifiedRoot() throws -> VerifiedAttachmentContentRoot {
        try AttachmentContentRootVerifier().verify(fixture.layout.internalAttachmentsRoot, inside: owned)
    }
    func store() throws -> AttachmentContentStore { AttachmentContentStore(root: try verifiedRoot()) }
    func assetURL(_ id: AttachmentID) -> URL { fixture.layout.internalAttachmentsRoot.appending(path: id.persistedValue + ".blob") }
    func contentNames() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: fixture.layout.internalAttachmentsRoot.path).sorted() }
}

private func attachmentDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func attachmentStat(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return value
}
private func attachmentSetQuarantine(_ url: URL, _ data: Data) throws {
    let result = data.withUnsafeBytes { setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
    guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}
private func attachmentReadQuarantine(_ url: URL) throws -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    return try AttachmentQuarantine.read(fd)
}
private final class AttachmentThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Bool] = []
    var values: [Bool] { lock.withLock { captured } }
    func record(_ value: Bool) { lock.withLock { captured.append(value) } }
}
private final class AttachmentScopeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    var events: [String] { lock.withLock { captured } }
    func record(_ value: String, _ url: URL) { lock.withLock { captured.append(value + ":" + url.path) } }
}
private final class AttachmentBlockingHook: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var hasEntered: Bool { condition.withLock { entered } }
    func wait() {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(2)
        while !released, condition.wait(until: deadline) {}
        condition.unlock()
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}
