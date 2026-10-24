# RealityKit observations (KIT-REALITYKIT, 2026-10-19)

Dirty-room working notes for `specs/frameworks/realitykit/`. Prose only;
no Apple code. All observations are of our own app (`RKProbe`) on Apple's
simulator, of our own USD files, and of SDK interface metadata.

## Sources used

- SDK `.swiftinterface` files of RealityFoundation, RealityKit,
  `_RealityKit_SwiftUI`, `_RealityKit_ComputeGraph`, USDKit and
  `_USDKit_RealityKit` (iPhoneSimulator 27.1), read by
  `research/experiments/realitykit/inventory/` scripts that keep names,
  argument labels, kinds, conformances and availability only. Interfaces
  contain inlinable bodies; the scripts drop every line that is not a
  declaration name, so no body text reaches the inventory.
- Header file names and accessor names of the Metal shader API in
  `RealityKit.framework/Headers` (grep for names only).
- developer.apple.com pages (RealityKit topic pages, "Implementing systems
  for entities in a scene", performance articles, USD articles, ShaderGraph
  node pages, cloth-simulation collection) and the WWDC26 session pages
  279 and 287 (titles and chapter lists).
- `realitytool --help` and one compile of our own `.rkassets`.
- Our Metal recorder (`research/experiments/simulator/metal-sim/mslog.c`)
  inserted into our own probe only.

## Run log

| Round | Modes | Notes |
|---|---|---|
| 1 | rv-basic, rv-nocamera, rv-ecs | `simctl launch --stdout=` did not create files in the scratch path; switched to `--console` capture. First launch after a fresh install sometimes printed nothing within 10 s (slow start under load). |
| 2 (`runs3`) | all 18 modes | Physics and animation sampled on simulated/scene time because the host load average was 250–990 (other agents' simulators). `renderer` never completed because our `RealityRenderer` was released after submission (probe bug). |
| 3 (`runs4`, "round2" logs) | rv-ecs, rv-physics, arview-nonar, arview-ar, renderer, rv-square, rv-basic; rv-basic and rv-mat with the Metal recorder | Added: transient-component clone check, per-entity collision subscription, `PhysicsMotionComponent` on the kicked body, render-option raw values, hit test after `generateCollisionShapes`, a 300×200 `RealityView`, renderer kept alive. |

## Findings worth a second look

- Scene-wide collision subscriptions get each `Began` twice (once per
  participant). Easy to misread as a bug in our probe; the filtered
  subscription confirms it.
- Values read in `SceneEvents.Update` lag animation by one frame.
- The ball bounce height implies averaged restitution (0.8 and 0 → ≈0.43
  effective, close to 0.4). A probe with two equal non-zero restitutions
  and with friction slides would pin the combine rules down.
- `Entity.write(to:)` writes the `.reality` container whatever the file
  extension — USD tools reject the output.
- `realitytool` treats a path argument that starts with `-` (our scratch
  directory has such a component) as an option unless it follows `--`.
- RealityKit in the simulator uses an HDR RGBA16Float 4× MSAA target with
  Depth32Float_Stencil8 and a 3D RGBA16Float texture (likely a tone-mapping
  lookup table; not verified), and record opcodes 24, 25, 131, 132, 212
  that `metal-sim-protocol.md` does not describe yet.
- The default virtual camera has a constant vertical FOV of about 65° at
  (0, 0, 2).

## Not done in this round

Joint probes, friction, idle frame behaviour, landscape orientation,
video material, multipeer synchronization, gestures (no input injected),
`CustomMaterial` uniforms, `LowLevelTexture`, post-process callbacks.
