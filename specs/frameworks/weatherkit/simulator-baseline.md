# WeatherKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/weatherkit/`. What a WeatherKit app sees in the
reference simulator (Xcode 27.1, iOS 27.1 runtime 24A94401, device type
iPhone Duo, Apple-silicon Mac). Ycode's simulator runs Apple's own runtime,
so it must reproduce the **conditions** (services, network, entitlements,
caches) under which Apple's framework behaves this way. Statements are
level 3 (our probe `research/experiments/weatherkit/WKProbe`, observations in
`research/notes/weatherkit-simulator-observations-2026-10-19.md`) unless
marked. Core Location behavior is in `location.md`.

## 1. Summary

WeatherKit is one of the frameworks that **does work in Apple's simulator**:
it uses the Mac's network to reach Apple's servers, and it signs its token
requests in software. Whether an app gets weather depends only on its
identity:

| App identity | `attribution` | Weather data calls |
|---|---|---|
| No `com.apple.developer.weatherkit` entitlement | works (no token needed) | every call throws an internal "XPC connection failed" error |
| Entitlement present, bundle ID not registered for WeatherKit (our probe) | works | every call throws an internal "token service listener" error code 2 after the token server answers 401 |
| Entitlement present, bundle ID of a paid team's App ID with WeatherKit enabled | works | expected to return data (level 1; **not tested** — needs the owner's account, §5) |

Neither failure surfaces as `WeatherError`; apps that switch only on
`WeatherError` cases fall into their default branch.

## 2. Request flow (as observable from the device side)

All of steps 1–6 run **in the app's process** (log subsystem
`com.apple.weather`); `weatherd` is not used by third-party apps.

1. **Attribution** (`WeatherService.attribution`): an unauthenticated GET of
   `https://weatherkit.apple.com/attribution/{language}` (HTTP/3), cached by
   the app's URL cache (later calls ~30 ms, also after relaunch).
2. **Location context**: the coordinate is reverse-geocoded through Apple's
   GEO (Maps) service to obtain the country code and time zone (and a place
   name). Results are cached in memory and on disk for 5 days, keyed by the
   coordinate rounded to 3 decimal places, the language and the configured
   country.
3. **Cache lookup**: per data product, a device-wide SQLite cache is
   consulted; expired entries are not used. A full hit returns without
   network access.
4. **Data request**: on a miss, one GET to Apple's private v2 endpoint
   `https://weatherkit.apple.com/api/v2/weather/{language}/{lat}/{lon}` with
   the coordinates rounded to 3 decimals and query items `timezone`,
   `dataSets` (comma-separated product names), `country`, `deviceLanguages`
   and an opaque client-metadata blob. The user agent is
   `WeatherKit_<process name>_iOS_Version <OS version> (Build <build>)`.
   `weather(for:)` without queries asks for currentWeather, forecastDaily,
   forecastHourly, forecastNextHour, weatherAlerts, weatherChanges and the
   non-public airQuality; a single `including:` query asks for its product
   only. (The public REST API, `rest-api.md`, is the documented v1 form of
   the same service.)
5. **Token**: before the data request, the framework asks the per-app XPC
   service `com.apple.weatherkit.authservice` for a JWT:
   1. the service checks that the **calling process** holds
      `com.apple.developer.weatherkit`; if not, it logs the missing
      entitlement, cancels the connection and the app sees an XPC
      interruption (Cocoa error 4097);
   2. otherwise it loads an AppleMediaServices "bag"
      (`bag.itunes.apple.com`, falling back to the local account when no
      Apple ID is signed in), performs a FairPlay SAP setup with
      `fpinit.itunes.apple.com`, signs a small JSON message containing only
      the **bundle identifier**, and POSTs it to
      `https://weatherkit.apple.com/v3/token`;
   3. a 401 answer becomes the error of §1. After a failure the service
      process exits; the next request waits about 9 s for a fresh instance,
      so failing calls after the first take ~10 s each.
