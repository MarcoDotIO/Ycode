# Scene composer 3: Shader Graph materials

Status: draft, round 0 (OBS-RCP, 2026-10-29). Reference: Reality Composer Pro
3.0 (the editor) and the RealityKit of Xcode 27.1 / macOS 27 (the consumer).
This file says how a Shader Graph material is stored in USD, which node
identifiers exist, which of them the build and the runtime accept, and what
Ycode's editor must write so that both read its files.

Sources, in evidence order: Apple's MIT-licensed MaterialX node definitions
published in the open-source repository `apple/plugins-for-godot`
(`godotrealitykit/GodotRealityKit/Materials/NodeDefs/*.mtlx`, level 1);
MaterialX 1.38/1.39 and OpenUSD (`UsdShade`, `UsdUI`, `UsdMtlx`) open source
(level 1); the USDA files of Xcode's visionOS templates read as a file-format
study (level 2); our own USDA files loaded by a macOS RealityKit probe and
compiled with `realitytool` (level 3, **[mat-probe]**); node-definition
interfaces (names, port names, types, defaults only) read from the MaterialX
data files that ship inside Reality Composer Pro and inside Xcode's USD
library (level 4, **[nd-iface]**). No implementation graphs, shader code or
documentation text were taken from those files.

## 1. Where materials live

1. A material is a `UsdShade` `Material` prim. It may sit anywhere in a scene
   layer (usually as a child of the root `Xform`) or in a separate library
   layer that the scene pulls in with a `references` arc. The visionOS app
   template stores its sample material in `Materials/<Name>.usda` whose
   `defaultPrim` is `Root` and whose material is `/Root/<Name>`; the scene
   references that layer on a prim named after the material, so the bound
   path is `</Root/<Name>/<Name>>` (the referencing prim plus the
   material's own name).
2. Binding uses `MaterialBindingAPI`: `prepend apiSchemas =
   ["MaterialBindingAPI"]` on the geometry prim and `rel material:binding =
   </path/to/Material>`. Reality Composer Pro writes the binding-strength
   metadata `bindMaterialAs = "weakerThanDescendants"` on every binding,
   including an empty `rel material:binding = None (bindMaterialAs = …)` on
   the root `Xform`. RealityKit accepted bindings with and without that
   metadata **[mat-probe]**.
3. The material's name in RealityKit is the `Material` prim's name
   (`Material.name`, observed for every case below, including fallbacks).
4. Loading by path: `ShaderGraphMaterial(named:from:in:)` takes the
   material's prim path and the scene file name inside a bundle (public API,
   level 1); a writer must therefore keep material prim paths stable.

## 2. The Material prim

| Property | Type | Meaning |
|---|---|---|
| `outputs:mtlx:surface` | `token`, connected | The surface terminal. Connect it to the `out` output of one surface-shader node (§5). Makes the material a `ShaderGraphMaterial`. |
| `outputs:realitykit:vertex` | `token`, optionally connected | The geometry-modifier terminal. Connect it to the `out` output of a geometry-modifier node (§6). Reality Composer Pro declares it even when unconnected. |
| `outputs:surface` | `token` | The plain `UsdPreviewSurface` terminal. Reality Composer Pro declares it unconnected on Shader Graph materials; when it is the only connected terminal the material is a `PhysicallyBasedMaterial` (§5.3). |
| `inputs:<Name>` | any parameter type | A promoted (exposed) parameter (§3). |
| `ui:nodegraph:realitykit:subgraphOutputs:pos` | `float2` | Editor position of the material's output box. |
| `ui:nodegraph:realitykit:subgraphOutputs:size` | `float2` | Editor size of the output box. |
| `ui:nodegraph:realitykit:subgraphOutputs:stackingOrder` | `int` | Editor z-order of the output box. |
| `reorder nameChildren = [...]` | list op | Child order. Reality Composer Pro's files contain empty strings in this list (an artefact of deleted nodes); readers must tolerate them, writers should not emit them. |
| prim metadata `references = None` | list op | Written by Reality Composer Pro on some materials and shader prims (an explicitly empty reference list). Harmless; readers ignore it. |

Children of the material are `Shader` prims (nodes) and `NodeGraph` prims
(node groups, §4). Shader prims may also be nested inside node groups.

### 2.1 Shader (node) prims

```
def Shader "<NodeName>"
{
    uniform token info:id = "<nodedef name>"          # e.g. ND_multiply_color3
    <type> inputs:<port> = <value>                     # constant input
    <type> inputs:<port>.connect = </Mat/Other.outputs:<port>>
    <type> inputs:<port>.connect = </Mat.inputs:<Param>>   # promoted parameter
    <type> outputs:<port>                              # declared output(s)
    float2 ui:nodegraph:node:pos = (x, y)
    float2 ui:nodegraph:node:size = (w, h)
    int    ui:nodegraph:node:stackingOrder = n
    string[] ui:nodegraph:realitykit:node:attributesShowingChildren = ["inputs:<port>", "Advanced"]
}
```

