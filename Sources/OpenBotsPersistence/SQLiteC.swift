import Foundation

typealias SQLiteConnection = OpaquePointer
typealias SQLiteStatement = OpaquePointer
typealias SQLiteBackup = OpaquePointer
typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias SQLiteExecCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_open_v2")
func sqlite3_open_v2(
    _ filename: UnsafePointer<CChar>?,
    _ database: UnsafeMutablePointer<SQLiteConnection?>?,
    _ flags: Int32,
    _ vfs: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("sqlite3_close_v2")
func sqlite3_close_v2(_ database: SQLiteConnection?) -> Int32

@_silgen_name("sqlite3_errmsg")
func sqlite3_errmsg(_ database: SQLiteConnection?) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_exec")
func sqlite3_exec(
    _ database: SQLiteConnection?,
    _ sql: UnsafePointer<CChar>?,
    _ callback: SQLiteExecCallback?,
    _ context: UnsafeMutableRawPointer?,
    _ errorMessage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_free")
func sqlite3_free(_ pointer: UnsafeMutableRawPointer?)

@_silgen_name("sqlite3_busy_timeout")
func sqlite3_busy_timeout(_ database: SQLiteConnection?, _ milliseconds: Int32) -> Int32

@_silgen_name("sqlite3_prepare_v2")
func sqlite3_prepare_v2(
    _ database: SQLiteConnection?,
    _ sql: UnsafePointer<CChar>?,
    _ byteCount: Int32,
    _ statement: UnsafeMutablePointer<SQLiteStatement?>?,
    _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_finalize")
func sqlite3_finalize(_ statement: SQLiteStatement?) -> Int32

@_silgen_name("sqlite3_step")
func sqlite3_step(_ statement: SQLiteStatement?) -> Int32

@_silgen_name("sqlite3_reset")
func sqlite3_reset(_ statement: SQLiteStatement?) -> Int32

@_silgen_name("sqlite3_clear_bindings")
func sqlite3_clear_bindings(_ statement: SQLiteStatement?) -> Int32

@_silgen_name("sqlite3_bind_null")
func sqlite3_bind_null(_ statement: SQLiteStatement?, _ index: Int32) -> Int32

@_silgen_name("sqlite3_bind_int64")
func sqlite3_bind_int64(_ statement: SQLiteStatement?, _ index: Int32, _ value: Int64) -> Int32

@_silgen_name("sqlite3_bind_double")
func sqlite3_bind_double(_ statement: SQLiteStatement?, _ index: Int32, _ value: Double) -> Int32

@_silgen_name("sqlite3_bind_text")
func sqlite3_bind_text(
    _ statement: SQLiteStatement?,
    _ index: Int32,
    _ value: UnsafePointer<CChar>?,
    _ byteCount: Int32,
    _ destructor: SQLiteDestructor?
) -> Int32

@_silgen_name("sqlite3_column_count")
func sqlite3_column_count(_ statement: SQLiteStatement?) -> Int32

@_silgen_name("sqlite3_column_name")
func sqlite3_column_name(_ statement: SQLiteStatement?, _ index: Int32) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_column_type")
func sqlite3_column_type(_ statement: SQLiteStatement?, _ index: Int32) -> Int32

@_silgen_name("sqlite3_column_int64")
func sqlite3_column_int64(_ statement: SQLiteStatement?, _ index: Int32) -> Int64

@_silgen_name("sqlite3_column_double")
func sqlite3_column_double(_ statement: SQLiteStatement?, _ index: Int32) -> Double

@_silgen_name("sqlite3_column_text")
func sqlite3_column_text(_ statement: SQLiteStatement?, _ index: Int32) -> UnsafePointer<UInt8>?

@_silgen_name("sqlite3_column_bytes")
func sqlite3_column_bytes(_ statement: SQLiteStatement?, _ index: Int32) -> Int32

@_silgen_name("sqlite3_changes")
func sqlite3_changes(_ database: SQLiteConnection?) -> Int32

@_silgen_name("sqlite3_errcode")
func sqlite3_errcode(_ database: SQLiteConnection?) -> Int32

@_silgen_name("sqlite3_backup_init")
func sqlite3_backup_init(
    _ destination: SQLiteConnection?,
    _ destinationName: UnsafePointer<CChar>?,
    _ source: SQLiteConnection?,
    _ sourceName: UnsafePointer<CChar>?
) -> SQLiteBackup?

@_silgen_name("sqlite3_backup_step")
func sqlite3_backup_step(_ backup: SQLiteBackup?, _ pageCount: Int32) -> Int32

@_silgen_name("sqlite3_backup_finish")
func sqlite3_backup_finish(_ backup: SQLiteBackup?) -> Int32

@_silgen_name("sqlite3_backup_pagecount")
func sqlite3_backup_pagecount(_ backup: SQLiteBackup?) -> Int32

let sqliteOK: Int32 = 0
let sqliteConstraint: Int32 = 19
let sqliteRow: Int32 = 100
let sqliteDone: Int32 = 101
let sqliteInteger: Int32 = 1
let sqliteFloat: Int32 = 2
let sqliteText: Int32 = 3
let sqliteNull: Int32 = 5
let sqliteOpenReadWrite: Int32 = 0x0000_0002
let sqliteOpenCreate: Int32 = 0x0000_0004
let sqliteOpenFullMutex: Int32 = 0x0001_0000
let sqliteOpenNoFollow: Int32 = 0x0100_0000

func sqliteTransientDestructor() -> SQLiteDestructor? {
    unsafeBitCast(-1, to: SQLiteDestructor?.self)
}
