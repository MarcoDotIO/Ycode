# Reality Composer Pro observations

## Editor (fork)

2026-10-29, OBS-RCP editor fork. No app runs or clicks were made for this section. Sources: Apple's Reality Composer Pro 3 documentation, which is published as markdown under developer.apple.com/documentation/realitycomposerpro (raw copies are in the git-ignored dirty folder for reference); WWDC26 sessions 252, 280, 281 and 393 and WWDC23 session 10083; and names from `strings` of the editor plug-in libraries.

- Reality Composer Pro 3 is a different product from RCP 1/2. It runs on a plug-in engine: about a hundred `libtm-*` plug-ins with editor commands, docked tabs and workspaces, and a command palette. Its documentation says plainly that it is no longer a USD editor. USD is only an import and export format, and the app consumes exported `.reality` files. Most pre-2026 tutorials (USD hierarchy, bottom editor tabs, Content Library, global Audio Mixer) describe RCP 2 only.
- Every action is a registered command with a menu path, shortcut label and description. The shortcut labels are stored next to the command identifiers in the binaries, so the key map in `editor-behavior.md` §3–§5 is level 4. Only F (frame), Q/W/E/R (tools), N or Space (add node), C (comment), Space/⇧Space (add component or asset) and ⌥-drag are confirmed by the docs.
- Import extensions come from the importer plug-ins: the bundled USD library's file formats (usd/usda/usdc/usdz, gltf/glb, obj, ply, stl, abc), image loaders (stb set, exr, dds, ktx, tif) and audio (wav, aiff, caf, m4a, aac, mp3, flac).
- The exporter plug-in has a hidden headless command line (`--reality-export-*`, `--usd-run-pipeline`). Its version choices are macOS/iOS/visionOS triples for older files (15.0/18.0/2.0 …) and single numbers from 26.0. It has not been run. A headless export of our own sample would give the compile round a second `.reality` writer to diff against `realitytool`.
- Xcode integration goes through a privileged helper (launch agent, XPC). It drives `xcodebuild -createNewProject` with a hidden app template, `devicectl` and `simctl`, and edits `project.pbxproj` text directly to add exported `.reality` resources and plug-in package products. The link is stored as a file path.
- The plug-in interface is MIT-licensed and public, so Ycode can host the same plug-ins. Root-entity names such as "RCP - Viewport" are an interop contract that plug-in systems check.
- The built-in help (`Resources/Help/Assist/*.docs`) consists of encrypted ZIP archives (general-purpose flag bit 0 set). They feed the in-app assistant. They were not opened and must not be.
- The app has localization strings (Swedish pairs appear beside English titles in the binaries). This does not matter for the spec.
- What still needs the GUI is listed in `editor-behavior.md` §16, including the AX reads that the parent could do in the background.

## Materials (fork)

Dirty-room notes for `specs/tools/scene-composer/materials.md`, 2026-10-29.

- Node interfaces were parsed (names, ports, types, defaults only) from the
  MaterialX data files in Reality Composer Pro 3.0's ShaderGraph framework and
  in Xcode 27.1's USD library. Raw dumps stay in `research/dirty/rcp/materials/`.
  Xcode's `libraries/realitykit` folder carries an Apple MIT licence file, and
  Apple publishes most of the same node definitions under MIT in the public
  repository `apple/plugins-for-godot`; 156 of the 170 public RealityKit
  nodedefs are there.
- The two Apple libraries differ: RCP 3.0 names its extended PBR shader
  `ND_realitykit_pbr_surfaceshader_v2` and its post-lighting shader
  `ND_realitykit_postlightingshader`; Xcode 27.1 and the macOS 27 runtime use
  `ND_realitykit_pbr_surfaceshader_2_0` and
  `ND_realitykit_post_lighting_surfaceshader`. The runtime treated `_v2` as
  unknown.
- Probe runs on our own USDA (`<samples>/materials/Mats.rkassets`, four
  scenes): every Material-level `inputs:*` becomes a ShaderGraphMaterial
  parameter, used or not; strings and unconnected assets are listed without a
  value; `half` reads back as float; `matrix4d` as float4x4. Colour-space
  metadata `srgb_texture` and the OCIO name `Input - Texture - sRGB - sRGB`
  both linearise; `lin_displayp3` keeps a P3 linear colour.
