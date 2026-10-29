// C-API (plan.md §2): every public name of api.md, with its type, used from
// client code (plain `import WeatherKit`, no testable access). Compiling this
// file is most of the test; running it checks values from the fixtures.
import CoreLocation
import Foundation
import Testing
import WeatherKit

@Suite("C-API: public interface (api.md)")
struct APITests {
    @Test("api.md §3: every model member has the documented type")
    func modelMembers() {
        // §3.1 containers
        let _: KeyPath<Weather, CurrentWeather> = \.currentWeather
        let _: KeyPath<Weather, Forecast<MinuteWeather>?> = \.minuteForecast
        let _: KeyPath<Weather, Forecast<HourWeather>> = \.hourlyForecast
        let _: KeyPath<Weather, Forecast<DayWeather>> = \.dailyForecast
        let _: KeyPath<Weather, [WeatherAlert]?> = \.weatherAlerts
        let _: KeyPath<Weather, WeatherAvailability> = \.availability
        let _: KeyPath<Forecast<HourWeather>, [HourWeather]> = \.forecast
        let _: KeyPath<Forecast<DayWeather>, WeatherMetadata> = \.metadata
        let _: KeyPath<Forecast<MinuteWeather>, String> = \.summary
        let _: KeyPath<WeatherMetadata, Date> = \.date
        let _: KeyPath<WeatherMetadata, Date> = \.expirationDate
        let _: KeyPath<WeatherMetadata, CLLocation> = \.location
        let _: KeyPath<WeatherAvailability, WeatherAvailability.AvailabilityKind> = \.minuteAvailability
        let _: KeyPath<WeatherAvailability, WeatherAvailability.AvailabilityKind> = \.alertAvailability
        // §3.2 CurrentWeather
        let _: KeyPath<CurrentWeather, Date> = \.date
        let _: KeyPath<CurrentWeather, Double> = \.cloudCover
        let _: KeyPath<CurrentWeather, CloudCoverByAltitude> = \.cloudCoverByAltitude
        let _: KeyPath<CurrentWeather, WeatherCondition> = \.condition
        let _: KeyPath<CurrentWeather, String> = \.symbolName
        let _: KeyPath<CurrentWeather, Measurement<UnitTemperature>> = \.dewPoint
        let _: KeyPath<CurrentWeather, Double> = \.humidity
        let _: KeyPath<CurrentWeather, Measurement<UnitSpeed>> = \.precipitationIntensity
        let _: KeyPath<CurrentWeather, Measurement<UnitPressure>> = \.pressure
        let _: KeyPath<CurrentWeather, PressureTrend> = \.pressureTrend
        let _: KeyPath<CurrentWeather, Bool> = \.isDaylight
        let _: KeyPath<CurrentWeather, Measurement<UnitTemperature>> = \.temperature
        let _: KeyPath<CurrentWeather, Measurement<UnitTemperature>> = \.apparentTemperature
        let _: KeyPath<CurrentWeather, UVIndex> = \.uvIndex
        let _: KeyPath<CurrentWeather, Measurement<UnitLength>> = \.visibility
        let _: KeyPath<CurrentWeather, Wind> = \.wind
        let _: KeyPath<CurrentWeather, WeatherMetadata> = \.metadata
        // §3.3 MinuteWeather
        let _: KeyPath<MinuteWeather, Date> = \.date
        let _: KeyPath<MinuteWeather, Precipitation> = \.precipitation
        let _: KeyPath<MinuteWeather, Double> = \.precipitationChance
        let _: KeyPath<MinuteWeather, Measurement<UnitSpeed>> = \.precipitationIntensity
        // §3.4 HourWeather
        let _: KeyPath<HourWeather, Date> = \.date
        let _: KeyPath<HourWeather, Double> = \.cloudCover
        let _: KeyPath<HourWeather, CloudCoverByAltitude> = \.cloudCoverByAltitude
        let _: KeyPath<HourWeather, WeatherCondition> = \.condition
        let _: KeyPath<HourWeather, String> = \.symbolName
        let _: KeyPath<HourWeather, Measurement<UnitTemperature>> = \.dewPoint
        let _: KeyPath<HourWeather, Double> = \.humidity
        let _: KeyPath<HourWeather, Bool> = \.isDaylight
        let _: KeyPath<HourWeather, Precipitation> = \.precipitation
        let _: KeyPath<HourWeather, Double> = \.precipitationChance
        let _: KeyPath<HourWeather, Measurement<UnitLength>> = \.precipitationAmount
        let _: KeyPath<HourWeather, Measurement<UnitLength>> = \.snowfallAmount
        let _: KeyPath<HourWeather, Measurement<UnitPressure>> = \.pressure
        let _: KeyPath<HourWeather, PressureTrend> = \.pressureTrend
        let _: KeyPath<HourWeather, Measurement<UnitTemperature>> = \.temperature
        let _: KeyPath<HourWeather, Measurement<UnitTemperature>> = \.apparentTemperature
        let _: KeyPath<HourWeather, UVIndex> = \.uvIndex
        let _: KeyPath<HourWeather, Measurement<UnitLength>> = \.visibility
        let _: KeyPath<HourWeather, Wind> = \.wind
        // §3.5 DayWeather
        let _: KeyPath<DayWeather, Date> = \.date
        let _: KeyPath<DayWeather, WeatherCondition> = \.condition
        let _: KeyPath<DayWeather, String> = \.symbolName
        let _: KeyPath<DayWeather, Measurement<UnitTemperature>> = \.highTemperature
        let _: KeyPath<DayWeather, Measurement<UnitTemperature>> = \.lowTemperature
        let _: KeyPath<DayWeather, Date?> = \.highTemperatureTime
        let _: KeyPath<DayWeather, Date?> = \.lowTemperatureTime
        let _: KeyPath<DayWeather, Double> = \.maximumHumidity
        let _: KeyPath<DayWeather, Double> = \.minimumHumidity
        let _: KeyPath<DayWeather, Precipitation> = \.precipitation
        let _: KeyPath<DayWeather, Double> = \.precipitationChance
        let _: KeyPath<DayWeather, PrecipitationAmountByType> = \.precipitationAmountByType
        let _: KeyPath<DayWeather, SunEvents> = \.sun
        let _: KeyPath<DayWeather, MoonEvents> = \.moon
        let _: KeyPath<DayWeather, UVIndex> = \.uvIndex
        let _: KeyPath<DayWeather, Wind> = \.wind
        let _: KeyPath<DayWeather, Double> = \.maximumVisibility
        let _: KeyPath<DayWeather, Double> = \.minimumVisibility
        let _: KeyPath<DayWeather, Measurement<UnitSpeed>?> = \.highWindSpeed
        let _: KeyPath<DayWeather, DayPartForecast> = \.daytimeForecast
        let _: KeyPath<DayWeather, DayPartForecast> = \.overnightForecast
        let _: KeyPath<DayWeather, DayPartForecast?> = \.restOfDayForecast
        // §3.6 DayPartForecast
        let _: KeyPath<DayPartForecast, Double> = \.cloudCover
        let _: KeyPath<DayPartForecast, CloudCoverByAltitude> = \.cloudCoverByAltitude
        let _: KeyPath<DayPartForecast, WeatherCondition> = \.condition
        let _: KeyPath<DayPartForecast, Measurement<UnitTemperature>> = \.highTemperature
        let _: KeyPath<DayPartForecast, Measurement<UnitTemperature>> = \.lowTemperature
        let _: KeyPath<DayPartForecast, Precipitation> = \.precipitation
        let _: KeyPath<DayPartForecast, PrecipitationAmountByType> = \.precipitationAmountByType
        let _: KeyPath<DayPartForecast, Double> = \.precipitationChance
        let _: KeyPath<DayPartForecast, Double> = \.maximumHumidity
        let _: KeyPath<DayPartForecast, Double> = \.minimumHumidity
        let _: KeyPath<DayPartForecast, Measurement<UnitLength>> = \.maximumVisibility
        let _: KeyPath<DayPartForecast, Measurement<UnitLength>> = \.minimumVisibility
        let _: KeyPath<DayPartForecast, Wind> = \.wind
        let _: KeyPath<DayPartForecast, Measurement<UnitSpeed>> = \.highWindSpeed
        // §3.7 amounts
        let _: KeyPath<PrecipitationAmountByType, Measurement<UnitLength>> = \.hail
        let _: KeyPath<PrecipitationAmountByType, Measurement<UnitLength>> = \.mixed
        let _: KeyPath<PrecipitationAmountByType, Measurement<UnitLength>> = \.rainfall
        let _: KeyPath<PrecipitationAmountByType, Measurement<UnitLength>> = \.sleet
        let _: KeyPath<PrecipitationAmountByType, Measurement<UnitLength>> = \.precipitation
        let _: KeyPath<PrecipitationAmountByType, SnowfallAmount> = \.snowfallAmount
        let _: KeyPath<SnowfallAmount, Measurement<UnitLength>> = \.amount
        let _: KeyPath<SnowfallAmount, Measurement<UnitLength>> = \.maximum
        let _: KeyPath<SnowfallAmount, Measurement<UnitLength>> = \.minimum
        let _: KeyPath<SnowfallAmount, Measurement<UnitLength>> = \.amountLiquidEquivalent
        let _: KeyPath<SnowfallAmount, Measurement<UnitLength>> = \.maximumLiquidEquivalent
        let _: KeyPath<SnowfallAmount, Measurement<UnitLength>> = \.minimumLiquidEquivalent
        let _: KeyPath<CloudCoverByAltitude, Double> = \.low
        let _: KeyPath<CloudCoverByAltitude, Double> = \.medium
        let _: KeyPath<CloudCoverByAltitude, Double> = \.high
        // §3.8 supporting values
        let _: KeyPath<Wind, Wind.CompassDirection> = \.compassDirection
        let _: KeyPath<Wind, Measurement<UnitAngle>> = \.direction
        let _: KeyPath<Wind, Measurement<UnitSpeed>> = \.speed
        let _: KeyPath<Wind, Measurement<UnitSpeed>?> = \.gust
        let _: KeyPath<Wind.CompassDirection, String> = \.abbreviation
        let _: KeyPath<Wind.CompassDirection, String> = \.accessibilityDescription
        let _: KeyPath<UVIndex, Int> = \.value
        let _: KeyPath<UVIndex, UVIndex.ExposureCategory> = \.category
        let _: KeyPath<UVIndex.ExposureCategory, ClosedRange<Int>> = \.rangeValue
        let _: [KeyPath<SunEvents, Date?>] = [
            \.astronomicalDawn, \.nauticalDawn, \.civilDawn, \.sunrise, \.solarNoon, \.sunset, \.civilDusk,
            \.nauticalDusk, \.astronomicalDusk, \.solarMidnight,
        ]
        let _: KeyPath<MoonEvents, MoonPhase> = \.phase
        let _: KeyPath<MoonEvents, Date?> = \.moonrise
        let _: KeyPath<MoonEvents, Date?> = \.moonset
        let _: KeyPath<MoonPhase, String> = \.symbolName
        let _: KeyPath<MoonPhase, String> = \.accessibilityDescription
        let _: KeyPath<WeatherCondition, String> = \.accessibilityDescription
        let _: KeyPath<Precipitation, String> = \.accessibilityDescription
        let _: KeyPath<PressureTrend, String> = \.accessibilityDescription
        let _: KeyPath<WeatherSeverity, String> = \.accessibilityDescription
        // §3.9 WeatherAlert
        let _: KeyPath<WeatherAlert, URL> = \.detailsURL
        let _: KeyPath<WeatherAlert, String> = \.source
        let _: KeyPath<WeatherAlert, String> = \.summary
        let _: KeyPath<WeatherAlert, String?> = \.region
        let _: KeyPath<WeatherAlert, WeatherSeverity> = \.severity
        let _: KeyPath<WeatherAlert, WeatherMetadata> = \.metadata
        // §3.10 changes and comparisons
        let _: KeyPath<WeatherChanges, [WeatherChange]> = \.changes
        let _: KeyPath<WeatherChanges, WeatherMetadata> = \.metadata
        let _: KeyPath<WeatherChange, Date> = \.date
        let _: KeyPath<WeatherChange, WeatherChange.Direction> = \.highTemperature
        let _: KeyPath<WeatherChange, WeatherChange.Direction> = \.lowTemperature
        let _: KeyPath<WeatherChange, WeatherChange.Direction> = \.dayPrecipitationAmount
        let _: KeyPath<WeatherChange, WeatherChange.Direction> = \.nightPrecipitationAmount
        let _: KeyPath<HistoricalComparisons, [HistoricalComparison]> = \.comparisons
        let _: KeyPath<HistoricalComparisons, WeatherMetadata> = \.metadata
        let _: (Trend<UnitTemperature>) -> HistoricalComparison = HistoricalComparison.highTemperature
        let _: (Trend<UnitTemperature>) -> HistoricalComparison = HistoricalComparison.lowTemperature
        let _: (Trend<UnitLength>) -> HistoricalComparison = HistoricalComparison.precipitationAmount
        let _: (Trend<UnitLength>) -> HistoricalComparison = HistoricalComparison.snowfallAmount
        let _: KeyPath<Trend<UnitLength>, TrendBaseline<UnitLength>> = \.baseline
        let _: KeyPath<Trend<UnitLength>, Measurement<UnitLength>> = \.currentValue
        let _: KeyPath<Trend<UnitLength>, Deviation> = \.deviation
        let _: KeyPath<TrendBaseline<UnitLength>, TrendBaseline<UnitLength>.Kind> = \.kind
        let _: KeyPath<TrendBaseline<UnitLength>, Measurement<UnitLength>> = \.value
        let _: KeyPath<TrendBaseline<UnitLength>, Date> = \.startDate
        // §3.11 statistics and summaries
        let _: KeyPath<DailyWeatherStatistics<DayTemperatureStatistics>, [DayTemperatureStatistics]> = \.days
        let _: KeyPath<DailyWeatherStatistics<DayTemperatureStatistics>, Date> = \.baselineStartDate
        let _: KeyPath<DailyWeatherStatistics<DayTemperatureStatistics>, WeatherMetadata> = \.metadata
        let _: KeyPath<HourlyWeatherStatistics<HourTemperatureStatistics>, [HourTemperatureStatistics]> = \.hours
        let _: KeyPath<HourlyWeatherStatistics<HourTemperatureStatistics>, Date> = \.baselineStartDate
        let _: KeyPath<MonthlyWeatherStatistics<MonthTemperatureStatistics>, [MonthTemperatureStatistics]> = \.months
        let _: KeyPath<MonthlyWeatherStatistics<MonthTemperatureStatistics>, Date> = \.baselineStartDate
        let _: KeyPath<DailyWeatherSummary<DayTemperatureSummary>, [DayTemperatureSummary]> = \.days
        let _: KeyPath<DailyWeatherSummary<DayTemperatureSummary>, WeatherMetadata> = \.metadata
        let _: KeyPath<DayTemperatureStatistics, Int> = \.day
        let _: KeyPath<DayTemperatureStatistics, Measurement<UnitTemperature>> = \.averageLowTemperature
        let _: KeyPath<DayTemperatureStatistics, Measurement<UnitTemperature>> = \.averageHighTemperature
        let _: KeyPath<DayPrecipitationStatistics, Int> = \.day
        let _: KeyPath<DayPrecipitationStatistics, Double> = \.averagePrecipitationProbability
        let _: KeyPath<DayPrecipitationStatistics, Measurement<UnitLength>> = \.averagePrecipitationAmount
        let _: KeyPath<DayPrecipitationStatistics, Measurement<UnitLength>> = \.averageSnowfallAmount
        let _: KeyPath<HourTemperatureStatistics, Int> = \.hour
        let _: KeyPath<HourTemperatureStatistics, Percentiles<UnitTemperature>> = \.percentiles
        let _: KeyPath<Percentiles<UnitTemperature>, Measurement<UnitTemperature>> = \.p10
        let _: KeyPath<Percentiles<UnitTemperature>, Measurement<UnitTemperature>> = \.p50
        let _: KeyPath<Percentiles<UnitTemperature>, Measurement<UnitTemperature>> = \.p90
        let _: KeyPath<MonthTemperatureStatistics, Int> = \.month
        let _: KeyPath<MonthTemperatureStatistics, Measurement<UnitTemperature>> = \.averageLowTemperature
        let _: KeyPath<MonthTemperatureStatistics, Measurement<UnitTemperature>> = \.averageHighTemperature
        let _: KeyPath<MonthPrecipitationStatistics, Int> = \.month
        let _: KeyPath<MonthPrecipitationStatistics, Double> = \.averagePrecipitationProbability
        let _: KeyPath<MonthPrecipitationStatistics, Measurement<UnitLength>> = \.averagePrecipitationAmount
        let _: KeyPath<MonthPrecipitationStatistics, Measurement<UnitLength>> = \.averageSnowfallAmount
        let _: KeyPath<DayTemperatureSummary, Date> = \.date
        let _: KeyPath<DayTemperatureSummary, Measurement<UnitTemperature>> = \.lowTemperature
        let _: KeyPath<DayTemperatureSummary, Measurement<UnitTemperature>> = \.highTemperature
        let _: KeyPath<DayPrecipitationSummary, Date> = \.date
        let _: KeyPath<DayPrecipitationSummary, Measurement<UnitLength>> = \.precipitationAmount
        let _: KeyPath<DayPrecipitationSummary, Measurement<UnitLength>> = \.snowfallAmount
        // §4 attribution
        let _: KeyPath<WeatherAttribution, String> = \.serviceName
        let _: KeyPath<WeatherAttribution, URL> = \.legalPageURL
        let _: KeyPath<WeatherAttribution, URL> = \.squareMarkURL
        let _: KeyPath<WeatherAttribution, URL> = \.combinedMarkLightURL
        let _: KeyPath<WeatherAttribution, URL> = \.combinedMarkDarkURL
        let _: KeyPath<WeatherAttribution, String> = \.legalAttributionText
    }

