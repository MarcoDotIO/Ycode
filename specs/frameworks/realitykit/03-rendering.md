# RealityKit 3: rendering — materials, meshes, textures, lighting, cameras, Metal

Status: draft round 0. Sources: SDK module metadata and Metal header
accessor names (level 4), public documentation (level 1), probe runs
(level 3; modes **[rv-basic]**, **[rv-mat]**, **[rv-mesh]**, **[rv-tex]**,
**[rv-nocamera]**, **[rv-perf…]**, **[metal-rec]**).

## 1. Conventions

| Topic | Rule | Evidence |
|---|---|---|
| Units | metres | 1 |
| Handedness, up | right-handed, +Y up | 1 (Y-up), 3 (rotation signs, `01-architecture.md` §5) |
| Camera and light direction | along the entity's −Z | 3 |
| Texture coordinates | (0,0) at the bottom-left of the image as displayed; +V is image up. A `CGImage` applied with `UnlitMaterial` to `generatePlane(width:height:)` appeared upright (top row of the image at +Y) **[rv-tex]** | 3 |
| Normal maps | tangent space, OpenGL convention (+Y green up) | 1 |
| Colour | colour textures are sRGB-encoded (`TextureResource` with `.color` semantic became `rgba8Unorm_srgb`), lighting in linear space; HDR colour has its own semantic | 3, 4 |
| Winding / culling | materials cull back faces by default (`faceCulling` default `.back` **[rv-mat]**); front faces are counter-clockwise seen from outside (generated meshes are visible from outside with default culling) | 3 |

## 2. Materials

All materials conform to `Material` and are value types placed in
`ModelComponent.materials` (one per material index of the mesh parts).
Common optional properties (iOS 18 for most): `faceCulling`
(`none`/`front`/`back`), `triangleFillMode` (`fill`/`lines`),
`writesDepth`, `readsDepth`, `name`.

### 2.1 `SimpleMaterial` (iOS 13)

Colour (tint and texture), `roughness`, `metallic` as
`MaterialScalarParameter` (`.float` or `.texture`). Defaults: roughness
1.0, metallic 0.0 **[rv-mat]**. The convenience initialiser
`(color:roughness:isMetallic:)` sets metallic 1 or 0. Rendered as a PBR
material (same model as §2.3).

### 2.2 `UnlitMaterial` (iOS 13)

Colour (tint × texture), `blending`, `opacityThreshold`, texture
coordinate transforms, and whether the post-process tone mapping applies
to it (`applyPostProcessToneMap`, iOS 18; `UnlitMaterial.Program.Descriptor`
holds it with a blend mode). Unlit output ignores lights and shadows (the
blue unlit cylinder in **[rv-basic]** had no shading).

### 2.3 `PhysicallyBasedMaterial` (iOS 15)

Metallic-roughness PBR (the USD "metallic workflow"). Inputs, each a value
times an optional texture (`MaterialParameters.Texture`, sampler, UV set):

| Input | Default **[rv-mat]** | Notes |
|---|---|---|
| `baseColor` (tint + texture) | white | |
| `metallic` | 0.0 | |
| `roughness` | 1.0 | |
| `specular` | 0.5 | dielectric reflectance scale |
| `emissiveColor`, `emissiveIntensity` | black, 1.0 | |
| `clearcoat`, `clearcoatRoughness`, `clearcoatNormal` (18) | 0.0 | second specular lobe |
| `sheen` (`SheenColor`) | none | cloth lobe |
| `anisotropyLevel`, `anisotropyAngle` | 0 | anisotropic GGX |
| `normal` | none | tangent-space map |
| `ambientOcclusion` | none | |
| `blending` | `.opaque` | `.transparent(opacity:)` |
| `opacityThreshold` | nil | alpha cut-out |
| `textureCoordinateTransform`, `secondaryTextureCoordinateTransform` | identity | offset, scale, rotation |
| iOS 27: `subsurfaceWeight`, `subsurfaceColor`, `subsurfaceRadius`, `subsurfaceRadiusScale`, `subsurfaceScatterAnisotropy`, `bentNormal`, `enableSpecularOcclusion` | — | subsurface scattering |

