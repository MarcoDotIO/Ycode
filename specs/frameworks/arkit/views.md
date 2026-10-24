# ARKit spec: views and rendering helpers

Part of `specs/frameworks/arkit/`. Conventions as in `session.md`. On devices
these classes live in the ARKitUI sub-framework (`README.md`).

## 1. What any renderer does with a session

`ARSCNView`, `ARSKView` and RealityKit's views all follow one pattern, which
is also what an app's own Metal renderer does:

1. Own an `ARSession` (created with the view) and expose it as `session`
   (`ARSessionProviding`).
2. Set the session's `viewLayer` to the layer that shows the camera image
   (27.0) and follow `viewRotationAngle` (or, before 27.0, the interface
   orientation).
3. On every display refresh, take `session.currentFrame`, draw
   `capturedImage` as the background using the frame's display transform for
   the view's size and angle, and set the virtual camera from
   `camera.viewMatrix…` and `camera.projectionMatrix…` for the same size and
   angle.
4. Keep a scene-graph node per anchor and update its transform from the
   frame's anchors.
5. Optionally apply light estimates, camera grain and motion blur.

Rendering is driven by the display, not by `didUpdateFrame`; the frame rate of
the camera and of the display may differ.

## 2. `ARSCNView` (11.0; deprecated on visionOS in favor of RealityView)

Subclass of `SCNView`, adopts `ARSessionProviding`.

