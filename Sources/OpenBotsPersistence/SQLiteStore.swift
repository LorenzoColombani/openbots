import Darwin
import Foundation
import OpenBotsDomain

public struct SQLiteStoreConfiguration: Equatable, Sendable {
    public let fileURL: URL
    public let protection: PersistenceProtectionPlan
    public let busyTimeoutMilliseconds: Int32

    public init(
        fileURL: URL,
        protection: PersistenceProtectionPlan,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) throws {
        guard fileURL.isFileURL else { throw SQLiteStoreError.invalidFileURL }
        guard busyTimeoutMilliseconds > 0 else { throw SQLiteStoreError.invalidBusyTimeout }
        self.fileURL = fileURL
        self.protection = protection
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }
}

public struct DatabaseRuntimeFacts: Equatable, Sendable {
    public let protectionMode: DatabaseProtectionMode
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let migrationCount: Int
}

public enum SQLiteStoreFileRole: String, Equatable, Sendable {
    case database
    case writeAheadLog
    case sharedMemory
}

public enum SQLiteStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidFileURL
    case invalidBusyTimeout
    case databaseParentUnavailable(code: Int32)
    case fileInspectionFailed(file: SQLiteStoreFileRole, code: Int32)
    case unexpectedFileType(file: SQLiteStoreFileRole)
    case orphanedSidecar(file: SQLiteStoreFileRole)
    case fileReservationFailed(file: SQLiteStoreFileRole, code: Int32)
    case fileProtectionFailed(file: SQLiteStoreFileRole, code: Int32)
    case fileProtectionVerificationFailed(file: SQLiteStoreFileRole, actualMode: UInt16)
    case openFailed(code: Int32, message: String)
    case operationFailed(code: Int32, operation: String, message: String)
    case invalidRow(reason: String)
    case migrationChecksumMismatch(version: Int)
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .invalidFileURL: "The SQLite store requires a local file URL."
        case .invalidBusyTimeout: "The SQLite busy timeout must be positive."
        case let .databaseParentUnavailable(code):
            "The SQLite database parent is unavailable (error \(code))."
        case let .fileInspectionFailed(file, code):
            "The SQLite \(file.rawValue) file could not be inspected (error \(code))."
        case let .unexpectedFileType(file):
            "The SQLite \(file.rawValue) path has an unexpected file type."
        case let .orphanedSidecar(file):
            "The SQLite \(file.rawValue) sidecar exists without its database."
        case let .fileReservationFailed(file, code):
            "The SQLite \(file.rawValue) file could not be reserved safely (error \(code))."
        case let .fileProtectionFailed(file, code):
            "The SQLite \(file.rawValue) file could not be protected (error \(code))."
        case let .fileProtectionVerificationFailed(file, actualMode):
            "The SQLite \(file.rawValue) file has mode \(String(actualMode, radix: 8)) instead of 600."
        case let .openFailed(code, message): "SQLite open failed (\(code)): \(message)"
        case let .operationFailed(code, operation, message):
            "SQLite \(operation) failed (\(code)): \(message)"
        case let .invalidRow(reason): "SQLite returned an invalid row: \(reason)"
        case let .migrationChecksumMismatch(version):
            "Migration \(version) does not match the signed schema manifest."
        case let .unsupportedSchemaVersion(version):
            "Database schema version \(version) is newer than this app supports."
        }
    }
}

/// The installed macOS SQLite SDK supports `SQLITE_OPEN_NOFOLLOW`. Keeping the
/// main-store flags explicit and test-visible prevents a future refactor from
/// silently following a replacement final-component symbolic link.
let sqliteStoreOpenFlags = sqliteOpenReadWrite | sqliteOpenFullMutex | sqliteOpenNoFollow

private struct SQLiteStoreFileSet {
    let database: URL

    init(databaseURL: URL) {
        database = databaseURL
    }