6. **Failure handling**: no retry for authentication failures, and no
   fallback to expired cache data ("no fallback cache policy"); the error is
   thrown to the caller.

The token request carries the bundle ID and a FairPlay signature but no team
identifier; the server decides from its App ID registry. We did not and must
not try a bundle ID that belongs to someone else.

## 3. Observed API behavior without a token

- `WeatherService.shared` is a singleton; `WeatherService()` creates
  independent instances with identical behavior.
- Errors (bridged to `NSError`, all with empty `userInfo` and a generic
  localized description):

| Situation | Domain | Code |
|---|---|---|
| No entitlement | `WeatherDaemon.WDSJWTAuthenticatorServiceProxy.Errors` | 0 (Swift case `xpcConnectionFailed`, carrying Cocoa error 4097) |
| Entitlement, token refused | `WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors` | 2 |
| (`WeatherError.permissionDenied` as `NSError`) | `WeatherKit.WeatherError` | 0 |
| (`WeatherError.unknown` as `NSError`) | `WeatherKit.WeatherError` | 1 |

- Timing: first data call ≈ 2.1–2.4 s (attribution, geocode and cache set-up
  included); without entitlement, later calls fail in 2–90 ms.
- Invalid coordinates (latitude 200) are not rejected locally; they fail the
  same way.
- An hourly or daily query built with an end date **before** its start date
  **crashes the app** when the query is constructed (Foundation
  `DateInterval` precondition). A zero-length range is accepted.
- Concurrent calls are independent; a task cancelled before it starts still
  finishes with the authentication error rather than `CancellationError`
  (failure path only; the success path was not observable).
- An ad-hoc code signature that itself carries the restricted entitlement
  prevents the app from launching at all; simulator builds must carry
  entitlements in the `__TEXT,__entitlements` section (what Xcode does).
- Codable, enum descriptions and other offline behavior: `behavior.md`,
  `codable.md`.

## 4. Files the framework writes

Device-wide (in the simulated device's data directory, not the app
container): `/Library/Weather/weather-data.db`,
`/Library/Weather/weather-statistics.db`, `/Library/Weather/geocode_wk.db`
(SQLite, WAL mode; level 2: one table per product plus "unavailable" twins,
rows with `modified`/`expires` times). The app's own `Library/Caches` and
`Library/HTTPStorages` hold the URL cache. Ycode needs only to allow these
writes; the formats are internal and need not be reproduced.

## 5. What the owner must provide to test the entitled path

Nothing here was done; it needs the owner's Apple developer account and must
be done by the owner (agents never sign in).

1. A **paid Apple Developer Program** membership (team).
2. An **explicit App ID** for a bundle ID the team owns (e.g. a
   `dev.ycode.*` identifier registered by the owner), with WeatherKit enabled
   on **both** the App Services tab and the Capabilities tab (level 1, Apple
   account help).
3. The probe carrying that bundle ID and the WeatherKit entitlement in its
   simulator `__entitlements` section: `OWNER_BUNDLE_ID=<id> WKProbe/build.sh
   OUTDIR` builds `WKProbeOwner.app` (ad-hoc signed, as all simulator test
   builds here). Our observation is that the token request identifies the
   app only by bundle ID; if the server also wants a team-signed build, build
   the same source in Xcode with automatic signing for the owner's team and
   the WeatherKit capability instead.
4. Patience after enabling: the service may reject the ID until the change
   propagates (level 1 guidance is informal; plan for some minutes).
5. For the REST API tests (`rest-api.md`): a **WeatherKit key** (`.p8`, its
   10-character Key ID), a **Services ID**, and the **Team ID**. The key
   goes into the owner's credential store (`get-key`), never into the
   repository; tests read it at run time.
6. Calls count against the team's monthly quota (500 000 included).

