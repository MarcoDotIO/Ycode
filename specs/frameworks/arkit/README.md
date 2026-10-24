# ARKit (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-19. Reference: the iOS 27.1 SDK
in Xcode 27.1 (27A9269) and the iOS 27.1 simulator runtime (24A94401), whose
ARKit bundle reports version 781.0.7.

## Scope

This spec covers the **iOS/iPadOS ARKit** API: the Objective-C classes and
their Swift refinements that an iPhone or iPad app links against
(`ARSession`, configurations, frames, anchors, raycasting, world maps,
collaboration, the SceneKit/SpriteKit views and the coaching overlay).

Not covered here:

- **visionOS ARKit** (`ARKitSession`, data providers, the C `ar_session_t`
  API). The whole iOS API surface is marked unavailable on visionOS, and the
  iOS session and delegate types are marked deprecated there in favor of
  those. It is a different API and gets its own spec when the visionOS track
  starts.
- **RealityKit's `ARView`** and `RealityView`. They host an `ARSession` and
  are specified in `specs/frameworks/realitykit/`. This spec states only what
  ARKit expects from any renderer that hosts a session (`views.md` §1).

## Files

| File | Content |
|---|---|
| `session.md` | `ARSession`, run/pause/run options, configurations and their options, capability queries, delegate protocols, callback order and threads, interruption and relocalization |
| `frame-and-camera.md` | `ARFrame`, `ARCamera`, video formats, captured image and depth buffers, light estimates, feature points, frame semantics, segmentation, view-rotation angle |
| `anchors.md` | `ARAnchor` and every subclass, their geometry types, skeletons and blend shapes, anchor archiving |
| `scene-understanding.md` | raycasting, tracked raycasts, legacy hit-testing, plane detection, scene reconstruction, world maps, collaboration, geo tracking, reference images and objects, environment texturing |
| `views.md` | `ARSCNView`, `ARSKView`, `ARCoachingOverlayView`, SceneKit geometry helpers, `ARMatteGenerator`, `ARSessionProviding` |
| `errors-and-states.md` | `ARErrorDomain` codes, tracking states and reasons, world-mapping status, geo-tracking states, exceptions |
| `coordinates.md` | coordinate systems, units, transform conventions, intrinsics and projection math, display transforms, timing |
| `simulator-baseline.md` | what ARKit does in Apple's iOS Simulator today (black-box), which Ycode matches first |
| `simulated-world.md` | **Ycode-original design note**: feeding a simulated world into an ARKit implementation |
| `plan.md` | implementation rounds (one agent each) and the conformance-test plan |

Black-box observations behind `simulator-baseline.md` are in
`research/notes/arkit-simulator-observations-2026-10-19.md`; the probe app is
`research/experiments/arkit/ARProbe/` (our own code).

## Framework layout facts (level 4)

- Install name `/System/Library/Frameworks/ARKit.framework/ARKit`, bundle
  identifier `com.apple.ARKit`. Swift refinements live in a separate overlay
  module, `libswiftARKit` (module `ARKit`, interface built in Swift 5 language
  mode with strict concurrency).
- On devices the framework re-exports three sub-frameworks under
  `/System/Library/SubFrameworks/`: **ARKitFoundation** (depth data),
  **ARKitCore** (session, configurations, frames, anchors, errors, raycasting,
  world maps, matte generator) and **ARKitUI** (`ARSCNView`, `ARSKView`,
  `ARCoachingOverlayView`, the SceneKit geometry helpers). The public headers
  are identical in content for device and simulator; the device copies merely
  forward to the sub-framework when it is present. A Ycode implementation may
  use the same three-layer split; it is a natural dependency order
  (Foundation ← Core ← UI).
- The simulator runtime ships `ARKit.framework` with a Metal library
  (`default.metallib`) and `SubFrameworks/ARKitCore.framework` containing only
  localized `Localizable.strings` tables (57 localizations). Error messages are
  therefore localized; Ycode must write its own message text.
- Availability: the iOS API starts at iOS 11.0; members carry their own
  introduction versions (listed per member in the files above). Several
  members were deprecated in iOS 27.0 (orientation-based camera math, legacy
  `.arobject` reference objects). Everything is unavailable on visionOS.

## Evidence summary

Level 1: public developer documentation pages for ARKit (summarized in our
words). Level 2: device-type `capabilities.plist`, the `NSKeyedArchiver`
output of anchors. Level 3: `ARProbe` on simulators named
`ycode-test-arkit-*`. Level 4: public SDK metadata (header and module
structure, member names, availability annotations, `.tbd` install names).
Level 5 (disassembly/decompilation) was **not** used. The reference tools
folder, `research/dirty/` and Ghidra were not opened.
