// Mapping REST v1 objects to the model (rest-api.md §5–§6). Units: the REST
// API is metric (°C, km/h, degrees, mbar, m, mm, mm/h), and so are the
// model values built here (api.md §6).
//
// Fields the Swift model has but v1 does not document get Ycode values,
// listed in the package README: zero amounts and extremes, cloud cover by
// altitude zero, day parts synthesized from the day when absent, dew point
// from temperature and humidity (Magnus formula) when absent.
import Foundation

struct RESTMapper {
    let requestDate: Date
    let language: String
    let baseURL: URL

    // MARK: Products

    func result(for product: WeatherProduct, in response: REST.Weather) throws -> WeatherProductResult {
        switch product {
        case .currentWeather:
            guard let current = response.currentWeather else { throw missing("currentWeather") }
            let value = currentWeather(current)
            return WeatherProductResult(value: .currentWeather(value), expirationDate: current.metadata.expireTime)
        case .forecastHourly:
            guard let hourly = response.forecastHourly else { throw missing("forecastHourly") }
            return WeatherProductResult(value: .forecastHourly(hourlyForecast(hourly)), expirationDate: hourly.metadata.expireTime)
        case .forecastDaily:
            guard let daily = response.forecastDaily else { throw missing("forecastDaily") }
            return WeatherProductResult(value: .forecastDaily(dailyForecast(daily)), expirationDate: daily.metadata.expireTime)
        case .forecastNextHour:
            guard let next = response.forecastNextHour else {
                return WeatherProductResult(value: .forecastNextHour(nil), expirationDate: requestDate.addingTimeInterval(3600))
            }
            return WeatherProductResult(value: .forecastNextHour(minuteForecast(next)), expirationDate: next.metadata.expireTime)
        case .weatherAlerts:
            guard let collection = response.weatherAlerts else {
                return WeatherProductResult(value: .weatherAlerts(nil), expirationDate: requestDate.addingTimeInterval(3600))
            }
            return WeatherProductResult(value: .weatherAlerts(alerts(collection)), expirationDate: collection.metadata.expireTime)
        case .availability:
            func kind(_ metadata: REST.Metadata?) -> WeatherAvailability.AvailabilityKind {
                guard let metadata else { return .unsupported }
                return metadata.temporarilyUnavailable == true ? .temporarilyUnavailable : .available
            }
            let minuteMetadata = response.forecastNextHour?.metadata
            let alertMetadata = response.weatherAlerts?.metadata
            let availability = WeatherAvailability(
                minuteAvailability: kind(minuteMetadata), alertAvailability: kind(alertMetadata))
            let expirations = [minuteMetadata?.expireTime, alertMetadata?.expireTime].compactMap { $0 }
            return WeatherProductResult(
                value: .availability(availability),
                expirationDate: expirations.min() ?? requestDate.addingTimeInterval(3600))
        default:
            throw WeatherBackendError.unsupported(product.rawValue)
        }
    }

    private func missing(_ name: String) -> WeatherBackendError {
        .malformedResponse("response has no \(name)")
    }

    // MARK: Values

    func metadata(_ metadata: REST.Metadata) -> WeatherMetadata {
        WeatherMetadata(
            date: metadata.readTime, expirationDate: metadata.expireTime, latitude: metadata.latitude,
            longitude: metadata.longitude)
    }

    func currentWeather(_ c: REST.CurrentWeather) -> CurrentWeather {
        let condition = Self.condition(c.conditionCode)
        let daylight = c.daylight ?? true
        let cloudCover = c.cloudCover ?? 0
        return CurrentWeather(
            date: c.asOf, cloudCover: cloudCover, cloudCoverByAltitude: CloudCoverByAltitude(low: 0, medium: 0, high: 0),
            cloudCoverLow: 0, cloudCoverMid: 0, cloudCoverHigh: 0, condition: condition,
            symbolName: Self.symbolName(condition, daylight: daylight), dewPoint: Self.celsius(c.temperatureDewPoint),
            humidity: c.humidity, precipitationIntensity: Self.mmPerHour(c.precipitationIntensity),
            apparentPrecipitationIntensity: Self.intensity(c.precipitationIntensity), pressure: Self.mbar(c.pressure),
            pressureTrend: Self.pressureTrend(c.pressureTrend), isDaylight: daylight,
            temperature: Self.celsius(c.temperature), apparentTemperature: Self.celsius(c.temperatureApparent),
            uvIndex: UVIndex(value: c.uvIndex), visibility: Self.meters(c.visibility),
            wind: Self.wind(direction: c.windDirection, speed: c.windSpeed, gust: c.windGust), metadata: metadata(c.metadata),
            highTemperature: nil, lowTemperature: nil, rainfallAmount: .zero, snowfallAmount: .zero,
            pastHourPrecipitationAmountByType: .zero, pastSixHoursPrecipitationAmountByType: .zero,
            pastTwentyFourHoursPrecipitationAmountByType: .zero, nextHourPrecipitationAmountByType: .zero,
            nextSixHoursPrecipitationAmountByType: .zero, nextTwentyFourHoursPrecipitationAmountByType: .zero)
    }

