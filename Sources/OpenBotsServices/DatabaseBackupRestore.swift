import CryptoKit
import Darwin
import Foundation
import OpenBotsContent
import OpenBotsPersistence

/// One backup file that has been proven, at this moment, to be a complete and
/// intact snapshot of *this* installation's control database.
///
/// A value of this type is a receipt of the four independent checks in
/// `DatabaseBackupCatalog`: the sidecar's byte count, the sidecar's SHA-256,
/// the file's own integrity check, and the protection decision recorded inside
/// the database itself. It is never constructed from a manifest alone.
public struct VerifiedDatabaseBackup: Equatable, Sendable, Identifiable {
    /// The backup's file name, unique within the backups folder.
    public let id: String
    public let fileURL: URL
    public let createdAt: Date
    public let byteCount: Int
    public let schemaVersion: Int
    public let reason: String

    public init(
        id: String,
        fileURL: URL,
        createdAt: Date,
        byteCount: Int,
        schemaVersion: Int,
        reason: String
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.schemaVersion = schemaVersion
        self.reason = reason
    }
}

/// A file in the backups folder that was not offered, and why. Reported for
/// diagnostics only: `verifiedBackups()` simply never returns it.
public struct SkippedDatabaseBackup: Equatable, Sendable {
    public let fileName: String
    public let reason: String

    public init(fileName: String, reason: String) {
        self.fileName = fileName
        self.reason = reason
    }
}

public struct DatabaseBackupCatalogReport: Equatable, Sendable {
    public let verified: [VerifiedDatabaseBackup]
    public let skipped: [SkippedDatabaseBackup]

    public init(verified: [VerifiedDatabaseBackup], skipped: [SkippedDatabaseBackup]) {
        self.verified = verified
        self.skipped = skipped
    }
}

/// Lists the backups a restore may legitimately offer.
///
/// Every check is a reason to refuse: a file is offered only when it passes all
/// of them. Nothing here creates, repairs, moves or deletes anything, so a
/// listing is safe to run at any time, including on a workspace that will not
/// open.
public struct DatabaseBackupCatalog: Sendable {
    /// The producer's naming contract, mirrored rather than imported so a
    /// listing never depends on the writer being loaded or healthy.
    static let fileNamePrefix = "OpenBots-"
    static let backupFileExtension = "sqlite"
    static let manifestFileExtension = "json"
    static let expectedProtectionMode = "ordinarySQLite"

    private let layout: PreviewStorageLayout
    private let expectedDecisionID: UUID
    private let supportedSchemaVersion: Int

    public init(
        layout: PreviewStorageLayout,
        expectedDecisionID: UUID,
        supportedSchemaVersion: Int = SQLiteStore.supportedSchemaVersion
    ) {
        self.layout = layout
        self.expectedDecisionID = expectedDecisionID
        self.supportedSchemaVersion = supportedSchemaVersion
    }

    /// Every intact backup of this installation, newest first.
    public func verifiedBackups() -> [VerifiedDatabaseBackup] {
        verify().verified
    }

    /// The same listing, plus what was refused and why.
    public func verify() -> DatabaseBackupCatalogReport {
        let root = layout.databaseBackupsRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return DatabaseBackupCatalogReport(verified: [], skipped: [])
        }

