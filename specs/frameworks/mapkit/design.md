# MapKit spec: design note for an open implementation

> **Ycode-original design.** Nothing in this file describes how Apple builds
> MapKit. It is our plan for (a) running Apple's MapKit in Ycode's simulator
> and (b) an open, Linux-buildable MapKit with the same interface, built from
> open data and permissively licensed renderers. Facts it relies on are cited
> to the other files of this directory.

## 1. Two targets

| Target | What runs | Where the map data comes from |
|---|---|---|
| **A. Baseline** | Apple's iOS 27.1 runtime in a Ycode micro-VM: Apple's MapKit, VectorKit, GeoServices and `geod` | Apple's servers, through the guest's network (exactly as Apple's simulator does, `simulator-baseline.md` §2) |
| **B. Open MapKit** | Ycode's own `MapKit` (same module, class, selector and constant names; binary-compatible in the guest; a Swift package on Linux) | open data and services that Ycode or the developer chooses (§4) |

Target A comes first: it is what makes existing apps "just work". Target B
is the long-term open-frameworks track (`docs/FUTURE.md`); it must never
depend on Apple's servers or resources.

## 2. Target A: what Ycode's simulator must provide

From `simulator-baseline.md` §§2–7. Each line is a dependency with the
evidence that it is needed. `plan.md` §2 orders them into rounds R1–R6.

| # | Dependency | Why |
|---|---|---|
| A1 | **Guest network with TLS to the public internet**, HTTP/2 and QUIC allowed, DNS | every tile, resource, search, directions, geocoding and Look Around request is an HTTPS request made by `geod` (§2); no request means a blank grid map and `MKErrorDomain` errors (§6) |
| A2 | **Metal in the app process** (the reference uses the host GPU through `com.apple.metal.simulator`) | `MKMapView`, SwiftUI `Map`, Look Around and the snapshot service render with Metal inside the client process; this is the same Metal→Vulkan layer the simulator track needs for every UI (stage 8a) |
| A3 | `geod` launchable on demand as user `mobile`, with writable `/var/mobile/Library/Caches/GeoServices`, `…/Caches/com.apple.geod`, `…/Preferences/com.apple.GEO.plist` | resource manifest, styles, icons, fonts and tiles are downloaded and cached there on first use (45 MB of resources after one map) |
| A4 | XPC lookup of `com.apple.geod` from apps, and of the snapshot XPC service bundled in `MapKit.framework/XPCServices` | the app's only map-data channel; `MKMapSnapshotter` runs out of process |
| A5 | `locationd` with its simulation service and the TCC location grant | user location, `MKMapItem.forCurrentLocation()`, follow modes (see `../weatherkit/location.md`) |
| A6 | Touch input with multi-step drags and double taps through Ycode's HID path | pan, fling deceleration, double-tap zoom, selection by tap (`simulator-baseline.md` §4.4) |
| A7 | Large virtual address space and memory for VectorKit (map process grows by ~150 MB with 3D) | 3D buildings, globe and satellite modes |
| A8 | Correct wall clock and time zone | TLS validity, ETA dates, time-zone fields of map items |
| A9 | `geoanalyticsd` launchable (looked up by every map app); `navd`, `mapssyncd`, `destinationd`, `mapspushd` jobs present (launch-on-demand) | the analytics lookup happens on every map use; the Maps-support daemons were not contacted by a MapKit app, only by the Maps app on 27.0 (`simulator-baseline.md` §2.1) |
| A10 | No Maps app on 27.1 | `openInMaps` and `maps:` URLs fail exactly as `simulator-baseline.md` §5 records; Ycode must not "fix" this in the 27.1 baseline |
| A11 | `com.apple.MTLCompilerService` XPC service for app processes | Metal shader compilation for the map, snapshots and Look Around (`simulator-baseline.md` §2.2) |
| A12 | `geod` in the **user** launchd domain (`user/501/…`), and a way to stop/restart it for tests | matches the reference's job placement; S16 checks the no-`geod` behavior (`simulator-baseline.md` §6) |

Not required: an Apple account, a team, entitlements, or MapKit JS tokens.

## 3. Target B: architecture

```
           app (Swift / ObjC)                     Linux app or guest app
                   |                                         |
      +------------+----------------+  public names only     |
      | YMapKit (module "MapKit")   |<-----------------------+
      |  Geometry  | Camera/Viewport | Annotation & overlay model | Search/Directions/Geocoding clients
      +------+-----+--------+--------+-------------+---------------+
             |              |                      |
       MKGeometry      Renderer bridge        Service adapters (pluggable)
     (pure Swift,     (MapLibre Native,       tiles | search | routing | geocoding | street imagery
      golden tests)    BSD-2, Metal/Vulkan/GL)
             |              |                      |
             +---- ycode-geod (open daemon, optional in the guest): cache, request queue, offline packs
```

### 3.1 Geometry core (`MKGeometry`)

Pure Swift, no dependencies, platform-independent, bit-exact against the
golden values of `geometry.md`. It owns: the 2^28 Web Mercator map-point
space with its clamps and invalid-coordinate sentinel, map rect algebra
including the 180th-meridian rules, regions from meters and from map rects,
meters-per-map-point, map-point distance (planar, not geodesic), circles and
polylines bounding rects, geodesic polyline densification, the distance
formatter. This is round R7 (`plan.md`) and the base for everything else.

### 3.2 Camera and viewport

One camera model (center, center-to-eye distance, pitch, heading) with
altitude derived from distance and pitch, and a viewport (the view's
safe-area rectangle) that maps the camera to a visible map rect and region,
as measured in `geometry.md` §6 (vertical field of view, region fitting by
aspect, zoom clamps, pitch limits that depend on distance, boundaries, zoom
ranges). Shared by the UIKit view, the SwiftUI view and the snapshotter.

### 3.3 Rendering

Use **MapLibre Native** (BSD-2-Clause, verified §5) as the engine behind
`MKMapView`: it renders Mapbox Vector Tiles (spec text CC BY 3.0 US — we
implement the format, we do not copy the text) with a MapLibre style
document, supports globe, terrain, 3D extrusions and raster layers, and has
Metal and Vulkan back ends (so the guest drop-in and Linux share one
renderer). Ycode writes **its own styles** for the four looks MapKit
exposes (standard, muted standard, imagery, hybrid) in light and dark,
starting from CC0 designs (Protomaps basemap themes, verified §5) — never
from Apple's style files, icons or fonts, which are Apple resources cached
in the simulator.

Mapping of MapKit concepts onto the engine:

| MapKit concept | Engine concept |
|---|---|
| configuration / map type | a style document per (look, elevation, emphasis, appearance); traffic and POI filter as layer filters |
| realistic elevation | terrain source + 3D building extrusion layer; flat = no terrain, no extrusions |
| overlays (`MKOverlay` + renderer) | client-drawn layers: our renderer classes draw with Core Graphics (or a portable 2D canvas on Linux) into tiles that the engine composites at the requested level (above roads / above labels) |
| `MKTileOverlay` | raster source with the template URL grammar of `interface.md` §4.4 |
| annotations | platform views positioned from map points every frame (not engine symbols), so `MKAnnotationView` subclasses keep working |
| POI selection (`selectableMapFeatures`) | engine feature query at the tap point, returned as `MKMapFeatureAnnotation` |

### 3.4 Services

A small protocol per service, with one adapter per open backend chosen at
run time (configuration file or environment, never hard-coded endpoints):

| MapKit API | Protocol | First open backend | License of what we link |
|---|---|---|---|
| tiles | `TileSource` | PMTiles file (offline) or a vector tile server | PMTiles reader BSD-3-Clause |
| `MKLocalSearch`, completer, POI request | `PlaceSearch` | Photon (Apache-2.0) or Pelias (MIT) over HTTP | HTTP only, nothing linked |
| `MKGeocodingRequest`, `MKReverseGeocodingRequest`, `CLGeocoder` | `Geocoder` | Nominatim over HTTP (server is GPL; we do not link it) or Photon | HTTP only |
| `MKDirections` (routes, ETA) | `Router` | Valhalla (MIT) or OSRM (BSD-2-Clause) over HTTP; optional in-process Valhalla library | MIT / BSD-2 |
| Look Around | `StreetImagery` | none by default (`scene` = nil, as for an uncovered place); optional Panoramax/Mapillary adapter — imagery licenses differ per source and must be checked per deployment | — |
| snapshots | (renderer) | headless engine render to an image | BSD-2 |

All adapters normalize into the response models of `services.md`
(names, categories, addresses as `MKAddress` full/short strings and
representations, polylines in map points, step lists, error codes of
`services.md` §7).

### 3.5 Open daemon (guest only, optional)

In the guest, Ycode's MapKit can talk to an open `ycode-geod` over XPC (same
role as `geod`): one HTTP client with caching, request coalescing, a disk
tile cache (SQLite of tiles keyed by source/z/x/y) and offline packs. On
Linux the same code runs in-process. The service name must differ from
Apple's (`dev.ycode.geod`) so the two never collide when Apple's runtime is
present.

