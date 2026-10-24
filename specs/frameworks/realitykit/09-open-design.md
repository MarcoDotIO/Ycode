# RealityKit 9: design note for an open implementation

> **Ycode-original design note.** This file is not a description of
> Apple's implementation. It proposes how Ycode builds a
> RealityKit-compatible library ("OpenReality" below, working name) from
> the behaviour in files 01–08 and from permissively licensed open source.
> Nothing here comes from Apple binaries.

Status: proposal, round 0 (KIT-REALITYKIT, 2026-10-19).

## 1. Two different consumers

1. **The Ycode iOS simulator.** A guest app runs Apple's own RealityKit
   from the iOS runtime image. Ycode does **not** reimplement RealityKit
   for this; it must provide what that RealityKit needs from the host:
   the Metal host protocol with the features listed in
   `08-simulator-baseline.md` §6 (texture views, fences, heaps, argument
   encoders, events, cube/3D/multisample textures, vertex-stage
   textures, five undescribed record opcodes), audio output, and later
   AR inputs (camera frames, poses — KIT-ARKIT). This is work for the
   simulator track (stage 8 follow-ups), not for this library.
2. **Swift apps on Linux** (and the long-term visionOS-like environment of
   `docs/FUTURE.md`). They need a library with RealityKit's API and
   behaviour that runs on Linux with Vulkan. This file is about that
   library.

## 2. Architecture

```
            RealityView-like host (SwiftUI-less)   RealityRenderer (headless)
                          \                         /
   ┌──────────────────────────── OpenReality (Swift) ────────────────────────────┐
   │ ECS core: Entity, ComponentSet, Scene, events, systems, queries, transforms  │
   │ Resources: MeshResource, TextureResource, materials, shapes, animations,     │
   │            audio resources, environments                                     │
   │ Built-in systems (fixed order): input → user systems (topological) →         │
   │   animation → physics (fixed 1/60 s steps) → transforms → audio → render     │
   └─────┬───────────────┬────────────────┬────────────────┬──────────────┬──────┘
         │ physics        │ assets          │ rendering       │ audio         │ nav
      Jolt (MIT)     OpenUSD (TOST) or   Vulkan renderer   miniaudio      Recast/Detour
                     tinyusdz (Apache);  (own, Swift+C)    (PD/MIT-0) +   (zlib)
                     MaterialX (Apache)  or Filament       Steam Audio
                     OpenSubdiv (TOST)   (Apache-2.0)      (Apache-2.0)
```

Language: Swift 6 (the public API is Swift), with C/C++ libraries through
Swift's C++ interoperability. The module is named `RealityKit` so
unchanged app sources build; `RealityFoundation` is a re-exporting alias.

### 2.1 ECS core (Ycode-original)

- Entities are classes (identity, hierarchy) holding a small
  `ComponentSet`: a dictionary from component type identifier to an
  existential box, with insertion order kept (event order depends on it,
  `01-architecture.md` §4.2). Sparse-set or archetype storage (as in EnTT
  or flecs, both MIT) is an internal optimisation for queries, added in a
  later round behind the same API.
- Events are delivered synchronously inside mutating calls, in exactly
  the order of `01-architecture.md` §4.2; scene-wide subscriptions see
  per-entity duplicates (collision events) as Apple's do.
- Systems: one instance per scene, created on first scene update in
  topological order of `dependencies`, ties broken by registration order.
  `SceneEvents.Update` is posted before systems; built-in animation is
  evaluated after user systems (`05-animation-audio.md` §3, item 2).
- Transforms: `simd`-compatible types (Swift `SIMD` on Linux; a small
  `simd_quatf` shim), T·R·S, right-handed, Y-up, metres.

### 2.2 Physics

**Jolt Physics (MIT)**: deterministic, fixed-step, convex hulls, triangle
meshes, capsules, compound shapes, all needed joint types (fixed,
point/cone, hinge, slider, distance, six-DOF), a virtual character
controller, sensors (triggers) and contact listeners. Adaptations:
step 1/60 s with a semi-implicit Euler integrator (Jolt's default
integration is of this kind; to be verified against
`04-physics.md` §5 numbers), restitution and friction combined by
**average** (Jolt lets the application set the combine functions),
damping semantics matched by test, collision filter = group/mask
bitmasks. Alternatives: PhysX 5 (BSD-3-Clause; averages by default but
large), Bullet (zlib; older).