    func hourlyForecast(_ forecast: REST.HourlyForecast) -> Forecast<HourWeather> {
        Forecast(forecast: forecast.hours.map(hour), metadata: metadata(forecast.metadata))
    }

    func hour(_ h: REST.HourWeatherConditions) -> HourWeather {
        let condition = Self.condition(h.conditionCode)
        let daylight = h.daylight ?? false
        let precipitation = Self.precipitation(h.precipitationType)
        return HourWeather(
            date: h.forecastStart, cloudCover: h.cloudCover,
            cloudCoverByAltitude: CloudCoverByAltitude(low: 0, medium: 0, high: 0), cloudCoverLow: 0, cloudCoverMid: 0,
            cloudCoverHigh: 0, condition: condition, symbolName: Self.symbolName(condition, daylight: daylight),
            dewPoint: Self.celsius(h.temperatureDewPoint ?? Self.dewPoint(temperature: h.temperature, humidity: h.humidity)),
            humidity: h.humidity, isDaylight: daylight, precipitation: precipitation,
            precipitationAmount: Self.mm(h.precipitationAmount ?? 0), precipitationChance: h.precipitationChance,
            snowfallAmount: Self.mm(h.snowfallIntensity ?? 0), pressure: Self.mbar(h.pressure),
            pressureTrend: h.pressureTrend.map(Self.pressureTrend) ?? .steady, temperature: Self.celsius(h.temperature),
            apparentTemperature: Self.celsius(h.temperatureApparent), uvIndex: UVIndex(value: h.uvIndex),
            visibility: Self.meters(h.visibility),
            wind: Self.wind(direction: h.windDirection, speed: h.windSpeed, gust: h.windGust),
            apparentPrecipitationIntensity: Self.intensity(h.precipitationAmount ?? 0))
    }

    func dailyForecast(_ forecast: REST.DailyForecast) -> Forecast<DayWeather> {
        Forecast(forecast: forecast.days.map(day), metadata: metadata(forecast.metadata))
    }

