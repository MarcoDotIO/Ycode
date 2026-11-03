// Shut-down seeding of samples HealthKit does not let apps save
// (health-simulation.md §6.2–§6.5, §8.6 H-13…H-15, round HEALTH-3).
//
// One row each in `objects`, `samples` and the kind table
// (`quantity_samples`, `category_samples`, `ecg_samples`) of
// healthdb_secure.sqlite, with the provenance of the device's own system
// source made on this device (`sync_provenance` 0), `objects.type` 1, a
// fresh UUID and the next `data_id`. Quantities are stored in the type's
// store unit (§3.1: AFib burden as a fraction, wrist temperature in degC,
// breathing disturbances as a count). ECGs get the stored classification of
// §6.5's table, the average heart rate in bpm, the symptoms status and an
// **empty voltage payload**: no waveform (H-14; the payload format is not
// known). Dates are seconds since 2001 (§6.2).
//
// The provenance: a `data_provenances` row of the system source with
// `sync_provenance` 0 is reused when there is one. Otherwise one is made by
// copying a row of this device (the agent's, made when it saved samples, or
// any local one) with `source_id` set to the system source and `device_id`
// to the device's own `source_devices` row; the copy takes every column of
// the row it copies, so Ycode needs to know only the documented ones.
//
// Only types whose store code the spec records can be seeded (§6.3).

import Foundation
import YcodeSimFeatures

public struct HealthSeedResult: Equatable, Sendable, CustomStringConvertible {
    public var seeded: [String: Int] = [:]
    public var provenance: Int64 = 0
    public var madeProvenance = false

    public var total: Int { seeded.values.reduce(0, +) }
    public var description: String {
        "seeded \(total) samples (" + seeded.sorted { $0.key < $1.key }.map { "\(HealthTypes.all[$0.key]?.shortName ?? $0.key) \($0.value)" }
            .joined(separator: ", ") + ") under the system source (provenance \(provenance)\(madeProvenance ? ", new" : ""))"
    }
}

public enum HealthSeedError: Error, CustomStringConvertible, Equatable {
    case noCode(String)
    case noSystemSource
    case noProvenanceToCopy
    case notSeedable(String)

    public var description: String {
        switch self {
        case .noCode(let t): "\(t): no store type code is known for it (health-simulation.md §6.3), so it cannot be seeded"
        case .noSystemSource: "the store has no system source of this device yet (boot the device once)"
        case .noProvenanceToCopy:
            "the store has no sample provenance of this device to copy (write any sample with Ycode's agent first, then seed)"
        case .notSeedable(let t): "\(t) cannot be seeded"
        }
    }
}

extension HealthStore {
    /// Stored ECG classification for a public one (§6.5: 3→1, 4→2, 6→3, 5→4, 1→5, 2→6, 0→0).
    public static func storedECGClassification(_ value: Int) -> Int {
        [0: 0, 1: 3, 2: 4, 3: 6, 4: 5, 5: 1, 6: 2][value] ?? 0
    }

    /// The system source's `sources` ROWID (`local_device` 1).
    public func systemSourceID() throws -> Int? {
        try open().query("SELECT ROWID FROM sources WHERE local_device = 1 ORDER BY ROWID LIMIT 1").first?.first?.int
    }

    func openProtected() throws -> SQLiteDatabase {
        guard FileManager.default.fileExists(atPath: protectedPath) else { throw HealthStoreError.noStore(protectedPath) }
        return try SQLiteDatabase(path: protectedPath)
    }

