# ARKit spec: raycasting, scene understanding, maps, collaboration, geo

Part of `specs/frameworks/arkit/`. Conventions as in `session.md`.

## 1. Raycasting (13.0)

### 1.1 `ARRaycastQuery`

A ray plus what it may hit. Created by the app (`initWithOrigin:direction:allowingTarget:alignment:`)
or from a screen/image point (`ARFrame` `raycastQueryFromPoint:allowingTarget:alignment:`,
`ARSCNView` `raycastQueryFromPoint:allowingTarget:alignment:` — the view
variant returns nil when there is no current frame). Read-only properties:
`origin` and `direction` (world space, float3), `target`, `targetAlignment`.
A query built from a point starts at the camera position and points through
that point along the camera's field of view.

`ARRaycastTarget` / `ARRaycastQuery.Target`:

| Case | Value | Hits |
|---|---|---|
| `ARRaycastTargetExistingPlaneGeometry` | 0 | detected planes, within their estimated shape (`ARPlaneGeometry`) |
| `ARRaycastTargetExistingPlaneInfinite` | 1 | detected planes treated as infinite |
| `ARRaycastTargetEstimatedPlane` | 2 | a plane estimated on the fly from feature points (and depth, where available) around the ray; with alignment "any" the estimate follows the real surface normal |

`ARRaycastTargetAlignment` / `ARRaycastQuery.TargetAlignment`:
`Horizontal` 0, `Vertical` 1, `Any` 2 (horizontal and vertical are with
respect to gravity).

### 1.2 Results

`ARRaycastResult`: `worldTransform` (pose of the hit; the translation is the
hit point; the rotation aligns local +Y with the surface normal), `target`,
`targetAlignment`, `anchor` (always set for existing-plane targets; may be set
for estimated planes when the hit lies on a known plane).

`ARSession raycast:` returns all hits sorted by distance from the camera,
nearest first; empty when nothing is hit or the session is not tracking.

### 1.3 Tracked raycasts

`trackedRaycast:updateHandler:` returns an `ARTrackedRaycast` (or nil). The
session re-evaluates the query as its understanding improves and calls the
handler on the delegate queue with the new sorted result list. `stopTracking`
ends it; so do reset tracking, a configuration change, the
stop-tracked-raycasts run option and deallocation of the handle. Only world
tracking (and its subclasses) supports tracked raycasts.

## 2. Plane detection

With `planeDetection` set, the session adds `ARPlaneAnchor`s for horizontal
and/or vertical surfaces, updates their center, extent and geometry as more of
the surface is seen, and removes the newer of two planes that are found to be
the same surface. Plane poses and sizes are unreliable right after detection
and settle over time. Classification (wall, floor, …) is reported when the
device supports it.

## 3. Legacy hit-testing (11.0, deprecated 14.0)

`ARFrame hitTest:types:` (normalized image point) and the view variants
(`ARSCNView`/`ARSKView` `hitTest:types:`, view point) return
`ARHitTestResult`s. `ARHitTestResultType` / `ARHitTestResult.ResultType`
bits:

| Bit | Name | Hits |
|---|---|---|
| 1 << 0 | `FeaturePoint` | nearest feature point along the ray |
| 1 << 1 | `EstimatedHorizontalPlane` | horizontal plane estimated for this frame |
| 1 << 2 | `EstimatedVerticalPlane` (11.3) | vertical plane estimated for this frame |
| 1 << 3 | `ExistingPlane` | plane anchors, infinite |
| 1 << 4 | `ExistingPlaneUsingExtent` | plane anchors within their extent |
| 1 << 5 | `ExistingPlaneUsingGeometry` (11.3) | plane anchors within their geometry |

`ARHitTestResult`: `type`, `distance` (meters from the camera),
`localTransform` (relative to the anchor or the feature point), `worldTransform`,
`anchor` (only for existing-plane types). Results are sorted nearest first.
An implementation can build hit-testing on top of the raycasting engine.

## 4. Environment texturing

With environment texturing on, the session accumulates camera imagery of the
surroundings. Each `AREnvironmentProbeAnchor` gets a cube-map Metal texture of
the environment as seen from the probe's position (HDR when
`wantsHDREnvironmentTextures`), regenerated as more is seen. Automatic mode
also places probes itself. Face tracking (27.0) can generate an environment
texture at the device position (`environmentTexturingEnabled`).

## 5. Scene reconstruction (13.4)

With `sceneReconstruction` set (devices with a depth sensor), the session
builds a triangle mesh of the surroundings and publishes it as many
`ARMeshAnchor`s, each covering a region, updated as the mesh changes.

`ARMeshGeometry` (`NSSecureCoding`):