    func day(_ d: REST.DayWeatherConditions) -> DayWeather {
        let condition = Self.condition(d.conditionCode)
        let precipitation = Self.precipitation(d.precipitationType)
        let byType = Self.amountByType(precipitation, total: d.precipitationAmount, snowfall: d.snowfallAmount)
        let parts = [d.daytimeForecast, d.overnightForecast].compactMap { $0 }
        let humidities = parts.map(\.humidity)
        let winds = parts.map(\.windSpeed)
        let daytime = dayPart(
            d.daytimeForecast, day: d, daylight: true,
            start: d.forecastStart.addingTimeInterval(7 * 3600), end: d.forecastStart.addingTimeInterval(19 * 3600))
        let overnight = dayPart(
            d.overnightForecast, day: d, daylight: false,
            start: d.forecastStart.addingTimeInterval(19 * 3600), end: d.forecastStart.addingTimeInterval(31 * 3600))
        let windSource = d.daytimeForecast ?? d.overnightForecast
        return DayWeather(
            date: d.forecastStart, condition: condition, symbolName: Self.symbolName(condition, daylight: true),
            highTemperature: Self.celsius(d.temperatureMax), lowTemperature: Self.celsius(d.temperatureMin),
            highTemperatureTime: nil, lowTemperatureTime: nil,
            maximumHumidity: humidities.max() ?? 0, minimumHumidity: humidities.min() ?? 0,
            humidityMax: humidities.max() ?? 0, humidityMin: humidities.min() ?? 0,
            precipitation: precipitation, precipitationChance: d.precipitationChance, precipitationAmountByType: byType,
            storedRainfallAmount: byType.rainfall, storedSnowfallAmount: Self.mm(d.snowfallAmount),
            sun: SunEvents(
                astronomicalDawn: d.sunriseAstronomical, nauticalDawn: d.sunriseNautical, civilDawn: d.sunriseCivil,
                sunrise: d.sunrise, solarNoon: d.solarNoon, sunset: d.sunset, civilDusk: d.sunsetCivil,
                nauticalDusk: d.sunsetNautical, astronomicalDusk: d.sunsetAstronomical, solarMidnight: d.solarMidnight),
            moon: MoonEvents(phase: Self.moonPhase(d.moonPhase), moonrise: d.moonrise, moonset: d.moonset),
            uvIndex: UVIndex(value: d.maxUvIndex),
            wind: Self.wind(direction: windSource?.windDirection, speed: windSource?.windSpeed ?? 0, gust: nil),
            maximumVisibility: 0, minimumVisibility: 0, visibilityMax: 0, visibilityMin: 0,
            highWindSpeed: winds.max().map(Self.kmh), windSpeedAvg: Self.kmh(winds.isEmpty ? 0 : winds.reduce(0, +) / Double(winds.count)),
            windSpeedMax: Self.kmh(winds.max() ?? 0), windGustSpeedMax: Self.kmh(winds.max() ?? 0),
            daytimeForecast: daytime, overnightForecast: overnight, restOfDayForecast: nil)
    }

    /// A day part from REST, or synthesized from the day when absent.
    func dayPart(_ p: REST.DayPartForecast?, day d: REST.DayWeatherConditions, daylight: Bool, start: Date, end: Date)
        -> DayPartForecast
    {
        let conditionCode = p?.conditionCode ?? d.conditionCode
        let type = Self.precipitation(p?.precipitationType ?? d.precipitationType)
        let total = p?.precipitationAmount ?? 0
        let snowfall = p?.snowfallAmount ?? 0
        let hours = max(1, ((p?.forecastEnd ?? end).timeIntervalSince(p?.forecastStart ?? start)) / 3600)
        let wind = Self.wind(direction: p?.windDirection, speed: p?.windSpeed ?? 0, gust: nil)
        return DayPartForecast(
            forecastStart: p?.forecastStart ?? start, forecastEnd: p?.forecastEnd ?? end, cloudCover: p?.cloudCover ?? 0,
            cloudCoverByAltitude: CloudCoverByAltitude(low: 0, medium: 0, high: 0),
            condition: Self.condition(conditionCode), highTemperature: Self.celsius(d.temperatureMax),
            lowTemperature: Self.celsius(d.temperatureMin), humidity: p?.humidity ?? 0,
            maximumHumidity: p?.humidity ?? 0, minimumHumidity: p?.humidity ?? 0, isDaylight: daylight,
            maximumVisibility: Self.meters(0), minimumVisibility: Self.meters(0),
            maximumUVIndex: UVIndex(value: daylight ? d.maxUvIndex : 0), minimumUVIndex: UVIndex(value: 0),
            precipitation: type, precipitationAmountByType: Self.amountByType(type, total: total, snowfall: snowfall),
            precipitationChance: p?.precipitationChance ?? 0,
            precipitationIntensityMax: Self.intensity(total / hours),
            perceivedPrecipitationIntensityMax: Self.intensity(total / hours), wind: wind,
            highWindSpeed: Self.kmh(p?.windSpeed ?? 0))
    }

