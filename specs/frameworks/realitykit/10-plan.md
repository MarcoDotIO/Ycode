# RealityKit 10: implementation rounds and conformance tests

Status: proposal, round 0 (KIT-REALITYKIT, 2026-10-19). Ycode-original
plan. Clean-room agents implement from files 01–09 only; they must not
open the reference tools (the Xcode copy, Ghidra, the IPSW),
`research/dirty/` or Ghidra projects.

## 1. Rounds (one agent each)

Library location (proposal): a Swift package under `ycode/Frameworks/
RealityKit/` building on macOS and on the Linux workstation (Swift 6.4),
module `RealityKit` (plus `RealityFoundation` re-export). Each round ends
with its conformance tests green on Linux.

| Round | Owner scope | Spec input | Exit criterion |
|---|---|---|---|
| R1 ECS core | `Entity`, `ComponentSet`, `Scene`, events and their order, systems and dependencies, queries, `Transform`/`HasTransform` math, `BoundingBox`, `clone`, `TransientComponent`, entity subclasses with their default components | 01, 02 §1, §10 | T-ECS and T-TF suites (§2) pass exactly |
| R2 Resources + headless renderer v1 | `MeshResource` (contents, generators with the bounds and part layout of 03 §3.2, `MeshDescriptor`, `LowLevelMesh`), `TextureResource` basics (CGImage-like input → formats and mips of 03 §4), `SimpleMaterial`, `UnlitMaterial`, `PhysicallyBasedMaterial` (no clearcoat/sheen yet), point/directional/spot lights, perspective/orthographic cameras and the default-camera rule, `RealityRenderer` on Vulkan (lavapipe in CI) | 03 §1–§6, 06 §3 | T-MESH, T-TEX pass; T-IMG pixel probes within tolerance |
| R3 Physics | Jolt integration: shapes, collision component and filters, bodies, mass from density, impulses/forces, fixed 1/60 s step and integrator, average restitution/friction, events (per-participant duplication), ray/convex casts, simulation roots, joints, `PhysicsMotionComponent` semantics | 04 §1–§7 | T-PHYS within tolerances |
| R4 Animation | definitions, resources, playback controllers, timing functions, event semantics (05 §3), skeletal (ozz), blend shapes, deformer stack (skinning first), `AnimationLibraryComponent`, `Entity.animate` later | 05 §1–§4, §6 | T-ANIM |
| R5 Assets | USD/USDZ loading with the mapping of 07 §2 (tinyusdz first), `UsdPreviewSurface` → PBR, MaterialX → `ShaderGraphMaterial` (core nodes + `ND_realitykit_pbr/unlit_surfaceshader`), skeletons and animations from USD, units and up-axis, `ModelEntity(contentsOf:)` flattening, `Entity.write` as USD | 07 | T-USD |
| R6 Rendering v2 | shadows (directional, spot), `EnvironmentResource` and IBL, tone mapping, HDR + 4× MSAA pipeline, transparency and sort groups, `OpacityComponent`, debug visualisation, billboards, instancing, particles, portals, post-process callbacks, `CustomMaterial` via AIR→SPIR-V | 03 §2.4–§2.7, §5, §7; 09 §2.4 | T-IMG full set |
| R7 Audio, characters, forces, navigation | miniaudio + Steam Audio, audio resources/controllers/components and events; character controller; force effects; Recast navigation (27 API) | 04 §8–§10, 05 §8 | T-AUD, T-CHAR, T-NAV |
| R8 Views and input on Linux | `RealityView`-shaped host (SDL3/GLFW), `RealityViewCameraContent` (projection, hit tests), camera controls, gesture targeting, `InputTargetComponent`, `ARView` non-AR shim, synchronization service with our own protocol | 06 | T-VIEW; RKProbe ported to the Linux host renders all non-AR modes |
| R9 iOS 27 additions | USDKit API over OpenUSD, `USDStageComponent`, LOD, render layers, bloom, decals, clipping, lightmaps/probes, animation graphs, behaviour trees, compute graphs | 02 §2–§9, 07 §7 | per-feature tests |

Simulator-track items (not part of this library; owners from the stage-8
team):

| Item | Scope | Exit criterion |
|---|---|---|
| S-RK1 | Metal host features RealityKit uses (`08-simulator-baseline.md` §6): texture views with ranges and swizzle, fences, heaps, argument encoders (tier 0), events, cube/3D/MS textures and resolve, vertex textures; identify and implement record opcodes 24, 25, 131, 132, 212 (dirty-room research first) | RKProbe modes rv-basic, rv-mat, rv-mesh, rv-tex, rv-physics render under Ycode on the Thor |
| S-RK2 | Audio output for guest apps | rv-audio completes |
| S-RK3 (with KIT-ARKIT) | AR: camera feed, world tracking, plane anchors from a simulated environment | arview-ar shows the camera image; plane anchors anchor |

## 2. Conformance tests

### 2.1 Principle: one test source, two implementations

