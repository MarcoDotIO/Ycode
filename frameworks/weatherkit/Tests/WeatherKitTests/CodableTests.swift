// C-CODABLE (plan.md §2): the archive format of codable.md. The reference
// goldens (W-CODABLE, R0b) are not available to the clean room, so these
// tests check our archives against codable.md's key tables directly: exact
// key sets, required vs optional keys, non-public keys preserved, value
// forms, and lossless round trips.
import Foundation
import Testing
@testable import WeatherKit

/// Expected keys per type: required and optional ("opt") keys of codable.md.
struct KeyTable: Sendable {
    let name: String
    let required: Set<String>
    let optional: Set<String>
    /// Picks the object for this type out of the encoded fixture `Weather`.
    let pick: @Sendable ([String: Any]) -> [String: Any]
    let decodes: @Sendable (Data) throws -> Void
}

private func sub(_ object: [String: Any], _ path: String...) -> [String: Any] {
    var current: Any = object
    for part in path {
        if let index = Int(part) {
            current = (current as! [Any])[index]
        } else {
            current = (current as! [String: Any])[part]!
        }
    }
    return current as! [String: Any]
}

private func decoder<T: Decodable & SendableMetatype>(_ type: T.Type) -> @Sendable (Data) throws -> Void {
    { data in _ = try JSONDecoder().decode(type, from: data) }
}

private let byTypeKeys: Set<String> = ["hail", "mixed", "rainfall", "sleet", "precipitation", "snowfallAmount"]
private let snowfallKeys: Set<String> = [
    "amount", "maximum", "minimum", "amountLiquidEquivalent", "maximumLiquidEquivalent", "minimumLiquidEquivalent",
]
private let sunKeys: Set<String> = [
    "astronomicalDawn", "nauticalDawn", "civilDawn", "sunrise", "solarNoon", "sunset", "civilDusk", "nauticalDusk",
    "astronomicalDusk", "solarMidnight",
]

