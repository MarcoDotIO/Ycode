# MapKit spec: interface and behavior

Part of `specs/frameworks/mapkit/`. What an open MapKit must offer, area by
area: names (interop facts, level 4; the complete list is
`api-inventory.md`), the model behind them in our own words, and the
behavior we measured (level 3, `MKProbe`). Geometry, projection and camera
math are in `geometry.md`; search, directions and geocoding models in
`services.md`.

## 1. Module layout (level 4)

- `MapKit.framework`: install name `/System/Library/Frameworks/MapKit.framework/MapKit`,
  bundle identifier `com.apple.MapKit`. Objective-C API in 80+ headers
  (one per type); a small Swift overlay module (`MapKit.swiftmodule`:
  `MKMultiPoint.locations(at:)`, `MKGradientPolylineRenderer` locations,
  bridging of `MKCoordinateSpan`, `MKAddressRepresentations.region`,
  `MKMapItemRequest(placeDescriptor:)` with GeoToolbox's `PlaceDescriptor`).
- SwiftUI map API lives in `_MapKit_SwiftUI.framework`, a cross-import
  overlay that is loaded when a file imports both `MapKit` and `SwiftUI`.
- The runtime bundle also contains `XPCServices/com.apple.MapKit.SnapshotService.xpc`
  (an XPC service of type "System" with two extension points named
  `com.apple.maps.services` and `com.apple.maps.ui-services`), localized
  strings for ~40 languages, an asset catalog and `CountryRegions.plist`.
  Ycode writes its own resources.
- Related frameworks an app links implicitly: `CoreLocation` (coordinates,
  `CLGeocoder`, `CLPlacemark`), `GeoToolbox` (`PlaceDescriptor`, 26.0+),
  `_LocationEssentials` (`CLLocationCoordinate2D` animatable data for
  SwiftUI).

## 2. Value types

`CLLocationCoordinate2D` (degrees), `MKCoordinateSpan` (latitudeDelta,
longitudeDelta), `MKCoordinateRegion` (center, span), `MKMapPoint` (x, y),
`MKMapSize` (width, height), `MKMapRect` (origin, size), `CLLocationDistance`
(meters), `MKZoomScale` (screen points per map point), `MKTileOverlayPath`
(x, y, z, contentScaleFactor). Their algebra and constants are in
`geometry.md` §§1–5.

## 3. The map view (`MKMapView`)

### 3.1 State

| Group | Members | Default (measured) |
|---|---|---|
| Look | `preferredConfiguration` (16.0), `mapType` (deprecated in favor of configurations), `showsBuildings`, `showsTraffic`, `pointOfInterestFilter`, `overrideUserInterfaceStyle` (UIKit) | `MKStandardMapConfiguration`, elevation flat (0), emphasis default (0), traffic NO, POI filter nil; `mapType` 0; buildings YES |
| Viewport | `region`, `centerCoordinate`, `visibleMapRect`, `camera`, `cameraZoomRange` (13.0), `cameraBoundary` (13.0) | before any change: center (37.132840, −95.785580) — the middle of the contiguous US, the default region for an en_US device; zoom range (−1, −1) meaning "default"; a non-nil default boundary object |
| Interaction | `isZoomEnabled`, `isScrollEnabled`, `isRotateEnabled`, `isPitchEnabled` | all YES |
| Ornaments | `showsCompass`, `showsScale`, `pitchButtonVisibility` (17.0), `showsUserTrackingButton` (17.0) | compass YES (shown only when heading ≠ 0), scale NO, pitch button `MKFeatureVisibility.hidden` (1) |
| User | `showsUserLocation`, `userLocation`, `isUserLocationVisible`, `userTrackingMode` | NO, an `MKUserLocation` at (0, 0) until a fix, NO, `.none` |
| Selection | `selectedAnnotations`, `selectableMapFeatures` (16.0) | empty, empty option set (0) |

### 3.2 Configurations and map types

A configuration object selects the look: `MKStandardMapConfiguration`
(`elevationStyle`, `emphasisStyle`, `pointOfInterestFilter`, `showsTraffic`),
`MKHybridMapConfiguration` (`elevationStyle`, `pointOfInterestFilter`,
`showsTraffic`), `MKImageryMapConfiguration` (`elevationStyle`). The
legacy `mapType` read back after setting a configuration (measured):

| Configuration | `mapType` |
|---|---|
| standard, flat or realistic, default emphasis | 0 standard |
| standard, muted emphasis / setting `mapType = .mutedStandard` | 5 mutedStandard |
| imagery, flat | 1 satellite |
| imagery, realistic | 3 satelliteFlyover |
| hybrid, realistic | 4 hybridFlyover |
| hybrid, flat | 2 hybrid (by symmetry; not measured) |

Setting `mapType = .satelliteFlyover` yields an imagery configuration with
realistic elevation. Rendering observations (level 3, screenshots in
`research/dirty/mapkit/`): standard realistic at 900 m with 60° pitch shows
extruded 3D buildings, trees and landmark models; standard flat with the
same camera shows a pitched flat map; imagery realistic shows textured 3D
city meshes; at 20,000 km the **imagery** look is a globe with atmosphere,
stars and a day/night terminator at the current sun position, while the
**standard** look stays a flat Mercator world with tropic and equator lines
and relief shading. Dark appearance (`overrideUserInterfaceStyle = .dark`)
switches the style. Labels and POI symbols are in the map, not views.

Setting a new configuration and a pitched camera in the same run-loop turn
can drop the pitch (imagery flat → imagery realistic with a 60° camera read
back pitch 0); setting the camera after the configuration takes effect
keeps it.

### 3.3 Viewport methods

`setRegion(_:animated:)`, `regionThatFits(_:)`, `setCenter(_:animated:)`,
`setVisibleMapRect(_:animated:)` and the `edgePadding:` variants,
`mapRectThatFits(_:)`, `setCamera(_:animated:)`, `showAnnotations(_:animated:)`,
conversions `convert(_:toPointTo:)`, `convert(_:toCoordinateFrom:)`,
`convert(_:toRectTo:)` (region → rect), `convert(_:toRegionFrom:)`. Their exact
geometry (safe-area viewport, fitting by aspect, zoom and pitch clamps) is in
`geometry.md` §6. Non-animated changes apply synchronously: the getters
return the new values immediately and the delegate's region callbacks run
inside the setter.

### 3.4 Delegate (`MKMapViewDelegate`) and its order

Region: `mapView(_:regionWillChangeAnimated:)`, `mapViewDidChangeVisibleRegion(_:)`
(per frame while moving), `mapView(_:regionDidChangeAnimated:)`.
Loading/rendering: `mapViewWillStartLoadingMap`, `mapViewDidFinishLoadingMap`,
`mapViewDidFailLoadingMap(_:withError:)`, `mapViewWillStartRenderingMap`,
`mapViewDidFinishRenderingMap(_:fullyRendered:)`. User: `mapViewWillStartLocatingUser`,
`mapViewDidStopLocatingUser`, `mapView(_:didUpdate:)`,
`mapView(_:didFailToLocateUserWithError:)`, `mapView(_:didChange:animated:)`.
Annotations: `mapView(_:viewFor:)`, `mapView(_:didAdd:)`,
`mapView(_:didSelect:)` (view and, 18.0, annotation variants),
`mapView(_:didDeselect:)`, callout and drag callbacks,
`mapView(_:clusterAnnotationForMemberAnnotations:)`. Overlays:
`mapView(_:rendererFor:)`, `mapView(_:didAdd:)` for renderers.

Observed sequences (27.1):

1. **First display** (region set before the first frame): `regionWillChange`
   (animated NO) → `didChangeVisibleRegion` → `regionDidChange` synchronously
   in `setRegion`; ≈0.3 s later `willStartLoadingMap` and
   `willStartRenderingMap`; then two or three `willStartLoadingMap` /
   `didFinishLoadingMap` pairs (one per tile batch) and finally
   `didFinishRenderingMap(fullyRendered: YES)`, ≈0.7 s after the region was
   set (≈1.8 s on a loaded host, including first-time resource downloads).
2. **Moving to a new area**: `willStartRenderingMap` → loading pairs →
   `didFinishRenderingMap(YES)`, ≈0.5–0.8 s.
3. **Returning to an area already in memory**: only the region callbacks;
   **no loading or rendering callbacks at all** (a client that waits for
   `didFinishRenderingMap` after every region change waits forever).
4. **Animated `setRegion`/`setCenter`/`setCamera`**: `regionWillChange(animated: YES)`,
   many `didChangeVisibleRegion`, rendering and loading callbacks
   interleaved, `regionDidChange(animated: YES)` at the end (≈0.35 s for
   `setCenter`, ≈1 s for a large camera change).
5. **Tile overlay with an unreachable host** (`canReplaceMapContent` YES):
   see `simulator-baseline.md` §6.

### 3.5 Ornaments

The map view hosts, as its own subviews: the map content (a Metal layer
host), an annotation container, the Apple Maps logo at the bottom left
(10 pt inset, ≈50 × 39 pt; hidden when a tile overlay replaces the map
content) and a "Legal" attribution link next to it, and a
compass (44 × 44 pt) at the top trailing corner of the safe area when the
heading is not 0. The logo and legal link stay inside the safe area. Ycode's
own implementation shows its data attribution in the same corner
(`design.md` §4).

## 4. Annotations and overlays

### 4.1 Annotation model

`MKAnnotation` (protocol: `coordinate`, optional `title`, `subtitle`);
concrete `MKPointAnnotation` (an `MKShape`), `MKPlacemark`,
`MKMapItemAnnotation` (18.0), `MKMapFeatureAnnotation` (16.0, POI tapped on
the map), `MKUserLocation`, `MKClusterAnnotation` (`memberAnnotations`).
Views: `MKAnnotationView` (`annotation`, `image`, `centerOffset`,
`calloutOffset`, `canShowCallout`, accessory views, `isSelected`,
`isDraggable`/`dragState`, `clusteringIdentifier`, `displayPriority`,
`collisionMode`, `zPriority`, `selectedZPriority`, reuse identifier),
`MKMarkerAnnotationView` (balloon marker: `markerTintColor`,
`glyphText`, `glyphImage`, `glyphTintColor`, title/subtitle visibility),
`MKPinAnnotationView` (deprecated), `MKUserLocationView` (17.0).

With no `mapView(_:viewFor:)` (or one returning nil) the map view uses an
`MKMarkerAnnotationView` dequeued with
`MKMapViewDefaultAnnotationViewReuseIdentifier`. Measured defaults
(27.1, 3× screen):

| Property | Value |
|---|---|
| frame size | 31.33 × 34.94 pt (the balloon; the title is drawn below it outside the frame) |
| `centerOffset` | (0, −17.471) = −height/2, so the balloon's bottom tip sits on the coordinate |
| `calloutOffset` | (0, 29.942) |
| `canShowCallout` | NO |
| `displayPriority` | 250 (`defaultLow`) |
| `collisionMode` | 1 (`circle`) |
| `zPriority` | 500 |
| `markerTintColor`, `glyphTintColor`, `glyphText` | nil (the default red balloon with a pin glyph is drawn) |
| `titleVisibility`, `subtitleVisibility` | 0 (`adaptive`) |
| `animatesWhenAdded` | NO |

Views are created lazily: `mapView(_:didAdd:)` arrives with all visible
views ≈30 ms after `addAnnotations` (once per batch, e.g. 3 then 23
views); `view(for:)` returns nil for annotations whose view does not exist.

### 4.2 Selection

`selectAnnotation(_:animated:)` calls `mapView(_:didSelect:)` with the
view and then with the annotation (both variants are delivered, view
first), and enlarges the marker; `deselectAnnotation` calls
`didDeselect`. `selectedAnnotations` has at most one element.

### 4.3 Clustering

Views with the same non-nil `clusteringIdentifier` whose collision frames
overlap are replaced by one `MKClusterAnnotation`, viewed by an
`MKMarkerAnnotationView` with reuse identifier
`MKMapViewDefaultClusterAnnotationViewReuseIdentifier`. Measured: 20
markers within ≈90 m (at 3.8 m per point) plus 3 farther markers sharing the
identifier produced one cluster whose glyph shows the member count ("20"),
whose title is a member's title and whose subtitle is "+19 more"; the
other three markers stayed separate. Member annotations keep reporting
their (hidden) views' frames.

### 4.4 Overlays and renderers

`MKOverlay` (protocol: `coordinate`, `boundingMapRect`, optional
`intersects(_:)`, `canReplaceMapContent`); shapes `MKPolyline`,
`MKPolygon` (with `interiorPolygons`), `MKCircle`, `MKMultiPolyline`,
`MKMultiPolygon`, `MKGeodesicPolyline`, `MKTileOverlay`; levels
`MKOverlayLevel.aboveRoads` (0) and `.aboveLabels` (1) chosen at
`addOverlay(_:level:)`. Renderers: `MKOverlayRenderer` (`overlay`, `alpha`,
`contentScaleFactor`, `point(for:)`, `mapPoint(for:)`, `rect(for:)`,
`mapRect(for:)`, `canDraw`, `draw(_:zoomScale:in:)`, `setNeedsDisplay`),
`MKOverlayPathRenderer` (`fillColor`, `strokeColor`, `lineWidth`,
`lineJoin`, `lineCap`, `miterLimit`, `lineDashPhase`, `lineDashPattern`,
`shouldRasterize` (13.0), `path`, `createPath`), concrete `MKPolylineRenderer`
(`strokeStart`, `strokeEnd`), `MKPolygonRenderer`, `MKCircleRenderer`,
`MKMultiPolylineRenderer`, `MKMultiPolygonRenderer`,
`MKGradientPolylineRenderer`, `MKTileOverlayRenderer`.

Measured renderer facts:

- Defaults of a path renderer: `lineWidth` 0, `strokeColor` nil,
  `fillColor` nil, `lineCap` round (1), `lineJoin` round (1), `miterLimit` 0,
  `alpha` 1, `strokeStart` 0, `strokeEnd` 1, `shouldRasterize` NO. (A line
  width of 0 draws a hairline scaled with zoom; apps set a width.)
- **Renderer coordinate space** = map points relative to the overlay's
  `boundingMapRect` origin, unscaled: `point(for:)` of a map point returns
  (x − origin.x, y − origin.y); `rect(for: boundingMapRect)` returns
  (0, 0, width, height) in map points; `path.boundingBox` equals it. Zoom
  enters only through the `zoomScale` passed to drawing.
- `contentScaleFactor` = the screen scale (3).

`MKTileOverlay`: `urlTemplate` with placeholders `{x}`, `{y}`, `{z}` and
`{scale}`; defaults `tileSize` 256 × 256, `minimumZ` 0, `maximumZ` 21,
`isGeometryFlipped` NO, `canReplaceMapContent` NO, `boundingMapRect` = the
world, `coordinate` (0, 0). `url(forTilePath:)` substitutes the path's x, y,
z and scale verbatim (`isGeometryFlipped` does not change what
`url(forTilePath:)` returns; it changes which y the map asks for).
`loadTile(at:)` fetches that URL; an unresolvable host fails with an
`NSURLErrorDomain` error (`simulator-baseline.md` §6).

## 5. Camera model

`MKMapCamera`: `centerCoordinate`, `centerCoordinateDistance` (13.0,
meters from eye to center), `pitch` (degrees from vertical), `heading`
(degrees clockwise from north), `altitude` (eye height above the center;
deprecated in favor of the distance). Constructors: `init()`,
`init(lookingAtCenter:fromDistance:pitch:heading:)`,
`init(lookingAtCenter:fromEyeCoordinate:eyeAltitude:)`,
`+cameraLookingAtMapItem:forViewSize:allowPitch:` (16.0, frames a map item). `MKMapView.CameraZoomRange`
(`minCenterCoordinateDistance`, `maxCenterCoordinateDistance`, constant
`MKMapCameraZoomDefault` = −1), `MKMapView.CameraBoundary` (`region` or
`mapRect`). Geometry and clamps: `geometry.md` §7.

SwiftUI: `MapCamera` (`centerCoordinate`, `distance`, `heading`, `pitch`),
`MapCameraPosition` (`.automatic`, `.camera(_:)`, `.region(_:)`,
`.rect(_:)`, `.item(_:allowsAutomaticPitch:)`,
`.userLocation(followsHeading:fallback:)`; read-only `camera`, `region`,
`rect`, `item`, `positionedByUser`, `followsUserLocation`,
`followsUserHeading`, `fallbackPosition`), `MapCameraBounds`,
`MapCameraUpdateContext` (`camera`, `region`, `rect`),
`MapCameraUpdateFrequency` (`.onEnd`, `.continuous`), `MapProxy`
(`convert(_:to:)`, `convert(_:from:)`, `camera(framing:)` variants),
`MapReader`.

## 6. User location

`showsUserLocation = YES` starts Core Location (the app needs
`NSLocationWhenInUseUsageDescription` and a grant; behavior of the grant and
of simulated locations is in `../weatherkit/location.md`). Measured:

1. `mapViewWillStartLocatingUser` immediately; `userLocation.isUpdating`
   YES; the first `mapView(_:didUpdate:)` ≈20 ms later with the simulated
   fix (accuracy 5 m, `sourceInformation.isSimulatedBySoftware` YES,
   heading nil). `userLocation.title` is "My Location".
2. The user-location view (`_MKUserLocationView`-class, 42 × 44 pt) is
   added only when its coordinate is inside the viewport.
3. `setUserTrackingMode(.follow)` recenters on the user at once, at a
   distance of ≈4,790 m (span ≈0.0164° lon on the 382 pt-wide viewport),
   with `didChange(mode: 1)`.
4. Changing the simulated location (`simctl location set`) gives a
   transient `didFailToLocateUser` (`kCLErrorDomain` 0) and then
   `didUpdate` with the new fix; in follow mode the map animates there
   (`regionDidChange(animated: YES)`).
5. `.followWithHeading` is accepted (mode 2) although the simulator has no
   heading; heading stays nil.
6. `MKMapItem.forCurrentLocation()` is a placeholder: `isCurrentLocation`
   YES, name "Unknown Location", coordinate (−180, −180) when read directly
   (observed after `simctl location clear`); services that take it as an
   input (directions source) resolve it to the current simulated fix at
   request time (`services.md` §4.2).

## 7. SwiftUI `Map`

`Map` initializers take an optional `position: Binding<MapCameraPosition>`
(or `initialPosition:`), `bounds: MapCameraBounds?`,
`interactionModes: MapInteractionModes` (`pan`, `zoom`, `rotate`,
`pitch`, `all`), optional `selection:` binding and `scope:`, and a
`@MapContentBuilder` content closure. Content (`MapContent` protocol):
`Marker` (title with a coordinate; variants with `systemImage:`, `image:`,
`monogram:`; or an `MKMapItem`), `Annotation` (title, coordinate,
`anchor:`, SwiftUI view content), `UserAnnotation`, `MapCircle`,
`MapPolyline` (with `contourStyle` straight or geodesic), `MapPolygon`,
`ForEach`, `Group`, `.tag(_:)`, `.tint(_:)`, `.stroke(…)`,
`.foregroundStyle(_:)`, `.mapOverlayLevel(level:)`,
`.annotationTitles(_:)`/`.annotationSubtitles(_:)`,
`.mapItemDetailSelectionAccessory(_:)` (18.0). View modifiers:
`.mapStyle(_:)` (`MapStyle.standard(elevation:emphasis:pointsOfInterest:showsTraffic:)`,
`.imagery(elevation:)`, `.hybrid(elevation:pointsOfInterest:showsTraffic:)`),
`.mapControls { MapUserLocationButton(); MapCompass(); MapScaleView(); MapPitchToggle() }`,
`.mapControlVisibility(_:)`, `.onMapCameraChange(frequency:_:)`,
`.mapCameraKeyframeAnimator(trigger:keyframes:)`,
`.mapFeatureSelectionDisabled(_:)`, `.mapFeatureSelectionContent(_:)`,
`.mapFeatureSelectionAccessory(_:)`, `.lookAroundViewer(…)`,
`.mapItemDetailSheet(…)`/`Popover(…)` (18.0), `.mapScope(_:)`.
Legacy (14.0, deprecated): `Map(coordinateRegion:…)`, `MapAnnotation`,
`MapMarker`, `MapPin`, `MapUserTrackingMode`. Several controls
(`MapPitchSlider`, `MapZoomStepper`, `MapLocationCompass`, `SelectedMarker`,
`SelectedUserAnnotation`) are unavailable on iOS.

Measured behavior: `simulator-baseline.md` §4.5 and `geometry.md` §10.

## 8. Snapshots (`MKMapSnapshotter`)

`MKMapSnapshotter.Options` (`camera`, `mapRect`, `region`,
`preferredConfiguration` (17.0), `mapType`, `pointOfInterestFilter`,
`showsBuildings`, `size`, `traitCollection`), `MKMapSnapshotter`
(`init(options:)`, `start(completionHandler:)`, `start(with:completionHandler:)`,
async `start()`, `cancel()`, `isLoading`), `MKMapSnapshotter.Snapshot`
(`image`, `traitCollection`, `point(for:)`).

Measured defaults: `size` 256 × 256, `region` the default US region
(center (37.132840, −95.785580)), `mapType` 0, `showsBuildings` YES,
POI filter nil, standard configuration, trait display scale = screen scale
(3), style unspecified. Setting `region` updates `mapRect` and `camera`
(and vice versa). Setting `size` to zero raises
`NSInvalidArgumentException` "Cannot set a zero area size." at once.

Results: `image.size` = `options.size` in points; `image.scale` = the
screen scale (3) **even when the trait collection asks for scale 1**;
`snapshot.traitCollection.userInterfaceStyle` = the requested style (light 1,
dark 2). The image **aspect-fits** the requested region (the
filling dimension is kept, the other extended, centered; no safe area):
`geometry.md` §9. The first snapshot of a process takes ≈1.3 s (7.3 s on a
cold 27.0 device); later ones ≈0.3–0.5 s; four in parallel take ≈3 s in
all. `cancel()` right after `start` suppresses the completion handler.
A 6000 × 6000 pt size fails at once with `MKErrorDomain` 1 (userInfo key
`Reason`). Snapshots render out of process (the snapshot XPC
service) and include no annotations or overlays; apps draw those on the
image with `point(for:)`.

## 9. Look Around

`MKLookAroundSceneRequest` (`init(coordinate:)`, `init(mapItem:)`,
`getSceneWithCompletionHandler`, async `scene`, `cancel`, `isLoading`,
`isCancelled`, `coordinate`, `mapItem`), `MKLookAroundScene` (opaque),
`MKLookAroundSnapshotter` (+ `Options`: `size`, `pointOfInterestFilter`,
`traitCollection`) and `MKLookAroundSnapshot` (`image`),
`MKLookAroundViewController` (`scene`, `isNavigationEnabled`,
`showsRoadLabels`, `pointOfInterestFilter`, `badgePosition`, delegate
with will/did present and dismiss full-screen and did-change-scene
callbacks); SwiftUI `LookAroundPreview` and `.lookAroundViewer`.

Measured: a covered street corner returns a scene in ≈0.1 s; the open
ocean and an uncovered city return **nil without error**; an invalid
coordinate fails at once with `MKErrorDomain` 1. A request cancelled before
it completes still returned (`scene` succeeded) when awaited right after
`cancel`. Snapshot options default to 256 × 256; a 300 × 200 Look Around
snapshot arrives in ≈1.3 s at scale 3. The view controller defaults:
navigation enabled, road labels shown, POI filter nil, badge at top
leading (0); presented full screen it shows the street-level panorama.

## 10. Map items in other apps, URLs and launch options

`MKMapItem.openInMaps(launchOptions:)`, `openInMaps(launchOptions:from:completionHandler:)`
(13.2), `MKMapItem.openMaps(with:launchOptions:)` and its async/completion
variant; launch-option keys `MKLaunchOptionsDirectionsModeKey`,
`MKLaunchOptionsMapTypeKey`, `MKLaunchOptionsShowsTrafficKey`,
`MKLaunchOptionsMapCenterKey`, `MKLaunchOptionsMapSpanKey`,
`MKLaunchOptionsCameraKey`, directions modes default/driving/walking/
transit/cycling (values §11). `MKMapItem` conforms to `NSSecureCoding`,
item providers (`MKMapItemTypeIdentifier` = "com.apple.mapkit.map-item"),
and `NSUserActivity.mapItem`.

Behavior on 27.1 (no Maps app) and 27.0: `simulator-baseline.md` §5.

## 11. String constants (runtime values, measured)

| Constant | Value |
|---|---|
| `MKErrorDomain` | `MKErrorDomain` |
| `MKLaunchOptionsDirectionsModeKey` | `MKLaunchOptionsDirectionsMode` |
| `MKLaunchOptionsMapTypeKey` | `MKLaunchOptionsMapType` |
| `MKLaunchOptionsShowsTrafficKey` | `MKLaunchOptionsShowsTraffic` |
| `MKLaunchOptionsMapCenterKey` | `MKLaunchOptionsMapCenter` |
| `MKLaunchOptionsMapSpanKey` | `MKLaunchOptionsMapSpan` |
| `MKLaunchOptionsCameraKey` | `MKLaunchOptionsCameraKey` (keeps the "Key" suffix, unlike the others) |
| `MKLaunchOptionsDirectionsModeDefault` / `Driving` / `Walking` / `Transit` / `Cycling` | the constant's own name |
| `MKMapItemTypeIdentifier` | `com.apple.mapkit.map-item` |
| `MKMapViewDefaultAnnotationViewReuseIdentifier`, `MKMapViewDefaultClusterAnnotationViewReuseIdentifier`, `MKAnnotationCalloutInfoDidChangeNotification` | the constant's own name |
| every `MKPointOfInterestCategory<Name>` (84 constants, list in `api-inventory.md` §4) | `MKPOICategory<Name>` (e.g. `MKPointOfInterestCategoryCafe` = `MKPOICategoryCafe`); no exceptions |

## 12. Errors

`services.md` §7 (`MKErrorDomain` codes 1–6 with observed causes and
userInfo keys) and §5 (`kCLErrorDomain` 8 for `CLGeocoder`).

## Evidence

| Claim | Level |
|---|---|
| Names, enum values, availability, module layout | 4 |
| Bundle contents (XPC service, extension point names, resources) | 2 (runtime bundle Info.plists and listing) |
| Purpose of APIs | 1 |
| Defaults, sequences, timings, geometry of views and renderers, constants' values, rendering observations | 3 (`MKProbe`, `consts` tool; notes in `research/notes/mapkit-simulator-observations-2026-10-19.md`) on iOS 27.1; services, Look Around and snapshot facts re-checked on iOS 27.0 |
