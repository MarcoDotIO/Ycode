import Foundation

/// Ycode's own SQLite schema (`design.md` §4). `user_version` tracks it.
enum Schema {
    static let version = 1

    static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS anchor_seq(id INTEGER PRIMARY KEY CHECK (id = 1), value INTEGER NOT NULL)",
        "INSERT OR IGNORE INTO anchor_seq(id, value) VALUES (1, 0)",
        """
        CREATE TABLE IF NOT EXISTS sources(id INTEGER PRIMARY KEY, bundle_id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL, kind INTEGER NOT NULL DEFAULT 0, first_authorized REAL)
        """,
        """
        CREATE TABLE IF NOT EXISTS source_revisions(id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES sources(id), version TEXT, product_type TEXT,
            os_major INTEGER NOT NULL, os_minor INTEGER NOT NULL, os_patch INTEGER NOT NULL,
            UNIQUE(source_id, version, product_type, os_major, os_minor, os_patch))
        """,
        "CREATE TABLE IF NOT EXISTS devices(id INTEGER PRIMARY KEY, record TEXT NOT NULL UNIQUE)",
        """
        CREATE TABLE IF NOT EXISTS objects(anchor INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
            kind INTEGER NOT NULL, type TEXT NOT NULL, source_id INTEGER NOT NULL REFERENCES sources(id),
            revision_id INTEGER NOT NULL REFERENCES source_revisions(id), device_id INTEGER REFERENCES devices(id),
            start REAL NOT NULL, "end" REAL NOT NULL, created REAL NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS objects_type_dates ON objects(type, start, \"end\")",
        """
        CREATE TABLE IF NOT EXISTS quantity(anchor INTEGER PRIMARY KEY REFERENCES objects(anchor) ON DELETE CASCADE,
            value REAL NOT NULL, unit TEXT NOT NULL, ref REAL NOT NULL, count INTEGER NOT NULL)
        """,
        """
        CREATE TABLE IF NOT EXISTS category(anchor INTEGER PRIMARY KEY REFERENCES objects(anchor) ON DELETE CASCADE,
            value INTEGER NOT NULL)
        """,
        """
        CREATE TABLE IF NOT EXISTS metadata(anchor INTEGER NOT NULL REFERENCES objects(anchor) ON DELETE CASCADE,
            key TEXT NOT NULL, kind INTEGER NOT NULL, text TEXT, integer INTEGER, number REAL, unit TEXT,
            PRIMARY KEY(anchor, key))
        """,
        "CREATE INDEX IF NOT EXISTS metadata_key ON metadata(key, text, number)",
        """
        CREATE TABLE IF NOT EXISTS associations(parent INTEGER NOT NULL REFERENCES objects(anchor) ON DELETE CASCADE,
            child INTEGER NOT NULL REFERENCES objects(anchor) ON DELETE CASCADE, kind INTEGER NOT NULL,
            PRIMARY KEY(parent, child, kind))
        """,
        "CREATE INDEX IF NOT EXISTS associations_child ON associations(child, kind)",
        """
        CREATE TABLE IF NOT EXISTS workouts(anchor INTEGER PRIMARY KEY REFERENCES objects(anchor) ON DELETE CASCADE,
            activity_type INTEGER NOT NULL, duration REAL NOT NULL, record TEXT NOT NULL)
        """,
        """
        CREATE TABLE IF NOT EXISTS tombstones(anchor INTEGER PRIMARY KEY, uuid TEXT NOT NULL, type TEXT NOT NULL,
            source_id INTEGER NOT NULL, metadata TEXT, deleted_at REAL NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS tombstones_type ON tombstones(type, anchor)",
        "CREATE INDEX IF NOT EXISTS tombstones_uuid ON tombstones(uuid)",
        """
        CREATE TABLE IF NOT EXISTS sync_ids(source_id INTEGER NOT NULL, type TEXT NOT NULL, sync_id TEXT NOT NULL,
            version REAL NOT NULL, anchor INTEGER NOT NULL REFERENCES objects(anchor) ON DELETE CASCADE,
            PRIMARY KEY(source_id, type, sync_id))
        """,
        """
        CREATE TABLE IF NOT EXISTS authorization(bundle_id TEXT NOT NULL, type TEXT NOT NULL,
            share_status INTEGER NOT NULL DEFAULT 0, read_status INTEGER NOT NULL DEFAULT 0, earliest REAL,
            decided_at REAL NOT NULL, PRIMARY KEY(bundle_id, type))
        """,
        "CREATE TABLE IF NOT EXISTS source_priority(type TEXT NOT NULL, bundle_id TEXT NOT NULL, rank INTEGER NOT NULL, PRIMARY KEY(type, bundle_id))",
        "CREATE TABLE IF NOT EXISTS bg_delivery(bundle_id TEXT NOT NULL, type TEXT NOT NULL, frequency INTEGER NOT NULL, PRIMARY KEY(bundle_id, type))",
        "CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    ]

    /// Association kinds.
    static let correlationMember: Int64 = 1
    static let workoutSample: Int64 = 2
}
