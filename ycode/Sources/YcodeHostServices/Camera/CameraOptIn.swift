// The camera extension's switch and its effects on a device (camera.md
// "Ycode implementation"): a per-device setting, off by default (parity:
// no camera, as the reference simulator), kept in the device directory; the
// rule that puts Ycode's guest capture layer into app processes when it is
// on; the capabilities answers of a device with a camera; and the privacy
// command's database rows (camera.md §6.2).

import Foundation

/// The device's camera setting (`ycode-simd --camera`, Settings ▸ Simulators).
public struct CameraOptIn: Equatable, Sendable, CustomStringConvertible {
    public enum Mode: Equatable, Sendable {
        /// No camera: the reference behavior (camera.md §7.1).
        case off
        /// The first V4L2 camera of the host, else the synthetic one.
        case on
        /// The synthetic test pattern (camera-host.md §7).
        case synthetic
        /// One host camera: a device node (`/dev/video0`) or ID (`v4l2:…`).
        case device(String)
    }

    public var mode: Mode
    /// Where the camera appears; nil: the device type's default (back on an
    /// iPhone, external on an iPad).
    public var placement: CameraGuestPresentation.Placement?

    public init(mode: Mode = .off, placement: CameraGuestPresentation.Placement? = nil) {
        self.mode = mode
        self.placement = placement
    }

    public static let off = CameraOptIn()

    public var isOn: Bool { mode != .off }

    /// `off`, `on`, `synthetic`, a `/dev/…` node or a `v4l2:` ID.
    public static func mode(_ text: String) -> Mode? {
        switch text.lowercased() {
        case "off", "none", "no", "0", "false": return .off
        case "on", "auto", "yes", "1", "true", "webcam": return .on
        case "synthetic": return .synthetic
        default:
            if text.hasPrefix("/dev/") || text.hasPrefix("v4l2:") { return .device(text) }
            return nil
        }
    }

    public var modeName: String {
        switch mode {
        case .off: "off"
        case .on: "on"
        case .synthetic: "synthetic"
        case let .device(d): d
        }
    }

    /// The host camera selection (`CameraHostService.resolve`); nil when off.
    public var selection: String? {
        switch mode {
        case .off: nil
        case .on: "auto"
        case .synthetic: "synthetic"
        case let .device(d): d
        }
    }

    public var description: String { modeName + (placement.map { " (\($0.rawValue))" } ?? "") }

    /// The placement for a device type: the setting, else back on an iPhone
    /// and external on an iPad (camera.md §7.2 C, step 9).
    public func placement(isPad: Bool) -> CameraGuestPresentation.Placement {
        placement ?? (isPad ? .external : .back)
    }

    // MARK: Persistence (DEV/ycode-camera.plist)

    public static let fileName = "ycode-camera.plist"

    public static func path(dev: String) -> String { (dev as NSString).appendingPathComponent(fileName) }

    /// The device's setting; off when there is none (or it is unreadable).
    public static func load(dev: String) -> CameraOptIn {
        guard let data = FileManager.default.contents(atPath: path(dev: dev)),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let m = (p["Mode"] as? String).flatMap(mode) else { return .off }
        return CameraOptIn(mode: m, placement: (p["Position"] as? String).flatMap(CameraGuestPresentation.Placement.init(rawValue:)))
    }

    public func save(dev: String) throws {
        var p: [String: Any] = ["Mode": modeName]
        if let placement { p["Position"] = placement.rawValue }
        let data = try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: Self.path(dev: dev)), options: .atomic)
    }

    // MARK: Capabilities (camera.md §7.2 C, step 9)

    /// With a camera the device answers like one with a camera at that
    /// position: `video-camera` and the position's key true; `camera-flash`
    /// stays false (a webcam has no flash).
    public func applyCapabilities(_ plist: [String: Any], isPad: Bool) -> [String: Any] {
        guard isOn else { return plist }
        var out = plist
        var caps = out["capabilities"] as? [String: Any] ?? [:]
        caps["video-camera"] = true
        caps["still-camera"] = true
        switch placement(isPad: isPad) {
        case .front: caps["front-facing-camera"] = true
        case .back, .external: caps["rear-facing-camera"] = true
        }
        if caps["camera-flash"] == nil { caps["camera-flash"] = false }
        out["capabilities"] = caps
        return out
    }
}

