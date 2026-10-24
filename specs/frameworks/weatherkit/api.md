# WeatherKit spec: Swift interface

Part of `specs/frameworks/weatherkit/`. The public Swift API of the
framework, as names, shapes and meanings in our own words. Type and member
names, generic shapes and availability are interop facts (level 4, iOS 27.1
SDK); meanings are from public documentation (level 1) and our probe
(level 3). "18+" means iOS 18 / macOS 15 / tvOS 18 / watchOS 11 /
visionOS 2; everything else is iOS 16 / macOS 13 / tvOS 16 / watchOS 9
unless noted.

General rules of the module:

- Every model type is a `struct` (or `enum`) that is `Codable`, `Equatable`
  and `Sendable`. **No model type has a public initializer**; values come
  from the service or from decoding (`codable.md`).
- Collections (`Forecast`, `WeatherChanges`, `HistoricalComparisons`, the
  statistics and summary wrappers) are `RandomAccessCollection`s with `Int`
  indices, exposing their element array and a `metadata`.
- String-backed enums are `RawRepresentable` with the case name as raw value,
  `CaseIterable` and `CustomStringConvertible` (localized `description`);
  several also have `accessibilityDescription`.
- Quantities are Foundation `Measurement`s; fractions (cloud cover,
  humidity, chances) are `Double` in 0…1.

## 1. `WeatherService`

A final class, `@unchecked Sendable`.

| Member | Meaning |
|---|---|
| `static let shared` | process-wide instance |
| `init()` | an independent instance (same behavior) |
| `var attribution: WeatherAttribution { get async throws }` | branding and legal attribution for the data provider (§4) |
| `weather(for: CLLocation) async throws -> Weather` | everything in one value: current, minute (optional), hourly, daily, alerts (optional), availability |
| `weather(for:including:)` with one to six `WeatherQuery` arguments, returning the value or a tuple in argument order | only the requested data sets |
| 18+: `weather(for:including:)` with a parameter pack of queries | same, any number |
| 18+: `dailyStatistics(for:including:)`, `dailyStatistics(for:forDaysIn: DateInterval, including:)`, `dailyStatistics(for:startDay:endDay:including:)` | historical daily statistics; days identified by day-of-year numbers or a date interval |
| 18+: `hourlyStatistics(for:including:)`, `…(for:forHoursIn:including:)`, `…(for:startHour:endHour:including:)` | historical hourly statistics (percentiles) |
| 18+: `monthlyStatistics(for:including:)`, `…(for:forMonthsIn:including:)`, `…(for:startMonth:endMonth:including:)` | historical monthly averages |
| 18+: `dailySummary(for:including:)`, `dailySummary(for:forDaysIn:including:)` | observed daily totals/extremes for past days |

All statistics/summary methods take parameter packs of their query type and
return a tuple of the matching wrapper types. The location argument is a
`CLLocation`; only its coordinate is used (level 3: altitude/accuracy do not
appear in requests).

## 2. Queries

### 2.1 `WeatherQuery<T>` (Sendable)

| Static member | `T` |
|---|---|
| `current` | `CurrentWeather` |
| `minute` | `Forecast<MinuteWeather>?` (nil where minute forecasts are unsupported) |
| `hourly` | `Forecast<HourWeather>` (default range not documented for Swift; the REST default is from the current hour for 24 hours or the length of the daily forecast, whichever is longer — verify in W-DATA) |
| `hourly(startDate:endDate:)` | `Forecast<HourWeather>` for the interval |
| `daily` | `Forecast<DayWeather>` (REST default: 10 days from the current day) |
| `daily(startDate:endDate:)` | `Forecast<DayWeather>` for the interval |
| `alerts` | `[WeatherAlert]?` (nil where alerts are unsupported) |
| `availability` | `WeatherAvailability` |
| 18+ `changes` | `WeatherChanges?` |
| 18+ `historicalComparisons` | `HistoricalComparisons?` |

Building a date-range query whose end precedes its start is a programming
error that **traps** (level 3).

### 2.2 Statistics and summary queries (18+, Sendable)