Rules observed in reference-written files (level 2) and accepted by the
runtime (level 3):

1. `info:id` is the MaterialX **nodedef name** (`ND_<node>_<type>[_<variant>]`),
   not the node category. USD types follow `UsdMtlx` mapping: MaterialX
   `float`→`float`, `integer`→`int`, `boolean`→`bool`, `color3`→`color3f`,
   `color4`→`color4f`, `vector2/3/4`→`float2/3/4`, `matrix33/44`→
   `matrix3d/4d`, `string`→`string`, `filename`→`asset`, `half*`→`half*`;
   surface and vertex outputs are `token`.
2. An input may carry both a value and a `.connect`; the connection wins.
   `inputs:x.connect = None` (an explicitly empty connection) appears in
   reference files after a link was removed. Inputs may be declared with no
   value (`float inputs:clearcoat`), meaning "use the nodedef default".
3. Multi-output nodes declare each output by its nodedef output name
   (`outputs:outx`, `outputs:outy` for `separate2`).
4. Node names are free; the editor uses the node category in title case with
   `_1`, `_2` suffixes for duplicates (`Multiply`, `Multiply_1`).
5. The `ui:nodegraph:node:*` attributes are the standard OpenUSD `UsdUI`
   `NodeGraphNodeAPI` properties (`pos`, `size`, `stackingOrder`,
   `displayColor`, `icon`, `expansionState`, `docURI`); reference files author
   them **without** applying the API schema. `attributesShowingChildren`
   lists inspector groups the user expanded (input names, or a group label
   such as `Advanced`). None of the `ui:` properties affect the runtime
   result **[mat-probe]**.
6. Colour constants may carry `colorSpace` metadata (§3.2).

## 3. Promoted parameters

A promoted parameter is an `inputs:<Name>` property on the `Material` prim;
nodes connect to it with `.connect = </Mat.inputs:<Name>>`. RealityKit
exposes every Material-level input as a `ShaderGraphMaterial` parameter whose
name is `<Name>` (without `inputs:`), whether or not any node uses it
**[mat-probe]**. These are the names apps pass to
`ShaderGraphMaterial.setParameter(name:value:)`.

### 3.1 Parameter types observed **[mat-probe]**

| USD type on the Material | `ShaderGraphMaterial` parameter value |
|---|---|
| `float` | `.float` |
| `half` | `.float` |
| `int` | `.int` |
| `bool` | `.bool` |
| `float2` / `float3` | `.simd2Float` / `.simd3Float` |
| `color3f` | `.color` (alpha 1), converted per §3.2 |
| `color4f` | `.color` |
| `matrix4d` | `.float4x4` |
| `asset` connected to a texture node's `file` input | `.textureResource` |
| `asset` not connected, or file missing | listed in `parameterNames`, no value |
| `string` | listed in `parameterNames`, no value |

The values survive `realitytool compile`: the same names and values came back
from the compiled `.reality` file **[mat-probe]**.

Editor layout of a promoted parameter inside the graph view: not observed in
our files. Earlier editor versions are reported to keep it in the input's
`customData` (`dictionary realitykit = { float2 positionInSubgraph; float2
sizeInSubgraph; int stackingOrderInSubgraph }`); RealityKit ignored such a
dictionary in our test. Open question Q3.

### 3.2 Colour spaces

`colorSpace` metadata on a colour input or attribute names the space of the
authored value. Observed conversions of an authored `(0.5, 0.5, 0.5)`
**[mat-probe]**:

| `colorSpace` token | Result |
|---|---|
| none | linear sRGB, 0.5 |
| `lin_srgb` | linear sRGB, 0.5 |
| `srgb_texture` | linearised, 0.214041 |
| `Input - Texture - sRGB - sRGB` (ACES/OCIO-style name written by the reference editor) | linearised, 0.214041 |
| `Utility - Linear - sRGB` | linear sRGB, 0.5 |
| `lin_displayp3` | linear Display P3, 0.5 |

Apple's public USD documentation also lists `srgb_displayp3` and
`sourceColorSpace` fallbacks for textures (`07-assets.md` §3). A Ycode writer
uses the MaterialX/USD tokens (`lin_srgb`, `srgb_texture`, `lin_displayp3`,
`srgb_displayp3`, `raw`) and reads the OCIO-style names as aliases.

## 4. Node groups (custom nodes)

A node group is a `NodeGraph` prim inside the material:

