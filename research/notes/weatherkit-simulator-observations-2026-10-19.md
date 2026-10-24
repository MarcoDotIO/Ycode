# WeatherKit and Core Location in Apple's iOS Simulator — observations, 2026-10-19

Dirty-room notes (prose only) by KIT-WEATHERKIT. Reference: Xcode 27.1
(27A9269), iOS 27.1 simulator runtime 24A94401, device type iPhone Duo
(simulator `ycode-test-weatherkit-1`, created for this work and deleted
afterwards), Apple-silicon Mac under very heavy load (load average 7 → 395
during the session; timings are indicative only). WeatherKit bundle version
1454.5 (`CFBundleVersion` of the runtime's framework and of the SDK's
`.tbd`).

Probe: `research/experiments/weatherkit/WKProbe/` (our own Swift code, built
with `swiftc` from the installed Xcode, ad-hoc signed, no team). Raw output,
logs and screenshots: `research/dirty/weatherkit/` (git-ignored). No
disassembly or decompilation was used. Logs were read with
`simctl spawn … log stream` (black-box: the system's own log output while our
probe ran). No account was signed in to; no credential was read.

## Variants

| App | Bundle ID | Entitlement | Location usage string |
|---|---|---|---|
| WKProbe | dev.ycode.wkprobe | none | yes |
| WKProbeEnt | dev.ycode.wkprobe.ent | `com.apple.developer.weatherkit` = true in the `__TEXT,__entitlements` section only (what Xcode does for simulator builds) | yes |
| WKProbeEntSig | dev.ycode.wkprobe.entsig | same, and also in the ad-hoc code signature | yes |
| WKProbeNoLoc | dev.ycode.wkprobe.noloc | none | no |

## 1. Bundle and service layout (level 4)

- SDK: `WeatherKit.framework` is a Swift-only module (`.swiftinterface` for
  arm64 and x86_64 simulator, no headers), install name
  `/System/Library/Frameworks/WeatherKit.framework/WeatherKit`, current
  version 1454.5, language mode 6, library evolution. It imports
  CoreLocation, Foundation, Network and os. `CLLocation` appears in the
  interface under the module `_LocationEssentials` (Core Location's types
  live in a lower-level module that CoreLocation re-exports).
- Runtime: `WeatherKit.framework` carries no visible binary (it is in the
  shared cache) but has 57 localizations and one embedded XPC service,
  `XPCServices/com.apple.weatherkit.authservice.xpc` (bundle type `XPC!`,
  `ServiceType` Application, i.e. one instance per client app, process type
  Adaptive, RunningBoard "Managed" false).
- Private frameworks named Weather, WeatherCore, WeatherDaemon, WeatherData,
  WeatherFoundation, WeatherUI, WeatherMaps, WeatherAnalytics,
  WeatherAppSupport, WeatherResources exist; the Weather app itself is not in
  the simulator runtime, but a WeatherPoster extension is, and it uses the
  same stack (its log lines show the same categories).
- `com.apple.weatherd` LaunchDaemon (`WeatherDaemon.framework/weatherd`, user
  mobile, Adaptive, on demand) vends Mach services `com.apple.weatherd.weatherkit`,
  `.database`, `.notifications`, `.predicted-locations`, `.decommissioning`,
  `com.apple.aps.weather` and a user-notifications delegate, with XPC
  activities for notifications and predicted locations. **It was not
  involved** in any of our third-party requests (no weatherd log lines tied to
  our probe).
- `com.apple.locationd` LaunchDaemon vends, among others,
  `com.apple.locationd.simulation` (the injection point for simulated
  locations), `.registration`, `.synchronous`, `.spi`.

## 2. WeatherKit without the entitlement (WKProbe)

- `WeatherService.shared` is a singleton; `WeatherService()` gives a distinct
  object. Both behave the same.
- `attribution` **succeeds without any entitlement or token**. First call
  2.1 s (an HTTP/3 request from the app process to
  `https://weatherkit.apple.com/attribution/en-US`), later calls 0.03 s, also
  across relaunches of the same app (URL cache). Values: service name "Apple
  Weather"; legal page `https://weatherkit.apple.com/legal-attribution.html`;
  square mark and light/dark combined marks as PNG URLs under
  `https://weatherkit.apple.com/assets/branding/…` (the combined marks are
  per language, `…/en/…`); `legalAttributionText` is a long multi-line plain
  text listing data sources by category (weather models, station data, radar,
  severe-weather alerts) with agency names and URLs, and a copyright line.