| Member | Type | Content |
|---|---|---|
| `vertices` | `ARGeometrySource` | float3 positions in the anchor's space |
| `normals` | `ARGeometrySource` | float3 per-vertex normals |
| `faces` | `ARGeometryElement` | triangles |
| `classification` | `ARGeometrySource`, nullable | one 8-bit `ARMeshClassification` per face, when classification was requested |

`ARGeometrySource` (`NSSecureCoding`): `buffer` (Metal buffer), `count`
(vectors), `format` (`MTLVertexFormat`), `componentsPerVector`, `offset`
(bytes), `stride` (bytes). Swift (14.0) adds subscripts that read one vector
as a float triple or one byte.

`ARGeometryElement` (`NSSecureCoding`): `buffer`, `count` (primitives),
`bytesPerIndex`, `indexCountPerPrimitive` (3 for triangles), `primitiveType`
(`ARGeometryPrimitiveType`: `Line` 0, `Triangle` 1). Swift (14.0) subscript
returns one primitive's indices as `[Int32]`.

`ARMeshClassification`: `None` 0, `Wall` 1, `Floor` 2, `Ceiling` 3, `Table` 4,
`Seat` 5, `Window` 6, `Door` 7 (same numbering as plane classification).

The `ARSessionRunOptionResetSceneReconstruction` option discards the mesh.

## 6. World maps (12.0)

`ARWorldMap` (`NSCopying`, `NSSecureCoding`) is the session's internal map of
a space: `center` and `extent` (meters, world space), `anchors` (read-write
copy of the anchors in the map — apps may edit the list before saving),
`rawFeaturePoints` (`ARPointCloud`).

- Obtain with `getCurrentWorldMapWithCompletionHandler:` while world tracking
  runs. Quality depends on `worldMappingStatus`; maps captured while the status
  is not "mapped" relocalize poorly. Errors: insufficient features (400) when
  too little has been seen, world-tracking failure, invalid configuration.
- Persist with `NSKeyedArchiver` (secure coding). The archive is a **black
  box** for apps: they never look inside. It is designed to be decoded across
  devices and OS versions with the "set error and return" decoding failure
  policy, so an unsupported map yields an error instead of an exception.
  Garbage data decodes to nil with a Cocoa "data not in the correct format"
  error (observed: `NSCocoaErrorDomain` 4864).
- Restore by setting `initialWorldMap` and running. The session then stays in
  limited/relocalizing until it recognizes the place, after which the map's
  anchors reappear in their saved positions and world coordinates match the
  saved session's. A map that cannot be used makes the run fail with
  `ARErrorCodeInvalidWorldMap` (302).

**Ycode position:** Ycode's world-map payload is its own format, wrapped in a
keyed archive of class `ARWorldMap` with the public properties encoded under
our own keys plus an opaque data blob. Maps are **not** expected to be
interchangeable with Apple devices (a real map holds Apple's proprietary
feature descriptors). Ycode's simulated-world mode can relocalize trivially,
because ground-truth poses are known (`simulated-world.md`). Only the
anchors' archive format (`anchors.md` §1.2) is matched, so that anchor lists
survive a round trip.

## 7. Reference images (11.3) and objects (12.0)

### 7.1 `ARReferenceImage` (`Sendable`)

| Member | Since | Meaning |
|---|---|---|
| `name` | 11.3 | Optional, read-write. |
| `physicalSize` | 11.3 | Size in meters (width as given; height from the aspect ratio). |
| `resourceGroupName` | 13.0 | AR resource group in the asset catalog the image came from, else nil. |
| `initWithCGImage:orientation:physicalWidth:` | 11.3 | From a `CGImage` with an EXIF orientation and the printed width in meters. Swift `init(_:orientation:physicalWidth:)`. |
| `initWithPixelBuffer:orientation:physicalWidth:` | 11.3 | Same from a `CVPixelBuffer`. |
| `referenceImagesInGroupNamed:bundle:` | 11.3 | All images of an AR resource group in the asset catalog (`Assets.car` of the given bundle, main bundle when nil). Nil when the group does not exist. |
| `validateWithCompletionHandler:` | 13.0 | Checks whether the image is good for detection (enough texture, not too uniform); the handler gets nil or an `ARErrorCodeInvalidReferenceImage` (300) error. Images from an asset catalog are validated at build time. |

Asset-catalog AR resource groups are compiled by `actool` into the app's
`Assets.car`; reading them is a CoreUI catalog lookup (the simulator logs an
attempt to open a catalog named "Assets" from the main bundle). Ycode needs a
catalog reader for this (shared with the asset-catalog work in
`specs/ide/asset-catalog.md`).

