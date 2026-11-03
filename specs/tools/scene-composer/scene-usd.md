# Scene composer 2: scenes as USD

Status: draft round 0 (OBS-RCP, 2026-10-29; RCP 3 sample and USD export added by OBS-RCP4). Reference: the USDA that the
Reality Composer Pro 1/2 generation writes into `.rkassets` folders, the
same conventions used by Xcode 27.1's visionOS app template, and what
RealityKit (macOS 27) and `realitytool` (Xcode 27.1) accept. Reality
Composer Pro 3.0 no longer stores scenes as USD (`project-format.md` §4);
for it, USD is an import/export format. This file is therefore the
contract for (a) the source form Ycode writes and Xcode compiles, and (b)
what Ycode must read from USD exported by any tool.

Evidence tags: **[tmpl]** format study of Xcode 27.1's visionOS app
template scenes (grammar only, nothing copied); **[probe]** our own USDA
loaded with macOS 27 RealityKit by our dump probe and, where stated,
compiled with `realitytool` and loaded again; **[str]** names from binary
metadata (level 4).

## 1. Layer conventions

Every scene file is a text USD layer (`#usda 1.0`). Rules:

| Item | Convention | Notes |
|---|---|---|
| Header metadata | `defaultPrim`, `metersPerUnit = 1`, `upAxis = "Y"` | always written **[tmpl]**. RealityKit converts other units/axes on the load wrapper (`07-assets.md` §2). |
| Default prim | an `Xform` named `Root` | the loaded wrapper entity's single child **[probe]**; other names work, but every reference tool writes `Root`. |
| Other layer metadata | `customLayerData` is allowed and ignored by the loader **[probe]**; `timeCodesPerSecond`, `startTimeCode`, `endTimeCode` when the layer has time samples (`timelines-behaviors.md` §6). | Ycode writes `customLayerData = { string creator = "<tool name> <version>" }`. |
| Child order | `reorder nameChildren = [...]` on a prim lists children in editor order **[tmpl]** | Purely for ordering; the reference sometimes leaves empty strings in the list (seen inside a material, `materials.md` §2); readers must tolerate them, Ycode never writes them. |
| Activation | `active = true` metadata is written on most prims the editor created **[tmpl]**; `active = false` drops the prim and its subtree from the loaded scene **[probe]** | |
| Transforms | `xformOp:translate` (`float3` or `double3`), `xformOp:orient` (`quatf`, real part first), `xformOp:scale` (`float3`), `uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:orient", "xformOp:scale"]` **[tmpl]** | The template keeps the three-entry `xformOpOrder` even when some ops are unauthored (e.g. only `scale` on a referencing prim). Readers must accept any `UsdGeomXformable` op set (rotateXYZ, transform …). Ycode writes exactly T·R·S in this order, `double3` for translate. |
| Visibility | `token visibility = "invisible"` keeps the entity in the tree **[probe]** | Whether the entity is disabled or only hidden: open question Q4. |
| Material binding | `prepend apiSchemas = ["MaterialBindingAPI"]` on the prim plus `rel material:binding = </path/Material> (bindMaterialAs = "weakerThanDescendants")` **[tmpl]** | A root prim may carry `rel material:binding = None (bindMaterialAs = …)`, i.e. an explicitly empty binding **[tmpl]**. |

Prim names are USD identifiers. Entity names in RealityKit are the prim
names, so `Entity.findEntity(named:)` in app code depends on them; Ycode
must never rename prims silently.

## 2. Geometry and assets

- Implicit shapes the editor creates are `Sphere` (`double radius`),
  `Cube` (`double size`), `Cylinder`, `Cone`, `Capsule`; `Plane` is not
  supported by RealityKit (`07-assets.md` §2–3). Meshes are `Mesh` prims
  with the usual `UsdGeomMesh` attributes; editors write
  `uniform token subdivisionScheme = "none"` for polygonal assets and may
  write `uniform token orientation = "leftHanded"` **[tmpl]**.