    func minuteForecast(_ next: REST.NextHourForecast) -> Forecast<MinuteWeather> {
        func kind(at date: Date) -> Precipitation? {
            next.summary.last { $0.startTime <= date && ($0.endTime.map { date < $0 } ?? true) }
                .map { Self.precipitation($0.condition) }
        }
        let minutes = next.minutes.map { m -> MinuteWeather in
            let precipitation = kind(at: m.startTime) ?? (m.precipitationIntensity > 0 ? .rain : Precipitation.none)
            return MinuteWeather(
                date: m.startTime, precipitation: m.precipitationIntensity > 0 ? precipitation : Precipitation.none,
                precipitationChance: m.precipitationChance, precipitationIntensity: Self.mmPerHour(m.precipitationIntensity),
                apparentPrecipitationIntensity: Self.intensity(m.precipitationIntensity))
        }
        let summaries = next.summary.map { s in
            MinuteSummary(
                date: s.startTime, expirationDate: s.endTime, precipitation: Self.precipitation(s.condition),
                precipitationChance: s.precipitationChance, precipitationKind: .string(s.condition),
                apparentPrecipitationIntensity: Self.intensity(s.precipitationIntensity))
        }
        return Forecast(
            forecast: minutes, metadata: metadata(next.metadata),
            minuteSummary: Self.summarySentence(next.summary, from: next.forecastStart ?? next.minutes.first?.startTime),
            minuteSummaries: summaries)
    }

    func alerts(_ collection: REST.WeatherAlertCollection) -> [WeatherAlert] {
        let shared = metadata(collection.metadata)
        return collection.alerts.map { a in
            let details = a.detailsUrl.flatMap { URL(string: $0) }
                ?? collection.detailsUrl.flatMap { URL(string: $0) }
                ?? baseURL.appendingPathComponent("api/v1/weatherAlert").appendingPathComponent(language)
                    .appendingPathComponent(a.id.uuidString)
            return WeatherAlert(
                detailsURL: details, source: a.source, summary: a.description, region: a.areaName,
                severity: WeatherSeverity(rawValue: a.severity) ?? .unknown, metadata: shared, id: a.id,
                importance: "normal", alertDescription: a.description, details: nil, date: a.effectiveTime,
                issuedDate: a.issuedTime, onsetTime: a.eventOnsetTime, endDate: a.eventEndTime,
                expirationDate: a.expireTime)
        }
    }

    // MARK: Enumerations (rest-api.md §6)

    /// `conditionCode` is the case name in UpperCamelCase. Unknown codes fall
    /// back by keyword (Ycode choice).
    static func condition(_ code: String) -> WeatherCondition {
        guard let first = code.first else { return .cloudy }
        let lowerCamel = first.lowercased() + code.dropFirst()
        if let condition = WeatherCondition(rawValue: lowerCamel) { return condition }
        let lowered = code.lowercased()
        if lowered.contains("thunder") { return .thunderstorms }
        if lowered.contains("snow") { return .snow }
        if lowered.contains("rain") || lowered.contains("shower") { return .rain }
        if lowered.contains("fog") { return .foggy }
        return .cloudy
    }

    /// `clear` → `none`, unspecified `precipitation` → `rain`.
    static func precipitation(_ type: String) -> Precipitation {
        switch type {
        case "clear": return .none
        case "precipitation": return .rain
        default: return Precipitation(rawValue: type) ?? .rain
        }
    }

    /// `thirdQuarter` → `lastQuarter`.
    static func moonPhase(_ phase: String) -> MoonPhase {
        phase == "thirdQuarter" ? .lastQuarter : (MoonPhase(rawValue: phase) ?? .new)
    }

    static func pressureTrend(_ trend: String) -> PressureTrend {
        PressureTrend(rawValue: trend) ?? .steady
    }

    // MARK: Units and derived values

    static func celsius(_ value: Double) -> Measurement<UnitTemperature> { Measurement(value: value, unit: .celsius) }
    static func kmh(_ value: Double) -> Measurement<UnitSpeed> { Measurement(value: value, unit: .kilometersPerHour) }
    static func mbar(_ value: Double) -> Measurement<UnitPressure> { Measurement(value: value, unit: .millibars) }
    static func meters(_ value: Double) -> Measurement<UnitLength> { Measurement(value: value, unit: .meters) }
    static func mm(_ value: Double) -> Measurement<UnitLength> { Measurement(value: value, unit: .millimeters) }
    static func mmPerHour(_ value: Double) -> Measurement<UnitSpeed> {
        Measurement(value: value, unit: WeatherUnits.millimetersPerHour)
    }

    static func wind(direction: Double?, speed: Double, gust: Double?) -> Wind {
        let degrees = direction ?? 0
        return Wind(
            compassDirection: .from(degrees: degrees), direction: Measurement(value: degrees, unit: .degrees),
            speed: kmh(speed), gust: gust.map(kmh))
    }