Tests are written once against the public RealityKit API (Swift Testing).
On macOS they run against **Apple's RealityKit** (in the iOS simulator via
a host app, or on macOS where the API exists) and record the expected
values; on Linux they run against OpenReality and compare. Expected values
below come from our probe (`RKProbe`) on iOS 27.1 and are the initial
golden data. Our probe modes double as the simulator-parity suite: run
the same app under Apple's simulator and under Ycode and diff logs and
screenshots.

### 2.2 Suites and expected results

| Suite | Content (our own sample code) | Expected (from round-0 runs) | Tolerance |
|---|---|---|---|
| T-ECS | default component sets of each entity class; event trace of `rv-ecs` (add, set, add second component, disable, enable, remove component, reparent, remove subtree); system init/update order C, A, B; clone copies components but not transient ones | `01-architecture.md` §2.1, §4.2; `results/rv-ecs.log` | exact sequence |
| T-DEF | defaults of light, camera, physics, character, collision-filter, PBR and particle components | `02-components.md`; `03-rendering.md` §2.3; particles: plane shape, birth rate 100, life span 1, size 0.02, speed 0.5 | 1e-4 relative |
| T-TF | transform composition, `look(at:)` (−Z and +Z forward), pitch/yaw quaternions, `convert(direction:)` with scale, `visualBounds` with scale | `01-architecture.md` §5 | 1e-4 |
| T-MESH | bounds, model/part/instance counts, material counts of every generator; descriptor normals generation; polygon triangulation; low-level mesh | `03-rendering.md` §3.2 | bounds 1e-4; part and material counts exact; vertex/triangle counts informative |
| T-TEX | pixel format, type, mip count for colour/raw semantics; environment creation | `03-rendering.md` §4 | exact |
| T-PHYS | free fall samples at 0.0167, 0.25, 0.5 s (simulated time) = 0.9973, 0.6736, rest 0.05; landing at 0.433 s; ball max after bounce 0.222; impulse 1 N·s on 2 kg → 0.498 m/s after 0.2 s; mass/inertia from density; ray-cast `.all` order and distances 1.9 / 2.0; collision `Began` count per scene-wide and per-entity subscription; steps 192 in 3.2 s | `04-physics.md`; `results/rv-physics.log` | positions ±0.002 m; times ±1 step; bounce height ±0.01 m |
| T-ANIM | linear move at scene time; one-frame lag in update handlers; auto-reverse loop events each second; sampled duration = frames × interval; completed then terminated | `05-animation-audio.md` §3 | values ±0.01; event times ±1 frame |
| T-USD | load our five USD files and the USDZ: hierarchy, entity classes, components, transforms, unit/axis wrapper, material tints, animation names and durations, skinned mapping, flattening | `07-assets.md` §2; `results/rv-usd.log` | exact structure; numbers 1e-4 |
| T-IMG | `RealityRenderer` into a 256×256 texture: background pixel (sRGB 0.1, 0.1, 0.3 → 25, 25, 74), sphere and floor probes; later full images of `rv-basic`, `rv-mat`, `rv-mesh`, `rv-tex` scenes | `06-views-anchoring-input.md` §3; screenshots kept by the round agent | background ±2/255; lit probes ±12/255; whole images SSIM ≥ 0.90 |
| T-VIEW | projection of fixed points with our camera and the default camera (466×678 and 300×200 views); hit-test order | `06-views-anchoring-input.md` §1, §2; `08-simulator-baseline.md` §3.1 | ±0.5 pt |
| T-AUD | buffer resource duration; playback completes; controller state | `05-animation-audio.md` §8.2 | state exact |
| T-SIM | RKProbe under Ycode vs Apple's simulator: every mode's log keys equal (timing keys excluded), screenshots SSIM ≥ 0.9 | `08-simulator-baseline.md` | as listed |

### 2.3 Test assets

Only our own assets: the hand-written USD files in
`research/experiments/realitykit/RKProbe/assets/`, generated textures and
meshes. No Apple models, textures, skyboxes or materials.

## 3. Open questions (for the next dirty-room round)

1. Default virtual camera: we measured position (0, 0, 2) and a vertical
   FOV of 65°; confirm on other view sizes and in landscape, and whether
   `RealityView` content bounds change it.
2. Friction combine rule (restitution averages; friction presumably too).
3. Joint frame conventions (hinge/slide axis = pin X?) — probe joints.
4. What triggers a `SceneEvents.Update` when nothing changes (idle frame
   rate) and whether updates stop when the view is hidden.
5. The five Metal record opcodes not yet described (24, 25, 131, 132,
   212) — simulator dirty room.
6. `MeshResource(extruding:)` with `AttributedString` returned an empty
   mesh for a 0.1-pt font; retry with realistic sizes.
7. `deltaTime` and physics catch-up after long stalls: how many fixed
   steps run after a 0.5 s frame.
8. Behaviour of `Entity.write` options and whether any API writes real USD
   on iOS (USDKit export in 27).
9. Cloth simulation APIs documented for 27 but absent from the installed
   SDKs: re-check with later SDKs.
