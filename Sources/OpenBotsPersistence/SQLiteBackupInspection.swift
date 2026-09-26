import Darwin
import Foundation

/// What one static SQLite snapshot file says about itself.
///
/// `schemaVersion` is `MAX(version)` from `schema_migrations`, and 0 when that
/// table is absent. Compare it against `SQLiteStore.supportedSchemaVersion`,
/// which is the last declared migration and the exact bound the migrator
/// enforces. Never against `expectedMigrationCount`: that is a count of the
/// manifest, equal to the maximum only while versions stay contiguous from 1.
public struct SQLiteBackupFacts: Equatable, Sendable {
    public let integrityOK: Bool
    public let schemaVersion: Int
    public let protectionMode: String?
    public let decisionID: String?
    public let pageCount: Int

    public init(
        integrityOK: Bool,
        schemaVersion: Int,
        protectionMode: String?,
        decisionID: String?,
        pageCount: Int
    ) {
        self.integrityOK = integrityOK
        self.schemaVersion = schemaVersion
        self.protectionMode = protectionMode
        self.decisionID = decisionID
        self.pageCount = pageCount
    }
}

public enum SQLiteBackupInspectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidFileURL
    case fileInspectionFailed(code: Int32)
    case unexpectedFileType
    case openFailed(code: Int32, message: String)
    /// The file opened but does not read as a database: truncated, foreign, or
    /// corrupt beyond the header. `PRAGMA integrity_check` never ran.
    case databaseUnreadable(code: Int32, message: String)
    case queryFailed(operation: String, message: String)

    public var description: String {
        switch self {
        case .invalidFileURL: "The backup inspector requires a local file URL."
        case let .fileInspectionFailed(code): "The backup file could not be inspected (error \(code))."
        case .unexpectedFileType: "The backup path is not a regular file."
        case let .openFailed(code, message): "Read-only open failed (\(code)): \(message)"
        case let .databaseUnreadable(code, message): "The file is not a readable database (\(code)): \(message)"
        case let .queryFailed(operation, message): "Backup \(operation) failed: \(message)"
        }
    }
}

let sqliteOpenReadOnly: Int32 = 0x0000_0001
let sqliteOpenURI: Int32 = 0x0000_0040

/// Read-only, symbolic-link-refusing, and `immutable=1`.
///
/// A file produced by SQLite's online backup API inherits the source database's
/// file-format header, so a snapshot of this WAL workspace is itself a WAL-mode
/// file (header bytes 18/19 are `02 02`). A plain read-only open of such a file
/// fails with SQLITE_CANTOPEN, because a read-only connection may not create
/// the `-shm` it would otherwise need. `immutable=1` tells SQLite the file
/// cannot change, so it reads the pages directly, takes no locks, and creates
/// no sidecar at all. Verified against the system SQLite 3.51.0;
/// `SQLiteBackupInspectionTests` guards both halves of that observation.
///
/// The flag is only sound for a file that is genuinely static. Callers inspect
/// backup snapshots, never the live workspace: a database with a live `-wal`
/// would be read as its pre-WAL contents without any error.
let sqliteBackupInspectionOpenFlags =
    sqliteOpenReadOnly | sqliteOpenURI | sqliteOpenFullMutex | sqliteOpenNoFollow

/// Reads the facts a restore decision needs out of a backup file without
/// opening, repairing, migrating or touching it in any way.
public enum SQLiteBackupInspection {
    static let busyTimeoutMilliseconds: Int32 = 5_000

