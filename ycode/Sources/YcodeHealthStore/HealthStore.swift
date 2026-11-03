// Edits of a shut-down device's HealthKit store (specs/simulator/
// health-simulation.md §6.2–§6.5, §8.2 H-5/H-6, "Ycode implementation").
//
// The store is DEV/data/Library/Health/; healthd owns its files while the
// device runs, so Ycode opens them only while the device is shut down (at a
// cold boot's preparation, before any guest process starts, or from the
// command line when no ycode-simd runs the device). Every edit first copies
// the store's files (with their WAL files) into DEV/ycode-health-backups/.
//
// Grants use only the `authorization` table's documented columns (§6.2,
// §6.4) and only rows healthd made itself when the app (or Ycode's agent)
// asked for access: an app's request writes its rows at once (status 100,
// the `request` value of what it asked), and Ycode then answers them as a
// person tapping Allow would:
//   asked to share and read (request 203)  → status 101 (share and read allowed)
//   asked to read only (request 202)       → status 103 (read allowed; read-only types)
//   revoke                                 → status 104 (both denied)
// Rows of types never asked for are left alone, so the app's own request
// flow stays what decides which types it has.

import CSQLite
import Foundation
import YcodeSimFeatures

public enum HealthStoreError: Error, CustomStringConvertible, Equatable {
    case noStore(String)
    case sqlite(String)
    case notShutDown

    public var description: String {
        switch self {
        case .noStore(let p): "no health store at \(p) (healthd makes it at the device's first boot)"
        case .sqlite(let m): "health store: \(m)"
        case .notShutDown: "the device is running: its health store belongs to healthd until it shuts down"
        }
    }
}

/// Authorization encoding (health-simulation.md §6.4).
public enum HealthAuthorizationCode {
    public static let notDetermined = 100, sharingAuthorized = 101, readDenied = 102, sharingDenied = 103, bothDenied = 104
    public static let neverPresented = [0, 200], readPresented = 202, sharePresented = 203
}

/// A small SQLite connection.
public final class SQLiteDatabase {
    private var db: OpaquePointer?
    public let path: String