| Member | Since | Behavior |
|---|---|---|
| `delegate` | 11.0 | `ARSCNViewDelegate` (§2.1). |
| `session` | 11.0 | The view's session (read-write; a new view has one). |
| `scene` | 11.0 | The SceneKit scene shown over the camera image. One scene unit is one meter; the scene's world coordinates are ARKit's world coordinates. |
| `automaticallyUpdatesLighting` | 11.0 | Default YES. The view creates and updates SceneKit lights from light estimates. |
| `rendersCameraGrain` | 13.0 | Default YES. Adds camera-like noise (`cameraGrainTexture`) to rendered content. |
| `rendersMotionBlur` | 13.0 | Default NO. Adds blur matching the camera's; overrides the SceneKit camera's motion-blur intensity. |
| `anchorForNode:` | 11.0 | The anchor mapped to a node (searching up the node's ancestors), or nil. |
| `nodeForAnchor:` | 11.0 | The node mapped to an anchor, or nil. |
| `hitTest:types:` | 11.0, deprecated 14.0 | Legacy hit test from a view point. |
| `unprojectPoint:ontoPlaneWithTransform:` | 12.0 | View point onto a plane (local +Y normal); Swift `unprojectPoint(_:ontoPlane:)` returns an optional. |
| `raycastQueryFromPoint:allowingTarget:alignment:` | 13.0 | Query from a view point; nil without a current frame. |

The view also: sets the scene background to the camera image; drives the
point-of-view camera node from the AR camera (pose and projection); adds,
updates and removes one node per anchor.

Debug options (`ARSCNDebugOptions`, a type alias of `SCNDebugOptions`):
`ARSCNDebugOptionShowWorldOrigin` / `.showWorldOrigin` (draw the world axes)
and `ARSCNDebugOptionShowFeaturePoints` / `.showFeaturePoints` (draw the
frame's raw feature points). Values (64-bit `SCNDebugOptions` bits, chosen
high so they do not collide with SceneKit's own options): show-feature-points
is `0x40000000` (1 << 30); show-world-origin is `0xFFFFFFFF80000000` (bit 31
sign-extended to 64 bits). Ycode must use the same values.

### 2.1 `ARSCNViewDelegate` (inherits `SCNSceneRendererDelegate` and `ARSessionObserver`)

| Method | Behavior |
|---|---|
| `renderer:nodeForAnchor:` | Supply the node for a new anchor. Not implemented: the view makes an empty node. Returning nil: the anchor gets no node. |
| `renderer:didAddNode:forAnchor:` | A node was mapped and added to the scene. |
| `renderer:willUpdateNode:forAnchor:` | Before the node takes the anchor's new data. |
| `renderer:didUpdateNode:forAnchor:` | After it. |
| `renderer:didRemoveNode:forAnchor:` | The node was removed with its anchor. |

These run on SceneKit's rendering queue, not on the session's delegate queue.
Because the view's delegate is also an `ARSessionObserver`, the view forwards
session observer callbacks (failure, interruption, tracking state) to it; the
app does not have to set `session.delegate`.

### 2.2 SceneKit geometry helpers

- `ARSCNPlaneGeometry` (11.3, `SCNGeometry`): `planeGeometryWithDevice:`
  (needs a Metal device; nullable) and `updateFromPlaneGeometry:`.
- `ARSCNFaceGeometry` (11.0, `SCNGeometry`): `faceGeometryWithDevice:`,
  `faceGeometryWithDevice:fillMesh:` (fill closes the eye and mouth openings,
  for occlusion), `updateFromFaceGeometry:`. Returns nil on devices without
  face tracking (and in the simulator).

## 3. `ARSKView` (11.0)

Subclass of `SKView`, adopts `ARSessionProviding`: `delegate`
(`ARSKViewDelegate`), `session`, `anchorForNode:`, `nodeForAnchor:`,
`hitTest:types:` (deprecated 14.0). It draws the camera image behind a
SpriteKit scene and places 2D nodes at the projected screen positions of
anchors (sprites face the viewer and scale with distance).

`ARSKViewDelegate` (inherits `SKViewDelegate` and `ARSessionObserver`):
`view:nodeForAnchor:`, `view:didAddNode:forAnchor:`,
`view:willUpdateNode:forAnchor:`, `view:didUpdateNode:forAnchor:`,
`view:didRemoveNode:forAnchor:` with the same meanings as for SceneKit.

## 4. `ARCoachingOverlayView` (13.0)

A `UIView` that shows built-in animated instructions while the session
initializes or tracking is limited, then hides itself when its goal is met.

| Member | Behavior |
|---|---|
| `delegate` | `ARCoachingOverlayViewDelegate` (IB outlet). |
| `sessionProvider` | IB outlet to an `ARSessionProviding` object; setting it also sets `session`. |
| `session` | The session watched. |
| `goal` | `ARCoachingGoal` / `ARCoachingOverlayView.Goal`: `Tracking` 0 (default), `HorizontalPlane` 1, `VerticalPlane` 2, `AnyPlane` 3, `GeoTracking` 4. |
| `activatesAutomatically` | Default YES: activate after tracking has been not-normal for a while; deactivate once tracking is normal and the goal is met. |
| `isActive` | Whether coaching is shown. |
| `setActive:animated:` | Manual control. Activation while the session needs relocalization shows a relocalization variant with a reset ("start over") button. Deactivation hides the view. |

Delegate (all optional): `coachingOverlayViewWillActivate:` (apps hide their
own UI), `coachingOverlayViewDidDeactivate:`,
`coachingOverlayViewDidRequestSessionReset:` (the reset button was tapped; if
not implemented, the overlay itself reruns the session's current
configuration with reset-tracking and remove-anchors).

The overlay's artwork, animations and strings are Apple's. Ycode draws its own
(original artwork, own wording) with the same states: hidden, coaching for the
goal, relocalizing with a reset button.

## 5. `ARMatteGenerator` (13.0)

Produces per-frame alpha mattes for people occlusion from a frame that has
person segmentation. `initWithDevice:matteResolution:` (designated; Metal
device; `ARMatteResolution` / `ARMatteGenerator.Resolution`: `Full` 0, `Half`
1), `generateMatteFromFrame:commandBuffer:` (returns a Metal texture: the
alpha matte at full or half camera resolution, encoded into the given command
buffer), `generateDilatedDepthFromFrame:commandBuffer:` (returns a 16-bit
float texture of dilated linear depth at the segmentation resolution, for
compositing). Create one generator and reuse it every frame.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Names, availability, enum values, inheritance | 4 | SDK headers |
| Debug option values | 3 | `ARProbe -probe consts` |
| Renderer behaviors, defaults, delegate meanings, coaching behavior and reset fallback | 1 | ARKit documentation (`ARSCNView`, `ARCoachingOverlayView` pages) and header documentation (summarized) |
| One scene unit = one meter | 1 | ARKit world tracking documentation (meters) applied to SceneKit's world |
| Renderer pattern (§1) | 1 | "Displaying an AR experience with Metal" documentation and the header contracts; Ycode wording |
| `ARSCNFaceGeometry` nil, `ARSCNPlaneGeometry` non-nil, matte generator creatable in the simulator | 3 | `ARProbe` |
| SceneKit delegate callbacks on the rendering queue | 1 | SceneKit renderer-delegate documentation; **confirm on hardware** for ARKit's node callbacks |