```
def NodeGraph "<GroupName>"
{
    <type> inputs:<In>  [= value] [.connect = </Mat.inputs:P> or </Mat/Node.outputs:o>]
    <type> outputs:<Out>.connect = </Mat/<GroupName>/<Inner>.outputs:out>
    float2 ui:nodegraph:node:pos = (x, y)                      # the group's box in the parent graph
    float2 ui:nodegraph:realitykit:subgraphOutputs:pos = (x, y)  # output box inside the group
    def Shader "<Inner>" { ... inputs:in1.connect = </Mat/<GroupName>.inputs:<In>> ... }
}
```

Nodes outside connect to `</Mat/<GroupName>.outputs:<Out>>`. Inner nodes read
the group's interface through `</Mat/<GroupName>.inputs:<In>>`. Our group
(one interface input fed by a promoted parameter, one output feeding the
surface) loaded as a `ShaderGraphMaterial` and the promoted parameter stayed
visible **[mat-probe]**. This is standard `UsdShade` NodeGraph encapsulation
(level 1), so groups may nest.

## 5. Surface shaders

Exactly one surface node feeds `outputs:mtlx:surface`. Inputs with defaults
**[nd-iface]**:

### 5.1 `ND_realitykit_pbr_surfaceshader` (Physically Based)

| Input | Type | Default |
|---|---|---|
| `baseColor` | color3 | 0.18, 0.18, 0.18 |
| `emissiveColor` | color3 | 0, 0, 0 |
| `normal` | vector3 (tangent space) | 0, 0, 1 |
| `roughness` | float | 0.5 |
| `metallic` | float | 0 |
| `ambientOcclusion` | float | 1 |
| `specular` | float | 0.5 |
| `opacity` | float | 1 |
| `opacityThreshold` | float | 0 |
| `clearcoat` | float | 0 |
| `clearcoatRoughness` | float | 0.01 |
| `clearcoatNormal` | vector3 | 0, 0, 1 |
| `hasPremultipliedAlpha` | boolean, uniform | false |

Output `out` (surfaceshader).

`ND_realitykit_pbr_surfaceshader_2_0` (Xcode 27.1 library and macOS 27
runtime) has the same first twelve inputs plus `subsurfaceWeight` 0,
`subsurfaceColor` (0.8, 0.8, 0.8), `subsurfaceRadius` 1,
`subsurfaceRadiusScale` (1.0, 0.5, 0.25), `subsurfaceScatterAnisotropy` 0,
`bentNormal` (0, 0, 1), `sheenColor` (0, 0, 0), `bakedIndirectIrradiance`
(−1, −1, −1, "not baked"), `hasPremultipliedAlpha` false,
`baseDiffuseRoughness` (half) 0, `clearcoatIOR` 1.6,
`clearcoatAnisotropyLevel` 0, `clearcoatAnisotropyAngle` 0, `specularIOR`
1.5, `specularAnisotropyLevel` 0, `specularAnisotropyAngle` 0,
`specularColor` (1, 1, 1), `specularWeight` (half) 1. It loaded as a
`ShaderGraphMaterial` and compiled **[mat-probe]**.

**Version skew.** Reality Composer Pro 3.0's own node library names the
extended shader `ND_realitykit_pbr_surfaceshader_v2` (first twenty inputs of
the list above, `bakedIndirectIrradiance` as half3). The macOS 27 runtime
and Xcode 27.1's `realitytool` do **not** know `_v2`: the material silently
became the fallback material (§5.5) and the compiled file held no shader graph
for it **[mat-probe]**. Ycode writes `ND_realitykit_pbr_surfaceshader` (or
`_2_0` when the deployment target is 27 or later) and reads `_v2` as an alias
of `_2_0`. Whether Reality Composer Pro 3.0 ever writes `_v2` into USDA is
open (Q1).

### 5.2 `ND_realitykit_unlit_surfaceshader` (Unlit)

| Input | Type | Default |
|---|---|---|
| `color` | color3 | 1, 1, 1 |
| `opacity` | float | 1 |
| `opacityThreshold` | float | 0 |
| `applyPostProcessToneMap` | boolean, uniform | true |
| `hasPremultipliedAlpha` | boolean, uniform | false |

### 5.3 `UsdPreviewSurface`, two forms

| Form | Terminal | Result **[mat-probe]** |
|---|---|---|
| Plain USD: `Shader` with `info:id = "UsdPreviewSurface"` plus `UsdUVTexture` / `UsdPrimvarReader_float2` | `outputs:surface` | `PhysicallyBasedMaterial` (diffuse colour, roughness, metallic, texture mapped) |
| MaterialX: `info:id = "ND_UsdPreviewSurface_surfaceshader"` | `outputs:mtlx:surface` | `ShaderGraphMaterial` |