- Imported files are **referenced**, never copied into the scene layer:
  `def "<Name>" (active = true; prepend references = @<relative path>@)`
  with an empty type name; the referencing prim may add xform overrides
  (e.g. a scale on a `.usdz` whose units differ) **[tmpl]**. Paths are
  relative to the referencing layer; `.usda`, `.usdc` and `.usdz` targets
  load **[probe]**.
- A reference to a material library layer is the same shape: a typeless
  prim referencing the layer's default prim, and bindings target the
  material *inside* it (`</Root/<Ref>/<Material>>`) **[tmpl] [probe]**.
- `references = None` (explicitly empty list) appears on editor-created
  prims **[tmpl]**; readers treat it as "no references".

## 3. Composition features (verified **[probe]**)

| Feature | Result at load |
|---|---|
| Internal and external references | subtree loaded under the referencing prim |
| `instanceable = true` on referencing prims | each instance becomes a full, separate entity subtree (instancing only shares mesh/texture data, `07-assets.md` §3) |
| `payload` | loaded eagerly (no deferred payload loading) |
| `variantSets` with a selection | the selected variant's subtree is loaded; switching variants after load is not possible through the scene file |
| `customLayerData` | ignored |
| `active = false` | prim and descendants absent |

## 4. Component storage

### 4.1 Encoding rule

A RealityKit component on an entity is a **child prim** of the entity's
prim:

```
def RealityKitComponent "<prim name>"
{
    uniform token info:id = "RealityKit.<Kind>"
    <type> <field> = <value>
    def RealityKitStruct "<field>"
    {
        <type> <field> = <value>
    }
}
```

- `info:id` selects the component kind; the prim name is free (the
  reference editor uses the kind name, e.g. `"Collider"`, and a suffix for
  disambiguation). Some files write `token info:id` without `uniform`;
  both load **[tmpl]**.
- Fields are attributes named after the runtime type's serialized field
  names (the engine type registry) **[str] [probe]**. Nested structures
  are `RealityKitStruct` child prims named after the field. Entity
  references are relationships to the target prim (`rel iblEntity =
  </Root/…>`) **[probe]**.
- Unknown `info:id`s and unknown fields are ignored without diagnostics;
  wrongly typed values read as zero (`compile.md` §2.5) **[probe]**. A
  writer must therefore use the exact names below.
- Custom (app-defined) components use a different prim type,
  `RealityKitCustomComponent`, with `info:id = "<Module>.<Type>"` and a
  prim name `<Module>_<Type>`; their fields are the Swift `Codable` keys
  (`compile.md` §4.5).
- Other RealityKit prim types seen: `RealityKitStruct` (nested data),
  `RealityKitAudioFile` / `RealityKitAudioFileGroup`
  (`particles-audio.md` §2), `RealityKitTimeline` / `RealityKitTrack` /
  `RealityKitAction` (`timelines-behaviors.md` §2),
  `RealityKitMeshSortingGroup` **[str]**, `RealityKitComponents` /
  `RealityKitCustomComponent` in schema files (`compile.md` §4.4).

### 4.2 Value types

USD types used by the reference and accepted by the loader: `bool`,
`int`, `uint`, `float`, `double`, `float2/3/4`, `quatf`, `token`
(enumerations; values are capitalised words such as `"Default"`,
`"Box"`, `"Kinematic"`, `"Plane"`), `string`, `asset`, `token[]`,
`float[]`, `rel`. Colours are `float3` linear values (no alpha) for
lights **[probe]**.

### 4.3 Components and their fields

"Verified" = we wrote a non-default value and the loaded RealityKit
component showed it **[probe]**. Field types are those that worked.

**Collision** — `info:id = "RealityKit.Collider"` → `CollisionComponent`

