# RealityKit 7: assets — USD/USDZ interop, USDKit, export, `.reality` and Reality Composer Pro

Status: draft round 0. Sources: Pixar OpenUSD specification and toolset
(level 1, open source), Apple's USD documentation (level 1), our own USD
files loaded by our probe (levels 2–3, **[rv-usd]**), `realitytool`
help and our own compiled `.reality` file at container level (level 3,
level 2), SDK module metadata (level 4).

## 1. Loading API

| Call | Behaviour |
|---|---|
| `Entity(named:in:)` (18, async) | load a scene by name from a bundle (USD files, `.reality` files, Reality Composer Pro package scenes) |
| `Entity(contentsOf:withName:)` (18, async) | load a file URL |
| `Entity(from:named:contentType:)` (27) | load from in-memory data |
| `Entity(from:configurations:)` (18) | load a configuration (variant) set from an `Entity.ConfigurationCatalog` |
| `ModelEntity(contentsOf:)` / `loadModel` | **flatten** the file into one `ModelEntity` with one merged model and no children (**[rv-usd]**: children 0, bounds covering every mesh) |
| `Entity.load…` / `loadAnchor…` (13, synchronous; `…Async` deprecated) | older API; `loadAnchor` returns an `AnchorEntity` from an anchoring prim |
| `ReferenceComponent` (18) | lazy reference to an entity in another file |

Observed load times on the simulator (our tiny files): first load 1.35 s
(framework warm-up), later loads 0.05 s; a `.reality` file 0.66 s
**[rv-usd]**.

## 2. USD → entity mapping (observed **[rv-usd]**)

Our test files are hand-written `.usda` (in
`research/experiments/realitykit/RKProbe/assets/`) validated with
`usdchecker`.

1. The loaded entity is an **unnamed wrapper** for the stage; its child is
   the `defaultPrim` (`Root`). For `.reality` files the wrapper is named
   after the scene.
2. **Units and axes are converted on the wrapper**: `metersPerUnit = 0.01`
   gave the wrapper scale 0.01 (prims keep their authored values);
   `upAxis = "Z"` gave the wrapper the rotation −90° about X (quaternion
   (−0.7071, 0, 0, 0.7071)), turning +Z into +Y.
3. `Xform` (and other non-geometry prims, `Skeleton`) → `Entity` with
   `Transform` from the xform ops; `Mesh` and implicit geometry (`Sphere`
   tested; `Cube`, `Cylinder`, `Cone`, `Capsule` per Apple's table;
   `Plane` not supported) → `ModelEntity` with a `ModelComponent`;
   implicit shapes are tessellated (our sphere of radius 0.03 had bounds
   ±0.03).
4. Materials: `UsdPreviewSurface` → `PhysicallyBasedMaterial`
   (`diffuseColor` → base colour tint (0.8, 0.1, 0.1) as authored,
   metallic, roughness). A mesh without a binding got a
   `PhysicallyBasedMaterial` with tint 0.18 grey (the
   `UsdPreviewSurface` fallback colour). MaterialX networks
   (`outputs:mtlx:surface`) → `ShaderGraphMaterial`.
5. Skinning: a `SkelRoot` containing a `Skeleton` and a skinned `Mesh`
   → the `SkelRoot` entity is a `ModelEntity` carrying the skinned mesh,
   `SkeletalPosesComponent`, `MeshDeformerComponent` and
   `AnimationLibraryComponent`; the `Skeleton` and `Mesh` prims become
   empty child entities.
6. Animation: time-sampled xform ops and `SkelAnimation` become
   animations; every Xform entity carries an `AnimationLibraryComponent`;
   the root lists "global scene animation" and "default subtree
   animation" with duration (end − start) / timeCodesPerSecond.
7. Components present on every loaded entity: `Transform`,
   `SynchronizationComponent`; Xforms add `AnimationLibraryComponent`.
8. USD lights are ignored; USD cameras are ignored (Apple's feature
   table).

## 3. USD features RealityKit reads (Apple's table, paraphrased)