    public init(path: String, create: Bool = false) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            db = nil
            throw HealthStoreError.sqlite("\(path): \(m)")
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close(db) }

    public enum Value: Equatable, Sendable {
        case null, int(Int64), real(Double), text(String), blob([UInt8])
        public var int: Int? { if case .int(let v) = self { Int(v) } else if case .real(let d) = self { Int(d) } else { nil } }
        public var real: Double? { if case .real(let v) = self { v } else if case .int(let i) = self { Double(i) } else { nil } }
        public var text: String? { if case .text(let v) = self { v } else { nil } }
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "failed"
            sqlite3_free(err)
            throw HealthStoreError.sqlite(m)
        }
    }

    /// Runs one statement with bound values; returns its rows.
    @discardableResult
    public func query(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HealthStoreError.sqlite(String(cString: sqlite3_errmsg(db)) + " in: " + sql)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(stmt, n)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            case .text(let v): sqlite3_bind_text(stmt, n, v, -1, transient)
            case .blob(let v): v.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(v.count), transient) }
            }
        }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw HealthStoreError.sqlite(String(cString: sqlite3_errmsg(db)) + " in: " + sql) }
            var row: [Value] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    let p = sqlite3_column_blob(stmt, c)
                    row.append(.blob(n > 0 && p != nil ? [UInt8](UnsafeRawBufferPointer(start: p, count: n)) : []))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var changes: Int { Int(sqlite3_changes(db)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// A device's health store (DEV/data/Library/Health).
public struct HealthStore {
    public let directory: String
    public var unprotectedPath: String { directory + "/healthdb.sqlite" }
    public var protectedPath: String { directory + "/healthdb_secure.sqlite" }

    public init(dev: String) { directory = dev + "/data/Library/Health" }
    public init(directory: String) { self.directory = directory }

    public var exists: Bool { FileManager.default.fileExists(atPath: unprotectedPath) }

    /// Seconds since 2001-01-01 (the store's dates, §6.2).
    public static func storeTime(_ d: Date) -> Double { d.timeIntervalSinceReferenceDate }

    // MARK: Backups

    /// Copies the store's database files (with their WAL and shared-memory
    /// files) into `<backups>/<stamp>-<reason>/`, keeping the newest `keep`.
    @discardableResult
    public func backup(into backups: String, reason: String, keep: Int = 5, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        guard exists else { throw HealthStoreError.noStore(directory) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var target = backups + "/" + f.string(from: now) + "-" + reason
        var n = 2
        while fm.fileExists(atPath: target) { target = backups + "/" + f.string(from: now) + "-" + reason + "-\(n)"; n += 1 }
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: directory) where name.hasPrefix("healthdb") {
            try fm.copyItem(atPath: directory + "/" + name, toPath: target + "/" + name)
        }
        let all = ((try? fm.contentsOfDirectory(atPath: backups)) ?? []).sorted()
        for old in all.dropLast(keep) { try? fm.removeItem(atPath: backups + "/" + old) }
        return target
    }

    // MARK: Authorization

    public struct AuthorizationRow: Equatable, Sendable {
        public let sourceID: Int
        public let objectType: Int
        public let status: Int
        public let request: Int
    }

    func open() throws -> SQLiteDatabase {
        guard exists else { throw HealthStoreError.noStore(directory) }
        return try SQLiteDatabase(path: unprotectedPath)
    }

    static let sourcesOf = """
        SELECT s.ROWID FROM sources s JOIN logical_sources l ON s.logical_source_id = l.ROWID WHERE l.bundle_id = ?
        """

    /// The `sources` rows of a bundle id (an app may have several: its own and ones that came by sync).
    public func sourceIDs(bundleID: String) throws -> [Int] {
        try open().query(Self.sourcesOf, [.text(bundleID)]).compactMap { $0.first?.int }
    }

    public func authorizationRows(bundleID: String) throws -> [AuthorizationRow] {
        try open().query("SELECT source_id, object_type, status, request FROM authorization WHERE source_id IN (\(Self.sourcesOf)) "
                         + "ORDER BY source_id, object_type", [.text(bundleID)])
            .map { AuthorizationRow(sourceID: $0[0].int ?? 0, objectType: $0[1].int ?? 0, status: $0[2].int ?? 0, request: $0[3].int ?? 0) }
    }

    public struct GrantResult: Equatable, Sendable, CustomStringConvertible {
        /// Rows of the bundle id (all its sources).
        public var rows = 0
        /// Rows now share-and-read (101), read-only (103) or denied (104).
        public var shared = 0, readOnly = 0, denied = 0
        /// Rows that changed.
        public var changed = 0

        public var description: String {
            rows == 0 ? "no authorization rows yet (the app has not asked for access on this device)"
                : "\(rows) types: \(shared) share and read, \(readOnly) read only, \(denied) denied (\(changed) changed)"
        }
    }

    /// Answers the bundle's own requests: 203 → 101, 202 → 103 (H-6).
    @discardableResult
    public func grant(bundleID: String, now: Date = Date()) throws -> GrantResult {
        let db = try open()
        return try db.transaction {
            let t = SQLiteDatabase.Value.real(Self.storeTime(now))
            var changed = 0
            try db.query("UPDATE authorization SET status = ?, date_modified = ? WHERE source_id IN (\(Self.sourcesOf)) AND request = ? AND status != ?",
                         [.int(Int64(HealthAuthorizationCode.sharingAuthorized)), t, .text(bundleID),
                          .int(Int64(HealthAuthorizationCode.sharePresented)), .int(Int64(HealthAuthorizationCode.sharingAuthorized))])
            changed += db.changes
            try db.query("UPDATE authorization SET status = ?, date_modified = ? WHERE source_id IN (\(Self.sourcesOf)) AND request = ? AND status != ?",
                         [.int(Int64(HealthAuthorizationCode.sharingDenied)), t, .text(bundleID),
                          .int(Int64(HealthAuthorizationCode.readPresented)), .int(Int64(HealthAuthorizationCode.sharingDenied))])
            changed += db.changes
            var r = try summary(db, bundleID)
            r.changed = changed
            return r
        }
    }

    /// Every row of the bundle → 104 (both denied).
    @discardableResult
    public func revoke(bundleID: String, now: Date = Date()) throws -> GrantResult {
        let db = try open()
        return try db.transaction {
            try db.query("UPDATE authorization SET status = ?, date_modified = ? WHERE source_id IN (\(Self.sourcesOf)) AND status != ?",
                         [.int(Int64(HealthAuthorizationCode.bothDenied)), .real(Self.storeTime(now)), .text(bundleID),
                          .int(Int64(HealthAuthorizationCode.bothDenied))])
            var r = try summary(db, bundleID)
            r.changed = db.changes
            return r
        }
    }

    func summary(_ db: SQLiteDatabase, _ bundleID: String) throws -> GrantResult {
        var r = GrantResult()
        for row in try db.query("SELECT status FROM authorization WHERE source_id IN (\(Self.sourcesOf))", [.text(bundleID)]) {
            r.rows += 1
            switch row[0].int {
            case HealthAuthorizationCode.sharingAuthorized: r.shared += 1
            case HealthAuthorizationCode.sharingDenied: r.readOnly += 1
            case HealthAuthorizationCode.bothDenied: r.denied += 1
            default: break
            }
        }
        return r
    }
}