| Field | Type | Meaning / default |
|---|---|---|
| `group` | uint | collision group bits; verified. Editor default 1 **[tmpl]**; 0 if absent **[probe]**. |
| `mask` | uint | collision mask; verified. Editor default 4294967295. |
| `type` | token | `"Default"` (editor default) or `"Trigger"`. The collider builder knows the names `type` and `interactionType` with the values `Default` and `Trigger` **[str]**. `"Trigger"` in either attribute (`uniform` or not) loads as `collisionOptions = .static` (`isStatic = true`) and leaves `mode = .default`, by direct load and after `realitytool compile` alike; when both are written, `type` wins; lower-case `trigger` and integer values are ignored **[probe]**. No USD spelling producing `mode = .trigger` was found (Q1). |
| struct `Shape` | | `token shapeType` = `"Box"` (with `float3 extent`), `"Sphere"` (`float radius`), `"Capsule"` (`float radius`, `float height`) — all verified by the loaded bounds; nested struct `pose` with `float3 position` offsets the shape (verified) and, by name, `quatf orientation` **[str]**. The editor writes both `extent` and `radius` regardless of shape **[tmpl]**. |

Static flag: OBS-RCP4's loads gave `isStatic = false` and empty
collision options for colliders without `"Trigger"` (no rigid body) and
`isStatic = true` only with it; this corrects round 0's note that every
loaded collider without a rigid body is static.

RCP 3 stores collision as `tm_re_collision_component` with `mode`
**0 = default, 1 = trigger, 2 = colliding** (`project-format.md` §4.7.4);
its `.reality` export of mode 1 loads as `.trigger`. Ycode's importer of
RCP 3 projects maps mode 1 to the runtime's trigger mode; Ycode's USD
writer has no verified spelling for it yet and keeps `mode` in its
pass-through data (§7).

**Physics body** — `"RealityKit.RigidBody"` → `PhysicsBodyComponent`

| Field | Type | Verified effect |
|---|---|---|
| `motionType` | token | `"Dynamic"` (default), `"Kinematic"` (verified), `"Static"` |
| `gravityEnabled` | bool | `isAffectedByGravity` (verified) |
| `isCCDEnabled` | bool | continuous collision detection (verified) |
| `lockRotationX/Y/Z`, `lockTranslationX/Y/Z` | bool | per-axis locks (X verified) |
| `angularDamping` | float | verified; `linearDamping` accepted by name **[str]**, not visible in our dump (Q2) |
| struct `massFrame` | | `float m_mass` → mass (verified); centre-of-mass pose `m_pose` **[str]** |
| struct `material` | | `double staticFriction`, `double dynamicFriction`, `double restitution` → the body's physics material (all verified) |
| other names **[str]** | | `setSleepOnCreation`, `ccdVelocityThreshold`, `canSleep`, `remoteAuthorityAllowed` |

**Physics motion** — `"RealityKit.MotionState"` → `PhysicsMotionComponent`:
`float3 m_linearVelocity`, `float3 m_angularVelocity` (verified; the
names without `m_` and the `m_userSet…` names are ignored).

**Anchoring** — `"RealityKit.Anchoring"` → `AnchoringComponent`; the
entity loads as an `AnchorEntity`. Fields live in struct `descriptor`:
`token type` (`"Plane"` verified; `"World"`, `"Camera"`, `"Image"`,
`"Face"`, `"Body"` **[str]**), `token alignment` (`"Horizontal"` verified,
`"Vertical"` **[str]**), `float2 bounds` (minimum plane bounds,
verified), classification tokens `"Floor"`, `"Wall"`, `"Ceiling"`,
`"Table"`, `"Seat"` **[str]** (field name not verified; an absent value
means "any"), image anchoring `anchorImage`, `physicalWidth`,
`scaleFactor` **[str]**, `isRequired` **[str]**, world `transform`
**[str]**. Tracking mode loaded as `.continuous`-equivalent (raw 1).
Reality Composer 1-style `Preliminary_AnchoringAPI` metadata
(`preliminary:anchoring:type`, `preliminary:planeAnchoring:alignment`,
`preliminary:imageAnchoring:referenceImage`) is also read **[str]**.

