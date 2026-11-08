import Foundation
import SQLite3

/// Minimal read-only SQLite access. A connection is opened per call because the agent owns the DB.
public enum SQLiteReader {
    public typealias Row = [String: String]

    public static func query(_ path: String, _ sql: String, _ params: [Any] = []) -> [Row]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [Row] = []
        let columns = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return rows.isEmpty ? nil : rows }
            var row: Row = [:]
            for c in 0..<columns {
                guard let name = sqlite3_column_name(stmt, c), let text = sqlite3_column_text(stmt, c) else { continue }
                row[String(cString: name)] = String(cString: text)
            }
            rows.append(row)
        }
        return rows
    }

    public static func columns(_ path: String, table: String) -> Set<String> {
        Set((query(path, "PRAGMA table_info(\(table))") ?? []).compactMap { $0["name"] })
    }
}