    var sidecars: [(url: URL, role: SQLiteStoreFileRole)] {
        [
            (URL(fileURLWithPath: database.path + "-wal"), .writeAheadLog),
            (URL(fileURLWithPath: database.path + "-shm"), .sharedMemory),
        ]
    }
}

enum SQLiteBinding: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

struct SQLiteRow: Sendable {
    private let values: [String: SQLiteValue]

    init(values: [String: SQLiteValue]) { self.values = values }

    func text(_ name: String) throws -> String {
        guard case let .text(value)? = values[name] else {
            throw SQLiteStoreError.invalidRow(reason: "missing text column \(name)")
        }
        return value
    }

    func optionalText(_ name: String) throws -> String? {
        guard let value = values[name] else {
            throw SQLiteStoreError.invalidRow(reason: "missing column \(name)")
        }
        return switch value {
        case let .text(text): text
        case .null: nil
        default: throw SQLiteStoreError.invalidRow(reason: "column \(name) is not text/null")
        }
    }

    func integer(_ name: String) throws -> Int64 {
        guard case let .integer(value)? = values[name] else {
            throw SQLiteStoreError.invalidRow(reason: "missing integer column \(name)")
        }
        return value
    }

    func optionalInteger(_ name: String) throws -> Int64? {
        guard let value = values[name] else {
            throw SQLiteStoreError.invalidRow(reason: "missing column \(name)")
        }
        return switch value {
        case let .integer(integer): integer
        case .null: nil
        default: throw SQLiteStoreError.invalidRow(reason: "column \(name) is not integer/null")
        }
    }

    func real(_ name: String) throws -> Double {
        guard let value = values[name] else {
            throw SQLiteStoreError.invalidRow(reason: "missing real column \(name)")
        }
        return switch value {
        case let .real(real): real
        case let .integer(integer): Double(integer)
        default: throw SQLiteStoreError.invalidRow(reason: "column \(name) is not numeric")
        }
    }

    func optionalReal(_ name: String) throws -> Double? {
        guard let value = values[name] else {
            throw SQLiteStoreError.invalidRow(reason: "missing column \(name)")
        }
        return switch value {
        case let .real(real): real
        case let .integer(integer): Double(integer)
        case .null: nil
        default: throw SQLiteStoreError.invalidRow(reason: "column \(name) is not numeric/null")
        }
    }
}

enum SQLiteValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

final class SQLiteConnectionBox: @unchecked Sendable {
    let pointer: SQLiteConnection

    init(_ pointer: SQLiteConnection) { self.pointer = pointer }

    deinit { _ = sqlite3_close_v2(pointer) }
}

