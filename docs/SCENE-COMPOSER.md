# Ycode Scene Composer

The Ycode Scene Composer is a scene editor for RealityKit content that
runs on Linux (x86-64 and arm64) and macOS, and later Windows. It reads and
writes the same USD scenes and content packages as Apple's Reality Composer
Pro, so content moves both ways, and it validates and packages them for the
runtime. Its command-line tool is `ycode-scene`.

"Reality Composer Pro" (RCP) appears in this document only to explain
compatibility. The composer is clean-room code: the behaviour it matches
comes from `specs/tools/scene-composer/` (written by the dirty room) and
from public USD and MaterialX sources. Normative Ycode decisions are in
`specs/tools/scene-composer/ycode-design.md`.

Status: round 1 (COMPOSER-CORE, 2026-10-29) — design, the USD library, the
document model, the MaterialX network model and the CLI. No user interface
or viewport yet.

## 1. What the reference needs from us

From the OBS-RCP specs (`specs/tools/scene-composer/README.md`):

- RCP 3.0 keeps its own projects in an engine-native format and hands
  `.reality` files to Xcode. The **RCP 1/2 content package** — a Swift
  package with a `.rkassets` folder of USDA scenes — is still compiled by
  every Xcode build, opens in RCP 3 (by migration) and is plain USD. Ycode's
  native project format is that package (shape B of `project-format.md`),
  plus plain `.usda` files in an app target (shape A).
- Scenes are USDA with fixed conventions (`scene-usd.md` §1): a `Root`
  `Xform` default prim, metres, +Y up, T·orient·S transform ops,
  `MaterialBindingAPI` bindings with `weakerThanDescendants`, imports as
  typeless referencing prims.
- Components are `RealityKitComponent` child prims with `info:id =
  "RealityKit.<Kind>"`; wrong names are dropped silently, so the composer
  writes only catalogued names and its validator reports the rest.
- Materials are UsdShade networks of MaterialX nodedefs, including
  RealityKit's `ND_realitykit_*` nodes; the PBR node to write is `_2_0`,
  not `_v2` (`materials.md` §5).
- `realitytool compile` exits 0 on bad input (`compile.md` §2.5); Ycode's
  validator is the only place errors are reported. On macOS the build can
  run Apple's tool; on Linux Ycode ships validated USD (the open RealityKit
  loads USD directly, `specs/frameworks/realitykit/07-assets.md` §8).

## 2. Architecture

```
            ┌──────────────────────── app shell (later rounds) ───────────────────────┐
            │  panels: hierarchy · inspector · project browser · graph · timeline      │
            │  UI toolkit (§3)                     viewport (Vulkan, §2.4)             │
            └───────────────┬──────────────────────────────────┬──────────────────────┘
                            │                                  │
   ycode-scene (CLI) ───────┤                                  │
                            ▼                                  ▼
   composer/  SceneComposerCore: SceneDocument · commands/undo · selection ·
              transforms · clipboard · components (catalogue) · validator
              (later: project package, compiler front end, importers)
                            │
   frameworks/usd/  USDCore (paths, values, layers; USDA, USDC, USDZ)
                    USDStage (composition)   USDShade (UsdShade + MaterialX)
                            │
                  shared later with OpenReality (frameworks/realitykit)
```

### 2.1 Core libraries (`frameworks/usd`, package `ycode-usd`)

