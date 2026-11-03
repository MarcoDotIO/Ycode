import Foundation
import Testing
@testable import YcodeHealthStore
import YcodeSimFeatures

/// HEALTH-1/2 (health-simulation.md §6.2, §6.4, §8.2): grants answered in a
/// shut-down device's store, on a stand-in store with the spec's documented
/// tables and columns.
struct HealthStoreGrantTests {
    /// A store directory with two apps' rows: the agent asked to share and
    /// read HR and steps; an app asked to read HR (shareable) and AFib burden
    /// (read only), and to share steps.
    func makeStore() throws -> (HealthStore, String) {
        let dir = NSTemporaryDirectory() + "ycode-health-store-\(UUID().uuidString)"
        let health = dir + "/data/Library/Health"
        try FileManager.default.createDirectory(atPath: health, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: health + "/healthdb.sqlite", create: true)
        try db.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE logical_sources (ROWID INTEGER PRIMARY KEY, bundle_id TEXT, owner_bundle_id TEXT);
            CREATE TABLE sources (ROWID INTEGER PRIMARY KEY, uuid BLOB, name TEXT, logical_source_id INTEGER, local_device INTEGER);
            CREATE TABLE authorization (source_id INTEGER, object_type INTEGER, status INTEGER, request INTEGER, mode INTEGER,
                                        date_modified REAL, modification_epoch INTEGER, provenance INTEGER, UNIQUE(source_id, object_type));
            INSERT INTO logical_sources VALUES (1, 'com.apple.health.X', NULL), (2, 'dev.ycode.health', NULL), (3, 'dev.example.app', NULL);
            INSERT INTO sources VALUES (1, NULL, 'System', 1, 1), (2, NULL, 'YcodeHealth', 2, 0), (3, NULL, 'App', 3, 0), (4, NULL, 'App', 3, 0);
            INSERT INTO authorization VALUES (2, 5, 100, 203, 0, 0, 1, 0), (2, 7, 100, 203, 0, 0, 1, 0),
                                             (3, 5, 100, 202, 0, 0, 1, 0), (3, 248, 100, 202, 0, 0, 1, 0), (3, 7, 100, 203, 0, 0, 1, 0),
                                             (4, 5, 100, 0, 0, 0, 1, 0), (1, 5, 101, 203, 0, 0, 1, 0);
            """)
        return (HealthStore(dev: dir), dir)
    }

    @Test func agentGrant() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try store.sourceIDs(bundleID: "dev.ycode.health") == [2])
        let r = try store.grant(bundleID: "dev.ycode.health", now: Date(timeIntervalSinceReferenceDate: 100))
        #expect(r.rows == 2 && r.shared == 2 && r.changed == 2)
        #expect(try store.authorizationRows(bundleID: "dev.ycode.health").map(\.status) == [101, 101])
        // Again: nothing changes.
        #expect(try store.grant(bundleID: "dev.ycode.health").changed == 0)
        // Other sources untouched.
        #expect(try store.authorizationRows(bundleID: "dev.example.app").allSatisfy { $0.status == 100 })
    }

    @Test func appGrantFollowsWhatTheAppAsked() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = try store.grant(bundleID: "dev.example.app")
        #expect(r.rows == 4 && r.shared == 1 && r.readOnly == 2 && r.changed == 3)
        let rows = try store.authorizationRows(bundleID: "dev.example.app")
        #expect(rows.first { $0.sourceID == 3 && $0.objectType == 7 }?.status == 101)
        #expect(rows.first { $0.sourceID == 3 && $0.objectType == 248 }?.status == 103)
        #expect(rows.first { $0.sourceID == 3 && $0.objectType == 5 }?.status == 103)
        // A type never presented is left as it was.
        #expect(rows.first { $0.sourceID == 4 }?.status == 100)
        let v = try store.revoke(bundleID: "dev.example.app")
        #expect(v.denied == 4 && v.changed == 4)
    }

    @Test func noRowsForAnAppThatNeverAsked() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = try store.grant(bundleID: "dev.never.asked")
        #expect(r.rows == 0 && r.changed == 0)
        #expect(r.description.contains("has not asked"))
    }

    @Test func backupsCopyTheStoreAndKeepTheNewest() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let backups = dir + "/ycode-health-backups"
        var made: [String] = []
        for i in 0..<4 {
            made.append(try store.backup(into: backups, reason: "grants", keep: 3, now: Date(timeIntervalSince1970: 1_793_400_000 + Double(i))))
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: backups).sorted()
        #expect(left.count == 3)
        #expect(!FileManager.default.fileExists(atPath: made[0]))
        let copy = try SQLiteDatabase(path: made[3] + "/healthdb.sqlite")
        #expect(try copy.query("SELECT count(*) FROM authorization").first?.first?.int == 7)
    }

    @Test func missingStore() {
        let s = HealthStore(dev: "/nonexistent-\(UUID().uuidString)")
        #expect(!s.exists)
        #expect(throws: HealthStoreError.self) { try s.grant(bundleID: "x") }
    }
}

/// HEALTH-3 (health-simulation.md §6.5, H-13/H-14): seeded rows on a
/// stand-in store with the documented tables.
struct HealthSeedTests {
    func makeStore(systemProvenance: Bool) throws -> (HealthStore, String) {
        let dir = NSTemporaryDirectory() + "ycode-health-seed-\(UUID().uuidString)"
        let health = dir + "/data/Library/Health"
        try FileManager.default.createDirectory(atPath: health, withIntermediateDirectories: true)
        let u = try SQLiteDatabase(path: health + "/healthdb.sqlite", create: true)
        try u.execute("""
            CREATE TABLE logical_sources (ROWID INTEGER PRIMARY KEY, bundle_id TEXT, owner_bundle_id TEXT);
            CREATE TABLE sources (ROWID INTEGER PRIMARY KEY, uuid BLOB, name TEXT, logical_source_id INTEGER, local_device INTEGER);
            CREATE TABLE source_devices (ROWID INTEGER PRIMARY KEY, name TEXT, manufacturer TEXT, model TEXT);
            INSERT INTO logical_sources VALUES (1, 'com.apple.health.X', NULL), (2, 'dev.ycode.health', NULL);
            INSERT INTO sources VALUES (1, NULL, 'Watch', 1, 1), (2, NULL, 'YcodeHealth', 2, 0);
            INSERT INTO source_devices VALUES (1, 'Apple Watch', 'Apple Inc.', 'Watch');
            """)
        let p = try SQLiteDatabase(path: health + "/healthdb_secure.sqlite", create: true)
        try p.execute("""
            CREATE TABLE data_provenances (ROWID INTEGER PRIMARY KEY, sync_provenance INTEGER, origin_product_type TEXT, source_id INTEGER,
                                           device_id INTEGER, tz_name TEXT);
            CREATE TABLE objects (data_id INTEGER PRIMARY KEY AUTOINCREMENT, uuid BLOB, provenance INTEGER, type INTEGER, creation_date REAL);
            CREATE TABLE samples (data_id INTEGER PRIMARY KEY, start_date REAL, end_date REAL, data_type INTEGER);
            CREATE TABLE quantity_samples (data_id INTEGER PRIMARY KEY, quantity REAL, original_quantity REAL, original_unit INTEGER);
            CREATE TABLE category_samples (data_id INTEGER PRIMARY KEY, value INTEGER);
            CREATE TABLE ecg_samples (data_id INTEGER PRIMARY KEY, private_classification INTEGER, average_heart_rate REAL,
                                      voltage_payload BLOB, symptoms_status INTEGER);
            INSERT INTO data_provenances VALUES (7, 0, 'Watch8,3', 2, 0, 'America/New_York');
            INSERT INTO objects (uuid, provenance, type, creation_date) VALUES (x'00', 7, 1, 0);
            """)
        if systemProvenance { try p.execute("INSERT INTO data_provenances VALUES (9, 0, 'Watch8,3', 1, 1, 'UTC');") }
        return (HealthStore(dev: dir), dir)
    }

    let t = Date(timeIntervalSinceReferenceDate: 815_000_000)

    @Test func seedsTheReadOnlyTypesUnderTheSystemSource() throws {
        let (store, dir) = try makeStore(systemProvenance: false)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let samples = [
            HealthSample(type: "HKCategoryTypeIdentifierSleepApneaEvent", start: t - 30 * 86400, end: t, value: 0),
            HealthSample(type: "HKQuantityTypeIdentifierAtrialFibrillationBurden", start: t - 7 * 86400, end: t, value: 0.02, unit: "%"),
            HealthSample(type: "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", start: t - 28_800, end: t, value: 5, unit: "count"),
            HealthSample(type: "HKQuantityTypeIdentifierAppleSleepingWristTemperature", start: t - 28_800, end: t, value: 97.7, unit: "degF"),
            HealthSample(type: HealthTypes.ecg, start: t, end: t + 30, value: 2, metadata: ["averageHeartRate": .number(92)]),
        ]
        let r = try store.seed(samples, model: "Watch", now: t)
        #expect(r.total == 5 && r.madeProvenance)
        let db = try SQLiteDatabase(path: store.protectedPath)
        // The new provenance: a copy of the agent's, now of the system source and the watch's device row.
        let prov = try db.query("SELECT sync_provenance, origin_product_type, source_id, device_id, tz_name FROM data_provenances WHERE ROWID = ?",
                                [.int(r.provenance)])[0]
        #expect(prov == [.int(0), .text("Watch8,3"), .int(1), .int(1), .text("America/New_York")])
        let objects = try db.query("SELECT data_id, provenance, type FROM objects WHERE provenance = ? ORDER BY data_id", [.int(r.provenance)])
        #expect(objects.count == 5 && objects.allSatisfy { $0[2] == .int(1) })
        let codes = try db.query("SELECT data_type FROM samples ORDER BY data_id").compactMap { $0[0].int }
        #expect(codes == [276, 248, 275, 256, 144])
        let q = try db.query("SELECT quantity FROM quantity_samples ORDER BY data_id").compactMap { $0[0].real }
        #expect(q[0] == 0.02 && q[1] == 5 && abs(q[2] - 36.5) < 1e-9)
        let ecg = try db.query("SELECT private_classification, average_heart_rate, length(voltage_payload), symptoms_status FROM ecg_samples")[0]
        #expect(ecg == [.int(4), .real(92), .int(0), .int(1)])  // AFib (public 2) is stored as 4
        let s = try db.query("SELECT start_date, end_date FROM samples WHERE data_type = 144")[0]
        #expect(s == [.real(t.timeIntervalSinceReferenceDate), .real(t.timeIntervalSinceReferenceDate + 30)])
    }

    @Test func reusesTheSystemSourcesProvenance() throws {
        let (store, dir) = try makeStore(systemProvenance: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = try store.seed([HealthSample(type: "HKCategoryTypeIdentifierIrregularHeartRhythmEvent", start: t, end: t + 3600, value: 0)],
                               model: "Watch")
        #expect(r.provenance == 9 && !r.madeProvenance)
    }

    @Test func refusesTypesWithoutAStoreCode() throws {
        let (store, dir) = try makeStore(systemProvenance: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(throws: HealthSeedError.self) {
            try store.seed([HealthSample(type: "HKQuantityTypeIdentifierWalkingHeartRateAverage", start: t, end: t + 60, value: 90, unit: "count/min")],
                           model: "Watch")
        }
        // Nothing was written.
        let db = try SQLiteDatabase(path: store.protectedPath)
        #expect(try db.query("SELECT count(*) FROM samples")[0][0] == .int(0))
    }

    @Test func storedECGClassifications() {
        #expect((0...6).map(HealthStore.storedECGClassification) == [0, 3, 4, 6, 5, 1, 2])
    }
}

/// health-simulation.md §12.1: a watch app's grants are its companion's.
struct HealthWatchAppTests {
    @Test func aWatchAppsCompanionIsFoundInTheInstalledBundle() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-watch-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        func install(_ name: String, _ info: [String: Any]) throws {
            let app = data.appendingPathComponent("Containers/Bundle/Application/\(UUID().uuidString)/\(name).app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
        }
        try install("HealthCheckWatch", ["CFBundleIdentifier": "dev.ycode.healthcheck.watchkitapp",
                                         "WKApplication": true, "WKCompanionAppBundleIdentifier": "dev.ycode.healthcheck"])
        try install("Solo", ["CFBundleIdentifier": "dev.ycode.solo", "WKWatchOnly": true])
        #expect(HealthWatchApps.companion(of: "dev.ycode.healthcheck.watchkitapp", deviceData: data.path) == "dev.ycode.healthcheck")
        #expect(HealthWatchApps.companion(of: "dev.ycode.solo", deviceData: data.path) == nil, "a watch-only app keeps its own id")
        #expect(HealthWatchApps.companion(of: "dev.ycode.healthcheck", deviceData: data.path) == nil, "not installed here")
        #expect(HealthWatchApps.companion(of: "x", deviceData: data.path + "/missing") == nil)
    }
}
