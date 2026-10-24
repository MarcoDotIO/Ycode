# ARKit spec: session and configurations

Part of `specs/frameworks/arkit/`. Names in `code` are interop identifiers
(Objective-C name first, Swift name after a slash where it differs). All
descriptions are our own. "Since" gives the first iOS version that has the
member. "Sim" marks what Apple's iOS 27.1 simulator does where it differs from
the device behavior (details in `simulator-baseline.md`).

## 1. Model

An app creates an `ARSession`, gives it a **configuration** object, and calls
run. The session then owns the camera and motion sensors, runs the tracking
techniques the configuration asks for, and publishes the result as a stream of
`ARFrame` snapshots (one per captured camera image) plus a set of `ARAnchor`
objects that change over time. The app reads the stream either by polling
`currentFrame` (renderers typically do this once per display refresh) or by
receiving delegate callbacks.

A session has no public state property. Observable states, which an
implementation should model internally:

| State | Entered by | Observable signs |
|---|---|---|
| idle | creation | `configuration` nil, `currentFrame` nil |
| running | a successful run | frames delivered; `configuration` is a copy of the last configuration run |
| paused | `pause`, or a failure | no frames; `currentFrame` keeps its last value on devices |
| interrupted | loss of sensor input while running (app in background, camera taken by another app or multitasking) | `sessionWasInterrupted:`; frames stop until `sessionInterruptionEnded:` |
| failed | a fatal error | `session:didFailWithError:`; the session is paused |

A failed or paused session can be run again with any configuration.

## 2. `ARSession` members

