# MapKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/mapkit/`. This is what a MapKit app sees in the
reference simulator (Xcode 27.1; iOS 27.1 runtime 24A94401 on an iPhone Duo,
466 × 678 pt, safe-area insets (0, 0, 34, 84); iOS 27.0 runtime 24A434 on
an iPhone 18 Pro, 402 × 874 pt, insets (62, 0, 34, 0); Apple-silicon Mac
with internet access). Ycode's simulator must behave the same way.
Statements are level 3 (our probe `research/experiments/mapkit/MKProbe`,
observations in `research/notes/mapkit-simulator-observations-2026-10-19.md`)
unless marked.

## 1. Summary

MapKit is **fully functional** in the simulator, with **no Apple account,
team, entitlement, key or token**. The probe is ad-hoc signed with no
entitlements; maps render (standard, muted, imagery, hybrid, 3D, globe,
dark), and search, completion, directions (except transit routes), ETA,
geocoding, Look Around and snapshots all return live results from Apple's
servers. Everything that needs data goes **out of the app process to the
`geod` daemon, which talks HTTPS to Apple's map servers through the host's
network**. Rendering happens **inside the app process with Metal** (and in
the snapshot XPC service for `MKMapSnapshotter`).

The two runtimes return the same answers for every API call we made
(services, geometry, snapshot geometry, Look Around, errors). Differences:

| | iOS 27.1 (24A94401) | iOS 27.0 (24A434) |
|---|---|---|
| `Maps.app` | **absent** (level 2: not in `RuntimeRoot/Applications`) | present |
| `canOpenURL("maps:")` | NO | YES (`open(maps://…)` completes YES in 0.25 s) |
| `openInMaps` / `openMaps(with:)` / `maps://` URL | completion NO within 0.03 s; app stays in front | completion YES; Maps opens, `destinationd` and `mapspushd` start |
| `https://maps.apple.com/…` URL | opens **Safari** (completion YES, app backgrounds) | not exercised (expected: Maps) |
| Map daemons (`geod`, `navd`, …) | same launchd jobs (level 2) | same |
| First map on a fresh device | rendered in ≈1.2–2 s | first render took 23 s and logged `mapViewDidFailLoadingMap` with `NSURLErrorDomain` −1001 (time-out) once, then normal |
| Synthetic touch input (our `hidsend`) | did **not** reach the map on the iPhone Duo (§4.4) | pan, fling, double-tap zoom work |

## 2. Processes, services and network

### 2.1 Who does what

| Piece | Where | Role |
|---|---|---|
| App process | MapKit, VectorKit-class renderer, GeoServices client | builds requests, renders tiles with Metal, owns annotation/overlay views |
| `geod` (`GeoServices.framework/geod`) | launchd job `com.apple.geod`, user `mobile`, demand-launched (spawn type Adaptive, pressured exit, `StartInterval` 432,000 s) | the only network client for map data: resource manifest, styles, icons, fonts, tiles, search, directions, geocoding, Look Around; on-disk caches |
| `com.apple.MapKit.SnapshotService` | XPC service bundled in `MapKit.framework/XPCServices` (service type System) | renders `MKMapSnapshotter` images out of process (looked up only in snapshot mode) |
| `com.apple.MTLCompilerService` | XPC service | compiles the renderer's Metal shaders (looked up in snapshot and Look Around modes) |
| `geoanalyticsd` | launchd job `com.apple.geoanalyticsd`, user `mobile` | analytics; the app looks it up on every map use; not needed for results |
| `locationd` | launchd job `com.apple.locationd` (run at load, keep-alive) | user location and its simulation (`com.apple.locationd.simulation`), registration and synchronous services used by the app |
| `tccd` | — | location authorization |
| `navd`, `destinationd`, `mapspushd`, `mapssyncd`, `geocorrectiond` | launchd jobs (level 2) | Maps-app and navigation support; not contacted by a MapKit app in our runs (`destinationd` and `mapspushd` started only when the Maps app opened on 27.0) |

