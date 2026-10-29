// Location simulation (specs/simulator/simulator-features.md §4.10,
// "Ycode implementation"): the request sequences Ycode's guest agent sends
// to locationd's simulation service through CoreLocation's simulation
// manager, the presets, the scenarios, and the route and scenario files the
// host reads (GPX, the route JSON of §7.2, plain coordinate lists).

import Foundation

public struct Coordinate: Equatable, Sendable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "lat,lon" (`.` decimals; simctl's form). Nil when malformed or out of range.
    public init?(argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        self.init(lat, lon)
    }

    public var description: String { "\(latitude),\(longitude)" }

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial great-circle bearing in degrees, 0…360.
    public func bearing(to other: Coordinate) -> Double {
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dl = (other.longitude - longitude) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let b = atan2(y, x) * 180 / .pi
        return (b + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// One fix of a scenario file (§4.10 "Scenario file format": the coding keys
/// of a keyed-archived CLLocation).
public struct ScenarioPoint: Equatable, Sendable {
    public var coordinate: Coordinate
    public var altitude: Double = 0
    public var horizontalAccuracy: Double = 5
    public var verticalAccuracy: Double = -1
    public var course: Double = -1
    public var speed: Double = -1
    /// Seconds from the scenario's start.
    public var time: Double

    public init(_ coordinate: Coordinate, time: Double, altitude: Double = 0, horizontalAccuracy: Double = 5,
                verticalAccuracy: Double = -1, course: Double = -1, speed: Double = -1) {
        self.coordinate = coordinate
        self.time = time
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.course = course
        self.speed = speed
    }

    /// The agent's wire form.
    public var dictionary: [String: Any] {
        ["latitude": coordinate.latitude, "longitude": coordinate.longitude, "altitude": altitude,
         "horizontalAccuracy": horizontalAccuracy, "verticalAccuracy": verticalAccuracy,
         "course": course, "speed": speed, "time": time]
    }
}

/// How often a route delivers a fix.
public enum RouteSpacing: Equatable, Sendable {
    case interval(Double)   // seconds
    case distance(Double)   // metres
}

/// One request to the simulation manager, in order.
public enum LocationStep: Equatable, Sendable {
    case stop
    case clear
    case append(Coordinate)
    case start
    case interval(Double)
    case distance(Double)
    case speed(Double)
    /// `LocationRepeatBehavior` of the scenario that follows (1 once, 2 loop).
    case repeatBehavior(Int)
    /// Loads a scenario file (a guest path; locationd reads it).
    case loadScenario(String)
    /// Ycode: the agent writes this scenario file (guest path) from points,
    /// then a `loadScenario` of it follows.
    case writeScenario(path: String, points: [ScenarioPoint], repeatBehavior: Int)

    /// The agent's wire form: { call, … }.
    public var dictionary: [String: Any] {
        switch self {
        case .stop: ["call": "stop"]
        case .clear: ["call": "clear"]
        case .start: ["call": "start"]
        case .append(let c): ["call": "append", "latitude": c.latitude, "longitude": c.longitude]
        case .interval(let s): ["call": "interval", "value": s]
        case .distance(let m): ["call": "distance", "value": m]
        case .speed(let v): ["call": "speed", "value": v]
        case .repeatBehavior(let r): ["call": "repeat", "value": r]
        case .loadScenario(let p): ["call": "scenario", "path": p]
        case .writeScenario(let p, let points, let r):
            ["call": "write-scenario", "path": p, "points": points.map(\.dictionary), "repeat": r]
        }
    }
}

public enum LocationCommand: Equatable, Sendable {
    case set(Coordinate)
    case route([Coordinate], speed: Double, spacing: RouteSpacing)
    /// A scenario file in the runtime (by name).
    case scenario(name: String)
    /// Ycode's own scenario (from a GPX or route file), written into the device.
    case points([ScenarioPoint], loop: Bool)
    case clear

    public static let defaultSpeed = 20.0
    public static let defaultInterval = 1.0
}

public enum SimLocation {
    /// The runtime's scenario directory (a guest path: the runtime is the guest's root).
    public static let scenarioDirectory = "/System/Library/Frameworks/CoreLocation.framework/Support/SimulationScenarios"
    /// The scenarios of §7.1 in menu order (files of the runtime; their data
    /// is never copied into Ycode).
    public static let builtInScenarios = ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"]
    /// The guest path Ycode's own scenarios are written to (DEV/data/tmp).
    public static let ycodeScenarioPath = "/tmp/ycode-location-scenario.plist"

    /// The request sequences of §4.10.
    public static func steps(for command: LocationCommand, scenarioDirectory: String = scenarioDirectory,
                             ycodeScenarioPath: String = ycodeScenarioPath) -> [LocationStep] {
        switch command {
        case .set(let c):
            return [.clear, .stop, .append(c), .start]
        case .route(let waypoints, let speed, let spacing):
            var s: [LocationStep] = [.stop, .clear]
            switch spacing {
            case .interval(let i): s.append(.interval(i))
            case .distance(let d): s.append(.distance(d))
            }
            s.append(.speed(speed))
            s += waypoints.map { .append($0) }
            s.append(.start)
            return s
        case .scenario(let name):
            let path = name.hasPrefix("/") ? name : scenarioDirectory + "/" + name + ".plist"
            return [.stop, .clear, .loadScenario(path), .start]
        case .points(let points, let loop):
            return [.stop, .clear, .writeScenario(path: ycodeScenarioPath, points: points, repeatBehavior: loop ? 2 : 1),
                    .loadScenario(ycodeScenarioPath), .start]
        case .clear:
            return [.stop, .clear]
        }
    }

    /// Device Hub's preset places (§7.1). **Ycode decision** (open question
    /// Q5): the reference's coordinates were not read; these are each city's
    /// commonly published centre.
    public static let presets: [(name: String, coordinate: Coordinate)] = [
        ("Berlin, Germany", Coordinate(52.5200, 13.4050)),
        ("Cupertino, CA, USA", Coordinate(37.3230, -122.0322)),
        ("Hong Kong, China", Coordinate(22.3193, 114.1694)),
        ("Johannesburg, South Africa", Coordinate(-26.2041, 28.0473)),
        ("London, England", Coordinate(51.5072, -0.1276)),
        ("Mexico City, Mexico", Coordinate(19.4326, -99.1332)),
        ("Mumbai, India", Coordinate(19.0760, 72.8777)),
        ("New York, NY, USA", Coordinate(40.7128, -74.0060)),
        ("Paris, France", Coordinate(48.8566, 2.3522)),
        ("Rio de Janeiro, Brazil", Coordinate(-22.9068, -43.1729)),
        ("San Francisco, CA, USA", Coordinate(37.7749, -122.4194)),
        ("Sydney, Australia", Coordinate(-33.8688, 151.2093)),
        ("Tokyo, Japan", Coordinate(35.6762, 139.6503)),
        ("Warsaw, Poland", Coordinate(52.2297, 21.0122)),
    ]

    /// A preset by name: its full name, or the city alone, any case.
    public static func preset(named name: String) -> Coordinate? {
        let n = name.lowercased()
        return presets.first { $0.name.lowercased() == n || $0.name.lowercased().split(separator: ",").first.map(String.init) == n }?.coordinate
    }

    // MARK: Files

    public enum FileError: Error, Equatable, CustomStringConvertible {
        case empty
        case malformed(String)
        public var description: String {
            switch self {
            case .empty: "no waypoints in the file"
            case .malformed(let s): s
            }
        }
    }

    /// A location file: GPX (track, route or way points), the route JSON of
    /// §7.2 ({ mode, distance|interval, speed, waypoints: [{latitude, longitude}] }),
    /// or a list of "lat,lon" lines. GPX with times becomes a scenario that
    /// replays the times; everything else becomes a route.
    public static func parseFile(_ text: String) throws -> LocationCommand {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") { return try parseRouteJSON(t) }
        if t.hasPrefix("<") { return try parseGPX(t) }
        var points: [Coordinate] = []
        for (i, line) in t.split(whereSeparator: \.isNewline).enumerated() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            guard let c = Coordinate(argument: l) else { throw FileError.malformed("line \(i + 1): not \"latitude,longitude\": \(l)") }
            points.append(c)
        }
        guard !points.isEmpty else { throw FileError.empty }
        return points.count == 1 ? .set(points[0]) : .route(points, speed: LocationCommand.defaultSpeed, spacing: .interval(LocationCommand.defaultInterval))
    }

    static func parseRouteJSON(_ text: String) throws -> LocationCommand {
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw FileError.malformed("not a JSON object")
        }
        guard let list = o["waypoints"] as? [[String: Any]] else { throw FileError.malformed("no \"waypoints\" array") }
        var points: [Coordinate] = []
        for (i, w) in list.enumerated() {
            guard let lat = (w["latitude"] as? NSNumber)?.doubleValue, let lon = (w["longitude"] as? NSNumber)?.doubleValue,
                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw FileError.malformed("waypoint \(i + 1): needs latitude and longitude")
            }
            points.append(Coordinate(lat, lon))
        }
        guard points.count >= 2 else { throw points.isEmpty ? FileError.empty : FileError.malformed("a route needs at least 2 waypoints") }
        let speed = (o["speed"] as? NSNumber)?.doubleValue ?? LocationCommand.defaultSpeed
        let mode = o["mode"] as? String ?? "interval"
        let spacing: RouteSpacing
        switch mode {
        case "distance": spacing = .distance((o["distance"] as? NSNumber)?.doubleValue ?? 10)
        case "interval": spacing = .interval((o["interval"] as? NSNumber)?.doubleValue ?? LocationCommand.defaultInterval)
        default: throw FileError.malformed("mode must be \"distance\" or \"interval\"")
        }
        guard speed > 0 else { throw FileError.malformed("speed must be positive") }
        return .route(points, speed: speed, spacing: spacing)
    }

    /// GPX 1.1 (public schema): `trkpt`, `rtept` and `wpt` elements with
    /// `lat` and `lon` attributes and optional `ele` and `time` children.
    static func parseGPX(_ text: String) throws -> LocationCommand {
        struct Raw { var c: Coordinate; var ele: Double?; var time: Date? }
        var found: [String: [Raw]] = ["trkpt": [], "rtept": [], "wpt": []]
        var rest = Substring(text)
        while let open = rest.range(of: "<") {
            rest = rest[open.upperBound...]
            let name = String(rest.prefix { $0.isLetter })
            guard found[name] != nil, let tagEnd = rest.firstIndex(of: ">") else { continue }
            let tag = rest[..<tagEnd]
            func attribute(_ a: String) -> Double? {
                for q in ["\"", "'"] {
                    if let r = tag.range(of: " \(a)=\(q)") ?? tag.range(of: "\t\(a)=\(q)") ?? tag.range(of: "\n\(a)=\(q)") {
                        let v = tag[r.upperBound...].prefix { String($0) != q }
                        return Double(v)
                    }
                }
                return nil
            }
            guard let lat = attribute("lat"), let lon = attribute("lon"), (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw FileError.malformed("a <\(name)> without valid lat and lon")
            }
            var raw = Raw(c: Coordinate(lat, lon))
            let selfClosing = tag.hasSuffix("/")
            rest = rest[rest.index(after: tagEnd)...]
            if !selfClosing, let close = rest.range(of: "</\(name)>") {
                let body = rest[..<close.lowerBound]
                func child(_ c: String) -> String? {
                    guard let a = body.range(of: "<\(c)>"), let b = body.range(of: "</\(c)>", range: a.upperBound..<body.endIndex) else { return nil }
                    return body[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                raw.ele = child("ele").flatMap(Double.init)
                raw.time = child("time").flatMap(parseISO8601)
                rest = rest[close.upperBound...]
            }
            found[name]!.append(raw)
        }
        let list = !found["trkpt"]!.isEmpty ? found["trkpt"]! : !found["rtept"]!.isEmpty ? found["rtept"]! : found["wpt"]!
        guard !list.isEmpty else { throw FileError.empty }
        if list.count == 1 { return .set(list[0].c) }
        // Times on every point: a scenario that replays them (course and
        // speed from the neighbouring points).
        if list.allSatisfy({ $0.time != nil }) {
            let t0 = list[0].time!
            var points: [ScenarioPoint] = []
            for (i, r) in list.enumerated() {
                let time = r.time!.timeIntervalSince(t0)
                var p = ScenarioPoint(r.c, time: max(0, time), altitude: r.ele ?? 0, verticalAccuracy: r.ele == nil ? -1 : 5)
                if i + 1 < list.count {
                    let n = list[i + 1]
                    let dt = n.time!.timeIntervalSince(r.time!)
                    p.course = r.c.bearing(to: n.c)
                    if dt > 0 { p.speed = r.c.distance(to: n.c) / dt }
                } else if let last = points.last {
                    p.course = last.course
                    p.speed = last.speed
                }
                points.append(p)
            }
            return .points(points, loop: false)
        }
        return .route(list.map(\.c), speed: LocationCommand.defaultSpeed, spacing: .interval(LocationCommand.defaultInterval))
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
