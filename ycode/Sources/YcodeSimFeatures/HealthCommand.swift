// `health …` command words (health-simulation.md §8.3 H-7): what
// `ycode-simd --device DEV --health <words…>`, the launcher's
// `ycode-sim --device DEV --health …` and the control socket take.
//
//   status
//   authorize                              the agent asks for its grants again
//   import <file.json|file.csv> [--open <bundle id>]
//   scenario <name> [--date YYYY-MM-DD] [--days N] [--seed S] [--steps N] [--start <time>] [--with-read-only]
//   stream heart-rate|spo2|respiratory-rate [--bpm A..B | --range A..B] [--every 5s] [--for 10m]
//   stop
//   clear                                  deletes the agent's samples (public delete API)
//   grant <bundle id> | revoke <bundle id> the app's own requests answered (shut-down device; queued)
//   seed <file> | seed scenario <name> […]  read-only types into a shut-down device (HEALTH-3)

import Foundation

public enum HealthCommand: Equatable, Sendable {
    case status
    case authorize
    case importFile(path: String, open: String?)
    case scenario(name: String, date: String?, days: Int, seed: UInt64, steps: Int?, start: String?, withReadOnly: Bool)
    case stream(kind: StreamKind, range: ClosedRange<Double>, every: TimeInterval, duration: TimeInterval?)
    case stop
    case clear
    case grant(bundleID: String)
    case revoke(bundleID: String)
    case seedFile(path: String)
    case seedScenario(name: String, date: String?, days: Int, seed: UInt64)

    public enum StreamKind: String, Sendable, CaseIterable {
        case heartRate = "heart-rate", spo2, respiratoryRate = "respiratory-rate"

        public var type: String {
            switch self {
            case .heartRate: HealthScenarios.hr
            case .spo2: HealthScenarios.spo2
            case .respiratoryRate: HealthScenarios.respiratory
            }
        }
        public var unit: String { self == .spo2 ? "%" : "count/min" }
        public var defaultRange: ClosedRange<Double> {
            switch self {
            case .heartRate: 80...150
            case .spo2: 95...99
            case .respiratoryRate: 12...18
            }
        }
    }

