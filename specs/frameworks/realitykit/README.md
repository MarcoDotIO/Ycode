# Spec set: RealityKit (open reimplementation track)

Status: **draft, round 0** (agent KIT-REALITYKIT, 2026-10-19). This set
starts the specification of Apple's RealityKit framework for the
open-frameworks goal of `docs/FUTURE.md`: a RealityKit-compatible library
that builds on Linux, and the RealityKit behaviour the Ycode iOS simulator
must reproduce for AR apps. Clean-room implementers read only this
directory, public documentation and the open-source projects named in
`09-open-design.md`.

Reference: Xcode 27.1 (27A9269), iPhoneSimulator 27.1 SDK, iOS 27.1
simulator runtime (24A94401), device type "iPhone Duo" (the only type that
runtime accepts on this Mac).

## Files

| File | Content |
|---|---|
| `01-architecture.md` | Modules, the entity–component–system model, scenes, events, update ordering, transforms and coordinate conventions |
| `02-components.md` | Catalogue of the built-in components, grouped by area, with observed defaults |
| `03-rendering.md` | Materials, meshes, textures, lights, image-based lighting, shadows, cameras, post-processing, frame pacing, Metal requirements, limits |
| `04-physics.md` | Collision shapes and filters, rigid bodies, forces, joints, simulation roots, events, casts, character controller, navigation meshes |
| `05-animation-audio.md` | Animation definitions and playback, skeletons, blend shapes, IK, entity actions, animation graphs, audio |
| `06-views-anchoring-input.md` | `RealityView` (iOS), `ARView`, `RealityRenderer`, anchoring, spatial tracking, gestures and input targets, attachments, synchronization |
| `07-assets.md` | USD/USDZ as interop (schemas RealityKit reads), USDKit, export, `.reality` and Reality Composer Pro as black boxes |
| `08-simulator-baseline.md` | What Apple's iOS simulator does with RealityKit today (black-box runs of our probe app) — the first target for Ycode |
| `09-open-design.md` | **Ycode-original design note**: building blocks for an open implementation, with verified licences |
| `10-plan.md` | Implementation rounds (one agent each) and the conformance-test plan |
| `api-inventory.md` | Name-only inventory of the public API surface (types, member names, availability), generated from SDK module metadata |

## Conventions

- Interop identifiers (type, member, enum case, component, file-format and
  schema names) are facts and appear verbatim. Everything else is our own
  description. No declaration, header text or documentation sentence is
  copied; member lists give names and argument labels only.
- "iOS n" means the first iOS release that has the symbol according to the
  SDK's availability metadata (level 4). Members that are not available on
  iOS but exist for visionOS are marked "visionOS only"; this spec covers
  them only where they shape the design.
- Observations from our probe app (level 3) name the probe mode in
  brackets, e.g. **[rv-ecs]**. The probe is
  `research/experiments/realitykit/RKProbe/` (our own code); its logs are in
  `research/experiments/realitykit/results/`.
- Each file ends with an **Evidence** table (AGENTS.md rule 4). Levels used
  in this set: 1 (public documentation, WWDC session pages, permissively
  licensed open source), 2 (files RealityKit reads and writes, studied as
  formats: our own USD files, our own compiled `.reality` file at container
  level), 3 (black-box runs of our own apps and of `realitytool`), 4 (public
  SDK module metadata: `.swiftinterface` symbol names and availability,
  header file names and accessor names). Level 5 was not used anywhere: no
  Apple binary was disassembled or decompiled, and the reference tools
  folder, `research/dirty/` and Ghidra were not opened.

## Scope decisions

1. **iOS first.** The simulator target is iOS, so the iOS surface
   (`RealityView` with a camera content, `ARView`, `RealityRenderer`) is
   specified in full; visionOS-only API (attachments, `Model3D`,
   manipulation, hand anchors, immersive spaces) is listed for later rounds.
2. **Behaviour over appearance.** Pixel-exact parity with Apple's renderer
   is not a goal. The conformance plan (`10-plan.md`) checks geometry,
   ECS semantics, physics trajectories and event order exactly, and images
   with tolerances.
3. **Asset formats.** USD is the interchange format (open spec, Apache-style
   licensed implementation). `.reality` files and Reality Composer Pro
   packages are opaque: the open implementation does not read them in its
   first rounds (`07-assets.md` §5).