| Area | Supported | Not supported |
|---|---|---|
| General | instancing (mesh and texture data), transform animation, `.usdz`, `.usd`/`.usdc`/`.usda`, visibility, variants (active variant at load; switching after load depends on context), spatial audio, accessibility (through USDKit) | point instancing, deferred payload loading |
| Geometry | polygon meshes, primitive shapes except `Plane`, subdivision (only with `UsdPreviewSurface` materials), geometry subsets, Alembic (Ogawa), vertex colours, purpose | vertex (point-cache) animation, double-sided meshes, NURBS, basis curves, tetrahedral meshes, points, cameras, Draco |
| Lights | — | every USD light type |
| Physics | physics scene, rigid body, mass, collisions, physics materials | mesh collisions, collision groups, filtered pairs, joints, limits, drives, articulations (and none through USDKit) |
| Shading | material graphs, `UsdPreviewSurface`, MaterialX, textures, AVIF, wrap modes, colour spaces (`srgb_texture`, `lin_srgb`, `srgb_displayp3`, `lin_displayp3`; `sourceColorSpace` fallback; embedded profile otherwise) | specular workflow, bias, displacement |
| Shading (partial) | one packed texture per material (several scalar channels of it), one `UsdTransform2d` per material, two UV sets, texture scale except on normal maps | |
| Skeletons | skeletons, skeletal animation, blend shapes | |
| Volumes | — | OpenVDB volumes, Gaussian splats |

## 4. Schemas an implementation must read

Standard OpenUSD schemas (all in the open-source distribution):

- `UsdGeom`: `Xform` and `Xformable` ops (translate, rotate*, orient,
  scale, transform, `xformOpOrder`, `resetXformStack`), `Mesh`
  (`points`, `faceVertexCounts`, `faceVertexIndices`, `normals`,
  `primvars:st`/`st1`, `primvars:displayColor`, `subdivisionScheme`,
  `orientation`), `GeomSubset` (material binding family), `Sphere`,
  `Cube`, `Cylinder`, `Cone`, `Capsule`, `Imageable` visibility and
  purpose, stage metadata `metersPerUnit` and `upAxis`, `extent`.
- `UsdShade`: `Material`, `Shader`, `MaterialBindingAPI`
  (`material:binding`), node inputs/outputs and connections; shader ids
  `UsdPreviewSurface`, `UsdUVTexture`, `UsdPrimvarReader_float2`,
  `UsdTransform2d`; MaterialX `ND_*` node definitions and the
  `outputs:mtlx:surface` terminal; RealityKit `ND_realitykit_*` nodes.
- `UsdSkel`: `SkelRoot`, `Skeleton` (`joints`, `bindTransforms`,
  `restTransforms`), `SkelAnimation`, `SkelBindingAPI`
  (`primvars:skel:jointIndices`/`jointWeights`, `geomBindTransform`,
  `skel:skeleton`, `skel:animationSource`), `BlendShape`.
- `UsdPhysics`: `PhysicsScene`, `PhysicsRigidBodyAPI`, `PhysicsMassAPI`,
  `PhysicsCollisionAPI`, `PhysicsMaterialAPI`.
- `UsdMedia`: `SpatialAudio`.
- Composition: references, payloads, variants (`variantSets`),
  instancing (`instanceable`), `defaultPrim`, time codes.

Apple's preliminary AR schemas (an addendum to the USD specification,
documented on developer.apple.com): `Preliminary_AnchoringAPI` (anchor a
root prim to a plane, image or face; not object or location),
`Preliminary_ReferenceImage`, `Preliminary_Text`, `Preliminary_Behavior`
pairing `Preliminary_Trigger`s (`TapGestureTrigger`, `CollideTrigger`,
`ProximityToCameraTrigger`, `SceneTransitionTrigger`,
`NotificationTrigger`) with `Preliminary_Action`s (`AudioAction`,
`ChangeSceneAction`, `EmphasizeAction`, `GroupAction`, `ImpulseAction`,
`LookAtCameraAction`, `OrbitAction`, `SpinAction`,
`StartAnimationAction`, `TransformAction`, `TransformAnimationAction`,
`VisibilityAction`, `WaitAction`, `NotificationAction`), and metadata
`autoPlay`, `playbackMode`, `preferredIblVersion`, `sceneLibrary`. Reality
Composer Pro stores anchoring in its USDA files with these schemas. The
schema definition files themselves are a public download for DCC
tools; an implementation should take field names from them (round 6).

## 5. USDZ packaging

USDZ is an uncompressed ZIP archive whose first file is the root layer
and whose file data start on 64-byte boundaries (OpenUSD specification;
`usdzip` produces this). Apple allows JPEG, PNG, EXR and AVIF textures in
USDZ for its renderers. Our `usdzip`-made `cube.usdz` (one stored entry,
`cube.usda`) loaded with the same tree as the `.usda` **[rv-usd]**.

## 6. Export: `Entity.write(to:)` (iOS 18)

Observed **[rv-usd]**: writing a loaded entity to `…/export.usdz` and to
`…/export.usda` produced **two files of 113 809 bytes with the same entry list
(they differ in a few header bytes) and neither is USD**: both were the `.reality` container (§8) — a ZIP whose entries
are `assets/*.compiled…` files, `assetMap.json`, `header.json` and an
`.align/` directory. `usdcat`/`usdtree` refused them. So `write(to:)` is a
RealityKit-native serialisation, independent of the extension.
`Entity.WriteOptions` (26) adds `preferSmallTextureFiles(quality:)` and
`preferFastExport` (27). USD export proper is USDKit's
(`USDStage.ExportOptions`, §7).

