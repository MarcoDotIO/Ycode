# WeatherKit spec: the REST API as an interop protocol

Part of `specs/frameworks/weatherkit/`. Apple documents a REST form of the
weather service for web and non-Apple platforms. It is the backend an open
WeatherKit uses when the user brings their own Apple developer key, and its
JSON is the reference shape for Ycode's own data pipeline. Everything here is
level 1 (public WeatherKit REST API documentation, read 2026-10-19), in our
own words; field and value names are interop identifiers. Items marked
"verify" need the owner-provided key (W-REST in `plan.md`).

## 1. Endpoints

Base `https://weatherkit.apple.com`. All data endpoints need the developer
token (§2); responses are JSON.

| Method and path | Parameters | Result |
|---|---|---|
| `GET /api/v1/availability/{latitude}/{longitude}` | query `country` (ISO 3166 alpha-2; needed to answer for alerts and air quality) | JSON array of data-set names available at the location |
| `GET /api/v1/weather/{language}/{latitude}/{longitude}` | query `dataSets` (comma-separated, §3), `timezone` (IANA name used to group hours into days; documented as required), `countryCode` (alpha-2, needed for alerts), `currentAsOf` (default now), `dailyStart` (default today), `dailyEnd` (default 10 days), `hourlyStart` (default current hour), `hourlyEnd` (default 24 h or the daily length, whichever is longer); times are ISO 8601 | `Weather` object (§4) |
| `GET /api/v1/weatherAlert/{language}/{id}` | `id` = alert UUID | full `WeatherAlert` (§4.6); 404 if no active alert with that id |
| `GET /attribution/{language}` | — | `Attribution` (§4.7); our probe saw the framework fetch it without a token (level 3) |

Path rules: latitude −90…90, longitude −180…180; `language` is a BCP-47
style tag (`en-US`, `es-419`, `zh-CN` …).

Status codes: 200, 400 (bad parameter), 401 (missing or bad token), 404
(alert endpoint). Quota exhaustion and server errors are not documented
(verify; expect 429/5xx).

## 2. Authentication: developer token

- A **JWT** sent as `Authorization: Bearer <token>` on every request.
- Header: `alg` = `ES256`, `kid` = the 10-character Key ID of a WeatherKit
  key, `id` = `<Team ID>.<Services ID>`.
- Claims (exactly these; extra claims are rejected): `iss` = Team ID,
  `iat` = issue time, `exp` = expiry (seconds since the Unix epoch), `sub` =
  the Services ID.
- Signature: ECDSA P-256 with SHA-256 over the standard JWT signing input,
  using the private key (`.p8`, PKCS#8 PEM) downloaded when the key was
  created. Unsigned or otherwise-signed tokens get 401.
- Lifetime is the client's choice (trade-off between re-signing cost and
  exposure). Apple advises never shipping the private key in an app; apps and
  sites should get tokens from a server the developer controls.
- Set-up (owner, in the developer account): create a WeatherKit key under
  Keys; register a Services ID under Identifiers.

The native framework does **not** use this token format end to end: it
obtains a token from Apple's private `/v3/token` endpoint with a
device-signed request and calls a private `/api/v2/…` path
(`simulator-baseline.md` §2). An open implementation must use only the
documented v1 API.

## 3. Data sets

`currentWeather`, `forecastDaily`, `forecastHourly`, `forecastNextHour`,
`weatherAlerts`. (The native framework additionally uses `weatherChanges`,
`historicalComparisons`, `airQuality` on its private path; they are not part
of the documented API and an open implementation must compute or omit them —
`design.md` §5.)

## 4. Objects

Every product object (`CurrentWeather`, `DailyForecast`, `HourlyForecast`,
`NextHourForecast`, `WeatherAlertCollection`) has `name` and `metadata`
(the documented base type `ProductData`).

### 4.1 `Weather`

Optional members `currentWeather`, `forecastDaily`, `forecastHourly`,
`forecastNextHour`, `weatherAlerts` — present for the requested and available
data sets.

### 4.2 `Metadata`

Required: `expireTime`, `latitude`, `longitude`, `readTime`, `version`.
Optional: `attributionURL`, `language`, `providerLogo`, `providerName`,
`reportedTime`, `temporarilyUnavailable`, `units` (`UnitsSystem`, only `m` =
metric).

### 4.3 `CurrentWeather`

Required: `asOf`, `conditionCode`, `humidity`, `precipitationIntensity`,
`pressure`, `pressureTrend`, `temperature`, `temperatureApparent`,
`temperatureDewPoint`, `uvIndex`, `visibility`, `windSpeed`. Optional:
`cloudCover`, `daylight`, `windDirection`, `windGust`.

### 4.4 `HourlyForecast` and `HourWeatherConditions`

`HourlyForecast`: `hours` [HourWeatherConditions].

`HourWeatherConditions` — required: `cloudCover`, `conditionCode`,
`forecastStart`, `humidity`, `precipitationChance`, `precipitationType`,
`pressure`, `temperature`, `temperatureApparent`, `uvIndex`, `visibility`,
`windSpeed`; optional: `daylight`, `pressureTrend`, `snowfallIntensity`,
`temperatureDewPoint`, `windDirection`, `windGust`, `precipitationAmount`.