- Unknown node ids, `_v2`, and the post-lighting shader on the surface
  terminal all gave the same silent fallback (PhysicallyBasedMaterial, 0.18
  grey, name kept). `realitytool compile` printed nothing and exited 0, even
  with a missing texture file. In the compiled asset map those materials had
  no shader-graph dependency; a material with a geometry modifier depended on
  two shader graphs.
- The compiled `assetMap.json` stores each texture's absolute source path
  (`cdm:resolvedpath`) and a debug name with that path: compiled `.reality`
  files leak the build machine's paths (relevant to compile.md determinism).
- Plain `UsdPreviewSurface` → PhysicallyBasedMaterial; the MaterialX
  `ND_UsdPreviewSurface_surfaceshader` → ShaderGraphMaterial. After compile,
  the plain form's base-colour texture was not visible through the public API.
- Texture asset paths resolve relative to the layer that authors them (tested
  with a referenced material library one folder down).
- RCP 3.0's own material assets (`tm_material`) store MaterialX nodedef names
  as node `type` strings and link nodes by connector hashes that equal
  MurmurHash64A (seed 0) of the connector id (`out`, `output__surface__0`).

## Timelines, behaviors, particles, audio (fork)

Method. All observations come from hand-written USDA in `<samples>/timelines/`
and `<samples>/particles-audio/` (plus generated WAV/PNG files), loaded with
RealityKit on macOS 27 through a small dump probe (entities, components,
animation-library definitions down to the `ActionAnimation` payloads, and the
scene's interaction service after attaching the entity to a renderer scene),
and compiled with `realitytool compile --platform xros --deployment-target
27.0`. The compiled `.reality` files always loaded to the same values as the
direct USDA load, so the compile step adds nothing semantic for these
features. Candidate names came from name strings in the runtime libraries;
every name in the specs that is not marked level 4 was confirmed by a load.

Timelines. A `RealityKitTimeline` prim is not an entity. It becomes two
entries in the default prim's animation library, keyed by the prim path and
by the path plus `__auto_generated_looping`. Each action becomes a delayed
view around an action animation. Kind names are short strings (`spin`,
`orbit`, `emphasize`, `moveTo`, `show`, `hide`, `enable`, `disable`,
`impulse`, `lookAt`, `audio`, `notification`, `animation`, `timeline`); 13
other plausible spellings were silently dropped. Clockwise spin is expressed
by negating the axis. Instant actions are stretched to one 1/30 s frame. The
default easing is the CSS "ease" Bézier.

Behaviors. `Preliminary_Behavior` prims inside the owning entity load into the
legacy Reality Composer interaction service (tap, start, collision and custom
triggers; play-timeline actions). The `RCP_BehaviorsContainer` component has
no runtime effect: removing it changed nothing. The notification trigger's
`identifier` reached the custom trigger unchanged.

Particles. The `VFXEmitter` component uses the C++-style field names
(`particleSize`, `particleLifeSpan`, `opacityOverLife`,
`radialGravityStrength`) and capitalised enum tokens, which differ from the
Swift property names. One USD flag, `isLocal`, sets two Swift properties.
`birthDirection = World` did not take effect: unresolved.

Audio. Audio files are `RealityKitAudioFile` prims referenced from an
`AudioLibrary` dictionary. Groups are parent prims with file children. The
mix-group relationship surfaces as the mix group's prim name. Calibration
uses `absoluteCalibration`/`relativeCalibration`. Reverb presets are
capitalised preset names, and an unknown name falls back to anechoic. A
UsdMedia `SpatialAudio` prim does not produce audio components.

Not reproduced. The USD form of an `AnimationLibrary` component with
`RealityKitAnimationFile` children did not load in four encodings tried with
transform-only and skinned animation files. This needs an RCP-written sample.
RCP 3 stores timelines as "sequences" (editor command names). RealityKit 27's
behavior-tree and animation-graph schemas ship as JSON type schemas. Only
their key structure was recorded.

## Compile and build (fork)

Black-box work on `realitytool` (Xcode 27.1) with our own samples under
`<samples>/compile/`; spec in `specs/tools/scene-composer/compile.md`.

- The first `realitytool` run of a session took about a minute; later
  runs 1–4 s. Every run prints an `[macosx] info:` echo line first.
- `compile` is forgiving to the point of hiding errors: a USD syntax error
  drops the scene with exit 0 and no message; unknown component ids and
  unknown fields are ignored; a wrongly typed field becomes zero.
- Deployment-target floors: iOS 18, macOS 15, tvOS 26, visionOS 1.0.
  `minVersion` in `header.json` follows the target (10, 12, 15, 18), and
  payloads change at visionOS 27. From target 26 most assets use the
  chunked method 32867 (`CHNK` frames of raw and LZFSE chunks).
- Two compiles of the same input differ only in `assetMap.json` (random
  GUIDs); texture assets record the absolute source path.
- The `.reality` container is now fully described at writer level:
  ZIP64 extras on local headers, SHA-256 of the uncompressed data in a
  `0xfffe` extra, a `.align/` entry padding the central directory to a
  4096 boundary, and a 42-byte `RAD` EOCD comment carrying a SHA-256 over
  (name + entry hash) pairs. Method 99 is plain LZFSE, not AES; the
  open-source `lzfse` encoder reproduced `realitytool`'s output byte for
  byte. The macOS loader accepted re-packed files with every integrity
  feature removed or wrong.
- Payloads start with `CA01` and are RealityKit's own object
  serialisation; not studied further (would need level 4–5, not needed).
- `--schema-file` works by copying the `.rkassets` tree and prepending a
  USD reference from each `RealityKitCustomComponent` prim to
  `</Components/<prim name>>` in the schema file; the match is by prim
  name, so custom-component prims must be named `<Module>_<Type>`.
  Schema defaults end up baked into the compiled scene.
- `create-schema` reads Swift source text line by line; defaults on
  single-line declarations are lost or garbled. Matrices, `Entity`,
  dictionaries, `URL`, `Date`, `UUID`, `Transform`, `CGColor`,
  `Character`, `Float16` are rejected; arrays and integer SIMD vectors
  only warn.
- One `xcodebuild` (macOS destination) of our own content package and
  executable confirmed swift-build's open-source task plan:
  `RealityAssetsSchemaGen` then `RealityAssetsCompile` in the package's
  resource target, output `<Package>_<Target>.bundle/.../<Name>.reality`.
  `Entity(named:in:)` matched `Scene`, `Scene.usda`, folder-qualified
  names and bare base names.
- `image` writes KTX 1.1 files with a `KTXmetalPixelFormat` key and full
  mips; `.realityenv` is the same container as `.reality` with an
  `ImageBasedLight` asset and three cube textures. A `.skybox` folder with
  one `.hdr` compiled to `<out dir>/<Name>.realityenv`. Xcode 27.1 does
  not define the `file.skybox` type its skybox rule expects.

## Projects, scenes, reference app runs (parent)

- The installed reference is Reality Composer Pro 3.0, a new product on a
  component-based game-engine core (about a hundred engine plug-in
  libraries, a self-describing type index of 925 types, a directory
  project of one text file per asset plus binary buffer folders). It
  migrates RCP 1/2 projects one way and no longer keeps scenes as USD.
  Xcode 27.1's own visionOS template no longer creates a
  RealityKitContent package either: it puts `.usda` scenes straight into
  the app's resources. The legacy `.rkassets` path is still fully
  supported by Xcode's build (open-source swift-build tasks) and is the
  only USD-native route into an Xcode build, so it is the format Ycode
  should write.
- RealityKit component prims are decoded generically from the engine's
  type registry: `info:id` names the kind, attribute names are the
  registry's field names (some with C++-style `m_` prefixes, e.g. motion
  velocities, the character controller's `m_controllerDesc` struct, the
  rigid body's `massFrame.m_mass`). A few kinds (collider, rigid body,
  lights, anchoring, IBL receiver) have dedicated builders with their own
  names. Wrong names are ignored silently, so every name in the catalogue
  was tested by loading our own USDA with RealityKit on macOS and, for a
  subset, after `realitytool compile`.