| Member | Kind | Since | Behavior |
|---|---|---|---|
| `identifier` | property, UUID, atomic, read-only | 13.0 | Identifies the running session. May change when run is called (device). Anchors added to the session record it as their `sessionIdentifier`; collaboration uses it to tell participants apart. Sim: assigned at creation and unchanged by run. |
| `delegate` | property, weak | 11.0 | Object conforming to `ARSessionDelegate` (§6). |
| `delegateQueue` | property, dispatch queue, nullable | 11.0 | Queue for delegate callbacks and for completion handlers of session methods. Nil means the main queue. |
| `currentFrame` | property, copy, nullable, read-only | 11.0 | The most recent frame. Nil before the first frame. |
| `configuration` | property, copy, nullable, read-only | 11.0 | The configuration in use. Nil before a successful run. Sim: stays nil after a run, because the run fails. |
| `runWithConfiguration:` | method | 11.0 | Same as the next one with no options. Not available in Swift. |
| `runWithConfiguration:options:` / `run(_:options:)` | method | 11.0 | Starts the session, or switches a running session to the new configuration at once. Returns immediately; failures are reported asynchronously through the delegate (§5). |
| `pause` | method | 11.0 | Stops sensor capture and processing. No more callbacks until the next run. Calling it on a session that never ran is harmless. |
| `addAnchor:` / `add(anchor:)` | method | 11.0 | Queues an app anchor; it appears in the next frame's `anchors` and is reported by `didAddAnchors`. The session stamps it with its `sessionIdentifier`. Harmless when not running (sim: no effect, no callback). |
| `removeAnchor:` / `remove(anchor:)` | method | 11.0 | Queues removal; the anchor is absent from later frames and reported by `didRemoveAnchors`. |
| `setWorldOrigin:` / `setWorldOrigin(relativeTransform:)` | method | 11.3 | Moves the world origin to the given pose expressed in the current world coordinates. Scale in the matrix is ignored. All later camera and anchor transforms are expressed relative to the new origin. |
| `getCurrentWorldMapWithCompletionHandler:` | method | 12.0 | Asynchronously snapshots the mapped space as an `ARWorldMap`. Only with world tracking (and configurations that run it); otherwise the handler gets an error. Handler runs on the delegate queue. Sim: the handler is never called. |
| `createReferenceObjectWithTransform:center:extent:completionHandler:` | method | 12.0, deprecated 27.0 | Builds a legacy reference object from features inside a box (pose `transform`, box `center` and `extent` in that pose's frame). Needs an object-scanning configuration. Handler on the delegate queue. Sim: never called. |
| `raycast:` | method | 13.0 | Synchronous one-shot raycast; returns results nearest first (possibly empty). See `scene-understanding.md` §1. Sim: empty. |
| `trackedRaycast:updateHandler:` | method | 13.0 | Starts a continuous raycast; returns an `ARTrackedRaycast` handle or nil (nil when the raycast cannot start or the configuration is not world tracking). Updates arrive on the delegate queue. Sim: nil. |
| `updateWithCollaborationData:` | method | 13.0 | Feeds data received from another participant. |
| `getGeoLocationForPoint:completionHandler:` | method | 14.0 | Converts a world position to latitude, longitude and altitude. Needs geo tracking in the localized state; otherwise the handler gets an error. Handler on the delegate queue. Sim: never called. |
| `captureHighResolutionFrameWithCompletion:` | method | 16.0 | Asks for one still-quality frame (an `ARFrame` whose image has the still resolution of the current video format). Errors 106 (another capture in progress) and 107 (capture failed). Sim: never called. |
| `captureHighResolutionFrameUsingPhotoSettings:completion:` | method | 26.0 | Same with caller-supplied photo settings (start from the video format's `defaultPhotoSettings`). |
| `viewLayer` | property, weak `CALayer` | 27.0 | The layer that shows the camera image. Renderers (`ARSCNView`, `ARSKView`, RealityKit views) set it. Needed before the view-rotation angle exists. |
| `viewRotationAngle` | property, degrees, atomic, read-only | 27.0 | Rotation to apply to a view so the displayed image stays level as the device rotates, tracking the system UI rotation. Normalized to [0, 360): 0 at landscape-right, 90 portrait, 180 landscape-left, 270 portrait-upside-down (interface orientations). NaN until `viewLayer` is set and on screen. Swift exposes it as an optional that is nil instead of NaN. Sim: NaN. |

`ARSession` is not usable on visionOS (deprecated there in favor of
`ARKitSession`/`ar_session_t`).

### 2.1 Run options (`ARSessionRunOptions` / `ARSession.RunOptions`)

Bit set; zero means "keep everything": tracking continues from the last known
pose and all anchors stay.

| Option | Bit | Since | Effect |
|---|---|---|---|
| `ARSessionRunOptionResetTracking` / `.resetTracking` | 1 << 0 | 11.0 | Start tracking afresh: new world origin at the current device pose (per the configuration's alignment), tracking state goes back to initializing. |
| `ARSessionRunOptionRemoveExistingAnchors` / `.removeExistingAnchors` | 1 << 1 | 11.0 | Remove all anchors (app anchors included); report them as removed. |
| `ARSessionRunOptionStopTrackedRaycasts` / `.stopTrackedRaycasts` | 1 << 2 | 13.0 | Stop every tracked raycast. |
| `ARSessionRunOptionResetSceneReconstruction` / `.resetSceneReconstruction` | 1 << 3 | 13.4 | Discard the reconstructed mesh (mesh anchors removed). |

Tracked raycasts also stop when tracking is reset, when the configuration
changes, or when their handle is deallocated.

## 3. Configurations

`ARConfiguration` is abstract (its `init`/`new` are unavailable); apps
instantiate one of the concrete subclasses. Configurations conform to
`NSCopying`; the session keeps a copy, so changing a configuration object after
run has no effect until it is run again.

### 3.1 Base class `ARConfiguration`

| Member | Kind | Since | Documented default / meaning |
|---|---|---|---|
| `isSupported` | class property | 11.0 | Whether this configuration class can run on this device. Each subclass answers for itself. |
| `supportedVideoFormats` | class property, array of `ARVideoFormat` | 11.3 | Formats this class can use on this device. The first element is the default format. |
| `videoFormat` | property | 11.3 | Camera format for the session; defaults to the first supported format. |
| `worldAlignment` | property, `ARWorldAlignment` | 11.0 | How the world axes are chosen (`coordinates.md` §2). Default gravity. |
| `lightEstimationEnabled` (getter `isLightEstimationEnabled`) | property, BOOL | 11.0 | Default YES. Frames carry an `ARLightEstimate` when on. |
| `providesAudioData` | property, BOOL | 11.0 | Default NO. When YES the session captures microphone audio and delivers sample buffers to the observer. |
| `frameSemantics` | property, `ARFrameSemantics` | 13.0 | Extra per-frame outputs (`frame-and-camera.md` §5). Default none. Asking for semantics the class does not support raises an exception (level 1; not observed in the simulator, which accepts any value). |
| `supportsFrameSemantics:` | class method | 13.0 | Whether a semantics set is supported by this class on this device. |
| `configurableCaptureDeviceForPrimaryCamera` | class property, nullable `AVCaptureDevice` | 16.0 | The capture device that feeds the rendered image, so apps can adjust focus, exposure and so on. Changing it may degrade tracking. |
| `recommendedVideoFormatFor4KResolution` | class property, nullable | 16.0 | A 4K format from the supported list, or nil. |
| `recommendedVideoFormatForHighResolutionFrameCapturing` | class property, nullable | 16.0 | The format best suited to high-resolution frame capture, or nil. |
| `videoHDRAllowed` | property, BOOL | 16.0 | Default NO. Permits HDR streaming when the chosen format supports it. |

`ARWorldAlignment` / `ARConfiguration.WorldAlignment`: `ARWorldAlignmentGravity`
(0), `ARWorldAlignmentGravityAndHeading` (1), `ARWorldAlignmentCamera` (2).

### 3.2 Concrete configurations

| Class | Since | Purpose | Camera |
|---|---|---|---|
| `ARWorldTrackingConfiguration` | 11.0 | Six-degree-of-freedom device tracking (visual-inertial odometry) with optional planes, images, objects, meshes, environment texturing, collaboration, world maps and simultaneous user-face tracking | back |
| `AROrientationTrackingConfiguration` | 11.0 | Three-degree-of-freedom tracking (rotation only; position stays at the origin) | back |
| `ARFaceTrackingConfiguration` | 11.0 | Face anchors from the front (depth-capable) camera; optional simultaneous world tracking with the back camera | front |
| `ARImageTrackingConfiguration` | 12.0 | Six-DoF tracking of known images only (no device world tracking); camera pose is not tracked against the world | back |
| `ARObjectScanningConfiguration` | 12.0, deprecated 27.0 | World tracking with extra feature detail for creating legacy reference objects | back |
| `ARBodyTrackingConfiguration` | 13.0 | World tracking plus a tracked human body (`ARBodyAnchor`); body-detection semantics on by default | back |
| `ARPositionalTrackingConfiguration` | 13.0 | Six-DoF tracking at the lowest camera resolution and frame rate (for apps that do not show the camera image) | back |
| `ARGeoTrackingConfiguration` | 14.0 | World tracking aligned to the Earth using location, heading and a map-based visual localization, for `ARGeoAnchor`s | back |

All of them declare `init` (and `new`, which Swift does not import) as their
initializer.

### 3.3 Options per configuration

"W" world, "O" orientation, "F" face, "I" image, "S" object scanning,
"B" body, "P" positional, "G" geo. Defaults are the documented device defaults.

| Property (ObjC getter if different) | Type | Default | W | O | F | I | S | B | P | G | Since |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `autoFocusEnabled` (`isAutoFocusEnabled`) | BOOL | YES | ✓ | ✓ | | ✓ | ✓ | ✓ | | | 11.3 (W, O) |
| `planeDetection` | `ARPlaneDetection` | none | ✓ | | | | ✓ | ✓ | ✓ | ✓ | 11.0 |
| `environmentTexturing` | `AREnvironmentTexturing` | none | ✓ | | | | | ✓ | | ✓ | 12.0 |
| `wantsHDREnvironmentTextures` | BOOL | YES | ✓ | | | | | ✓ | | ✓ | 13.0 |
| `initialWorldMap` | `ARWorldMap`, nullable | nil | ✓ | | | | | ✓ | ✓ | | 12.0 |
| `detectionImages` | set of `ARReferenceImage` | empty | ✓ (null-resettable) | | | | | ✓ | | ✓ (null-resettable) | 11.3 |
| `trackingImages` | set of `ARReferenceImage` | empty | | | | ✓ | | | | | 12.0 |
| `automaticImageScaleEstimationEnabled` | BOOL | NO | ✓ | | | | | ✓ | | ✓ | 13.0 |
| `maximumNumberOfTrackedImages` | integer | 0 (W, B, G); 1 (I) | ✓ | | | ✓ | | ✓ | | ✓ | 12.0 |
| `detectionObjects` | set of `ARReferenceObject` | empty | ✓ | | | | | | | ✓ | 12.0 |
| `trackingObjects` | set of `ARReferenceObject` | empty | ✓ | | | | | | | ✓ | 27.0 |
| `collaborationEnabled` (`isCollaborationEnabled`) | BOOL | NO | ✓ | | | | | | | | 13.0 |
| `userFaceTrackingEnabled` (getter `userFaceTrackingEnabled`) | BOOL | NO | ✓ | | | | | | | | 13.0 |
| `appClipCodeTrackingEnabled` | BOOL | NO | ✓ | | | | | ✓ | | ✓ | 14.3 |
| `sceneReconstruction` | `ARSceneReconstruction` | none | ✓ | | | | | | | | 13.4 |
| `maximumNumberOfTrackedFaces` | integer | 1 | | | ✓ | | | | | | 13.0 |
| `worldTrackingEnabled` (`isWorldTrackingEnabled`) | BOOL | NO | | | ✓ | | | | | | 13.0 |
| `environmentTexturingEnabled` (`isEnvironmentTexturingEnabled`) | BOOL | NO | | | ✓ | | | | | | 27.0 |
| `automaticSkeletonScaleEstimationEnabled` | BOOL | NO | | | | | | ✓ | | | 13.0 |

`ARGeoTrackingConfiguration` makes the inherited `worldAlignment` unavailable
(geo tracking fixes the axes itself: `coordinates.md` §2).

Class-level capability queries per configuration:

| Query | On | Since | Meaning |
|---|---|---|---|
| `supportsUserFaceTracking` | W | 13.0 | Front-camera face tracking can run alongside world tracking. |
| `supportsAppClipCodeTracking` | W, B, G | 14.3 | App Clip Codes can be detected. |
| `supportsSceneReconstruction:` | W | 13.4 | The given reconstruction type is available (needs a depth sensor). |
| `supportedNumberOfTrackedFaces` | F | 13.0 | Maximum faces tracked at once on this device. |
| `supportsWorldTracking` | F | 13.0 | Face tracking can run alongside world tracking. |
| `checkAvailabilityWithCompletionHandler:` | G | 14.0 | Gets a location fix in the background, then reports whether geo tracking works there (BOOL plus optional error). Handler on an arbitrary serial queue. Swift does not import an async form. |
| `checkAvailabilityAtCoordinate:completionHandler:` | G | 14.0 | Same for a given coordinate. |
| `classificationSupported` (`isClassificationSupported`) on `ARPlaneAnchor` | — | 12.0 | Plane classification is available on this device. |

Related option types:

- `ARPlaneDetection` / `ARWorldTrackingConfiguration.PlaneDetection`:
  `ARPlaneDetectionNone` 0, `ARPlaneDetectionHorizontal` 1 << 0,
  `ARPlaneDetectionVertical` 1 << 1 (11.3).
- `AREnvironmentTexturing` / `ARWorldTrackingConfiguration.EnvironmentTexturing`:
  `AREnvironmentTexturingNone` 0, `AREnvironmentTexturingManual` 1 (textures only
  for probes the app adds), `AREnvironmentTexturingAutomatic` 2 (the session
  also places probes).
- `ARSceneReconstruction` / `ARConfiguration.SceneReconstruction`:
  `ARSceneReconstructionNone` 0, `ARSceneReconstructionMesh` 1 << 0,
  `ARSceneReconstructionMeshWithClassification` (1 << 1) | (1 << 0).
- `ARFrameSemantics`: see `frame-and-camera.md` §5.

### 3.4 Validation

- Running a configuration whose class reports `isSupported == NO` fails with
  `ARErrorCodeUnsupportedConfiguration` (100) through the delegate (§5). It
  does not throw.
- Inconsistent settings (for example mixing legacy `.arobject` and
  `.referenceobject` reference objects in one session) fail with
  `ARErrorCodeInvalidReferenceObject` (301); bad images with 300; an unusable
  world map with 302; other invalid combinations with
  `ARErrorCodeInvalidConfiguration` (303).
- Unsupported frame semantics raise an Objective-C exception (level 1).

## 4. Info.plist and privacy

| Key | Role |
|---|---|
| `NSCameraUsageDescription` | Required: every configuration uses a camera. The system asks for camera permission the first time a session runs. Without permission the session fails with `ARErrorCodeCameraUnauthorized` (103). |
| `NSMicrophoneUsageDescription` | Needed when `providesAudioData` is YES; denial gives `ARErrorCodeMicrophoneUnauthorized` (104). |
| `NSLocationWhenInUseUsageDescription` | Needed for geo tracking; denial gives `ARErrorCodeLocationUnauthorized` (105) and the geo state reason "needs location permissions". |
| `UIRequiredDeviceCapabilities` containing `arkit` | Restricts installation to ARKit-capable devices (App Store and device install). The iOS simulator installs and launches such an app anyway (`simulator-baseline.md`). |

## 5. Failures

When a session fails it pauses itself and calls `session:didFailWithError:`
once, on the delegate queue, **after** the run call has returned (observed
asynchronously in the simulator; the error is not delivered inside the run
call). The error domain is `ARErrorDomain` (string value
`com.apple.arkit.error`); codes are in `errors-and-states.md` §1. The error's
`userInfo` carries a localized description and a localized failure reason.

## 6. Delegate protocols

### 6.1 `ARSessionObserver` (all optional)

| Method | Since | When |
|---|---|---|
| `session:didFailWithError:` | 11.0 | Session failed; it is now paused. |
| `session:cameraDidChangeTrackingState:` | 11.0 | The camera's tracking state or reason changed. Receives the `ARCamera` of the frame where the change happened. |
| `sessionWasInterrupted:` | 11.0 | Required sensor data stopped (camera interrupted: app backgrounded, camera used by another foreground app, multiple foreground apps). No frames until the interruption ends. |
| `sessionInterruptionEnded:` | 11.0 | Sensor data is back; the session continues from its last state, so content may be misaligned if the device moved. |
| `sessionShouldAttemptRelocalization:` | 11.3 | Asked after a pause or interruption, on resume. Returning YES puts tracking into limited/relocalizing until the session recognizes the earlier map (can last indefinitely); the app can give up by running with reset tracking. Returning NO (or not implementing it) means tracking restarts without relocalization. |
| `session:didOutputAudioSampleBuffer:` | 11.0 | One `CMSampleBuffer` of microphone audio, when `providesAudioData` is on. |
| `session:didOutputCollaborationData:` | 13.0 | The session produced data that the app must send to every other participant (`scene-understanding.md` §6). |
| `session:didChangeGeoTrackingStatus:` | 14.0 | Geo-tracking status changed. |
| `session:didChangeViewRotationAngle:` | 27.0 | A new view-rotation angle (degrees, normalized as in §2) is available. |

### 6.2 `ARSessionDelegate` (inherits `ARSessionObserver`; all optional)

| Method | Since | When |
|---|---|---|
| `session:didUpdateFrame:` | 11.0 | A new frame was produced. |
| `session:didAddAnchors:` | 11.0 | Anchors were added (by the app or detected by the session). |
| `session:didUpdateAnchors:` | 11.0 | Existing anchors changed (pose, geometry, tracking flag, …). |
| `session:didRemoveAnchors:` | 11.0 | Anchors were removed (by the app, by merging planes, by reset options). |

Anchor arrays contain the anchor objects of the current frame; each callback
groups all anchors that changed in the same way for that frame.

### 6.3 `ARSessionProviding`

A protocol with one read-only `session` property. Views that own a session
adopt it (`ARSCNView`, `ARSKView`) so that `ARCoachingOverlayView` can find the
session through its `sessionProvider` outlet. Swift classes that implement it
should make the property observable (Objective-C dynamic) so that changes are
seen.

### 6.4 Threads and ordering

- All delegate callbacks and session-method completion handlers run on
  `delegateQueue`, or the main queue when it is nil (level 1; level 3 in the
  simulator for `didFailWithError` on both the main queue and a custom serial
  queue). `checkAvailability…` handlers are the exception: an arbitrary serial
  queue on devices (the simulator calls them synchronously on the calling
  thread).
- Delegate callbacks for one session are serialized (one queue).
- Per frame, the order Ycode uses: anchor callbacks for that frame (added,
  then updated, then removed) and then `didUpdateFrame` with a frame whose
  `anchors` already reflect those changes; `cameraDidChangeTrackingState`
  before the `didUpdateFrame` of the frame that changed it. The device order
  has **not** been verified on hardware (open question in `plan.md`); the
  invariant that must hold is that every anchor reported as added is present
  in `currentFrame.anchors` when the callback runs, and every removed anchor
  is absent.
- Frames are pooled by the capture pipeline: an app that keeps many frames
  alive (for example by storing them from `didUpdateFrame`) starves the pool
  and the session stops delivering new frames until they are released. An
  implementation should use a bounded pool (a small fixed number of camera
  buffers) and drop frames rather than block capture when the pool is empty.
- After a tracking-state change caused by run: the expected sequence on a
  device is not-available → limited(initializing) → normal, each reported
  once through `cameraDidChangeTrackingState`.
- After `pause`, no further callbacks for that run are delivered, including
  late anchor updates.

## 7. Swift surface (summary)

The Swift overlay renames and refines several items:

| Objective-C | Swift |
|---|---|
| `ARSessionRunOptions` | `ARSession.RunOptions` |
| `ARCollaborationData` | `ARSession.CollaborationData` |
| `ARWorldAlignment` | `ARConfiguration.WorldAlignment` |
| `ARFrameSemantics` | `ARConfiguration.FrameSemantics` |
| `ARSceneReconstruction` | `ARConfiguration.SceneReconstruction` |
| `ARVideoFormat` | `ARConfiguration.VideoFormat` |
| `ARPlaneDetection` | `ARWorldTrackingConfiguration.PlaneDetection` |
| `AREnvironmentTexturing` | `ARWorldTrackingConfiguration.EnvironmentTexturing` |
| `viewRotationAngle` (CGFloat, NaN when unknown) | `viewRotationAngle` (optional CGFloat) |
| `runWithConfiguration:` | not imported; use `run(_:options:)` (options default to none in Swift usage) |

The remaining Swift refinements are listed in the files where the types live.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Member names, kinds, availability, Swift names, option bit values | 4 | iOS 27.1 SDK public headers and the ARKit `.swiftinterface`, read and described, not copied |
| Member semantics (run, pause, options, observer callbacks, defaults, queues) | 1 | ARKit developer documentation pages; SDK header documentation summarized |
| Interruption causes, relocalization behavior | 1 | same |
| Info.plist keys and permission behavior | 1 | "Verifying Device Support and User Permission" page; error codes in the SDK |
| Simulator remarks ("Sim:") and asynchronous failure delivery, queue behavior in the simulator | 3 | `ARProbe` runs on `ycode-test-arkit-1` (iOS 27.1) |
| Frame-pool starvation | 1 | long-standing guidance in ARKit documentation and sample code; not measured |
| Callback order per frame on devices | — | **unverified**; Ycode decision pending a hardware check |
| Framework layout | 4 | `.tbd` install names, header includes, runtime bundle file list |
