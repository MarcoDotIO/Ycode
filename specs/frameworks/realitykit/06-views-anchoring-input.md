# RealityKit 6: views, renderer, anchoring, tracking, input, synchronization

Status: draft round 0. Sources: SDK module metadata (level 4),
documentation (level 1), probe runs (level 3, **[rv-basic]**,
**[rv-nocamera]**, **[rv-square]**, **[rv-spatial]**, **[arview-nonar]**,
**[arview-ar]**, **[renderer]**).

## 1. `RealityView` on iOS (SwiftUI, iOS 18)

- Initialisers on iOS: `RealityView(make:update:)` and
  `RealityView(make:update:placeholder:)`. `make` is an async main-actor
  closure that receives an `inout RealityViewCameraContent`; `update`
  runs on SwiftUI updates. The attachment initialisers and
  `RealityViewAttachments` are **visionOS only** in the 27.1 SDK.
- `RealityViewCameraContent` (iOS only): `entities` (the root
  collection; `add`, `remove`), `subscribe(to:on:componentType:_:)`,
  `camera` (`RealityViewCamera.virtual` or `.spatialTracking`),
  `cameraTarget`, `environment` (`RealityViewEnvironment.default` or
  `.skybox(EnvironmentResource)`), `audioListener`, `renderingEffects`
  (`03-rendering.md` §7), `animate(body:completion:)` (26), and the
  projection API (`project(point:to:)`, `unproject(_:from:to:ontoPlane:)`,
  `ray(through:in:to:)`, `entity(at:in:)`, `entities(at:in:)`,
  `hitTest(point:in:query:mask:)`).
- Modifiers: `realityViewCameraControls(_:)` (`CameraControls` none,
  orbit, pan, tilt, dolly) and `realityViewLayoutBehavior(_:)` (26:
  flexible, centered, fixed size).
- Observed: `make` ran once at first display; the first
  `SceneEvents.Update` came 0.05–0.16 s later; entities added in `make`
  are in the scene immediately (`scene != nil`, `isAnchored == true`)
  **[rv-basic]**. The view draws over the SwiftUI background.
- Camera: a `PerspectiveCamera` entity in the content is used as the view
  camera; otherwise the default virtual camera is at (0, 0, 2) facing −Z
  with a **vertical field of view ≈ 65°** whatever the aspect ratio (focal
  length 532.1 pt for a 466 × 678 pt view, 157.0 pt for a 300 × 200 pt
  view; 2·atan(339/532.1) = 2·atan(100/157.0) = 65.0°) **[rv-nocamera]**,
  **[rv-square]**.

## 2. `ARView` (UIKit, iOS 13; not visionOS)