    /// Ycode's intensity bands (mm/h): 0 none, < 2.5 light, < 7.6 moderate, else heavy.
    static func intensity(_ millimetersPerHour: Double) -> PrecipitationIntensityValue {
        let category: String
        switch millimetersPerHour {
        case ..<0.000_001: category = "none"
        case ..<2.5: category = "light"
        case ..<7.6: category = "moderate"
        default: category = "heavy"
        }
        return PrecipitationIntensityValue(category: category, value: millimetersPerHour)
    }

    /// Dew point from temperature (°C) and relative humidity (0…1), Magnus formula.
    static func dewPoint(temperature: Double, humidity: Double) -> Double {
        let b = 17.625, c = 243.04
        let gamma = log(max(humidity, 0.01)) + b * temperature / (c + temperature)
        return c * gamma / (b - gamma)
    }

    static func amountByType(_ type: Precipitation, total: Double, snowfall: Double) -> PrecipitationAmountByType {
        let zero = mm(0)
        return PrecipitationAmountByType(
            hail: type == .hail ? mm(total) : zero, mixed: type == .mixed ? mm(total) : zero,
            rainfall: type == .rain ? mm(total) : zero, sleet: type == .sleet ? mm(total) : zero,
            precipitation: mm(total),
            snowfallAmount: SnowfallAmount(
                amount: mm(snowfall), maximum: mm(snowfall), minimum: mm(snowfall),
                amountLiquidEquivalent: type == .snow ? mm(total) : zero,
                maximumLiquidEquivalent: type == .snow ? mm(total) : zero,
                minimumLiquidEquivalent: type == .snow ? mm(total) : zero))
    }

    /// Ycode's English sentence for the next hour (the public `summary`).
    static func summarySentence(_ periods: [REST.ForecastPeriodSummary], from start: Date?) -> String {
        guard let first = periods.first else { return "" }
        let firstKind = precipitation(first.condition)
        guard periods.count > 1, let start else {
            return firstKind == .none ? "No precipitation for the hour." : "\(label(firstKind)) for the hour."
        }
        let change = periods[1]
        let minutes = max(1, Int((change.startTime.timeIntervalSince(start) / 60).rounded()))
        let nextKind = precipitation(change.condition)
        if firstKind == .none {
            return "\(label(nextKind)) starting in \(minutes) min."
        }
        if nextKind == .none {
            return "\(label(firstKind)) stopping in \(minutes) min."
        }
        return "\(label(firstKind)) changing to \(nextKind.description) in \(minutes) min."
    }

    private static func label(_ kind: Precipitation) -> String {
        kind == .none ? "No precipitation" : CaseName.capitalized(kind.description)
    }

    /// Ycode's condition × daylight → SF Symbols name table (design.md §5).
    static func symbolName(_ condition: WeatherCondition, daylight: Bool) -> String {
        switch condition {
        case .clear, .hot: return daylight ? "sun.max" : "moon.stars"
        case .mostlyClear: return daylight ? "sun.min" : "moon"
        case .partlyCloudy: return daylight ? "cloud.sun" : "cloud.moon"
        case .mostlyCloudy, .cloudy: return "cloud"
        case .foggy: return "cloud.fog"
        case .haze: return daylight ? "sun.haze" : "moon.haze"
        case .smoky: return "smoke"
        case .blowingDust: return "sun.dust"
        case .breezy, .windy: return "wind"
        case .drizzle: return "cloud.drizzle"
        case .rain: return "cloud.rain"
        case .heavyRain: return "cloud.heavyrain"
        case .sunShowers: return daylight ? "cloud.sun.rain" : "cloud.moon.rain"
        case .freezingDrizzle, .freezingRain, .sleet, .wintryMix: return "cloud.sleet"
        case .hail: return "cloud.hail"
        case .flurries, .snow, .heavySnow, .sunFlurries: return "cloud.snow"
        case .blizzard, .blowingSnow: return "wind.snow"
        case .frigid: return "thermometer.snowflake"
        case .isolatedThunderstorms, .scatteredThunderstorms:
            return daylight ? "cloud.sun.bolt" : "cloud.moon.bolt"
        case .thunderstorms, .strongStorms: return "cloud.bolt.rain"
        case .tropicalStorm: return "tropicalstorm"
        case .hurricane: return "hurricane"
        }
    }
}