- Every data call (`weather(for:)`, each `including:` query, statistics,
  summaries) throws. The error is **not** a `WeatherError`: it is an internal
  Swift error whose reflected type is
  `WeatherDaemon.WDSJWTAuthenticatorServiceProxy.Errors.xpcConnectionFailed`
  carrying an `NSCocoaErrorDomain` 4097 error ("connection to service named
  com.apple.weatherkit.authservice"). Bridged to `NSError`: domain
  `WeatherDaemon.WDSJWTAuthenticatorServiceProxy.Errors`, code 0, empty
  `userInfo`, generic localized description.
- Timing: the first data call 2.4 s; afterwards 2–90 ms each.
- Flow seen in the logs, all **inside the app process** (subsystem
  `com.apple.weather`, categories AuthService, WeatherService,
  WeatherDataService, WK_Geocode, CacheConfig):
  1. decides to authenticate "via com.apple.weatherkit.authservice" because
     the caller is a third-party process;
  2. user agent `WeatherKit_<process name>_iOS_Version 27.1 (Build 24A94401)`;
  3. reverse-geocodes the coordinate through the GEO (Maps) service to obtain
     a place name, time zone and country code; caches the result in memory and
     in `geocode_wk.db` (expiry exactly 5 days after the lookup; key = lat/lon
     to 3 decimals + language + country);
  4. looks in a local SQLite cache (policy "disallows expired data"), per
     product; on miss, builds a request to
     `https://weatherkit.apple.com/api/v2/weather/{lang}/{lat}/{lon}` with
     coordinates rounded to 3 decimals and query items `timezone`,
     `dataSets`, `country`, `deviceLanguages` and an opaque base64
     `clientMetadata` (not recorded);
  5. "Generate new JWT token": opens an XPC connection to
     `com.apple.weatherkit.authservice`; the service starts, receives the
     message, logs a missing-entitlement error naming
     `com.apple.developer.weatherkit`, cancels the connection; the app sees
     4097 and fails without retry ("no fallback cache policy").
- `weather(for:)` with no query asks for the data sets airQuality (twice),
  currentWeather, forecastDaily, forecastHourly, forecastNextHour,
  weatherAlerts, weatherChanges. `including: .current` asks only for
  currentWeather.
- Caches live in `/Library/Weather/` of the simulated device's data
  directory (device-wide, not in the app container): `weather-data.db`
  (tables per product plus "unavailable" twins, `lastFetch`, `metadata`,
  rows keyed by lat/lon/id with `modified`, `expires`, binary model),
  `weather-statistics.db`, `geocode_wk.db`.
- Latitude 200 is not rejected client-side (same error, after a geocode
  attempt). `(0, 0)` reverse-geocodes to an ocean with an empty country code.
- An hourly query whose end date precedes its start date **crashes the app**
  (Foundation `DateInterval` precondition, `EXC_BREAKPOINT`, raised while the
  query is built). A zero-length range is accepted.
- Two concurrent calls fail independently. A task cancelled before it runs
  still ends with the same authentication error, not a cancellation error.
- `WeatherError.permissionDenied` bridges to domain `WeatherKit.WeatherError`
  code 0, `.unknown` to code 1; descriptions are short ("Permission denied",
  "Unknown error"); `permissionDenied` has a failure reason about revoked
  keys, malformed tokens or disallowed operations; other `LocalizedError`
  fields are nil.

## 3. With the entitlement (WKProbeEnt)

- Entitlement in the signature (WKProbeEntSig): **the app does not launch**
  (`simctl launch`: POSIX 3 "No such process", no crash report). Restricted
  entitlements must be delivered through the `__entitlements` section for
  simulator apps.
- Entitlement in the section only: launches; the auth service logs that the
  third-party caller has the correct entitlement and accepts. It then:
  1. loads an AppleMediaServices bag (`https://bag.itunes.apple.com/bag.xml`,
     profile appstored, no active account, falls back to the local account;
     it reads the iTunes Store account type through accountsd);
  2. performs a FairPlay SAP setup
     (`https://fpinit.itunes.apple.com/v1/signSapSetup`; the simulator does
     not provide hardware info but signing still succeeds);
  3. signs a JSON message containing only the bundle identifier, and POSTs a
     token request to `https://weatherkit.apple.com/v3/token` (HTTP/1.1);
  4. the server answers **HTTP 401**; the service reports an invalid JWT
     response.
- The app receives `NSError` domain
  `WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors` code 2, empty
  `userInfo`. First call 2.1 s; each later call 9.6–10.6 s, because the auth
  service process exits after a failure and the next request waits about
  9 s before a new instance (new pid) receives it.
- We did **not** try any bundle identifier other than our own. With a bundle
  ID registered by a paying team with WeatherKit enabled, the token request
  is expected to succeed (public docs say the framework works in the
  simulator); the owner must run that test (see the spec's
  simulator-baseline §5).

## 4. Codable shape (all model types)

The model types have no public initializers; apps can only obtain values
from the service or by decoding. Our probe decoded each type with a
recording decoder (answering every request with a placeholder, and trying
public case names for enums whose raw values are not public), re-encoded the
result with `JSONEncoder`, decoded it again and compared: **every type
round-trips**. Findings (key names only; the spec lists them):

- Dates encode as Foundation's default (seconds since 2001 as a number),
  measurements with Foundation's own encoding (`value` and `unit` with
  `symbol` and `converter{coefficient, constant}`), URLs as strings.
- `WeatherAttribution` encodes as `{storage: {...}}` with seven URL/name
  keys (`serviceName`, `logoURL`, `sourceURL`, `legalPageURL`,
  `squareMarkURL`, `combinedMarkLightURL`, `combinedMarkDarkURL`).