    @Test("api.md general rules: model types are Codable, Equatable, Sendable; collections random-access")
    func conformances() {
        func model<T: Codable & Equatable & Sendable>(_: T.Type) {}
        func collection<C: RandomAccessCollection>(_: C.Type) where C.Index == Int {}
        model(Weather.self); model(CurrentWeather.self); model(MinuteWeather.self); model(HourWeather.self)
        model(DayWeather.self); model(DayPartForecast.self); model(WeatherAlert.self); model(WeatherMetadata.self)
        model(WeatherAvailability.self); model(WeatherAttribution.self); model(Wind.self); model(UVIndex.self)
        model(SunEvents.self); model(MoonEvents.self); model(PrecipitationAmountByType.self); model(SnowfallAmount.self)
        model(CloudCoverByAltitude.self); model(WeatherChanges.self); model(WeatherChange.self)
        model(HistoricalComparisons.self); model(HistoricalComparison.self); model(Trend<UnitLength>.self)
        model(TrendBaseline<UnitTemperature>.self); model(Deviation.self); model(Percentiles<UnitTemperature>.self)
        model(Forecast<DayWeather>.self); model(DailyWeatherStatistics<DayPrecipitationStatistics>.self)
        model(HourlyWeatherStatistics<HourTemperatureStatistics>.self)
        model(MonthlyWeatherStatistics<MonthPrecipitationStatistics>.self)
        model(DailyWeatherSummary<DayPrecipitationSummary>.self)
        collection(Forecast<MinuteWeather>.self); collection(WeatherChanges.self); collection(HistoricalComparisons.self)
        collection(DailyWeatherStatistics<DayTemperatureStatistics>.self)
        collection(HourlyWeatherStatistics<HourTemperatureStatistics>.self)
        collection(MonthlyWeatherStatistics<MonthTemperatureStatistics>.self)
        collection(DailyWeatherSummary<DayTemperatureSummary>.self)
        func stringEnum<E: RawRepresentable & CaseIterable & CustomStringConvertible>(_: E.Type) where E.RawValue == String {}
        stringEnum(WeatherCondition.self); stringEnum(Precipitation.self); stringEnum(PressureTrend.self)
        stringEnum(WeatherSeverity.self); stringEnum(MoonPhase.self); stringEnum(Wind.CompassDirection.self)
        stringEnum(UVIndex.ExposureCategory.self)
        func comparable<C: Comparable>(_: C.Type) {}
        comparable(UVIndex.ExposureCategory.self)
        func sendable<S: Sendable>(_: S.Type) {}
        sendable(WeatherService.self); sendable(WeatherQuery<CurrentWeather>.self)
        sendable(DailyWeatherStatisticsQuery<DayTemperatureStatistics>.self)
        func localizedError<E: LocalizedError>(_: E.Type) {}
        localizedError(WeatherError.self)
    }

