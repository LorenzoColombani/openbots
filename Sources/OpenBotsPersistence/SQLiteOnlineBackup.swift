import Darwin
import Foundation

/// One exact, collision-intolerant SQLite backup destination.
///
/// Persistence enforces only local-path, parent-directory, collision, and source-alias safety.
/// This value does not prove app ownership or grant filesystem authority. A higher-level service
/// must verify root containment before constructing it.
public struct ExclusiveSQLiteBackupDestination: Equatable, Sendable {
    public let exactFileURL: URL

    public init(exactFileURL: URL) throws {
        guard exactFileURL.isFileURL else { throw SQLiteOnlineBackupError.destinationIsNotAFileURL }
        guard !exactFileURL.lastPathComponent.isEmpty,
              exactFileURL.lastPathComponent != ".",
              exactFileURL.lastPathComponent != ".." else {
            throw SQLiteOnlineBackupError.invalidDestinationName
        }
        self.exactFileURL = exactFileURL
    }
}

public struct SQLiteOnlineBackupReceipt: Equatable, Sendable {
    public let destinationFileURL: URL
    public let databasePageCount: Int

    public init(destinationFileURL: URL, databasePageCount: Int) {
        self.destinationFileURL = destinationFileURL
        self.databasePageCount = databasePageCount
    }
}

public enum SQLiteOnlineBackupError: Error, Equatable, Sendable {
    case destinationIsNotAFileURL
    case invalidDestinationName
    case sourceUnavailable
    case destinationParentUnavailable
    case destinationAliasesSource
    case destinationCollision
    case protectionPlanMismatch
    case reservationFailed(code: Int32)
    case openFailed(code: Int32, message: String)
    case initializationFailed(code: Int32, message: String)
    case copyFailed(code: Int32, message: String)
    case finishFailed(code: Int32, message: String)
}

/// The installed macOS SQLite SDK supports `SQLITE_OPEN_NOFOLLOW`. Keeping the
/// flag explicit and test-visible prevents a future refactor from reopening a
/// reserved backup destination through a final-component symbolic link.
let sqliteBackupDestinationOpenFlags = sqliteOpenReadWrite | sqliteOpenFullMutex | sqliteOpenNoFollow

public extension SQLiteStore {
    /// Creates one WAL-consistent snapshot through SQLite's online backup API.
    ///
    /// The destination must not exist. This method reserves it with `O_EXCL`, never overwrites,
    /// and never reads or copies the source database's `-wal` or `-shm` files as files.
    /// A failed backup is left at the exact destination for recovery inspection; this layer does
    /// not gain cleanup authority over its parent directory.
    func createOnlineBackup(
        at destination: ExclusiveSQLiteBackupDestination,
        protection: PersistenceProtectionPlan
    ) throws -> SQLiteOnlineBackupReceipt {
        guard protection.mode == protectionMode,
              protection.decision.decisionID == protectionDecisionID else {
            throw SQLiteOnlineBackupError.protectionPlanMismatch
        }
        guard protection.mode == .ordinarySQLite else {
            throw DatabaseProtectionError.adapterUnavailable(requested: protection.mode)
        }

        guard let sourceURL = Self.physicalExistingURL(fileURL, isDirectory: false) else {
            throw SQLiteOnlineBackupError.sourceUnavailable
        }
        let requestedURL = destination.exactFileURL.standardizedFileURL
        guard let parentURL = Self.physicalExistingURL(
            requestedURL.deletingLastPathComponent(),
            isDirectory: true
        ) else {
            throw SQLiteOnlineBackupError.destinationParentUnavailable
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SQLiteOnlineBackupError.destinationParentUnavailable
        }
        let destinationURL = parentURL.appendingPathComponent(requestedURL.lastPathComponent, isDirectory: false)
        guard destinationURL != sourceURL else { throw SQLiteOnlineBackupError.destinationAliasesSource }
        guard !FileManager.default.fileExists(atPath: destinationURL.path),
              !FileManager.default.fileExists(atPath: destinationURL.path + "-wal"),
              !FileManager.default.fileExists(atPath: destinationURL.path + "-shm") else {
            throw SQLiteOnlineBackupError.destinationCollision
        }

        let descriptor = destinationURL.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw SQLiteOnlineBackupError.destinationCollision }
            throw SQLiteOnlineBackupError.reservationFailed(code: errno)
        }
        _ = Darwin.close(descriptor)

        var destinationConnection: SQLiteConnection?
        let openResult = destinationURL.path.withCString {
            sqlite3_open_v2($0, &destinationConnection, sqliteBackupDestinationOpenFlags, nil)
        }
        guard openResult == sqliteOK, let openedDestination = destinationConnection else {
            let message = destinationConnection.flatMap(sqlite3_errmsg).map(String.init(cString:))
                ?? "unknown error"
            if destinationConnection != nil { _ = sqlite3_close_v2(destinationConnection) }
            throw SQLiteOnlineBackupError.openFailed(code: openResult, message: message)
        }
        let destinationBox = SQLiteConnectionBox(openedDestination)

        let backup = Self.initializeBackup(destination: destinationBox, source: connectionBox)
        guard let backup else {
            let code = sqlite3_errcode(destinationBox.pointer)
            let message = sqlite3_errmsg(destinationBox.pointer).map(String.init(cString:)) ?? "unknown error"
            throw SQLiteOnlineBackupError.initializationFailed(code: code, message: message)
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let pageCount = Int(sqlite3_backup_pagecount(backup))
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == sqliteDone else {
            let message = sqlite3_errmsg(destinationBox.pointer).map(String.init(cString:)) ?? "unknown error"
            throw SQLiteOnlineBackupError.copyFailed(code: stepResult, message: message)
        }
        guard finishResult == sqliteOK else {
            let message = sqlite3_errmsg(destinationBox.pointer).map(String.init(cString:)) ?? "unknown error"
            throw SQLiteOnlineBackupError.finishFailed(code: finishResult, message: message)
        }
        return SQLiteOnlineBackupReceipt(
            destinationFileURL: destinationURL,
            databasePageCount: pageCount
        )
    }

    private nonisolated static func initializeBackup(
        destination: SQLiteConnectionBox,
        source: SQLiteConnectionBox
    ) -> SQLiteBackup? {
        "main".withCString { destinationName in
            "main".withCString { sourceName in
                sqlite3_backup_init(destination.pointer, destinationName, source.pointer, sourceName)
            }
        }
    }

    /// Foundation preserves macOS convenience aliases such as `/var`, while
    /// SQLite's supported `SQLITE_OPEN_NOFOLLOW` flag rejects any symbolic-link
    /// component. `realpath` gives the physical spelling of an existing source or
    /// parent without changing the requested final filename.
    private nonisolated static func physicalExistingURL(
        _ url: URL,
        isDirectory: Bool
    ) -> URL? {
        guard url.isFileURL else { return nil }
        let resolved = url.path.withCString { realpath($0, nil) }
        guard let resolved else { return nil }
        defer { free(resolved) }
        return URL(
            fileURLWithPath: String(cString: resolved),
            isDirectory: isDirectory
        )
    }
}
