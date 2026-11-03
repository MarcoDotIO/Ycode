# Scene composer 1: project formats

Status: draft round 0 (OBS-RCP, 2026-10-29). Reference: Reality Composer
Pro 3.0 (`3.0 (1A153)`, engine build 75.0.14.500.1), Xcode 27.1
(27A9269) and its `realitytool`. Ycode's tool gets its own name; "RCP"
below names only the reference.

Evidence tags: **[tmpl]** format study of templates and data shipped
with Xcode or RCP (grammar and key names only, nothing copied);
**[run]** our own black-box runs; **[oss]** open-source swift-build /
SwiftPM / the MIT RCP plug-in interface; **[str]** binary metadata names
(level 4); **[doc]** Apple's public RCP documentation.

## 1. Three project shapes

| Shape | Who writes it | Scenes stored as | How Xcode uses it |
|---|---|---|---|
| A. USD in the app target | Xcode 27.1's visionOS app template | `.usda` files in the app's `Resources` group | copied as plain resources; RealityKit loads the USD at run time |
| B. "Legacy" content package (RCP 1/2 generation) | RCP 1/2; still built by Xcode 27.1 | `.usda` in a `.rkassets` folder inside a Swift package, plus a `Package.realitycomposerpro` bookkeeping folder | `realitytool compile` turns `.rkassets` into a `.reality` in the package's resource bundle (`compile.md` §3) |
| C. RCP 3 project | RCP 3.0 | an engine-native text/binary asset tree in a `<Name>.realitycomposerpro` directory | not built by Xcode; RCP 3 **exports** `.reality` files into an Xcode project that copies them as resources |

Both B and C use the extension `.realitycomposerpro`; §5 says how to
tell them apart.

**Ycode policy (proposal).** Ycode's native format is **B** (USD source,
built by stock Xcode, readable by every USD tool, migrated by RCP 3 on
open). Ycode reads A and B fully, imports USD exported by RCP 3, and
treats C as a later read-only import round (§4.6). It never writes C.

## 2. Shape A: USD directly in the app target

- The template adds `ContentView.swift` plus `Resources/Scene.usda`,
  `Resources/Immersive.usda` and a `Resources/Materials` folder holding a
  Shader Graph material layer **[tmpl]**. Scenes reference the material
  layer by a relative path (`@Materials/<File>.usda@`).
- Swift loads them by base name from the main bundle (e.g.
  `Model3D(named: "Scene", bundle: .main)`) **[tmpl]**.
