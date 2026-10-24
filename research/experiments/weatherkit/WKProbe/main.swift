// WKProbe: our own black-box probe for WeatherKit and Core Location in the
// iOS Simulator. It calls only public API and prints what it observes to
// stderr (one line per observation, prefixed with seconds since launch).
//
// Launch arguments:
//   -mode weather   call every WeatherService entry point and report results/errors
//   -mode location  Core Location authorization, updates, geocoding, then weather
//   -mode codable   record the Codable shape of the WeatherKit model types
//   -mode trap      reversed date range for an hourly query (crashes the app)
//   -wait N         seconds to keep collecting location updates (default 8)
//   -lat X -lon Y   location for weather calls (default 41.15, -81.36)

import UIKit
import CoreLocation
import WeatherKit

let gStart = Date()
nonisolated(unsafe) var gLines: [String] = []
func P(_ s: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(gStart))
    let line = "[\(t)] \(s)"
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    DispatchQueue.main.async {
        gLines.append(line)
        if gLines.count > 60 { gLines.removeFirst(gLines.count - 60) }
        gLabel?.text = gLines.joined(separator: "\n")
    }
}
nonisolated(unsafe) var gLabel: UILabel?

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

func describe(_ error: Error) -> String {
    let ns = error as NSError
    var s = "type=\(type(of: error)) reflect=\(String(reflecting: error)) domain=\(ns.domain) code=\(ns.code)"
    s += " userInfoKeys=\(ns.userInfo.keys.sorted())"
    s += " localizedDescription=\"\(error.localizedDescription)\""
    if let le = error as? LocalizedError {
        s += " failureReason=\(le.failureReason ?? "nil") recoverySuggestion=\(le.recoverySuggestion ?? "nil") helpAnchor=\(le.helpAnchor ?? "nil")"
    }
    if let we = error as? WeatherError {
        s += " isWeatherError permissionDenied=\(we == .permissionDenied) unknown=\(we == .unknown)"
    }
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        s += " underlying=(\(u.domain) \(u.code) \(u.localizedDescription))"
    }
    return s
}

func timed<T>(_ label: String, _ body: () async throws -> T) async -> T? {
    let t0 = Date()
    do {
        let v = try await body()
        P("\(label): OK in \(String(format: "%.3f", Date().timeIntervalSince(t0)))s value=\(String(describing: v).prefix(400))")
        return v
    } catch {
        P("\(label): THROW in \(String(format: "%.3f", Date().timeIntervalSince(t0)))s \(describe(error))")
        return nil
    }
}

// MARK: weather

func weatherProbe(_ loc: CLLocation) async {
    let svc = WeatherService.shared
    P("weather: shared===shared \(svc === WeatherService.shared); new instance distinct \(WeatherService() !== svc)")
    P("weather: WeatherError.permissionDenied desc=\"\(WeatherError.permissionDenied.localizedDescription)\" errorDescription=\(WeatherError.permissionDenied.errorDescription ?? "nil") failureReason=\(WeatherError.permissionDenied.failureReason ?? "nil")")
    P("weather: WeatherError.unknown desc=\"\(WeatherError.unknown.localizedDescription)\" errorDescription=\(WeatherError.unknown.errorDescription ?? "nil")")
    let ns = WeatherError.permissionDenied as NSError
    P("weather: WeatherError.permissionDenied as NSError domain=\(ns.domain) code=\(ns.code); unknown code=\((WeatherError.unknown as NSError).code)")

    if let a = await timed("attribution", { try await svc.attribution }) {
        P("attribution serviceName=\(a.serviceName) legalPageURL=\(a.legalPageURL) squareMarkURL=\(a.squareMarkURL) combinedMarkLightURL=\(a.combinedMarkLightURL) combinedMarkDarkURL=\(a.combinedMarkDarkURL) legalAttributionText=\(a.legalAttributionText)")
    }
    _ = await timed("weather(for:) #1", { try await svc.weather(for: loc) })
    _ = await timed("weather(for:) #2 (repeat)", { try await svc.weather(for: loc) })
    _ = await timed("new WeatherService().weather(for:)", { try await WeatherService().weather(for: loc) })
    _ = await timed("including .current", { try await svc.weather(for: loc, including: .current) })
    _ = await timed("including .minute", { try await svc.weather(for: loc, including: .minute) })
    _ = await timed("including .hourly", { try await svc.weather(for: loc, including: .hourly) })
    _ = await timed("including .daily", { try await svc.weather(for: loc, including: .daily) })
    _ = await timed("including .alerts", { try await svc.weather(for: loc, including: .alerts) })
    _ = await timed("including .availability", { try await svc.weather(for: loc, including: .availability) })
    _ = await timed("including .changes", { try await svc.weather(for: loc, including: .changes) })
    _ = await timed("including .historicalComparisons", { try await svc.weather(for: loc, including: .historicalComparisons) })
    let now = Date()
    _ = await timed("including .daily(start:end:) 10d", { try await svc.weather(for: loc, including: .daily(startDate: now, endDate: now.addingTimeInterval(10 * 86400))) })
    _ = await timed("including .hourly(start:end:) empty range", { try await svc.weather(for: loc, including: .hourly(startDate: now, endDate: now)) })
    _ = await timed("including .current,.daily,.hourly", { try await svc.weather(for: loc, including: .current, .daily, .hourly) })
    _ = await timed("dailyStatistics temperature", { try await svc.dailyStatistics(for: loc, including: .temperature) })
    _ = await timed("monthlyStatistics precipitation", { try await svc.monthlyStatistics(for: loc, including: .precipitation) })
    _ = await timed("hourlyStatistics temperature", { try await svc.hourlyStatistics(for: loc, including: .temperature) })
    _ = await timed("dailySummary temperature", { try await svc.dailySummary(for: loc, including: .temperature) })
    _ = await timed("weather invalid lat=200", { try await svc.weather(for: CLLocation(latitude: 200, longitude: 0), including: .current) })
    _ = await timed("weather (0,0)", { try await svc.weather(for: CLLocation(latitude: 0, longitude: 0), including: .current) })
    // concurrency: two simultaneous calls
    let t0 = Date()
    async let x: Void = { _ = await timed("concurrent A", { try await svc.weather(for: loc, including: .current) }) }()
    async let y: Void = { _ = await timed("concurrent B", { try await svc.weather(for: loc, including: .current) }) }()
    _ = await (x, y)
    P("concurrent pair total \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")
    // cancellation
    let task = Task { await timed("cancelled task", { try await svc.weather(for: loc) }) }
    task.cancel()
    _ = await task.value
    P("weather: END-OF-WEATHER")
}