- **USDCore** — the Sdf-level data model: `Path`, `Value` (every USD value
  type, arrays as flat component buffers), `Spec`, `Layer` (a value type: a
  map from paths to specs with typed fields, children kept as token
  vectors exactly as the binary format stores them), list ops, references,
  payloads, layer offsets. File formats:
  - USDA reader (recursive descent, the whole prim/property/metadata
    grammar of OpenUSD's text format) and writer. The writer has two
    modes: *authored order* (default; exact round trip) and *OpenUSD
    order* (properties and variants sorted), which reproduces usd-core's
    own output byte for byte on our fixtures.
  - USDC (crate) reader for versions 0.4–0.10 and writer for 0.8.0
    (0.9.0/0.10.0 when timecodes or path expressions are present), with
    compressed structural sections and compressed int/float arrays. LZ4 and
    the crate integer coding are our own code.
  - USDZ: stored ZIP, root layer first, entry data on 64-byte boundaries.
- **USDStage** — composition for an editor: layer stacks (sublayers with
  offsets), references, payloads (loadable), inherits, specializes,
  variant selections and fallbacks, LIVRPS strength order with direct arcs
  stronger than ancestral ones, child and property name composition
  (weakest first), value resolution with time samples and layer offsets,
  target and connection mapping into stage namespace, `flatten()`.
  Instancing, relocates, value clips and implied inherits are not composed
  (round SC-USD).
- **USDShade** — `ShadeNetwork` (a Material's Shader and NodeGraph prims,
  typed ports, connections; read from a layer or a stage, written back,
  validated) and `MaterialXLibrary` (MaterialX `<nodedef>` documents with
  `inherit`; the open MaterialX 1.39.5 stdlib, pbrlib and bxdf definitions
  are bundled).

### 2.2 Document model (`composer/`, package `ycode-scene-composer`)

- **SceneDocument** — one layer is the edit target; a `Stage` over it gives
  the composed view (references to imported assets, variants). The layer
  is a value: every edit runs on a copy and is committed as a
  `LayerDelta` (before/after specs of the paths that changed), so every
  edit is undoable, grouping is a merge of deltas, and failing edits leave
  the document untouched.
- **Edits** — create, delete (local specs are removed; prims that come from
  other sites are deactivated), rename and reparent (relationship targets
  and connections in the layer follow), duplicate, copy/paste through a
  USDA clipboard layer (paths inside copied subtrees are remapped),
  attribute values and time samples, metadata, transforms, references,
  variant selections, material binding, components.
- **Transforms** — UsdGeom op semantics in USD's row-vector convention
  (checked against usd-core); edits write `translate`/`orient`/`scale`
  (`scene-usd.md` §1); world/local conversion for gizmos.
- **Selection** — ordered paths with a primary; follows renames.
- **Components** — a `ComponentStorage` protocol with the RealityKit
  encoding (`RealityKitComponent` / `RealityKitCustomComponent` prims,
  `RealityKitStruct` children, relationships for entity references) and a
  catalogue data file (`Resources/components.json`) built from
  `scene-usd.md` §4.3; unknown prims and fields stay in the layer untouched.
- **Validator** — layer conventions, composition errors, dangling targets
  and connections, value/type mismatches, xform op order, mesh topology,
  MaterialX interfaces, the `_v2` PBR node, and every component problem the
  runtime drops silently.

### 2.3 Command-line tool (`ycode-scene`)

`info`, `tree`, `cat` (USDA, optionally flattened or sorted), `convert`
(USDA ⇄ USDC ⇄ USDZ, USDZ with relative dependencies), `validate` (exit 1
on errors), `edit` (scripted, undoable operations), `components`. It is the
test harness for every later round and the build step on Linux.

### 2.4 Viewport (later round)

A Vulkan renderer shared with, or built ahead of, OpenReality's
`RealityRenderer` (`specs/frameworks/realitykit/09-open-design.md` §2.4,
`10-plan.md` R2/R6): the composer needs a subset first (meshes and
implicit shapes, PBR from `UsdPreviewSurface`/`ND_realitykit_pbr`, lights,
IBL, selection outlines, gizmos, grid). Building it as the R2 headless
renderer plus an interactive surface means the composer and the open
RealityKit share one renderer. On macOS it runs on MoltenVK
(Apache-2.0) or Ycode's own Metal-on-Vulkan pieces, never on Apple's
RealityKit.

### 2.5 Compiler (later round)

`compile.md` §7: on macOS, run Apple's `realitytool` the way Xcode does;
elsewhere validate the `.rkassets` tree, run our `create-schema`, and ship
USD. A `.reality` container reader/writer (`compile.md` §6) supports
inspection and re-packing.

## 3. UI toolkit for Linux and macOS

The composer needs docked panels, trees, property grids, a node-graph
editor, a timeline and one or more Vulkan viewports, on Linux first.

| Option | Licence | Swift fit | Linux today | Notes |
|---|---|---|---|---|
| Open SwiftUI port (`frameworks/swiftui`, "OpenViews") | MIT (ours) | native Swift, the API Apple developers know | **no rendering**: rounds R1–R4 and R6 are done (views, data flow, layout, text, animation) but there is no renderer (R5) and no platform host or display link (R7) | the right long-term home for panels; not usable for this tool yet; would also need list/outline, split views, a canvas for graphs |
| SDL3 or GLFW + Dear ImGui (docking) | SDL3 zlib (3.4.18), GLFW zlib (3.5.1), Dear ImGui MIT (1.93.0), cimgui MIT | C API through `cimgui`, imported as a Swift module; immediate-mode code is short in Swift | yes (X11/Wayland), Vulkan backend shipped with Dear ImGui | used by many engine editors; docking, tables, trees, node editors exist as MIT add-ons; looks like a tool, not a native app; text input and accessibility are basic |
| Qt 6 | LGPL-3.0 (or GPL/commercial) | C++ only; Swift C++ interop can call it but moc/signals need generated glue; large | yes | best widgets and accessibility; LGPL obliges dynamic linking and relinkability, adds a large runtime to every install, slow to build on the Thor |
| GTK 4 | LGPL-2.1+ | C API (GObject); Swift bindings exist but are thin and lag | yes, native on GNOME | weak on macOS; Vulkan viewport needs a GL/Vulkan interop widget; LGPL like Qt |
| Web UI with a Swift back end | front end any (MIT libraries); back end e.g. Hummingbird (Apache-2.0); a WebView shell or the browser | back end in Swift, UI in TypeScript | yes (browser) | two languages; the viewport must be WebGPU/WebGL in the page (a second renderer) or a streamed image; good for remote use on the Thor |

**Decision (2026-10-30): OpenViews.** The composer's editor UI,
like the Linux IDE, is built on Ycode's own SwiftUI port
(`frameworks/swiftui`), behind a thin `ComposerUI` module so panels talk
only to `SceneComposerCore`:

1. One UI codebase in SwiftUI's API for the composer and the Linux IDE
   (`docs/PARITY.md` §5); on macOS the same panels can use Apple's SwiftUI.
2. OpenViews' rendering (R5: display list, ThorVG, Vulkan compositor) and
   platform host (R7: SDL3 windows and input) are the prerequisites; the
   viewport shares the Vulkan device with the compositor.
3. The editor also needs OpenViews' later desktop rounds (controls R8,
   containers R9, and the outline, split-view, drag-and-drop and
   text-editing rounds proposed in `docs/PARITY.md`), plus a canvas for the
   node-graph and timeline editors.