    public static let usage = """
        health status | authorize | import <file.json|file.csv> [--open <bundle id>]
          | scenario <\(HealthScenarios.writable.joined(separator: "|"))> [--date YYYY-MM-DD] [--days N] [--seed S] [--steps N] [--start <time>] [--with-read-only]
          | stream heart-rate|spo2|respiratory-rate [--bpm A..B] [--every 5s] [--for 10m] | stop | clear
          | grant <bundle id> | revoke <bundle id>
          | seed <file> | seed scenario <\(HealthScenarios.readOnly.joined(separator: "|"))|spo2-dips> [--date …] [--days N] [--seed S]
        """

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ s: String) { description = s }
    }

    /// Whether the command can run while the device is shut down.
    public var worksOffline: Bool {
        switch self {
        case .grant, .revoke, .seedFile, .seedScenario, .status: true
        default: false
        }
    }

    /// `words` without the leading "health".
    public static func parse(_ words: [String]) throws -> HealthCommand {
        var w = words
        if w.first == "health" { w.removeFirst() }
        guard let verb = w.first else { throw ParseError("health: a command is missing\n" + usage) }
        let rest = Array(w.dropFirst())
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        var i = 0
        let valued: Set<String> = ["--open", "--date", "--days", "--seed", "--steps", "--start", "--bpm", "--range", "--every", "--for"]
        while i < rest.count {
            let a = rest[i]
            if valued.contains(a) {
                guard i + 1 < rest.count else { throw ParseError("health \(verb): \(a) needs a value") }
                options[a] = rest[i + 1]
                i += 2
            } else if let eq = a.firstIndex(of: "="), valued.contains(String(a[..<eq])) {
                options[String(a[..<eq])] = String(a[a.index(after: eq)...])
                i += 1
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
        func int(_ k: String, _ d: Int) throws -> Int {
            guard let s = options[k] else { return d }
            guard let n = Int(s), n > 0 else { throw ParseError("health \(verb): \(k) takes a positive number") }
            return n
        }
        func seedValue() throws -> UInt64 {
            guard let s = options["--seed"] else { return 1 }
            guard let n = UInt64(s) else { throw ParseError("health \(verb): --seed takes a number") }
            return n
        }
        func date() throws -> String? {
            guard let d = options["--date"] else { return nil }
            guard parseDay(d, timeZone: .current) != nil else { throw ParseError("health \(verb): --date takes YYYY-MM-DD") }
            return d
        }
        let known: Set<String> = ["--with-read-only"]
        if let bad = flags.subtracting(known).first { throw ParseError("health \(verb): unknown option \(bad)") }
        switch verb {
        case "status": return .status
        case "authorize": return .authorize
        case "stop": return .stop
        case "clear": return .clear
        case "import":
            guard positional.count == 1 else { throw ParseError("health import <file.json|file.csv> [--open <bundle id>]") }
            guard HealthImport.format(of: positional[0]) != nil else { throw ParseError("health import: \(positional[0]) is not a .json or .csv file") }
            return .importFile(path: positional[0], open: options["--open"])
        case "scenario":
            guard positional.count == 1 else { throw ParseError("health scenario <name>: \(HealthScenarios.writable.joined(separator: ", "))") }
            let name = positional[0]
            if HealthScenarios.readOnly.contains(name) {
                throw ParseError("health scenario \(name): its types are read-only for apps; use `health seed scenario \(name)` on a shut-down device (HEALTH-3)")
            }
            guard HealthScenarios.writable.contains(name) else {
                throw ParseError("health scenario: unknown scenario '\(name)' (\(HealthScenarios.writable.joined(separator: ", ")))")
            }
            if let s = options["--steps"], Int(s) == nil { throw ParseError("health scenario: --steps takes a number") }
            if let s = options["--start"], HealthImport.time(s, now: Date()) == nil { throw ParseError("health scenario: --start takes a time") }
            return .scenario(name: name, date: try date(), days: try int("--days", 1), seed: try seedValue(),
                             steps: options["--steps"].flatMap { Int($0) }, start: options["--start"], withReadOnly: flags.contains("--with-read-only"))
        case "stream":
            guard positional.count == 1, let kind = StreamKind(rawValue: positional[0]) else {
                throw ParseError("health stream \(StreamKind.allCases.map(\.rawValue).joined(separator: "|")) [--bpm A..B] [--every 5s] [--for 10m]")
            }
            var range = kind.defaultRange
            if let r = options["--bpm"] ?? options["--range"] {
                let parts = r.components(separatedBy: "..")
                guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a < b else {
                    throw ParseError("health stream: a range is A..B (80..150)")
                }
                range = a...b
            }
            if kind == .spo2, range.upperBound > 1 { range = (range.lowerBound / 100)...(range.upperBound / 100) }
            let every = try options["--every"].map { s -> TimeInterval in
                guard let d = HealthImport.duration(s), d >= 1 else { throw ParseError("health stream: --every takes a duration of at least 1s (5s)") }
                return d
            } ?? 5
            let duration = try options["--for"].map { s -> TimeInterval in
                guard let d = HealthImport.duration(s), d > 0 else { throw ParseError("health stream: --for takes a duration (10m)") }
                return d
            }
            return .stream(kind: kind, range: range, every: every, duration: duration)
        case "grant", "revoke":
            guard positional.count == 1 else { throw ParseError("health \(verb) <bundle id>") }
            if positional[0] == HealthChannel.agentBundleID {
                throw ParseError("health \(verb): Ycode grants its own agent itself")
            }
            return verb == "grant" ? .grant(bundleID: positional[0]) : .revoke(bundleID: positional[0])
        case "seed":
            if positional.first == "scenario" {
                guard positional.count == 2 else { throw ParseError("health seed scenario <name>") }
                let name = positional[1]
                guard HealthScenarios.readOnly.contains(name) || name == "spo2-dips" else {
                    throw ParseError("health seed scenario: \(HealthScenarios.readOnly.joined(separator: ", ")) or spo2-dips")
                }
                return .seedScenario(name: name, date: try date(), days: try int("--days", 1), seed: try seedValue())
            }
            guard positional.count == 1 else { throw ParseError("health seed <file> | seed scenario <name>") }
            return .seedFile(path: positional[0])
        default:
            throw ParseError("health: unknown command '\(verb)'\n" + usage)
        }
    }

    /// "YYYY-MM-DD" → that day's local midnight.
    public static func parseDay(_ text: String, timeZone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }
}