let keyTables: [KeyTable] = [
    KeyTable(
        name: "Weather (§5)",
        required: ["currentWeather", "hourlyForecast", "dailyForecast", "availability"],
        optional: ["minuteForecast", "weatherAlerts", "weatherChanges"],
        pick: { $0 }, decodes: decoder(Weather.self)),
    KeyTable(
        name: "WeatherMetadata (§2)",
        required: ["date", "expirationDate", "latitude", "longitude"], optional: ["attribution"],
        pick: { sub($0, "currentWeather", "metadata") }, decodes: decoder(WeatherMetadata.self)),
    KeyTable(
        name: "Wind (§2)", required: ["compassDirection", "direction", "speed"], optional: ["gust"],
        pick: { sub($0, "currentWeather", "wind") }, decodes: decoder(Wind.self)),
    KeyTable(
        name: "UVIndex (§2)", required: ["value", "category"], optional: [],
        pick: { sub($0, "currentWeather", "uvIndex") }, decodes: decoder(UVIndex.self)),
    KeyTable(
        name: "SunEvents (§2)", required: [], optional: sunKeys,
        pick: { sub($0, "dailyForecast", "forecast", "0", "sun") }, decodes: decoder(SunEvents.self)),
    KeyTable(
        name: "MoonEvents (§2)", required: ["phase"], optional: ["moonrise", "moonset"],
        pick: { sub($0, "dailyForecast", "forecast", "0", "moon") }, decodes: decoder(MoonEvents.self)),
    KeyTable(
        name: "WeatherAvailability (§2)",
        required: ["minuteAvailability", "alertAvailability", "airQualityAvailability"], optional: [],
        pick: { sub($0, "availability") }, decodes: decoder(WeatherAvailability.self)),
    KeyTable(
        name: "intensity object (§2)", required: ["category", "value"], optional: [],
        pick: { sub($0, "currentWeather", "apparentPrecipitationIntensity") },
        decodes: decoder(PrecipitationIntensityValue.self)),
    KeyTable(
        name: "CurrentWeather (§3)",
        required: [
            "date", "cloudCover", "cloudCoverByAltitude", "cloudCoverLow", "cloudCoverMid", "cloudCoverHigh",
            "condition", "symbolName", "dewPoint", "humidity", "precipitationIntensity",
            "apparentPrecipitationIntensity", "pressure", "pressureTrend", "isDaylight", "temperature",
            "apparentTemperature", "uvIndex", "visibility", "wind", "metadata", "rainfallAmount", "snowfallAmount",
            "pastHourPrecipitationAmountByType", "pastSixHoursPrecipitationAmountByType",
            "pastTwentyFourHoursPrecipitationAmountByType", "nextHourPrecipitationAmountByType",
            "nextSixHoursPrecipitationAmountByType", "nextTwentyFourHoursPrecipitationAmountByType",
        ],
        optional: ["highTemperature", "lowTemperature"],
        pick: { sub($0, "currentWeather") }, decodes: decoder(CurrentWeather.self)),
    KeyTable(
        name: "CurrentWeather past/next amounts (§3)",
        required: ["pastHour", "pastSixHours", "pastTwentyFourHours", "nextHour", "nextSixHours", "nextTwentyFourHours"],
        optional: [],
        pick: { sub($0, "currentWeather", "rainfallAmount") }, decodes: decoder(PeriodAmounts.self)),
    KeyTable(
        name: "CloudCoverByAltitude (§3)", required: ["low", "medium", "high"], optional: [],
        pick: { sub($0, "currentWeather", "cloudCoverByAltitude") }, decodes: decoder(CloudCoverByAltitude.self)),
    KeyTable(
        name: "MinuteWeather (§3)",
        required: ["date", "precipitation", "precipitationChance", "precipitationIntensity", "apparentPrecipitationIntensity"],
        optional: [],
        pick: { sub($0, "minuteForecast", "forecast", "0") }, decodes: decoder(MinuteWeather.self)),
    KeyTable(
        name: "HourWeather (§3)",
        required: [
            "date", "cloudCover", "cloudCoverByAltitude", "cloudCoverLow", "cloudCoverMid", "cloudCoverHigh",
            "condition", "symbolName", "dewPoint", "humidity", "isDaylight", "precipitation", "precipitationAmount",
            "precipitationChance", "snowfallAmount", "pressure", "pressureTrend", "temperature",
            "apparentTemperature", "uvIndex", "visibility", "wind", "apparentPrecipitationIntensity",
        ],
        optional: [],
        pick: { sub($0, "hourlyForecast", "forecast", "0") }, decodes: decoder(HourWeather.self)),
    KeyTable(
        name: "DayWeather (§3)",
        required: [
            "date", "condition", "symbolName", "highTemperature", "lowTemperature", "maximumHumidity",
            "minimumHumidity", "humidityMax", "humidityMin", "precipitation", "precipitationChance",
            "precipitationAmountByType", "rainfallAmount", "snowfallAmount", "sun", "moon", "uvIndex", "wind",
            "maximumVisibility", "minimumVisibility", "visibilityMax", "visibilityMin", "windSpeedAvg",
            "windSpeedMax", "windGustSpeedMax", "daytimeForecast", "overnightForecast",
        ],
        optional: ["highTemperatureTime", "lowTemperatureTime", "highWindSpeed", "restOfDayForecast"],
        pick: { sub($0, "dailyForecast", "forecast", "0") }, decodes: decoder(DayWeather.self)),
    KeyTable(
        name: "DayPartForecast (§3)",
        required: [
            "forecastStart", "forecastEnd", "cloudCover", "cloudCoverByAltitude", "condition", "highTemperature",
            "lowTemperature", "humidity", "maximumHumidity", "minimumHumidity", "isDaylight", "maximumVisibility",
            "minimumVisibility", "maximumUVIndex", "minimumUVIndex", "precipitation", "precipitationAmountByType",
            "precipitationChance", "precipitationIntensityMax", "perceivedPrecipitationIntensityMax", "wind",
            "highWindSpeed",
        ],
        optional: [],
        pick: { sub($0, "dailyForecast", "forecast", "0", "daytimeForecast") }, decodes: decoder(DayPartForecast.self)),
    KeyTable(
        name: "PrecipitationAmountByType (§3)", required: byTypeKeys, optional: [],
        pick: { sub($0, "dailyForecast", "forecast", "0", "precipitationAmountByType") },
        decodes: decoder(PrecipitationAmountByType.self)),
    KeyTable(
        name: "SnowfallAmount (§3)", required: snowfallKeys, optional: [],
        pick: { sub($0, "dailyForecast", "forecast", "0", "precipitationAmountByType", "snowfallAmount") },
        decodes: decoder(SnowfallAmount.self)),
    KeyTable(
        name: "WeatherAlert (§3)",
        required: [
            "summary", "source", "severity", "detailsURL", "metadata", "id", "importance", "description", "date",
            "issuedDate", "expirationDate",
        ],
        optional: ["region", "details", "onsetTime", "endDate"],
        pick: { sub($0, "weatherAlerts", "0") }, decodes: decoder(WeatherAlert.self)),
    KeyTable(
        name: "Forecast<MinuteWeather> (§4)", required: ["forecast", "metadata"],
        optional: ["minuteSummary", "minuteSummaries", "minuteConditions", "marineLocation"],
        pick: { sub($0, "minuteForecast") }, decodes: decoder(Forecast<MinuteWeather>.self)),
    KeyTable(
        name: "Forecast<HourWeather> (§4)", required: ["forecast", "metadata"],
        optional: ["minuteSummary", "minuteSummaries", "minuteConditions", "marineLocation"],
        pick: { sub($0, "hourlyForecast") }, decodes: decoder(Forecast<HourWeather>.self)),
    KeyTable(
        name: "minuteSummaries element (§4)",
        required: ["date", "precipitation", "precipitationChance", "precipitationKind"],
        optional: ["expirationDate", "apparentPrecipitationIntensity"],
        pick: { sub($0, "minuteForecast", "minuteSummaries", "1") }, decodes: decoder(MinuteSummary.self)),
    KeyTable(
        name: "minuteConditions element (§4)",
        required: ["date", "shortDescription", "longDescription", "shift"], optional: ["expirationDate"],
        pick: { sub($0, "minuteForecast", "minuteConditions", "0") }, decodes: decoder(MinuteCondition.self)),
    KeyTable(
        name: "minuteConditions shift (§4)", required: ["date", "nextDate", "kind"], optional: [],
        pick: { sub($0, "minuteForecast", "minuteConditions", "0", "shift") }, decodes: decoder(MinuteCondition.Shift.self)),
    KeyTable(
        name: "WeatherChanges (§4)", required: ["changes", "metadata"], optional: [],
        pick: { sub($0, "weatherChanges") }, decodes: decoder(WeatherChanges.self)),
    KeyTable(
        name: "WeatherChange (§4)",
        required: ["date", "highTemperature", "lowTemperature", "dayPrecipitationAmount", "nightPrecipitationAmount"],
        optional: [],
        pick: { sub($0, "weatherChanges", "changes", "0") }, decodes: decoder(WeatherChange.self)),
]

