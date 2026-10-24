# WeatherKit spec: Codable archive format

Part of `specs/frameworks/weatherkit/`. Every WeatherKit model type is
`Codable`, and none has a public initializer, so **decoding is the only way
an app can construct values** — app unit tests and previews do it with JSON
fixtures, and apps persist fetched weather by encoding it. An open
implementation should read archives written by Apple's framework and write
archives Apple's framework can read. This file gives the key structure
(level 3: WKProbe `-mode codable` decoded each type with a recording
decoder, re-encoded it with `JSONEncoder`, decoded the result again — every
type round-trips). Key names are interop identifiers; this is a format
description, not code.

## 1. Conventions

- Keyed containers with the key names below. Encoder strategies are the
  caller's (`JSONEncoder` defaults shown here): `Date` as Foundation's
  default (seconds since 2001-01-01 as a number), `URL` as a string.
- Every `Measurement` (written **M** below) uses Foundation's own Codable
  form: `{"value": number, "unit": {"symbol": string, "converter":
  {"coefficient": number, "constant": number}}}`. An implementation must
  produce the same (it does automatically when it uses Foundation's
  `Measurement`).
- String enums encode their raw value (the case name).
- Enums with payloads use Swift's synthesized form:
  `{"caseName": {"_0": payload}}`; payload-free enums that are not
  String-backed encode as `{"caseName": {}}` (`WeatherChange.Direction`,
  `Deviation`, `TrendBaseline.Kind`).
- "opt" = decoded with `decodeIfPresent` (may be absent); all other keys
  are required for decoding.
- Several types carry **non-public keys** (marked *np*). An implementation
  must accept and preserve them when present; when it has no value for a
  required *np* key it must still write something decodable — the plan
  (`plan.md` R2) fixes Ycode's default per key after the owner-run W-DATA
  check shows real values.

## 2. Small types

| Type | Keys |
|---|---|
| `WeatherAttribution` | `storage` → `serviceName`, `legalPageURL`, `squareMarkURL`, `combinedMarkLightURL`, `combinedMarkDarkURL`, *np* `logoURL` (opt), *np* `sourceURL` (opt) |
| `WeatherMetadata` | `date`, `expirationDate`, `latitude`, `longitude` (numbers; `location` is rebuilt from them), `attribution` (opt, a `WeatherAttribution`) |
| `Wind` | `compassDirection`, `direction` M, `speed` M, `gust` M opt |
| `UVIndex` | `value`, `category` |
| `SunEvents` | the ten event names of `api.md` §3.8, each opt |
| `MoonEvents` | `phase`, `moonrise` opt, `moonset` opt |
| `WeatherAvailability` | `minuteAvailability`, `alertAvailability`, *np* `airQualityAvailability` |
| *np* intensity object | `{"category": string, "value": number}` — used by `apparentPrecipitationIntensity`, `precipitationIntensityMax`, `perceivedPrecipitationIntensityMax` |

## 3. Weather values

`CurrentWeather`: `date`, `cloudCover`, `cloudCoverByAltitude`
{`low`,`medium`,`high`}, *np* `cloudCoverLow`/`cloudCoverMid`/`cloudCoverHigh`,
`condition`, `symbolName`, `dewPoint` M, `humidity`, `precipitationIntensity`
M, *np* `apparentPrecipitationIntensity`, `pressure` M, `pressureTrend`,
`isDaylight`, `temperature` M, `apparentTemperature` M, `uvIndex`,
`visibility` M, `wind`, `metadata`; *np* `highTemperature` M opt,
`lowTemperature` M opt; *np* `rainfallAmount` and `snowfallAmount`, each
{`pastHour`, `pastSixHours`, `pastTwentyFourHours`, `nextHour`,
`nextSixHours`, `nextTwentyFourHours`} of M; *np*
`past|next` × `Hour|SixHours|TwentyFourHours` + `PrecipitationAmountByType`
(six keys, each a `PrecipitationAmountByType`).

`MinuteWeather`: `date`, `precipitation`, `precipitationChance`,
`precipitationIntensity` M, *np* `apparentPrecipitationIntensity`.

`HourWeather`: `date`, `cloudCover`, `cloudCoverByAltitude`, *np*
`cloudCoverLow/Mid/High`, `condition`, `symbolName`, `dewPoint` M,
`humidity`, `isDaylight`, `precipitation`, `precipitationAmount` M,
`precipitationChance`, `snowfallAmount` M, `pressure` M, `pressureTrend`,
`temperature` M, `apparentTemperature` M, `uvIndex`, `visibility` M, `wind`,
*np* `apparentPrecipitationIntensity`.