// MARK: location

final class LocObs: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let m = CLLocationManager()
    var count = 0
    var first: CLLocation?
    override init() {
        super.init()
        m.delegate = self
    }
    func statusName(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        P("loc: didChangeAuthorization status=\(statusName(m.authorizationStatus)) accuracy=\(m.accuracyAuthorization == .fullAccuracy ? "full" : "reduced") main=\(Thread.isMainThread)")
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        for l in locs {
            count += 1
            if first == nil { first = l }
            P("loc: update #\(count) lat=\(l.coordinate.latitude) lon=\(l.coordinate.longitude) hAcc=\(l.horizontalAccuracy) alt=\(l.altitude) vAcc=\(l.verticalAccuracy) speed=\(l.speed) sAcc=\(l.speedAccuracy) course=\(l.course) cAcc=\(l.courseAccuracy) floor=\(String(describing: l.floor?.level)) age=\(String(format: "%.3f", -l.timestamp.timeIntervalSinceNow)) simulated=\(String(describing: l.sourceInformation?.isSimulatedBySoftware)) accessory=\(String(describing: l.sourceInformation?.isProducedByAccessory))")
        }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        P("loc: didFailWithError \(describe(e))")
    }
}

func locationProbe(wait: Double) async {
    let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    P("loc: locationServicesEnabled=\(enabled)")
    let o = await MainActor.run { LocObs() }
    await MainActor.run {
        P("loc: initial status=\(o.statusName(o.m.authorizationStatus)) accuracy=\(o.m.accuracyAuthorization == .fullAccuracy ? "full" : "reduced") desiredAccuracy=\(o.m.desiredAccuracy) distanceFilter=\(o.m.distanceFilter) headingAvailable=\(CLLocationManager.headingAvailable()) significantChange=\(CLLocationManager.significantLocationChangeMonitoringAvailable()) rangingAvailable=\(CLLocationManager.isRangingAvailable())")
        P("loc: plist WhenInUse=\(Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil)")
        o.m.requestWhenInUseAuthorization()
        P("loc: requestWhenInUseAuthorization returned; status now=\(o.statusName(o.m.authorizationStatus))")
    }
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await MainActor.run {
        P("loc: after 2s status=\(o.statusName(o.m.authorizationStatus)) cached location=\(String(describing: o.m.location?.coordinate.latitude)),\(String(describing: o.m.location?.coordinate.longitude))")
        o.m.requestLocation()
        P("loc: requestLocation called")
    }
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await MainActor.run {
        o.m.startUpdatingLocation()
        P("loc: startUpdatingLocation called")
    }
    try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    await MainActor.run { o.m.stopUpdatingLocation(); P("loc: stopped after \(o.count) updates") }
    // async API (iOS 17)
    let t0 = Date()
    let live = Task { () -> Int in
        var n = 0
        do {
            for try await u in CLLocationUpdate.liveUpdates() {
                n += 1
                P("loc: liveUpdate #\(n) location=\(String(describing: u.location?.coordinate.latitude)),\(String(describing: u.location?.coordinate.longitude)) authDenied=\(u.authorizationDenied) authDeniedGlobally=\(u.authorizationDeniedGlobally) authRequestInProgress=\(u.authorizationRequestInProgress) insufficientlyInUse=\(u.insufficientlyInUse) stationary=\(u.stationary) locationUnavailable=\(u.locationUnavailable) accuracyLimited=\(u.accuracyLimited) serviceSessionRequired=\(u.serviceSessionRequired)")
                if n >= 3 { break }
            }
        } catch { P("loc: liveUpdates threw \(describe(error))") }
        return n
    }
    let watchdog = Task { try? await Task.sleep(nanoseconds: 6_000_000_000); live.cancel() }
    let n = await live.value
    watchdog.cancel()
    P("loc: liveUpdates got \(n) in \(String(format: "%.3f", Date().timeIntervalSince(t0)))s")

    let loc = await MainActor.run { o.first ?? o.m.location }
    if let loc {
        let g = CLGeocoder()
        let t1 = Date()
        do {
            let pms = try await g.reverseGeocodeLocation(loc)
            for p in pms {
                P("loc: reverseGeocode in \(String(format: "%.3f", Date().timeIntervalSince(t1)))s locality=\(p.locality ?? "nil") admin=\(p.administrativeArea ?? "nil") country=\(p.isoCountryCode ?? "nil") tz=\(p.timeZone?.identifier ?? "nil") name=\(p.name ?? "nil")")
            }
        } catch {
            P("loc: reverseGeocode THROW in \(String(format: "%.3f", Date().timeIntervalSince(t1)))s \(describe(error))")
        }
        _ = await timed("weather for simulated location", { try await WeatherService.shared.weather(for: loc, including: .current) })
    } else {
        P("loc: no location obtained")
    }
    P("loc: END-OF-LOCATION")
    _ = o
}