The table above records the options that were compared; SDL3 is used
underneath OpenViews (R7) rather than as the UI toolkit.

## 4. Where the code lives

- `frameworks/usd/` (package `ycode-usd`): the reusable USD library, so the
  future OpenReality package (`10-plan.md` R5 asset loading, R9 USDKit) and
  the IDE share one implementation.
- `composer/` (package `ycode-scene-composer`, repository top level): the
  document model, CLI, and later the compiler front end and the app shell.
  A separate package keeps the IDE's large `ycode/` package (simulator,
  translators) out of the composer's build, which matters on the Thor; the
  IDE integrates by depending on `composer/` as a path package (round
  SC-IDE below).

## 5. Dependencies: Swift-native USD

| Choice | For | Against |
|---|---|---|
| **Swift-native USDA/USDC/USDZ + composition (chosen)** | no C++ toolchain issues; builds in ~5 s; values-and-specs model fits an editor's undo; same code on every platform | composition subset must grow with use (instancing, relocates, clips) |
| OpenUSD through C++ interop | complete composition, schemas, USDKit-shaped API | very large (TBB, Boost-free but still ~1M lines); tens of minutes per build on the Thor; Swift C++ interop with its template-heavy API is fragile; TOST 1.0 is fine licence-wise |
| tinyusdz (Apache-2.0) | small C++ reader | composition and writing are partial; still C++ interop |

