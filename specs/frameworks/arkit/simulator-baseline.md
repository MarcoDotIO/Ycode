# ARKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/arkit/`. This is what an ARKit app sees in the
reference simulator (Xcode 27.1, iOS 27.1 runtime 24A94401, device type
iPhone Duo, Apple-silicon Mac). Ycode's simulator must behave the same way
**by default**, before the optional simulated-world feature is switched on
(`simulated-world.md`). Every statement here is level 3 (our own probe app,
`research/experiments/arkit/ARProbe`, observations in
`research/notes/arkit-simulator-observations-2026-10-19.md`) unless marked.

## 1. Summary

ARKit links and loads, every class exists and can be instantiated, but the
simulator has no AR capability: every capability query answers "no", every
session run fails with `ARErrorCodeUnsupportedConfiguration` (100), no frame
is ever produced, and the views render only their non-AR content. Many objects
behave like **inert stand-ins**: they accept property writes, but defaults
are zero, copies lose state, and several asynchronous requests never call
their completion handlers. Apps written defensively (checking `isSupported`)
show their non-AR path; apps that do not check get a failure callback.

## 2. Capability queries

For all eight configuration classes (world, orientation, face, image, object
scanning, body, positional, geo):

| Query | Result |
|---|---|
| `isSupported` | NO |
| `supportedVideoFormats` | empty array |
| `supportsFrameSemantics:` (each of the five semantics) | NO |
| `configurableCaptureDeviceForPrimaryCamera` | nil |
| `recommendedVideoFormatFor4KResolution`, `…ForHighResolutionFrameCapturing` | nil |
| `supportsUserFaceTracking`, `supportsAppClipCodeTracking` (where present) | NO |
| `supportsSceneReconstruction:` (mesh, mesh with classification) | NO |
| `ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces` | 0 |
| `ARFaceTrackingConfiguration.supportsWorldTracking` | NO |
| `ARPlaneAnchor.classificationSupported` | **YES** (the only "yes") |
| `ARGeoTrackingConfiguration checkAvailability…` (both forms) | handler called with NO and a nil error, **synchronously on the calling thread** before the method returns |

Camera: `AVCaptureDevice` reports no default video device and authorization
"not determined"; no permission prompt ever appears (with or without
`NSCameraUsageDescription` in Info.plist, the behavior is identical).

## 3. Configuration objects

- `init` works for every class and returns a distinct object; `copy`
  returns a new object of the same class.
- **All properties start at zero/NO/nil**, including those documented to
  default to YES or 1 (`lightEstimationEnabled`, `autoFocusEnabled`,
  `wantsHDREnvironmentTextures`, `maximumNumberOfTrackedFaces`,
  `ARImageTrackingConfiguration.maximumNumberOfTrackedImages`). `videoFormat`
  is nil even though the property is declared non-null (a Swift app that reads
  it gets a nil bridged into a non-optional — a crash hazard to reproduce
  faithfully, not to fix).
- Setters store values: writing 1 to each scalar property reads back 1, with
  one exception observed — `appClipCodeTrackingEnabled` on world tracking stays
  NO (it stores on body and geo configurations).
- `copy` does **not** carry stored values over: a copy of a configuration with
  light estimation turned on reports it off.
- No exception on any setter, including unsupported frame semantics, scene
  reconstruction, or user face tracking.
- `description` prints only the class name and address.
- Set-valued properties (`detectionImages`, `trackingImages`,
  `detectionObjects`, `trackingObjects`) read nil on a fresh object although
  they are declared non-null; assigning an empty set stores it; assigning nil
  to the null-resettable `detectionImages` reads back nil (not an empty set).

## 4. Sessions