        var verified: [VerifiedDatabaseBackup] = []
        var skipped: [SkippedDatabaseBackup] = []
        for name in names.sorted() {
            guard name.hasPrefix(Self.fileNamePrefix),
                  name.hasSuffix(".\(Self.backupFileExtension)"),
                  !name.contains("/") else {
                // Not a backup file at all: the folder also holds sidecars,
                // restore receipts and damaged-database folders.
                continue
            }
            do {
                verified.append(try verifyOne(named: name, in: root))
            } catch let refusal as BackupRefusal {
                skipped.append(SkippedDatabaseBackup(fileName: name, reason: refusal.reason))
            } catch {
                skipped.append(SkippedDatabaseBackup(fileName: name, reason: "\(error)"))
            }
        }
        return DatabaseBackupCatalogReport(
            verified: verified.sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id > rhs.id : lhs.createdAt > rhs.createdAt
            },
            skipped: skipped
        )
    }

    private func verifyOne(named name: String, in root: URL) throws -> VerifiedDatabaseBackup {
        let fileURL = root.appending(path: name, directoryHint: .notDirectory)
        let manifest = try DatabaseBackupManifestDocument.read(besideBackupNamed: name, in: root)
        if let declaredName = manifest.fileName, declaredName != name {
            throw BackupRefusal("the sidecar names \(declaredName)")
        }

        var value = stat()
        guard lstat(fileURL.path, &value) == 0 else {
            throw BackupRefusal("the file could not be inspected (error \(errno))")
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw BackupRefusal("the path is not a regular file")
        }
        let byteCount = Int(value.st_size)
        guard byteCount == manifest.byteCount else {
            throw BackupRefusal("the file is \(byteCount) bytes, the sidecar says \(manifest.byteCount)")
        }

        let digest = try DatabaseBackupDigest.hex(ofFileAt: fileURL)
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw BackupRefusal("the file does not match its recorded SHA-256")
        }

        let facts: SQLiteBackupFacts
        do {
            facts = try SQLiteBackupInspection.inspect(fileURL: fileURL)
        } catch {
            throw BackupRefusal("the file did not read as a database: \(error)")
        }
        guard facts.integrityOK else {
            throw BackupRefusal("the database failed its integrity check")
        }
        guard facts.protectionMode == Self.expectedProtectionMode else {
            throw BackupRefusal("the protection mode is \(facts.protectionMode ?? "absent")")
        }
        guard facts.decisionID == expectedDecisionID.uuidString.lowercased() else {
            throw BackupRefusal("the protection decision is \(facts.decisionID ?? "absent")")
        }
        guard facts.schemaVersion <= supportedSchemaVersion else {
            throw BackupRefusal(
                "schema version \(facts.schemaVersion) is newer than the supported \(supportedSchemaVersion)"
            )
        }
        // The sidecar's claim is checked as a bound, never against the file's own
        // version. The producer still records `SQLiteStore.expectedMigrationCount`,
        // a count of the declared manifest, while the file reports `MAX(version)`;
        // the two agree only while migrations run contiguously. So this check
        // stays a soft bound. The file's own version, checked above against
        // `SQLiteStore.supportedSchemaVersion`, is the authority, and the byte
        // count and digest already prove this sidecar describes this exact file.
        if let declaredVersion = manifest.schemaVersion, declaredVersion > supportedSchemaVersion {
            throw BackupRefusal(
                "the sidecar claims schema version \(declaredVersion), above the supported \(supportedSchemaVersion)"
            )
        }

        return VerifiedDatabaseBackup(
            id: name,
            fileURL: fileURL,
            createdAt: manifest.createdAt,
            byteCount: byteCount,
            schemaVersion: facts.schemaVersion,
            reason: manifest.reason
        )
    }
}

/// What one restore did. Written next to the backups it chose from, so the
/// move is explainable long after the fact.
public struct DatabaseBackupRestoreReceipt: Codable, Equatable, Sendable {
    /// The backup's file name.
    public let restoredFrom: String
    public let restoredAt: Date
    /// The folder inside the backups root that now holds the replaced files.
    public let damagedFolder: String
    /// The names moved into that folder, in the order they were moved.
    public let movedFiles: [String]

    public init(
        restoredFrom: String,
        restoredAt: Date,
        damagedFolder: String,
        movedFiles: [String]
    ) {
        self.restoredFrom = restoredFrom
        self.restoredAt = restoredAt
        self.damagedFolder = damagedFolder
        self.movedFiles = movedFiles
    }
}

public enum DatabaseBackupRestoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case backupOutsideBackupsRoot
    case backupMissing
    case backupUnexpectedFileType
    case backupManifestUnreadable
    case backupSizeChanged(expected: Int, actual: Int)
    case backupDigestChanged
    case backupUnreadable(code: Int32)
    case damagedFolderCreationFailed(code: Int32)
    /// The workspace is unchanged: everything already moved was moved back.
    case damagedFileMoveFailed(name: String, code: Int32, damagedFolder: String)
    /// A directory entry could not be made durable, so the move it records
    /// might not survive a power loss. The workspace is left as it was.
    case directorySyncFailed(code: Int32)
    case databaseCopyFailed(code: Int32)
    case restoredProtectionFailed(code: Int32, actualMode: UInt16)
    case restoredDigestMismatch
    case receiptWriteFailed(code: Int32)

    public var description: String {
        switch self {
        case .backupOutsideBackupsRoot: "The chosen backup is not inside the backups folder."
        case .backupMissing: "The chosen backup no longer exists."
        case .backupUnexpectedFileType: "The chosen backup is not a regular file."
        case .backupManifestUnreadable: "The chosen backup has no readable sidecar."
        case let .backupSizeChanged(expected, actual):
            "The chosen backup is \(actual) bytes, not the expected \(expected)."
        case .backupDigestChanged: "The chosen backup no longer matches its recorded SHA-256."
        case let .backupUnreadable(code): "The chosen backup could not be read (error \(code))."
        case let .damagedFolderCreationFailed(code):
            "The folder for the replaced database could not be created (error \(code))."
        case let .damagedFileMoveFailed(name, code, folder):
            "\(name) could not be moved into \(folder) (error \(code)); the workspace was left as it was."
        case let .directorySyncFailed(code):
            "A folder could not be flushed to disk (error \(code)); the workspace was left as it was."
        case let .databaseCopyFailed(code): "The backup could not be copied into place (error \(code))."
        case let .restoredProtectionFailed(code, mode):
            "The restored database has mode \(String(mode, radix: 8)) (error \(code)), not 600."
        case .restoredDigestMismatch: "The restored copy does not match the backup it came from."
        case let .receiptWriteFailed(code): "The restore receipt could not be written (error \(code))."
        }
    }
}