## 7. USDKit (iOS 27) and the USD stage component

A new Swift API over USD: `USDStage` (open options, initial load rule,
edit target, time codes, notices `ObjectsDidChange`, observation tokens,
export options with texture quality), `USDLayer` (identifier, sublayers,
time codes, default prim, specs, fields, list operations, change lists),
`USDPrim` (attributes, relationships, references, payloads, inherits,
specializes, variant sets, specifiers, predicates), `USDPrim.Attribute`
(typed values, time samples), `USDValue` (scalars, vectors, matrices,
quaternions, half types, arrays, tokens, asset paths, path expressions),
`USDTransformOperation`. `_USDKit_RealityKit` adds `USDStageComponent`
(stage, time code, hit testing, automatic rendering, render-completion
wait) and `USDPlayer` (per-frame additions/updates/removals of meshes,
materials, textures and deformations). The API mirrors OpenUSD's
`Usd`/`Sdf` layers closely, so an open implementation can wrap OpenUSD
directly (round 6). Apple's documentation states USDKit does not load
physics data into RealityKit and that macOS 27 Preview/Quick Look render
through it.

## 8. `.reality` files and Reality Composer Pro (black boxes)

Public facts:

- A Reality Composer Pro project is a Swift package whose resources
  include a `.rkassets` folder of USDA scenes (USDA is its native scene
  format) and custom-component Swift files. Xcode compiles it with
  `realitytool` (in the Xcode toolchain) into a `.reality` file in the
  app bundle.
- `realitytool` subcommands (from its `--help`, level 3): `compile`
  (input `.rkassets` or `.skybox`; required platform —
  appletvos/appletvsimulator/iphoneos/iphonesimulator/macosx/xros/
  xrsimulator — and deployment target; optional schema file from
  `create-schema`, derived-data directory, Metal use, reduced texture
  sizes), `create-schema` (parses custom component Swift files into a
  `.usda` schema with initial values), `image` (pre-processes textures to
  `.realityenv` or `.ktx` with semantic, colour space, cube face size).
  It runs the compile in an agent that loads the target platform's own
  asset runtime, i.e. compilation uses Apple's RealityKit itself. (Paths
  starting with `-` must follow `--` on its command line.)
- Container observations on files we produced from our own USD (level 2):
  a ZIP archive; `header.json` with keys `versionInfo`, `minVersion`
  (18 for our file), `metadata`, `targetPlatform`
  (`RealityFilePlatformAll`), `restrictedSeedVersion`; `assetMap.json`
  with `scenes`, `assets`, configuration-set keys; and per-asset entries
  `assets/<Kind>_<n>.compiled<kind>` (scene, mesh, material, animation
  library, animation scene, timeline) stored with ZIP method 99 and
  LZFSE-framed payloads. The payload format is **not public and is not
  specified here**.
- Loading: a `.reality` file compiled from our `cube.usda` loaded with
  `Entity(contentsOf:)` into the same hierarchy, components, materials
  and animations as the USD source.

Policy for Ycode:

1. The **simulator** never needs to read `.reality`: the guest app runs
   Apple's own RealityKit from the runtime image.
2. The **open RealityKit** reads USD only. Apps that ship `.reality`
   files are out of scope until a public specification exists; the Ycode
   IDE can keep Reality Composer Pro packages as USDA (their source form)
   and, on Linux, load the USDA scenes directly instead of compiling them.
3. `Entity.write(to:)` in the open implementation writes **USD** (USDA or
   USDZ by extension). This is a deliberate, documented difference.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Loading API names | 4 | SDK `.swiftinterface` |
| Mapping rules §2, flattening, load times | 3 | **[rv-usd]** with our files |
| Feature table §3, colour-space names, USDKit physics note | 1 | developer.apple.com "Validating feature support for USD files", "Creating USD files for Apple devices" |
| Standard schema names §4 | 1 | OpenUSD (open source, Pixar; licence in `09-open-design.md`) |
| Preliminary AR schemas | 1 | developer.apple.com "OpenUSD schemas for AR", "Actions and triggers" |
| USDZ packaging | 1, 3 | OpenUSD USDZ specification; `usdzip` output |
| `write(to:)` output | 2, 3 | **[rv-usd]** export of our own scene, inspected with Python `zipfile` and `usdtree` |
| `realitytool` | 3 | `xcrun realitytool help …`; one compile of our own `.rkassets` |
| `.reality` container | 2 | our own compiled file, container level only |
