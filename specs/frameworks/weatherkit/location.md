# WeatherKit spec: Core Location for weather apps

Part of `specs/frameworks/weatherkit/`. A weather app needs a coordinate.
This file covers the Core Location behavior such apps rely on and the
simulated-location machinery Ycode's simulator must reproduce. It is not a
full Core Location spec. Statements are level 3 (WKProbe in the reference
simulator) unless marked; API names are interop facts.

## 1. API surface used by weather apps (level 1/4)

- `CLLocationManager`: `authorizationStatus`, `accuracyAuthorization`,
  `requestWhenInUseAuthorization()`, `requestAlwaysAuthorization()`,
  `requestLocation()`, `startUpdatingLocation()`/`stopUpdatingLocation()`,
  `location` (last fix), `desiredAccuracy`, `distanceFilter`; class queries
  `locationServicesEnabled()`, `headingAvailable()`,
  `significantLocationChangeMonitoringAvailable()`, `isRangingAvailable()`.
- `CLLocationManagerDelegate`: `locationManagerDidChangeAuthorization(_:)`,
  `locationManager(_:didUpdateLocations:)`,
  `locationManager(_:didFailWithError:)`.
- `CLLocationUpdate.liveUpdates()` (iOS 17): async sequence of updates with
  optional `location` and flags `authorizationDenied`,
  `authorizationDeniedGlobally`, `authorizationRequestInProgress`,
  `insufficientlyInUse`, `stationary`, `locationUnavailable`,
  `accuracyLimited`, `serviceSessionRequired`.
- `CLLocation`: coordinate, `horizontalAccuracy`, `altitude`,
  `verticalAccuracy`, `speed`, `speedAccuracy`, `course`, `courseAccuracy`,
  `floor`, `timestamp`, `sourceInformation`
  (`isSimulatedBySoftware`, `isProducedByAccessory`). Negative accuracy
  means "invalid".