- Oddities: the character controller's `extents.x` is the height and
  `extents.y` the radius; `RealityKit.WorldRoot` (not `World`) creates a
  world component; the opacity component is `HierarchicalFade`; an empty
  character-controller prim gives height and radius 0, not the API's
  defaults. Trigger colliders, the portal target, hover effect, shadow
  components and the IBL source were not settled.
- Headless runs of the reference (isolated home folder, no window):
  `--version` works; `--usd-run-pipeline` parsed our USD (it printed USD
  statistics) but could not find the imported asset without a project;
  loading an empty directory with only a `project.rcp` marker never
  finished loading, so no RCP 3 project could be produced without the
  GUI. On macOS 27.2 the reference logged that one engine plug-in
  (compute graphs) failed to load because of a missing symbol in the
  system framework: the 3.0 build targets an older OS.
- A background `open -g` of our hand-made legacy package showed a
  migration window named after the package, so `ProjectData/main.json`
  plus the `.rkassets` folder is enough to be recognised. The native menu
  bar was readable through accessibility; the engine-drawn windows were
  not. The instance was stopped with a terminate signal; it wrote nothing
  into the sample.
- The RCP app template ships a compiled `Scene.reality` and an
  MIT-licensed plug-in interface package; the shipped engine data
  contains an absolute path from the authoring machine, a reminder that
  Ycode must never write absolute paths into projects.