### 7.2 `ARReferenceObject` (`NSSecureCoding`, `Sendable`)

Two formats since iOS 27: legacy `.arobject` archives (scanned with object
scanning, exportable, mergeable; deprecated) and `.referenceobject` files
(trained in Create ML, shared with visionOS; may include a USDZ model). A
session may not mix them (error 301).

| Member | Since | Meaning |
|---|---|---|
| `name` | 12.0 | Optional, read-write. |
| `center`, `extent`, `scale` | 12.0 | Bounding box in the object's local space; extent × scale is the physical size in meters. |
| `resourceGroupName` | 13.0, deprecated 27.0 | Asset-catalog group (legacy only). |
| `rawFeaturePoints` | 12.0, deprecated 27.0 | Legacy features; empty point cloud for `.referenceobject`. |
| `usdzFile` | 27.0 | URL of an extracted USDZ model, if the file has one. |
| `referenceObjectsInGroupNamed:bundle:` | 12.0, deprecated 27.0 | Legacy asset-catalog loading. |
| `initWithArchiveURL:error:` | 12.0 | Load either format from a file URL. |
| `exportObjectToURL:previewImage:error:` | 12.0, deprecated 27.0 | Write a legacy archive (extension from `ARReferenceObjectArchiveExtension`, value `arobject`); not allowed for `.referenceobject` objects. |
| `referenceObjectByApplyingTransform:` | 12.0, deprecated 27.0 | Move the object's origin; returns the same object unchanged for `.referenceobject`. |
| `referenceObjectByMergingObject:error:` | 12.0, deprecated 27.0 | Align and merge two scans (error 401 when they share too few features); not for `.referenceobject`. |

Detection versus tracking (27.0): objects in `detectionObjects` are found and
then held still in world space (cheap; moved objects update late). Objects in
`trackingObjects` (`.referenceobject` only) are tracked at the full frame rate
(expensive; for hand-held or moving objects).

## 8. Collaboration (13.0)

With `collaborationEnabled`, each participant's session periodically emits
`ARCollaborationData` (Swift `ARSession.CollaborationData`, `NSSecureCoding`)
through `session:didOutputCollaborationData:`. The app serializes it (keyed
archive), sends it over its own transport to every other participant and
feeds what it receives into `updateWithCollaborationData:`. Each object has a
`priority`: `ARCollaborationDataPriorityCritical` 0 (send reliably) or
`ARCollaborationDataPriorityOptional` 1 (send fast; loss is tolerated). Once
the maps of two participants are merged, each session adds an
`ARParticipantAnchor` for the other device and shares app anchors (anchors
keep their `sessionIdentifier`, which tells which participant owns them).
Corrupt data is reported as error 304.

**Ycode position:** collaboration data is an opaque payload; only its
transport contract (secure coding, the priority flag, idempotent delivery) is
interop. Collaboration between a Ycode simulated device and a real device is
out of scope; between two Ycode simulated devices sharing one simulated world
it is straightforward (shared ground truth).

## 9. Geo tracking (14.0)

`ARGeoTrackingConfiguration` combines world tracking with GPS, compass and a
visual localization against Apple's map imagery, available only in supported
regions. Flow: check availability (class methods; `session.md` §3.3) → run →
`ARGeoTrackingStatus` progresses through states (`errors-and-states.md` §5)
→ once localized, `ARGeoAnchor`s are placed at their coordinates and
`getGeoLocationForPoint:completionHandler:` converts world points back to
coordinates. World axes in geo tracking: `coordinates.md` §2.

**Ycode position:** Ycode cannot localize against Apple's map data. In
simulated-world mode the simulated world carries its own geodetic reference
(origin latitude/longitude/altitude and heading), so geo states can be driven
to "localized" deterministically and conversions are exact.

## 10. App Clip Codes (14.3)

With `appClipCodeTrackingEnabled` the session detects App Clip Codes in the
image and adds `ARAppClipCodeAnchor`s whose URL is decoded asynchronously
(`anchors.md` §7). The code format is Apple's; Ycode can support it only in
simulated-world mode (the world declares where codes are and which URL each
encodes).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Names, enum values, availability | 4 | SDK headers and `.swiftinterface` |
| Semantics of targets, results, tracked raycasts, maps, collaboration, geo, reference images and objects | 1 | ARKit documentation and header documentation (summarized) |
| World-map garbage decode error, `referenceImagesInGroupNamed:` nil for a missing group, catalog lookup in the main bundle | 3 | `ARProbe` (simulator log and output) |
| `ARReferenceObjectArchiveExtension` value | 3 | `ARProbe` constants run |
| "Ycode position" paragraphs | — | Ycode design decisions |