**Accessibility** — `"RealityKit.Accessibility"` → `AccessibilityComponent`:
`bool isEnabled` → `isAccessibilityElement` (verified), `string label`,
`string value` (verified; become localized-string keys), `isRoot`,
`traits`, `customContent`, `systemRotors`, `customRotors`,
`systemActions`, `customActions` **[str]**.

**Input target** — `"RealityKit.InputTarget"` → `InputTargetComponent`:
`bool allowsIndirectInput` (verified: false leaves direct input only),
`allowsDirectTouchInput`, `allowsDirectPinchInput`, `isHandAnchored`,
`handAnchoringChirality`, `hitTestingType` (`"Strong"`, `"Weak"`,
`"Hierarchical"`) **[str]**. An empty prim gives the default (all input
types, enabled) **[tmpl] [probe]**. Needs a collider to receive gestures.

**Grounding shadow** (RCP 3 stores `tm_re_grounding_shadow_component`
with `casts_shadow`, `receives_shadow`, `fade_behavior_near_physical_objects`
— all false/0 when the component is just added; its `.reality` loads
as `castsShadow = false`) — `"RealityKit.GroundingShadow"` →
`GroundingShadowComponent`: `bool enableIBLShadow`, `bool
enableMeshShadow` (cast), `bool enableReceiveIBLShadow`, `bool
enableReceiveMeshShadow` (receive), `shadowFadeBehaviorNearPhysicalObjects`,
`meshShadowIntensity`, `modeBitFlags` **[str]**. Loading with the cast
flags set gave `castsShadow = true` (verified); the receive flags were
not visible through the public API (Q3).

**Opacity** — `"RealityKit.HierarchicalFade"` → `OpacityComponent`:
`float opacity` (verified).

**Billboard** — `"RealityKit.Billboard"` → `BillboardComponent`: `float
blendFactor` (verified).

**Character controller** — `"RealityKit.CharacterController"` →
`CharacterControllerComponent`. All fields are in struct
`m_controllerDesc`: `float3 extents` (**x → height, y → radius**,
verified), `float skinWidth`, `float slopeLimit` (radians), `float
stepLimit`, struct `collisionFilter` with `uint group`, `uint mask` (all
verified). `upVector` as a `float3` field was not taken (Q2). Defaults
when the prim is empty: height 0, radius 0 (note: not the API defaults
2.0/0.25), skin 0.01, slope π/4, step 0.2, group 1, mask all.

**Lights** (dedicated builder **[str]**, verified fields):

| `info:id` | Component | Fields |
|---|---|---|
| `RealityKit.PointLight` | `PointLightComponent` | `float3 color` (linear), `float intensity` (lumens), `float attenuationRadius`, `float attenuationFalloffExponent` |
| `RealityKit.SpotLight` | `SpotLightComponent` | the above plus `float innerAngle`, `float outerAngle` (degrees); `zNear`, `zFar`, `isEnabled` **[str]** |
| `RealityKit.DirectionalLight` | `DirectionalLightComponent` | `float3 color`, `float intensity` (lux); `isRealWorldProxy` **[str]** |