// MARK: - Putting the capture layer into apps

/// The guest capture layer (`libYcodeCamera.dylib`) goes into app processes
/// through the environment the kernel builds at spawn: an app's executable
/// gets the library in `DYLD_INSERT_LIBRARIES` (a public dyld feature) and
/// the endpoint's name in `YCODE_CAMERA_SERVICE`. Daemons and system
/// services are left alone.
public enum CameraAppInjection {
    /// The dyld variable that names libraries to insert.
    public static let insertKey = "DYLD_INSERT_LIBRARIES"
    /// The variable that gives the capture layer the endpoint's name; the
    /// layer does nothing without it (`camera.md` §9.3).
    public static let serviceKey = "YCODE_CAMERA_SERVICE"

    /// Apps and app extensions: executables inside an `.app` bundle under
    /// an `Applications` folder or an installed-app container (system
    /// CoreServices bundles such as SpringBoard are not apps).
    public static func isAppExecutable(_ path: String) -> Bool {
        guard path.contains(".app/") else { return false }
        if path.contains("/System/Library/CoreServices/") || path.contains("/System/Library/PrivateFrameworks/") { return false }
        return path.contains("/Containers/Bundle/Application/") || path.contains("/Applications/")
    }

    /// `envp` with the library inserted (kept once, after any library the
    /// environment already inserts) and the service variable set.
    public static func environment(_ envp: [String], library: String) -> [String] {
        var out: [String] = []
        var inserted = false
        for e in envp {
            if e.hasPrefix(insertKey + "=") {
                let list = String(e.dropFirst(insertKey.count + 1)).split(separator: ":").map(String.init)
                out.append(insertKey + "=" + (list.contains(library) ? list : list + [library]).joined(separator: ":"))
                inserted = true
            } else if !e.hasPrefix(serviceKey + "=") {
                out.append(e)
            }
        }
        if !inserted { out.append(insertKey + "=" + library) }
        out.append(serviceKey + "=" + CameraGuestProtocol.serviceName)
        return out
    }
}

// MARK: - Privacy (camera.md §6.2)

/// The TCC rows `ycode-simd --privacy` writes into the device's
/// `data/Library/TCC/TCC.db` (table `access`; the row of camera.md §6.2:
/// client type 0, auth reason 4, auth version 1; auth value 2 granted, 0
/// denied; reset removes the row). The database is the guest `tccd`'s: it
/// exists once the device has booted.
public enum CameraPrivacy {
    public enum Action: String, Sendable, CaseIterable { case grant, revoke, reset }

    /// Service names Ycode's command accepts, and their TCC service.
    public static let services: [String: String] = ["camera": "kTCCServiceCamera", "microphone": "kTCCServiceMicrophone"]

