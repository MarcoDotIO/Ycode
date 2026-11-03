// `health import` files (health-simulation.md §8.3 H-9): JSON and CSV
// sample files, read and checked on the host before anything reaches the
// guest agent.
//
// JSON: {"version": 1, "device": "watch"|"phone" (optional),
//        "samples": [{"type", "start", "end"?, "value", "unit"?, "metadata"?}],
//        "workouts": [{"activity", "start", "end", "indoor"?, "energy_kcal"?, "distance_m"?,
//                      "samples"?: […], "route"?: [[lat, lon, time], …], "metadata"?}]}
// CSV:  a header naming the columns type,start,end,value,unit (any order;
//       end and unit may be absent or empty), one sample per line; '#'
//       starts a comment line; fields may be double-quoted.
// Times: ISO 8601 (2026-10-30T07:00:00Z, with an offset, with fractional
// seconds, or a date alone), the export form "2026-10-30 07:00:00 -0400",
// seconds since 1970, or relative to now: "now", "-8h", "-30m", "+90s", "-2d".
// Types: identifiers, short names (HeartRate) or aliases (spo2, sleep).
// Category values: integers or the enumeration case names (identifiers.md).
// Units: HealthKit unit strings (units.md §2). Real health exports are not
// read (no export parser); every example Ycode ships is synthetic.

import Foundation

public struct HealthImportFile: Sendable, Equatable {
    public var device: String?
    public var samples: [HealthSample] = []
    public var workouts: [HealthWorkout] = []
    /// Samples of read-only types (refused for import; accepted by `seed`).
    public var readOnly: [HealthSample] = []

    public var sampleCount: Int { samples.count + workouts.reduce(0) { $0 + $1.samples.count } }
}

