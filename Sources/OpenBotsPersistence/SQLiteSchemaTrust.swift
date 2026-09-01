import Foundation

/// Decides the `trusted_schema` pragma for a connection from the SQLite library actually linked
/// at run time.
///
/// The store hardens every connection with `PRAGMA trusted_schema=OFF`. Under an untrusted schema
/// SQLite treats a virtual table used inside a trigger or view as direct-only unless its module is
/// tagged `SQLITE_VTAB_INNOCUOUS`; the statement then fails with
/// "unsafe use of virtual table". FTS5 received that tag in SQLite 3.44.0 (2023-11-01).
///
/// The message search index (`conversation_message_search`) is maintained from triggers, and the
/// package links the *system* libsqlite3: macOS 26 ships 3.51 (fine), macOS 15 ships 3.43.2 and
/// macOS 14 ships 3.39 (every message insert fails). So the schema is trusted only where the
/// library is too old to know FTS5 is innocuous. The decision is per connection, asked of the
/// library at open time; nothing about it is stored in the database file, so a database moves
/// freely between macOS versions.
enum SQLiteSchemaTrust {
    /// First release whose FTS5 is tagged `SQLITE_VTAB_INNOCUOUS` (SQLITE_VERSION_NUMBER form).
    static let firstVersionWithInnocuousFTS5: Int32 = 3_044_000

    /// `SQLITE_VERSION_NUMBER` of the library the process is actually running against.
    static var linkedLibraryVersionNumber: Int32 { sqlite3_libversion_number() }

    static func requiresTrustedSchema(libraryVersionNumber: Int32) -> Bool {
        libraryVersionNumber < firstVersionWithInnocuousFTS5
    }

    /// The exact pragma to run right after open, for the linked library.
    static var trustedSchemaPragma: String {
        let trusted = requiresTrustedSchema(libraryVersionNumber: linkedLibraryVersionNumber)
        return "PRAGMA trusted_schema=\(trusted ? "ON" : "OFF");"
    }
}