The MaterialX form is what the reference editor writes for its "Preview
Surface" node (template files, level 2); its inputs are those of the
standard MaterialX `UsdPreviewSurface` nodedef (`diffuseColor`,
`emissiveColor`, `useSpecularWorkflow`, `specularColor`, `metallic`,
`roughness`, `clearcoat`, `clearcoatRoughness`, `opacity`,
`opacityThreshold`, `ior`, `normal`, `displacement`, `occlusion`). The
reference template also uses the primvar readers in MaterialX form
(`ND_UsdPrimvarReader_vector2` with `string inputs:varname`).

After compiling, the plain-USD form with a diffuse texture came back as a
`PhysicallyBasedMaterial` whose `baseColor.texture` was empty although the
compiled material depended on a texture asset **[mat-probe]**; open (Q4).

### 5.4 Other surface nodes **[nd-iface]**

| Nodedef | Inputs (defaults) | Notes |
|---|---|---|
| `ND_realitykit_occlusion_surfaceshader` | — | Occlusion material (hides virtual content behind it). |
| `ND_realitykit_shadowreceiver_surfaceshader` | — | Shadow-catcher material. |
| `ND_realitykit_portal_surface_shader` | `opacity` 1 | Portal surface; not in the public Godot node set. |
| `ND_realitykit_hair_surfaceshader` | `baseColor` 0; `opacity` 1; `opacityThreshold` 0; `ambientOcclusion` 1; `normal` (0,0,1); `tangent` (0,1,0); `primarySpecularColor` 0.047; `primarySpecular` 0.5; `primaryRoughness` 0.3; `primaryShift` 0; `secondarySpecularColor` 0; `secondarySpecular` 0.2; `secondaryRoughness` 0.5; `secondaryShift` 0.1; `backlitColor` 0; `backlitPower` 10; `backlitScale` 10; `shadowDensity` 1; Xcode's copy adds `hasPremultipliedAlpha` false | Hair shading (27). |
| `ND_realitykit_post_lighting_surfaceshader` (Xcode/runtime) / `ND_realitykit_postlightingshader` (RCP 3.0, output type `postlightingshader`) | `color` color4 (0,0,0,0) | Post-lighting pass. Connected to `outputs:mtlx:surface` it gave the fallback material **[mat-probe]**; the right terminal is unknown (Q2). |
| Standard MaterialX surfaces (`ND_standard_surface_surfaceshader`, `ND_open_pbr_surface_surfaceshader`, `ND_gltf_pbr_surfaceshader`, `ND_surface_unlit`) | MaterialX 1.39 | Present in the reference editor's library (RCP carries an override of `standard_surface`); runtime support not tested (Q5). |

### 5.5 Fallback

An unknown `info:id` anywhere in the surface network (our test:
`ND_ycode_does_not_exist`), an unsupported surface node, or `_v2` produced a
`PhysicallyBasedMaterial` with base colour 0.18 grey, roughness 0.5,
metallic 0, keeping the material's name. Neither the loader nor
`realitytool compile` reported an error, and `compile` exited 0
**[mat-probe]**. Ycode's editor must therefore validate node ids itself and
warn, since the reference toolchain is silent.

## 6. Geometry modifier

`outputs:realitykit:vertex` connects to the `out` (type `vertex`) of
`ND_realitykit_geometrymodifier_2_0_vertexshader` (version "2.0", the current
one) **[nd-iface]**:

| Input | Type | Default |
|---|---|---|
| `modelPositionOffset` | vector3 | 0, 0, 0 |
| `color` | color4 | geometry colour (`GeomColor_Color4`) |
| `normal` | vector3 | object-space normal |
| `bitangent` | vector3 | object-space bitangent |
| `uv0`, `uv1` | vector2 | UV sets 0, 1 |
| `uv2` … `uv7` | vector4 | UV sets 2–7 |

The older `ND_realitykit_geometrymodifier_vertexshader` (no version) has
`modelPositionOffset`, `color`, `normal`, `bitangent`, `uv0`, `uv1`,
`userAttribute` (vector4), `userAttributeHalf4_0…3`, `userAttributeHalf2_0…1`
and is in the Xcode library's deprecated set. `ND_realitykit_portal_geometry_modifier`
adds `worldPositionOffset`. A material with both terminals compiled into one
material asset that depends on two shader-graph assets **[mat-probe]**.

Geometry-modifier-only input nodes (no inputs, one output):
`…_geometry_modifier_model_to_world` / `world_to_model` / `model_to_view` /
`view_to_projection` / `projection_to_view` (matrix44),
`…_normal_to_world` (matrix33), `…_vertex_id` (integer), all with the
`ND_realitykit_` prefix.

## 7. Textures

### 7.1 Texture nodes (current) **[nd-iface]**