`PhysicallyBasedMaterial.Program` (iOS 18) is a precompiled pipeline
variant keyed by a descriptor (blend mode); creating materials from a
shared program avoids shader compiles.

### 2.4 Other built-in materials

| Material | iOS | Behaviour |
|---|---|---|
| `OcclusionMaterial` | 13 | Writes depth only: hides virtual content behind it and shows the background (or the camera image in AR). In **[rv-mat]** the occlusion sphere showed the view background over the floor. `receivesDynamicLighting` variant draws shadows on it. |
| `VideoMaterial` | 14 | Texture from an `AVPlayer` (or a `VideoRenderer`, 18); exposes `avPlayer` and a `VideoPlaybackController`. |
| `PortalMaterial` | 18 | Marks the surface through which a `PortalComponent` world is drawn; iOS 27 adds a shader-graph program with parameters. Alone (no portal component) it drew nothing **[rv-mat]**. |
| `ShaderGraphMaterial` | 18 | §2.5 |
| `CustomMaterial` | 15 (not visionOS) | §2.6 |
| `LightmapComponent.FinalShadedColorBakeMaterial` | 27 | Used when baking lightmaps |

### 2.5 `ShaderGraphMaterial` (MaterialX)

- Created from a material prim in a USD file (`init(named:from:in:)` with a
  prim path such as `/Root/Material`, and a file in a bundle or at a URL),
  or from MaterialX data (`init(materialXLabel:data:)`), or (iOS 27) from a
  `Program` whose descriptor holds a shader graph, a `LightingModel`, blend
  mode, dithering, input and constant values.
- The material's **interface inputs** (USD `inputs:` on the Material prim)
  become parameters: `parameterNames`, `setParameter(name:value:)`,
  `getParameter`, and the faster `parameterHandle(name:)`.
  `MaterialParameters.Value` cases: float, simd2/3/4, color, float2x2/3x3/
  4x4, bool, int, texture resource.
- Errors: `LoadError` (`invalidTypeFound`, `materialNameNotFound`,
  `invalidURL`, `resourceShareFailed`), `Error` (`parameterNameNotFound`,
  `incorrectTypeForParameterName`).
- Observed **[rv-mat]**: our hand-written USD material with one interface
  input `Tint` connected to a MaterialX `ND_UsdPreviewSurface_surfaceshader`
  node via `outputs:mtlx:surface` loaded; `parameterNames == ["Tint"]`.
- Node catalogue: Apple's ShaderGraph documentation lists MaterialX 1.38
  standard nodes plus RealityKit nodes whose node-definition names follow
  `ND_realitykit_…` (for example `ND_realitykit_pbr_surfaceshader`, "PBR
  Surface (RealityKit)" with inputs base colour, emissive colour, normal,
  roughness, metallic, ambient occlusion, specular, opacity, opacity
  threshold, clearcoat, clearcoat roughness, clearcoat normal, premultiplied
  alpha flag). Other RealityKit nodes: unlit, hair, occlusion and
  shadow-receiving occlusion surfaces; geometry modifier; camera position,
  view direction, screen position; model/world/view/projection matrices
  for the surface and geometry stages; vertex ID; environment radiance;
  reflection diffuse/specular; hover state; blurred background; camera
  index switch (per eye); image samplers (2D, 2D array, 3D, cube) with
  LOD/gradient/pixel variants and direct reads; derivative and IEEE
  classification helpers. Groups: 2D/3D procedural, 2D/3D texture,
  adjustment, application, compositing, data, geometric, logic, material,
  math, organisation, procedural, RealityKit, surface.
- Implementation plan: translate MaterialX graphs to our shading language
  with the open MaterialX library (`09-open-design.md` §3.3), plus our own
  implementations of the `ND_realitykit_*` nodes from their documented
  inputs and outputs.

### 2.6 `CustomMaterial` and the Metal shader API