| Query type | Static members → element type |
|---|---|
| `DailyWeatherStatisticsQuery<T>` | `temperature` → `DayTemperatureStatistics`; `precipitation` → `DayPrecipitationStatistics` |
| `HourlyWeatherStatisticsQuery<T>` | `temperature` → `HourTemperatureStatistics` |
| `MonthlyWeatherStatisticsQuery<T>` | `temperature` → `MonthTemperatureStatistics`; `precipitation` → `MonthPrecipitationStatistics` |
| `DailyWeatherSummaryQuery<T>` | `temperature` → `DayTemperatureSummary`; `precipitation` → `DayPrecipitationSummary` |

## 3. Data model

### 3.1 Containers

| Type | Members |
|---|---|
| `Weather` | `currentWeather: CurrentWeather`, `minuteForecast: Forecast<MinuteWeather>?`, `hourlyForecast`, `dailyForecast`, `weatherAlerts: [WeatherAlert]?`, `availability: WeatherAvailability` |
| `Forecast<Element>` | `forecast: [Element]`, `metadata`; collection of `Element`. For minute forecasts also `summary: String` (a sentence describing the next hour's precipitation) |
| `WeatherMetadata` | `date` (when the data was produced), `expirationDate` (when it should be refreshed), `location: CLLocation` (the coordinate the data is for) |
| `WeatherAvailability` | `minuteAvailability`, `alertAvailability`: `AvailabilityKind` = `available`, `temporarilyUnavailable`, `unsupported`, `unknown` (String raw values; not `CaseIterable`) |
| `WeatherAttribution` | §4 |

### 3.2 `CurrentWeather`

`date`, `cloudCover` (0…1), 18+ `cloudCoverByAltitude`, `condition:
WeatherCondition`, `symbolName` (an SF Symbols name), `dewPoint`
(temperature), `humidity` (0…1), `precipitationIntensity` (`UnitSpeed`,
i.e. depth per time), `pressure` (`UnitPressure`), `pressureTrend`,
`isDaylight`, `temperature`, `apparentTemperature` (feels-like), `uvIndex`,
`visibility` (`UnitLength`), `wind`, `metadata`.

### 3.3 `MinuteWeather`

`date`, `precipitation: Precipitation`, `precipitationChance` (0…1),
`precipitationIntensity` (`UnitSpeed`).

### 3.4 `HourWeather`

`date`, `cloudCover`, 18+ `cloudCoverByAltitude`, `condition`, `symbolName`,
`dewPoint`, `humidity`, `isDaylight`, `precipitation`,
`precipitationChance`, `precipitationAmount` (`UnitLength`), 18+
`snowfallAmount`, `pressure`, `pressureTrend`, `temperature`,
`apparentTemperature`, `uvIndex`, `visibility`, `wind`.

### 3.5 `DayWeather`

`date`, `condition`, `symbolName`, `highTemperature`, `lowTemperature`, 18+
`highTemperatureTime`/`lowTemperatureTime` (optional dates), 18+
`maximumHumidity`/`minimumHumidity`, `precipitation`,
`precipitationChance`, 18+ `precipitationAmountByType`, `sun: SunEvents`,
`moon: MoonEvents`, `uvIndex` (the day's maximum), `wind`, 18+
`maximumVisibility`/`minimumVisibility` (plain `Double`, metres — unlike the
`Measurement` used elsewhere), 18+ `highWindSpeed` (optional, not on
visionOS), 18+ `daytimeForecast`, `overnightForecast` (`DayPartForecast`),
`restOfDayForecast` (optional).

Deprecated members: `precipitationAmount` and `snowfallAmount` (deprecated in
18 for `precipitationAmountByType`), `rainfallAmount` (deprecated in 16.4).

### 3.6 `DayPartForecast` (18+)

`cloudCover`, `cloudCoverByAltitude`, `condition`, `highTemperature`,
`lowTemperature`, `precipitation`, `precipitationAmountByType`,
`precipitationChance`, `maximumHumidity`, `minimumHumidity`,
`maximumVisibility`, `minimumVisibility` (`Measurement<UnitLength>`),
`wind`, `highWindSpeed`. The span of each part is not public in the Swift
API; the REST form carries explicit `forecastStart`/`forecastEnd` per part
(the Codable form has them too, `codable.md`). Commonly the daytime part is
the local morning to evening and the overnight part the following night;
verify the exact hours in W-DATA.

### 3.7 Precipitation amounts (18+)

- `PrecipitationAmountByType`: `hail`, `mixed`, `rainfall`, `sleet`,
  `precipitation` (all `UnitLength`), `snowfallAmount: SnowfallAmount`.
- `SnowfallAmount`: `amount`, `maximum`, `minimum` and their
  `…LiquidEquivalent` counterparts (`UnitLength`).
- `CloudCoverByAltitude`: `low`, `medium`, `high` (0…1).

### 3.8 Supporting values

| Type | Members |
|---|---|
| `Wind` | `compassDirection: Wind.CompassDirection`, `direction` (`UnitAngle`, degrees from which the wind blows), `speed` (`UnitSpeed`), `gust` (optional `UnitSpeed`) |
| `Wind.CompassDirection` | 16 points `north`, `northNortheast`, `northeast`, `eastNortheast`, `east`, `eastSoutheast`, `southeast`, `southSoutheast`, `south`, `southSouthwest`, `southwest`, `westSouthwest`, `west`, `westNorthwest`, `northwest`, `northNorthwest`; `abbreviation` (N, NNE, …), `description`, `accessibilityDescription` |
| `UVIndex` | `value: Int`, `category: UVIndex.ExposureCategory` (`low`, `moderate`, `high`, `veryHigh`, `extreme`; `Comparable`; `rangeValue: ClosedRange<Int>` = 0…2, 3…5, 6…7, 8…10, 11…`Int.max`) |
| `SunEvents` | optional dates `astronomicalDawn`, `nauticalDawn`, `civilDawn`, `sunrise`, `solarNoon`, `sunset`, `civilDusk`, `nauticalDusk`, `astronomicalDusk`, `solarMidnight` (nil when the event does not occur that day, e.g. polar day/night) |
| `MoonEvents` | `phase: MoonPhase`, optional `moonrise`, `moonset` |
| `MoonPhase` | `new`, `waxingCrescent`, `firstQuarter`, `waxingGibbous`, `full`, `waningGibbous`, `lastQuarter`, `waningCrescent`; `description`, `accessibilityDescription`, `symbolName` (`moonphase.<words>`) |
| `WeatherCondition` | 34 cases: `blizzard`, `blowingDust`, `blowingSnow`, `breezy`, `clear`, `cloudy`, `drizzle`, `flurries`, `foggy`, `freezingDrizzle`, `freezingRain`, `frigid`, `hail`, `haze`, `heavyRain`, `heavySnow`, `hot`, `hurricane`, `isolatedThunderstorms`, `mostlyClear`, `mostlyCloudy`, `partlyCloudy`, `rain`, `scatteredThunderstorms`, `sleet`, `smoky`, `snow`, `strongStorms`, `sunFlurries`, `sunShowers`, `thunderstorms`, `tropicalStorm`, `windy`, `wintryMix`; `description`, `accessibilityDescription` |
| `Precipitation` | `none`, `hail`, `mixed`, `rain`, `sleet`, `snow`; `description`, `accessibilityDescription` |
| `PressureTrend` | `rising`, `falling`, `steady`; `description`, `accessibilityDescription` |
| `WeatherSeverity` | `minor`, `moderate`, `severe`, `extreme`, `unknown`; `description`, `accessibilityDescription` |

### 3.9 `WeatherAlert`

`detailsURL` (Apple-hosted page with the full alert), `source` (issuing
agency name), `summary` (headline), `region` (optional area name),
`severity: WeatherSeverity`, `metadata`.

### 3.10 Changes and comparisons (18+)

- `WeatherChanges`: collection of `WeatherChange` (`date`,
  `highTemperature`, `lowTemperature`, `dayPrecipitationAmount`,
  `nightPrecipitationAmount`, each a `WeatherChange.Direction` =
  `increase`, `decrease`, `steady`) — how the coming days compare with the
  day before, plus `metadata`.
- `HistoricalComparisons`: collection of `HistoricalComparison`, an enum
  with associated `Trend` values: `highTemperature(Trend<UnitTemperature>)`,
  `lowTemperature(…)`, `precipitationAmount(Trend<UnitLength>)`,
  `snowfallAmount(Trend<UnitLength>)`; plus `metadata`.
- `Trend<Dimension>`: `baseline: TrendBaseline<Dimension>`, `currentValue`,
  `deviation: Deviation` (`muchHigher`, `higher`, `normal`, `lower`,
  `muchLower`).
- `TrendBaseline<Dimension>`: `kind` (`TrendBaseline.Kind.mean`), `value`,
  `startDate` (start of the baseline period).

### 3.11 Statistics and summaries (18+)

| Wrapper | Members |
|---|---|
| `DailyWeatherStatistics<T>` | `days: [T]`, `baselineStartDate`, `metadata` |
| `HourlyWeatherStatistics<T>` | `hours: [T]`, `baselineStartDate`, `metadata` |
| `MonthlyWeatherStatistics<T>` | `months: [T]`, `baselineStartDate`, `metadata` |
| `DailyWeatherSummary<T>` | `days: [T]`, `metadata` |

| Element | Members |
|---|---|
| `DayTemperatureStatistics` | `day` (day of year), `averageLowTemperature`, `averageHighTemperature` |
| `DayPrecipitationStatistics` | `day`, `averagePrecipitationProbability`, `averagePrecipitationAmount`, `averageSnowfallAmount` |
| `HourTemperatureStatistics` | `hour` (hour of year), `percentiles: Percentiles<UnitTemperature>` |
| `Percentiles<Dimension>` | `p10`, `p50`, `p90` |
| `MonthTemperatureStatistics` | `month` (1…12), `averageLowTemperature`, `averageHighTemperature` |
| `MonthPrecipitationStatistics` | `month`, `averagePrecipitationProbability`, `averagePrecipitationAmount`, `averageSnowfallAmount` |
| `DayTemperatureSummary` | `date`, `lowTemperature`, `highTemperature` |
| `DayPrecipitationSummary` | `date`, `precipitationAmount`, `snowfallAmount` |

## 4. `WeatherAttribution`

`serviceName` (provider name, "Apple Weather" for Apple's service),
`legalPageURL` (page listing data sources), `squareMarkURL`,
`combinedMarkLightURL` and `combinedMarkDarkURL` (logo images for light and
dark backgrounds, localized), 16.4+ `legalAttributionText` (the same
source list as plain text, for contexts where a web link cannot be shown).
Display rules: `behavior.md` §6.

## 5. `WeatherError`

`enum WeatherError: LocalizedError` with `permissionDenied` and `unknown`;
`errorDescription`, `failureReason`, `helpAnchor`, `recoverySuggestion`.
Bridged to `NSError` with domain `WeatherKit.WeatherError` and codes 0 and 1
(level 3). In practice other, internal errors are thrown too
(`behavior.md` §4).

## 6. Units

Measurement dimensions per field are part of the API (above). The unit the
values arrive in is not specified by the Swift API; apps convert with
`converted(to:)` and format with `MeasurementFormatter`/`FormatStyle`. The
REST API delivers metric values (°C, km/h, mbar, m, mm, mm/h); an
implementation should return those units (`.celsius`,
`.kilometersPerHour`, `.millibars`/`.hectopascals`, `.meters`,
`.millimeters`, and for intensities a custom `UnitSpeed` of millimetres per
hour or the equivalent) — to be confirmed against real values in W-DATA.

## Evidence

| Claim | Level |
|---|---|
| Names, shapes, generics, availability, deprecations, conformances | 4 |
| Meanings of fields and queries, metric units, REST defaults | 1 |
| Error bridging, trap on reversed range, UV ranges, symbol names, absence of public initializers verified by use | 3 (+4) |