| Node category | Nodedef ids | Output types | Distinct inputs |
|---|---|---|---|
| `RealityKitTexture2D` | `ND_RealityKitTexture2D_{color3,color4,vector4}` | color3, color4, vector4 | sampler set A, `texcoord` (vector2, UV0), `no_flip_v`, `bias`, `dynamic_min_lod_clamp`, `offset` (integer2) |
| `RealityKitTexture2DLOD` | `…2DLOD_*` | same | A, `lod` |
| `RealityKitTexture2DGradient` | `…2DGradient_*` | same | A, `gradient_dPdx`, `gradient_dPdy` |
| `RealityKitTexture2DPixel`, `…PixelLOD`, `…PixelGradient` | `…2DPixel*_*` | same | sampler set B (pixel coordinates) |
| `RealityKitTexture2DArray` (+`LOD`, `Gradient`, `Pixel*`) | `…2DArray*_*` | same | adds `index` (integer) |
| `RealityKitTexture3D` (+`LOD`, `Gradient`, `Pixel*`) | `…3D*_*` | same | adds `w_wrap_mode`; `texcoord` vector3; `offset` integer3 |
| `RealityKitTextureCube` (+`LOD`, `Gradient`) | `…Cube*_{color4,vector4}` | color4, vector4 | `texcoord` vector3 (object position) |
| `RealityKitTextureRead`, `…2DArrayRead`, `…3DRead` | `…Read_{color4,vector4}` | color4, vector4 | `x`, `y` (`z`), `lod`, `index` integers; no sampler |
| `RealityKitImageInfo` | `ND_RealityKitImageInfo_{texture2d,texture3d,texturecube}{float,half}` | outputs `width`, `height`, `num_mip_levels` (integer) | `file` |

Sampler set A (all `uniform` strings unless noted): `file` (filename),
`u_wrap_mode`, `v_wrap_mode` ∈ {`repeat`, `mirrored_repeat`,
`clamp_to_edge` (default), `clamp_to_zero`, `clamp_to_border`};
`border_color` ∈ {`transparent_black` (default), `opaque_black`,
`opaque_white`}; `mag_filter`, `min_filter`, `mip_filter` (default
`linear`); `max_anisotropy` integer 1; `max_lod_clamp` 65504.0;
`min_lod_clamp` 0.0; `default` (value when the file is missing, black).
Sampler set B replaces the three filters with one `filter`.

The standard MaterialX image nodes (`ND_image_*`, `ND_tiledimage_*`) are
also accepted: an unlit material reading `ND_image_color3` compiled and
loaded as a `ShaderGraphMaterial` **[mat-probe]**. The deprecated
`ND_realitykit_image_*` family (56 variants:
`[bias_|lod_|gradient2d_][min_lod_clamp_]<type>` with inputs `file`,
`default`, `texcoord`, `coord`, `s_address`, `t_address`, `border_color`,
filters, `max_anisotropy`, `lod_min`, `lod_max`) and
`ND_realitykit_cubeimage_*` (`file`, `default`, `texcoord` = world normal,
`filtertype` default `closest`) remain in the libraries for reading old files.
Ycode reads them and writes the `RealityKitTexture*` family.

### 7.2 Asset paths

- A texture is an `asset` value on the node's `file` input, or on a promoted
  parameter connected to it (`asset inputs:Tex = @Textures/a.png@` on the
  Material, `asset inputs:file.connect = </Mat.inputs:Tex>` on the node).
- Paths are relative to **the layer that authors them** (USD asset
  resolution, level 1). A material library at `Materials/Lib.usda` reaching
  `@../Textures/checker.png@` resolved correctly when referenced from a scene
  one folder up **[mat-probe]**. The reference template likewise refers to an
  EXR next to its layer (`@DefaultAttenuationMap.exr@`).
- A missing texture file is silent: the material stays a
  `ShaderGraphMaterial`, the parameter has no value, and `realitytool
  compile` exits 0 with no diagnostic **[mat-probe]**.
- Texture formats and colour-space rules are those of `07-assets.md` §3.

## 8. RealityKit utility nodes **[nd-iface]**

All have prefix `ND_realitykit_` unless shown. "—" means no inputs.