RCP 3 point light (`tm_re_point_light_component`, `project-format.md`
§4.7.4): a newly added light loads from RCP's `.reality` with colour
white (linear sRGB), `intensity` 100000, `attenuationRadius` 10 and
falloff exponent **1** (the API's default exponent is 2) and light
layer `default` **[run]**. The editor's defaults, not the API's, are
what a user sees; Ycode's editor should offer the same values for a new
light and write them explicitly.

Defaults with only `intensity` written: spot inner 45°, outer 60°,
radius 10, exponent 2, colour white — the API defaults. Shadow components
(`DirectionalLightShadow`, `SpotLightShadow`, `…ShadowMap` names **[str]**)
did not appear on load with an empty prim (Q2).

**Image-based light** — receiver `"RealityKit.ImageBasedLightReceiver"`
with `rel iblEntity = </…>` (verified: the target entity is attached);
the source `"RealityKit.ImageBasedLight"` takes an environment asset and
`intensityExponent`, `inheritsRotation` (names **[str]**; asset form
not verified, Q2).

**Portals and worlds** — `"RealityKit.WorldRoot"` → `WorldComponent`
(verified; `"RealityKit.World"` gives nothing). `"RealityKit.Portal"` →
`PortalComponent` (verified present); its target-world relationship name
is not settled: `targetEntity` and `targetWorldEntity` both left
`targetEntity = nil` (Q2). Other portal fields **[str]**: `clipPlanePosition`,
`clipPlaneNormal`, `crossPlanePosition`, `crossPlaneNormal`,
`lightingBlendDistance`, `clipVolumePosition`, `clipVolumeExtents`.

**Particles** — `"RealityKit.VFXEmitter"` (`particles-audio.md` §1).
**Audio** — `"RealityKit.SpatialAudio"`, `"RealityKit.AmbientAudio"`,
`"RealityKit.ChannelAudio"`, `"RealityKit.AudioLibrary"`,
`"RealityKit.AudioMixGroups"`, `"RealityKit.Reverb"`
(`particles-audio.md` §3). **Animation library** —
`"RealityKit.AnimationLibrary"` (`timelines-behaviors.md`).

**Docking region** — `"RealityKit.CustomDockingRegion"` with struct
`m_bounds` (`float3 min`, `float3 max`) **[tmpl]** (visionOS video docking).

**Hover effect** — `HoverEffectComponent` exists in the runtime and in the
reference's component list **[str]**, but neither `RealityKit.HoverEffect`,
`RealityKit.HoverEffectComponent` nor `RealityFoundation.HoverEffect`
created it from USD (Q2). RCP 3 stores `tm_re_hover_effect_component`
(`hover_effect_type`, names `Highlight`/`Shader` **[str]**; `hover_effect`
= a highlight style with `color`, `strength` or a shader style with fade
durations); a new component exported to `.reality` loads as the
highlight effect with colour white and strength 1 **[run]**. RCP 3's
USD export does not write it (§5.1), so the USD form stays open.

**Model and transform** are not component prims: the model comes from
the geometry prim plus its material binding; the transform from xform ops.
`SynchronizationComponent` is added to every entity automatically.

### 4.4 Defaults policy for writers

Write every field the user changed and the fields the reference always
writes (collider `group`, `mask`, `type`, both `extent` and `radius`);
omit everything else so that runtime defaults apply. Do not rely on
API-level defaults for empty prims: the loader's empty-prim defaults
differ for some kinds (character controller, collider group).

### 4.5 RCP 3 component names (for the RCP 3 importer)

Pairs confirmed by one sample: the `tm_re_*` component in an app-made
project, the runtime component its `.reality` export loads as
**[run]**, and the USD `info:id` of the same runtime component (from
§4.3, verified by our own USD loads). RCP 3 itself writes no component
prims to USD (§5.1).

| RCP 3 type | Runtime component | USD `info:id` |
|---|---|---|
| `tm_re_collision_component` (`mode` 1) | `CollisionComponent` (`.trigger`) | `RealityKit.Collider` (trigger mode: open, Q1) |
| `tm_re_input_target_component` | `InputTargetComponent` (enabled) | `RealityKit.InputTarget` |
| `tm_re_spatial_audio_component` | `SpatialAudioComponent` | `RealityKit.SpatialAudio` |
| `tm_re_audio_library_component` | `AudioLibraryComponent` (key = asset name) | `RealityKit.AudioLibrary` |
| `tm_re_particle_emitter_component` | `ParticleEmitterComponent` | `RealityKit.VFXEmitter` |
| `tm_re_hover_effect_component` | `HoverEffectComponent` (highlight) | unknown (Q2) |
| `tm_re_grounding_shadow_component` | `GroundingShadowComponent` | `RealityKit.GroundingShadow` |
| `tm_re_point_light_component` | `PointLightComponent` | `RealityKit.PointLight` |
| `tm_model_component` + `tm_box_mesh_resource` | `ModelComponent` (1 m box mesh) | a `Cube`/`Mesh` prim with a material binding |

Field names differ between the three layers (snake_case engine fields
for most `tm_re_*` types, Swift-style names for the emitter, the
type-registry names in USD); the importer maps each field, it never
copies names across.

## 5. What the reference accepts

- **Direct USD load** (`Entity(contentsOf:)` on `.usda`): everything in
  §1–4 **[probe]**.
- **`realitytool compile`** of an `.rkassets` folder: same results after
  loading the `.reality` (spot-checked for colliders, materials,
  timelines, emitters, audio) **[probe]**; silent drops are listed in
  `compile.md` §2.5.
- **Xcode's build** runs `realitytool compile` on the `.rkassets` folder
  (`compile.md` §3), so what compiles is what the build accepts.
- **Reality Composer Pro 3.0's own USD export** — see §5.1.
- **Reality Composer Pro 3.0** imports USD (`editor-behavior.md` §6) and
  migrates RCP 2 projects (`project-format.md` §3.4, §3.6). In our
  sample the collider (box shape, size, `Default` type) and the input
  target survived as `tm_re_collision_component` and
  `tm_re_input_target_component`; the `Cube` became a baked mesh; the
  binding became a model-component material slot; an empty referencing
  prim survived only in the unoptimized hierarchy.

### 5.1 What RCP 3.0 writes when it exports USDA (observed)

*File ▸ Export Selected ▸ USDA (Mesh)* of the whole scene of an app-made
sample (cube with collider, input target, spatial audio, audio library,
emitter, hover effect, grounding shadow and a textured graph material;
a point light) wrote a folder named like the file, `<Name>.usda/`,
holding `<Name>.usda` and an **empty** `<Name>_textures/` folder **[run]**.

| Item | Written |
|---|---|
| Layer metadata | `defaultPrim = "<Name>"` (the export name, default `Selection`), `metersPerUnit = 1`, `upAxis = "Y"`; no `customLayerData`, no time codes |
| Root | `def Xform "<Name>"` with an identity `matrix4d xformOp:transform` and `xformOpOrder = ["xformOp:transform"]` |
| Entities | one `Xform` per entity, named as the entity, transform as **`matrix4d xformOp:transform`** only (no T·R·S ops) |
| Model | a child `Xform "Model<decimal 64-bit id>"` holding `Mesh "Part<decimal 64-bit id>"`: triangles (`faceVertexCounts` all 3), `points` (the library cube became 24 vertices, ±0.5), `normals` and `texCoord2f[] primvars:st1` (both `interpolation = "vertex"`; note the name `st1`), `subdivisionScheme = "none"`; no `extent`, no `orientation` |
| Binding | `rel material:binding` directly on the `Mesh`, **without** `MaterialBindingAPI` in `apiSchemas` and without `bindMaterialAs` |
| Material | a sibling of the entities under the root, named `<entity>_Mat<n>`: a `UsdPreviewSurface` `Shader "PBRShader"` with only `diffuseColor = (0, 0, 0)` and `opacity = 0`, and `outputs:surface` and `outputs:displacement` connected. The graph material (image node into a preview-surface node) and its texture were **not** exported: no texture file, no MaterialX node, the base colour lost, and an opacity of 0 |
| Components | **none**: no `RealityKitComponent` prims at all (collider, input target, audio, emitter, hover effect, shadow) |
| Light | the light entity is an empty `Xform`; no `RealityKit.PointLight` and no `UsdLux` prim |
| Audio files | none |

Consequences: the USDA (Mesh) export is geometry-only, as its menu name
says. It settles none of the component names of §4.3 (they remain
confirmed by our own loads only), and it cannot be used to carry an
RCP 3 scene into Ycode. Ycode imports such files as plain USD meshes,
and must accept the matrix transform form, bindings without
`MaterialBindingAPI`, and `st1` as a texture-coordinate primvar. The
`.reality` export (`compile.md` §6.9) is the full-fidelity path; a
direct RCP 3 project import (`project-format.md` §4.6) is the editable
one.

## 6. Requirements for Ycode

1. Writer: §1 conventions exactly; component prims per §4 with verified
   names only; anything unverified stays in a "pass-through" bag (§7).
2. Reader: full OpenUSD composition (references, payloads, variants,
   instancing), unknown prims and fields preserved on round trip.
3. A component catalogue file in Ycode (data, not code) maps each
   `info:id` to fields, types, defaults and the verification state above,
   so later observation rounds only edit data.

## 7. Round-trip rule

Ycode must keep unknown component prims, unknown fields and unknown
metadata verbatim (as opaque USD specs) and write them back unchanged.
This is how files from newer reference versions survive a Ycode edit.

## Open questions

- Q1. **Partly answered.** RCP 3 stores a trigger as collision `mode`
  1 and its `.reality` loads as `.trigger`; its USD export writes no
  collider at all. In USD, `type`/`interactionType = "Trigger"` gives
  static collision options, not trigger mode (§4.3). Still open: a USD
  spelling that loads as `.trigger` (would need an RCP 2-written file
  or more probe permutations).
- Q2. Field names not settled by runs: rigid body `linearDamping`
  visibility, character `upVector`, shadow components, IBL source asset,
  portal target relationship, hover effect id and fields. RCP 3's USD
  export writes no components (§5.1), so it cannot settle them; only
  more probe permutations or an RCP 2-written file can. The RCP 3
  storage of the hover effect is now known (§4.3, §4.5).
- Q3. Grounding-shadow receive flags through the public API.
- Q4. `visibility = "invisible"`: entity disabled or only hidden.
- Q5. **Partly answered** (`project-format.md` §3.6): collider and input
  target survive. The other catalogue components were not in the
  migrated sample and remain untested.
- Q6. Whether *Export Selected ▸ USDZ (Mesh)* packs the texture that the
  USDA export dropped, and whether a material made from Physically Based
  nodes (instead of a preview-surface node) exports with its values.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Header metadata, `Root`, xform op order, binding form, `nameChildren`, reference shapes, collider/input-target/docking prims | 2 | format study of Xcode 27.1 visionOS template scenes **[tmpl]** |
| Composition results §3 | 3 | **[probe]** our `t3` samples |
| Component encoding rule, arbitrary-component builder, custom component prim type | 4, 3 | type-registry names in RealityKit's bundled frameworks **[str]**; confirmed by **[probe]** |
| Every "verified" field in §4.3 | 3 | **[probe]** our `t1`, `t2` samples (direct load; compile path spot-checked) |
| Field names marked **[str]** | 4 | strings of CoreRE / CoreRealityIO / RealityIO (names only) |
| Silent-ignore behaviour | 3 | **[probe]**, `compile.md` §2.5 |
| RCP 3 no longer stores USD | 1, 2 | Apple's RCP 3 documentation; `project-format.md` §4 |
| Collider and input target survive migration | 2, 3 | migrated sample read as a file format (`project-format.md` §3.6) |
| `Trigger` → static collision options, `type` beats `interactionType`, static flag correction | 3, 4 | builder names from CoreRealityIO strings **[str]**; 17 collider variants of ours loaded directly and after `realitytool compile` (OBS-RCP4) **[probe]** |
| RCP 3 component names and their runtime results (§4.5), point-light, hover and shadow defaults | 2, 3 | owner-made RCP 3 sample read as a file format; its headless `.reality` export loaded by our macOS probe (OBS-RCP4) |
| RCP 3 USDA export contents (§5.1) | 2 | the owner's USDA export of that sample, read as a file format |
