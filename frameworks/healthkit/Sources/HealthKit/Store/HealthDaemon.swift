import Foundation

// MARK: - Consent (test hook / developer default; the real consent UI is round R6)

/// How far back a read grant reaches (`authorization.md` §5).
public enum YcodeHistoricalRange: Sendable {
    case allRecordedData
    case past30Days
}

/// What the store asks the user: the types never presented to this client before.
public struct YcodeConsentRequest: Sendable {
    public let client: YcodeHealthClient
    public let shareTypes: [HKSampleType]
    public let readTypes: [HKObjectType]
}

/// The user's answer: the identifiers turned on in each section.
public struct YcodeConsentAnswer: Sendable {
    public var share: Set<String>
    public var read: Set<String>
    public var historicalRange: YcodeHistoricalRange
    /// When the user answered (defaults to now); the historical bound is computed from it.
    public var date: Date?

    public init(share: Set<String>, read: Set<String>, historicalRange: YcodeHistoricalRange = .allRecordedData,
                date: Date? = nil) {
        self.share = share
        self.read = read
        self.historicalRange = historicalRange
        self.date = date
    }

    /// "Select All" then "Allow".
    public static func allowAll(_ request: YcodeConsentRequest, historicalRange: YcodeHistoricalRange = .allRecordedData,
                                date: Date? = nil) -> YcodeConsentAnswer {
        YcodeConsentAnswer(share: Set(request.shareTypes.map(\.identifier)), read: Set(request.readTypes.map(\.identifier)),
                           historicalRange: historicalRange, date: date)
    }
    /// "Don't Allow": every type presented and denied.
    public static let denyAll = YcodeConsentAnswer(share: [], read: [])
}

/// Answers authorization requests. Return nil to cancel (code 7).
public typealias YcodeConsentResponder = @Sendable (YcodeConsentRequest) -> YcodeConsentAnswer?

// MARK: - Change sets

struct ChangeSet: Sendable {
    var added: [ObjectRecord] = []
    var deleted: [TombstoneRecord] = []
    var types: Set<String> {
        Set(added.map(\.type)).union(deleted.map(\.type))
    }
    var isEmpty: Bool { added.isEmpty && deleted.isEmpty }
}

struct AuthRow: Sendable {
    var shareStatus: Int = 0   // 0 not presented, 1 denied, 2 authorized
    var readStatus: Int = 0    // 0 not presented, 1 denied, 2 granted
    var earliest: Double?
    var decidedAt: Double = 0
    var determined: Bool { shareStatus != 0 || readStatus != 0 }
}

enum SortKey: Sendable {
    case startDate, endDate, quantity, duration
}

struct StatisticsInput: Sendable {
    var records: [ObjectRecord]
    /// Bundle identifiers, highest priority first.
    var priority: [String]
}

// MARK: - The engine

