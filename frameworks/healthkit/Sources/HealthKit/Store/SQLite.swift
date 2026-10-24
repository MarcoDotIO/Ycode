import Foundation
import CSQLite

/// Minimal wrapper over the system SQLite library. Not thread-safe: the engine
/// uses one connection from its own serial queue.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { "SQLite: \(message)" }
    }

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `path == nil` opens a private in-memory database.
    init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path ?? ":memory:", &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(db)
            throw Failure(message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { close() }

    func close() {
        for (_, s) in statements { sqlite3_finalize(s) }
        statements.removeAll()
        if let db { sqlite3_close(db) }
        db = nil
    }

    var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw Failure(message: "\(msg) in \(sql.prefix(120))")
        }
    }

    enum Value {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    struct Row {
        fileprivate let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return isNull(i) ? nil : Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
        func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw Failure(message: "\(errorMessage) in \(sql.prefix(160))")
        }
        statements[sql] = s
        return s
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ s: OpaquePointer, _ args: [Value]) {
        for (n, v) in args.enumerated() {
            let i = Int32(n + 1)
            switch v {
            case .null: sqlite3_bind_null(s, i)
            case .int(let x): sqlite3_bind_int64(s, i, x)
            case .double(let x): sqlite3_bind_double(s, i, x)
            case .text(let x): sqlite3_bind_text(s, i, x, -1, SQLiteDatabase.transient)
            case .blob(let d):
                _ = d.withUnsafeBytes { p in
                    sqlite3_bind_blob(s, i, p.baseAddress, Int32(d.count), SQLiteDatabase.transient)
                }
            }
        }
    }

    /// Run a statement without results.
    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        let s = try prepare(sql)
        bind(s, args)
        let rc = sqlite3_step(s)
        defer { sqlite3_reset(s) }
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw Failure(message: "\(errorMessage) in \(sql.prefix(160))")
        }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: [Value] = [], _ each: (Row) throws -> Void) throws {
        let s = try prepare(sql)
        bind(s, args)
        defer { sqlite3_reset(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(message: "\(errorMessage) in \(sql.prefix(160))") }
            try each(Row(stmt: s))
        }
    }

    func scalar(_ sql: String, _ args: [Value] = []) throws -> Int64? {
        var out: Int64?
        try query(sql, args) { row in if out == nil, !row.isNull(0) { out = row.int(0) } }
        return out
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

extension SQLiteDatabase.Value {
    static func optText(_ s: String?) -> Self { s.map { .text($0) } ?? .null }
    static func optDouble(_ d: Double?) -> Self { d.map { .double($0) } ?? .null }
}