    @Test("api.md §2: query static members have the documented result types")
    func queries() {
        let _: WeatherQuery<CurrentWeather> = .current
        let _: WeatherQuery<Forecast<MinuteWeather>?> = .minute
        let _: WeatherQuery<Forecast<HourWeather>> = .hourly
        let _: WeatherQuery<Forecast<HourWeather>> = .hourly(startDate: .now, endDate: .now)
        let _: WeatherQuery<Forecast<DayWeather>> = .daily
        let _: WeatherQuery<Forecast<DayWeather>> = .daily(startDate: .now, endDate: .now)
        let _: WeatherQuery<[WeatherAlert]?> = .alerts
        let _: WeatherQuery<WeatherAvailability> = .availability
        let _: WeatherQuery<WeatherChanges?> = .changes
        let _: WeatherQuery<HistoricalComparisons?> = .historicalComparisons
        let _: DailyWeatherStatisticsQuery<DayTemperatureStatistics> = .temperature
        let _: DailyWeatherStatisticsQuery<DayPrecipitationStatistics> = .precipitation
        let _: HourlyWeatherStatisticsQuery<HourTemperatureStatistics> = .temperature
        let _: MonthlyWeatherStatisticsQuery<MonthTemperatureStatistics> = .temperature
        let _: MonthlyWeatherStatisticsQuery<MonthPrecipitationStatistics> = .precipitation
        let _: DailyWeatherSummaryQuery<DayTemperatureSummary> = .temperature
        let _: DailyWeatherSummaryQuery<DayPrecipitationSummary> = .precipitation
    }