`DayWeather`: `date`, `condition`, `symbolName`, `highTemperature` M,
`lowTemperature` M, `highTemperatureTime` opt, `lowTemperatureTime` opt,
`maximumHumidity`, `minimumHumidity`, *np* `humidityMax`, `humidityMin`,
`precipitation`, `precipitationChance`, `precipitationAmountByType`,
`rainfallAmount` M, `snowfallAmount` M, `sun`, `moon`, `uvIndex`, `wind`,
`maximumVisibility`, `minimumVisibility` (numbers), *np* `visibilityMax`,
`visibilityMin` (numbers), `highWindSpeed` M opt, *np* `windSpeedAvg`,
`windSpeedMax`, `windGustSpeedMax` (M), `daytimeForecast`,
`overnightForecast`, `restOfDayForecast` opt.

`DayPartForecast`: *np* `forecastStart`, `forecastEnd` (dates),
`cloudCover`, `cloudCoverByAltitude`, `condition`, `highTemperature` M,
`lowTemperature` M, *np* `humidity`, `maximumHumidity`, `minimumHumidity`,
*np* `isDaylight`, `maximumVisibility` M, `minimumVisibility` M, *np*
`maximumUVIndex`, `minimumUVIndex` (UV objects), `precipitation`,
`precipitationAmountByType`, `precipitationChance`, *np*
`precipitationIntensityMax`, `perceivedPrecipitationIntensityMax`, `wind`,
`highWindSpeed` M.

`PrecipitationAmountByType`: `hail`, `mixed`, `rainfall`, `sleet`,
`precipitation` (M), `snowfallAmount` (`SnowfallAmount`: `amount`,
`maximum`, `minimum`, `amountLiquidEquivalent`, `maximumLiquidEquivalent`,
`minimumLiquidEquivalent`, all M).

`WeatherAlert`: `summary`, `source`, `region` opt, `severity`, `detailsURL`,
`metadata`; *np* `id` (UUID string), `importance` (string enum; `normal` is
one accepted value), `description`, `details` opt, `date`, `issuedDate`,
`onsetTime` opt, `endDate` opt, `expirationDate`.

## 4. Collections

`Forecast<Element>` (all three element types): `forecast` [Element],
`metadata`; *np* opt: `minuteSummary` (string), `minuteSummaries`
[{`date`, `expirationDate` opt, `precipitation`, `precipitationChance`,
`precipitationKind`, `apparentPrecipitationIntensity` opt}],
`minuteConditions` [{`date`, `expirationDate` opt, `shortDescription`,
`longDescription`, `shift` {`date`, `nextDate`, `kind` (payload-free enum;
`clear` is one accepted case)}}], `marineLocation` {`latitude`,
`longitude`}. (The public `summary` of a minute forecast is derived from
these.)

`WeatherChanges`: `changes` [{`date`, `highTemperature`, `lowTemperature`,
`dayPrecipitationAmount`, `nightPrecipitationAmount`}], `metadata`.

`HistoricalComparisons`: `comparisons` [`HistoricalComparison`], `metadata`;
a comparison is `{"highTemperature": {"_0": Trend}}` (or `lowTemperature`,
`precipitationAmount`, `snowfallAmount`); `Trend` = {`baseline`
{`kind`, `value` M, `startDate`}, `currentValue` M, `deviation`}.

Statistics/summaries: `{baselineStartDate, days|hours|months: [...],
metadata}` (summaries have no `baselineStartDate`); elements use exactly the
public member names of `api.md` §3.11 (`percentiles` = {`p10`,`p50`,`p90`}
of M).

## 5. `Weather`

`currentWeather`, `hourlyForecast`, `dailyForecast`, `availability`
(required); `minuteForecast` opt, `weatherAlerts` opt, *np*
`weatherChanges` opt, and further *np* optional products (`airQuality`,
`news`, `dataNotice`, and others with internal formats). An implementation
writes only the products it has and ignores unknown keys on decoding.

## Evidence

All of this file: level 3 (our recording-decoder probe, which only observes
what keys a type's public `init(from:)` asks for and what its public
`encode(to:)` writes). Names of payload cases not in the public API
(`importance`, `shift.kind`) were found by trying candidate words; only
the accepted ones are listed.