// MARK: codable shape recorder

final class Rec: @unchecked Sendable {
    var lines: [String] = []
    var nextString: String? = nil
    var attempt: [String: Int] = [:]
    func log(_ path: [CodingKey], _ what: String) {
        lines.append(path.map { $0.stringValue }.joined(separator: ".") + " " + what)
    }
}

func firstRaw<E: CaseIterable & RawRepresentable>(_ t: E.Type) -> Any? { t.allCases.first?.rawValue }

struct IndexKey: CodingKey {
    var stringValue: String; var intValue: Int?
    init(_ i: Int) { stringValue = "[\(i)]"; intValue = i }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.init(intValue) }
}

struct RDecoder: Decoder {
    let rec: Rec
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    func container<K: CodingKey>(keyedBy: K.Type) throws -> KeyedDecodingContainer<K> {
        rec.log(codingPath, "{keyed}")
        return KeyedDecodingContainer(RKeyed<K>(rec: rec, codingPath: codingPath))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        rec.log(codingPath, "[unkeyed]")
        return RUnkeyed(rec: rec, codingPath: codingPath)
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        RSingle(rec: rec, codingPath: codingPath)
    }
}

func prim<T>(_ t: T.Type, _ rec: Rec) -> T? {
    if T.self == String.self { let s = rec.nextString ?? "x"; rec.nextString = nil; return (s as! T) }
    if T.self == Double.self { return (1.5 as! T) }
    if T.self == Float.self { return (Float(1.5) as! T) }
    if T.self == Int.self { return (1 as! T) }
    if T.self == Bool.self { return (true as! T) }
    if T.self == Int64.self { return (Int64(1) as! T) }
    if T.self == UInt64.self { return (UInt64(1) as! T) }
    if T.self == Int32.self { return (Int32(1) as! T) }
    return nil
}

// Candidate names tried, in order, when a value is an enum whose raw values or
// case names are not public (no CaseIterable): public case names first, then guesses.
let candidates = ["available", "temporarilyUnavailable", "unsupported", "unknown",
    "increase", "decrease", "steady", "mean", "highTemperature", "lowTemperature",
    "precipitationAmount", "snowfallAmount", "minor", "moderate", "severe", "extreme",
    "normal", "high", "low", "expected", "likely", "observed", "immediate", "future",
    "past", "none", "clear", "start", "end", "begin", "stop", "constant", "change",
    "onset", "cessation", "rain", "snow", "beginning", "ending",
    "00000000-0000-0000-0000-000000000001"]