/// Ycode's HealthKit store engine (`design.md` §3–§6): one SQLite database, the
/// authorization store, the change journal and the query/statistics back end.
/// Today it runs in-process; every entry point takes value-type records and a
/// client identity so that a later round can put it behind a socket/XPC daemon.
public final class YcodeHealthDaemon: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.ycode.healthkit.daemon")
    private var db: SQLiteDatabase
    public let databaseURL: URL?
    private var responder: YcodeConsentResponder = { .allowAll($0) }
    private var live: [UUID: LiveRegistration] = [:]
    var clock: @Sendable () -> Date = { Date() }

    struct LiveRegistration {
        let client: String
        let onChange: (ChangeSet) -> Void
    }

    /// Opens (creating if needed) the store at `databaseURL`; nil keeps it in memory.
    public init(databaseURL: URL?) throws {
        self.databaseURL = databaseURL
        if let url = databaseURL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        db = try SQLiteDatabase(path: databaseURL?.path)
        if databaseURL != nil { try db.exec("PRAGMA journal_mode=WAL") }
        try db.exec("PRAGMA foreign_keys=ON")
        try db.transaction {
            for s in Schema.statements { try db.exec(s) }
            try db.exec("PRAGMA user_version=\(Schema.version)")
        }
    }

    /// The process-wide store: `YCODE_HEALTHKIT_STORE`, else a per-user data directory.
    public static let shared: YcodeHealthDaemon = {
        let env = ProcessInfo.processInfo.environment
        let url: URL
        if let p = env["YCODE_HEALTHKIT_STORE"] {
            url = URL(fileURLWithPath: p)
        } else {
            #if os(Linux)
            let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
            #else
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            #endif
            url = base.appendingPathComponent("ycode-healthkit/healthdb.sqlite")
        }
        do { return try YcodeHealthDaemon(databaseURL: url) } catch {
            fatalError("ycode-healthkit: cannot open the health store at \(url.path): \(error)")
        }
    }()

    public func close() { queue.sync { db.close() } }

    /// Replace the consent answerer (default: allow everything, all recorded data).
    public func setConsentResponder(_ responder: @escaping YcodeConsentResponder) {
        queue.sync { self.responder = responder }
    }

    /// Explicit source order for a type, highest priority first (the Health app's Data Sources list).
    public func setSourcePriority(_ bundleIdentifiers: [String], for type: HKObjectType) {
        queue.sync {
            try? db.transaction {
                try db.run("DELETE FROM source_priority WHERE type = ?", [.text(type.identifier)])
                for (i, b) in bundleIdentifiers.enumerated() {
                    try db.run("INSERT INTO source_priority(type, bundle_id, rank) VALUES (?, ?, ?)",
                               [.text(type.identifier), .text(b), .int(Int64(i))])
                }
            }
        }
    }

    /// Developer tool: set a characteristic (`interface.md` §6). Values are the enum raw values;
    /// `dateOfBirth` takes "yyyy-mm-dd".
    public func setCharacteristic(_ type: HKCharacteristicTypeIdentifier, value: String?) {
        queue.sync {
            if let value {
                _ = try? db.run("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(type.rawValue), .text(value)])
            } else {
                _ = try? db.run("DELETE FROM settings WHERE key = ?", [.text(type.rawValue)])
            }
        }
    }

    // MARK: change journal

    func register(_ id: UUID, client: String, onChange: @escaping (ChangeSet) -> Void) {
        live[id] = LiveRegistration(client: client, onChange: onChange)
    }
    func unregister(_ id: UUID) { live[id] = nil }

    private func publish(_ change: ChangeSet) {
        guard !change.isEmpty else { return }
        for (_, reg) in live { reg.onChange(change) }
    }

    // MARK: sources

    private func sourceID(_ s: SourceRecord) throws -> Int64 {
        if let id = try db.scalar("SELECT id FROM sources WHERE bundle_id = ?", [.text(s.bundleIdentifier)]) {
            try db.run("UPDATE sources SET name = ? WHERE id = ? AND name != ?", [.text(s.name), .int(id), .text(s.name)])
            return id
        }
        try db.run("INSERT INTO sources(bundle_id, name) VALUES (?, ?)", [.text(s.bundleIdentifier), .text(s.name)])
        return db.lastInsertRowID
    }

    private func revisionID(_ r: SourceRevisionRecord, sourceID: Int64) throws -> Int64 {
        let args: [SQLiteDatabase.Value] = [.int(sourceID), .optText(r.version), .optText(r.productType),
                                            .int(Int64(r.osMajor)), .int(Int64(r.osMinor)), .int(Int64(r.osPatch))]
        if let id = try db.scalar("""
            SELECT id FROM source_revisions WHERE source_id = ? AND version IS ? AND product_type IS ?
              AND os_major = ? AND os_minor = ? AND os_patch = ?
            """, args) { return id }
        try db.run("""
            INSERT INTO source_revisions(source_id, version, product_type, os_major, os_minor, os_patch)
            VALUES (?, ?, ?, ?, ?, ?)
            """, args)
        return db.lastInsertRowID
    }

    private func deviceID(_ d: DeviceRecord?) throws -> SQLiteDatabase.Value {
        guard let d else { return .null }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let text = String(decoding: try enc.encode(d), as: UTF8.self)
        if let id = try db.scalar("SELECT id FROM devices WHERE record = ?", [.text(text)]) { return .int(id) }
        try db.run("INSERT INTO devices(record) VALUES (?)", [.text(text)])
        return .int(db.lastInsertRowID)
    }

    private func nextAnchor() throws -> Int64 {
        try db.run("UPDATE anchor_seq SET value = value + 1 WHERE id = 1")
        return try db.scalar("SELECT value FROM anchor_seq WHERE id = 1") ?? 0
    }

    func currentAnchor() -> Int64 { (try? db.scalar("SELECT value FROM anchor_seq WHERE id = 1")) ?? 0 }

    // MARK: authorization store

    func authRows(_ client: String) -> [String: AuthRow] {
        var out: [String: AuthRow] = [:]
        try? db.query("SELECT type, share_status, read_status, earliest, decided_at FROM authorization WHERE bundle_id = ?",
                      [.text(client)]) { row in
            out[row.text(0)!] = AuthRow(shareStatus: Int(row.int(1)), readStatus: Int(row.int(2)),
                                       earliest: row.optDouble(3), decidedAt: row.double(4))
        }
        return out
    }

    func authRow(_ client: String, _ type: String) -> AuthRow {
        var out = AuthRow()
        try? db.query("SELECT share_status, read_status, earliest, decided_at FROM authorization WHERE bundle_id = ? AND type = ?",
                      [.text(client), .text(type)]) { row in
            out = AuthRow(shareStatus: Int(row.int(0)), readStatus: Int(row.int(1)), earliest: row.optDouble(2),
                          decidedAt: row.double(3))
        }
        return out
    }

    func requestAuthorization(client: YcodeHealthClient, share: [HKSampleType], read: [HKObjectType]) -> HKError? {
        let rows = authRows(client.bundleIdentifier)
        let newShare = share.filter { (rows[$0.identifier]?.shareStatus ?? 0) == 0 }
        let newRead = read.filter { (rows[$0.identifier]?.readStatus ?? 0) == 0 }
        if newShare.isEmpty && newRead.isEmpty { return nil }
        guard let answer = responder(YcodeConsentRequest(client: client, shareTypes: newShare, readTypes: newRead)) else {
            return HKError(.errorUserCanceled)
        }
        let when = (answer.date ?? clock()).t
        let earliest: Double? = answer.historicalRange == .past30Days ? when - 30 * 86400 : nil
        do {
            try db.transaction {
                let sid = try sourceID(client.sourceRecord)
                try db.run("UPDATE sources SET first_authorized = ? WHERE id = ? AND first_authorized IS NULL",
                           [.double(when), .int(sid)])
                for t in newShare {
                    try db.run("""
                        INSERT INTO authorization(bundle_id, type, share_status, decided_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(bundle_id, type) DO UPDATE SET share_status = excluded.share_status
                        """, [.text(client.bundleIdentifier), .text(t.identifier),
                              .int(answer.share.contains(t.identifier) ? 2 : 1), .double(when)])
                }
                for t in newRead {
                    let granted = answer.read.contains(t.identifier)
                    try db.run("""
                        INSERT INTO authorization(bundle_id, type, read_status, earliest, decided_at) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(bundle_id, type) DO UPDATE SET read_status = excluded.read_status,
                            earliest = excluded.earliest, decided_at = excluded.decided_at
                        """, [.text(client.bundleIdentifier), .text(t.identifier), .int(granted ? 2 : 1),
                              granted ? .optDouble(earliest) : .null, .double(when)])
                }
            }
        } catch {
            return HKError(.errorDatabaseInaccessible, message: "\(error)")
        }
        return nil
    }

    func requestStatus(client: String, share: [HKSampleType], read: [HKObjectType]) -> Int {
        let rows = authRows(client)
        let pending = share.contains { (rows[$0.identifier]?.shareStatus ?? 0) == 0 }
            || read.contains { (rows[$0.identifier]?.readStatus ?? 0) == 0 }
        return pending ? 1 : 2
    }

    /// Gate for reads: never-presented types answer code 5.
    /// Correlation types cannot be requested; their member types carry the authorization.
    static func authorizationTypes(_ type: String) -> [String] {
        switch type {
        case HKCorrelationTypeIdentifier.bloodPressure.rawValue:
            return [HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue, HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue]
        case HKCorrelationTypeIdentifier.food.rawValue:
            return quantityTypeTable.map(\.identifier).filter { $0.hasPrefix("HKQuantityTypeIdentifierDietary") }
        default:
            return [type]
        }
    }

    /// Gate for reads: never-presented types answer code 5.
    private func readGate(_ client: String, _ types: [String]) -> HKError? {
        let rows = authRows(client)
        for t in types {
            let candidates = YcodeHealthDaemon.authorizationTypes(t)
            if !candidates.contains(where: { rows[$0]?.determined ?? false }) { return .notDetermined }
        }
        return nil
    }

    /// Gate for writes: never presented at all → 5; presented without share permission → 4.
    private func shareGate(_ client: String, _ type: String) -> HKError? {
        let row = authRow(client, type)
        switch row.shareStatus {
        case 2: return nil
        case 0 where row.readStatus == 0: return .notDetermined
        default: return .notAuthorized
        }
    }

    /// May `client` see record `r`? (`queries.md` §6.6, §7; `authorization.md` §3, §5)
    private func readable(_ r: (type: String, source: String, start: Double), client: String,
                          rows: [String: AuthRow], forStatistics: Bool) -> Bool {
        let own = r.source == client
        let types = YcodeHealthDaemon.authorizationTypes(r.type)
        if !own && !types.contains(where: { rows[$0]?.readStatus == 2 }) { return false }
        let earliest = types.compactMap { rows[$0]?.earliest }.max()
        if let e = earliest, r.start < e, forStatistics || !own { return false }
        return true
    }

    // MARK: loading

    private static let selectColumns = """
        SELECT o.anchor, o.uuid, o.kind, o.type, o.start, o."end", s.bundle_id, s.name, r.version, r.product_type,
               r.os_major, r.os_minor, r.os_patch, d.record, q.value, q.unit, q.ref, q.count, c.value, w.record,
               (SELECT p.uuid FROM associations a JOIN objects p ON p.anchor = a.parent WHERE a.child = o.anchor AND a.kind = 1 LIMIT 1),
               (SELECT p.uuid FROM associations a JOIN objects p ON p.anchor = a.parent WHERE a.child = o.anchor AND a.kind = 2 LIMIT 1)
        FROM objects o JOIN sources s ON s.id = o.source_id JOIN source_revisions r ON r.id = o.revision_id
        LEFT JOIN devices d ON d.id = o.device_id LEFT JOIN quantity q ON q.anchor = o.anchor
        LEFT JOIN category c ON c.anchor = o.anchor LEFT JOIN workouts w ON w.anchor = o.anchor
        """

    private func load(where clause: String, _ args: [SQLiteDatabase.Value]) throws -> [ObjectRecord] {
        var out: [ObjectRecord] = []
        let dec = JSONDecoder()
        try db.query(YcodeHealthDaemon.selectColumns + " WHERE " + clause + " ORDER BY o.anchor", args) { row in
            var r = ObjectRecord(uuid: UUID(uuidString: row.text(1)!)!, kind: RecordKind(rawValue: Int(row.int(2)))!,
                                 type: row.text(3)!, start: row.double(4), end: row.double(5))
            r.anchor = row.int(0)
            r.revision = SourceRevisionRecord(source: SourceRecord(bundleIdentifier: row.text(6)!, name: row.text(7)!),
                                              version: row.text(8), productType: row.text(9),
                                              osMajor: Int(row.int(10)), osMinor: Int(row.int(11)), osPatch: Int(row.int(12)))
            if let d = row.text(13) { r.device = try? dec.decode(DeviceRecord.self, from: Data(d.utf8)) }
            if !row.isNull(14) {
                r.value = row.double(14)
                r.unit = row.text(15) ?? ""
                r.ref = row.double(16)
                r.count = Int(row.int(17))
            }
            if !row.isNull(18) { r.categoryValue = Int(row.int(18)) }
            if let w = row.text(19) { r.workout = try? dec.decode(WorkoutRecord.self, from: Data(w.utf8)) }
            r.correlationParent = row.text(20).flatMap(UUID.init(uuidString:))
            r.workoutParent = row.text(21).flatMap(UUID.init(uuidString:))
            out.append(r)
        }
        guard !out.isEmpty else { return out }
        // metadata
        var byAnchor: [Int64: Int] = [:]
        for (i, r) in out.enumerated() { byAnchor[r.anchor] = i }
        for chunk in stride(from: 0, to: out.count, by: 500) {
            let anchors = out[chunk..<min(chunk + 500, out.count)].map(\.anchor)
            let list = anchors.map(String.init).joined(separator: ",")
            try db.query("SELECT anchor, key, kind, text, integer, number, unit FROM metadata WHERE anchor IN (\(list))") { row in
                guard let i = byAnchor[row.int(0)] else { return }
                let v: MetadataValue
                switch row.int(2) {
                case 1: v = .string(row.text(3) ?? "")
                case 2: v = .int(row.int(4))
                case 3: v = .double(row.double(5))
                case 4: v = .bool(row.int(4) != 0)
                case 5: v = .date(row.double(5))
                default: v = .quantity(value: row.double(5), unit: row.text(6) ?? "count")
                }
                if out[i].metadata == nil { out[i].metadata = [:] }
                out[i].metadata![row.text(1)!] = v
            }
        }
        // correlation members
        for i in out.indices where out[i].kind == .correlation {
            out[i].members = try load(where: "o.anchor IN (SELECT child FROM associations WHERE parent = ? AND kind = 1)",
                                      [.int(out[i].anchor)])
        }
        return out
    }

    private func loadCandidates(types: [String], node: PredicateNode?, extra: String = "",
                                _ extraArgs: [SQLiteDatabase.Value] = []) throws -> [ObjectRecord] {
        guard !types.isEmpty else { return [] }
        var clause = "o.type IN (\(types.map { _ in "?" }.joined(separator: ",")))"
        var args: [SQLiteDatabase.Value] = types.map { .text($0) }
        let b: (start: Double?, end: Double?) = node?.coarseBounds ?? (nil, nil)
        if let s = b.start { clause += " AND o.\"end\" >= ?"; args.append(.double(s)) }
        if let e = b.end { clause += " AND o.start <= ?"; args.append(.double(e)) }
        if !extra.isEmpty { clause += " AND " + extra; args += extraArgs }
        return try load(where: clause, args)
    }

    // MARK: saving

    func save(_ objects: [ObjectRecord], client: YcodeHealthClient) -> HKError? {
        // authorization: every concrete type written (correlation members instead of the correlation)
        var types = Set<String>()
        for o in objects {
            if o.kind == .correlation { for m in o.members ?? [] { types.insert(m.type) } } else { types.insert(o.type) }
        }
        for t in types.sorted() { if let e = shareGate(client.bundleIdentifier, t) { return e } }
        var change = ChangeSet()
        do {
            try db.transaction {
                let sid = try sourceID(client.sourceRecord)
                let rid = try revisionID(client.revisionRecord, sourceID: sid)
                for o in objects {
                    try insert(o, sourceID: sid, revisionID: rid, client: client, change: &change)
                }
            }
        } catch {
            return HKError(.errorDatabaseInaccessible, message: "\(error)")
        }
        publish(change)
        return nil
    }

    private func exists(_ uuid: UUID) throws -> Int64? {
        if let a = try db.scalar("SELECT anchor FROM objects WHERE uuid = ?", [.text(uuid.uuidString)]) { return a }
        if try db.scalar("SELECT anchor FROM tombstones WHERE uuid = ?", [.text(uuid.uuidString)]) != nil { return -1 }
        return nil
    }

    @discardableResult
    private func insert(_ input: ObjectRecord, sourceID sid: Int64, revisionID rid: Int64, client: YcodeHealthClient,
                        change: inout ChangeSet) throws -> Int64? {
        if let a = try exists(input.uuid) { return a >= 0 ? a : nil }   // resave: no-op
        var o = input
        o.revision = client.revisionRecord
        // sync identifiers (`queries.md` §9)
        if let syncID = o.syncIdentifier {
            let version = o.syncVersion ?? 0
            var existing: (anchor: Int64, version: Double)?
            try db.query("SELECT anchor, version FROM sync_ids WHERE source_id = ? AND type = ? AND sync_id = ?",
                         [.int(sid), .text(o.type), .text(syncID)]) { row in existing = (row.int(0), row.double(1)) }
            if let existing {
                guard version > existing.version else { return nil }        // lower or equal: ignored
                if let old = try load(where: "o.anchor = ?", [.int(existing.anchor)]).first {
                    change.deleted.append(try tombstone(old, sourceID: sid))
                }
            }
        }
        // correlation members first, so they carry lower anchors
        var memberAnchors: [Int64] = []
        if o.kind == .correlation {
            var stored: [ObjectRecord] = []
            for m in o.members ?? [] {
                if let a = try insert(m, sourceID: sid, revisionID: rid, client: client, change: &change) {
                    memberAnchors.append(a)
                    var mm = m
                    mm.revision = client.revisionRecord
                    mm.anchor = a
                    mm.correlationParent = o.uuid
                    stored.append(mm)
                }
            }
            o.members = stored
        }
        let anchor = try nextAnchor()
        o.anchor = anchor
        try db.run("""
            INSERT INTO objects(anchor, uuid, kind, type, source_id, revision_id, device_id, start, "end", created)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.int(anchor), .text(o.uuid.uuidString), .int(Int64(o.kind.rawValue)), .text(o.type), .int(sid),
                  .int(rid), try deviceID(o.device), .double(o.start), .double(o.end), .double(clock().t)])
        switch o.kind {
        case .quantity:
            try db.run("INSERT INTO quantity(anchor, value, unit, ref, count) VALUES (?, ?, ?, ?, ?)",
                       [.int(anchor), .double(o.value), .text(o.unit), .double(o.ref), .int(Int64(o.count))])
        case .category:
            try db.run("INSERT INTO category(anchor, value) VALUES (?, ?)", [.int(anchor), .int(Int64(o.categoryValue))])
        case .workout:
            let w = o.workout!
            try db.run("INSERT INTO workouts(anchor, activity_type, duration, record) VALUES (?, ?, ?, ?)",
                       [.int(anchor), .int(Int64(w.activityType)), .double(w.duration),
                        .text(String(decoding: try JSONEncoder().encode(w), as: UTF8.self))])
        case .correlation:
            for m in memberAnchors {
                try db.run("INSERT OR IGNORE INTO associations(parent, child, kind) VALUES (?, ?, 1)", [.int(anchor), .int(m)])
            }
        }
        for (key, v) in o.metadata ?? [:] {
            var kind: Int64 = 0
            var text: SQLiteDatabase.Value = .null, integer: SQLiteDatabase.Value = .null
            var number: SQLiteDatabase.Value = .null, unit: SQLiteDatabase.Value = .null
            switch v {
            case .string(let s): kind = 1; text = .text(s)
            case .int(let i): kind = 2; integer = .int(i); number = .double(Double(i))
            case .double(let d): kind = 3; number = .double(d)
            case .bool(let b): kind = 4; integer = .int(b ? 1 : 0); number = .double(b ? 1 : 0)
            case .date(let t): kind = 5; number = .double(t)
            case .quantity(let q, let u): kind = 6; number = .double(q); unit = .text(u)
            }
            try db.run("INSERT INTO metadata(anchor, key, kind, text, integer, number, unit) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [.int(anchor), .text(key), .int(kind), text, integer, number, unit])
        }
        if let syncID = o.syncIdentifier {
            try db.run("INSERT OR REPLACE INTO sync_ids(source_id, type, sync_id, version, anchor) VALUES (?, ?, ?, ?, ?)",
                       [.int(sid), .text(o.type), .text(syncID), .double(o.syncVersion ?? 0), .int(anchor)])
        }
        change.added.append(o)
        return anchor
    }

    private func tombstone(_ r: ObjectRecord, sourceID sid: Int64) throws -> TombstoneRecord {
        let anchor = try nextAnchor()
        let md = try r.metadata.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.run("INSERT INTO tombstones(anchor, uuid, type, source_id, metadata, deleted_at) VALUES (?, ?, ?, ?, ?, ?)",
                   [.int(anchor), .text(r.uuid.uuidString), .text(r.type), .int(sid), .optText(md), .double(clock().t)])
        try db.run("DELETE FROM objects WHERE anchor = ?", [.int(r.anchor)])
        return TombstoneRecord(anchor: anchor, uuid: r.uuid, type: r.type, sourceBundle: r.sourceBundle, metadata: r.metadata)
    }

    /// Associate saved samples with a workout (`addSamples(_:to:)`).
    func associate(_ samples: [ObjectRecord], workout: UUID, client: YcodeHealthClient) -> HKError? {
        if let e = save(samples, client: client) { return e }
        do {
            try db.transaction {
                guard let w = try db.scalar("SELECT anchor FROM objects WHERE uuid = ?", [.text(workout.uuidString)]) else {
                    throw HKError(.errorInvalidArgument, message: "Workout not found")
                }
                for s in samples {
                    if let a = try db.scalar("SELECT anchor FROM objects WHERE uuid = ?", [.text(s.uuid.uuidString)]) {
                        try db.run("INSERT OR IGNORE INTO associations(parent, child, kind) VALUES (?, ?, 2)", [.int(w), .int(a)])
                    }
                }
            }
        } catch let e as HKError {
            return e
        } catch {
            return HKError(.errorDatabaseInaccessible, message: "\(error)")
        }
        return nil
    }

    // MARK: deleting (`queries.md` §8)

    func delete(_ uuids: [UUID], client: String) -> HKError? {
        do {
            var targets: [ObjectRecord] = []
            for u in uuids {
                // not found, already deleted, never saved, or another source's object: code 3
                guard let r = try load(where: "o.uuid = ?", [.text(u.uuidString)]).first, r.sourceBundle == client else {
                    return .deletionNotFound
                }
                targets.append(r)
            }
            for t in Set(targets.map(\.type)).sorted() where !(TypeRegistry.type(t) is HKCorrelationType) {
                if let e = shareGate(client, t) { return e }
            }
            var change = ChangeSet()
            try db.transaction {
                for r in targets {
                    let sid = try sourceID(r.revision!.source)
                    change.deleted.append(try tombstone(r, sourceID: sid))
                }
            }
            publish(change)
            return nil
        } catch {
            return HKError(.errorDatabaseInaccessible, message: "\(error)")
        }
    }

    func deleteObjects(type: String, node: PredicateNode?, client: String) -> Result<Int, HKError> {
        if let e = readGate(client, [type]) { return .failure(e) }
        do {
            let own = try loadCandidates(types: [type], node: node, extra: "s.bundle_id = ?", [.text(client)])
                .filter { PredicateEvaluator.matches(node, $0) }
            if own.isEmpty { return .success(0) }
            if !(TypeRegistry.type(type) is HKCorrelationType), let e = shareGate(client, type) { return .failure(e) }
            var change = ChangeSet()
            try db.transaction {
                for r in own {
                    let sid = try sourceID(r.revision!.source)
                    change.deleted.append(try tombstone(r, sourceID: sid))
                }
            }
            publish(change)
            return .success(own.count)
        } catch {
            return .failure(HKError(.errorDatabaseInaccessible, message: "\(error)"))
        }
    }

    // MARK: queries

    func samples(types: [String], node: PredicateNode?, limit: Int, sort: [(SortKey, Bool)],
                 client: String) -> Result<[ObjectRecord], HKError> {
        if let e = readGate(client, types) { return .failure(e) }
        do {
            let rows = authRows(client)
            var out = try loadCandidates(types: types, node: node).filter {
                readable(($0.type, $0.sourceBundle, $0.start), client: client, rows: rows, forStatistics: false)
                    && PredicateEvaluator.matches(node, $0)
            }
            let keys = sort.isEmpty ? [(SortKey.startDate, true)] : sort
            out.sort { a, b in
                for (k, asc) in keys {
                    let x: Double, y: Double
                    switch k {
                    case .startDate: x = a.start; y = b.start
                    case .endDate: x = a.end; y = b.end
                    case .quantity: x = a.ref; y = b.ref
                    case .duration: x = a.workout?.duration ?? a.duration; y = b.workout?.duration ?? b.duration
                    }
                    if x != y { return asc ? x < y : x > y }
                }
                return a.anchor < b.anchor
            }
            if limit > 0, out.count > limit { out = Array(out.prefix(limit)) }
            return .success(out)
        } catch {
            return .failure(HKError(.errorDatabaseInaccessible, message: "\(error)"))
        }
    }

    struct AnchoredResult: Sendable {
        var added: [ObjectRecord]
        var deleted: [TombstoneRecord]
        var anchor: Int64
    }

    /// Objects and tombstones after `anchor`, in anchor order; the limit counts both (`queries.md` §4).
    func anchored(types: [String], node: PredicateNode?, after anchor: Int64, limit: Int,
                  client: String) -> Result<AnchoredResult, HKError> {
        if let e = readGate(client, types) { return .failure(e) }
        do {
            let rows = authRows(client)
            let added = try loadCandidates(types: types, node: nil, extra: "o.anchor > ?", [.int(anchor)]).filter {
                readable(($0.type, $0.sourceBundle, $0.start), client: client, rows: rows, forStatistics: false)
                    && PredicateEvaluator.matches(node, $0)
            }
            var deleted: [TombstoneRecord] = []
            let list = types.map { _ in "?" }.joined(separator: ",")
            try db.query("""
                SELECT t.anchor, t.uuid, t.type, s.bundle_id, t.metadata FROM tombstones t JOIN sources s ON s.id = t.source_id
                WHERE t.anchor > ? AND t.type IN (\(list)) ORDER BY t.anchor
                """, [.int(anchor)] + types.map { .text($0) }) { row in
                let md = row.text(4).flatMap { try? JSONDecoder().decode([String: MetadataValue].self, from: Data($0.utf8)) }
                let t = TombstoneRecord(anchor: row.int(0), uuid: UUID(uuidString: row.text(1)!)!, type: row.text(2)!,
                                        sourceBundle: row.text(3)!, metadata: md)
                if t.sourceBundle == client || rows[t.type]?.readStatus == 2 { deleted.append(t) }
            }
            enum Item { case a(ObjectRecord), d(TombstoneRecord) }
            var items: [(Int64, Item)] = added.map { ($0.anchor, .a($0)) } + deleted.map { ($0.anchor, .d($0)) }
            items.sort { $0.0 < $1.0 }
            var newAnchor = max(anchor, currentAnchor())
            if limit > 0, items.count > limit {
                items = Array(items.prefix(limit))
                newAnchor = items.last!.0
            }
            var out = AnchoredResult(added: [], deleted: [], anchor: newAnchor)
            for (_, i) in items {
                switch i {
                case .a(let r): out.added.append(r)
                case .d(let t): out.deleted.append(t)
                }
            }
            return .success(out)
        } catch {
            return .failure(HKError(.errorDatabaseInaccessible, message: "\(error)"))
        }
    }

    func correlations(type: String, node: PredicateNode?, samplePredicates: [(String, PredicateNode?)],
                      client: String) -> Result<[ObjectRecord], HKError> {
        let memberTypes = samplePredicates.map(\.0)
        if let e = readGate(client, memberTypes.isEmpty ? [type] : memberTypes) { return .failure(e) }
        do {
            let rows = authRows(client)
            let out = try loadCandidates(types: [type], node: node).filter { c in
                guard node.map({ PredicateEvaluator.matches($0, c) }) ?? true else { return false }
                let members = (c.members ?? []).filter {
                    readable(($0.type, $0.sourceBundle, $0.start), client: client, rows: rows, forStatistics: false)
                }
                guard !members.isEmpty else { return false }
                return samplePredicates.allSatisfy { (t, p) in
                    members.contains { m in m.type == t && (p.map { PredicateEvaluator.matches($0, m) } ?? true) }
                }
            }
            return .success(out)
        } catch {
            return .failure(HKError(.errorDatabaseInaccessible, message: "\(error)"))
        }
    }

    func sources(type: String, node: PredicateNode?, client: String) -> Result<[SourceRecord], HKError> {
        switch samples(types: [type], node: node, limit: 0, sort: [], client: client) {
        case .failure(let e): return .failure(e)
        case .success(let recs):
            var seen = Set<String>()
            var out: [SourceRecord] = []
            for r in recs where seen.insert(r.sourceBundle).inserted { out.append(r.revision!.source) }
            return .success(out)
        }
    }

    /// Records for statistics: the historical bound applies to every source (`queries.md` §6.6).
    func statisticsInput(type: String, node: PredicateNode?, client: String) -> Result<StatisticsInput, HKError> {
        if let e = readGate(client, [type]) { return .failure(e) }
        do {
            let rows = authRows(client)
            let recs = try loadCandidates(types: [type], node: node).filter {
                readable(($0.type, $0.sourceBundle, $0.start), client: client, rows: rows, forStatistics: true)
                    && PredicateEvaluator.matches(node, $0)
            }
            return .success(StatisticsInput(records: recs, priority: try sourcePriority(type)))
        } catch {
            return .failure(HKError(.errorDatabaseInaccessible, message: "\(error)"))
        }
    }

    /// Explicit order first, then the most recently authorized apps (`design.md` §6).
    func sourcePriority(_ type: String) throws -> [String] {
        var out: [String] = []
        try db.query("SELECT bundle_id FROM source_priority WHERE type = ? ORDER BY rank", [.text(type)]) { out.append($0.text(0)!) }
        try db.query("SELECT bundle_id FROM sources ORDER BY first_authorized IS NULL, first_authorized DESC, id DESC") { row in
            let b = row.text(0)!
            if !out.contains(b) { out.append(b) }
        }
        return out
    }

    // MARK: characteristics, preferences, background delivery

    func characteristic(_ type: String, client: String) -> Result<String?, HKError> {
        if let e = readGate(client, [type]) { return .failure(e) }
        var value: String?
        try? db.query("SELECT value FROM settings WHERE key = ?", [.text(type)]) { value = $0.text(0) }
        return .success(value)
    }

    func determined(_ type: String, client: String) -> Bool { authRow(client, type).determined }

    func earliestDates(_ types: [String], client: String) -> [String: Double?] {
        let rows = authRows(client)
        var out: [String: Double?] = [:]
        for t in types { out[t] = rows[t]?.earliest }
        return out
    }

    func setBackgroundDelivery(_ type: String?, frequency: Int?, client: String) {
        if let type {
            if let frequency {
                _ = try? db.run("INSERT OR REPLACE INTO bg_delivery(bundle_id, type, frequency) VALUES (?, ?, ?)",
                            [.text(client), .text(type), .int(Int64(frequency))])
            } else {
                _ = try? db.run("DELETE FROM bg_delivery WHERE bundle_id = ? AND type = ?", [.text(client), .text(type)])
            }
        } else {
            _ = try? db.run("DELETE FROM bg_delivery WHERE bundle_id = ?", [.text(client)])
        }
    }

    /// Diagnostic counts (`count` phase of the probe: P1).
    public func objectCounts() -> [String: Int] {
        queue.sync {
            var out: [String: Int] = [:]
            try? db.query("SELECT type, COUNT(*) FROM objects GROUP BY type") { out[$0.text(0)!] = Int($0.int(1)) }
            return out
        }
    }
}