/// The connection stays actor-isolated; callers receive domain values, never SQLite handles/statements.
public actor SQLiteStore {
    /// The startup validator shares the migration manifest instead of maintaining
    /// a second count that can reject a successfully migrated database.
    public static var expectedMigrationCount: Int { SchemaMigrator.migrations.count }

    public let fileURL: URL
    public let protectionMode: DatabaseProtectionMode
    let protectionDecisionID: UUID
    let connectionBox: SQLiteConnectionBox

    public init(configuration: SQLiteStoreConfiguration) throws {
        guard configuration.protection.mode == .ordinarySQLite else {
            throw DatabaseProtectionError.adapterUnavailable(requested: configuration.protection.mode)
        }

        let databaseURL = try Self.physicalDatabaseURL(configuration.fileURL)
        let fileSet = SQLiteStoreFileSet(databaseURL: databaseURL)
        let existedBeforeOpen = try Self.prepareFilesForOpen(fileSet)
        var opened: SQLiteConnection?
        let result = databaseURL.path.withCString {
            sqlite3_open_v2($0, &opened, sqliteStoreOpenFlags, nil)
        }
        guard result == sqliteOK, let opened else {
            let message = opened.flatMap(sqlite3_errmsg).map { String(cString: $0) } ?? "unknown error"
            if opened != nil { _ = sqlite3_close_v2(opened) }
            throw SQLiteStoreError.openFailed(code: result, message: message)
        }

        do {
            let busyResult = sqlite3_busy_timeout(opened, configuration.busyTimeoutMilliseconds)
            guard busyResult == sqliteOK else {
                throw Self.error(connection: opened, code: busyResult, operation: "busy timeout")
            }
            if existedBeforeOpen {
                try Self.verifyExistingProtection(
                    selection: configuration.protection,
                    connection: opened
                )
            }
            try Self.execute(connection: opened, sql: "PRAGMA foreign_keys=ON;")
            try Self.execute(connection: opened, sql: "PRAGMA journal_mode=WAL;")
            try Self.execute(connection: opened, sql: "PRAGMA synchronous=FULL;")
            // OFF wherever the linked SQLite lets FTS5 run inside triggers (>= 3.44.0); ON on the
            // older system libraries of macOS 14/15, where OFF makes every message insert fail.
            // See SQLiteSchemaTrust.
            try Self.execute(connection: opened, sql: SQLiteSchemaTrust.trustedSchemaPragma)
            try Self.execute(connection: opened, sql: "PRAGMA secure_delete=ON;")
            try SchemaMigrator.migrate(connection: opened)
            if !existedBeforeOpen {
                try Self.initializeProtection(selection: configuration.protection, connection: opened)
            }
            try Self.protectAndVerifyLiveFiles(fileSet)
        } catch {
            _ = sqlite3_close_v2(opened)
            throw error
        }

        self.fileURL = configuration.fileURL
        self.protectionMode = configuration.protection.mode
        self.protectionDecisionID = configuration.protection.decision.decisionID
        self.connectionBox = SQLiteConnectionBox(opened)
    }

    /// Resolves only the already-existing parent. This accommodates physical
    /// macOS spellings such as `/private/var` while leaving the database final
    /// component subject to both descriptor checks and SQLite's NOFOLLOW flag.
    private static func physicalDatabaseURL(_ requestedURL: URL) throws -> URL {
        guard requestedURL.isFileURL,
              !requestedURL.lastPathComponent.isEmpty,
              requestedURL.lastPathComponent != ".",
              requestedURL.lastPathComponent != ".." else {
            throw SQLiteStoreError.invalidFileURL
        }
        let parentPath = requestedURL.deletingLastPathComponent().path
        let resolved = parentPath.withCString { realpath($0, nil) }
        guard let resolved else {
            throw SQLiteStoreError.databaseParentUnavailable(code: errno)
        }
        defer { free(resolved) }
        return URL(
            fileURLWithPath: String(cString: resolved),
            isDirectory: true
        ).appendingPathComponent(requestedURL.lastPathComponent, isDirectory: false)
    }

    /// A new database is reserved without consulting the process umask. Existing
    /// database and sidecar files are narrowed through descriptors before SQLite
    /// can use them. Descriptor verification protects the final component; the
    /// higher-level owned-root service remains responsible for parent containment.
    private static func prepareFilesForOpen(_ files: SQLiteStoreFileSet) throws -> Bool {
        let databaseExists = try inspectRegularFile(at: files.database, role: .database)
        if databaseExists {
            try protectAndVerifyExistingFile(at: files.database, role: .database)
            for sidecar in files.sidecars {
                if try inspectRegularFile(at: sidecar.url, role: sidecar.role) {
                    try protectAndVerifyExistingFile(at: sidecar.url, role: sidecar.role)
                }
            }
            return true
        }

        for sidecar in files.sidecars {
            if try inspectRegularFile(at: sidecar.url, role: sidecar.role) {
                throw SQLiteStoreError.orphanedSidecar(file: sidecar.role)
            }
        }
        try reserveProtectedDatabase(at: files.database)
        return false
    }

    private static func protectAndVerifyLiveFiles(_ files: SQLiteStoreFileSet) throws {
        guard try inspectRegularFile(at: files.database, role: .database) else {
            throw SQLiteStoreError.fileInspectionFailed(file: .database, code: ENOENT)
        }
        try protectAndVerifyExistingFile(at: files.database, role: .database)
        for sidecar in files.sidecars {
            if try inspectRegularFile(at: sidecar.url, role: sidecar.role) {
                try protectAndVerifyExistingFile(at: sidecar.url, role: sidecar.role)
            }
        }
    }

    /// Returns false only for ENOENT. Every present non-regular type, including a
    /// symbolic link, is rejected before SQLite is allowed to interpret it.
    private static func inspectRegularFile(
        at url: URL,
        role: SQLiteStoreFileRole
    ) throws -> Bool {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw SQLiteStoreError.fileInspectionFailed(file: role, code: code)
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteStoreError.unexpectedFileType(file: role)
        }
        return true
    }

    private static func reserveProtectedDatabase(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw SQLiteStoreError.fileReservationFailed(file: .database, code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        try protectAndVerifyDescriptor(descriptor, role: .database)
    }

    private static func protectAndVerifyExistingFile(
        at url: URL,
        role: SQLiteStoreFileRole
    ) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw SQLiteStoreError.fileProtectionFailed(file: role, code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        try protectAndVerifyDescriptor(descriptor, role: role)
    }

    private static func protectAndVerifyDescriptor(
        _ descriptor: Int32,
        role: SQLiteStoreFileRole
    ) throws {
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw SQLiteStoreError.fileInspectionFailed(file: role, code: errno)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteStoreError.unexpectedFileType(file: role)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SQLiteStoreError.fileProtectionFailed(file: role, code: errno)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw SQLiteStoreError.fileInspectionFailed(file: role, code: errno)
        }
        guard after.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteStoreError.unexpectedFileType(file: role)
        }
        let actualMode = UInt16(after.st_mode & 0o7777)
        guard actualMode == 0o600 else {
            throw SQLiteStoreError.fileProtectionVerificationFailed(file: role, actualMode: actualMode)
        }
    }

    public func runtimeFacts() throws -> DatabaseRuntimeFacts {
        let journal = try scalarText(sql: "PRAGMA journal_mode;")
        let foreignKeys = try scalarInteger(sql: "PRAGMA foreign_keys;") == 1
        let migrationCount = Int(try scalarInteger(sql: "SELECT COUNT(*) FROM schema_migrations;"))
        return DatabaseRuntimeFacts(
            protectionMode: protectionMode,
            journalMode: journal,
            foreignKeysEnabled: foreignKeys,
            migrationCount: migrationCount
        )
    }

    public func integrityCheck() throws -> Bool {
        try scalarText(sql: "PRAGMA integrity_check;") == "ok"
    }

    func execute(sql: String, bindings: [SQLiteBinding] = []) throws -> Int32 {
        let statement = try prepare(sql: sql)
        defer { _ = sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == sqliteDone else {
            throw Self.error(connection: requiredConnection(), code: result, operation: "execute")
        }
        return sqlite3_changes(requiredConnection())
    }

    func query(sql: String, bindings: [SQLiteBinding] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql: sql)
        defer { _ = sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == sqliteDone { return rows }
            guard result == sqliteRow else {
                throw Self.error(connection: requiredConnection(), code: result, operation: "query")
            }
            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let namePointer = sqlite3_column_name(statement, index) else {
                    throw SQLiteStoreError.invalidRow(reason: "column name is unavailable")
                }
                let name = String(cString: namePointer)
                switch sqlite3_column_type(statement, index) {
                case sqliteInteger:
                    values[name] = .integer(sqlite3_column_int64(statement, index))
                case sqliteFloat:
                    values[name] = .real(sqlite3_column_double(statement, index))
                case sqliteText:
                    values[name] = .text(try Self.columnText(statement, index: index))
                case sqliteNull:
                    values[name] = .null
                default:
                    throw SQLiteStoreError.invalidRow(reason: "unsupported SQLite type for \(name)")
                }
            }
            rows.append(SQLiteRow(values: values))
        }
    }

    func transaction<T: Sendable>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try Self.execute(connection: requiredConnection(), sql: "BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try Task.checkCancellation()
            try Self.execute(connection: requiredConnection(), sql: "COMMIT;")
            return result
        } catch {
            try? Self.execute(connection: requiredConnection(), sql: "ROLLBACK;")
            throw error
        }
    }

    private func scalarText(sql: String) throws -> String {
        guard let row = try query(sql: sql).first else {
            throw SQLiteStoreError.invalidRow(reason: "scalar query returned no row")
        }
        return try row.text(Array(try columnNames(sql: sql))[0])
    }

    private func scalarInteger(sql: String) throws -> Int64 {
        guard let row = try query(sql: sql).first else {
            throw SQLiteStoreError.invalidRow(reason: "scalar query returned no row")
        }
        return try row.integer(Array(try columnNames(sql: sql))[0])
    }

    private func columnNames(sql: String) throws -> [String] {
        let statement = try prepare(sql: sql)
        defer { _ = sqlite3_finalize(statement) }
        return (0..<sqlite3_column_count(statement)).compactMap { index in
            sqlite3_column_name(statement, index).map(String.init(cString:))
        }
    }

    func requiredConnection() -> SQLiteConnection {
        connectionBox.pointer
    }

    private func prepare(sql: String) throws -> SQLiteStatement {
        try Self.prepare(connectionBox: connectionBox, sql: sql)
    }

    private nonisolated static func prepare(
        connectionBox: SQLiteConnectionBox,
        sql: String
    ) throws -> SQLiteStatement {
        var statement: SQLiteStatement?
        let result = sql.withCString { sqlite3_prepare_v2(connectionBox.pointer, $0, -1, &statement, nil) }
        guard result == sqliteOK, let statement else {
            throw Self.error(connection: connectionBox.pointer, code: result, operation: "prepare")
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: SQLiteStatement) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                result = sqlite3_bind_double(statement, index, value)
            case let .text(value):
                guard let byteCount = Int32(exactly: value.utf8.count) else {
                    throw SQLiteStoreError.invalidRow(reason: "text binding exceeds SQLite byte limit")
                }
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, byteCount, sqliteTransientDestructor())
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == sqliteOK else {
                throw Self.error(connection: requiredConnection(), code: result, operation: "bind")
            }
        }
    }

    static func execute(connection: SQLiteConnection, sql: String) throws {
        var messagePointer: UnsafeMutablePointer<CChar>?
        let result = sql.withCString {
            sqlite3_exec(connection, $0, nil, nil, &messagePointer)
        }
        defer { if let messagePointer { sqlite3_free(messagePointer) } }
        guard result == sqliteOK else {
            let message = messagePointer.map { String(cString: $0) }
                ?? sqlite3_errmsg(connection).map { String(cString: $0) }
                ?? "unknown error"
            throw SQLiteStoreError.operationFailed(code: result, operation: "execute schema", message: message)
        }
    }

    static func querySingleText(connection: SQLiteConnection, sql: String) throws -> String? {
        var statement: SQLiteStatement?
        let prepareResult = sql.withCString { sqlite3_prepare_v2(connection, $0, -1, &statement, nil) }
        guard prepareResult == sqliteOK, let statement else {
            throw error(connection: connection, code: prepareResult, operation: "prepare scalar")
        }
        defer { _ = sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == sqliteDone { return nil }
        guard result == sqliteRow else {
            throw error(connection: connection, code: result, operation: "query scalar")
        }
        if sqlite3_column_type(statement, 0) == sqliteNull { return nil }
        return try columnText(statement, index: 0)
    }

    /// SQLite TEXT is length-delimited UTF-8, not a C string. Embedded NUL is
    /// valid text and must never silently discard the rest of a saved draft.
    /// Corrupt UTF-8 is rejected rather than substituted with new characters.
    private nonisolated static func columnText(_ statement: SQLiteStatement, index: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            throw SQLiteStoreError.invalidRow(reason: "text pointer is unavailable")
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0,
              let text = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else {
            throw SQLiteStoreError.invalidRow(reason: "stored text is not valid UTF-8")
        }
        return text
    }

    private static func verifyExistingProtection(
        selection: PersistenceProtectionPlan,
        connection: SQLiteConnection
    ) throws {
        let metadataTable = try querySingleText(
            connection: connection,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='app_metadata';"
        )
        guard metadataTable == "app_metadata" else {
            throw DatabaseProtectionError.storedModeMissing
        }
        let storedMode = try querySingleText(
            connection: connection,
            sql: "SELECT value FROM app_metadata WHERE key='database_protection_mode';"
        )
        let requestedMode = selection.mode.rawValue
        guard let storedMode else { throw DatabaseProtectionError.storedModeMissing }
        guard storedMode == requestedMode else {
            throw DatabaseProtectionError.storedModeMismatch(stored: storedMode, requested: selection.mode)
        }
        let storedDecision = try querySingleText(
            connection: connection,
            sql: "SELECT value FROM app_metadata WHERE key='database_protection_decision_id';"
        )
        guard storedDecision == selection.decision.decisionID.uuidString.lowercased() else {
            throw DatabaseProtectionError.decisionReceiptMismatch
        }
        let storedReceipt = try querySingleText(
            connection: connection,
            sql: "SELECT value FROM app_metadata WHERE key='database_protection_decision_receipt';"
        )
        guard storedReceipt == canonicalProtectionDecisionReceipt(selection.decision) else {
            throw DatabaseProtectionError.decisionReceiptMismatch
        }
    }

    private static func initializeProtection(
        selection: PersistenceProtectionPlan,
        connection: SQLiteConnection
    ) throws {
        let requestedMode = selection.mode.rawValue
        try execute(connection: connection, sql: "BEGIN IMMEDIATE;")
        do {
            let mode = requestedMode.replacingOccurrences(of: "'", with: "''")
            let decision = selection.decision.decisionID.uuidString.lowercased()
            let receipt = canonicalProtectionDecisionReceipt(selection.decision)
            try execute(
                connection: connection,
                sql: "INSERT INTO app_metadata(key,value) VALUES ('database_protection_mode','\(mode)'), ('database_protection_decision_id','\(decision)'), ('database_protection_decision_receipt','\(receipt)');"
            )
            try execute(connection: connection, sql: "COMMIT;")
        } catch {
            try? execute(connection: connection, sql: "ROLLBACK;")
            throw error
        }
    }

    /// Stable, lossless receipt encoding for fail-closed reopen checks. The
    /// selected-at value uses the exact `Double` bit pattern instead of a
    /// locale- or precision-dependent date string; the value prefix versions
    /// this storage contract without changing the schema migration count.
    private static func canonicalProtectionDecisionReceipt(
        _ receipt: ProtectionDecisionReceipt
    ) -> String {
        let rawTimestamp = String(
            receipt.selectedAt.timeIntervalSinceReferenceDate.bitPattern,
            radix: 16,
            uppercase: false
        )
        let timestamp = String(
            repeating: "0",
            count: max(0, 16 - rawTimestamp.count)
        ) + rawTimestamp
        return [
            "v1",
            receipt.decisionID.uuidString.lowercased(),
            timestamp,
            String(receipt.rationaleVersion),
        ].joined(separator: "|")
    }

    static func error(connection: SQLiteConnection?, code: Int32, operation: String) -> SQLiteStoreError {
        let message = sqlite3_errmsg(connection).map { String(cString: $0) } ?? "unknown error"
        return .operationFailed(code: code, operation: operation, message: message)
    }
}
