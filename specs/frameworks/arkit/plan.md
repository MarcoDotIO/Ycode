# ARKit spec: implementation rounds and conformance tests

Part of `specs/frameworks/arkit/`. This plan is Ycode's own. Each round is
sized for one clean-room agent. Clean-room agents read only `specs/`, public
documentation and permissively licensed open source; they must not open the
reference tools (the Xcode copy, Ghidra, the IPSW), `research/dirty/`, or
Ghidra projects.

## 1. Two delivery targets

1. **Guest drop-in ARKit** for Ycode's iOS simulator. Ycode's guest runs
   Apple's simulator runtime, whose own ARKit already shows the baseline
   behavior. To add the simulated world, Ycode supplies its own
   `ARKit.framework` that apps load instead of Apple's. It must be
   **binary-compatible** with apps built against the SDK: same install name,
   Objective-C class names and selectors, exported C symbols (the constants
   and the one C function in the headers), enum values, and the Swift overlay
   (`libswiftARKit`, module `ARKit`) with matching mangled names for every
   public declaration of the `.swiftinterface` (library evolution, so layouts
   are resilient). Only the **public** symbol subset is needed — the SDK
   `.tbd` lists many internal exports that apps never reference.
2. **Open ARKit for Linux** (the "open frameworks" goal of `docs/FUTURE.md`):
   a source-compatible Swift package with the same API names and semantics,
   fed from recorded or simulated sensor data, for tools and tests on Linux.
   Shares the engine with target 1.

## 2. Rounds

| Round | Owner (one agent) | Scope | Done when |
|---|---|---|---|
| R0 | KIT-ARKIT (this) | Specification | this directory reviewed and merged |
| R1 | simulator track | **Baseline in Ycode** with Apple's own ARKit: run the conformance app C-BASE in a Ycode guest and diff against the golden output from the reference simulator; fix host gaps (Metal device for the matte generator, SceneKit/SpriteKit rendering, asset-catalog lookup). | C-BASE output identical (modulo UUIDs, addresses, times) |
| R2 | clean room | **ABI inventory and skeleton**: from public headers and the `.swiftinterface`, generate the list of public classes, selectors, properties, constants and Swift declarations; build a drop-in framework that implements `simulator-baseline.md` exactly (baseline mode) plus the documented data behavior of `ARAnchor`, `AREnvironmentProbeAnchor`, skeleton definitions. Decide with the simulator track how the guest loads it (runtime-root overlay or loader redirect). | C-BASE identical with Ycode's framework; C-SWIFT compiles and links against it |
| R3 | clean room | **Data model and math**: every anchor subclass with real storage; secure coding (anchor keys per `anchors.md` §1.2); `ARPointCloud`, plane/face/mesh geometry types; `ARReferenceImage` (CGImage, pixel buffer, asset-catalog AR groups via the asset-catalog reader); `ARWorldMap` and `ARCollaborationData` containers (Ycode payloads); 3D skeleton definition and face topology authored by Ycode; all `ARCamera`/`ARFrame` math of `coordinates.md`. | C-MATH (formulas), C-ARCHIVE pass |
| R4 | clean room + simulator track | **Session engine and oracle core**: state machine, run options, delegate queue dispatch and ordering, bounded frame pool, interruptions; sensor-channel client; host sensor renderer for the back camera and IMU; world/orientation/positional tracking from ground truth; scripted tracking states; light estimate; feature points; capability answers in simulated-world mode (`isSupported` YES, video formats of the simulated device model). | C-SESSION passes in simulated-world mode; baseline mode still passes C-BASE |
| R5 | clean room | **Scene understanding (oracle)**: progressive planes with merging and classification; raycasts, tracked raycasts, legacy hit tests; scene depth and confidence; mesh anchors; environment probes; image detection/tracking; object detection/tracking; world maps with relocalization; collaboration between two simulated devices. | C-PLANE, C-IMAGE, C-DEPTH, C-MAP, C-COLLAB pass |
| R6 | clean room | **People and faces (oracle)**: front camera and face rig; face anchors, blend shapes, eye transforms, `ARFaceGeometry`, directional light estimate, front depth; body tracking with retargeting to the joint set; 2D body detection; person segmentation and estimated depth; `ARMatteGenerator`. | C-FACE, C-BODY pass |
| R7 | clean room | **Views**: `ARSCNView`, `ARSKView` (on the guest's SceneKit/SpriteKit), `ARCoachingOverlayView` with Ycode-original artwork, SceneKit geometry helpers, view-rotation angle and `viewLayer`. | C-VIEWS screenshots match goldens produced by Ycode's own reference renderer; behavior checks pass |
| R8 | clean room | **Geo and App Clip Codes (oracle)**: availability checks, geo states, geo anchors, point↔coordinate conversion, App Clip Code anchors from the world side-car. | C-GEO passes |
| R9 | clean room (optional) | **Vision backend**: VIO from permissive libraries (Basalt or Kimera-VIO), plane fitting, TSDF meshing (Open3D-style, own code or MIT library); evaluation against ground truth. | trajectory error and plane accuracy within agreed bounds on the test worlds |
| R10 | clean room (optional) | **Linux package**: source-compatible Swift API on Linux (simd substitute, no UIKit/SceneKit views), driven by recorded trajectories. | conformance tests that do not need views pass on Linux |

R4 depends on the simulator track's sensor channel and Metal→Vulkan layer;
R7 depends on SceneKit rendering working in the guest.

## 3. Conformance-test plan

All test apps are written by us (Objective-C and Swift), in the style of
`research/experiments/arkit/ARProbe`: they print one line per observation and
are compared with golden files. "Reference" means Apple's simulator (for
baseline tests) or a hardware run of the same app (for device-only facts,
see §4); "oracle" means expected values computed from the simulated world.

