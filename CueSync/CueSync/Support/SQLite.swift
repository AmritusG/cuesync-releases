import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Tells SQLite to copy bound text/blob data immediately rather than assume the
/// caller's buffer stays alive past the bind call — Swift can free or move its
/// backing storage as soon as `sqlite3_bind_*` returns, so every bind in this
/// codebase must pass this destructor. Defined once here so the fragile
/// `unsafeBitCast` isn't repeated at every call site.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteSupport {
    /// Reads column `col` of the current row as text, or `""` if it is NULL.
    static func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }
}
