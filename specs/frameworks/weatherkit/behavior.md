# WeatherKit spec: behavior of the Swift API

Part of `specs/frameworks/weatherkit/`. How the framework behaves around the
data: what a call requests, how locations are handled, caching and expiry,
errors, concurrency, display strings and the attribution rules apps must
follow. Levels per section; level 3 facts come from WKProbe in the reference
simulator (failure paths only — see `simulator-baseline.md` §5 for what still
needs an entitled run).

## 1. Request composition (level 3)

- Each data set the caller asks for maps to one server product:

| Swift query | Product (REST data-set name) |
|---|---|
| `.current` | `currentWeather` |
| `.minute` | `forecastNextHour` |
| `.hourly`, `.hourly(startDate:endDate:)` | `forecastHourly` |
| `.daily`, `.daily(startDate:endDate:)` | `forecastDaily` |
| `.alerts` | `weatherAlerts` |
| `.availability` | `forecastNextHour` + `weatherAlerts` (+ non-public air quality): availability is derived from whether those products exist for the location |
| `.changes` | `weatherChanges` (not in the public v1 REST list) |
| `.historicalComparisons` | `historicalComparisons` (not in the public v1 REST list) |

- `weather(for:)` requests current, daily, hourly, next-hour, alerts and
  changes (plus non-public products) in **one** network request.
- `weather(for:including: a, b, c)` requests exactly those products, also in
  one request, and returns them as a tuple in argument order.
- Date-range queries add `dailyStart`/`dailyEnd` (or `hourlyStart`/
  `hourlyEnd`) as ISO 8601 UTC timestamps with seconds (`…T23:30:02Z`),
  exactly the caller's dates; queries without a range send no range
  parameters (server defaults apply).
- Statistics and summaries use separate products and a separate cache
  database.

## 2. Location handling (level 3)

- Only the coordinate of the `CLLocation` matters. Coordinates are rounded to
  **3 decimal places** (~110 m) for the request and the cache key.
- No client-side range check: invalid latitudes reach the request path.
- Before an uncached request the framework derives the location's **country
  code and time zone** by reverse geocoding (cached 5 days). The time zone
  decides how hours roll up into days; the country decides alert and
  minute-forecast availability. An implementation needs a coordinate →
  (country, time zone) resolver; offline boundary data is sufficient
  (`design.md` §4).
- The language is the device's preferred language (`en-US` form); the
  device's language list is also sent.

## 3. Caching and expiry

- Every product carries `metadata.date` (when produced) and
  `metadata.expirationDate` (when to refresh) (level 1/4).