## 4. Data and license rules

1. **OpenStreetMap data is ODbL 1.0.** Share-alike applies to the *data*:
   any derivative database we distribute (an extract, a tile set built from
   OSM, a search index) must be offered under ODbL. Rendered images and our
   code are not derivative databases; produced works only need attribution
   ("© OpenStreetMap contributors" on the map). Our *code* stays under its own
   license (MIT for Ycode). Ycode's attribution view must therefore be
   driven by the active sources, like Apple's "Legal" link (`simulator-baseline.md` §3, item 1).
2. We link only permissive code (BSD, MIT, Apache-2.0). GPL servers
   (Nominatim) are used, if at all, over HTTP as separate programs.
3. We never ship or reuse Apple's cached resources (styles, icon packs,
   fonts, region files, tiles) or Apple's scenario data, and never point the
   open implementation at Apple's endpoints.
4. Every bundled style, icon set and font gets a recorded license in the
   repository (CC0 or OFL preferred).

## 5. Licenses verified (2026-10-19, from each project's license file)

| Project | Role | License |
|---|---|---|
| MapLibre Native | renderer | BSD-2-Clause (copyright lines include Mapbox 2014–2020, MapLibre contributors, MapTiler) |
| MapLibre style spec / GL JS | style format reference | BSD-3-Clause (GL JS bundles one MIT component) |
| Mapbox Vector Tile specification | tile format | text under CC BY 3.0 US (we implement the format; no text copied) |
| PMTiles | archive format and readers | BSD-3-Clause |
| Protomaps basemaps | styles to start from | code BSD-3-Clause; visual design CC0; some icons MIT |
| Planetiler | building OSM tiles | Apache-2.0 |
| OSRM | routing | BSD-2-Clause |
| Valhalla | routing | MIT |
| Photon | search/geocoding | Apache-2.0 |
| Nominatim | geocoding server | GPL-3.0 (license file) — HTTP only, never linked |
| OpenStreetMap data | map data | ODbL 1.0 (share-alike for databases; attribution for produced works) |

## 6. Testing strategy

- **Geometry and camera**: unit tests with the golden values of
  `geometry.md` (exact to the printed digits), on Linux and in the guest.
- **Viewport**: the same `MKProbe` math phase run against Ycode's MapKit in
  the guest must print identical lines (modulo the device's safe area).
- **Rendering**: no pixel parity with Apple (different data and styles).
  Tests check callbacks and their order (`interface.md` §3.4),
  overlay/annotation placement in points (`geometry.md` §8), and image
  geometry of snapshots (`geometry.md` §9).
- **Services**: recorded responses from the open backends (fixtures we
  produce, ODbL-attributed), and shape tests mirroring the reference
  (`services.md`): counts, ordering by distance, category sets, error codes.