/// Puts one verified backup back in place of a database that will not open.
///
/// The replaced files are moved, never deleted, into a timestamped folder
/// inside the backups tree, and the backup itself is copied rather than moved,
/// so a failed restore can be retried from the same snapshot. If the copy
/// fails, the replaced files are moved back and the partial copy is set aside;
/// this type deletes nothing under any outcome.
public struct DatabaseBackupRestoreService: Sendable {
    static let damagedFolderPrefix = "Damaged-"
    static let receiptFilePrefix = "restore-"
    static let partialRestoreSuffix = ".partial-restore"

    private let layout: PreviewStorageLayout
    private let clock: @Sendable () -> Date

    public init(
        layout: PreviewStorageLayout,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.layout = layout
        self.clock = clock
    }

    public func restore(_ backup: VerifiedDatabaseBackup) throws -> DatabaseBackupRestoreReceipt {
        let root = layout.databaseBackupsRoot
        let backupURL = try validatedBackupURL(backup, in: root)
        let digest = try revalidate(backup, at: backupURL)

        let restoredAt = clock()
        let (damagedURL, damagedFolderName) = try makeDamagedFolder(
            in: root,
            stamp: Self.timestamp(restoredAt)
        )

        var moved: [String] = []
        for url in [layout.databaseURL, layout.databaseWALURL, layout.databaseSHMURL] {
            let name = url.lastPathComponent
            var value = stat()
            guard lstat(url.path, &value) == 0 else { continue }
            let destination = damagedURL.appending(path: name, directoryHint: .notDirectory)
            guard rename(url.path, destination.path) == 0 else {
                let code = errno
                moveBack(moved, from: damagedURL)
                throw DatabaseBackupRestoreError.damagedFileMoveFailed(
                    name: name,
                    code: code,
                    damagedFolder: damagedFolderName
                )
            }
            moved.append(name)
        }

        // A rename is only durable once both directories are flushed. Until
        // then a power loss could lose the entries this receipt claims to have
        // moved. Failing here is safe: nothing has been copied yet.
        if !moved.isEmpty {
            for directory in [damagedURL, layout.databaseDirectory] {
                let code = Self.syncDirectory(at: directory)
                guard code == 0 else {
                    moveBack(moved, from: damagedURL)
                    throw DatabaseBackupRestoreError.directorySyncFailed(code: code)
                }
            }
        }

        var createdDestination = false
        do {
            try Self.copyExclusively(
                from: backupURL,
                to: layout.databaseURL,
                created: &createdDestination
            )
            let restoredDigest = try DatabaseBackupDigest.hex(ofFileAt: layout.databaseURL)
            guard restoredDigest.caseInsensitiveCompare(digest) == .orderedSame else {
                throw DatabaseBackupRestoreError.restoredDigestMismatch
            }
            // The copied bytes are already flushed; this makes the new
            // directory entry itself survive a power loss.
            let code = Self.syncDirectory(at: layout.databaseDirectory)
            guard code == 0 else {
                throw DatabaseBackupRestoreError.directorySyncFailed(code: code)
            }
        } catch {
            // Set the partial copy aside first: moving the replaced database
            // back would otherwise overwrite it, which would be a deletion.
            if createdDestination {
                let aside = damagedURL.appending(
                    path: layout.databaseURL.lastPathComponent + Self.partialRestoreSuffix,
                    directoryHint: .notDirectory
                )
                _ = rename(layout.databaseURL.path, aside.path)
            }
            moveBack(moved, from: damagedURL)
            throw error
        }

        let receipt = DatabaseBackupRestoreReceipt(
            restoredFrom: backup.id,
            restoredAt: restoredAt,
            damagedFolder: damagedFolderName,
            movedFiles: moved
        )
        let encoded: Data
        do {
            encoded = try Self.receiptEncoder().encode(receipt)
        } catch {
            throw DatabaseBackupRestoreError.receiptWriteFailed(code: EINVAL)
        }
        let stamp = damagedFolderName.dropFirst(Self.damagedFolderPrefix.count)
        try Self.writeExclusively(
            encoded,
            to: root.appending(
                path: "\(Self.receiptFilePrefix)\(stamp).\(DatabaseBackupCatalog.manifestFileExtension)",
                directoryHint: .notDirectory
            )
        )
        // The database is already in place and durable. The receipt is a record
        // of that, so an unflushed folder here is not a failed restore.
        _ = Self.syncDirectory(at: root)
        return receipt
    }