| Nodedef | Inputs | Outputs |
|---|---|---|
| `viewdirection_vector3` | `space` (uniform string, `world`) | vector3 |
| `cameraposition_vector3` | `space` (`world`) | vector3 |
| `surface_view_direction` | — | vector3 |
| `surface_screen_position` | — | vector4 |
| `surface_model_to_world`, `surface_model_to_view`, `surface_world_to_view`, `surface_view_to_projection`, `surface_projection_to_view` | — | matrix44 |
| `instance_id` | — | integer |
| `is_front_facing` | — | boolean |
| `barycentric_vector3` | — | vector3 |
| `hover_state` | — | `intensity` float, `position` vector3, `timeSinceHoverStart` float, `isActive` boolean |
| `geometry_switch_cameraindex_<type>` (11 types incl. half and integer) | `mono`, `left`, `right` | <type> |
| `environment_radiance` | `baseColor` (1,1,1), `roughness`, `specular`, `metallic` (half 0), `normal` (world normal) | color3 |
| `light_spill_diffuse` | `emitterUV` (UV0), `attenuationUV` (UV1), `attenuationMap` (filename) | color4 |
| `light_spill_diffuse_for_pfrm_content` | as above plus `attenuationUVStart` (0,1), `attenuationUVEnd` (1,0) | color4 |
| `light_spill_specular` | `reflection_origin` (world position), `unreflected_direction` (0,0,1), `normal` (world normal), `antialiasingStrength` (0.01,0.01) | color4 |
| `light_spill_specular_ggx` | as above plus `roughness` 0, `samples` 8 | color4 |
| `background_blur_color3` / `_color4` | — | color3 / color4 |
| `surface_custom_attribute` | — | vector4 |
| `surface_custom_attribute_half2_{0,1}`, `_half4_{0..3}` | — | half2 / half4 |
| `lighting_color` | — | color4 |
| `reflect_{vector3,half3}`, `refract_{vector3,half3}` | `in`, `normal` (world), `eta` (refract) | vector3 / half3 |
| `fractional_<t>`, `oneminus_<t>`, `step_<t>` (10 types each: float, vector2–4, color3–4, half, half2–4) | `in` (+`edge` for step) | <t> |
| `logical_and`, `logical_or`, `logical_xor`, `logical_not` | boolean `in1`, `in2` (`in`) | boolean |
| `combine2_matrix22`, `combine3_matrix33`, `combine4_matrix44` | row vectors `in1…in4` (identity) | matrix |
| `ND_normal_map_decode` | `in` (0.5,0.5,1) | vector3 |
| `ND_updirection_vector3` | `space` (`world`) | vector3 |
| `ND_ambientocclusion_float` | `coneangle` 90, `maxdistance` 1e38 | float |
| `ND_dot_realitykit_geometry_modifier` | `in` (vertex), `note` | vertex (pass-through "dot" node for vertex wires) |

Deprecated (read-only) property nodes, one output each:
`ND_realitykit_surface_{uv0,uv1,color,time,model_position,world_position,
geometry_normal,geometry_tangent,geometry_bitangent,tangent_space_normal}`
and `ND_realitykit_geometry_modifier_{position,normal,bitangent,color,uv0,
uv1,time}`. The Xcode library marks a further set as unsupported
(`…_material_parameters_*`, `…_surface_{base_color,emissive_color,
roughness,metallic,specular,opacity,clearcoat,clearcoat_roughness,
ambient_occlusion,custom_parameter}`, `…_geometry_modifier_{*_offset,
*_transform,custom_parameter,custom_attribute*}`, `curveadjust`,
`curvelookup`): Ycode's editor does not offer them.

## 9. Node families beyond the table

| Family | Id pattern | Count (Xcode 27.1 library) | Source of truth for Ycode |
|---|---|---|---|
| Standard MaterialX 1.38/1.39 stdlib, pbrlib, bxdf | `ND_<node>_<type>` | ~780 | MaterialX open source (Apache-2.0). Apple adds four overrides of `position`, `normal`, `tangent`, `bitangent` (vector3) for 1.39. |
| Half-precision variants | `ND_<node>_half[2-4]`, some with `_v2` suffix | 247 | Same interfaces as the float version with `half` types. |
| Swizzle (removed from MaterialX 1.39, kept by Apple) | `ND_swizzle_<in>_<out>`, input `in`, uniform string `channels` | 61 | The reference template uses `ND_swizzle_color4_color3` with `channels = "rgb"`. |
| Integer vectors, `matrix22` | `ND_*_integer{2,3,4}`, `ND_*_matrix22`, `ND_texcoord_vector4` | 25 | |
| Comparison with half/boolean results | `ND_if{greater,greatereq,equal}_<t>[H|B…]` | ~70 | |
| Metal intrinsics | `ND_MTL_<function>_<type>` (e.g. `ND_MTL_fma_float`, `ND_MTL_simd_sum_float`, `ND_MTL_quad_shuffle_up_*`) | ~700 | nodegroups `math`, `realitykit`, `realitykit_private` |
| Bitwise | `ND_MTL_bitwise_{and,or,xor,not}_*`, shifts, rotates | ~50 | |
| Internal | `ND_INTERNAL_realitykit_*`, `ND_InternalRealityKitTexture*` | ~70 | Never written by Ycode. |