With that, rerun `WKProbe -mode weather` and record: per-query results and
timings, cache-hit timing on repeat, `WeatherMetadata` dates (expiry per
product), availability for a region with and without minute forecasts and
alerts, and the `Codable` JSON of real values.

## 6. What Ycode's simulator must provide

For WeatherKit (Apple's framework running in Ycode's guest):

| Need | Why | Check |
|---|---|---|
| Outbound HTTPS from guest processes through the host: DNS, TCP, **QUIC/HTTP3** (UDP 443) and HTTP/1.1, system trust store (`trustd`) | attribution, data, token, bag, FairPlay and GEO requests | W-ATTR succeeds |
| Launch of **framework-embedded per-app XPC services** (`ServiceType` Application) on demand, with RunningBoard identity resolution of the service as belonging to the app | `com.apple.weatherkit.authservice` | W-NOENT error is the XPC-interruption error, not a hang |
| **Peer entitlement checks** that see entitlements from the `__entitlements` section of simulator apps | the auth service accepts or rejects the caller | W-ENT reaches the token request |
| Relaunch of an exited XPC service on the next message (with the same ~9 s gap only if we want timing parity) | auth service exits after failures | W-ENT-REPEAT |
| AppleMediaServices dependencies: `accountsd` (no account is fine), cfprefsd, the FairPlay software path the simulator runtime already contains | token signing | W-ENT log shows "Signed successfully" |
| GEO services (`geod` and network access to Apple's GEO servers) | reverse geocoding before every uncached request | W-GEO |
| Writable device-wide `/Library/Weather/` and the app container's caches | SQLite caches | second call is a cache hit (entitled path) |
| Time zone database and locale/language settings | `timezone`, language and `deviceLanguages` parameters | request URL in the log matches the device settings |
| The `__entitlements` section honored for **launch** while code signatures stay ad-hoc | apps built by Ycode for the simulator | W-LAUNCH-ENT |

For location, see `location.md` §6.

## 7. Conformance checklist

Run each in Apple's simulator to produce goldens, then in Ycode's guest; the
output must match after normalizing times, pids, UUIDs and timings.

| Id | Probe | Expected |
|---|---|---|
| W-ATTR | `WKProbe -mode weather`, attribution line | service name "Apple Weather"; legal page and three mark URLs under `weatherkit.apple.com`; non-empty multi-line legal text; repeat call fast |
| W-NOENT | `WKProbe -mode weather` (no entitlement) | every data call throws domain `…AuthenticatorServiceProxy.Errors` code 0; log shows the service rejecting the missing entitlement |
| W-ENT | `WKProbe` built as the Ent variant | first call throws `…AuthenticatorServiceListener.Errors` code 2 after a 401 from the token endpoint |
| W-ENT-REPEAT | same, second and third calls | same error; a new auth-service process each time |
| W-LAUNCH-ENT | launch the EntSig variant | launch fails with "No such process"; the Ent variant launches |
| W-GEO | log of W-NOENT | reverse geocode succeeds (place name, time zone, country) before the data request |
| W-TRAP | `WKProbe -mode trap` | app crashes in `DateInterval` construction |
| W-CODABLE | `WKProbe -mode codable` | identical output (all types round-trip; key sets as `codable.md`) |
| W-ERRORS | weather mode, `WeatherError` lines | domains/codes and descriptions as §3 |
| W-DATA (owner) | weather mode with an entitled, registered bundle ID | all queries succeed; repeat call served from cache; metadata expiry after date |
| L-* | location probes | see `location.md` §7 |

## Evidence

| Claim | Level |
|---|---|
| Behavior tables §1, §3; flow §2 (as seen in the system log while our probe ran); file locations §4 | 3 |
| Service names, XPC service type, launchd keys | 2/4 (runtime plists) |
| Server-side App ID check and that registered apps get data in the simulator; App ID set-up steps; quota | 1 |
| Requirements §6 | derived from 3 |