- A `CustomMaterial` combines a **surface shader** and/or a **geometry
  modifier** — Metal functions marked `[[visible]]` in the app's Metal
  library, found by name (`CustomMaterial.SurfaceShader(named:in:)`,
  `GeometryModifier(named:in:)`, with function constant values in 18) — with
  a lighting model (`lit`, `unlit`, `clearcoat`) or with a base material
  (`init(from:surfaceShader:geometryModifier:)`). It carries the same
  PBR-style inputs as §2.3 plus a `custom` value/texture slot, and uniforms
  (`withMutableUniforms(ofType:stage:)`, iOS 18).
- Errors: `CustomMaterialError.geometryModifierFunctionNotFound`,
  `.surfaceShaderFunctionNotFound`, `.defaultSurfaceShaderForMaterialNotFound`.
- Shader API (names from the SDK headers `RealityKitSurfaceShader.h`,
  `RealityKitGeometryModifier.h`; level 4): namespace `realitykit`.
  A surface function receives `surface_parameters` with accessors
  `geometry()` (position in model/world space, normal, tangent, bitangent,
  `uv0`…`uv7`, colour, view direction, screen position, custom attribute),
  `uniforms()` (time, matrices), `material_constants()` (base colour tint,
  roughness/metallic/… scales, custom parameter), `textures()`, `lighting()`
  (environment radiance), and `surface()` with setters `set_base_color`,
  `set_emissive_color`, `set_normal`, `set_roughness`, `set_metallic`,
  `set_ambient_occlusion`, `set_specular`, `set_opacity`, `set_clearcoat`,
  `set_clearcoat_roughness`, `set_clearcoat_normal`. A geometry modifier
  receives `geometry_parameters` with `geometry()` (vertex ID, instance ID,
  model position, normal, UVs, colour, custom attribute) and setters
  `set_model_position_offset`, `set_world_position_offset`, `set_normal`,
  `set_uv0…7`, `set_color`, `set_custom_attribute`, plus `uniforms()`.
  Both have `hover_state` accessors (visionOS hover).
- **Observed in the simulator** **[rv-mat]**: both kinds compiled from our
  own `.metal` file (built with `xcrun -sdk iphonesimulator metal`) created
  without error and rendered correctly (stripes from `uv0`; vertices offset
  by a sine of `model_position` and time). `supportsMutableUniformsResources`
  was false in the simulator.
- For Ycode this is the hardest material: the app's AIR for the visible
  functions must be linked with the renderer's own shader skeleton
  (`09-open-design.md` §3.4).

### 2.7 Material parameters, textures and samplers

`MaterialParameters.Texture` = `TextureResource` + `Sampler` (wraps an
`MTLSamplerDescriptor`) + UV index (+ swizzle, 18).
`MaterialParameterTypes`: `FaceCulling`, `TextureCoordinateTransform`
(offset, scale, rotation), `TriangleFillMode`, `BlendMode` (`alpha`,
`add`, 18). iOS 27 `LightingModel`: `.lit(LitLightingModel)` with diffuse
model `hammon`/`lambertian`/`orenNayar`, specular model `ggx`/`blinnPhong`/
`sheen`/`anisotropicGGX` and flags for subsurface, multiscattering, bent
normals, clearcoat; `.hair`; `.unlit(isTonemappingEnabled:)`.

## 3. Meshes

### 3.1 `MeshResource`

- Contents (iOS 15): `models` (each with `parts`: positions, normals,
  tangents, bitangents, texture coordinates, triangle indices, material
  index, custom buffers, joint influences and skeleton ID from 18),
  `instances` (model reference + transform), `skeletons` (18).
  `MeshBuffers` semantics include `uv2`…`uv7` and
  `textureCoordinates1…7` (27), blend-shape offsets (18), joint influences
  (18). Rates: vertex, face, faceVarying.
- `bounds`, `expectedMaterialCount`, `replace(with:)` (contents swap),
  `lowLevelMesh` (18).
- Generated from `MeshDescriptor`s (`generate(from:)` / `init(from:)`):
  positions plus optional normals, tangents, UVs, primitives
  `triangles`, `polygons(counts, indices)` (triangulated), or
  `trianglesAndQuads`; materials `allFaces(index)` or `perFace`.
  Observed **[rv-mesh]**: a triangle descriptor without normals got normals
  generated (and no UVs); a 4-vertex polygon became 2 triangles.

