# RealityKit 8: what Apple's iOS simulator does with RealityKit (baseline for Ycode)

Status: reference, round 0 (agent KIT-REALITYKIT, 2026-10-19). This is the
behaviour the Ycode simulator must reproduce first: a guest app that uses
RealityKit must get the same results under Ycode as under Apple's
simulator. Every fact here is level 3 (our own app, run on Apple's
simulator), except the Metal tallies (§6), which use the project's own
Metal recorder on our own app (level 3).

## 1. Method

- Probe: `research/experiments/realitykit/RKProbe/` (our SwiftUI app,
  built with `swiftc` and `metal` from Xcode 27.1 without a project;
  `build.sh`, `run.sh`). One mode per launch (`-mode <name>`); the app
  prints `RKP key=value` lines. Logs: `research/experiments/realitykit/
  results/`. Screenshots (`simctl io screenshot`) stayed in the agent's
  scratch directory.
- Device: throwaway `ycode-test-realitykit-1`, device type iPhone Duo,
  iOS 27.1 runtime (24A94401), 466 × 678 points, scale 3; deleted after
  the runs.
- Host: this Mac (Apple M3 Max) while other agents ran up to nine other
  simulators; the load average was between 250 and 990 during the runs.
  Time-sensitive measurements are therefore taken on **simulated or scene
  time** (sums of `deltaTime`), and frame rates are lower bounds.

## 2. Summary table

| Feature | Result in Apple's simulator | Mode |
|---|---|---|
| `RealityView` (iOS 18) with the virtual camera, our `PerspectiveCamera`, lit PBR objects, directional light with shadows | **Renders correctly** (shadows, metallic reflections of the default environment, unlit material) | rv-basic |
| `RealityView` without a camera entity | renders from the default camera at (0,0,2), vertical FOV ≈ 65° | rv-nocamera, rv-square |
| `RealityView` camera controls `.orbit` | view renders (interaction not exercised) | rv-orbit |
| `ARView` `.nonAR` | **renders correctly**; background colour honoured; snapshot works (device pixels); hit test works with collision shapes | arview-nonar |
| `ARView` default (`.ar`, auto-configured session) | **falls back**: `cameraMode` reads `.nonAR`, `session.configuration` is nil, no error delivered; background stays `cameraFeed` and renders **black**; scene renders from the default camera (0,0,2); `ARWorldTrackingConfiguration`, face, body and orientation tracking all report `isSupported == false` | arview-ar |
| `RealityView` with `.spatialTracking` + `SpatialTrackingSession` | every anchor capability (camera, world, plane, image) and scene-understanding capability (occlusion, collision) **unavailable**; plane-anchored content never appears; blank view | rv-spatial |
| `AnchorEntity(world:)` | anchored immediately everywhere | all |
| `AnchorEntity(plane:)` | never anchored (all views) | all |
| `RealityRenderer` offscreen into an app `MTLTexture` | **works**; completion in ~0.08 s; pixels read back as expected | renderer |
| Materials: Simple, Unlit, PBR (clearcoat, emissive, transparent), Occlusion, wireframe (`triangleFillMode .lines`) | all render | rv-mat |
| `CustomMaterial` surface shader and geometry modifier from the app's own metallib | **compile and render** (`supportsMutableUniformsResources == false`) | rv-mat |
| `ShaderGraphMaterial` from our MaterialX USD | loads; parameters exposed | rv-mat |
| `PortalMaterial` alone | draws nothing (expected without a portal) | rv-mat |
| Mesh generators, `MeshDescriptor`, `LowLevelMesh` | work (tessellation table in `03-rendering.md` §3.2) | rv-mesh |
| `MeshResource(extruding: AttributedString)` with a 0.1-point font | produced an empty mesh (our input is the likely cause; open) | rv-mesh |
| `TextureResource` from `CGImage`, mipmaps, `DrawableQueue`, `EnvironmentResource` from equirectangular image, IBL | work | rv-tex |
| USD/USDZ loading, unit/axis conversion, skinning, animations; `.reality` loading; `Entity.write` | work (`07-assets.md`) | rv-usd |
| Physics (fixed 60 Hz step, gravity, restitution, impulses, collision events, ray casts) | work, deterministic | rv-physics |
| Animation (move, from-to-by, sampled, events) | work | rv-anim |
| ECS (custom components and systems, events, queries) | work | rv-ecs |
| Audio (`AudioBufferResource`, spatial component, completion event) | works | rv-audio |
| Particle emitters (presets) | render | rv-particles |
| Frame rate, simple scene | 55–60 updates per second | all |
| Frame rate, 1000 / 5000 boxes | 59 / 29 updates per second (loaded host) | rv-perf1000, rv-perf5000 |