func pathString(_ p: [CodingKey]) -> String { p.map { $0.stringValue }.joined(separator: ".") }

func decodeAny<T: Decodable>(_ t: T.Type, _ rec: Rec, _ path: [CodingKey]) throws -> T {
    if let ct = T.self as? any (CaseIterable & RawRepresentable).Type, let r = firstRaw(ct) as? String {
        rec.nextString = r
    }
    if T.self == String.self, let i = rec.attempt[pathString(path)], i > 0 {
        rec.log(path, ": String (candidate \(candidates[i - 1]))")
        return candidates[i - 1] as! T
    }
    if let p = prim(t, rec) { rec.log(path, ": \(T.self)"); return p }
    rec.log(path, ": \(T.self)")
    let ps = pathString(path)
    var lastError: Error?
    for i in 0...candidates.count {
        rec.attempt[ps] = i
        do {
            let v = try T(from: RDecoder(rec: rec, codingPath: path))
            if i > 0 { rec.log(path, "accepted candidate #\(i) (\(candidates[i - 1]))") }
            rec.attempt[ps] = nil
            return v
        } catch let e as DecodingError {
            lastError = e
            var ctxPath: [CodingKey] = []
            switch e {
            case .dataCorrupted(let c), .typeMismatch(_, let c): ctxPath = c.codingPath
            default: break
            }
            if pathString(ctxPath) != ps { rec.attempt[ps] = nil; throw e }
        }
    }
    rec.attempt[ps] = nil
    throw lastError!
}

struct RKeyed<K: CodingKey>: KeyedDecodingContainerProtocol {
    let rec: Rec
    var codingPath: [CodingKey]
    var allKeys: [K] {
        guard let i = rec.attempt[pathString(codingPath)], i > 0 else { return [] }
        if let k = K(stringValue: candidates[i - 1]) { return [k] }
        return []
    }
    func contains(_ key: K) -> Bool { true }
    func decodeNil(forKey key: K) throws -> Bool {
        // Optional values are reported present, except non-public air quality data, Foundation URL's
        // optional "base" (it would recurse forever) and anything very deep.
        let absent = ["base", "airQuality", "news", "marineForecast", "tideEvents", "locationInfo", "weatherHighlights", "dataNotice", "historicalFacts", "periodForecasts"].contains(key.stringValue) || codingPath.count > 10
        rec.log(codingPath + [key], absent ? "?nil-check -> nil" : "?nil-check")
        return absent
    }
    func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T { try decodeAny(type, rec, codingPath + [key]) }
    func nestedContainer<NK: CodingKey>(keyedBy: NK.Type, forKey key: K) throws -> KeyedDecodingContainer<NK> {
        rec.log(codingPath + [key], "{nested keyed}")
        return KeyedDecodingContainer(RKeyed<NK>(rec: rec, codingPath: codingPath + [key]))
    }
    func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
        rec.log(codingPath + [key], "[nested unkeyed]")
        return RUnkeyed(rec: rec, codingPath: codingPath + [key])
    }
    func superDecoder() throws -> Decoder { RDecoder(rec: rec, codingPath: codingPath) }
    func superDecoder(forKey key: K) throws -> Decoder { RDecoder(rec: rec, codingPath: codingPath + [key]) }
}

struct RUnkeyed: UnkeyedDecodingContainer {
    let rec: Rec
    var codingPath: [CodingKey]
    var count: Int? { 1 }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= 1 }
    mutating func decodeNil() throws -> Bool { false }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        defer { currentIndex += 1 }
        return try decodeAny(type, rec, codingPath + [IndexKey(currentIndex)])
    }
    mutating func nestedContainer<NK: CodingKey>(keyedBy: NK.Type) throws -> KeyedDecodingContainer<NK> {
        defer { currentIndex += 1 }
        return KeyedDecodingContainer(RKeyed<NK>(rec: rec, codingPath: codingPath + [IndexKey(currentIndex)]))
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        defer { currentIndex += 1 }
        return RUnkeyed(rec: rec, codingPath: codingPath + [IndexKey(currentIndex)])
    }
    mutating func superDecoder() throws -> Decoder {
        defer { currentIndex += 1 }
        return RDecoder(rec: rec, codingPath: codingPath + [IndexKey(currentIndex)])
    }
}

struct RSingle: SingleValueDecodingContainer {
    let rec: Rec
    var codingPath: [CodingKey]
    func decodeNil() -> Bool { false }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decodeAny(type, rec, codingPath) }
}