| Test | App does | Expected |
|---|---|---|
| C-BASE | Everything `ARProbe -probe all`, `-probe consts`, `-ui scn|sk|coachscn` does | Identical to the golden output of the reference simulator (`simulator-baseline.md`), after normalizing UUIDs, addresses and times |
| C-SWIFT | Uses the Swift refinements: `TrackingState` enum with reasons, plane `Classification` with status, arrays of points/vertices/joints, optional `viewRotationAngle`, optional unprojection, `ARSkeletonJointName.init(_:)` | Compiles against the SDK, links against Ycode's framework, same output as against Apple's |
| C-SESSION | Runs/pauses/re-runs with each option; custom and main delegate queues; retains frames to starve the pool; backgrounds and foregrounds the app; changes configuration while running | Callback threads; per-frame invariants (`session.md` §6.4); tracking-state sequence; frames stop while starved and resume after release; interruption begin/end and the relocalization question; `configuration` reflects the last run |
| C-MATH | For fixed intrinsics/poses: projection, view matrices, display transforms for all four angles and several viewport sizes, project/unproject round trips | Matches `coordinates.md`; also run on hardware once to confirm the derived formulas |
| C-ARCHIVE | Archives anchors (plain, named, subclasses) with Apple's and Ycode's frameworks and decodes each with the other | Round trip preserves identifier, name, transform |
| C-PLANE | Tabletop world, plane detection on, raycast from the screen center | A horizontal plane anchor within the scripted discovery time at the table height (±1 cm); extent grows as the camera pans; raycast hit on the table; vertical plane on the wall when enabled |
| C-IMAGE | Poster world; image tracking and world-tracking detection | Image anchor at the poster pose (±1 cm, ±1°); `isTracked` false when out of view; `estimatedScaleFactor` 1 unless scale estimation is on |
| C-DEPTH | Room world, scene depth and reconstruction | Depth equals ground-truth distance (±1 %); confidence high on near frontal surfaces; mesh anchors cover the walls and floor with correct classification |
| C-MAP | Saves a world map, kills the app, relaunches with `initialWorldMap` | Relocalizing then normal; saved anchors reappear at saved poses |
| C-COLLAB | Two simulated devices in one world exchange collaboration data over a loopback socket | Participant anchors appear on both; anchors added on one appear on the other with the right `sessionIdentifier` |
| C-FACE | Face world with a scripted blend-shape track | Coefficients equal the script (mirrored as specified); geometry vertex count constant; eye transforms follow the script |
| C-BODY | Person walking along a path | Body anchor root follows the path; joint transforms equal the retargeted script |
| C-GEO | Plaza world with a geodetic origin | Availability YES; state reaches localized; geo anchor lands at the expected world position; point↔coordinate round trip within 0.1 m |
| C-VIEWS | `ARSCNView` with a box at a known anchor, debug options on; coaching overlay with goal horizontal plane | Camera background visible; box drawn at the projected position; world-origin axes drawn; coaching shown while initializing and hidden once a plane exists |

## 4. Open questions

Device-only facts (need a run of our own probe on real hardware, which is
level 3 evidence and allowed):

1. Per-frame order of anchor callbacks versus `didUpdateFrame` and
   `cameraDidChangeTrackingState`.
2. Depth convention of `projectionMatrix` (0…1, reversed, or −1…1) and the
   half-pixel convention of the principal point; confirmation of all
   **derived** formulas in `coordinates.md`.
3. Clock base of `ARFrame.timestamp`.
4. Exact pixel format of `capturedImage`; size of `sceneDepth` maps per model.
5. Device defaults of configuration properties (expected to match the
   documentation; the simulator's are all zero).
6. The 3D skeleton definition (joint names and parents) and the neutral
   pose; face mesh vertex/triangle counts.
7. Exception names and timing for unsupported frame semantics and other
   misuse.
8. Whether `identifier` changes on every run.
9. Archive keys of anchor subclasses (plane, image, face, body, mesh).
10. Video-format lists per device model (for the simulated device's
    capability answers).

Design questions:

11. How Ycode's guest loads Ycode's `ARKit.framework` instead of Apple's
    (runtime-root overlay versus loader redirect), and how the Swift overlay
    `libswiftARKit` is replaced consistently (simulator track decision).
12. The `.referenceobject` file format (produced by Create ML) — study as a
    file format from files we create ourselves, when needed.
13. Ownership of RealityKit's `ARView`/`RealityView` session integration
    (coordinate with KIT-REALITYKIT; this spec states only the renderer
    contract in `views.md` §1).
14. A separate spec for visionOS ARKit (`ARKitSession`, providers) when the
    visionOS track starts; the simulated world should feed both.
15. The reference simulator's AVFoundation has a simulator capture source
    (its log names one when the app queries capture devices); whether Ycode's
    camera service should plug in there for AVFoundation apps is a simulator
    track question.

## Evidence

Ycode plan; facts it relies on are cited in the other files.