### 3.2 Generators (observed tessellation, **[rv-mesh]**)

These numbers are what Apple's generators produce in iOS 27.1; matching
them is not required for correctness but our generators should produce
the same bounds, the same part/material layout and comparable density.

| Call | Bounds | Parts | Vertices | Triangles | Notes |
|---|---|---|---|---|---|
| `generateBox(size: 0.2)` | ±0.1 | 1 | 24 | 12 | per-face vertices, normals, UVs |
| `generateBox(size: 0.2, cornerRadius: 0.02)` | ±0.1 | 1 | 6936 | 13068 | rounded |
| `generateBox(width:height:depth:cornerRadius:0, splitFaces: true)` | ±0.1 | **6** | 24 | 12 | `expectedMaterialCount == 6`, one part per face |
| `generateSphere(radius: 0.1)` | ±0.1 | 1 | 4223 | 8064 | UV sphere, 64 segments × 64 rings (8064 = 2·64·63) |
| `generatePlane(width: 0.4, height: 0.2)` | x ±0.2, y ±0.1, z 0 | 1 | 4 | 2 | XY plane facing +Z |
| `generatePlane(width: 0.4, depth: 0.2)` | x ±0.2, y 0, z ±0.1 | 1 | 4 | 2 | XZ plane facing +Y |
| `generateCone(height: 0.2, radius: 0.1)` (18) | ±0.1 | 1 | 194 | 128 | centred on its bounding box; 64 segments |
| `generateCylinder(height: 0.2, radius: 0.1)` (18) | ±0.1 | 1 | 260 | 256 | centred; 64 segments, capped |
| `generateText("RK", extrusionDepth: 0.02, font: system 0.1)` | x 0.009…0.132, y 0.024…0.095, z ±0.01 | 1 | 766 | 692 | extrusion centred on z = 0; origin at the left of the text frame, below the baseline |

All generated meshes have normals and UVs. iOS 18 adds rounded boxes with
separate major/minor radii, `MeshResource(shape:)` and
`MeshResource(extruding:textOptions:extrusionOptions:)` for `Path`s and
`AttributedString`s (extrusion method, chamfers, per-face material
assignment).

### 3.3 `LowLevelMesh` (iOS 18)

GPU-friendly mesh with an explicit layout: `Descriptor` with
`vertexAttributes` (semantic `position`, `color`, `normal`, `tangent`,
`bitangent`, `uv0…uv7`, `unspecified`; `MTLVertexFormat`; layout index;
offset), `vertexLayouts` (buffer index, offset, stride; iOS 27 step
function and rate for instancing), `vertexCapacity`, `indexCapacity`,
`indexType`, up to `maxVertexBufferCount` buffers; iOS 27 adds instance
capacity and primitive restart. `parts` (index offset, count, topology,
material index, bounds). Access through `withUnsafe(Mutable)Bytes`,
`replace(bufferIndex:using:)` (a Metal command buffer writes the buffer on
the GPU). A `MeshResource(from: lowLevelMesh)` renders it **[rv-mesh]**.
Companions: `LowLevelTexture` (18), `LowLevelBuffer` (26),
`LowLevelInstanceData`, `LowLevelDeviceResource` (27, IOSurface-backed).

## 4. Textures and environments

- `TextureResource` (iOS 13; most initialisers 18): from a `CGImage`, a
  named asset, a file URL, raw `dimensions` + `format` + `contents`
  (mip levels, slices), `LowLevelTexture`, 2D arrays, cubes (also from an
  equirectangular image), 3D textures. Properties: `width`, `height`,
  `depth`, `mipmapLevelCount`, `pixelFormat`, `textureType`,
  `arrayLength`, `semantic`. `replace(withImage:)`, `copy(to:)`.
- `CreateOptions`: `semantic` (`raw`, `scalar`, `color`, `hdrColor`,
  `normal`), `mipmapsMode` (`none`, `allocateAll`,
  `allocateAndGenerateAll`), `compression` (18: none, default, ASTC block
  size and quality).
