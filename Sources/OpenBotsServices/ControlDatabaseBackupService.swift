import CryptoKit
import Darwin
import Foundation
import OpenBotsContent
import OpenBotsPersistence
import os

/// Why a control-database snapshot was taken. The raw value is part of every
/// backup file name, so these spellings are a persisted format detail.
public enum ControlDatabaseBackupReason: String, Codable, CaseIterable, Sendable {
    case quit
    case scheduled
    case manual
}

public enum ControlDatabaseBackupError: Error, Equatable, Sendable {
    /// The bootstrap owns directory creation. This service never makes one.
    case backupsDirectoryMissing
    case backupsDirectoryNotADirectory
    case noAvailableBackupName
    case backupFileUnreadable
    case manifestEncodingFailed
    case manifestReservationFailed(code: Int32)
    case manifestWriteFailed(code: Int32)
}

/// The exact on-disk sidecar written next to every backup file. Retention and
/// listing both refuse to consider a backup whose sidecar does not parse, so
/// this type is the only thing that makes a file in the folder ours.
struct ControlDatabaseBackupManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let fileName: String
    let reason: ControlDatabaseBackupReason
    let createdAt: Date
    let byteCount: Int
    let sha256: String
    let databasePageCount: Int
    let schemaVersion: Int
    let protectionMode: String
    let decisionID: String
}

/// One backup and the sidecar that describes it, plus what the same call pruned.
public struct ControlDatabaseBackupRecord: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let fileName: String
    public let reason: ControlDatabaseBackupReason
    public let createdAt: Date
    public let byteCount: Int
    public let sha256: String
    public let databasePageCount: Int
    public let schemaVersion: Int
    public let protectionMode: String
    public let decisionID: String
    public let fileURL: URL
    public let manifestURL: URL
    /// Empty for records read back by `listRecords()`; retention reports only
    /// what the call that produced the record deleted.
    public let prunedFileNames: [String]

    public init(
        formatVersion: Int,
        fileName: String,
        reason: ControlDatabaseBackupReason,
        createdAt: Date,
        byteCount: Int,
        sha256: String,
        databasePageCount: Int,
        schemaVersion: Int,
        protectionMode: String,
        decisionID: String,
        fileURL: URL,
        manifestURL: URL,
        prunedFileNames: [String]
    ) {
        self.formatVersion = formatVersion
        self.fileName = fileName
        self.reason = reason
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.sha256 = sha256
        self.databasePageCount = databasePageCount
        self.schemaVersion = schemaVersion
        self.protectionMode = protectionMode
        self.decisionID = decisionID
        self.fileURL = fileURL
        self.manifestURL = manifestURL
        self.prunedFileNames = prunedFileNames
    }

    init(
        manifest: ControlDatabaseBackupManifest,
        fileURL: URL,
        manifestURL: URL,
        prunedFileNames: [String]
    ) {
        self.init(
            formatVersion: manifest.formatVersion,
            fileName: manifest.fileName,
            reason: manifest.reason,
            createdAt: manifest.createdAt,
            byteCount: manifest.byteCount,
            sha256: manifest.sha256,
            databasePageCount: manifest.databasePageCount,
            schemaVersion: manifest.schemaVersion,
            protectionMode: manifest.protectionMode,
            decisionID: manifest.decisionID,
            fileURL: fileURL,
            manifestURL: manifestURL,
            prunedFileNames: prunedFileNames
        )
    }
}