    /// The TCC database of the device directory `dev`.
    public static func databasePath(dev: String) -> String { dev + "/data/Library/TCC/TCC.db" }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// The SQL for one action (bundle IDs quoted as SQL literals).
    public static func statements(_ action: Action, service: String, bundleID: String) -> [String] {
        let s = quote(service), c = quote(bundleID)
        let delete = "DELETE FROM access WHERE service = \(s) AND client = \(c) AND client_type = 0"
        switch action {
        case .reset: return [delete]
        case .grant, .revoke:
            let value = action == .grant ? 2 : 0
            return [delete, "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version) "
                + "VALUES (\(s), \(c), 0, \(value), 4, 1)"]
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Applies an action to the device's database.
    public static func apply(_ action: Action, service: String, bundleID: String, dev: String) throws {
        guard let tcc = services[service] else {
            throw Failure("unknown service '\(service)' (\(services.keys.sorted().joined(separator: ", ")))")
        }
        guard !bundleID.isEmpty else { throw Failure("no bundle identifier") }
        let path = databasePath(dev: dev)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Failure("\(path) does not exist (the guest's tccd makes it at the device's first boot)")
        }
        let db = try SQLite(path: path)
        defer { db.close() }
        try db.exec("BEGIN IMMEDIATE")
        do {
            for sql in statements(action, service: tcc, bundleID: bundleID) { try db.exec(sql) }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// The auth value of the device's row, nil when there is none.
    public static func authValue(service: String, bundleID: String, dev: String) throws -> Int? {
        guard let tcc = services[service] else { throw Failure("unknown service '\(service)'") }
        let db = try SQLite(path: databasePath(dev: dev))
        defer { db.close() }
        let rows = try db.query("SELECT auth_value FROM access WHERE service = \(quote(tcc)) AND client = \(quote(bundleID)) AND client_type = 0")
        // swiftlint:disable:next redundant_nil_coalescing - flattens a double optional
        return rows.first.flatMap { $0.first ?? nil }.flatMap { Int($0) }
    }

    /// SQLite through the system library, loaded at run time (no build
    /// dependency): `libsqlite3.so.0` on Linux, `libsqlite3.dylib` on macOS.
    final class SQLite {
        typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>, Int32, UnsafePointer<CChar>?) -> Int32
        typealias Callback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                             UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias Exec = @convention(c) (OpaquePointer, UnsafePointer<CChar>, Callback?, UnsafeMutableRawPointer?,
                                         UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias Close = @convention(c) (OpaquePointer) -> Int32
        typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias BusyTimeout = @convention(c) (OpaquePointer, Int32) -> Int32
        typealias ErrorMessage = @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?

        nonisolated(unsafe) static let library: UnsafeMutableRawPointer? = {
            for name in ["libsqlite3.so.0", "libsqlite3.so", "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib"] {
                if let h = dlopen(name, RTLD_NOW) { return h }
            }
            return nil
        }()

        static func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let lib = library else { throw Failure("cannot load the SQLite library (libsqlite3)") }
            guard let p = dlsym(lib, name) else { throw Failure("libsqlite3 has no \(name)") }
            return unsafeBitCast(p, to: T.self)
        }

        let db: OpaquePointer
        private let execFn: Exec
        private let closeFn: Close
        private let freeFn: Free
        private let errorFn: ErrorMessage

        init(path: String, create: Bool = false) throws {
            let open = try Self.symbol("sqlite3_open_v2", Open.self)
            execFn = try Self.symbol("sqlite3_exec", Exec.self)
            closeFn = try Self.symbol("sqlite3_close", Close.self)
            freeFn = try Self.symbol("sqlite3_free", Free.self)
            errorFn = try Self.symbol("sqlite3_errmsg", ErrorMessage.self)
            var handle: OpaquePointer?
            // SQLITE_OPEN_READWRITE (2); the database must exist (tests: | CREATE, 4).
            let rc = open(path, &handle, create ? 6 : 2, nil)
            guard rc == 0, let handle else {
                if let handle { _ = closeFn(handle) }
                throw Failure("cannot open \(path) (SQLite error \(rc))")
            }
            db = handle
            _ = try? Self.symbol("sqlite3_busy_timeout", BusyTimeout.self)(db, 5000)
        }

        func close() { _ = closeFn(db) }

        func exec(_ sql: String) throws { _ = try run(sql, collect: false) }

        func query(_ sql: String) throws -> [[String?]] { try run(sql, collect: true) }

        final class Rows { var rows: [[String?]] = [] }

        private func run(_ sql: String, collect: Bool) throws -> [[String?]] {
            let box = Rows()
            var message: UnsafeMutablePointer<CChar>?
            let callback: Callback = { context, count, values, _ in
                guard let context else { return 0 }
                let rows = Unmanaged<Rows>.fromOpaque(context).takeUnretainedValue()
                rows.rows.append((0..<Int(count)).map { i in values?[i].map { String(cString: $0) } })
                return 0
            }
            let rc = withExtendedLifetime(box) {
                execFn(db, sql, collect ? callback : nil, collect ? Unmanaged.passUnretained(box).toOpaque() : nil, &message)
            }
            if rc != 0 {
                let text = message.map { String(cString: $0) } ?? errorFn(db).map { String(cString: $0) } ?? "error \(rc)"
                if let message { freeFn(message) }
                throw Failure("SQLite: \(text) (in: \(sql))")
            }
            return box.rows
        }
    }
}