public enum HealthImport {
    public enum Format: Sendable { case json, csv }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let errors: [HealthValidationError]
        public var description: String {
            let shown = errors.prefix(20).map(\.description)
            let more = errors.count > 20 ? ["… and \(errors.count - 20) more"] : []
            return (shown + more).joined(separator: "\n")
        }
        public var readOnlyOnly: Bool { !errors.isEmpty && errors.allSatisfy(\.readOnly) }
    }

    public static func format(of path: String) -> Format? {
        switch (path as NSString).pathExtension.lowercased() {
        case "json": .json
        case "csv", "txt": .csv
        default: nil
        }
    }

    /// Reads and checks a file. `seeding` accepts read-only types (they go
    /// to `readOnly`); otherwise each one is an error that names HEALTH-3.
    public static func read(_ data: Data, format: Format, now: Date = Date(), seeding: Bool = false) throws -> HealthImportFile {
        var errors: [HealthValidationError] = []
        var file = HealthImportFile()
        let entries: [(String, HealthSample)]
        switch format {
        case .json:
            let parsed = try parseJSON(data, now: now, errors: &errors)
            file.device = parsed.device
            file.workouts = parsed.workouts
            entries = parsed.samples
        case .csv:
            entries = parseCSV(String(decoding: data, as: UTF8.self), now: now, errors: &errors)
        }
        for (location, s) in entries {
            let problems = HealthValidation.check(s, seeding: seeding)
            if problems.isEmpty {
                if HealthTypes.all[s.type]?.writable == false { file.readOnly.append(s) } else { file.samples.append(s) }
            } else {
                let ro = HealthTypes.all[s.type]?.writable == false
                errors += problems.map { HealthValidationError(location, $0, readOnly: ro) }
            }
        }
        for (i, w) in file.workouts.enumerated() {
            errors += HealthValidation.check(w).map { HealthValidationError("workout \(i + 1)", $0) }
        }
        if !errors.isEmpty { throw Failure(errors: errors) }
        if file.sampleCount == 0 && file.workouts.isEmpty && file.readOnly.isEmpty {
            throw Failure(errors: [HealthValidationError("", "the file has no samples")])
        }
        return file
    }

    public static func read(path: String, now: Date = Date(), seeding: Bool = false) throws -> HealthImportFile {
        guard let f = format(of: path) else {
            throw Failure(errors: [HealthValidationError(path, "not a .json or .csv file")])
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Failure(errors: [HealthValidationError(path, "cannot read the file")])
        }
        return try read(data, format: f, now: now, seeding: seeding)
    }

    // MARK: Times

    nonisolated(unsafe) static let isoFormatters: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let c = ISO8601DateFormatter()
        c.formatOptions = [.withFullDate]
        return [a, b, c]
    }()
    static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()
    static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// A time of the forms in the header comment.
    public static func time(_ any: Any, now: Date) -> Date? {
        if let n = any as? NSNumber, !(any is Bool) { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let text = (any as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text == "now" { return now }
        if let d = relative(text) { return now.addingTimeInterval(d) }
        if let n = Double(text), text.count >= 9 { return Date(timeIntervalSince1970: n) }
        for f in isoFormatters.prefix(2) { if let d = f.date(from: text) { return d } }
        if let d = exportFormatter.date(from: text) { return d }
        if let d = localFormatter.date(from: text) { return d }
        // A date alone (2026-10-30): its UTC midnight.
        return text.count == 10 ? isoFormatters[2].date(from: text) : nil
    }

    /// "-8h", "+30m", "90s", "-2d" → seconds (a sign is required, or a unit suffix after digits).
    public static func relative(_ text: String) -> TimeInterval? {
        var t = Substring(text)
        var sign = 1.0
        if t.first == "-" { sign = -1; t = t.dropFirst() } else if t.first == "+" { t = t.dropFirst() } else { return nil }
        return duration(String(t)).map { $0 * sign }
    }

    /// "5s", "10m", "1.5h", "2d", "300" (seconds) → seconds.
    public static func duration(_ text: String) -> TimeInterval? {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let last = text.last else { return nil }
        if let u = units[last], let n = Double(text.dropLast()), n >= 0 { return n * u }
        if text.hasSuffix("ms"), let n = Double(text.dropLast(2)), n >= 0 { return n / 1000 }
        if let n = Double(text), n >= 0 { return n }
        return nil
    }

    // MARK: JSON

    struct ParsedJSON {
        var device: String?
        var samples: [(String, HealthSample)] = []
        var workouts: [HealthWorkout] = []
    }

    static func parseJSON(_ data: Data, now: Date, errors: inout [HealthValidationError]) throws -> ParsedJSON {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(errors: [HealthValidationError("", "not a JSON object (expected {\"version\": 1, \"samples\": […]})")])
        }
        if let v = root["version"] as? Int, v != 1 {
            throw Failure(errors: [HealthValidationError("version", "version \(v) is not supported (1 is)")])
        }
        var out = ParsedJSON()
        out.device = root["device"] as? String
        if let d = out.device, d != "watch" && d != "phone" {
            errors.append(HealthValidationError("device", "'\(d)' is not watch or phone"))
        }
        for (i, any) in (root["samples"] as? [Any] ?? []).enumerated() {
            let where_ = "sample \(i + 1)"
            guard let d = any as? [String: Any] else {
                errors.append(HealthValidationError(where_, "not an object"))
                continue
            }
            if let s = sample(d, now: now, location: where_, errors: &errors) { out.samples.append((where_, s)) }
        }
        for (i, any) in (root["workouts"] as? [Any] ?? []).enumerated() {
            let where_ = "workout \(i + 1)"
            guard let d = any as? [String: Any] else {
                errors.append(HealthValidationError(where_, "not an object"))
                continue
            }
            if let w = workout(d, now: now, location: where_, errors: &errors) { out.workouts.append(w) }
        }
        return out
    }

    static func sample(_ d: [String: Any], now: Date, location: String, errors: inout [HealthValidationError]) -> HealthSample? {
        guard let name = d["type"] as? String else {
            errors.append(HealthValidationError(location, "no \"type\""))
            return nil
        }
        guard let type = HealthTypes.type(named: name) else {
            errors.append(HealthValidationError(location, "unknown sample type '\(name)'"))
            return nil
        }
        guard let start = d["start"].flatMap({ time($0, now: now) }) else {
            errors.append(HealthValidationError(location, "no readable \"start\" time"))
            return nil
        }
        var end = start
        if let e = d["end"], !(e is NSNull) {
            guard let t = time(e, now: now) else {
                errors.append(HealthValidationError(location, "unreadable \"end\" time"))
                return nil
            }
            end = t
        }
        var value: Double?
        if let n = d["value"] as? NSNumber, !(d["value"] is Bool) { value = n.doubleValue }
        if value == nil, let s = d["value"] as? String {
            value = type.kind == .category ? HealthTypes.categoryValue(s, for: type).map(Double.init) : Double(s)
        }
        if value == nil, type.kind == .category, type.categoryValues == [0], d["value"] == nil { value = 0 }
        guard let value else {
            errors.append(HealthValidationError(location, "\(type.shortName): no readable \"value\""))
            return nil
        }
        var metadata: [String: HealthMetadataValue] = [:]
        for (k, v) in d["metadata"] as? [String: Any] ?? [:] {
            if let m = metadataValue(v, now: now) { metadata[k] = m } else {
                errors.append(HealthValidationError(location, "metadata \(k): not a string, number, time or {value, unit}"))
            }
        }
        return HealthSample(type: type.identifier, start: start, end: end, value: value, unit: d["unit"] as? String, metadata: metadata)
    }

    static func metadataValue(_ v: Any, now: Date) -> HealthMetadataValue? {
        if let b = v as? Bool { return .number(b ? 1 : 0) }
        if let n = v as? NSNumber { return .number(n.doubleValue) }
        if let s = v as? String { return .string(s) }
        if let d = v as? [String: Any] {
            if let t = d["date"].flatMap({ time($0, now: now) }) { return .date(t) }
            if let x = d["value"] as? NSNumber, let u = d["unit"] as? String, (try? HealthUnit(u)) != nil { return .quantity(x.doubleValue, u) }
        }
        return nil
    }

    static func workout(_ d: [String: Any], now: Date, location: String, errors: inout [HealthValidationError]) -> HealthWorkout? {
        let activityName = (d["activity"] as? String) ?? (d["activity"] as? NSNumber)?.stringValue ?? "other"
        guard let activity = HealthWorkout.activity(named: activityName) else {
            errors.append(HealthValidationError(location, "unknown activity '\(activityName)'"))
            return nil
        }
        guard let start = d["start"].flatMap({ time($0, now: now) }), let end = d["end"].flatMap({ time($0, now: now) }) else {
            errors.append(HealthValidationError(location, "a workout needs readable \"start\" and \"end\" times"))
            return nil
        }
        var w = HealthWorkout(activity: activity, start: start, end: end, indoor: d["indoor"] as? Bool ?? false)
        for (i, any) in (d["samples"] as? [Any] ?? []).enumerated() {
            if let sd = any as? [String: Any], let s = sample(sd, now: now, location: "\(location) sample \(i + 1)", errors: &errors) {
                w.samples.append(s)
            }
        }
        // Totals as one sample each over the workout (when the file gives no samples of that type).
        if let kcal = (d["energy_kcal"] as? NSNumber)?.doubleValue, !w.samples.contains(where: { $0.type == "HKQuantityTypeIdentifierActiveEnergyBurned" }) {
            w.samples.append(HealthSample(type: "HKQuantityTypeIdentifierActiveEnergyBurned", start: start, end: end, value: kcal, unit: "kcal"))
        }
        if let m = (d["distance_m"] as? NSNumber)?.doubleValue {
            let type = [13: "HKQuantityTypeIdentifierDistanceCycling", 46: "HKQuantityTypeIdentifierDistanceSwimming"][activity]
                ?? "HKQuantityTypeIdentifierDistanceWalkingRunning"
            if !w.samples.contains(where: { $0.type == type }) {
                w.samples.append(HealthSample(type: type, start: start, end: end, value: m, unit: "m"))
            }
        }
        for (i, any) in (d["route"] as? [Any] ?? []).enumerated() {
            guard let p = any as? [Any], p.count >= 3, let lat = (p[0] as? NSNumber)?.doubleValue, let lon = (p[1] as? NSNumber)?.doubleValue,
                  let t = time(p[2], now: now) else {
                errors.append(HealthValidationError("\(location) route point \(i + 1)", "expected [latitude, longitude, time]"))
                continue
            }
            w.route.append((lat, lon, t))
        }
        for (k, v) in d["metadata"] as? [String: Any] ?? [:] {
            if let m = metadataValue(v, now: now) { w.metadata[k] = m }
        }
        return w
    }

    // MARK: CSV

    static func fields(_ line: Substring) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if quoted {
                if c == "\"" {
                    let n = line.index(after: i)
                    if n < line.endIndex, line[n] == "\"" { cur.append("\""); i = n } else { quoted = false }
                } else {
                    cur.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(c)
            }
            i = line.index(after: i)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    static func parseCSV(_ text: String, now: Date, errors: inout [HealthValidationError]) -> [(String, HealthSample)] {
        var out: [(String, HealthSample)] = []
        var columns: [String: Int]?
        for (n, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = fields(Substring(line))
            guard let cols = columns else {
                var c: [String: Int] = [:]
                for (i, name) in f.enumerated() { c[name.lowercased()] = i }
                guard c["type"] != nil, c["start"] != nil, c["value"] != nil else {
                    errors.append(HealthValidationError("line \(n + 1)", "the header must name the columns type,start,end,value,unit"))
                    return []
                }
                columns = c
                continue
            }
            func field(_ name: String) -> String? {
                cols[name].flatMap { $0 < f.count ? f[$0] : nil }.flatMap { $0.isEmpty ? nil : $0 }
            }
            var d: [String: Any] = [:]
            d["type"] = field("type")
            d["start"] = field("start")
            d["end"] = field("end")
            d["value"] = field("value")
            d["unit"] = field("unit")
            if let s = sample(d, now: now, location: "line \(n + 1)", errors: &errors) { out.append(("line \(n + 1)", s)) }
        }
        if columns == nil { errors.append(HealthValidationError("", "no header line")) }
        return out
    }
}