func shape<T: Codable>(_ t: T.Type) {
    let rec = Rec()
    do {
        let v = try decodeAny(t, rec, [])
        P("codable \(T.self): decode OK, \(rec.lines.count) steps")
        for l in rec.lines { P("codable \(T.self) step: \(l)") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .deferredToDate
        let data = try enc.encode(v)
        P("codable \(T.self) json: \(String(data: data, encoding: .utf8) ?? "?")")
        let back = try JSONDecoder().decode(T.self, from: data)
        let again = try enc.encode(back)
        P("codable \(T.self) roundtrip-identical=\(again == data)")
    } catch {
        P("codable \(T.self): FAILED after \(rec.lines.count) steps: \(error)")
        for l in rec.lines.suffix(8) { P("codable \(T.self) step: \(l)") }
    }
}

func codableProbe() {
    shape(WeatherAttribution.self)
    shape(WeatherMetadata.self)
    shape(Wind.self)
    shape(UVIndex.self)
    shape(SunEvents.self)
    shape(MoonEvents.self)
    shape(CurrentWeather.self)
    shape(MinuteWeather.self)
    shape(HourWeather.self)
    shape(DayWeather.self)
    shape(WeatherAlert.self)
    shape(WeatherAvailability.self)
    shape(Forecast<HourWeather>.self)
    shape(Forecast<MinuteWeather>.self)
    shape(WeatherChanges.self)
    shape(HistoricalComparisons.self)
    shape(DailyWeatherStatistics<DayTemperatureStatistics>.self)
    shape(MonthlyWeatherStatistics<MonthPrecipitationStatistics>.self)
    shape(HourlyWeatherStatistics<HourTemperatureStatistics>.self)
    shape(DailyWeatherSummary<DayPrecipitationSummary>.self)
    shape(Weather.self)
    for c in WeatherCondition.allCases { P("enum WeatherCondition \(c.rawValue) desc=\"\(c.description)\" accessibility=\"\(c.accessibilityDescription)\"") }
    for c in Precipitation.allCases { P("enum Precipitation \(c.rawValue) desc=\"\(c.description)\" accessibility=\"\(c.accessibilityDescription)\"") }
    for c in PressureTrend.allCases { P("enum PressureTrend \(c.rawValue) desc=\"\(c.description)\"") }
    for c in MoonPhase.allCases { P("enum MoonPhase \(c.rawValue) desc=\"\(c.description)\" symbol=\(c.symbolName)") }
    for c in WeatherSeverity.allCases { P("enum WeatherSeverity \(c.rawValue) desc=\"\(c.description)\"") }
    for c in Wind.CompassDirection.allCases { P("enum CompassDirection \(c.rawValue) abbr=\(c.abbreviation) desc=\"\(c.description)\"") }
    for c in UVIndex.ExposureCategory.allCases { P("enum UVExposure \(c.rawValue) range=\(c.rangeValue) desc=\"\(c.description)\"") }
    P("codable: END-OF-CODABLE")
}

// MARK: app shell

final class VC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let l = UILabel(frame: view.bounds.insetBy(dx: 8, dy: 60))
        l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        l.numberOfLines = 0
        l.font = .monospacedSystemFont(ofSize: 8, weight: .regular)
        view.addSubview(l)
        gLabel = l
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo s: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = VC()
        w.makeKeyAndVisible()
        window = w
        P("scene connected")
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let mode = arg("-mode") ?? "weather"
        let wait = Double(arg("-wait") ?? "8") ?? 8
        let lat = Double(arg("-lat") ?? "41.15") ?? 41.15
        let lon = Double(arg("-lon") ?? "-81.36") ?? -81.36
        P("WKProbe start mode=\(mode) bundle=\(Bundle.main.bundleIdentifier ?? "?") os=\(UIDevice.current.systemVersion)")
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            switch mode {
            case "location": await locationProbe(wait: wait)
            case "codable": codableProbe()
            case "trap":
                // A date range whose end precedes its start; observed to trap.
                let now = Date()
                P("trap: building .hourly(startDate:endDate:) with end < start")
                _ = await timed("including .hourly(start:end:) reversed", { try await WeatherService.shared.weather(for: CLLocation(latitude: lat, longitude: lon), including: .hourly(startDate: now, endDate: now.addingTimeInterval(-3600))) })
            default: await weatherProbe(CLLocation(latitude: lat, longitude: lon))
            }
            P("END-OF-SCRIPT")
        }
        return true
    }
    func application(_ app: UIApplication, configurationForConnecting s: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: s.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}
