# Scene composer: boundary specs (reference: Reality Composer Pro)

Status: round 0 (OBS-RCP, 2026-10-29), with the migration (OBS-RCP2)
and the owner's app-made sample (OBS-RCP4) folded in. Goal from the owner: a
clean-room tool so that developers can make RealityKit scenes outside
macOS. These files are the boundary: what Ycode's scene editor must read
and write, and what the build must produce, to interoperate with Reality
Composer Pro ("RCP", the reference; Ycode's tool has its own name) and
with Xcode builds.

Reference versions: Reality Composer Pro 3.0 (1A153), Xcode 27.1
(27A9269) with `realitytool`, RealityKit of macOS 27.

| File | Topic |
|---|---|
| `project-format.md` | the three project shapes, the legacy content package, the RCP 3 directory project, content vs user state |
| `scene-usd.md` | USDA conventions, composition, the component encoding and catalogue |
| `materials.md` | Shader Graph materials in USD, node identifiers, promoted parameters |
| `timelines-behaviors.md` | timelines, actions, behaviors, triggers, animation libraries |
| `particles-audio.md` | particle emitters, audio files, audio components |
| `compile.md` | `realitytool compile` / `create-schema` / `image`, Xcode's build tasks, the `.reality` container |
| `editor-behavior.md` | windows, menus, shortcuts, viewport, import/export, Xcode link, plug-ins, CLI |
| `ycode-design.md` | Ycode-original decisions of the composer (names, what Ycode writes, preservation, validation codes); architecture in `docs/SCENE-COMPOSER.md` |

## The one decision that shapes everything

The reference changed generation. RCP 3 is a new standalone editor on a
game-engine core; its projects are an engine-native asset tree, not USD,
and it hands content to Xcode as exported `.reality` files. Xcode 27.1's
own template puts plain `.usda` scenes in the app. The RCP 1/2 format —
a Swift package with a `.rkassets` folder of USDA scenes — is still
compiled by every Xcode build and is migrated by RCP 3 on open.

**Ycode writes the RCP 1/2 content-package format** (USD source,
`project-format.md` §3). That gives: builds with stock Xcode on macOS;
openable (by migration) in RCP 3; readable by any USD tool; loadable
directly by the open RealityKit on Linux. RCP 3's native projects are a
later read-only import (`project-format.md` §4.6); until then Ycode
imports RCP 3's USD or `.reality` exports.

## Answers in brief

**Project format.** Shape A: `.usda` in the app target (plain
resources). Shape B: `<Pkg>/Package.swift` (tools ≥ 5.7, `.rkassets`
auto-processed), `Sources/<Pkg>/<Pkg>.rkassets/*.usda`,
`Sources/<Pkg>/<Pkg>.swift` exporting `Bundle.module`,
`Package.realitycomposerpro/ProjectData/main.json` (the legacy marker;
key names unverified) and `WorkspaceData/` (user state). Shape C:
`<Name>.realitycomposerpro/` with `project.rcp`, `__type_index.tm_meta`,
one tab-indented, comma-less text file per asset (`*.tm_entity`,
`*.tm_material`, …), `*.tm_buffers/<uuid>.<hash>` blobs, UUID identity
and prototype/override inheritance. A hand-made shape-B package is
recognised by RCP 3 (it opens a migration window). An app-made project
(§4.7 there) settles the per-asset grammar: fields equal to the type
index's defaults are omitted, references name object `__uuid`s,
library entities are prototype instances with `…__instantiated`
overrides, buffer names carry the MurmurHash64A of their bytes, and
`type_hash` is the hash of a type name.

**Scenes as USD.** `#usda 1.0`, `defaultPrim = "Root"`,
`metersPerUnit = 1`, `upAxis = "Y"`, T·R·S xform ops, `MaterialBindingAPI`
bindings with `weakerThanDescendants`, imports as typeless referencing
prims. Components are `RealityKitComponent` child prims, `info:id =
"RealityKit.<Kind>"`, attributes named after the engine's field names,
nested `RealityKitStruct`s, relationships for entity references; unknown
names are silently ignored, so the catalogue lists only names we verified
by loading our own files (collider, rigid body, motion, anchoring,
accessibility, input target, grounding shadow, opacity, billboard,
character controller, lights, IBL receiver, world, portal; plus emitter
and audio in `particles-audio.md`). Custom components are
`RealityKitCustomComponent` prims named `<Module>_<Type>`. Instanced
references load as separate entities; payloads load eagerly; the
selected variant loads.

**Materials.** `Material` prim → `outputs:mtlx:surface` (surface node)
and `outputs:realitykit:vertex` (geometry modifier); nodes are `Shader`
prims whose `info:id` is a MaterialX nodedef name (`ND_*`, RealityKit
`ND_realitykit_*`, `ND_RealityKitTexture2D_*` …); promoted parameters are
`Material` `inputs:*`; node groups are `NodeGraph`s; editor layout in
`ui:nodegraph:*` attributes. Most RealityKit nodedefs are published by
Apple under MIT. RCP 3's library names a newer PBR shader (`_v2`) that
Xcode 27.1's compiler and the macOS 27 runtime do not accept: write
`_2_0`. Unknown nodes fall back silently to a grey material.

**Timelines and behaviors.** (Legacy model: RCP 3 authors Animation
Graph and Behavior Tree assets instead — state-machine node graphs,
storage in `project-format.md` §4.7.7.) `RealityKitTimeline` → `RealityKitTrack` →
`RealityKitAction` prims with 14 verified `actionKind`s; each timeline
becomes two animation-library entries on the default prim. Behaviors are
the public `Preliminary_Behavior`/`Trigger`/`Action` schemas (tap,
collision, scene start, notification triggers; the action is "play
timeline"). Notification names are `RealityKit.NotificationTrigger` and
`RealityKit.NotifyAction`.

**Particles and audio.** `RealityKit.VFXEmitter` with `currentState` →
`mainEmitter`/`spawnedEmitter` structs (engine field names, capitalised
enum tokens); preset names only. Audio files are `RealityKitAudioFile`
prims (`file`, looping, loading strategy, calibration, mix group);
spatial/ambient/channel audio, audio library and reverb components are
verified.

**Compile and build.** `realitytool compile` takes `.rkassets` (every USD
inside becomes a scene named by relative path) and writes `.reality`;
deployment target picks `minVersion`; it never reports USD errors (exit
0), so Ycode must validate. Xcode runs `RealityAssetsSchemaGen`
(`create-schema` over the package's Swift files, via
`ModuleWithDependencies.json` → `CustomComponentUSDInitializers.usda`)
then `RealityAssetsCompile` into the package resource bundle (swift-build,
open source). `image` writes KTX 1.1 and `.realityenv`.

**The `.reality` container** (writer level, `compile.md` §6): a ZIP with
version-45 headers, zero timestamps, ZIP64 and `0xfffe` (SHA-256)
extras, a `.align/` entry padding to 4096, a `RAD` end-record comment;
entries `assets/<Kind>_<n>.compiled<kind>`, `assetMap.json`,
`header.json`. Method 99 is plain LZFSE (not encryption; reproduced byte
for byte with the open-source encoder); method 32867 is a `CHNK` frame
of raw/LZFSE chunks. The macOS loader accepts a re-packed, uncompressed
container. The payloads (`CA01`) are RealityKit's internal serialization
and were **not** analysed: levels 2–3 settled the container; payloads
would need levels 4–5, and Ycode does not need them (on macOS it runs
Apple's `realitytool`; on Linux it ships validated USD).

**Editor.** RCP 3: docked tabs/workspaces (Hierarchy, Viewport,
Inspector, Project Browser, Graph, Simulate, Preview, Console, …), a
command palette, Q/W/E/R tools, F/⇧F framing, ⌘R play, import of
USD/glTF/OBJ/PLY/STL/ABC, images and audio, export of Reality, USDA
(mesh) and USDZ (mesh), Preview on device, Run with Xcode, LAN/internet
collaboration, `rcpmerge` for git, plug-ins through the MIT
`RealityComposerPro` package (C entry point
`createRealityComposerProPlugin`). The full menu bar with shortcuts was
read through accessibility (`editor-behavior.md` §15a).

## Proposed clean rounds

One agent each, in order. Each reads only `specs/` (this folder,
`specs/frameworks/realitykit/`), public docs and permissively licensed
open source; none may open the reference app, Xcode internals, the
dirty room, or run Apple's Simulator.

1. **SC-USD** — USDA reader/writer with lossless round trip
   (`scene-usd.md` §1–3, §7) and the component catalogue as a data file
   (§4). Done when: our sample scenes (rewritten by the round from the
   specs) round-trip byte-stable after a no-op edit; unknown prims and
   fields survive; a writer test emits every catalogue component; on a
   macOS host the files load in RealityKit with the expected values
   (test harness provided by the round, using public API only).
2. **SC-PROJECT** — create/open/save the content package
   (`project-format.md` §3, §5, §6) and shape A. Done when: a new package
   made by Ycode builds with `xcodebuild` and `Entity(named:in:)` finds
   its scenes; files outside Ycode's ownership are preserved.
3. **SC-EDITOR** (with COMPOSER-CORE's editor) — hierarchy, inspector
   generated from the catalogue, transform gizmos, selection, undo,
   copy/paste, import of USDZ/USD/images/audio, the menu and shortcut map
   of `editor-behavior.md` §3 and §15a. Done when: a scene with a model,
   collider, input target and light can be authored end-to-end on Linux
   and passes round 1's checks.
4. **SC-COMPILE** — `realitytool`-compatible front end
   (`compile.md` §2–§4, §6–§7): the validator (diagnostics for every
   silent drop), `create-schema` (exact output layout), scene discovery
   and naming, the container reader/writer for inspection and repacking;
   on macOS delegate `compile` to Apple's tool. Done when: our
   `create-schema` output matches the spec's layout on the round's own
   Swift fixtures; the validator flags every case in `compile.md` §2.5;
   the container writer produces files the macOS loader accepts.
5. **SC-MATERIALS** — Shader Graph editor and node library from MaterialX
   and Apple's MIT nodedefs (`materials.md`). Done when: a material using
   PBR, a texture, a promoted parameter and a node group round-trips and
   loads as `ShaderGraphMaterial` with those parameters.
6. **SC-TIMELINES** — timelines, actions, behaviors and notifications
   (`timelines-behaviors.md`), with the open runtime's animation library
   mapping. Done when: each verified action kind round-trips and plays in
   the open RealityKit with the timing rules.
7. **SC-FX-AUDIO** — particle emitters and audio (`particles-audio.md`).
   Done when: emitter and audio components round-trip with all verified
   fields and defaults.
8. **SC-RCP3-IMPORT** — read-only import of RCP 3 directory projects
   (`project-format.md` §4.3, §4.7; component map `scene-usd.md` §4.5).
   Can start on scenes with library shapes, lights, colliders, audio,
   emitters and graph materials; imported meshes and filled animation
   graphs/behavior trees still need owner samples. Done when: the
   round's own hand-written fixtures in the §4.7 grammar import to the
   expected USD prims and component values.

## Open questions (summary)

Steps the owner can do by hand in RCP 3 are marked ✋.

- Q-P2 **Answered** (OBS-RCP2, `project-format.md` §3.6): migration
  writes `<Pkg>/<Pkg>.realitycomposerpro/` in place, one `.import` asset
  folder per USD layer, leaves the legacy files untouched; collider and
  input target survive, `Cube` is baked to a mesh, colours go to
  ACES2065-1.
- Q-P3 **Answered** (OBS-RCP4, `project-format.md` §4.7): the owner's
  app-made sample gave the per-asset grammar, collision mode values
  (0 default, 1 trigger, 2 colliding), the hover-effect, grounding-shadow,
  point-light, emitter, audio-file and audio-library storage, the graph
  material form and `type_hash` (hash of a type name), and the storage of
  empty Animation Graph and Behavior Tree assets. A headless `.reality`
  export of it works (`compile.md` §6.9, `editor-behavior.md` §7a).
  RCP 3's USDA (Mesh) export is geometry-only (`scene-usd.md` §5.1), so it
  settles **no** USD component names.
- Still open after Q-P3: a USD spelling for trigger mode (`type =
  "Trigger"` gives static collision options, `scene-usd.md` §4.3), the
  hover-effect, portal-target, shadow and IBL-source USD names (Q2 there:
  probe permutations or an RCP 2 file), a promoted parameter instance in
  RCP 3, filled animation graphs and behavior trees (✋ owner: add a state
  with a clip, a transition with a condition, a tree with a few nodes and
  a parameter, attach both to an entity, save), the emitter enum tables,
  RCP 3's `rcp_<n>` parameter names, and where a Reality Export Settings
  asset writes its file.
- ✋ Q-P1 Any old RCP 2 project of the owner's: only the key names of
  `ProjectData/main.json` and `WorkspaceData/*`.
- Q-S4 `visibility = "invisible"`: disabled or hidden.
- Q-P6 Template shape A: does the `Materials/` subfolder survive the
  build?
- Compile: does a device loader check the container hashes; method 99
  vs 32867 selection; `.skybox` folder contents; `--use-metal` effect.
- Editor ✋: Q/W/E/R mapping, units, snapping defaults, undo scope,
  statistics counters, copy/paste across projects.
- Full lists are in each file's "Open questions".

## Method and limits

- Black box first: our own samples (in `<samples>/`), RealityKit on
  macOS loading them through a dump probe, `realitytool` runs, one
  `xcodebuild`, headless runs of the reference (a `HOME` override does
  not isolate a sandboxed app; OBS-RCP4 restored the container state its
  runs changed), one background `open -g` with accessibility reads of
  the native menu bar (no clicks or keystrokes).
- The owner's hand-made RCP 3 sample (OBS-RCP4) was read as a file
  format only; headless exports ran on a copy.
- Format study of shipped templates and engine data: grammar and key
  names only; nothing copied.
- Level 4 (names in binaries) only for component, field, schema and node
  names, always marked; every name used by a writer rule was confirmed by
  a run unless flagged.
- No level 5 work was done. Nothing was decrypted (the reference's
  built-in help archives are encrypted and were left alone).

## Evidence

| Topic | Levels | Main sources |
|---|---|---|
| Project shapes and legacy package | 1, 2, 3, 4 | swift-build/SwiftPM open source; Xcode and RCP templates (format study); our package builds; RCP 3 importer names; migration window on our sample |
| RCP 3 directory project | 2, 3, 4 | engine data shipped in RCP 3 (format study, own parser); `rcpmerge --help`; headless runs; strings |
| Scene conventions and components | 2, 3, 4 | template scenes; RealityKit loads of our USDA, before and after `realitytool compile`; type-registry names |
| Materials | 1, 2, 3, 4 | MaterialX; Apple's MIT nodedefs; nodedef files (interfaces only); our material loads |
| Timelines, behaviors, particles, audio | 1, 3, 4 | Apple's public AR schema docs; our loads; names |
| Compile, build, container | 1, 2, 3 | swift-build sources; our compiles and build; container metadata; open-source LZFSE |
| Editor | 1, 3, 4 | Apple's RCP 3 docs and WWDC sessions; accessibility read of menus; names |
| App-made RCP 3 project, its USDA and `.reality` exports | 2, 3 | owner-made sample read with our parser; headless exports parsed with our container reader and loaded by our macOS probe (OBS-RCP4) |