- Observed **[rv-tex]**: a 64×32 sRGB `CGImage`, semantic `.color`,
  default options → `MTLPixelFormat` 71 (`rgba8Unorm_srgb`), 2D, **7 mip
  levels** (full chain allocated and generated by default); semantic
  `.raw` → 70 (`rgba8Unorm`).
- `DrawableQueue` (15): a swap chain of drawables that replaces a texture's
  contents each frame (created fine in the simulator).
- `EnvironmentResource`: image-based lighting environment (specular
  cube with mips plus diffuse data, optional skybox). From a named
  `.skybox` folder/asset, an equirectangular `CGImage` (18), a cube
  texture (18), or explicit skybox/specular/diffuse textures (27).
  Observed **[rv-tex]**: creating one from a 128×64 `CGImage` succeeded and
  exposed a skybox texture; as an `ImageBasedLightComponent` source it
  tinted the scene.

## 5. Lights, shadows, image-based lighting

- Lights: directional (lux), point and spot (lumens) with physical
  attenuation radius and falloff exponent; defaults in `02-components.md`
  §3. Lights in USD files are ignored by RealityKit (Apple's USD feature
  table, level 1).
- Shadows: directional and spot lights cast shadow maps when the
  `Shadow` component is present (**[rv-basic]**: soft shadows of all three
  objects on the floor). iOS 18 adds fixed/automatic shadow projections;
  iOS 27 cascades, light size and quality. Grounding shadows are a
  separate mechanism (`GroundingShadowComponent`, ARView's grounding
  shadow option).
- Default lighting: with no IBL component a non-AR scene is still lit by
  a default environment (the metallic sphere in **[rv-basic]** reflects a
  neutral studio-like environment). In AR, lighting comes from ARKit light
  estimation and environment texturing unless disabled.
- IBL: `ImageBasedLightComponent` on a source entity +
  `ImageBasedLightReceiverComponent` on receivers; `intensityExponent` is a
  power of two (EV-like). `RealityRenderer.lighting` sets a renderer-wide
  IBL.

## 6. Cameras and projection

- An entity with `PerspectiveCameraComponent` in the scene becomes the
  view camera in `RealityView` and in non-AR `ARView` **[rv-basic]**,
  **[arview-nonar]**. The field of view is measured along the axis named by
  `fieldOfViewOrientation` (default vertical): with fov 60° the focal length
  was 587.2 points for a 678-point-high view (339 / tan 30° = 587.2).
- Without a camera entity the default virtual camera stands at
  **(0, 0, 2) looking down −Z** **[rv-nocamera]**, **[arview-ar]**. Its focal
  length was 532.1 points for a 466 × 678-point view (vertical FOV ≈ 64.9°,
  horizontal ≈ 47.3°); the rule that produces this value is open
  (`10-plan.md` open questions).
- `RealityView` on iOS: `realityViewCameraControls(.orbit/.pan/.tilt/.dolly)`
  (`CameraControls`) lets the user move the virtual camera.
- Backgrounds: `RealityView` draws over the SwiftUI background (white in
  light mode) **[rv-basic]**; non-AR `ARView` uses
  `environment.background` (colour or skybox); `ARView` in AR mode uses the
  camera feed (black in the simulator, `08-simulator-baseline.md`).
- Projection helpers: `ARView.project`, `unproject`, `ray(through:)`;
  `RealityViewCameraContent.project(point:to:)`, `unproject`, `ray`,
  `entity(at:)`, `entities(at:)`, `hitTest`.

## 7. Render features and post-processing

- Antialiasing: `AntialiasingMode` `.none`, `.multisample4X`
  (`RealityRenderer.CameraSettings.antialiasing`,
  `RealityViewRenderingEffects.antialiasing`).
- Tone mapping is on by default (`RealityRenderer.cameraSettings
  .isToneMappingEnabled`, `UnlitMaterial` opt-out); iOS 27 makes the curve
  configurable (`ToneMappingComponent`).
- `ARView.RenderOptions` (opt-outs): camera grain, grounding shadows,
  motion blur, depth of field, HDR, person occlusion, AR environment
  lighting, face mesh. The system disables some automatically depending on
  the GPU (documentation); the default value observed in the simulator is
  in `08-simulator-baseline.md`.