### 2.3 Assets and materials

- **OpenUSD** (Tomorrow Open Source Technology License 1.0 = Apache-2.0
  with a modified trademark section; permissive) for full USD
  composition, USDZ and the USDKit-shaped API. **tinyusdz** (Apache-2.0)
  is a lighter reader for round 2; switch to OpenUSD when composition
  (references, variants, payloads) matters (round 6).
- **MaterialX** (Apache-2.0): parse `ShaderGraphMaterial` networks and
  generate GLSL/SPIR-V with its shader generators; implement the
  `ND_realitykit_*` nodes ourselves from their documented inputs and
  outputs.
- **OpenSubdiv** (TOST 1.0): USD subdivision and the subdivision deformer.
- Textures: libpng (libpng licence), libjpeg-turbo (BSD-style/IJG),
  libavif (BSD-2-Clause), OpenEXR (BSD-3-Clause); KTX-Software
  (Apache-2.0), astc-encoder (Apache-2.0), basis_universal (Apache-2.0)
  for compressed textures; mip generation ourselves.
- Mesh utilities: meshoptimizer (MIT), MikkTSpace (zlib-style) for
  tangents, earcut.hpp (ISC) for polygon triangulation.
- Text meshes (`generateText`, extrusion): HarfBuzz ("Old MIT") for
  shaping, FreeType under its FreeType License (FTL, BSD-style; FreeType
  is dual-licensed and we choose FTL, never the GPLv2 option), earcut
  for triangulation.

### 2.4 Rendering on Vulkan

- Option A (recommended for speed): **Filament** (Apache-2.0) as the
  renderer core — physically based (metallic-roughness, clearcoat, sheen,
  anisotropy), IBL from cube maps, directional/point/spot lights with
  shadows, MSAA, tone mapping, Vulkan backend. OpenReality maps
  components to Filament entities. Risk: Filament's material system must
  host MaterialX-generated and custom shaders.
- Option B: our own Swift renderer on Vulkan (volk, MIT;
  VulkanMemoryAllocator, MIT; Vulkan headers Apache-2.0/MIT) implementing
  exactly RealityKit's model: HDR RGBA16Float colour, 4× MSAA,
  Depth32Float_Stencil8, cube-map IBL, tone mapping to an 8-bit sRGB
  output (`08-simulator-baseline.md` §6 shows Apple's pipeline has this
  shape). Slower to build, full control.
- Shading language: GLSL or Slang (Apache-2.0 with LLVM exception)
  compiled to SPIR-V; shaderc (Apache-2.0) at runtime for generated
  material variants. glslang's licence is a mix of BSD-3-Clause, MIT and
  Apache-2.0 per file and must be checked per file before vendoring.