    /// The columns of a table (to copy a row whole).
    static func columns(_ db: SQLiteDatabase, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1].text : nil }
    }

    /// The device's own `source_devices` row for `model` ("Watch", "iPhone").
    func deviceRow(model: String) throws -> Int? {
        try open().query("SELECT ROWID FROM source_devices WHERE model = ? ORDER BY ROWID LIMIT 1", [.text(model)]).first?.first?.int
    }

    /// A local provenance of the system source (made when missing; see the header).
    func systemProvenance(_ db: SQLiteDatabase, system: Int, model: String) throws -> (Int64, Bool) {
        if let p = try db.query("SELECT ROWID FROM data_provenances WHERE source_id = ? AND sync_provenance = 0 ORDER BY ROWID LIMIT 1",
                                [.int(Int64(system))]).first?.first?.int {
            return (Int64(p), false)
        }
        let agent = try sourceIDs(bundleID: HealthChannel.agentBundleID)
        var template: Int?
        for s in agent {
            template = try db.query("SELECT ROWID FROM data_provenances WHERE source_id = ? AND sync_provenance = 0 ORDER BY ROWID LIMIT 1",
                                    [.int(Int64(s))]).first?.first?.int
            if template != nil { break }
        }
        if template == nil {
            template = try db.query("SELECT ROWID FROM data_provenances WHERE sync_provenance = 0 ORDER BY ROWID LIMIT 1").first?.first?.int
        }
        guard let template else { throw HealthSeedError.noProvenanceToCopy }
        let cols = try Self.columns(db, "data_provenances").filter { $0 != "ROWID" }
        let list = cols.joined(separator: ", ")
        try db.query("INSERT INTO data_provenances (\(list)) SELECT \(list) FROM data_provenances WHERE ROWID = ?", [.int(Int64(template))])
        let id = db.lastInsertRowID
        try db.query("UPDATE data_provenances SET source_id = ? WHERE ROWID = ?", [.int(Int64(system)), .int(id)])
        if let device = try deviceRow(model: model) {
            try db.query("UPDATE data_provenances SET device_id = ? WHERE ROWID = ?", [.int(Int64(device)), .int(id)])
        }
        return (id, true)
    }

    /// Seeds `samples` (read-only or any type with a known code). `model` is
    /// the device's `HKDevice` model ("Watch" on a watch, "iPhone" on a phone).
    @discardableResult
    public func seed(_ samples: [HealthSample], model: String, now: Date = Date()) throws -> HealthSeedResult {
        for s in samples {
            guard let t = HealthTypes.all[s.type] else { throw HealthSeedError.notSeedable(s.type) }
            guard t.storeCode != nil else { throw HealthSeedError.noCode(s.type) }
            guard t.kind == .category || t.kind == .quantity || t.identifier == HealthTypes.ecg else { throw HealthSeedError.notSeedable(s.type) }
            if t.kind == .quantity, s.storeValue() == nil { throw HealthSeedError.notSeedable("\(s.type) in \(s.unit ?? "no unit")") }
        }
        guard let system = try systemSourceID() else { throw HealthSeedError.noSystemSource }
        let db = try openProtected()
        return try db.transaction {
            var result = HealthSeedResult()
            let (prov, made) = try systemProvenance(db, system: system, model: model)
            result.provenance = prov
            result.madeProvenance = made
            let created = SQLiteDatabase.Value.real(Self.storeTime(now))
            for s in samples {
                let t = HealthTypes.all[s.type]!
                var uuid = UUID().uuid
                let bytes = withUnsafeBytes(of: &uuid) { [UInt8]($0) }
                try db.query("INSERT INTO objects (uuid, provenance, type, creation_date) VALUES (?, ?, 1, ?)", [.blob(bytes), .int(prov), created])
                let id = db.lastInsertRowID
                try db.query("INSERT INTO samples (data_id, start_date, end_date, data_type) VALUES (?, ?, ?, ?)",
                             [.int(id), .real(Self.storeTime(s.start)), .real(Self.storeTime(s.end)), .int(Int64(t.storeCode!))])
                if t.identifier == HealthTypes.ecg {
                    let bpm: Double = { if case .number(let n)? = s.metadata["averageHeartRate"] { n } else { 70 } }()
                    let symptoms: Int64 = { if case .number(let n)? = s.metadata["symptomsStatus"] { Int64(n) } else { 1 } }()
                    try db.query("INSERT INTO ecg_samples (data_id, private_classification, average_heart_rate, voltage_payload, symptoms_status) "
                                 + "VALUES (?, ?, ?, ?, ?)",
                                 [.int(id), .int(Int64(Self.storedECGClassification(Int(s.value)))), .real(bpm), .blob([]), .int(symptoms)])
                } else if t.kind == .category {
                    try db.query("INSERT INTO category_samples (data_id, value) VALUES (?, ?)", [.int(id), .int(Int64(s.value))])
                } else {
                    try db.query("INSERT INTO quantity_samples (data_id, quantity) VALUES (?, ?)", [.int(id), .real(s.storeValue()!)])
                }
                result.seeded[s.type, default: 0] += 1
            }
            return result
        }
    }
}