- `RealityViewRenderingEffects` (iOS 18): motion blur, depth of field,
  camera grain, antialiasing, dynamic range, custom post-processing (26).
- Custom post-processing: `ARView.renderCallbacks.postProcess` (15) and
  the `PostProcessEffect` protocol (26) receive a context with the Metal
  device, command buffer, source colour and depth textures, target colour
  texture, projection matrix and time; the callback encodes its own GPU
  work.

## 8. Frame pacing

- Documentation: rendering is typically capped at 60 fps (16.6 ms per
  frame for main thread, render thread and GPU).
- Observed in the simulator: 55–60 `SceneEvents.Update` per second for
  simple scenes **[rv-basic]**, about 59 with 1000 boxes and 29 with 5000
  boxes **[rv-perf1000]**, **[rv-perf5000]** (host heavily loaded, see
  `08-simulator-baseline.md`). `deltaTime` is the wall time between updates
  and is **not clamped** (0.477 s seen after a stall **[rv-anim]**); the
  first frames after creation are irregular (0.03, 0.1 s).

## 9. Metal requirements (for Ycode's Metal → Vulkan layer)

- In the iOS simulator RealityKit renders on the simulator GPU device
  "Apple iOS simulator GPU", which reports only the `apple1`, `apple2` and
  `common1` families, argument-buffer tier 0, read-write texture tier 0, no
  ray tracing, 512 threads per threadgroup, 256 MiB maximum buffer, 4×
  MSAA supported **[all modes]**. So RealityKit's iOS renderer runs on a
  minimal feature profile; Ycode's host does not need higher tiers for
  parity.
- What RealityKit submits through the simulator Metal protocol
  (`specs/simulator/metal-sim-protocol.md`) for our scenes:
  see `08-simulator-baseline.md` §6 **[metal-rec]**.
- `Scene.commandQueue` (27), `RealityRenderer` (Metal textures in,
  `MTLEvent` wait/signal actions), `LowLevelMesh/Texture.replace(using:)`
  (app command buffers), post-process callbacks and custom materials all
  expose Metal objects to the app: an implementation on Vulkan must still
  present Metal-shaped objects (through Ycode's Metal layer) on these APIs.

## 10. Performance guidance (documentation, level 1)

- Textures on iPhone/iPad rarely need more than 2048 px per side;
  power-of-two sizes are most efficient; uncompressed memory ≈ channels ×
  width × height × 4/3 (mips are generated automatically).
- Transparency costs one fragment pass per overlapping layer; lights and
  shadows add fragment work; skeletal deformation runs on the GPU.
- Depth of field and motion blur are the most expensive effects;
  `contentScaleFactor` can be lowered to reduce resolution.
- USD subdivision multiplies triangles by 4 per level; `subdivisionScheme`
  defaults to Catmull–Clark in USD, so assets should set `none`.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Material, mesh, texture API names and availability | 4 | SDK `.swiftinterface` |
| Metal shader accessor names | 4 | SDK headers `RealityKitSurfaceShader.h`, `RealityKitGeometryModifier.h` (names only) |
| Units, Y-up, OpenGL normal maps, USD lights ignored, subdivision default | 1 | developer.apple.com "Creating USD files for Apple devices", "Validating feature support for USD files" |
| ShaderGraph node names, MaterialX 1.38, PBR Surface inputs | 1 | developer.apple.com ShaderGraph documentation |
| Performance guidance | 1 | developer.apple.com "Improving the Performance of a RealityKit App", "Reducing GPU Utilization…" |
| Material defaults, custom materials and shader-graph material in the simulator | 3 | **[rv-mat]** |
| Tessellation table, descriptor behaviour, LowLevelMesh | 3 | **[rv-mesh]** |
| Texture pixel formats and mip counts, IBL from CGImage | 3 | **[rv-tex]** |
| Camera rules, default camera | 3 | **[rv-basic]**, **[rv-nocamera]**, **[arview-…]** |
| Frame pacing | 1, 3 | documentation; **[rv-…]** frame counters |
| Simulator GPU feature profile | 3 | `MTLDevice` queries in every mode |