- `CustomMaterial` (Metal functions): Linux has no Metal compiler. Accept
  a precompiled `.metallib` produced on macOS and translate its AIR with
  Ycode's existing AIR→SPIR-V translator (`specs/simulator/
  metal-shaders.md`, `ycode-airc`), linking the visible functions into
  our own surface/geometry skeleton that provides the
  `realitykit::surface_parameters`/`geometry_parameters` API as SPIR-V
  functions. A Linux-native alternative (Slang source with the same API
  names) can follow.
- Metal-shaped APIs (`LowLevelMesh.replace(using:)`, `RealityRenderer`
  textures, post-process contexts, `Scene.commandQueue`) are bridged to
  Vulkan objects through Ycode's Metal-on-Vulkan layer where it exists,
  or offered as Vulkan-typed equivalents on Linux (documented
  difference).

### 2.5 Animation, audio, navigation

- Skeletal sampling and blending: **ozz-animation** (MIT); our own code
  for `FromToByAnimation`, `SampledAnimation`, blend trees, timing
  functions and the event semantics of `05-animation-audio.md` §3.
- Audio: **miniaudio** (public domain or MIT-0, user's choice) for output
  and decoding; **Steam Audio** (Apache-2.0) or **Resonance Audio**
  (Apache-2.0) for spatialisation, reverb and (27) geometric reverb.
  OpenAL Soft is LGPL-2 and is not used.
- Navigation meshes: **Recast/Detour** (zlib), whose parameters are those
  of `NavigationMeshResource.Configuration` (`04-physics.md` §10).

### 2.6 Views on Linux

There is no SwiftUI or UIKit on Linux. Provide (a) `RealityRenderer` first
(headless, textures out — also the conformance harness), (b) a
`RealityView`-shaped host over a window from SDL3 or GLFW (both zlib) with
the same `make`/`update` closures and `RealityViewCameraContent` API, and
(c) an `ARView` shim only for source compatibility (non-AR mode).

## 3. Licence summary (verified 2026-10-19)

Verification: GitHub's licence detection (`gh api repos/<repo>/license`)
and, where it reported no SPDX identifier, the licence file's own text.

| Project | Licence | Use |
|---|---|---|
| OpenUSD (PixarAnimationStudios/OpenUSD) | TOST 1.0 (Apache-2.0, modified §6 trademarks) | USD |
| tinyusdz (lighttransport) | Apache-2.0 | light USD reader |
| MaterialX (ASWF) | Apache-2.0 | shader graphs |
| OpenSubdiv (Pixar) | TOST 1.0 | subdivision |
| Jolt Physics | MIT | physics |
| PhysX 5 (NVIDIA-Omniverse) | BSD-3-Clause | alternative physics |
| Bullet3 | zlib (except `Extras`, third-party examples) | alternative physics |
| Recast/Detour | zlib | navigation |
| ozz-animation | MIT | skeletal animation |
| EnTT | MIT | ECS ideas/storage |
| flecs | MIT | ECS ideas/storage |
| meshoptimizer | MIT | mesh processing |
| MikkTSpace | zlib-style notice | tangents |
| earcut.hpp | ISC | triangulation |
| libtess2 | SGI Free Software License B 2.0 (permissive) | alternative triangulation |
| HarfBuzz | Old MIT | text shaping |
| FreeType | FTL or GPLv2 (we use FTL) | glyph outlines |
| Filament | Apache-2.0 | renderer option A |
| Vulkan-Headers | Apache-2.0 or MIT per file | Vulkan |
| Vulkan-Loader | Apache-2.0 (some files more permissive) | Vulkan |
| volk | MIT | Vulkan loader |
| VulkanMemoryAllocator | MIT | GPU memory |
| SPIRV-Tools, SPIRV-Cross | Apache-2.0 | shader tooling |
| shaderc | Apache-2.0 | runtime shader compile |
| glslang | mixed BSD-3/MIT/Apache-2.0 (check per file) | GLSL front end |
| Slang | Apache-2.0 WITH LLVM-exception | shader language option |
| KTX-Software | Apache-2.0 | KTX textures |
| astc-encoder | Apache-2.0 | ASTC |
| basis_universal | Apache-2.0 | supercompressed textures |
| libavif | BSD-2-Clause | AVIF |
| OpenEXR | BSD-3-Clause | EXR |
| oneTBB | Apache-2.0 | OpenUSD dependency |
| miniaudio | Public domain or MIT-0 | audio I/O |
| Steam Audio | Apache-2.0 | spatial audio |
| Resonance Audio | Apache-2.0 | spatial audio |
| SDL3, GLFW | zlib | windows, input |
| lzfse | BSD-3-Clause | not needed (only `.reality` payloads use it) |
| **Not usable** | OpenAL Soft (LGPL-2), FreeType's GPLv2 option, any GPL code | — |

Third-party code is vendored or fetched by the build with its licence
file; Ycode's own code stays MIT (repository licence).

## 4. Risks and open design questions

1. Determinism versus Apple: our numbers match Apple's only as far as
   the integrator, combine rules and solver iterations match; tolerance
   policy in `10-plan.md` §3.
2. MaterialX coverage of RealityKit-specific nodes, and the visual gap
   between our PBR and Apple's.
3. Custom materials without a Metal compiler on Linux.
4. OpenUSD's size and build time; whether tinyusdz suffices for most
   apps.
5. SwiftUI-free `RealityView`: source compatibility with SwiftUI-based
   apps needs Ycode's broader SwiftUI work (`docs/FUTURE.md`).