## Migration result and GUI session (OBS-RCP2)

2026-10-29. The owner accepted the migration of `<samples>/legacy/ObsContent`
by hand. The orchestrator had looked for a new `project.rcp` before the
files appeared; they were there when this round started.

- RCP 3.0 migrates **in place and without a save dialog**: it writes
  `ObsContent/ObsContent.realitycomposerpro/` inside the legacy package
  folder. Checksums and modification times show that `Package.swift`,
  `main.json` and both `.usda` layers were not touched. The editor window
  still showed the project as "Edited" afterwards, but everything was
  already on disk. A copy of the migrated folder as found was taken to
  `<samples>/migrated/ObsContent-as-migrated/` before anything else.
- Each source USD layer becomes its own `<Name>.import/` asset folder,
  even a layer that is only referenced (the material library). Each one
  holds a `tm_usd_asset` settings file (with the absolute source path), a
  full entity, an "optimized" entity and a proxy entity that inherits from
  the optimized one, plus geometry, mesh and material assets and two
  binary blobs (an import session with magic `TMTS`, and the
  scene-optimizer output).
- The optimizer drops the empty entity that came from the referencing
  prim. The `Cube` primitive is baked to a 24-vertex mesh. The
  `UsdPreviewSurface` shader becomes the MaterialX
  `ND_UsdPreviewSurface_surfaceshader` node in a graph on the engine's PBR
  material definition, and the diffuse colour is converted to ACES2065-1.
  The roughness entry has no stored value.
- The collider keeps its box shape and size. Its `mode` is written as 0,
  while a fresh component's default in the type index is 2. The shape
  orientation is a zero quaternion (`w: 0`), which looks like an importer
  quirk rather than an intended rotation.
- The new project carries its own copy of the engine core library
  (`core.lib/`, about 55 MB, mostly an image buffer of the PBR creation
  graph and the IBL textures) and a type index of 916 types (the shipped
  engine data had 925).