Apple publishes its node-definition files under the MIT licence in the
open-source repository `apple/plugins-for-godot` (folder
`godotrealitykit/GodotRealityKit/Materials/NodeDefs`, files `apple_defs`,
`apple_image_nodedefs`, `apple_image_nodedefs_old`, `apple_image_info_nodedefs`,
`apple_metal_nodedefs`, `apple_stdlib_extensions`, `apple_light_spill_defs`,
`apple_defs_cameraindex`, `apple_bitwise_operations`,
`apple_comparison_node_extensions`, plus MaterialX `stdlib_defs`,
`stdlib_ng`, `usd_preview_surface`). Of 170 public RealityKit nodedefs in
Xcode's library, 156 are in that repository; the 14 missing are
`ND_realitykit_pbr_surfaceshader_2_0`, `…_barycentric_vector3`,
`…_hair_surfaceshader`, `…_lighting_color`, `…_portal_geometry_modifier`,
`…_portal_surface_shader`, `…_post_lighting_surfaceshader` and the seven
`…_surface_custom_attribute*` nodes; their interfaces are in this file.
**Clean rounds take node definitions from that repository and from MaterialX,
not from this table**, and use this file for what is missing there.

## 10. Reality Composer Pro 3.0's native graph storage

Reality Composer Pro 3.0 keeps materials in its own project format
(`project-format.md`), not in USD. Its material asset is a text object of
type `tm_material` with a `shader_graph.graph` holding `nodes` (each with a
UUID, a `type` string that is the MaterialX nodedef name, e.g.
`ND_UsdPreviewSurface_surfaceshader`, or `tm_output_node` for the output box,
a `position {x, y}`, an optional `width`, `label` and per-input `data`),
`connections` (`from_node`, `to_node` as UUIDs; `from_connector_hash`,
`to_connector_hash`), and an `interface.outputs` list (`name` `surface` /
`vertex`, `id` `output__surface__0` / `output__vertex__1`, `type_hash`,
`order`). The connector hashes are MurmurHash64A (seed 0) of the connector
id string printed as 16 hex digits: `out` → `685a9889b8402b60`,
`output__surface__0` → `c324f3a437be79e3` (verified by recomputation, level
2). `type_hash` is MurmurHash64A (seed 0) of a **type name**, printed as 16
hex digits: the outputs use `sg_surface_shader` (`c3f642cf65c817b8`) and
`sg_geometry_modifier` (`84dbff90ce229699`); graph inputs in the core
library use `tm_float`, `tm_bool`, `tm_uint32_t`, `tm_vec2_t`, `tm_vec3_t`,
`tm_color_aces2065_rgb`, `tm_color_aces2065_rgba` and resource types
(verified by recomputation; the two `sg_*` names were found among the
library's name strings, level 4 → 2). Sub-graphs are objects of type
`tm_material_shader_graph_subgraph`. This matters only for importing RCP 3
projects directly; the USD encoding above is the interchange format.

### 10.1 A material made in the app (OBS-RCP4)

The owner's material (an imported PNG on a cube, made in RCP 3.0) is a
`tm_material` with an **empty** `shader` (no definition path: a pure graph
material) and a graph of three nodes: `tm_output_node`, `ND_image_color3`
(the standard MaterialX image node, not a `RealityKitTexture2D` node) and
`ND_UsdPreviewSurface_surfaceshader`. Connections: image `out` →
`diffuseColor`; surface `out` → `output__surface__0`. The texture is not a
connection but a graph **data** entry on the image node's `file` connector:
`{ to_node, to_connector_hash = hash("file"), data: { __type:
"tm_material_resource", resource: <texture __uuid>, resource__type:
"tm_texture" } }`. Node `position`s are graph-editor coordinates; a node
may carry `width`. The interface lists the two standard outputs with
`display_name`s `Surface Shader` and `Geometry Modifier`.

Promoted parameters belong in the graph's `interface.inputs`
(`tm_graph_input`: `name`, `display_name`, `id`, `type_hash`,
`edit_type_hash`, `value_set_by_user`, `value`, `tooltip`, `public`,
`order`, `metadata`) — names from the type index; the sample had none, so
an instance was not observed.

Exported to `.reality` headless (`compile.md` §6.9) and loaded on macOS,
this material is a `ShaderGraphMaterial` named after the asset, with
**one parameter** that nobody promoted: `rcp_<decimal number>` (one
`rcp_` name, stable across five exports of the same project) holding the
256×256 texture. The exporter therefore exposes graph data (here the
texture) as material parameters under generated names. The number looks
like a packed pair of small engine ids, not a hash; Ycode treats such
names as opaque, never generates them, and maps them back to the node
input on import only by position in the graph.

## 11. Rules for Ycode's editor

Writing:

1. One `Material` prim per material; surface node connected to
   `outputs:mtlx:surface`; geometry modifier, if any, to
   `outputs:realitykit:vertex`. Do not author `outputs:surface` unless the
   material is a plain `UsdPreviewSurface` network.
2. `info:id` = nodedef name from the public node set (§9); surface nodes from
   §5.1–5.2 by default.
3. Promoted parameters as Material `inputs:*`; textures as `asset` promoted
   parameters connected to `RealityKitTexture2D` `file` inputs; asset paths
   relative to the authoring layer.
4. Write `ui:nodegraph:node:pos/size/stackingOrder` and
   `ui:nodegraph:realitykit:subgraphOutputs:pos/size/stackingOrder` so node
   layout survives a round trip; write `colorSpace` with USD tokens.
5. Never emit empty strings in `nameChildren` reorder lists.

Reading: accept everything in §2–§9, including deprecated ids, OCIO colour
space names, `_v2` (as `_2_0`), `references = None`, `.connect = None`, and
inputs declared without values. Report unknown ids as warnings (§5.5).

## 12. Open questions

- Q1. **Partly answered.** RCP 3.0's *USDA (Mesh)* export writes no
  MaterialX nodes at all: a graph material became a flat
  `UsdPreviewSurface` with black diffuse and opacity 0, and the texture
  was dropped (`scene-usd.md` §5.1). So the export never writes `_v2`.
  Still open: whether its USD **import** reads `_2_0`, and whether the
  USDZ export differs.
- Q2. Which terminal does a post-lighting shader connect to?
- Q3. How the reference editor stores a promoted parameter's position in the
  graph (customData dictionary or `ui:` attributes). RCP 3 cannot answer it
  (its USD export writes no graph); needs an RCP 2-written file. RCP 3's own
  slot for a promoted parameter is `interface.inputs` (§10.1); an instance
  with a value is still unobserved.
- Q4. Why the compiled `UsdPreviewSurface` material reports no base-colour
  texture through the public API.
- Q5. Runtime support of `standard_surface`, `open_pbr_surface`,
  `gltf_pbr` surfaces.
- Q6. **Answered** (§10): MurmurHash64A of a type name.
- Q8. How a texture node's data input becomes a `rcp_<n>` parameter name in
  RCP 3's `.reality` export, and whether user-promoted parameters keep
  their own names there.
- Q7. Whether the reference editor shows deprecated or unsupported nodes when
  it opens a file that uses them.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Material/Shader/NodeGraph grammar, connections, `info:id` = nodedef name, UsdMtlx type mapping | 1 | OpenUSD `UsdShade`, `UsdMtlx` (open source) |
| `ui:nodegraph:node:*` properties | 1 | OpenUSD `UsdUI` NodeGraphNodeAPI schema |
| Reference-written details: `bindMaterialAs`, empty `nameChildren` entries, `references = None`, `.connect = None`, valueless inputs, `subgraphOutputs:*`, `attributesShowingChildren`, OCIO colour-space names, referenced material library layout | 2 | Xcode 27.1 visionOS template USDA files, read as a format study (not copied) |
| Parameter names/types, colour-space conversions, node groups, geometry modifier, texture path resolution, missing-texture behaviour, fallback material, `_v2`/post-lighting not accepted, compile results | 3 | **[mat-probe]**: our USDA under `<samples>/materials/` loaded by a macOS 27 RealityKit probe and compiled with `realitytool compile` (xros and macosx, deployment target 27.0); compiled container read at the JSON-manifest level only |
| Public Apple node definitions | 1 | `apple/plugins-for-godot` (MIT), fetched at commit `d2133518` |
| Node ids, port names, types, defaults, families, deprecated/unsupported sets, RCP 3 vs Xcode differences | 4 | **[nd-iface]**: interface fields parsed from the MaterialX data files shipped in Reality Composer Pro 3.0 and Xcode 27.1 (no implementations, docs or graphs taken) |
| RCP 3 `tm_material` grammar | 2 | RCP 3.0's bundled core project files, read as a format study |
| Connector hash = MurmurHash64A of the connector id | 2 | Recomputation with the public MurmurHash64A algorithm matched the stored values |
| `type_hash` = MurmurHash64A of a type name; `sg_surface_shader`, `sg_geometry_modifier` | 2, 4 | recomputation over every interface entry in an app-made project; the two names found among RCP 3 library strings (OBS-RCP4) |
| App-made material graph, data entry for the texture, `interface.inputs` slot | 2 | owner-made RCP 3 sample read with our parser, type index (OBS-RCP4) |
| Exported material = `ShaderGraphMaterial` with a generated `rcp_<n>` texture parameter | 3 | headless `.reality` export of that sample loaded by our macOS probe (OBS-RCP4) |
| RCP 3 USDA export flattens graph materials | 2 | the owner's USDA export, read as a file format |