    @Test("api.md §1: WeatherService call shapes (tuples 1…6, parameter packs, statistics)")
    func serviceShapes() async throws {
        let backend = try FixtureWeatherBackend.bundled()
        let service = WeatherService(backend: backend, configuration: .init(language: "en-US", clock: { Date(timeIntervalSince1970: 1_768_478_400) }))
        let _: WeatherService = .shared
        // swiftlint:disable:next redundant_type_annotation - checks the type name compiles
        let _: WeatherService = WeatherService()
        let location = CLLocation(latitude: 41.5, longitude: -81.5)

        let weather: Weather = try await service.weather(for: location)
        #expect(weather.currentWeather.condition == .partlyCloudy)
        let current: CurrentWeather = try await service.weather(for: location, including: .current)
        #expect(current == weather.currentWeather)
        let two: (CurrentWeather, Forecast<DayWeather>) = try await service.weather(for: location, including: .current, .daily)
        #expect(two.1.count == 10)
        let three: (CurrentWeather, Forecast<HourWeather>, Forecast<DayWeather>) =
            try await service.weather(for: location, including: .current, .hourly, .daily)
        #expect(three.1.first?.date == Date(timeIntervalSince1970: 1_768_478_400))
        let four: (CurrentWeather, Forecast<MinuteWeather>?, Forecast<HourWeather>, Forecast<DayWeather>) =
            try await service.weather(for: location, including: .current, .minute, .hourly, .daily)
        #expect(four.1?.count == 60)
        let five: (CurrentWeather, Forecast<MinuteWeather>?, Forecast<HourWeather>, Forecast<DayWeather>, [WeatherAlert]?) =
            try await service.weather(for: location, including: .current, .minute, .hourly, .daily, .alerts)
        #expect(five.4?.first?.severity == .moderate)
        let six: (CurrentWeather, Forecast<MinuteWeather>?, Forecast<HourWeather>, Forecast<DayWeather>, [WeatherAlert]?, WeatherAvailability) =
            try await service.weather(for: location, including: .current, .minute, .hourly, .daily, .alerts, .availability)
        #expect(six.5.minuteAvailability == .available)
        let eight = try await service.weather(
            for: location, including: .current, .minute, .hourly, .daily, .alerts, .availability, .changes,
            .historicalComparisons)
        #expect(eight.6?.count == 7)
        #expect(eight.7?.count == 4)

        let attribution: WeatherAttribution = try await service.attribution
        #expect(attribution.serviceName == "Fixture data")

        let (dailyTemperature, dailyPrecipitation) = try await service.dailyStatistics(
            for: location, including: .temperature, .precipitation)
        #expect(dailyTemperature.days.count == 31)
        #expect(dailyPrecipitation.count == 31)
        let byDays = try await service.dailyStatistics(for: location, startDay: 10, endDay: 15, including: .temperature)
        #expect(byDays.days.map(\.day) == [10, 11, 12, 13, 14])
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_768_478_400), duration: 2 * 86_400)
        let byInterval = try await service.dailyStatistics(for: location, forDaysIn: interval, including: .temperature)
        #expect(byInterval.days.map(\.day) == [15, 16, 17])
        let hourly = try await service.hourlyStatistics(for: location, including: .temperature)
        #expect(hourly.hours.count == 48)
        let hourRange = try await service.hourlyStatistics(for: location, startHour: 340, endHour: 343, including: .temperature)
        #expect(hourRange.hours.map(\.hour) == [340, 341, 342])
        let hourInterval = try await service.hourlyStatistics(
            for: location, forHoursIn: DateInterval(start: Date(timeIntervalSince1970: 1_768_478_400), duration: 3 * 3600),
            including: .temperature)
        #expect(hourInterval.hours.map(\.hour) == [349, 350, 351])
        let (monthlyTemperature, monthlyPrecipitation) = try await service.monthlyStatistics(
            for: location, including: .temperature, .precipitation)
        #expect(monthlyTemperature.months.count == 12)
        #expect(monthlyPrecipitation.months.count == 12)
        let months = try await service.monthlyStatistics(for: location, startMonth: 3, endMonth: 6, including: .temperature)
        #expect(months.months.map(\.month) == [3, 4, 5])
        let monthInterval = try await service.monthlyStatistics(
            for: location, forMonthsIn: DateInterval(start: Date(timeIntervalSince1970: 1_768_478_400), duration: 40 * 86_400),
            including: .precipitation)
        #expect(monthInterval.months.map(\.month) == [1, 2])
        let (summaryTemperature, summaryPrecipitation) = try await service.dailySummary(
            for: location, including: .temperature, .precipitation)
        #expect(summaryTemperature.days.count == 7)
        #expect(summaryPrecipitation.days.count == 7)
        let lastTwo = try await service.dailySummary(
            for: location,
            forDaysIn: DateInterval(start: Date(timeIntervalSince1970: 1_768_478_400 - 2.5 * 86_400), end: Date(timeIntervalSince1970: 1_768_478_400)),
            including: .temperature)
        #expect(lastTwo.days.count == 2)
    }

    @Test("api.md §5, behavior.md §4: WeatherError cases, strings and NSError bridging")
    func weatherError() {
        let denied = WeatherError.permissionDenied as NSError
        let unknown = WeatherError.unknown as NSError
        #expect(denied.domain == "WeatherKit.WeatherError")
        #expect(denied.code == 0)
        #expect(unknown.domain == "WeatherKit.WeatherError")
        #expect(unknown.code == 1)
        #expect(WeatherError.permissionDenied.errorDescription?.isEmpty == false)
        #expect(WeatherError.unknown.errorDescription?.isEmpty == false)
        #expect(WeatherError.permissionDenied.failureReason?.isEmpty == false)
        #expect(WeatherError.unknown.failureReason == nil)
        #expect(WeatherError.permissionDenied.helpAnchor == nil)
        #expect(WeatherError.permissionDenied.recoverySuggestion == nil)
        #expect(WeatherError.unknown.recoverySuggestion == nil)
    }
}