### 2.2 Mach and XPC services an app process uses (level 3, our `svctrace` interposer)

Map-specific: `com.apple.geod` (several connections per process),
`com.apple.geoanalyticsd`, `com.apple.locationd.registration`,
`com.apple.locationd.synchronous`, `com.apple.tccd`, XPC services
`com.apple.MapKit.SnapshotService` and `com.apple.MTLCompilerService`.
GPU and display: `com.apple.metal.simulator` (and a per-app lookup
`com.apple.metal.simulator.<app name>` that **fails** with kr 1102, not
found, every time — harmless), `com.apple.IOSurface.Remote`,
`com.apple.CARenderServer`. Generic app plumbing (also used by non-map
apps): `com.apple.cfprefsd.daemon`, `com.apple.fontservicesd`,
`com.apple.lsd.mapdb`, `com.apple.lsd.open`, `com.apple.runningboard`,
`com.apple.backboard.display.services`, `com.apple.backboard.hid.services`,
`com.apple.logd`, `com.apple.system.notification_center`,
`com.apple.distributed_notifications@1v3`,
`com.apple.uiintelligencesupport.agent`.

Darwin notifications the app registers for when MapKit loads (level 3):
`GEODaemonDidStartDarwinNotification`,
`kGEORegionalResourcesTileRequesterDidDownloadNotification`,
`com.apple.GeoServices.ActiveTileGroupChanged.internal`,
`com.apple.GeoServices.experimentsChanged`,
`com.apple.GeoServices.internal.networkDefaultsChanged`,
`com.apple.GeoServices.countryProvidersChanged`,
`com.apple.GeoServices.TileLoader.didDeleteExternalData`,
`com.apple.GeoServices.SubscriptionsDidChange`,
`com.apple.GeoServices.FullyDownloadedSubscriptionsDidChange`,
`com.apple.GeoServices.additionalEnabledMarketsChanged`,
`com.apple.GeoServices.internal.searchAttributionManifestUpdated`,
`com.apple.geo.place_request_extras_updated`,
`com.apple.locationd.registration`, `com.apple.system.timezone`,
`com.apple.system.SystemConfiguration.nwi`,
`com.apple.system.networkd.settings`.

### 2.3 launchd jobs (level 2, the runtime's `LaunchDaemons` plists read as files)

| Label | Mach services | Notes |
|---|---|---|
| `com.apple.geod` | `com.apple.geod`, `com.apple.geod.cachedelete`, `com.apple.private.alloy.geoservices-idswake` | user `mobile`; launch events: a daily background task `com.apple.geod.telemetry.daily`, notify matches on preference and privacy-reset notifications. In the booted simulator the job lives in the **user domain** (`user/501/com.apple.geod`), not `system/` |
| `com.apple.geoanalyticsd` | `com.apple.geoanalyticsd` | user `mobile`, demand |
| `com.apple.locationd` | 18 services incl. `com.apple.locationd.registration`, `.synchronous`, `.simulation`, `.spi` | run at load |
| `com.apple.navd` | `com.apple.navd`, `com.apple.navigationServer`, `com.apple.navigationService`, `com.apple.navigationListener`, `com.apple.navd.commuteroute`, … | run at load, keep-alive on the path `…/Caches/GeoServices/Navd/working` |
| `com.apple.maps.destinationd` | `com.apple.maps.destinationd.{donations,predictions,signalPipeline,sources}` | demand |
| `com.apple.Maps.mapssyncd` | `com.apple.Maps.MapsSync.{cache,service,store,xpc}` | demand |
| `com.apple.Maps.pushdaemon` | `com.apple.Maps.mapspushd`, `com.apple.Maps.xpc.*` | demand |
| `com.apple.Maps.geocorrectiond` | none | demand |

### 2.4 Entitlements and Info.plist keys

- No entitlement is needed for any MapKit API in the simulator (probe
  signed ad hoc with an empty entitlement set).