Conclusion: Apple's iOS simulator supports **all non-AR RealityKit**
features we tried, including custom Metal materials, and supports **no AR
tracking**: AR views degrade silently to non-AR with a black camera
background. Ycode's first target is exactly this. AR support (camera
feed, tracking, plane detection) is a later, Ycode-specific extension
(`docs/FUTURE.md`; see KIT-ARKIT's `specs/frameworks/arkit/`).

## 3. Detailed observations

### 3.1 Views and cameras

- `RealityView.make` ran at first display; first `SceneEvents.Update`
  0.05–0.16 s later. Content root is anchored and in the scene at once.
- Our camera at (0, 0.7, 1.3) looking at (0, 0.1, 0), FOV 60°: centre ray
  origin (0, 0.7, 1.3), direction (0, −0.4191, −0.9080); world origin
  projected to (233.0, 375.18) pt in a 466 × 678 view; (0.1, 0, 0) to
  (272.84, 375.18); (0, 0.1, 0) to (233.0, 339.0).
- No camera: centre ray origin (0, 0, 2), direction (0, 0, −1); origin →
  (233, 339); (0.1, 0, 0) → (259.61, 339); same focal length for a
  300 × 200 view scaled by height (157.0 pt).
- `ARView` non-AR with our camera: `cameraTransform` (0, 0.7, 1.3) and the
  same projection as `RealityView`. `contentScaleFactor` 3.0. Default
  `renderOptions` 56 (motion blur, depth of field, HDR disabled) in both
  camera modes; `debugOptions` 0.
- `RealityView` background: the SwiftUI background shows through (white).

### 3.2 Frame pacing

- Updates per second 55–60 for simple scenes even under host load;
  `deltaTime` mean 0.0169–0.018 s, irregular first frames (0.03, 0.1 s),
  single stalls up to 0.84 s (custom-material shader compilation in
  rv-mat delayed the first update to 3.5 s and averaged 31 updates/s over
  that run).

### 3.3 ECS, physics, animation, audio, assets

See `01-architecture.md` §2–§4 (event order, system order),
`04-physics.md` §3–§7 (numbers), `05-animation-audio.md` §3 and §8,
`07-assets.md` §2, §6, §8. The full logs are in
`research/experiments/realitykit/results/`.

## 4. Metal profile seen by RealityKit

The simulator's Metal device (every mode): name "Apple iOS simulator
GPU"; GPU families `apple1`, `apple2`, `common1` only; argument buffers
tier 0; read-write textures tier 0; no ray tracing; 512 threads per
threadgroup; 256 MiB maximum buffer length; 4× MSAA supported.

## 5. What the simulator does *not* show

- Camera images, AR anchoring, scene reconstruction, people occlusion,
  light estimation, face and body tracking — unavailable.
- Visual effects disabled by default in the simulator (motion blur, depth
  of field, HDR) are not exercised by default.
- Attachments and other visionOS-only APIs are not in the iOS SDK.

## 6. Metal traffic of RealityKit scenes **[metal-rec]**

Our recorder (`research/experiments/simulator/metal-sim/mslog.c`) was
inserted into the probe for the modes rv-basic and rv-mat (about 10 s
each). Message names refer to `specs/simulator/metal-sim-protocol.md`.

| Item | rv-basic | rv-mat |
|---|---|---|
| Command-buffer submissions (`messageType` 6) | 1956 | 1952 |
| Buffers (1) | 476 | 489 |
| Functions (15) | 141 | 201 |
| Render pipelines (12, op 14) | 75 | 105 |
| Compute pipelines (12, op 11) | 20 | 20 |
| Texture views (12, op 8) | 488 | 487 |
| Fences (12, op 13) | 1531 | 1528 |
| Argument-buffer layouts/encoders/sets (12, ops 16, 17, 19) | 1, 1, 15 | 1, 1, 30 |
| Heaps and heap resources (12, ops 20, 21, 22, 25, 31, 32) | yes | yes |
| Events (12, op 28) | 2 | 2 |
| IOSurface textures (13) | 3 | 3 |

Textures created (type, pixel format, sample count): cube RGBA16Float
(12; environment lighting), 1D R32Float (6), 2D RGBA16Float (4), 2D
BGRA8Unorm (3), 2D R32Float (3), 2D R16Float (2), 2D RGBA8Unorm (2), cube
R16Float (2), 2D-array RGBA16Float (1), **3D RGBA16Float** (1), 2D
Depth32Float (1), **2D multisample ×4 RGBA16Float** (1) and **2D
multisample ×4 Depth32Float_Stencil8** (1). So the view renders in HDR
(RGBA16Float) with 4× MSAA and a combined depth-stencil target, then
resolves/tone-maps into the BGRA8 drawable.

Command records used (counts in rv-basic): draws (ops 5, 7), render pass
begin (26), depth-stencil state (104), cull mode (107), depth bias (108),
fragment/vertex buffers and offsets (110, 111, 125, 126), samplers (112),
fragment textures (114), **vertex textures (129, mostly in rv-mat)**,
winding (115), pipeline (116), stencil reference (119), fill mode (124),
`useResource(s)` (137), compute dispatch and bindings (200, 203, 204, 206,
208), blit copy buffer→texture (300), fill buffer (306), generate mipmaps
(307), fence update/wait (316, 317), event wait/signal (400, 401). Opcodes
**24, 25, 131, 132 (render) and 212 (compute) are not yet described** in
`metal-sim-protocol.md`; they occur in every frame.

Compared with what a boot to the home screen needs (`metal-sim-protocol.md`
§10), a RealityKit app additionally requires from Ycode's Metal host:
texture views with type/level/slice ranges and swizzle, fences (per
frame), heaps, argument encoders (tier 0 emulation), events, 3D and cube
textures, multisample render targets with resolve, vertex-stage texture
sampling, and the five undescribed record opcodes.

## Evidence

| Claim | Level | Source |
|---|---|---|
| All behaviour in §2–§5 | 3 | RKProbe runs, logs in `results/` |
| Metal tallies §6 | 3 | our recorder inserted into our probe; tally script `research/experiments/realitykit/mstally.py` over `msparse.py` output |
| Opcode meanings | — | `specs/simulator/metal-sim-protocol.md` (earlier project work) |
