// A thin wrapper over the system SQLite 3 C library.

import Foundation
import CSQLite

enum SQLValue: Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    var int: Int? { if case .int(let v) = self { return Int(v) }; if case .double(let d) = self { return Int(d) }; return nil }
    var double: Double? { if case .double(let v) = self { return v }; if case .int(let i) = self { return Double(i) }; return nil }
    var text: String? { if case .text(let v) = self { return v }; return nil }
    var bool: Bool { (int ?? 0) != 0 }
    var data: Data? { if case .blob(let v) = self { return v }; return nil }
}

extension Optional where Wrapped == String {
    var sql: SQLValue { map { .text($0) } ?? .null }
}

extension Optional where Wrapped == Data {
    var sql: SQLValue { map { .blob($0) } ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteConnection {
    private var db: OpaquePointer?
    let path: String

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil
            throw SQLiteError(code: rc, message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(v.count), transient)
                }
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
            let n = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(n))
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_NULL: row.append(.null)
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), n > 0 {
                        row.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    if let p = sqlite3_column_text(stmt, c) {
                        row.append(.text(String(cString: p)))
                    } else {
                        row.append(.null)
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }

    static var libraryVersion: String { String(cString: sqlite3_libversion()) }
}
