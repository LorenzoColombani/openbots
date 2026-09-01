import Darwin
import Foundation
import XCTest
@testable import OpenBotsContent

final class AttachmentIngestionTests: XCTestCase {
    func testSuccessfulIngestionCopiesHashesAndLeavesSourceUnchanged() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "research.txt", data: Data("attachment-body".utf8))
        let before = try statValue(at: source)
        let operationID = UUID()
        let expectedScratch = scratchURL(in: context, operationID: operationID)

        let request = AttachmentIngestionRequest(
            sourceFileURL: source,
            ingestRoot: context.ingestRoot,
            operationID: operationID
        )
        _ = AttachmentIngestor()
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedScratch.path), "Construction must be inert")

        let receipt = try await AttachmentIngestor().ingest(request)

        XCTAssertEqual(receipt.operationID, operationID)
        XCTAssertEqual(receipt.sourceFileName, "research.txt")
        XCTAssertEqual(receipt.sourceIdentity.device, UInt64(before.st_dev))
        XCTAssertEqual(receipt.sourceIdentity.inode, UInt64(before.st_ino))
        XCTAssertEqual(receipt.byteCount, 15)
        XCTAssertEqual(receipt.sha256, "4eead195a6f9064b466e55d790b6127b3eac77658d51f9de956783c60e669f89")
        XCTAssertFalse(receipt.isDurable)
        XCTAssertFalse(receipt.isPublished)
        XCTAssertEqual(try Data(contentsOf: receipt.stagedFileURL), Data("attachment-body".utf8))
        XCTAssertEqual(permissions(at: expectedScratch), 0o700)
        XCTAssertEqual(permissions(at: receipt.stagedFileURL), 0o600)

        let after = try statValue(at: source)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(try Data(contentsOf: source), Data("attachment-body".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.fixture.layout.stableAttachmentsRoot.path))
    }

    func testWorkRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "background.txt", data: Data("copy".utf8))
        let observation = ThreadObservation()
        let hooks = AttachmentIngestionTestHooks(afterScratchDirectoryCreated: { _ in
            observation.record(Thread.isMainThread)
        })
        let ingestor = AttachmentIngestor(policy: AttachmentIngestionPolicy(), testHooks: hooks)

        _ = try await MainActor.run {
            Task { @MainActor in
                try await ingestor.ingest(
                    AttachmentIngestionRequest(sourceFileURL: source, ingestRoot: context.ingestRoot)
                )
            }
        }.value

        XCTAssertEqual(observation.value, false)
    }

    func testSuccessfulPreviewReceiptDiscardsOnlyItsExactScratchObjects() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "discard.txt", data: Data("copy".utf8))
        let operationID = UUID()
        let ingestor = AttachmentIngestor()
        let receipt = try await ingestor.ingest(
            AttachmentIngestionRequest(
                sourceFileURL: source,
                ingestRoot: context.ingestRoot,
                operationID: operationID
            )
        )

        try await ingestor.discard(receipt, inside: context.ingestRoot)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratchURL(in: context, operationID: operationID).path
            )
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("copy".utf8))
    }

    func testSuccessfulReceiptDiscardRefusesAReplacementPayload() async throws {
        let context = try makeContext()
        let source = try makeSource(
            in: context,
            name: "discard-replacement.txt",
            data: Data("original".utf8)
        )
        let operationID = UUID()
        let ingestor = AttachmentIngestor()
        let receipt = try await ingestor.ingest(
            AttachmentIngestionRequest(
                sourceFileURL: source,
                ingestRoot: context.ingestRoot,
                operationID: operationID
            )
        )
        let scratch = scratchURL(in: context, operationID: operationID)
        let payload = scratch.appending(path: "payload")
        let preserved = scratch.appending(path: "owned-original")
        try FileManager.default.moveItem(at: payload, to: preserved)
        try Data("foreign".utf8).write(to: payload, options: .withoutOverwriting)

        do {
            try await ingestor.discard(receipt, inside: context.ingestRoot)
            XCTFail("Expected exact-identity discard refusal")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .discardRefused)
        }

        XCTAssertEqual(try Data(contentsOf: payload), Data("foreign".utf8))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testSymlinkSourceAndSymlinkParentAreRefusedWithoutScratch() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "actual.txt", data: Data("safe".utf8))
        let directLink = context.fixture.root.appending(path: "source-link")
        try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: source)
        let directID = UUID()

        await assertIngestionError(
            .sourceIsSymbolicLink,
            source: directLink,
            context: context,
            operationID: directID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(in: context, operationID: directID).path))

        let linkedParent = context.fixture.root.appending(path: "linked-parent", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: source.deletingLastPathComponent()
        )
        let parentID = UUID()
        await assertIngestionError(
            .sourceIsSymbolicLink,
            source: linkedParent.appending(path: source.lastPathComponent),
            context: context,
            operationID: parentID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(in: context, operationID: parentID).path))
    }

    func testFinderAliasFlagIsRefused() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "alias-file", data: Data("alias".utf8))
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x80
        let result = source.path.withCString { path in
            finderInfo.withUnsafeBytes { bytes in
                setxattr(path, "com.apple.FinderInfo", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        await assertIngestionError(.sourceIsFinderAlias, source: source, context: context)
    }

    func testSpecialNodeIsRefusedWithoutBlocking() async throws {
        let context = try makeContext()
        let sourceDirectory = try sourceDirectory(in: context)
        let fifo = sourceDirectory.appending(path: "named-pipe")
        guard mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        await assertIngestionError(.sourceIsNotRegularFile, source: fifo, context: context)
    }

    func testOversizeSourceFailsBeforeScratchCreation() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "large.bin", data: Data(repeating: 0x41, count: 9))
        let operationID = UUID()
        let ingestor = AttachmentIngestor(policy: AttachmentIngestionPolicy(maximumBytes: 8))

        do {
            _ = try await ingestor.ingest(
                AttachmentIngestionRequest(
                    sourceFileURL: source,
                    ingestRoot: context.ingestRoot,
                    operationID: operationID
                )
            )
            XCTFail("Expected bounded-size refusal")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .sourceTooLarge(maximumBytes: 8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(in: context, operationID: operationID).path))
    }

    func testExistingOperationDirectoryCollisionIsNeverCleaned() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "collision.txt", data: Data("copy".utf8))
        let operationID = UUID()
        let collision = scratchURL(in: context, operationID: operationID)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: collision.path)
        let sentinel = collision.appending(path: "preexisting")
        try Data("keep".utf8).write(to: sentinel)

        await assertIngestionError(
            .scratchCollision,
            source: source,
            context: context,
            operationID: operationID
        )

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: collision.path))
    }

    func testStagedFileCollisionIsRefusedWithoutDeletingForeignItem() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "staged-collision.txt", data: Data("copy".utf8))
        let operationID = UUID()
        let hooks = AttachmentIngestionTestHooks(afterScratchDirectoryCreated: { scratch in
            try Data("foreign".utf8).write(
                to: scratch.appending(path: "payload"),
                options: .withoutOverwriting
            )
        })
        let ingestor = AttachmentIngestor(policy: AttachmentIngestionPolicy(), testHooks: hooks)

        do {
            _ = try await ingestor.ingest(
                AttachmentIngestionRequest(
                    sourceFileURL: source,
                    ingestRoot: context.ingestRoot,
                    operationID: operationID
                )
            )
            XCTFail("Expected exclusive staged-file collision")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .stagedFileCollision)
        }

        let foreign = scratchURL(in: context, operationID: operationID).appending(path: "payload")
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
    }

    func testPartialCopyFailureCleansOnlyCallOwnedScratch() async throws {
        let context = try makeContext()
        let source = try makeSource(
            in: context,
            name: "partial.bin",
            data: Data(repeating: 0x55, count: 96 * 1_024)
        )
        let operationID = UUID()
        let outsideSentinel = context.ingestRoot.url.appending(path: "outside-sentinel")
        try Data("untouched".utf8).write(to: outsideSentinel)
        let hooks = AttachmentIngestionTestHooks(failAfterCopiedBytes: 1)
        let ingestor = AttachmentIngestor(policy: AttachmentIngestionPolicy(), testHooks: hooks)

        do {
            _ = try await ingestor.ingest(
                AttachmentIngestionRequest(
                    sourceFileURL: source,
                    ingestRoot: context.ingestRoot,
                    operationID: operationID
                )
            )
            XCTFail("Expected injected partial-copy failure")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .copyFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(in: context, operationID: operationID).path))
        XCTAssertEqual(try Data(contentsOf: outsideSentinel), Data("untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: source).count, 96 * 1_024)
    }

    func testCleanupNeverDeletesAReplacementAtTheStagedFileName() async throws {
        let context = try makeContext()
        let source = try makeSource(
            in: context,
            name: "cleanup-replacement.txt",
            data: Data("owned-source".utf8)
        )
        let operationID = UUID()
        let scratch = scratchURL(in: context, operationID: operationID)
        let staged = scratch.appending(path: "payload")
        let preservedOwnedInode = scratch.appending(path: "preserved-owned-payload")
        let hooks = AttachmentIngestionTestHooks(beforeFinalSourceRevalidation: {
            try FileManager.default.moveItem(at: staged, to: preservedOwnedInode)
            try Data("foreign-replacement".utf8).write(to: staged, options: .withoutOverwriting)
        })
        let ingestor = AttachmentIngestor(
            policy: AttachmentIngestionPolicy(),
            testHooks: hooks
        )

        do {
            _ = try await ingestor.ingest(
                AttachmentIngestionRequest(
                    sourceFileURL: source,
                    ingestRoot: context.ingestRoot,
                    operationID: operationID
                )
            )
            XCTFail("Expected staged identity replacement to fail closed")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .failureCleanupFailed)
        }

        XCTAssertEqual(try Data(contentsOf: staged), Data("foreign-replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: preservedOwnedInode), Data("owned-source".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("owned-source".utf8))
    }

    func testSourceReplacementIsDetectedAndReplacementIsNotMutated() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "replace.txt", data: Data("original".utf8))
        let preservedOriginal = source.deletingLastPathComponent().appending(path: "preserved-original.txt")
        let operationID = UUID()
        let hooks = AttachmentIngestionTestHooks(beforeFinalSourceRevalidation: {
            try FileManager.default.moveItem(at: source, to: preservedOriginal)
            try Data("replacement".utf8).write(to: source, options: .withoutOverwriting)
        })
        let ingestor = AttachmentIngestor(policy: AttachmentIngestionPolicy(), testHooks: hooks)

        do {
            _ = try await ingestor.ingest(
                AttachmentIngestionRequest(
                    sourceFileURL: source,
                    ingestRoot: context.ingestRoot,
                    operationID: operationID
                )
            )
            XCTFail("Expected exact source identity revalidation to fail")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .sourceChangedDuringIngestion)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(in: context, operationID: operationID).path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: preservedOriginal), Data("original".utf8))
    }

    func testIngestRootReplacementFailsBeforeAnyWrite() async throws {
        let context = try makeContext()
        let source = try makeSource(in: context, name: "root-change.txt", data: Data("copy".utf8))
        let originalRoot = context.ingestRoot.url
        let movedRoot = originalRoot.deletingLastPathComponent().appending(path: "AttachmentIngest-original")
        try FileManager.default.moveItem(at: originalRoot, to: movedRoot)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: originalRoot.path)
        let operationID = UUID()

        await assertIngestionError(
            .ingestRootIdentityChanged,
            source: source,
            context: context,
            operationID: operationID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL(in: context, operationID: operationID).path))
        XCTAssertEqual(try Data(contentsOf: source), Data("copy".utf8))
    }

    func testErrorsDoNotExposeSourcePaths() async throws {
        let context = try makeContext()
        let missing = context.fixture.root.appending(path: "private-name-never-log.txt")

        do {
            _ = try await AttachmentIngestor().ingest(
                AttachmentIngestionRequest(sourceFileURL: missing, ingestRoot: context.ingestRoot)
            )
            XCTFail("Expected missing source refusal")
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, .sourceUnavailable)
            XCTAssertFalse(String(describing: error).contains(missing.path))
            XCTAssertFalse(String(reflecting: error).contains(missing.path))
        }
    }

    private func assertIngestionError(
        _ expected: AttachmentIngestionError,
        source: URL,
        context: IngestionContext,
        operationID: UUID = UUID(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AttachmentIngestor().ingest(
                AttachmentIngestionRequest(
                    sourceFileURL: source,
                    ingestRoot: context.ingestRoot,
                    operationID: operationID
                )
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AttachmentIngestionError, expected, file: file, line: line)
        }
    }

    private func makeContext() throws -> IngestionContext {
        let fixture = try ContentTemporaryFixture()
        let installationID = UUID()
        let cacheRootID = UUID()
        try fixture.materializeOwnedRoot(
            fixture.layout.cacheRoot,
            installationID: installationID,
            rootID: cacheRootID
        )
        try FileManager.default.createDirectory(
            at: fixture.layout.attachmentIngestRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.layout.attachmentIngestRoot.path
        )
        let verifiedCache = try OwnedRootVerifier().verify(
            fixture.layout.cacheRoot,
            expectedInstallationID: installationID,
            expectedRootID: cacheRootID
        )
        let ingestRoot = try AttachmentIngestRootVerifier().verify(
            fixture.layout.attachmentIngestRoot,
            inside: verifiedCache
        )
        return IngestionContext(fixture: fixture, ingestRoot: ingestRoot)
    }

    private func sourceDirectory(in context: IngestionContext) throws -> URL {
        let directory = context.fixture.root.appending(path: "Sources", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }

    private func makeSource(in context: IngestionContext, name: String, data: Data) throws -> URL {
        let url = try sourceDirectory(in: context).appending(path: name)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func scratchURL(in context: IngestionContext, operationID: UUID) -> URL {
        context.ingestRoot.url.appending(path: operationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func permissions(at url: URL) -> UInt16 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? UInt16.max
    }

    private func statValue(at url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return value
    }
}

private struct IngestionContext: @unchecked Sendable {
    let fixture: ContentTemporaryFixture
    let ingestRoot: VerifiedAttachmentIngestRoot
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: Bool?

    var value: Bool? {
        lock.withLock { recordedValue }
    }

    func record(_ value: Bool) {
        lock.withLock { recordedValue = value }
    }
}