- `NSLocationWhenInUseUsageDescription` is needed only for
  `showsUserLocation`, user tracking and `MKMapItem.forCurrentLocation()`
  routing (Core Location's rule; `../weatherkit/location.md`).
- `LSApplicationQueriesSchemes` containing `maps` is needed for
  `canOpenURL("maps:")` to answer truthfully.
- There is no MapKit key, token or Info.plist setting for the native
  framework (MapKit JS tokens are a web product, not used).

### 2.5 Network endpoints (level 3, `geod`'s own log)

All map traffic is HTTPS from `geod` (never from the app). Hosts contacted
during one full probe run (counts are connections in our run):

| Host family | Role (from the request kind it served) |
|---|---|
| `gspe19-ssl.ls.apple.com`, `gspe19-2-ssl…`, `gspe19-kittyhawk-ssl…`, `gspe11-ssl…`, `gspe12…`, `gspe21…`, `gspe35…`, `gspe72…`, `gspe76…`, `gspe79…`, `gspe85…`, `gspe92…`, `gspe121…` (`*.ls.apple.com`) | vector tiles, imagery, 3D, terrain and resource downloads |
| `gsp-ssl.ls.apple.com`, `gsp10-ssl…`, `gsp36…`, `gsp47…`, `gsp51…`, `gsp53…`, `gsp64…`, `gsp85…` | place data, search, directions |
| `gsp57-ssl-revgeo.ls.apple.com`, `gsp57-ssl-locus…`, `gsp57-ssl-bcx…`, `gsp57-ssl-background…`, `gsp-ssl-commute…` | reverse geocoding and background services |
| `sundew.ls.apple.com` | analytics |
| `gsp9-ssl.apple.com`, `cdn.apple-mapkit.com`, `maps.apple.com`, `maps.apple`, `mapsconnect.apple.com` | configuration, attribution and legal links |

Protocols: HTTP/2 and HTTP/1.1 over TLS (ALPN `h2` and `http/1.1`), and
QUIC was attempted/used (the network stack logged QUIC connections). The
**list of hosts is not fixed**: it comes from the resource manifest that
`geod` downloads first. Ycode must provide general outbound internet
access, not an allow-list.

Volume (one run, cold for the San Francisco area): the configurations
mode made 300 requests and received 15.8 MB; Look Around 3.4 MB; snapshots
1.7 MB; search 1.0 MB. Re-displaying an area already seen made only 2–3
requests (304/200 for configuration) — **tiles are served from geod's disk
cache**.

### 2.6 On-disk state (in the device's data directory)

`Library/Caches/GeoServices/` (73 MB after the runs: `ResourceManifest.pbd`,
`ActiveTileGroup.pbd`, `Experiments.pbd`, `networkDefaults.plist`,
`Resources/`, `RegionalResources/`, `Attribution/`, `SearchAttribution*`,
`DirectReadConfigStore.plist`) and `Library/Caches/com.apple.geod/`
(27 MB: the tile cache). Names are interop facts for a Ycode guest's
writable filesystem; the contents are Apple's data and are never copied.

## 3. Rendering

1. The map content is a Metal layer hosted by `_MKMapLayerHostingView`
   inside `MKBasicMapView` inside `_MKMapContentView`; above it an
   `MKScrollContainerView` (a huge virtual scroll surface,
   33,972,863 pt square in our run), the `MKAnnotationContainerView`, and
   touch pass-through views. Ornaments are siblings: `MKAppleLogoLabel`
   (10, 607.91, 50.25 × 39.09 on the 466 × 678 view), `MKAttributionLabel`
   ("Legal", 70.25, 623.26, 28.58 × 10.74) and a compass (`MKCompassView`
   44 × 44 in a pass-through stack at (322, 170)) — all inside the safe area.
2. GPU path: the app looks up `com.apple.metal.simulator` and
   `com.apple.IOSurface.Remote` as soon as a map view exists; Metal shader
   compilation goes to `com.apple.MTLCompilerService`. **Without Metal in
   the app process no map can draw** — this is the same Metal→Vulkan layer
   that Ycode's simulator needs for every app (stage 8a).
3. Rendering does not need the network for areas already cached; for new
   areas the tile requests go through `geod`.
4. Configurations (screenshots, level 3): standard flat, standard
   realistic (3D buildings, trees, landmarks at 900 m / 60° pitch), muted,
   imagery flat, imagery realistic (textured 3D city), hybrid realistic,
   dark appearance (with traffic and with POIs hidden), and at 20,000 km the
   imagery look is a globe with atmosphere and day/night terminator while
   standard realistic and flat show a flat world. Each took 1.3–2.2 s to
   render fully with a warm cache.

## 4. Behavior by area

### 4.1 Map view life cycle

`interface.md` §3.4 lists the callback sequences. Baseline facts:
first full render ≈0.3–0.8 s after `setRegion` with a warm cache, 1.2–2 s
cold; moving to another city ≈0.5–0.8 s; **returning to an area still in
memory produces no loading or rendering callbacks** (a wait for
`didFinishRenderingMap` timed out after 41 s on both runtimes).

### 4.2 Viewport and camera

Deterministic and identical on both runtimes for the same view size:
`geometry.md` §§6–7.

### 4.3 Annotations, clustering, overlays

`interface.md` §4: default marker view 31.33 × 34.94 pt; a cluster of 20
markers within ≈90 m shows one red balloon with the glyph "20", title "C1"
(a member's title) and subtitle "+19 more"; programmatic selection
enlarges the marker; overlays at `.aboveRoads` and `.aboveLabels`.

### 4.4 Touch input

On the 27.0 iPhone 18 Pro (402 × 874), with our `hidsend` driver (ratio
coordinates, 20 move steps unless noted, map at 4.39 m per point):

| Gesture | Effect |
|---|---|
| horizontal drag 0.3 → 0.7 of the width (160.8 pt) | map center moved 145.8 pt the opposite way (≈15 pt lost to the pan threshold), 54 per-frame region callbacks, one `regionWillChange`/`regionDidChange` pair (animated NO) |
| vertical drag 0.4 → 0.6 of the height (174.8 pt) | 231.5 pt (release with residual velocity: deceleration adds distance) |
| fling (3 steps, same distance) | 570.5 pt (deceleration), plus loading and rendering callbacks |
| double tap at 0.25, 0.30 | zoom in by 2.32 × (width ratio 0.4313), centered towards the tapped point |
| double tap at the center | no change (our two taps were too far apart in time to count as a double tap) |
| long press (60 steps, no move) | no camera change, no selection |
| drag starting at the left edge with the left-edge flag | panned like a normal drag (212.2 pt) — no system gesture in an app |

On the 27.1 **iPhone Duo** the same events reached SpringBoard (a drag
changed the home-screen page) but **not the probe's map or SwiftUI
markers** (no region change; taps on markers selected nothing); likely a
display/digitizer routing issue of the foldable device type in our driver
(see `research/notes/hid-input-observations.md`). Recorded as an open
question, not as MapKit behavior.

### 4.5 SwiftUI `Map`

Renders like `MKMapView` (same tiles, same callbacks underneath); the
camera answers are in `geometry.md` §10. `.automatic` frames the content;
`.userLocation(fallback:)` first shows the fallback, then the simulated
fix ≈30 ms later.

### 4.6 Look Around

Covered street corner (Union Square, SF) → scene in 0.1–0.25 s; open ocean
and Reykjavik → nil without error; invalid coordinate → `MKErrorDomain` 1
at once; Look Around snapshot 300 × 200 in 1.3–2.5 s at scale 3; the view
controller presents a street-level panorama (3.4 MB of downloads).
Identical on 27.0.

### 4.7 Snapshots

`geometry.md` §9 and `interface.md` §8. First snapshot of a process
≈1.3 s (27.1) / 7.3 s (27.0 cold); later ones 0.3–0.5 s; four in parallel
3.1 s total; cancel suppresses the completion; 6000 × 6000 fails with
code 1; zero size raises.

### 4.8 Location (Core Location dependency)

1. MapKit's user location is Core Location's: authorization (`simctl
   privacy grant location`, status 4 when-in-use) and the simulated
   location (`simctl location set`, or Xcode's scheme option) are what the
   map shows. The fix arrives ≈20 ms after `showsUserLocation = YES`,
   accuracy 5 m, `isSimulatedBySoftware` YES, speed and course −1, no
   heading.
2. Changing the simulated location: `didFailToLocateUser` with
   `kCLErrorDomain` 0 (transient), then `didUpdate` with the new fix;
   follow mode animates the camera there.
3. `simctl location clear`: the last fix stays (`userLocation` keeps the
   old coordinate and `isUpdating` YES); no new update arrives.
4. Services: search, geocoding and directions take **no** location from the
   device unless the app passes it, except that (a) requests without a
   region are biased by the **host's network position** on the server
   side (search with `.physicalFeature`, forward geocoding "Apple Park"
   without a region answered places ≈3,500 km away near the Mac's real
   location), and (b) `MKMapItem.forCurrentLocation()` as a directions
   source is resolved to the current simulated fix at request time.
5. `forCurrentLocation()` read directly (after `location clear`): name
   "Unknown Location", coordinate (−180, −180), `isCurrentLocation` YES —
   the item is a placeholder that services resolve.
6. The heading-based follow mode is accepted (mode 2) but heading stays nil.

## 5. Opening other apps

| Call (27.1) | Result |
|---|---|
| `canOpenURL` `maps://?q=coffee`, `maps:` | NO |
| `canOpenURL` `http://maps.apple.com/?q=…`, `https://maps.apple.com/place?…` | YES (Safari handles them) |
| `canOpenURL` `geo:…`, `comgooglemaps://` | NO |
| `MKMapItem.openInMaps(launchOptions:from:completionHandler:)` | completion NO after 0.03 s; app stays active |
| `MKMapItem.openMaps(with:launchOptions:)` with directions mode | returns NO after 0.015 s |
| `open(maps://…)` | completion NO after 0.007 s |
| `open(https://maps.apple.com/…)` | completion YES after 0.38 s; app resigns active; Safari launches |

On 27.0 `maps:` URLs are openable and `openInMaps` completes YES in
0.32 s with the Maps app in front.

## 6. Failure and offline behavior

| Situation | Result |
|---|---|
| `MKTileOverlay` with `canReplaceMapContent` YES and an unresolvable host | the map shows MapKit's **empty grid** (light beige with grid lines), the "Legal" link stays, the Apple Maps logo is hidden; `didFinishRenderingMap(fullyRendered: YES)` anyway, no `didFailLoadingMap`; `loadTile(at:)` fails with `NSURLErrorDomain` −1003 |
| `geod` removed from launchd while the app runs (`launchctl bootout`) | `MKLocalSearch` fails in 0.03 s with `MKErrorDomain` 1 (`MKErrorGEOError` in userInfo); moving the map to an uncached city (Paris) shows the **empty grid** with the logo and `didFinishRenderingMap(fullyRendered: NO)`; no `didFailLoadingMap`; a device reboot brings `geod` back |
| cold cache and slow network (27.0 first boot) | `mapViewDidFailLoadingMap` with `NSURLErrorDomain` −1001 after ≈21 s, then the map loaded on later requests |
| area already cached | renders with almost no requests (§2.5) |
| transit directions | `calculate` fails client-side in 0.000 s with code 5 on both runtimes; transit ETA works |

**Not observed:** a real network outage (the host network cannot be cut
without administrator rights; the Network Link Conditioner "100% loss"
profile would do it). The expected shape from the observations above —
grid map, cached areas still drawn, service calls failing with
`MKErrorDomain` codes carrying an underlying GEO error — is a hypothesis
for round R1 to confirm.

### 6.1 What works offline vs needs network

| Feature | Needs network | Needs an account |
|---|---|---|
| Geometry, camera math, conversions, distance formatting | no | no |
| Annotation and overlay views, clustering | no | no |
| Map tiles | yes for areas not in `geod`'s cache; cached areas draw | no |
| Styles, icons, fonts (first map on a device) | yes, once (≈45 MB of resources) | no |
| Search, completion, POI request, geocoding, directions, ETA, Look Around | yes, every request | no |
| Snapshots | as tiles (rendered locally from cached or fetched tiles) | no |
| User location | no (simulated by `locationd`) | no |
| Opening Maps | 27.0 only (local app) | no |

## 7. Conformance checklist (what Ycode's simulator must reproduce)

Run `MKProbe` (modes in parentheses) on a Ycode device and compare with
these rows (server content, timings and safe areas excepted).

| # | Check | Expected |
|---|---|---|
| S1 | (math) geometry, camera values and formatter strings | identical digits to `geometry.md` §§1–7, §11 |
| S2 | (map) a map renders within 3 s with a warm cache | screenshot shows streets; `didFinishRenderingMap(fullyRendered: YES)` |
| S3 | (map) callback sequences | `interface.md` §3.4 orders; none on return to a loaded area |
| S4 | (config) every configuration renders and reports the `mapType` of `interface.md` §3.2 | 3D buildings with realistic elevation; globe for imagery at 20,000 km |
| S5 | (annot, annot:cluster) marker defaults, selection, cluster "+19 more" | `interface.md` §4 |
| S6 | (user) location fix ≈ immediately after `showsUserLocation`, simulated, 5 m | §4.8 |
| S7 | (user) `simctl location set` equivalent moves the user and the following camera | §4.8 item 2 |
| S8 | (search) "coffee" near Apple Park: 25 items with addresses and identifiers; gibberish → code 4 | `services.md` §2 |
| S9 | (search) completer results and highlight ranges; empty fragment → code 5 | `services.md` §3 |
| S10 | (dir) automobile route with steps and polyline; transit `calculate` → code 5 at once; ocean → code 2 | `services.md` §4 |
| S11 | (geo) forward/reverse geocoding including the ocean case; gibberish → `kCLErrorDomain` 8 / code 4 | `services.md` §5 |
| S12 | (look) scene for a covered corner, nil for the ocean, code 1 for invalid input | §4.6 |
| S13 | (snap) image sizes, scale 3, `point(for:)` corners | `geometry.md` §9 |
| S14 | (open) 27.1: `openInMaps` NO, `https://maps.apple.com` opens Safari; 27.0: Maps opens | §5 |
| S15 | (gesture) pan/fling/double-tap move the camera as §4.4 | §4.4 (27.0 values) |
| S16 | (offline, offline:geodstopped) grid map, −1003 for an unreachable tile host, code 1 when `geod` is gone | §6 |

## 8. 27.0 versus 27.1 detail

Identical: request defaults; search counts, ordering, categories and
bounding regions (e.g. "coffee" 25 items, required-region variant 25,
POI request 43 within 412 m, identifier raw value 17 characters);
completer; directions distances (25,912 m, 19,708 m walking, 19,739 m
cycling), transit failure and ETA, error codes and userInfo keys;
geocoding answers; Look Around; snapshot geometry. Travel times differ by
the time of day (server traffic), as expected.

## Evidence

| Claim | Level |
|---|---|
| Presence/absence of Maps.app, launchd job labels, programs, users, Mach services, launch events; SnapshotService Info.plist | 2 (runtime files read as plists) |
| Mach/XPC lookups and notification registrations of the app | 3 (our `svctrace` interposer in our own app process) |
| Hosts, protocols, request counts and bytes | 3 (`geod`'s unified log, `log stream` of the simulator) |
| View hierarchy class names | 4 (runtime class names printed by our probe) |
| Everything else | 3 (`MKProbe` on `ycode-test-mapkit-271` and `ycode-test-mapkit-270`) |
| Level 5 (disassembly/decompilation) | not used |