### 4.5 `DailyForecast`, `DayWeatherConditions`, `DayPartForecast`

`DailyForecast`: `days` [DayWeatherConditions], `learnMoreURL` opt.

`DayWeatherConditions` — required: `conditionCode`, `forecastStart`,
`forecastEnd`, `maxUvIndex`, `moonPhase`, `precipitationAmount`,
`precipitationChance`, `precipitationType`, `snowfallAmount`,
`temperatureMax`, `temperatureMin`; optional: `daytimeForecast`,
`overnightForecast` (DayPartForecast), `moonrise`, `moonset`,
`solarMidnight`, `solarNoon`, `sunrise`, `sunriseAstronomical`,
`sunriseCivil`, `sunriseNautical`, `sunset`, `sunsetAstronomical`,
`sunsetCivil`, `sunsetNautical`. (The iOS 18 Swift fields — rest-of-day
part, temperature times, humidity/visibility/wind extremes — have no
documented REST counterpart; verify whether the v1 API returns them.)

`DayPartForecast` — required: `cloudCover`, `conditionCode`,
`forecastStart`, `forecastEnd`, `humidity`, `precipitationAmount`,
`precipitationChance`, `precipitationType`, `snowfallAmount`, `windSpeed`;
optional `windDirection`.

### 4.6 `NextHourForecast`, alerts

`NextHourForecast`: `summary` [ForecastPeriodSummary], `minutes`
[ForecastMinute], `forecastStart` opt, `forecastEnd` opt.
`ForecastMinute`: `startTime`, `precipitationChance`,
`precipitationIntensity`. `ForecastPeriodSummary`: `startTime`, `endTime`
opt, `condition` (PrecipitationType), `precipitationChance`,
`precipitationIntensity`.

`WeatherAlertCollection`: `alerts` [WeatherAlertSummary], `detailsUrl` opt.
`WeatherAlertSummary` — required: `certainty`, `countryCode`,
`description`, `effectiveTime`, `expireTime`, `id` (UUID), `issuedTime`,
`responses` [ResponseType], `severity`, `source`; optional: `areaId`,
`areaName`, `detailsUrl`, `eventEndTime`, `eventOnsetTime`, `urgency`.
`WeatherAlert` (detail endpoint) = summary fields + `area` (an area
object) + `messages` [EventText {`language`, `text`}].

### 4.7 `Attribution`

Optional strings `serviceName` and nine logo URLs:
`logoLight@1x|2x|3x`, `logoDark@1x|2x|3x`, `logoSquare@1x|2x|3x`. The
native framework's `WeatherAttribution` exposes the 3x combined marks, the
square mark and the legal page (`https://weatherkit.apple.com/legal-attribution.html`,
level 3).

## 5. Units and value conventions

| Quantity | REST unit |
|---|---|
| temperatures | °C |
| wind speed, gust | km/h |
| wind direction | degrees (integer) |
| pressure | millibars (hPa) |
| visibility | metres |
| precipitation and snowfall amounts | millimetres |
| precipitation and snowfall intensity | mm/h |
| cloud cover, humidity, precipitation chance | fraction 0…1 |
| UV index | integer |
| times | ISO 8601 date-time strings |

## 6. Enumerations

| Type | Values |
|---|---|
| `PrecipitationType` | `clear`, `precipitation`, `rain`, `snow`, `sleet`, `hail`, `mixed` |
| `PressureTrend` | `rising`, `falling`, `steady` |
| `MoonPhase` | `new`, `waxingCrescent`, `firstQuarter`, `waxingGibbous`, `full`, `waningGibbous`, `thirdQuarter`, `waningCrescent` |
| `Severity` | `extreme`, `severe`, `moderate`, `minor`, `unknown` |
| `Certainty` | `observed`, `likely`, `possible`, `unlikely`, `unknown` |
| `Urgency` | `immediate`, `expected`, `future`, `past`, `unknown` |
| `ResponseType` | `shelter`, `evacuate`, `prepare`, `execute`, `avoid`, `monitor`, `assess`, `allClear`, `none` |
| `UnitsSystem` | `m` |
| `conditionCode` | a string; the docs give no enumeration. Expected: the 34 conditions of `api.md` §3.8 in UpperCamelCase (`Clear`, `MostlyClear`, `HeavyRain`, …) — verify |

Mapping to the Swift API (implementation guidance): REST `thirdQuarter` →
Swift `lastQuarter`; REST `clear` precipitation type → Swift `none`;
`precipitation` (unspecified type) → Swift `rain` is the natural fallback
(verify against native results with W-DATA); `conditionCode` → the
`WeatherCondition` case with the same name in lowerCamelCase.

## 7. Usage terms relevant to an implementation

Included quota 500 000 calls per month per membership; paid tiers above
that; unused calls lapse. Display and attribution rules of
`behavior.md` §7 apply to data obtained through REST as well.

## Evidence

All level 1 except: attribution fetched without a token and the
legal-page URL (level 3); the private v2/v3 paths (level 3, recorded so that
implementers know **not** to use them).