The crate format is implemented from OpenUSD's open-source
`crateFile`/`integerCoding`/`fastCompression` sources used as the format
description (TOST 1.0, Apache-2.0-based); Pixar's `usd-core` Python wheel
was used during development as a black-box oracle (its outputs are test
fixtures; `frameworks/usd/Scripts/make_fixtures.py`). If a later round needs
full OpenUSD fidelity (e.g. value clips), OpenUSD can be added behind the
same `Layer`/`Stage` API for platforms where its build cost is acceptable.

## 6. Rounds

| Round | Scope | Spec input | Exit |
|---|---|---|---|
| **COMPOSER-CORE** (done) | this document; `ycode-usd`; document model; MaterialX model; `ycode-scene` | public USD/MaterialX; `scene-usd.md` §1, §4 | tests green on macOS, x86-64 and arm64 Linux |
| SC-USD | composition gaps (instancing as prototypes, relocates, clips), unknown-field pass-through checks on RCP samples, writer test emitting every catalogue component, macOS load harness (public RealityKit API) | `scene-usd.md` §1–3, §7 | per README round 1 |
| SC-PROJECT | create/open/save the content package and shape A (`main.json`, `Package.swift`, `Bundle.module` file), asset import into `.rkassets`, rename with reference fix-up | `project-format.md` §3, §5, §6 | a new package builds with `xcodebuild` |
| SC-EDITOR | app shell (§3), hierarchy, inspector generated from the catalogue, viewport v1, gizmos, menus/shortcuts of `editor-behavior.md` §3/§15a | `editor-behavior.md` | a scene with model, collider, input target and light authored end-to-end on Linux |
| SC-COMPILE | `realitytool`-compatible front end: validator rules of `compile.md` §2.5, `create-schema`, scene discovery and naming, `.reality` container reader/writer; macOS delegation | `compile.md` | per README round 4 |
| SC-MATERIALS | Shader Graph editor; RealityKit nodedefs from `apple/plugins-for-godot` (MIT, verified) plus the 14 interfaces in `materials.md` §9; promoted parameters; node groups; editor layout attributes | `materials.md` | PBR + texture + promoted parameter + node group round trip |
| SC-TIMELINES | timelines, actions, behaviors, notifications | `timelines-behaviors.md` | each action kind round-trips |
| SC-FX-AUDIO | particle emitters and audio components | `particles-audio.md` | emitter and audio round trip |
| SC-RCP3-IMPORT | read-only import of RCP 3 projects (after a dirty round) | `project-format.md` §4 | per README round 8 |
| SC-IDE | Ycode IDE integration: open `.realitycomposerpro`/`.rkassets` from the navigator, build phase (validate; on macOS `realitytool`), schema step | `compile.md` §3 | an app target with a content package builds in Ycode |

## 7. Open questions for OBS-RCP

Answered by the specs that arrived during this round: project format,
component encoding, transform op stack (T·orient·S), binding form, the PBR
node name. Still open, and needed by later rounds:

1. Trigger colliders (`scene-usd.md` Q1) — the catalogue writes `type =
   "Default"` only.
2. Which RCP-written prims carry `active = true` and `references = None`
   (written "on most prims the editor created"): should Ycode write them on
   every new prim to keep diffs with RCP small?
3. `customLayerData` creator string: exact format RCP writes (the composer
   writes `"Ycode Scene Composer"`; `scene-usd.md` §1 suggests
   `"<tool name> <version>"`).
4. Does RCP sort properties (as OpenUSD's writer does) or keep authored
   order? The composer keeps authored order by default and can sort.
5. `main.json` key names (`project-format.md` Q-P1) for SC-PROJECT.
6. Undo scope and copy/paste across projects (editor open questions).

## 8. Build and test

    cd frameworks/usd && swift build && swift test
    cd composer && swift build && swift test
    ycode/scripts/lint.sh

Both packages build with Swift 6.4 and no system libraries on macOS and
Linux. Results for this round are in `frameworks/usd/README.md` and
`composer/README.md`.