- Info.plist usage keys: `NSLocationWhenInUseUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`.
- Errors: `kCLErrorDomain` code 0 `locationUnknown`, code 1 `denied`.
- Reverse geocoding: `CLGeocoder.reverseGeocodeLocation` (deprecated in
  iOS 26 in favor of MapKit's reverse-geocoding request) returning
  placemarks with locality, administrative area, ISO country code, time zone,
  name. WeatherKit itself needs no app-side geocoding; apps use it to show a
  place name.

## 2. Defaults and capability answers

`locationServicesEnabled` YES; `headingAvailable` NO;
`significantLocationChangeMonitoringAvailable` YES; `isRangingAvailable`
NO; `desiredAccuracy` −1 (best); `distanceFilter` −1 (none). A new manager
calls `locationManagerDidChangeAuthorization` once, on the main thread,
shortly after creation.

## 3. Authorization

| State (how reached) | `authorizationStatus` / accuracy | `requestWhenInUseAuthorization` | `requestLocation` | `liveUpdates` |
|---|---|---|---|---|
| Fresh install, usage string present | notDetermined / full | shows the prompt (§3.1); status unchanged while it is up | fails with code 1 about 2 s later while the prompt is pending | one update flagged "request in progress", then silence |
| Fresh install, **no** usage string | notDetermined / full | no prompt; a console message names the missing key | fails with code 1 about 2 s later | logs an error naming both usage keys; one update flagged "request in progress" |
| `simctl privacy … grant location` | authorizedWhenInUse / full | no prompt, no change | delivers a fix (§4) | first an empty update (no location, no flags), then fixes |
| `simctl privacy … revoke location` | denied / reduced | no prompt | fails immediately with code 1 | one update flagged "denied" |

`simctl privacy` also offers `location-always` and `reset`; granting or
revoking may terminate the running app (simctl's own help, level 1).

### 3.1 The prompt

A system alert over the app: title "Allow “<app name>” to use your
location?", message = the usage string, three stacked buttons "Allow Once",
"Allow While Using App", "Don't Allow". On the iPhone Duo device type no
precise-location map or toggle was shown. (Screenshot in
`research/dirty/weatherkit/loc-prompt.png`.)

## 4. Simulated locations

The host drives the device's location through `simctl location`
(Xcode's Debug ▸ Simulate Location and the Simulator app use the same
mechanism). Inside the runtime the injection point is locationd's
`com.apple.locationd.simulation` Mach service (level 2, launchd plist).

| Host command | Effect on an authorized app |
|---|---|
| `set <lat>,<lon>` | Fix at that point: horizontal accuracy 5 m, altitude 0, vertical accuracy −1, speed −1, course −1, speed/course accuracy −1, floor nil, `isSimulatedBySoftware` YES, `isProducedByAccessory` NO. `requestLocation` answers within ~50 ms; `startUpdatingLocation` delivers once and then stays silent while the point is unchanged. |
| `start [--speed=m/s] [--distance=m | --interval=s] <wp1> … <wpN>` | Moves along the waypoints (default 20 m/s, one update per second): each fix has `speed` equal to the requested speed, `course` = bearing of the current segment (it drifts slightly along a long segment, i.e. great-circle bearing), horizontal accuracy 5 m, speed/course accuracy −1. |
| `run <scenario>` | Built-in recorded tracks: "City Run", "City Bicycle Ride", "Freeway Drive", "Apple". City Run: one fix per second around the Infinite Loop campus in Cupertino, horizontal accuracy 30 m then 10 m, speed ≈ 3.5 m/s varying, speed and course accuracy 0, floor 0. `requestLocation` waits while accuracy is poor (no fix within 2 s at 30 m). |
| `clear` | Stops the scenario. The last fix is still delivered once with a stale timestamp, then `didFailWithError` code 0 (location unknown); `liveUpdates` flags "location unavailable". |
| `list` | Lists the scenario names above. |

Coordinates use `.` as decimal separator and `,` between latitude and
longitude (level 1, simctl help).

## 5. Reverse geocoding

`CLGeocoder` works in the simulator through Apple's GEO servers over the
Mac's network: 0.15–0.8 s per lookup, returning locality, administrative
area, country code, time zone and a street-level name. WeatherKit performs
its own reverse geocoding in-process before each uncached weather request
(`simulator-baseline.md` §2), so GEO access is needed even by apps that never
geocode.

## 6. What Ycode's simulator must provide

| Need | Notes |
|---|---|
| locationd running, with its simulation service fed from the host | Ycode's equivalent of `simctl location set/start/run/clear/list`, including interpolation along waypoints at a given speed with interval or distance spacing, and course/speed values as §4 |
| The built-in scenarios | Ycode must ship **its own** recorded tracks (the reference scenarios are Apple resources); keep the names only if they are needed for script compatibility, with Ycode-made data |
| tccd privacy database and `simctl privacy grant/revoke/reset location[-always]` | grant/revoke without prompting; reset brings the prompt back |
| SpringBoard's location authorization alert | shown over the app; Ycode's input path must be able to press its buttons (HID taps) |
| GEO services and network | reverse geocoding by apps and by WeatherKit |
| Location marked as simulated | `sourceInformation.isSimulatedBySoftware` YES, as in the reference |

## 7. Conformance checklist

All with `WKProbe -mode location -wait N` (golden = reference simulator).

| Id | Set-up | Expected |
|---|---|---|
| L-PROMPT | fresh install, `location set` | prompt with three buttons; status notDetermined; code 1 errors; screenshot matches in layout |
| L-NOPLIST | `WKProbeNoLoc` | no prompt; missing-key console message; code 1 errors |
| L-FIXED | `privacy grant`, `location set` | one fix with the §4 values; no repeats while stationary |
| L-ROUTE | `location start --speed=20 --interval=1` with three waypoints | ~1 update/s, speed 20, course ≈ segment bearing |
| L-SCENARIO | `location run "City Run"` with Ycode's own track | per-fix accuracies, speed and floor shaped as §4 (values from Ycode's track) |
| L-CLEAR | `location clear` after a scenario | stale last fix, then code 0; live update "location unavailable" |
| L-DENIED | `privacy revoke` | status denied/reduced; immediate code 1; live update "denied" |
| L-LIVE | granted | first live update empty, then fixes |
| L-GEOCODE | granted, fixed point | reverse geocode returns locality, country, time zone |
| L-WEATHER | granted | WeatherKit call for the fix fails/succeeds exactly as `simulator-baseline.md` §1 for the app's identity |

## Evidence

| Claim | Level |
|---|---|
| API names, usage keys, error codes, deprecation of `CLGeocoder` | 1/4 |
| `simctl location`/`privacy` syntax and scenario list | 1 (tool help), 3 |
| Values and sequences in §2–§5 | 3 |
| locationd simulation service name | 2 |