    // MARK: - Preconditions

    private func validatedBackupURL(_ backup: VerifiedDatabaseBackup, in root: URL) throws -> URL {
        guard !backup.id.isEmpty,
              !backup.id.contains("/"),
              backup.id != ".",
              backup.id != ".." else {
            throw DatabaseBackupRestoreError.backupOutsideBackupsRoot
        }
        let expected = root.appending(path: backup.id, directoryHint: .notDirectory)
        guard backup.fileURL.standardizedFileURL.path == expected.standardizedFileURL.path else {
            throw DatabaseBackupRestoreError.backupOutsideBackupsRoot
        }
        return expected
    }

    /// The catalog's verdict can be minutes old. Size and digest are checked
    /// again immediately before anything moves.
    private func revalidate(_ backup: VerifiedDatabaseBackup, at url: URL) throws -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw DatabaseBackupRestoreError.backupMissing
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw DatabaseBackupRestoreError.backupUnexpectedFileType
        }
        let byteCount = Int(value.st_size)
        guard byteCount == backup.byteCount else {
            throw DatabaseBackupRestoreError.backupSizeChanged(
                expected: backup.byteCount,
                actual: byteCount
            )
        }
        guard let manifest = try? DatabaseBackupManifestDocument.read(
            besideBackupNamed: backup.id,
            in: layout.databaseBackupsRoot
        ) else {
            throw DatabaseBackupRestoreError.backupManifestUnreadable
        }
        guard byteCount == manifest.byteCount else {
            throw DatabaseBackupRestoreError.backupSizeChanged(
                expected: manifest.byteCount,
                actual: byteCount
            )
        }
        let digest = try DatabaseBackupDigest.hex(ofFileAt: url)
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw DatabaseBackupRestoreError.backupDigestChanged
        }
        return digest
    }

    // MARK: - Filesystem steps

    private func makeDamagedFolder(in root: URL, stamp: String) throws -> (url: URL, name: String) {
        var lastCode = EEXIST
        for candidateStamp in [stamp, "\(stamp)-2"] {
            let name = "\(Self.damagedFolderPrefix)\(candidateStamp)"
            let url = root.appending(path: name, directoryHint: .isDirectory)
            guard url.path.withCString({ mkdir($0, S_IRWXU) }) == 0 else {
                lastCode = errno
                if lastCode == EEXIST { continue }
                throw DatabaseBackupRestoreError.damagedFolderCreationFailed(code: lastCode)
            }
            // The process umask may have narrowed the requested mode; make the
            // folder exactly 0700 through its own descriptor.
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw DatabaseBackupRestoreError.damagedFolderCreationFailed(code: errno)
            }
            defer { _ = Darwin.close(descriptor) }
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                throw DatabaseBackupRestoreError.damagedFolderCreationFailed(code: errno)
            }
            return (url, name)
        }
        throw DatabaseBackupRestoreError.damagedFolderCreationFailed(code: lastCode)
    }

    /// Flushes a directory's own entries, which `fsync` on a file does not
    /// cover. Returns 0, or the errno that explains why it could not.
    private static func syncDirectory(at url: URL) -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return errno }
        defer { _ = Darwin.close(descriptor) }
        return fsync(descriptor) == 0 ? 0 : errno
    }

    private func moveBack(_ names: [String], from damagedURL: URL) {
        for name in names {
            let source = damagedURL.appending(path: name, directoryHint: .notDirectory)
            let destination = layout.databaseDirectory.appending(
                path: name,
                directoryHint: .notDirectory
            )
            _ = rename(source.path, destination.path)
        }
    }

    /// Copies through descriptors so the destination is created exclusively at
    /// 0600 and verified there. `SQLiteStore` refuses to open a database whose
    /// mode is anything else, so this check decides whether the restore worked.
    private static func copyExclusively(from source: URL, to destination: URL, created: inout Bool) throws {
        let readDescriptor = source.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard readDescriptor >= 0 else {
            throw DatabaseBackupRestoreError.databaseCopyFailed(code: errno)
        }
        defer { _ = Darwin.close(readDescriptor) }

        let writeDescriptor = destination.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard writeDescriptor >= 0 else {
            throw DatabaseBackupRestoreError.databaseCopyFailed(code: errno)
        }
        created = true
        defer { _ = Darwin.close(writeDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(readDescriptor, $0.baseAddress, $0.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw DatabaseBackupRestoreError.databaseCopyFailed(code: errno)
            }
            if readCount == 0 { break }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < readCount {
                    let written = Darwin.write(
                        writeDescriptor,
                        raw.baseAddress!.advanced(by: offset),
                        readCount - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw DatabaseBackupRestoreError.databaseCopyFailed(code: errno)
                    }
                    offset += written
                }
            }
        }

        guard fsync(writeDescriptor) == 0 else {
            throw DatabaseBackupRestoreError.databaseCopyFailed(code: errno)
        }
        guard fchmod(writeDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw DatabaseBackupRestoreError.restoredProtectionFailed(code: errno, actualMode: 0)
        }
        var value = stat()
        guard fstat(writeDescriptor, &value) == 0 else {
            throw DatabaseBackupRestoreError.restoredProtectionFailed(code: errno, actualMode: 0)
        }
        let actualMode = UInt16(value.st_mode & 0o7777)
        guard value.st_mode & S_IFMT == S_IFREG, actualMode == 0o600 else {
            throw DatabaseBackupRestoreError.restoredProtectionFailed(code: 0, actualMode: actualMode)
        }
    }

    /// Creates the receipt at 0600 in one step, exclusively.
    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw DatabaseBackupRestoreError.receiptWriteFailed(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DatabaseBackupRestoreError.receiptWriteFailed(code: errno)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw DatabaseBackupRestoreError.receiptWriteFailed(code: errno)
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func receiptEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func receiptDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Shared reading

private struct BackupRefusal: Error {
    let reason: String

    init(_ reason: String) { self.reason = reason }
}

enum DatabaseBackupDigest {
    /// Streams the file through SHA-256 rather than mapping it, so a large
    /// snapshot costs one buffer and a changing file cannot be read twice.
    static func hex(ofFileAt url: URL) throws -> String {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DatabaseBackupRestoreError.backupUnreadable(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw DatabaseBackupRestoreError.backupUnreadable(code: errno)
            }
            if readCount == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<readCount]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The sidecar as a reader sees it: only the four fields a verification cannot
/// proceed without are required, so a manifest written by a newer or older
/// producer still parses. Everything else is a claim to be checked, not trusted.
struct DatabaseBackupManifestDocument: Equatable, Sendable {
    let reason: String
    let createdAt: Date
    let byteCount: Int
    let sha256: String
    let fileName: String?
    let schemaVersion: Int?
    let protectionMode: String?
    let decisionID: String?
    let databasePageCount: Int?
    let formatVersion: Int?

    static func read(besideBackupNamed name: String, in root: URL) throws -> Self {
        let extensionName = DatabaseBackupCatalog.manifestFileExtension
        // The producer writes `<file name>.json`; a sidecar named after the
        // base name alone is accepted too, so a hand-written one still reads.
        let candidates = [
            root.appending(path: "\(name).\(extensionName)", directoryHint: .notDirectory),
            root.appending(
                path: "\((name as NSString).deletingPathExtension).\(extensionName)",
                directoryHint: .notDirectory
            )
        ]
        for candidate in candidates {
            var value = stat()
            guard lstat(candidate.path, &value) == 0,
                  value.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: candidate),
                  let document = try? decoder().decode(Self.self, from: data) else {
                continue
            }
            return document
        }
        throw BackupRefusal("no readable sidecar")
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension DatabaseBackupManifestDocument: Decodable {
    private enum CodingKeys: String, CodingKey {
        case reason, createdAt, byteCount, sha256, fileName
        case schemaVersion, protectionMode, decisionID, databasePageCount, formatVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(String.self, forKey: .reason)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        protectionMode = try container.decodeIfPresent(String.self, forKey: .protectionMode)
        decisionID = try container.decodeIfPresent(String.self, forKey: .decisionID)
        databasePageCount = try container.decodeIfPresent(Int.self, forKey: .databasePageCount)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
    }
}