GUI session. Access to Reality Composer Pro was granted. Its UI is drawn
by the engine, so background clicks were refused ("canvas/custom view
with no accessibility action"). The first full-screen action was
interrupted by the owner, and this round stopped its GUI work there,
as its brief requires. The sample project (task 2), the exports and
everything that depends on them were not done. RCP was left running as
found, with the migrated project open and unsaved.

## The owner's app-made sample (OBS-RCP4)

2026-10-29. The owner built the sample by hand in Reality Composer Pro
3.0 and saved it in `<samples>/sample3-src/`: the project, a USDA
export folder, and the two generated inputs (a 256×256 checker PNG and
a 1 s 440 Hz WAV). No `.reality` had been exported. This round had no
screen control and did no GUI work; RCP was not running when the
headless runs started. Raw dumps, logs and our scripts are in
`research/dirty/rcp/obs-rcp4/`.

Project as a file format.
- Our own parser read every file. The scene is one `world` entity with a
  `box` child and a `point_light` child. The box is a prototype instance
  of the core library's box entity: it keeps the parametric box mesh,
  overrides the transform and the material slot through
  `…__instantiated` arrays, and carries its added components in a plain
  `components` array. The core library's object uuids are the same in
  every project; only the asset uuids change.
- Fields equal to their type's default are left out. The type index
  carries the defaults, so a reader that assumes zero gets wrong values
  (the point light would lose its 100000 intensity). The light's colour
  shows the rule well: `g` and `b` are written because the light's
  initial colour differs from the colour type's default in the last bit.
- Every 64-bit hash we met is MurmurHash64A with seed 0: of a type name
  (`type_hash`, including the material outputs `sg_surface_shader` and
  `sg_geometry_modifier`, which answers the old question about those
  values), of a connector id, of a label name (`Image` on textures), of a
  data-transform name (`Color` in a texture's `transform`), of the root
  node type name (the fixed id of a graph's root node), of a buffer's
  bytes (the second part of a buffer file name), and of the project's
  absolute path (the per-user settings file name, in decimal).
- Collision `mode` is 0 default, 1 trigger, 2 colliding: the owner's
  Trigger choice wrote 1, the migration of a USD `Default` wrote 0, a new
  component defaults to 2, and the three names sit in that order in the
  physics plug-in's string table.
- The emitter is stored with Swift-style field names, flat (no
  `currentState`), `secondaryEmitter` instead of `spawnedEmitter`, integer
  enums, and ACES2065-1 colours. The stored defaults convert exactly to
  the runtime's linear-sRGB defaults, except that the exported file
  loaded a different end colour B. RCP's defaults also differ from the
  API's: Y-aligned billboards, and a 3×3 image sequence at 9 fps.
- Imported files are copied byte-for-byte into the asset's buffer folder;
  audio is also decoded to 32-bit float samples. The texture's source
  path was stored relative to the project folder; the audio's as an
  absolute machine path.
- The material is a graph: an `ND_image_color3` node feeding
  `diffuseColor` of an `ND_UsdPreviewSurface_surfaceshader` node. The
  texture reaches the image node as a graph data entry, not a
  connection. Nothing was promoted.
- The Animation Graph and Behavior Tree assets are generic engine graphs
  whose nodes carry typed `settings`. The animation graph's root node
  links to a state machine through a graph connection, while the root's
  own `childID` field stays empty. The state machine holds one state
  ("New State", start state). The behavior tree holds only its root
  with a loop modifier. Node, state, transition, parameter and tag
  types (names and fields) come from the type index. Per the owner,
  RCP 3 authors animation this way, not with timelines.

USDA export. The *USDA (Mesh)* export of the scene is geometry only: a
matrix transform per entity, the box as a 24-vertex triangle mesh under
`Model<id>/Part<id>` prims with an `st1` UV set, a flat
`UsdPreviewSurface` material with black diffuse and opacity 0, an empty
textures folder, an empty Xform for the light, and no component prims at
all. It confirms none of the component names in `scene-usd.md`. It does
show what Ycode's USD importer must accept: bindings without
`MaterialBindingAPI`, matrix transforms, and `st1`.

Headless `.reality` export. On a copy, `--headless --load-project <copy>
--reality-export-asset world --reality-export-output <file>
--reality-export-version <v>` works in about 5 s. The first attempt
failed because the sandboxed app may write only into the loaded project's
folder, so the file was written there and moved out afterwards. Setting
`HOME` does not isolate a sandboxed app. The runs added the copy to the
real container's recent files and last-opened project, and created a
per-project settings file. Afterwards the two `settings.json` entries
were restored to their previous values, the settings file was moved into
the dirty folder, and the empty temporary zip folders were removed. The
per-run log files were left in the container's Logs folder.
- The exports at 27.0, 26.0 and `15.0/18.0/2.0` were identical apart from
  GUIDs, all with `minVersion` 12. Every asset is plain LZFSE (method 99),
  except the audio, which is stored. GUIDs use the string form; the mesh's
  GUID is `INVALID`. There is no path metadata. The container passed
  every integrity check.
- `--reality-export-all` found a Reality Export Settings asset that we
  wrote by hand, but exported to "null". The same asset, run by name with
  `--reality-export-output`, exported normally.
- Our macOS probe loaded the file as expected: trigger collision, input
  target, spatial audio, audio library keyed by the asset name, the
  emitter, a highlight hover effect, a grounding shadow (cast off), the
  point light (100000, radius 10, exponent 1), and a
  `ShaderGraphMaterial` named after the material. That material had one
  generated texture parameter, `rcp_<n>`, which was the same in all five
  exports.

Trigger in USD. Our USD loads, direct and compiled, gave
`collisionOptions = .static` for `type` or `interactionType` = `"Trigger"`
and never gave trigger mode. The collider builder's name list contains
`type`, `interactionType`, `Default` and `Trigger`. These loads also gave
`isStatic = false` for plain colliders, which corrects an earlier note.