    public static func inspect(fileURL: URL) throws -> SQLiteBackupFacts {
        let physicalURL = try physicalFileURL(fileURL)
        try requireRegularFile(at: physicalURL)

        var opened: SQLiteConnection?
        let uri = immutableReadOnlyURI(for: physicalURL)
        let openResult = uri.withCString {
            sqlite3_open_v2($0, &opened, sqliteBackupInspectionOpenFlags, nil)
        }
        guard openResult == sqliteOK, let connection = opened else {
            let message = opened.flatMap(sqlite3_errmsg).map { String(cString: $0) } ?? "unknown error"
            if opened != nil { _ = sqlite3_close_v2(opened) }
            throw SQLiteBackupInspectionError.openFailed(code: openResult, message: message)
        }
        defer { _ = sqlite3_close_v2(connection) }

        let busyResult = sqlite3_busy_timeout(connection, busyTimeoutMilliseconds)
        guard busyResult == sqliteOK else {
            throw SQLiteBackupInspectionError.queryFailed(
                operation: "busy timeout",
                message: errorMessage(connection)
            )
        }

        // The integrity check doubles as the "is this a database at all" probe:
        // a garbage file fails to prepare it with SQLITE_NOTADB.
        let integrity: String?
        do {
            integrity = try SQLiteStore.querySingleText(
                connection: connection,
                sql: "PRAGMA integrity_check;"
            )
        } catch {
            throw SQLiteBackupInspectionError.databaseUnreadable(
                code: sqlite3_errcode(connection),
                message: errorMessage(connection)
            )
        }

        let schemaVersion: Int
        if try tableExists("schema_migrations", connection: connection) {
            let value = try text(
                "SELECT MAX(version) FROM schema_migrations;",
                operation: "schema version",
                connection: connection
            )
            schemaVersion = value.flatMap(Int.init) ?? 0
        } else {
            schemaVersion = 0
        }

        var protectionMode: String?
        var decisionID: String?
        if try tableExists("app_metadata", connection: connection) {
            protectionMode = try text(
                "SELECT value FROM app_metadata WHERE key='database_protection_mode';",
                operation: "protection mode",
                connection: connection
            )
            decisionID = try text(
                "SELECT value FROM app_metadata WHERE key='database_protection_decision_id';",
                operation: "protection decision",
                connection: connection
            )
        }

        let pageText = try text("PRAGMA page_count;", operation: "page count", connection: connection)
        guard let pageCount = pageText.flatMap(Int.init) else {
            throw SQLiteBackupInspectionError.queryFailed(
                operation: "page count",
                message: "PRAGMA page_count returned no integer"
            )
        }

        return SQLiteBackupFacts(
            integrityOK: integrity == "ok",
            schemaVersion: schemaVersion,
            protectionMode: protectionMode,
            decisionID: decisionID,
            pageCount: pageCount
        )
    }

    private static func tableExists(_ name: String, connection: SQLiteConnection) throws -> Bool {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        let found = try text(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='\(escaped)';",
            operation: "table lookup",
            connection: connection
        )
        return found == name
    }

    private static func text(
        _ sql: String,
        operation: String,
        connection: SQLiteConnection
    ) throws -> String? {
        do {
            return try SQLiteStore.querySingleText(connection: connection, sql: sql)
        } catch {
            throw SQLiteBackupInspectionError.queryFailed(
                operation: operation,
                message: errorMessage(connection)
            )
        }
    }

    private static func errorMessage(_ connection: SQLiteConnection?) -> String {
        sqlite3_errmsg(connection).map { String(cString: $0) } ?? "unknown error"
    }

    /// Resolves only the already-existing parent, exactly as `SQLiteStore` does,
    /// so a physical spelling such as `/private/var` is accepted while the final
    /// component stays subject to both the `lstat` check and SQLite's NOFOLLOW.
    private static func physicalFileURL(_ requestedURL: URL) throws -> URL {
        guard requestedURL.isFileURL,
              !requestedURL.lastPathComponent.isEmpty,
              requestedURL.lastPathComponent != ".",
              requestedURL.lastPathComponent != ".." else {
            throw SQLiteBackupInspectionError.invalidFileURL
        }
        let parentPath = requestedURL.deletingLastPathComponent().path
        let resolved = parentPath.withCString { realpath($0, nil) }
        guard let resolved else {
            throw SQLiteBackupInspectionError.fileInspectionFailed(code: errno)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(requestedURL.lastPathComponent, isDirectory: false)
    }

    /// Returns normally only for a regular file. A symbolic link, directory,
    /// socket or device is refused before SQLite is allowed to interpret it.
    private static func requireRegularFile(at url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw SQLiteBackupInspectionError.fileInspectionFailed(code: errno)
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteBackupInspectionError.unexpectedFileType
        }
    }

    /// Builds the URI from the filesystem path, percent-encoding every byte
    /// SQLite's own parser would otherwise consume. `absoluteString` must not be
    /// used here: it is already encoded and carries an authority component, so
    /// the two encodings would compound. The live backups folder sits under
    /// `Application Support`, so the space case is load-bearing, not theoretical.
    static func immutableReadOnlyURI(for url: URL) -> String {
        var encoded = ""
        for byte in url.path.utf8 {
            let isUnreserved = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: "~")
                || byte == UInt8(ascii: "/")
            if isUnreserved {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return "file:" + encoded + "?immutable=1"
    }
}