- `ARView(frame:cameraMode:automaticallyConfigureSession:)`;
  `CameraMode` `.ar` (camera feed, ARKit pose) or `.nonAR` (virtual
  camera; the scene's `PerspectiveCamera`, else the default camera).
- `scene` (anchors are the roots), `session` (`ARSession`),
  `automaticallyConfigureSession` (the view runs a world-tracking
  configuration itself), `cameraTransform`, `physicsOrigin`,
  `audioListener`, `contentScaleFactor` (3.0 on the iPhone Duo
  simulator), `snapshot(saveToHDR:completion:)` (our snapshot was
  1398 × 2034 at image scale 1, i.e. device pixels).
- `environment`: `background` (`cameraFeed(exposureCompensation:)`,
  `skybox(_:)`, `color(_:)`), `lighting` (IBL resource and intensity
  exponent), `reverb` (`noReverb`, `preset(…)`, `automatic`),
  `sceneUnderstanding.options` (`occlusion`, `receivesLighting`,
  `collision`, `physics`, `default`).
- `debugOptions` (`showPhysics`, `showStatistics`, `showWorldOrigin`,
  `showAnchorOrigins`, `showAnchorGeometry`, `showFeaturePoints`,
  `showSceneUnderstanding`); default 0.
- `renderOptions` raw values **[arview-…]**: `disableCameraGrain` 1,
  `disableGroundingShadows` 4, `disableMotionBlur` 8,
  `disableDepthOfField` 16, `disableHDR` 32, `disablePersonOcclusion` 128,
  `disableAREnvironmentLighting` 256, `disableFaceMesh` 1024 (2 and 64 are
  the deprecated `disableAutomaticLighting` and `disableFaceOcclusions`).
  Default in the simulator: 56 = motion blur, depth of field and HDR
  disabled (in both camera modes).
- Picking and AR ray casts: `project`, `unproject(_:ontoPlane:)`,
  `ray(through:)`, `hitTest(_:query:mask:)`, `entity(at:)`,
  `entities(at:)` (collision shapes), `raycast(from:allowing:alignment:)`,
  `makeRaycastQuery`, `trackedRaycast` (ARKit ray casts against
  real-world estimates; zero results in the simulator).
- Gestures: `installGestures(_:for:)` with `EntityGestures`
  `translation`, `rotation`, `scale`, `all` on an entity with collision
  installs `EntityTranslationGestureRecognizer`,
  `EntityRotationGestureRecognizer`, `EntityScaleGestureRecognizer`
  (UIKit recognizers that expose `entity`, `location(in:)`, translation,
  velocity).
- `renderCallbacks` (`prepareWithDevice`, `postProcess`), §7 of
  `03-rendering.md`.

## 3. `RealityRenderer` (iOS 18): offscreen rendering

- An independent scene: `entities`, `activeCamera`, `cameraSettings`
  (`colorBackground` `.color(CGColor)` or `.outputTexture()`,
  `isToneMappingEnabled`, `antialiasing`), `lighting` (IBL),
  `audioListener` (27), event subscription.
- `update(_:)` advances the simulation; `updateAndRender(deltaTime:
  cameraOutput:whenScheduled:onComplete:actionsBeforeRender:
  actionsAfterRender:)` renders into app-provided Metal textures
  (`CameraOutput` with colour textures and relative viewports;
  `MetalEventAction.wait/signal` to synchronise with the app's GPU work).
- Observed **[renderer]**: into a 256 × 256 `bgra8Unorm_srgb` shared
  texture the completion handler ran 0.078 s after submission; the
  background colour sRGB (0.1, 0.1, 0.3) read back as (25, 25, 74);
  the green metallic sphere and the grey floor were where the camera
  predicts. The renderer object must be kept alive until completion (a
  renderer released right after submitting never called back).
- For Ycode this is the best **headless conformance harness**: tests can
  render a scene and compare pixels without a window or screenshots
  (`10-plan.md` §2).

## 4. Anchoring

- `AnchoringComponent(target:trackingMode:physicsSimulation:)`;
  `AnchorEntity` initialisers wrap it. Targets
  (`AnchoringComponent.Target`): `.world(transform:)`,
  `.plane(alignment, classification, minimumBounds)` (alignment
  horizontal/vertical/any; classification wall, floor, ceiling, table,
  seat, any), `.image(group:name:)`, `.referenceImage(from:)` (18),
  `.object(group:name:)`, `.referenceObject(from:)` (18), `.face`,
  `.body`, `.camera`, `.anchor(identifier:)` (an `ARAnchor`), and on
  visionOS hand, head, accessory. `AnchorEntity(raycastResult:)`,
  `AnchorEntity(anchor:)` bind to ARKit results.
- `TrackingMode` `.once` (place and stop following) or `.continuous`;
  `PhysicsSimulation` `.none` or `.isolated` (an anchor's subtree gets its
  own simulation, 18).
- `HasAnchoring.reanchor(_:preservingWorldTransform:)`,
  `anchorIdentifier`; `isAnchored` on entities; events
  `SceneEvents.AnchoredStateChanged` and (26) `AnchorStateEvents.DidAnchor`
  (`newAnchor`, `reanchor`), `WillUnanchor` (`anchorDisqualified`,
  `authorizationFailed`), `DidFailToAnchor` (`addAnchorFailed`,
  `maximumLimitReached`, `anchorNotSupported`, `unspecified`).
- Rule: content under an anchor that is not anchored is not rendered.
- Observed: `AnchorEntity(world:)` is anchored at once in every view;
  `AnchorEntity(plane: .horizontal)` never anchored in `RealityView`
  (virtual camera), non-AR `ARView` or AR `ARView` on the simulator
  **[rv-basic]**, **[arview-…]**.

## 5. `SpatialTrackingSession` (iOS 18)

Asks for tracking and scene-understanding capabilities before using AR
anchors in `RealityView` with the `.spatialTracking` camera.
`Configuration(tracking: [AnchorCapability], sceneUnderstanding:
[SceneUnderstandingCapability], camera: .back/.front)`; anchor
capabilities `world`, `plane`, `image`, `object`, `camera`, `face`,
`body` (iOS); scene understanding `collision`, `physics`, `shadow`,
`occlusion`. `run(_:)` returns `UnavailableCapabilities` (anchor,
scene understanding, missing camera authorisation) or nil when all are
available; `stop()`.
Observed on the simulator **[rv-spatial]**: every requested capability was
unavailable (anchor: camera, world, plane, image; scene understanding:
occlusion, collision), camera authorisation was not reported missing,
the plane-anchored content never appeared, and the view stayed blank.

## 6. Input

- SwiftUI (18): gestures on `RealityView` are targeted with
  `.targetedToAnyEntity()`, `.targetedToEntity(_:)`,
  `.targetedToEntity(where:)`; the value is an `EntityTargetValue`
  (gesture value, `entity`, conversion helpers `convert`/`unproject` to
  scene or entity space). Only entities with `InputTargetComponent` (and
  collision shapes) are hit; `allowedInputTypes` `direct`, `indirect`,
  `all`.
- `GestureComponent` (iOS 26) attaches a gesture to an entity.
- UIKit: §2 gesture recognizers; `ARView.entity(at:)` for taps.
- `HoverEffectComponent`, `ManipulationComponent` and system manipulation
  are visionOS-centred.

## 7. Attachments

SwiftUI views placed in the 3D scene (`RealityView` `attachments:`,
`ViewAttachmentComponent`) are not available on iOS in the 27.1 SDK.
`TextComponent` (18) is the iOS way to show text panels in 3D.

## 8. Synchronization (networking)

- Every entity has a `SynchronizationComponent` (identifier, `isOwner`,
  `ownershipTransferMode` `.autoAccept`/`.manual`).
  `HasSynchronization`: `isOwner`, `requestOwnership(timeout:_:)` →
  `.granted`/`.timedOut`, `withUnsynchronized(_:)`.
- A scene's `synchronizationService` (`SynchronizationService` protocol:
  entity for identifier, owner, give ownership) replicates entities and
  components between peers. The provided implementation is
  `MultipeerConnectivityService(session: MCSession)` with `startSync`,
  `stopSync`, handshake settings; `NetworkCompatibilityToken` checks
  protocol compatibility. Events `SynchronizationEvents.OwnershipRequest`
  and `.OwnershipChanged`.
- The replication wire protocol is not public. An open implementation
  defines its own protocol behind the same API (round 7); interoperating
  with Apple devices is out of scope.

## Evidence

| Claim | Level | Source |
|---|---|---|
| API names and platform availability (attachments visionOS-only on 27.1) | 4 | SDK `.swiftinterface` |
| `RealityView` make/update behaviour, default camera and FOV | 3 | **[rv-basic]**, **[rv-nocamera]**, **[rv-square]** |
| `ARView` defaults, render option values, snapshot size, hit tests | 3 | **[arview-nonar]**, **[arview-ar]** (round 2) |
| `RealityRenderer` offscreen results | 3 | **[renderer]** (round 2) |
| Anchoring outcomes | 3 | all view modes |
| `SpatialTrackingSession` on the simulator | 3 | **[rv-spatial]** |
| Purposes of APIs | 1 | developer.apple.com symbol pages (paraphrased) |