/// Writes one retained, manifest-described SQLite snapshot of the control
/// database into the preview's marker-owned `DatabaseBackups` folder.
///
/// Every filesystem authority stays where it already lives: containment and the
/// online backup belong to `SQLiteBackupContainmentService`, and directory
/// creation belongs to the storage bootstrap. This type adds only naming,
/// the sidecar manifest, and retention. It owns no timer: the application
/// decides when a backup happens.
public actor ControlDatabaseBackupService {
    /// Only a file directly inside the backups folder with this prefix and
    /// extension, carrying a sidecar that names it, is ever listed or deleted.
    static let fileNamePrefix = "OpenBots-"
    static let backupFileExtension = "sqlite"
    static let manifestFileExtension = "json"
    private static let maximumNameAttempts = 64

    private let layout: PreviewStorageLayout
    private let applicationSupportRoot: VerifiedOwnedRoot
    private let protection: PersistenceProtectionPlan
    private let executor: any SQLiteBackupExecuting
    private let containment: SQLiteBackupContainmentService
    private let retainedCount: Int
    private let clock: @Sendable () -> Date
    private let logger = Logger(
        subsystem: "com.lorenzocolombani.openbotsnext.preview",
        category: "database-backup"
    )

    // Actor isolation alone does not serialize `backupNow`: it suspends on the
    // containment service, so a second call could interleave a retention pass
    // with a running backup. This FIFO gate makes the second caller wait.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        layout: PreviewStorageLayout,
        applicationSupportRoot: VerifiedOwnedRoot,
        protection: PersistenceProtectionPlan,
        executor: any SQLiteBackupExecuting,
        locationAdmission: any MacOSLocationAdmissionChecking = MacOSLocationAdmission(),
        retainedCount: Int = 5,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.layout = layout
        self.applicationSupportRoot = applicationSupportRoot
        self.protection = protection
        self.executor = executor
        self.containment = SQLiteBackupContainmentService(
            layout: layout,
            locationAdmission: locationAdmission
        )
        // Retaining nothing would delete the backup this service just wrote.
        self.retainedCount = max(1, retainedCount)
        self.clock = clock
    }

    /// Writes one backup and then enforces retention. The clock is read exactly
    /// once per call and floored to whole seconds, so the file name and the
    /// manifest's ISO 8601 timestamp always describe the same instant.
    public func backupNow(
        reason: ControlDatabaseBackupReason
    ) async throws -> ControlDatabaseBackupRecord {
        await acquire()
        defer { release() }
        return try await performBackup(reason: reason)
    }

    /// Every backup in the folder that still has a parseable sidecar, newest first.
    public func listRecords() throws -> [ControlDatabaseBackupRecord] {
        let root = try existingBackupsDirectory()
        return pairedBackups(in: root).map {
            ControlDatabaseBackupRecord(
                manifest: $0.manifest,
                fileURL: $0.fileURL,
                manifestURL: $0.manifestURL,
                prunedFileNames: []
            )
        }
    }

    // MARK: - Backup

    private func performBackup(
        reason: ControlDatabaseBackupReason
    ) async throws -> ControlDatabaseBackupRecord {
        let root = try existingBackupsDirectory()
        let createdAt = Self.flooredToSecond(clock())
        let baseName = "\(Self.fileNamePrefix)\(Self.timestamp(createdAt))-\(reason.rawValue)"

        let receipt = try await createBackupFile(baseName: baseName, inside: root)
        let fileURL = receipt.destinationFileURL
        let fileName = fileURL.lastPathComponent
        let manifestURL = fileURL
            .deletingLastPathComponent()
            .appending(
                path: "\(fileName).\(Self.manifestFileExtension)",
                directoryHint: .notDirectory
            )

        let bytes: Data
        do {
            bytes = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw ControlDatabaseBackupError.backupFileUnreadable
        }
        let manifest = ControlDatabaseBackupManifest(
            formatVersion: ControlDatabaseBackupManifest.currentFormatVersion,
            fileName: fileName,
            reason: reason,
            createdAt: createdAt,
            byteCount: bytes.count,
            sha256: Self.hexDigest(of: bytes),
            databasePageCount: receipt.databasePageCount,
            schemaVersion: SQLiteStore.supportedSchemaVersion,
            protectionMode: protection.mode.rawValue,
            decisionID: protection.decision.decisionID.uuidString.lowercased()
        )

        let encoded: Data
        do {
            encoded = try Self.manifestEncoder().encode(manifest)
        } catch {
            throw ControlDatabaseBackupError.manifestEncodingFailed
        }
        // A backup whose manifest fails to land stays on disk unpaired, and an
        // unpaired file is invisible to both listing and retention. Leaving it
        // is deliberate: this service never deletes a file it cannot describe.
        try Self.writeExclusively(encoded, to: manifestURL)

        let pruned = pruneSurplusBackups(in: root)
        logger.notice(
            "Wrote control database backup \(fileName, privacy: .public), pruned \(pruned.count, privacy: .public)"
        )
        return ControlDatabaseBackupRecord(
            manifest: manifest,
            fileURL: fileURL,
            manifestURL: manifestURL,
            prunedFileNames: pruned
        )
    }

    /// Finds the first free `<base>[-n].sqlite` whose manifest sidecar is also
    /// free, then delegates the actual write. The containment service does not
    /// know about sidecars, so an orphaned manifest must be stepped over here.
    private func createBackupFile(
        baseName: String,
        inside root: URL
    ) async throws -> SQLiteOnlineBackupReceipt {
        for attempt in 1...Self.maximumNameAttempts {
            let name = attempt == 1
                ? "\(baseName).\(Self.backupFileExtension)"
                : "\(baseName)-\(attempt).\(Self.backupFileExtension)"
            let candidate = root.appending(path: name, directoryHint: .notDirectory)
            let manifestCandidate = root.appending(
                path: "\(name).\(Self.manifestFileExtension)",
                directoryHint: .notDirectory
            )
            guard !Self.itemExists(candidate), !Self.itemExists(manifestCandidate) else {
                continue
            }
            do {
                return try await containment.createBackup(
                    at: candidate,
                    inside: applicationSupportRoot,
                    protection: protection,
                    using: executor
                )
            } catch SQLiteBackupContainmentError.destinationCollision {
                continue
            }
        }
        throw ControlDatabaseBackupError.noAvailableBackupName
    }

    // MARK: - Retention

    private struct PairedBackup: Sendable {
        let fileURL: URL
        let manifestURL: URL
        let manifest: ControlDatabaseBackupManifest
    }

    /// The single admission rule shared by retention and `listRecords()`: a
    /// regular file named `OpenBots-*.sqlite` directly inside the backups root,
    /// whose `<name>.json` sidecar parses and names that exact file. Symbolic
    /// links, directories, unpaired files, foreign names and anything outside
    /// this folder are never returned, so retention can never reach them.
    private func pairedBackups(in root: URL) -> [PairedBackup] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        let decoder = Self.manifestDecoder()
        var pairs: [PairedBackup] = []
        for name in names {
            guard name.hasPrefix(Self.fileNamePrefix),
                  name.hasSuffix(".\(Self.backupFileExtension)"),
                  !name.contains("/")
            else {
                continue
            }
            let fileURL = root.appending(path: name, directoryHint: .notDirectory)
            let manifestURL = root.appending(
                path: "\(name).\(Self.manifestFileExtension)",
                directoryHint: .notDirectory
            )
            guard Self.isRegularFile(fileURL),
                  Self.isRegularFile(manifestURL),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(ControlDatabaseBackupManifest.self, from: data),
                  manifest.fileName == name
            else {
                continue
            }
            pairs.append(PairedBackup(fileURL: fileURL, manifestURL: manifestURL, manifest: manifest))
        }
        return pairs.sorted { lhs, rhs in
            if lhs.manifest.createdAt != rhs.manifest.createdAt {
                return lhs.manifest.createdAt > rhs.manifest.createdAt
            }
            return lhs.fileURL.lastPathComponent > rhs.fileURL.lastPathComponent
        }
    }

    private func pruneSurplusBackups(in root: URL) -> [String] {
        let pairs = pairedBackups(in: root)
        guard pairs.count > retainedCount else { return [] }
        var pruned: [String] = []
        for pair in pairs.dropFirst(retainedCount) {
            let name = pair.fileURL.lastPathComponent
            do {
                try FileManager.default.removeItem(at: pair.fileURL)
                pruned.append(name)
            } catch {
                logger.notice("Retention could not remove backup \(name, privacy: .public)")
                continue
            }
            do {
                try FileManager.default.removeItem(at: pair.manifestURL)
            } catch {
                logger.notice("Retention could not remove manifest for \(name, privacy: .public)")
            }
        }
        return pruned
    }

    // MARK: - Serialization gate

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // Ownership transfers straight to the next waiter; `isBusy` stays true.
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Filesystem helpers

    private func existingBackupsDirectory() throws -> URL {
        let root = layout.databaseBackupsRoot
        var value = stat()
        guard lstat(root.path, &value) == 0 else {
            throw ControlDatabaseBackupError.backupsDirectoryMissing
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw ControlDatabaseBackupError.backupsDirectoryNotADirectory
        }
        return root
    }

    private static func itemExists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
    }

    /// Creates the sidecar at 0600 in one step. `Data.write` would leave a
    /// umask-wide window before a follow-up `chmod`.
    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ControlDatabaseBackupError.manifestReservationFailed(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlDatabaseBackupError.manifestWriteFailed(code: errno)
                }
                offset += written
            }
        }
    }

    // MARK: - Encoding helpers

    private static func flooredToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