@Suite("C-CODABLE: archive format (codable.md)")
struct CodableTests {
    let encoded: [String: Any]

    init() throws {
        encoded = try jsonObject(try fixtureWeather())
    }

    @Test("codable.md §2–§5: key sets equal the tables", arguments: keyTables.map(\.name))
    func keySets(name: String) throws {
        let table = keyTables.first { $0.name == name }!
        let object = table.pick(encoded)
        let keys = Set(object.keys)
        #expect(keys.isSuperset(of: table.required), "missing required keys: \(table.required.subtracting(keys))")
        #expect(keys.isSubset(of: table.required.union(table.optional)),
                "unexpected keys: \(keys.subtracting(table.required.union(table.optional)))")
    }

    @Test("codable.md §1: required keys are required, opt keys may be absent", arguments: keyTables.map(\.name))
    func requiredAndOptional(name: String) throws {
        let table = keyTables.first { $0.name == name }!
        let object = table.pick(encoded)
        try table.decodes(try data(object))
        for key in table.required {
            var reduced = object
            reduced[key] = nil
            #expect(throws: DecodingError.self, "\(name): decoding without required '\(key)' must fail") {
                try table.decodes(try data(reduced))
            }
        }
        for key in table.optional where object[key] != nil {
            var reduced = object
            reduced[key] = nil
            try table.decodes(try data(reduced))
        }
    }

    @Test("codable.md §2: WeatherAttribution is {storage: {...}} with non-public logoURL/sourceURL preserved")
    func attribution() throws {
        let json = """
            {"storage": {"serviceName": "S", "legalPageURL": "https://a.invalid/legal",
             "squareMarkURL": "https://a.invalid/sq.png", "combinedMarkLightURL": "https://a.invalid/l.png",
             "combinedMarkDarkURL": "https://a.invalid/d.png", "logoURL": "https://a.invalid/logo.png",
             "sourceURL": "https://a.invalid/source"}}
            """
        let attribution = try decode(WeatherAttribution.self, Data(json.utf8))
        #expect(attribution.serviceName == "S")
        #expect(attribution.legalPageURL.absoluteString == "https://a.invalid/legal")
        let object = try jsonObject(attribution)
        #expect(Set(object.keys) == ["storage"])
        let storage = object["storage"] as! [String: Any]
        #expect(Set(storage.keys) == [
            "serviceName", "legalPageURL", "squareMarkURL", "combinedMarkLightURL", "combinedMarkDarkURL", "logoURL",
            "sourceURL",
        ])
        #expect(storage["logoURL"] as? String == "https://a.invalid/logo.png")
        #expect(storage["sourceURL"] as? String == "https://a.invalid/source")
        // Without the opt keys.
        var reduced = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var reducedStorage = reduced["storage"] as! [String: Any]
        reducedStorage["logoURL"] = nil
        reducedStorage["sourceURL"] = nil
        reduced["storage"] = reducedStorage
        let minimal = try decode(WeatherAttribution.self, try data(reduced))
        #expect(Set((try jsonObject(minimal)["storage"] as! [String: Any]).keys).count == 5)
        // legalAttributionText is not archived.
        #expect(!String(decoding: try encode(attribution), as: UTF8.self).contains("legalAttributionText"))
    }

    @Test("codable.md §1: Measurement uses Foundation's form {value, unit {symbol, converter {coefficient, constant}}}")
    func measurementForm() throws {
        let current = encoded["currentWeather"] as! [String: Any]
        let temperature = current["temperature"] as! [String: Any]
        #expect(Set(temperature.keys) == ["value", "unit"])
        let unit = temperature["unit"] as! [String: Any]
        #expect(Set(unit.keys) == ["symbol", "converter"])
        #expect(unit["symbol"] as? String == "°C")
        let converter = unit["converter"] as! [String: Any]
        #expect(Set(converter.keys) == ["coefficient", "constant"])
        #expect(converter["constant"] as? Double == 273.15)
        // Our own encoding of a Foundation unit matches Foundation's.
        let foundation = try jsonObject(Measurement(value: 1.5, unit: UnitSpeed.kilometersPerHour))
        let wind = (current["wind"] as! [String: Any])["speed"] as! [String: Any]
        #expect(NSDictionary(dictionary: foundation["unit"] as! [String: Any]) == NSDictionary(dictionary: wind["unit"] as! [String: Any]))
    }

    @Test("codable.md §1: dates are numbers (seconds since 2001), URLs strings, string enums raw values")
    func scalarForms() throws {
        let current = encoded["currentWeather"] as! [String: Any]
        let date = try #require(current["date"] as? Double)
        #expect(Date(timeIntervalSinceReferenceDate: date) == fixtureAnchor)
        #expect(current["condition"] as? String == "partlyCloudy")
        #expect(current["pressureTrend"] as? String == "falling")
        let wind = current["wind"] as! [String: Any]
        #expect(wind["compassDirection"] is String)
        let alert = (encoded["weatherAlerts"] as! [[String: Any]])[0]
        #expect(alert["detailsURL"] as? String == "https://fixtures.invalid/weatherkit/alerts/1")
        #expect(alert["severity"] as? String == "moderate")
        #expect(alert["id"] as? String == "6F1A2B3C-4D5E-4F60-8172-93A4B5C6D7E8")
    }

    @Test("codable.md §1: payload-free non-String enums encode as {case: {}}, payload enums as {case: {_0: …}}")
    func enumForms() throws {
        let change = sub(encoded, "weatherChanges", "changes", "0")
        let high = change["highTemperature"] as! [String: Any]
        #expect(high.count == 1)
        #expect((high.values.first as? [String: Any])?.isEmpty == true)
        for direction in [WeatherChange.Direction.increase, .decrease, .steady] {
            let object = try JSONSerialization.jsonObject(with: try encode([direction])) as! [[String: Any]]
            #expect(Set(object[0].keys) == ["\(direction)"])
        }
        let comparisons = try fixtureFile(HistoricalComparisons.self, "historical-comparisons.json")
        let object = try jsonObject(comparisons)
        #expect(Set(object.keys) == ["comparisons", "metadata"])
        let first = (object["comparisons"] as! [[String: Any]])[0]
        #expect(Set(first.keys) == ["highTemperature"])
        let payload = first["highTemperature"] as! [String: Any]
        #expect(Set(payload.keys) == ["_0"])
        let trend = payload["_0"] as! [String: Any]
        #expect(Set(trend.keys) == ["baseline", "currentValue", "deviation"])
        let baseline = trend["baseline"] as! [String: Any]
        #expect(Set(baseline.keys) == ["kind", "value", "startDate"])
        #expect(Set((baseline["kind"] as! [String: Any]).keys) == ["mean"])
        #expect(Set((trend["deviation"] as! [String: Any]).keys) == ["higher"])
        guard case .highTemperature(let decodedTrend) = comparisons[0] else {
            Issue.record("first comparison is not highTemperature")
            return
        }
        #expect(decodedTrend.deviation == .higher)
        #expect(decodedTrend.baseline.kind == .mean)
        #expect(decodedTrend.currentValue.converted(to: .celsius).value == 4.1)
    }

    @Test("codable.md §4: statistics {baselineStartDate, days|hours|months, metadata}; summaries without baseline")
    func statisticsForms() throws {
        let cases: [(String, Set<String>, Set<String>, (Data) throws -> Any)] = [
            ("daily-temperature-statistics.json", ["baselineStartDate", "days", "metadata"],
             ["day", "averageLowTemperature", "averageHighTemperature"],
             { try decode(DailyWeatherStatistics<DayTemperatureStatistics>.self, $0) }),
            ("daily-precipitation-statistics.json", ["baselineStartDate", "days", "metadata"],
             ["day", "averagePrecipitationProbability", "averagePrecipitationAmount", "averageSnowfallAmount"],
             { try decode(DailyWeatherStatistics<DayPrecipitationStatistics>.self, $0) }),
            ("hourly-temperature-statistics.json", ["baselineStartDate", "hours", "metadata"], ["hour", "percentiles"],
             { try decode(HourlyWeatherStatistics<HourTemperatureStatistics>.self, $0) }),
            ("monthly-temperature-statistics.json", ["baselineStartDate", "months", "metadata"],
             ["month", "averageLowTemperature", "averageHighTemperature"],
             { try decode(MonthlyWeatherStatistics<MonthTemperatureStatistics>.self, $0) }),
            ("monthly-precipitation-statistics.json", ["baselineStartDate", "months", "metadata"],
             ["month", "averagePrecipitationProbability", "averagePrecipitationAmount", "averageSnowfallAmount"],
             { try decode(MonthlyWeatherStatistics<MonthPrecipitationStatistics>.self, $0) }),
            ("daily-temperature-summary.json", ["days", "metadata"], ["date", "lowTemperature", "highTemperature"],
             { try decode(DailyWeatherSummary<DayTemperatureSummary>.self, $0) }),
            ("daily-precipitation-summary.json", ["days", "metadata"], ["date", "precipitationAmount", "snowfallAmount"],
             { try decode(DailyWeatherSummary<DayPrecipitationSummary>.self, $0) }),
        ]
        let backend = try FixtureWeatherBackend.bundled(rebase: WeatherKit.FixtureWeatherBackend.Rebase.none)
        for (file, wrapperKeys, elementKeys, decodeFile) in cases {
            let raw = try Data(contentsOf: backend.directory.appendingPathComponent(file))
            // Normalize the fixture's ISO dates to the archive's default form.
            let value = try decodeFile(try reencode(raw, file: file))
            let object = try JSONSerialization.jsonObject(with: try encode(AnyEncodable(value))) as! [String: Any]
            #expect(Set(object.keys) == wrapperKeys, "\(file)")
            let elements = object.first { $0.value is [Any] }!.value as! [[String: Any]]
            #expect(Set(elements[0].keys) == elementKeys, "\(file)")
            if file.hasPrefix("hourly") {
                #expect(Set((elements[0]["percentiles"] as! [String: Any]).keys) == ["p10", "p50", "p90"])
            }
        }
    }

    @Test("C-CODABLE: decode → encode → decode is lossless; second encoding is identical")
    func roundTrip() throws {
        let weather = try fixtureWeather()
        let first = try encode(weather)
        let again = try decode(Weather.self, first)
        #expect(again == weather)
        #expect(try encode(again) == first)
        // Every bundled product file too.
        let comparisons = try fixtureFile(HistoricalComparisons.self, "historical-comparisons.json")
        #expect(try decode(HistoricalComparisons.self, try encode(comparisons)) == comparisons)
        let attribution = try fixtureFile(WeatherAttribution.self, "attribution.json")
        #expect(try decode(WeatherAttribution.self, try encode(attribution)) == attribution)
    }

    @Test("codable.md §1: non-public keys are decoded, kept and written back unchanged")
    func nonPublicKeysPreserved() throws {
        var object = encoded
        var current = object["currentWeather"] as! [String: Any]
        current["cloudCoverMid"] = 0.123
        current["apparentPrecipitationIntensity"] = ["category": "heavy", "value": 9.5]
        object["currentWeather"] = current
        var minute = object["minuteForecast"] as! [String: Any]
        minute["marineLocation"] = ["latitude": 1.25, "longitude": 2.5]
        var conditions = minute["minuteConditions"] as! [[String: Any]]
        var shift = conditions[0]["shift"] as! [String: Any]
        shift["kind"] = ["someFutureKind": [:] as [String: Any]]
        conditions[0]["shift"] = shift
        minute["minuteConditions"] = conditions
        object["minuteForecast"] = minute
        var alerts = object["weatherAlerts"] as! [[String: Any]]
        alerts[0]["importance"] = "high"
        object["weatherAlerts"] = alerts

        let weather = try decode(Weather.self, try data(object))
        #expect(weather.currentWeather.cloudCoverMid == 0.123)
        #expect(weather.currentWeather.apparentPrecipitationIntensity == PrecipitationIntensityValue(category: "heavy", value: 9.5))
        #expect(weather.minuteForecast?.marineLocation == MarineLocation(latitude: 1.25, longitude: 2.5))
        #expect(weather.weatherAlerts?.first?.importance == "high")

        let back = try jsonObject(weather)
        let backMinute = back["minuteForecast"] as! [String: Any]
        let backShift = sub(backMinute, "minuteConditions", "0", "shift")
        #expect(Set((backShift["kind"] as! [String: Any]).keys) == ["someFutureKind"])
        #expect(NSDictionary(dictionary: backMinute["marineLocation"] as! [String: Any]) == NSDictionary(dictionary: ["latitude": 1.25, "longitude": 2.5]))
        #expect(sub(back, "currentWeather")["cloudCoverMid"] as? Double == 0.123)
        #expect((back["weatherAlerts"] as! [[String: Any]])[0]["importance"] as? String == "high")
    }

    @Test("codable.md §5: other non-public products of Weather are accepted (Ycode keeps them)")
    func otherProducts() throws {
        var object = encoded
        object["airQuality"] = ["index": 42, "scale": "made-up"]
        object["news"] = [["title": "x"]]
        let weather = try decode(Weather.self, try data(object))
        #expect(weather.otherProducts.count == 2)
        let back = try jsonObject(weather)
        #expect(back["airQuality"] != nil)
        #expect(back["news"] != nil)
        // Without them nothing extra is written.
        #expect(Set(try jsonObject(try fixtureWeather()).keys) == [
            "currentWeather", "minuteForecast", "hourlyForecast", "dailyForecast", "weatherAlerts", "availability",
            "weatherChanges",
        ])
    }

    @Test("api.md §3.1: metadata.location is rebuilt from latitude/longitude")
    func metadataLocation() throws {
        let weather = try fixtureWeather()
        let location = weather.currentWeather.metadata.location
        #expect(location.coordinate.latitude == 41.5)
        #expect(location.coordinate.longitude == -81.5)
    }

    @Test("codable.md §4: the minute forecast's public summary comes from the non-public minuteSummary")
    func minuteSummary() throws {
        let weather = try fixtureWeather()
        #expect(weather.minuteForecast?.summary == "Light snow starting in 25 min.")
        var object = encoded
        var minute = object["minuteForecast"] as! [String: Any]
        minute["minuteSummary"] = nil
        object["minuteForecast"] = minute
        #expect(try decode(Weather.self, try data(object)).minuteForecast?.summary == "")
    }

    @Test("api.md §3.5: deprecated DayWeather amounts read their archive keys")
    @available(*, deprecated)
    func deprecatedAmounts() throws {
        let weather = try fixtureWeather()
        let snowDay = try #require(weather.dailyForecast.first { $0.condition == .snow })
        #expect(snowDay.snowfallAmount.converted(to: .millimeters).value == 40)
        #expect(snowDay.precipitationAmount == snowDay.precipitationAmountByType.precipitation)
        let rainDay = try #require(weather.dailyForecast.first { $0.condition == .rain })
        #expect(rainDay.rainfallAmount.converted(to: .millimeters).value == 3)
    }
}

/// Re-encodes a fixture file's dates in the archive's default form.
private func reencode(_ raw: Data, file: String) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: raw)
    return try JSONSerialization.data(withJSONObject: convertDates(object))
}

private func convertDates(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
        return dictionary.mapValues(convertDates)
    }
    if let array = value as? [Any] {
        return array.map(convertDates)
    }
    if let text = value as? String, let date = FixtureWeatherBackend.parseDate(text) {
        return date.timeIntervalSinceReferenceDate
    }
    return value
}

struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: any Encoder) throws {
        try (value as! any Encodable).encode(to: encoder)
    }
}