- `WeatherMetadata` encodes `date`, `expirationDate`, `latitude`,
  `longitude`, `attribution`.
- Many types carry non-public keys (current weather: past/next hour, six-hour
  and 24-hour precipitation by type, rainfall and snowfall windows, high/low
  temperature; minute: apparent precipitation intensity; day: humidity and
  wind aggregates, visibility min/max; forecasts: minute conditions and
  summaries, marine location; availability: air quality; alert: id (UUID),
  importance, description, details, issued/onset/end/expiration dates).
- Enums with associated values use Swift's synthesized form
  (`{"caseName": {"_0": …}}`); `WeatherChange.Direction`,
  `Deviation`, `TrendBaseline.Kind` encode as `{"case": {}}`.
- `Weather` encodes `availability`, `currentWeather`, `dailyForecast`,
  `hourlyForecast`, `minuteForecast`, `weatherAlerts`, `weatherChanges` (and,
  if present, further non-public products: air quality, news and others).

## 5. Enum display strings (level 3)

`description` of conditions is title case English ("Mostly Clear"), with a
few names that differ from the case: blowingDust "Dust", foggy "Fog", frigid
"Cold", smoky "Smoke", strongStorms "Severe Thunderstorm", thunderstorms
"Thunderstorm". `accessibilityDescription` is the same in lower case.
`Precipitation.description` is lower case ("rain", mixed "wintry mix", none
the empty string). `WeatherSeverity` descriptions are the lower-case case
names. `PressureTrend`: "Rising", "Falling", "Steady". Moon phases: "New
Moon", …, "Full Moon", "Last Quarter"; `symbolName` is the SF Symbol name
`moonphase.<words>` (e.g. `moonphase.waxing.crescent`, `moonphase.new.moon`).
Compass directions: 16 points, abbreviations N … NNW, descriptions "North
Northeast" etc. UV categories: low 0–2, moderate 3–5, high 6–7, veryHigh
8–10, extreme 11 and up (upper bound `Int.max`).

## 6. Core Location

- `locationServicesEnabled` true; heading not available; significant-change
  monitoring available; beacon ranging not available. Defaults:
  `desiredAccuracy` −1 (best), `distanceFilter` −1 (none). On creation the
  manager calls `locationManagerDidChangeAuthorization` once, on the main
  thread.
- **Not determined, usage string present**: `requestWhenInUseAuthorization`
  shows a system alert titled with the app name and the usage string as
  message, buttons "Allow Once", "Allow While Using App", "Don't Allow" (no
  precise-location map was shown). Status stays notDetermined while the
  alert is up. `requestLocation` and `startUpdatingLocation` issued meanwhile
  fail with `kCLErrorDomain` 1 (denied) about 2 s later. `liveUpdates`
  yields one update flagged "authorization request in progress" and nothing
  else.
- **Granted** (`simctl privacy grant location`): status authorizedWhenInUse,
  accuracy full; `location` already holds the simulated fix.
  - Fixed point (`simctl location set`): `requestLocation` delivers within
    about 50 ms; horizontal accuracy 5 m, altitude 0, vertical accuracy −1,
    speed −1, course −1, floor nil, `sourceInformation.isSimulatedBySoftware`
    true, `isProducedByAccessory` false. `startUpdatingLocation` delivers one
    update, then nothing while the point does not change.
  - Waypoints (`simctl location start --speed=20 --interval=1 …`): one update
    per second; speed exactly 20; course is the bearing of the segment
    (about 51° here, drifting along the great circle); accuracy 5 m; speed
    and course accuracies −1.
  - Scenario "City Run": updates each second near the Infinite Loop campus in Cupertino;
    horizontal accuracy 30 m then 10 m; speed about 3.5 m/s; speed and course
    accuracy 0; floor 0. `requestLocation` did not deliver within 2 s while
    accuracy was 30 m.
  - After `simctl location clear`: the last fix of the previous scenario is
    still delivered (with a stale timestamp), followed by `kCLErrorDomain` 0
    (location unknown); `liveUpdates` reports "location unavailable".
  - `liveUpdates` always starts with an update carrying no location and no
    flags, then real fixes.
- **Revoked** (`simctl privacy revoke location`): status denied, accuracy
  reduced; `requestLocation` fails at once with code 1; `liveUpdates`
  reports "authorization denied".
- **No usage string**: no alert; the framework prints a console message about
  the missing `NSLocationWhenInUseUsageDescription`; status stays
  notDetermined; requests fail with code 1 after about 2 s; `liveUpdates`
  logs an error naming both usage keys and reports "authorization request in
  progress".
- `simctl location list` offers scenarios City Run, City Bicycle Ride,
  Freeway Drive, Apple.
- Reverse geocoding with `CLGeocoder` (deprecated in iOS 26 in favor of
  MapKit) works over the network: Kent, OH, US, America/New_York for our
  point; Cupertino for City Run; 0.15–0.84 s.