- `ARSession` creation works; `identifier` is a fresh UUID, unchanged by run.
- `viewRotationAngle` is NaN (Swift: nil); no rotation callbacks occur.
- `runWithConfiguration:options:` returns normally, then the delegate gets
  exactly one `session:didFailWithError:` with domain `com.apple.arkit.error`,
  code 100, `userInfo` holding only a localized description and a localized
  failure reason (meaning: the configuration is not supported on this
  device). Delivered **asynchronously**: on a custom delegate queue it arrives
  immediately after run returns; on the main queue it arrives on a later turn
  of the main run loop (in the probe, after the app's scene connected). Every
  configuration class, every run option, and frame semantics make no
  difference. Re-running a failed session fails again the same way.
- After the failure `configuration` and `currentFrame` stay nil. There are no
  tracking-state, interruption, frame, anchor, audio, collaboration or geo
  callbacks, ever.
- `addAnchor:`, `removeAnchor:`, `setWorldOrigin:`, `pause` (even on a
  never-run session): no effect, no exception, no callback; an added anchor's
  `sessionIdentifier` stays nil.
- `raycast:` returns an empty array; `trackedRaycast:updateHandler:` returns
  nil.
- **Never-called completion handlers** (waited more than two minutes):
  `getCurrentWorldMapWithCompletionHandler:`,
  `createReferenceObjectWithTransform:…`,
  `getGeoLocationForPoint:completionHandler:`,
  `captureHighResolutionFrameWithCompletion:`. Apps that wait on these hang
  in the reference simulator; Ycode reproduces that by default.

## 5. Data objects

| Object | Behavior |
|---|---|
| `ARAnchor` (`initWithTransform:`, `initWithName:transform:`) | Fully functional: stores name and transform, copies keep the identifier and compare equal, secure archiving round-trips (key list in `anchors.md` §1.2). |
| `AREnvironmentProbeAnchor` | Stores the extent; `initWithTransform:` gives an infinite extent; texture nil. |
| `ARGeoAnchor` | Inert: coordinate reads (0, 0), altitude 0 and source unknown regardless of the arguments; transform zero; not tracked. |
| `ARRaycastQuery` (app-created) | Inert: origin, direction, target and alignment all read zero regardless of the arguments. |
| `ARFaceGeometry initWithBlendShapes:` | Returns an object (also for the neutral, empty dictionary) with zero vertices, texture coordinates and triangles. |
| `ARSkeletonDefinition.defaultBody2DSkeletonDefinition` | Fully populated: 19 joints with names and parents (`anchors.md` §6). |
| `ARSkeletonDefinition.defaultBody3DSkeletonDefinition` | Empty: zero joints; index lookups give `NSNotFound`; `neutralBodySkeleton3D` is an object with zero joints; model transforms looked up by name have a zero translation, and an unknown name does not give NaN (first element read 1.0). |
| `ARReferenceImage initWithCGImage:…` | Stores the physical size (height from the aspect ratio); name and group nil. Creating the first one took several seconds (one-time framework start-up). |
| `ARReferenceImage validateWithCompletionHandler:` | Always error 100 (also for a uniform gray image), on the main queue, about 1–1.5 s later. |
| `ARReferenceImage referenceImagesInGroupNamed:bundle:` | nil for a missing group; the framework tries to open the main bundle's "Assets" catalog. |
| `ARReferenceObject initWithArchiveURL:error:` | nil **without** setting an error, for a bogus file and for a missing file. |
| `ARWorldMap` from garbage data via secure unarchiving | nil with the standard Cocoa format error (`NSCocoaErrorDomain` 4864). |
| `ARMatteGenerator initWithDevice:matteResolution:` | Returns an object (with the simulator's Metal device). |
| `ARSCNPlaneGeometry planeGeometryWithDevice:` | Returns a geometry. |
| `ARSCNFaceGeometry faceGeometryWithDevice:` | nil. |

## 6. Views

| View | What the app sees |
|---|---|
| `ARSCNView` | `session` is **nil** (so every call through it is a no-op and no failure is ever reported to the view's delegate); `automaticallyUpdatesLighting`, `rendersCameraGrain`, `rendersMotionBlur` read NO. The view renders its SceneKit scene like a plain `SCNView`: no camera background, no AR camera — SceneKit's default camera is created to frame the content (in the probe a 10 cm box at −0.5 m filled the screen), the AR debug options (world origin, feature points) draw nothing, and the statistics bar shows 0 fps (on-demand rendering). `raycastQueryFromPoint:` returns nil. |
| `ARSKView` | `session` nil; the SpriteKit scene renders on its default dark gray background; no camera image, no anchors. |
| `ARCoachingOverlayView` | Defaults: goal tracking (0), `activatesAutomatically` **NO**, inactive, no session. `setActive:YES animated:` leaves it inactive; nothing is drawn; no delegate callbacks — with a stand-alone session or with an `ARSCNView`'s (nil) session. |

Screenshots (kept in `research/dirty/arkit/`, not committed): the
`ARSCNView` app shows the red box full-screen with the SceneKit statistics
bar; the `ARSKView` app shows a uniform dark gray view; the coaching-overlay
app shows the app's own white background and label only.

## 7. Installation and Info.plist

- An app whose `UIRequiredDeviceCapabilities` contains `arkit` installs and
  launches normally (`simctl install` succeeds). The simulator device type's
  `capabilities.plist` has no `arkit` key and no camera keys (level 2), so a
  capability check, if any, has nothing to match.
- `NSCameraUsageDescription` present or absent: no difference.

## 8. What Ycode must do (baseline mode)

1. Ship an ARKit framework whose public classes exist with the full
   interface of the other files in this directory.
2. In baseline mode, reproduce sections 2–7 exactly: capability answers,
   zeroed defaults, asynchronous error 100 on run, inert data objects, nil
   view sessions, the never-firing completion handlers, the populated 2D
   skeleton definition, `classificationSupported == YES`.
3. Provide its own localized error text (not Apple's) with the same two
   `userInfo` keys.
4. Switch to full behavior only when the simulated-world feature is enabled
   for the device (a per-device setting owned by the simulator host).

## Evidence

| Section | Level | Source |
|---|---|---|
| 2–6 | 3 | `ARProbe` (`-probe all`, `-ui scn|sk|coach|coachscn`) on `ycode-test-arkit-1`, iOS 27.1, three app variants; raw logs and screenshots in `research/dirty/arkit/` |
| 7 | 2, 3 | device type `capabilities.plist` (plutil); `simctl install` of the `UIRequiredDeviceCapabilities` variant |
| 8 | — | Ycode decision |