- The framework keeps a **persistent per-product cache**, keyed by rounded
  coordinate and language, and answers from it while the entry has not
  expired; expired entries are never returned on the normal path, and a
  failed refresh does not fall back to stale data (level 3: "policy
  disallows expired data", "no fallback cache policy").
- The cache is shared by all processes of the device in Apple's simulator
  (device-wide `/Library/Weather`); on devices it is presumably per app.
  Apps must not rely on either; an implementation may keep a per-app cache.
- Attribution is cached by the URL cache (first fetch network, later
  ~30 ms, survives relaunch) (level 3).
- Recommended for an implementation: cache key = (product, rounded
  coordinate, language, requested range); honour `expirationDate`; coalesce
  identical in-flight requests; persist across launches.

## 4. Errors

| Condition | What the reference throws | Level |
|---|---|---|
| App lacks the WeatherKit entitlement | internal error (bridged domain `WeatherDaemon.WDSJWTAuthenticatorServiceProxy.Errors`, code 0) | 3 |
| Entitled app whose bundle ID is not enabled for WeatherKit (server 401) | internal error (domain `WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors`, code 2) | 3 |
| Revoked key, malformed token, operation not allowed | `WeatherError.permissionDenied` (its failure reason describes exactly these causes) | 1/4 (inferred from the reason text) |
| Anything else unexpected | `WeatherError.unknown` | 1/4 |
| Network unreachable | presumably a URL-loading error; **not observed** | — |
| Reversed date range in a query | trap (crash) at query construction | 3 |

Guidance for an implementation: throw `WeatherError.permissionDenied` for
all authentication/authorization failures (it is what apps test for), and
`WeatherError.unknown` for other service errors; let `URLError`s from the
transport pass through unchanged. Do **not** copy Apple's internal error
domains; parity tests should compare "is a `WeatherError`" vs "is not",
not the internal domains (`plan.md` notes this deliberate difference).

`WeatherError` bridges to `NSError` domain `WeatherKit.WeatherError`, codes
0 (`permissionDenied`) and 1 (`unknown`); `errorDescription` is a short
localized phrase, `failureReason` is set for `permissionDenied` only,
`helpAnchor` and `recoverySuggestion` are nil (level 3).

## 5. Concurrency and cancellation (level 3, failure path)

- `WeatherService` is safe to use from any task; concurrent calls are
  independent.
- Cancellation was not honoured on the failure path (a cancelled task still
  ended with the authentication error). An implementation should check
  cancellation before network access and throw `CancellationError`; this is a
  harmless difference.

## 6. Display strings (level 3)

`description` values are localized English in the reference:

- `WeatherCondition`: title case of the case name in words, except
  `blowingDust` "Dust", `foggy` "Fog", `frigid` "Cold", `smoky` "Smoke",
  `strongStorms` "Severe Thunderstorm", `thunderstorms` "Thunderstorm".
  `accessibilityDescription`: the same in lower case.
- `Precipitation`: lower case; `mixed` reads "wintry mix"; `none` is the
  empty string.
- `PressureTrend`: "Rising", "Falling", "Steady".
- `WeatherSeverity`: the case name.
- `MoonPhase`: "New Moon", "Waxing Crescent", "First Quarter", "Waxing
  Gibbous", "Full Moon", "Waning Gibbous", "Last Quarter", "Waning
  Crescent"; `symbolName` is `moonphase.` followed by the words in lower case
  separated by dots (`new.moon`, `full.moon`, `last.quarter`, …).
- `Wind.CompassDirection`: "North Northeast" style; abbreviations N, NNE, NE,
  ENE, E, ESE, SE, SSE, S, SSW, SW, WSW, W, WNW, NW, NNW.
- `UVIndex.ExposureCategory`: "Low", "Moderate", "High", "Very High",
  "Extreme".
- `symbolName` on current/hour/day values is an SF Symbols name chosen from
  condition and daylight (values not observed without data; an
  implementation needs its own condition → symbol table, `design.md` §5).

Ycode writes its own localization tables (these short English labels are
facts about output; other languages are not copied).

## 7. Attribution and display requirements (level 1)

Apple's terms for apps that show WeatherKit data (summarized):

- Show the **Apple Weather mark** (the "Weather" trademark with the Apple
  logo) and a **link to the legal attribution page** of the data sources
  wherever Apple weather data is displayed (apps, web apps, sites). The
  Swift API supplies the mark URLs (light and dark) and the legal page URL;
  `legalAttributionText` is for places that cannot show a link.
- **Alerts**: link to Apple's alert details page (`detailsURL`), name the
  issuing agency in full (`source`), and never modify or obscure alert text.
- **Derived ("value-added") products** that do not expose Apple's data must
  still credit "Weather" as a source and say the data was modified.
- Some features exist only in some regions (minute forecasts, alerts);
  `WeatherAvailability` and the optional types tell apps what is supported at
  a location.
- Quota: 500 000 calls per month per developer membership, more by paid
  subscription; unused calls do not roll over.

For an open implementation the same rules apply **per backend**: the
attribution value must describe the backend actually used (provider name,
logo, legal page, licence text), and the backend's licence terms decide what
apps must display (`design.md` §3).

## Evidence

| Section | Level |
|---|---|
| §1–§2, §5, §6 | 3 |
| §3 | 1/4 (metadata fields) + 3 (cache policy messages) |
| §4 | 3 + 1/4 |
| §7 | 1 |