- Xcode has no build rule for `.usd*`, `.reality` or `.realityenv`
  files; they are ordinary resources **[oss]** (no such file types in
  swift-build's specifications). Whether the `Materials/` subfolder is
  preserved in the bundle (needed for the relative reference) depends on
  how the group is added (folder reference versus synchronized group);
  open question Q6.

## 3. Shape B: the legacy content package

### 3.1 Layout

```
<Package>/                         Swift package root (name = product = target)
  Package.swift
  Package.realitycomposerpro/      RCP 1/2 bookkeeping (not a build input)
    ProjectData/main.json
    WorkspaceData/…                (per-user editor state, §6)
  Sources/<Package>/
    <Package>.swift                exports the resource bundle
    <Package>.rkassets/            the scenes: the build input
      Scene.usda
      <sub>/<More>.usda
      <textures, audio, referenced .usdz …>
  Tests/…                          optional
```

The `.rkassets` location `<root>/Sources/<Name>/<Name>.rkassets` with
`<Name>` equal to the package folder name is what RCP 3's legacy
importer expects ("did not find .rkassets folder at expected path")
**[str]**.

### 3.2 `Package.swift`

- `swift-tools-version` **5.7 or later**: SwiftPM then treats a
  `.rkassets` folder as a processed resource automatically, without a
  `resources:` entry **[oss]** (SwiftPM's PIF builder rule for
  `rkassets`).
- One library product and one regular target named like the package;
  platforms for the OSes that load the content. A minimal package of
  ours with one library target and no dependencies built, and its
  `.rkassets` was compiled into the package resource bundle **[run]**
  (`compile.md` §3.3).
- The target exports the bundle, conventionally
  `public let <lowerCamelPackage>Bundle = Bundle.module`, and apps load
  `Entity(named: "Scene", in: <thatBundle>)` (`compile.md` §3.4).
- Custom components (`Component, Codable` Swift types) in the same
  target are turned into a schema layer during the build
  (`create-schema`, `compile.md` §4); their prims in scenes follow
  `scene-usd.md` §4.1.

### 3.3 `Package.realitycomposerpro`

- `ProjectData/main.json` is the marker RCP 3 looks for to recognise a
  legacy project **[str]**. Its content is a JSON object; the form
  published in public sample projects maps package-relative scene paths
  to UUID strings (`{"pathsToIds": {"/<Package>/Sources/<Package>/<Package>.rkassets/Scene.usda": "<UUID>", …}}`).
  That key form is **unverified** here (no RCP 1/2 is installed; no run
  could show it) — open question Q1. Ycode writes it in that form and
  never depends on reading it.
- `WorkspaceData/` holds per-user and per-workspace editor state (file
  names in public samples: `SceneMetadataList.json`,
  `Settings.rcprojectdata`, `<user>.rcuserdata`) — unverified, Q1. Ycode
  writes nothing there and preserves whatever exists.
- Neither folder is read by `realitytool` or Xcode **[oss]**: the build
  sees only the `.rkassets` folder (swift-build compiles every
  `folder.rkassets` in a resources phase; `compile.md` §3).

### 3.4 Opening a legacy package in RCP 3

RCP 3 offers a one-way migration ("to continue editing … you'll need to
migrate this project") through an editor command that imports RCP 2
projects; USD scenes are extracted into the new asset tree **[str]
[doc]**. The importer reads `ProjectData/main.json` and the `.rkassets`
folder **[str]**. Opening our hand-made `<samples>/legacy/ObsContent` (only
`ProjectData/main.json`, an empty `WorkspaceData/` and the `.rkassets`
folder) in a background RCP 3 instance produced a window titled
"Migrate ObsContent" **[run]** (accessibility read, no clicks): the
minimal layout is enough to be recognised. Accepting the migration needs
a click; the owner accepted it by hand and its output is described in
§3.6 (Q2 answered).

### 3.6 What the migration produces (observed)

Input: `<samples>/legacy/ObsContent` — `Package.swift`,
`Package.realitycomposerpro/ProjectData/main.json` (two path→UUID
entries), empty `WorkspaceData/`, and `ObsContent.rkassets/` with
`Scene.usda` (a `Cube` "Box" with a box collider of type `Default`, an
input target, a `MaterialBindingAPI` binding, and a typeless prim
"Tint" referencing `Materials/Tint.usda`) and `Materials/Tint.usda` (one
`UsdPreviewSurface` material) **[run]**.

Where it goes. The migration writes **in place**: a new directory
project `<Package>/<Package>.realitycomposerpro/` is created *inside*
the legacy package folder, beside `Package.swift`. No save dialog is
shown. The legacy files (`Package.swift`, `Package.realitycomposerpro/`,
`Sources/…/*.rkassets`) are left byte-for-byte unchanged, so the legacy
package still builds with Xcode **[run]**. After migration the editor
window shows the new project as edited (unsaved), but every file below
was already on disk.

Layout written (only the user content is listed; `core.lib/` is a copy
of the engine's core asset library, the same in every project):

```
ObsContent.realitycomposerpro/
  project.rcp                             empty marker
  __type_index.tm_meta                    916 type definitions
  __migration_index.tm_meta               array of 123 applied migration ids (hex strings)
  __project_settings.tm_project_settings  settings owner (cloth gravity, rendering,
                                          build settings: xcode_directory,
                                          plugin_directory, build_configuration "Debug",
                                          camera sensor size, lightmap)
  core.lib/                               engine core library (materials, creation
                                          graphs, environments, IBL textures, icons)
  Custom Components/                      folder asset, with a "Referenced" subfolder
  Scene.import/                           one ".import" folder per source USD layer
    __tm_directory.tm_dir
    settings.tm_usd                       tm_usd_asset: source_path, import settings,
                                          variants
    settings.tm_buffers/<uuid>.<hash>     two binary blobs: the import session
                                          (magic "TMTS") and the scene-optimizer output
    __Scene.tm_entity                     the imported hierarchy (full)
    __Scene_optimized.tm_entity           the optimized hierarchy
    Scene.tm_entity                       proxy: prototype of __Scene_optimized, no overrides
    geometry/Box.tm_geometry (+ .tm_buffers)  vertex channels and indices
    meshes/Box.tm_mesh_resource           model list with bounds
    materials/Tint.tm_material            the bound material, converted
  Materials/
    __tm_directory.tm_dir
    Tint.import/                          the material layer, imported on its own
      (same shape: settings.tm_usd, __Tint.tm_entity, __Tint_optimized.tm_entity,
       Tint.tm_entity, materials/Tint.tm_material)
```

There is no top-level `__tm_directory.tm_dir` and no
`project.the_machinery_dir` (both appear in the engine data shipped in
the app, §4.2) **[run]**. `main.json`'s UUIDs do not appear anywhere in
the new project: identity is re-minted.

Per source layer (`tm_usd_asset`):

| Key | Content |
|---|---|
| `source_path` | the **absolute** path of the source `.usda` (a machine path; Ycode must strip or ignore it) |
| `settings` | `tm_scene_optimizer` (a graph interface with inputs `scene_optimizer_settings__merging_mode`, `scene_optimizer_settings__keep_entities_list`; `output` = buffer id) and `tm_lod_generator` |
| `pro_settings` | `tm_usd_purpose_settings`, `tm_usd_dev_settings` (`mesh_creation_graph` → a core-library creation graph) |
| `variants` | one `Default` entry: `root_entity` (the full entity), `proxy_entity` (the proxy), `session` (buffer id) |

What each legacy item became:

| Legacy USD | RCP 3 result |
|---|---|
| layer `Scene.usda` | asset folder `Scene.import/` with the three entity assets above |
| `Xform "Root"` (default prim) | child entity `Root` under an entity named `/` (the stage pseudo-root) |
| `Cube "Box"` (`size = 0.2`) | entity `Box` with `tm_model_component` → `tm_mesh_resource_reference` → `meshes/Box.tm_mesh_resource` (24 vertices, bounds ±0.1); the cube primitive is baked to a mesh, not kept as a parametric shape |
| `xformOp:translate` | `tm_transform_component.local_position_double.y = 0.1` (doubles; zero components omitted) |
| `RealityKit.Collider` (box, `type = "Default"`, group 1, mask all) | `tm_re_collision_component`: one shape `tm_re_collision_shape_box` with `width`/`height`/`depth` 0.2, `mode: 0`, an empty `filter` (group/mask at their defaults); shape `name` empty. The shape's `orientation` was written with `w: 0` (a zero quaternion, not identity) |
| `RealityKit.InputTarget` (no fields) | `tm_re_input_target_component` (no fields, i.e. defaults) |
| `material:binding` → `/Root/Tint/Tint` | the model component's `materials` array: one slot named after the mesh (`Box`) → `Scene.import/materials/Tint.tm_material` |
| `UsdPreviewSurface` material | `tm_material` with `shader.asset_path = "engine:pbr.rematerialdefinition"` and a shader graph: `tm_output_node` ← node `ND_UsdPreviewSurface_surfaceshader` (label "Surface"); `diffuseColor` (0.2, 0.6, 0.9) became a `tm_color_aces2065_rgb` data entry (0.477, 0.593, 0.854: converted to ACES2065-1); the `roughness` entry is present with no stored value. The graph interface lists the full PBR parameter set (`textureBaseColor` … `baseColorTint`, `roughnessScale`, … `Blending`) |
| typeless prim `Tint` referencing `Materials/Tint.usda` | an empty entity `Tint` (transform only) in `__Scene`; **dropped** from `__Scene_optimized` |
| `Materials/Tint.usda` | its own `Materials/Tint.import/` asset (entity `/` → `Root`, no children) with a second copy of the material (same content, new UUIDs) |
| `Package.swift`, `main.json`, `WorkspaceData/`, `ObsContent.swift` | not read into the project; left as they were |

The default `tm_re_collision_component` in the type index has
`mode: 2` and one box shape named "Shape 1", whereas the migration wrote
`mode: 0` for the USD `Default` type **[run]** (so 0 is not "the
component's default"; the full mode enumeration, including trigger, is
still open: `scene-usd.md` Q1).

Consequences for Ycode:

- An RCP 3 user who migrates a Ycode-written package ends up with two
  sources of truth in one folder (the untouched `.rkassets` and the new
  directory project). Ycode should detect a sibling
  `<Name>.realitycomposerpro/` with `project.rcp` inside a package and
  warn that edits made in RCP 3 are no longer reflected in the USD.
- The RCP 3 importer bakes `Cube`/`Sphere` primitives to meshes and
  converts colours to ACES2065-1; a round trip back to USD will not
  reproduce the original prims.

### 3.5 What the editor writes (shape B), as Ycode should do it

| User action | Files touched |
|---|---|
| New scene | new `<Name>.usda` in `.rkassets` (layer per `scene-usd.md` §1, empty `Root`); a `main.json` path→UUID entry (Ycode choice: random UUID, upper case) |
| Import an asset (USDZ, image, audio) | copy the file into `.rkassets` (default: next to the scene, or an `Assets/` folder); scenes reference it by relative path; `main.json` entry for USD files |
| Add an asset to a scene | a referencing prim (`scene-usd.md` §2) |
| Add a component | a `RealityKitComponent` child prim (`scene-usd.md` §4) |
| New material | a `Material` prim in the scene or a material-library layer (`materials.md` §1) |
| Rename/move | rename the file, update every `@…@` reference and `main.json` key |
| Save | rewrite only changed layers, USDA text, LF line endings, 4-space indentation as in the reference |

## 4. Shape C: the RCP 3 project

RCP 3 is built on a component-based engine with a plug-in architecture
(about a hundred plug-in libraries) **[str] [doc]**. A project is an
asset database stored as files.

### 4.1 Containers

| Form | Extension / UTI | Notes |
|---|---|---|
| Directory project | `<Name>.realitycomposerpro`, UTI `com.apple.realitycomposerpro` (conforms to `com.apple.package`) **[tmpl]** | the normal form; marker file `project.rcp` at its root **[str] [tmpl]** |
| Single-file project | `.rcp`, UTI `com.apple.corerealitytools.project.object` (conforms to `public.data`) **[tmpl]** | a database form (`project.rcp_db` named in the binary) **[str]**; not observed |
| Object Capture project | `.objcap` (package) | also opened by the app; out of scope |

### 4.2 Directory layout (from the engine data shipped in the app, studied as a format)

```
<Name>.realitycomposerpro/
  project.rcp                          marker (empty)
  project.the_machinery_dir            second marker (empty) in the shipped data
  __project_settings.tm_project_settings
  __type_index.tm_meta                 self-describing type table
  __migration_index.tm_meta            list of applied migration ids
  __tm_directory.tm_dir                one per folder (folder asset)
  <asset>.<kind>                       one text file per asset
  <asset>.tm_buffers/<uuid>.<hash16>   binary blobs belonging to that asset
  <folder>/__tm_directory.tm_dir
  <folder>/<asset>.<kind> …
```

Asset kinds seen (file extension = kind): `tm_entity` (entity
hierarchies, the scene unit), `tm_creation` (creation graphs: textures,
meshes, materials pipelines), `tm_material`, `tm_shadergraph`,
`tm_texture`, `tm_compute_graph`, `tm_physics_material`, `tm_asset_label`,
`tm_dashboard`, `tm_data_transform`, `tm_project_settings`, `tm_dir`,
`tm_meta` **[tmpl]**; in a project made in the app also `tm_audio_file`,
`tm_animation_graph`, `tm_behavior_tree`, and (by the exporter's
extension list) `tm_reality_export_settings` **[run] [str]** (§4.7). The
file extension is not always the object's `__type`: `tm_audio_file`
holds a `tm_audio_file_asset`, `tm_animation_graph` a
`tm_re_animation_graph`, `tm_behavior_tree` a `tm_re_behavior_tree`.
Folder and asset names may contain spaces.

### 4.3 Text grammar

- UTF-8; one object per file, written as `key: value` lines; **no
  commas**; tabs indent; keys are bare identifiers or quoted strings;
  values are quoted strings (backslash escapes), integers, decimals
  (floats printed with up to 17 significant digits), `true`/`false`,
  `{ … }` objects and `[ … ]` arrays **[tmpl]**. Our own 60-line parser
  read every shipped file.
- Reserved keys: `__type` (type name), `__uuid` (object identity, a
  UUID-formatted 128-bit value), `__asset_uuid` (identity of the asset
  as a whole), `__asset_thumbnail` (object holding a buffer id),
  `__asset_labels` (array of 16-hex-digit label hashes),
  `__prototype_type` / `__prototype_uuid` (the object inherits from a
  prototype — e.g. an entity or graph placed from another asset — and
  stores only overrides), `<field>__instantiated` (overridden array
  elements of a prototype) **[tmpl]**.
- Binary data (images, meshes, compiled shaders, thumbnails) is held in
  buffers: a field stores the buffer's UUID string, and the bytes are in
  `<asset>.tm_buffers/<uuid>.<16-hex content hash>` **[tmpl]**.
- `__type_index.tm_meta` is an array of type definitions
  `{name, properties: [{name, type, type_hash?}], default?}` (925 types
  in the shipped data). Property types: `bool`, `uint32_t`, `uint64_t`,
  `int32_t`, `int64_t`, `float`, `double`, `string`, `buffer`,
  `reference`, `reference_set`, `subobject`, `subobject_set`, or a type
  name/hash for typed subobjects **[tmpl]**. A reader can therefore load
  unknown types generically.
- Hashes stored in graph assets are 64-bit MurmurHash64A (seed 0) of the
  identifier string (`materials.md` §10) **[run]**.
- Shipped data contained an absolute source path from the authoring
  machine in an image asset (`filename`). Ycode must never write
  absolute paths and must tolerate them on read.

### 4.4 Entities and components

An entity asset has `name`, `components` (array of typed subobjects),
`children` (entities), `child_sort_values` (editor order) **[tmpl]**.
Component subobjects are engine types; the RealityKit ones are named
`tm_re_<kind>_component` with snake_case fields (125 `tm_re_*` types),
e.g. collision (`shapes`, `mode`, `filter`; shapes
`tm_re_collision_shape_box/sphere/capsule/convex_mesh/static_mesh`),
physics body, physics motion (`linear_velocity`, `angular_velocity`),
lights, IBL, grounding shadow (`casts_shadow`, `receives_shadow`, …),
input target (`input_type`, `is_enabled`), accessibility, character
controller, particle emitter, spatial/ambient/channel audio, audio
library and mix groups, portals, billboard, opacity, hover effect,
tone mapping, bloom, decals, navigation mesh, behavior trees, animation
graphs, IK rigs **[tmpl]** (full list in the dirty-room notes). Engine
types (`tm_transform_component`, `tm_render_component`,
`tm_model_component`, …) sit beside them.

### 4.5 Getting content to Xcode

- RCP 3 exports `.reality` files (export settings assets, or entities)
  and copies them into a linked Xcode project; the RCP app template's
  Xcode project includes `Scene.reality` as an app resource and,
  optionally, two local packages: the MIT-licensed plug-in interface
  package and a custom-components package whose dynamic library RCP
  loads as a plug-in **[tmpl] [oss] [doc]** (`editor-behavior.md` §12).
- A headless command line exports too: `--reality-export-asset`,
  `--reality-export-all`, `--reality-export-output`,
  `--reality-export-version` (15.0 … 27.0), `--usd-run-pipeline` with
  `--usd-asset`/`--usd-output-reality` **[str]**. With a project made
  in the app, a headless entity export works (`editor-behavior.md` §7a,
  `compile.md` §6.9) **[run]**; an empty directory holding only
  `project.rcp` never finishes loading.
- Version control: the `rcpmerge` tool is a three-way merge driver for
  the directory format; recommended `.gitattributes` route
  `*.realitycomposerpro/**` to it and exclude `*.tm_buffers/**` (binary)
  **[run]** (its `--help`).

### 4.6 Round for Ycode

A read-only importer for shape C can now be specified from §4.3 and
§4.7: text grammar, defaults from the project's type index, prototype
resolution against `core.lib/`, `tm_re_*` components mapped onto the
`scene-usd.md` component catalogue (mapping table in
`scene-usd.md` §4.5), buffers for textures and audio. Still missing for
it: imported meshes in a project made in the app, and non-empty
animation graphs and behavior trees. Until then Ycode imports what RCP 3
exports as USD (`editor-behavior.md` §7) or `.reality`.

### 4.7 A project made in the app (observed, OBS-RCP4)

Input: a project the owner made by hand in RCP 3.0 (`<samples>/sample3-src/`):
New Project; a cube from the core library with Collision (mode
Trigger), Input Target, Spatial Audio, an Audio Library entry, a Particle
Emitter, Hover Effect and Grounding Shadow; a point light; a material
made from an imported PNG; an imported WAV; an empty Animation Graph and
an empty Behavior Tree asset; saved. Read with our own parser **[run]**.

#### 4.7.1 Files

```
<Name>.realitycomposerpro/
  project.rcp                             empty marker
  __type_index.tm_meta                    916 type definitions (§4.3)
  __migration_index.tm_meta               123 applied migration ids (same list as a
                                          migrated project, §3.6)
  __project_settings.tm_project_settings  tm_settings_owner (cloth gravity, rendering,
                                          build settings with xcode_directory "",
                                          plugin_directory "", build_configuration
                                          "Debug", camera sensor size)
  core.lib/                               engine core library copy (§4.7.6)
  Custom Components/__tm_directory.tm_dir
  Custom Components/Referenced/__tm_directory.tm_dir   (parent = the folder's __uuid)
  world.tm_entity                         the scene: one tm_entity named "world"
  <image>.tm_texture                      imported PNG
  <image>.tm_buffers/<uuid>.<hash>.<file name>          the PNG, byte-identical
  <image>.tm_material                     material made from the texture (§4.7.4)
  <sound>.tm_audio_file                   imported WAV (§4.7.5)
  <sound>.tm_buffers/<uuid>.<hash>.<file name>          the WAV, byte-identical
  <sound>.tm_buffers/<uuid>.<hash>                      decoded samples
  Animation Graph.tm_animation_graph      new asset, default name
  Behavior Tree.tm_behavior_tree          new asset, default name
```

Assets live at the project root unless the user makes folders; the file
name (without extension) is the asset name shown in the Project
Browser. Folders are `__tm_directory.tm_dir` objects
(`tm_asset_directory`: `name`, `parent` = the parent folder object's
`__uuid`; a top-level folder has no `parent`). There is no top-level
`__tm_directory.tm_dir`.

#### 4.7.2 Grammar rules confirmed on user content

| Rule | Detail |
|---|---|
| Omitted fields | A field is written only when it differs from the default of the type that owns it. A type's `default` in the type index gives its scalar defaults and the initial content of its subobjects; a subobject is itself compared with its own type's default. Example: the point light's `intensity` is absent (type default 100000), while its `color` subobject carries `g` and `b` because the light type's initial colour differs from the colour type's default (1, 1, 1) in the last float bit. Readers must apply type-index defaults, not zero. |
| Subobjects | Every subobject is written, even when empty, as `{ __uuid: … }`. |
| Polymorphic subobjects | Fields declared with the type hash of `tm_anything` (`8944e0b1cefd4756`, the hash of that name) carry `__type` inside the subobject (components, collision `shape`, hover `hover_effect`, graph `settings` and `data`). |
| References | A reference is the `__uuid` string of the target **object** (the root object of the target asset, or any sub-object), never its `__asset_uuid`. When the declared target type is not the concrete one, a sibling key `<field>__type` names it (`"Audio Asset__type": "tm_audio_file_asset"`, `resource__type: "tm_texture"`). |
| Key spelling | Property names are bare identifiers or quoted strings; quoted keys may contain spaces and capitals (`"Audio Resources"`, `"Audio Asset"`); bare keys may be capitalised (`Name`). |
| 64-bit values | Written as quoted lowercase hex. The migration index and buffer file names drop leading zeros; the type index pads `type_hash` to 16 digits. Readers accept both. |
| Hashes | `type_hash` = MurmurHash64A (seed 0) of the type **name** (418 of the 420 type references in the type index resolve to a listed name; the other two are `tm_anything` and the creation-graph `transform` name); graph connector hashes = the hash of the connector id; asset labels = the hash of the label name (`Image` → `e4bec38d8f73f423` on every texture) **[run]**. |
| Fixed node ids | The root node of an animation graph and of a behavior tree has `id` = hash of its node type name (`RootNodeDefinition`, `BTRootNodeDefinition`); other node, state and parameter ids are random 64-bit values. |
| Two identities | `__uuid` identifies an object and is what references and prototypes use; `__asset_uuid` (last key of the file) identifies the asset in this project's database. Both are 128-bit; the per-user state files (§6) store an asset uuid as two 64-bit halves `{a, b}`. |

#### 4.7.3 Prototypes and overrides in a scene

The library cube is not copied: the entity `box` in `world.tm_entity` is
an instance of the core library's box entity.

```
children: [
  {
    __uuid: <new>
    __prototype_type: "tm_entity"
    __prototype_uuid: <__uuid of the core box entity>
    name: "box"                         overridden field (prototype name is "")
    components: [ … ]                   components added to the instance (full objects)
    components__instantiated: [         overrides of the prototype's own components
      { __type: "tm_transform_component", __uuid: <new>,
        __prototype_type: "tm_transform_component", __prototype_uuid: <prototype's component>,
        local_position_double: { __uuid: <new>, __prototype_type: "tm_position_double",
                                 __prototype_uuid: <…>, x: …, y: …, z: … } … }
      { __type: "tm_model_component", …,
        materials__instantiated: [ { __uuid: <new>, __prototype_type: "tm_model_component_material",
                                     __prototype_uuid: <prototype's slot>, material: <material __uuid> } ] }
    ]
  }
]
child_sort_values: [ { child: <child __uuid> }, { child: <…>, value: 1 } ]
```

- The core box carries a parametric `tm_box_mesh_resource` (`width`,
  `height`, `depth` 1; also `corner_radius`, `split_faces`) and one
  material slot named `Material` bound to the core default material. A
  library cube therefore stays parametric (the USD migration bakes it to
  a mesh, §3.6).
- Core-library object `__uuid`s are identical in every project of this
  build (they matched across our migrated project and this one), while
  their `__asset_uuid`s are per project. A prototype link therefore
  resolves against the project's own `core.lib/` copy.
- An entity without a prototype (`point_light`) writes all of its
  components in `components`.

#### 4.7.4 Components, material and texture as stored

Components on the cube (`tm_re_*` names and fields, defaults from the
type index; the inspector names are in brackets):

| Component | Stored | Type fields and defaults |
|---|---|---|
| Collision | `shapes: [{ offset, orientation, shape: tm_re_collision_shape_box {width 1, height 1, depth 1}, id: 1, name: "Shape 1" }]`, `mode: 1`, `filter: {}` | `mode` default 2; filter `group` 1, `mask` 4294967295; box default 0.5 per side; `orientation` default `w: 1` |
| Input Target | empty | `input_type` (0, the first of the names `all`, `direct`, `indirect` **[str]**), `is_enabled` true |
| Spatial Audio | empty | `gain`, `direct_level`, `reverb_level`, `focus` 0; `rolloff_factor` 1 |
| Audio Library | `"Audio Resources": [{ Name: "<sound>", "Audio Asset": <audio __uuid>, "Audio Asset__type": "tm_audio_file_asset" }]` | entries are `tm_named_audio_reference`; the key is the asset name **without** extension |
| Particle Emitter | only subobject bodies (every value at its default) | see `particles-audio.md` §1.4 |
| Hover Effect | `hover_effect: { __type: "tm_re_hover_effect_highlight_style", color: {} }` | `hover_effect_type` 0; styles `tm_re_hover_effect_highlight_style` (`color` default white, `strength` 1) and `tm_re_hover_effect_shader_style` (`custom_fade_duration`, `fade_in_duration`, `fade_out_duration`); type names `Highlight`, `Shader` **[str]** |
| Grounding Shadow | empty | `casts_shadow`, `receives_shadow` false; `fade_behavior_near_physical_objects` 0 (names `Constant`, `Fade` **[str]**) |

Collision `mode` values: **0 = default, 1 = trigger, 2 = colliding** —
1 written by the editor's Trigger choice and loaded as
`CollisionComponent.Mode.trigger` from the exported `.reality` **[run]**;
0 written by the migration for USD `Default` (§3.6) **[run]**; 2 is the
type default of a new component; the order of the three names in the
physics plug-in's string table matches **[str]**. The point light:
`tm_re_point_light_component` (`color` ACES2065-1 default white,
`intensity` default 100000, `attenuation` 10,
`attenuation_falloff_exponent` 1, `mr_lighting`, light layers,
`light_mobility`).

Material (`tm_material`): `shader: {}` (empty: a graph material, unlike
the migration's `engine:pbr.rematerialdefinition`), `shader_graph.graph`
with three nodes — `tm_output_node`, `ND_image_color3` (MaterialX image
node) and `ND_UsdPreviewSurface_surfaceshader` (`width` 265) — two
connections (`out` → `diffuseColor`, `out` → `output__surface__0`), one
`data` entry on the image node's `file` connector holding a
`tm_material_resource` that references the texture, and the standard
interface outputs `surface`/`vertex` (`materials.md` §10). No promoted
parameter was made; the slot for one is `interface.inputs` (§10 there).

Texture (`tm_texture`): `source_filename` (here **relative**, `../<file>`,
i.e. relative to the project folder), `source_texture` (buffer: the
original file), `transform` = hash of the data-transform name (`Color`
→ the core library's `data_transforms/Color` asset), `transform_settings`
(a prototype instance of that transform's creation graph),
`color_space` (`color_primary` 1, `transfer_function` 2, `color_model` 1:
the default), `__asset_labels: ["<hash of Image>"]`. The processed
`texture` buffer is not saved.

#### 4.7.5 Imported audio

`tm_audio_file_asset`: `source_filename` (here an **absolute** machine
path — the same project stores the texture's path relatively; Ycode
must accept both and write neither), `source_audio` (buffer: the
original file, byte-identical), `sample_data` (buffer: the decoded
samples as little-endian 32-bit float, interleaved; 44 100 frames of
mono = 176 400 bytes, values = 16-bit sample / 32768), `sample_rate`
(double), `num_channels`. Other fields with defaults: `sample_format`,
`interleaved`, `should_loop`, `should_randomize_start`, `should_stream`,
`calibration_level_absolute` (80), `calibration_level_relative`,
`calibration_mode`, `normalization_mode`, `mix_group` (reference),
`channel_layout_tag`.

#### 4.7.6 Buffers and the core library

- Buffer file name: `<buffer uuid>.<MurmurHash64A (seed 0) of the file
  bytes, hex, no leading zeros>[.<original file name>]` — the hash was
  recomputed and matched for every buffer of the sample and for core
  icons **[run]**. Imported source files keep their name as a suffix;
  derived data has none.
- `core.lib/` is the same in every project apart from per-project
  `__asset_uuid`s, thumbnail validity hashes and one regenerated icon
  buffer; Ycode's importer can treat it as a known library keyed by
  object `__uuid`.
- The type index of a new project and of a migrated one hold the same
  916 type names but are not byte-identical (a few defaults differ,
  e.g. randomly generated ids inside defaults): readers must take
  defaults from the project's own index.

#### 4.7.7 Animation Graph and Behavior Tree assets

Both are graphs of the engine's generic `tm_graph` form (`nodes`,
`connections`, `data`, `comments`, `interface`, `grid_size` default 30,
`variables`, `node_groups`); each node is
`{ type: "<Definition type name>", position {x, y}, settings: { __type: <same name>, … } }`.

Animation Graph (`tm_re_animation_graph`):

| Field | Content |
|---|---|
| `animation_graph` | the node graph. A new asset holds one `RootNodeDefinition` node (`id` fixed, `childID` pose link). The owner's asset also has a `StateMachineNodeDefinition` node connected to the root: connection `out` → `childID` (connector hashes of those names) |
| `animation_graph_parameters` | `parameters`: typed `AnimParameterDefinition`s (`name` default "Unnamed", `id`, `readonly`, `implicit_index`); value types `Bool`, `Float` (`startingValue`), `Int`, `Option`, `Rotation`, `Vector`, `Trigger` `…ParameterDefinition` |
| `animation_graph_tags` | `tags`: `AnimTagDefinition` (`name` default "Unnamed Tag", `id`) |
| `preview_entity`, `skeleton_definition_ref`, `blendshape_weight_count` | preview and rig references (unset in the sample) |

State machine node settings: `name`, `id`, `states`, `conduits`. A state
(`StateDefinition`): `id`, `child_node` (a pose id: the state's content
graph, empty in the sample), `name` (new: "New State"), `position`,
`start_state`, `end_state`, `passthrough`, `transitions`, `tags`,
`implicit_index` (1 for the first state). A transition
(`StateTransitionDefinition`): `id`, `target` (state id), `sort_order`,
`reset`, `blend_duration`, `blend_curve` (`control_point1/2`),
`conditions`. Conduits (`ConduitDefinition`) have `id`, `position`,
`start_state` and conduit transitions. Node types available:
`RootNodeDefinition`, `StateMachineNodeDefinition`,
`AnimationClipNodeDefinition` (`resource` {`resource_type` default 4,
`asset_reference`}, `speed` 1), `Blend1D`, `Additive`, `Subtract`,
`BlendMask`, `BindPose`, `SpeedScale`, `RootMotionGeneration`,
`FootPlacement`, `FullBodyIK`, `MotionWarping` (`…NodeDefinition`).
State links are stored as ids inside node settings; the graph-level
`connections` carry only node-to-node pose links. A root node's
`childID` stays empty in the saved file even though a connection exists:
the graph connection is the source of truth.

Behavior Tree (`tm_re_behavior_tree`):

| Field | Content |
|---|---|
| `behavior_tree` | the node graph; a new asset holds one `BTRootNodeDefinition` (`id` fixed, `modifiers` {`preConditions`, `loopModifier` {`loopType`, `loopCount`, `loopCountParamID`, `loopCondition`}, `returnType`}, `childID` {`name`, `id`}) |
| `definition` | `BehaviorTreeDefinition`: `nodes` (references), `parameters` (`Bool`, `Float`, `Int`, `Option`, `Rotation`, `String`, `Vector2/3/4` `…BehaviorParameterDefinition`, each `name`, `id`, `readonly`, `startingValue`) — empty in the sample |

Behavior node types: `BTRoot`, `BTSequence` (`childrenIDs`,
`randomizeChildren`), `BTSelector`, `BTRandomSelector`, `BTParallel`,
`BTWait` (`waitTime`, `waitTimeParamID`, `randomDeviation`), `BTMoveTo`,
`BTMoveOnNavMesh`, `BTRotateToFace`, `BTParamSetter`, `BTSetTree`,
`BTAction`, `BTNoOp`, `BTDebug`, `BTGeneric` (`…NodeDefinition`); every
node has `name`, `id`, `modifiers`.

Attaching them to entities: `tm_re_animation_graph_component`
(`animation_graph` → the asset) and `tm_re_behavior_tree_component`
(`behavior_trees`: entries referencing tree assets, `active_tree` name).
Neither was attached in the sample; transitions, conditions, clips and
parameters with values were not observed (the assets were empty).

## 5. Recognising a project

| Test (in order) | Shape |
|---|---|
| `<dir>.realitycomposerpro/project.rcp` exists | C |
| `<dir>.realitycomposerpro/ProjectData/main.json` exists | B |
| a `Package.swift` whose sources contain `*.rkassets` | B without bookkeeping (valid; Xcode builds it) |
| `.usda`/`.usdz` files in an app target | A |

## 6. Content versus user state

| Path | Kind | Ycode |
|---|---|---|
| `.rkassets/**` | content (build input) | read/write |
| `Package.swift`, `Sources/**/*.swift` | content | read/write (via the IDE) |
| `Package.realitycomposerpro/ProjectData/main.json` | project content (ids) | write on change, never required on read |
| `Package.realitycomposerpro/WorkspaceData/**` | per-user editor state | preserve, do not write; suggest `.gitignore` for `*.rcuserdata` |
| RCP 3 `*.tm_*`, `*.tm_buffers/**`, `__*.tm_meta` | content | read later (§4.6), never write |
| RCP 3 window layouts, recent files, settings | per-user, outside the project, in the app's sandbox container: `Library/Application Support/Reality Composer Pro/settings.json` (keys `window_layouts`, `recent_files` with absolute paths and time stamps, `last_opened_project`, `docking_settings`, `settings_owner`, workspace templates) and `Project Settings/<decimal MurmurHash64A of the project's absolute path>.json` (last opened scene as an asset uuid `{a, b}`, scene settings, window layouts): JSON forms of the same object model (`__type`, `__uuid`) **[run]** | n/a |
| Ycode's own editor state | per-user | `<Package>.ycomposer/` next to the package, git-ignored by default (Ycode-original) |

## Open questions

- Q1. Exact keys of `ProjectData/main.json` and the `WorkspaceData`
  files of RCP 1/2. Needs an RCP 2-made project (owner: any old project
  of their own) — only key names would be recorded.
- Q2. **Answered** (§3.6): the migration writes a directory project
  inside the legacy package folder, one `.import` asset folder per USD
  layer, and leaves the legacy files untouched. The collision `mode`
  values are settled (§4.7.4). Still open: whether a later *Save*
  changes the migrated files (the migration was observed only before
  the first save).
- Q3. **Answered** (§4.7): a project made in the app, with the
  per-asset files, defaults rule, references, prototype overrides,
  buffer naming, imported texture and audio, and empty animation-graph
  and behavior-tree assets. Collision `mode` values settled (§4.7.4).
  Still open: an imported mesh (USD/glTF) in an app-made project, and
  filled animation graphs and behavior trees.
- Q4. Answered: *File ▸ Save Project As Asset Database…* exists beside *Save Project As…* (`editor-behavior.md` §15a); the database file's layout is still unobserved.
- Q5. Whether RCP 3 writes anything into the linked Xcode project besides
  `.reality` files (pbxproj edits are described in `editor-behavior.md`
  §12).
- Q6. Whether shape A's `Resources/Materials` folder keeps its structure
  in the built bundle (one `xcodebuild` of a template-shaped project).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Shape A layout and loading call | 2 | format study of Xcode 27.1 visionOS template **[tmpl]** |
| No build rule for USD/`.reality` resources; `.rkassets` rule and tasks | 1 | swift-build open source (`RealityAssets.xcspec`, `RealityAssetsTaskProducer.swift`), SwiftPM PIF builder **[oss]** |
| Legacy layout, `.rkassets` path rule, `main.json` marker, migration message | 4 | names in RCP 3's legacy importer library **[str]** |
| `main.json` / `WorkspaceData` key names | — | unverified (public sample projects, not re-checked) |
| Our package builds and compiles | 3 | `compile.md` §3.3 **[run]** |
| RCP 3 UTIs, extensions, document types | 2 | RCP 3 `Info.plist` |
| RCP 3 directory layout, grammar, reserved keys, buffers, type index, `tm_re_*` names | 2 | format study of the engine data shipped inside RCP 3 **[tmpl]**, parsed with our own parser |
| `project.rcp` marker, `.rcp` database form, headless export options | 4 | strings of RCP 3 libraries **[str]** |
| Headless runs (version, USD parse, no completed load) | 3 | **[run]** with an isolated home folder |
| `rcpmerge` behaviour and `.gitattributes` | 3 | `rcpmerge --help` **[run]** |
| RCP app template (exported `.reality`, plug-in packages, MIT interface) | 2, 1 | template format study; MIT licence in the package **[oss]** |
| Hash function | 3 | recomputed by us (`materials.md` §10) |
| Migration output layout, per-item mapping, in-place write, legacy files unchanged | 2, 3 | owner-accepted migration of our own sample in RCP 3.0, output read as a file format with our parser and checksums (OBS-RCP2) **[run]** |
| Default collision `mode: 2` | 2 | type index written into the migrated project |
| App-made project layout, defaults rule, reference and `<field>__type` form, prototype overrides, components, material, texture, audio, animation-graph and behavior-tree storage (§4.7) | 2 | owner-made sample read with our parser, defaults from its own type index (OBS-RCP4) **[run]** |
| `type_hash` = hash of the type name; buffer hash = hash of the bytes; label and fixed root-node ids = hash of the name | 2, 3 | recomputed with the public MurmurHash64A over every value in the sample **[run]**; two preimages (`sg_surface_shader`, `transform`) found among library name strings **[str]** |
| Collision mode 1 = trigger | 3 | `.reality` exported headless from the sample, loaded by our macOS probe **[run]** |
| Mode names default/trigger/colliding, input-type, hover-type and shadow-fade names | 4 | string tables of the physics and components plug-ins **[str]** |
| Core-library object uuids fixed across projects | 2 | comparison of two projects' `core.lib/` (migrated and app-made) |
| Per-user settings files and their naming | 3 | files the headless runs created in the app's container; name recomputed as the hash of the project path **[run]** |
