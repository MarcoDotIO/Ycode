# Spec: Metal shaders for the simulator host — metallib, AIR, and SPIR-V

Status: **reference** for stage 8a (`stage8-contract.md` §2, agent R8).
It describes the shader path of Ycode's Metal host service: the
`.metallib` container and the AIR payload as file formats, the AIR
intrinsics and metadata that the iOS 27.1 runtime (24A94401) uses, a plan
to translate AIR to SPIR-V for Vulkan on the Thor, the Vulkan features the
plan needs (checked on the Thor), and a proof of concept that runs our own
Metal shaders, compiled to AIR, on the Thor's GPU.

Every fact comes from public documentation and open-source projects
(level 1), from `.metallib` files read as a file format (level 2: files we
compiled ourselves with the public Metal toolchain, and the runtime's own
files, headers and tables only), from black-box runs of our own programs
and of the public toolchain on our own shaders (level 3), and from names
and counts of intrinsics and metadata keys in the runtime's files
(level 4). No Apple binary was disassembled or decompiled, and no Apple
shader's logic was read: tools that converted runtime modules to text kept
only names and counts and deleted the text at once. No Apple shader,
metallib or bitcode is in the repository. Integers are little-endian
unless stated.

Terms:

- **metallib**: a file or memory blob with magic `MTLB` (§2).
- **AIR**: Apple's intermediate representation for Metal, LLVM bitcode
  with a Metal target and `air.*` intrinsics and metadata (§3).
- **Module**: one LLVM bitcode module inside a metallib.
- **Function entry**: one record of the metallib function list (§2.3).
- **Tag list**: a sequence of tagged fields ended by `ENDT` (§2.2).
- **`functionIR`**: the per-function metallib that the simulator Metal
  driver sends to the host (`metal-sim-protocol.md` §6).
- **The home-screen set**: the metallibs that the home screen is expected
  to need: QuartzCore, CoreUI, IconRendering, RenderBox, CoreMaterial3D,
  and MTLSimDriver (§3.10). R7's captures (`metal-sim-protocol.md` §10)
  establish the processes and records; the exact function set is open
  (§8).
- **airc**, **vkrun**, **vkdraw**: our PoC programs (Appendix A).

## 1. How shaders reach the host

R7 found (`metal-sim-protocol.md` §6) that libraries never reach the host:
the guest compiles source in its own `MTLCompilerService`, and loads
metallib files and data itself. When a pipeline uses a function, the
driver sends **one metallib that holds that one function** (AIR bitcode
inside a bitcode wrapper; 2.9–6.3 KB for typical functions). The same form
comes from source, from metallib files and from specialization; function
constants are resolved in the guest before sending.

So the host's input is exactly the metallib-with-AIR form of §2 and §3,
and the translator of §4 works on one function at a time. The runtime's
own metallib files (§3.10) are what the guest loads; the host never reads
them, but they tell us which AIR the host will receive.

If a future runtime sent **MSL source** instead, nothing in §4 would
change except a front end in front of it: there is no open-source MSL
compiler, so the host would compile source to AIR with the runtime's own
compiler in a guest helper process (the runtime ships
`Metal.framework/XPCServices/MTLCompilerService.xpc`, `MTLCompiler.framework`
and `GPUCompiler.framework` with its own `libLLVM.dylib`; names only,
level 4) and then translate the AIR as here. AIR stays the pivot format.

## 2. The metallib container

### 2.1 Layout

| Part | Where | Contents |
|---|---|---|
| Header | 0, 88 bytes | magic, versions, target, section table (§2.2) |
| Function list | header offset (always 88) | u32 count, then one entry per function (§2.3) |
| Header extension | right after the last function entry | tag list (§2.4); just `ENDT` when empty |
| Public metadata | header offset | one tag-list entry per function (§2.5) |
| Private metadata | header offset | one tag-list entry per function (§2.5) |
| Bitcode | header offset | the modules (§2.7) |
| Extension sections | after the bitcode, at offsets named by the header extension | dynamic header, reflection list, embedded sources (§2.4) |

### 2.2 Header

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `MTLB` |
| 4 | 2 | bit 15: target is macOS; bits 0–14: 1 in every file seen |
| 6 | 2 | version major (2) |
| 8 | 2 | version minor (9 in every current file; 6 and 7 in older ones) |
| 10 | 1 | bits 0–6 file type: 0 executable, 1 Core Image library, 2 dynamic library, 3 companion; bit 7 stub |
| 11 | 1 | bits 0–6 platform, Mach-O platform numbers (1 macOS, 2 iOS, 7 iOS simulator); bit 7 set in every file seen |
| 12 | 2 | OS version major (27) |
| 14 | 2 | OS version minor (1) |
| 16 | 8 | file size |
| 24 | 8 | function list offset (88) |
| 32 | 8 | function list size: the sum of the entry sizes, **without** the u32 count |
| 40 | 8 | public metadata offset |
| 48 | 8 | public metadata size |
| 56 | 8 | private metadata offset |
| 64 | 8 | private metadata size |
| 72 | 8 | bitcode offset |
| 80 | 8 | bitcode size |

The version at 6–9 equaled the AIR version of the modules in every
current file (2.9). Runtime files for iOS 27.1 have platform 7, OS 27.1.
The public `file(1)` magic database describes bytes 0–11 the same way.

**Tag lists.** A field is a 4-byte ASCII tag, a u16 payload length, and
the payload. The tag `ENDT` has no length and ends the list. One
exception: `RBUF` (§2.6) has a u32 length. A reader skips unknown tags by
their length.

### 2.3 Function list

`u32 count`, then `count` entries. An entry is `u32 entry size` (counting
the size field) and a tag list:

| Tag | Payload | Meaning |
|---|---|---|
| `NAME` | NUL-terminated string | function name |
| `TYPE` | u8 | function kind (table below) |
| `HASH` | 32 bytes | SHA-256 of the function's module bytes (the `MDSZ` bytes at the module offset, wrapper included); checked on 3 QuartzCore functions |
| `OFFT` | 3 × u64 | offsets of the function's public metadata, private metadata, and module, each relative to its section |
| `VERS` | 4 × u16 | AIR version major, minor; language version major, minor (2.9, 4.1 for our toolchain) |
| `MDSZ` | u64 | module size in bytes |
| `RFLT` | u64 | offset of the function's entry in the reflection list (§2.6) |
| `SOFF` | u64 | offset of the function's source record in the embedded sources (§2.4) |
| `TESS` | u8 | tessellation: bits 0–1 patch type (1 = triangle), bits 2–7 control points per patch |
| `LAYR` | u8 | data type (`MTLDataType`) of the layer output (`[[render_target_array_index]]`; 0x21 `uint`) |

Function kinds (`TYPE`), from our own shaders of each kind:

| Value | Kind | Runtime count (§3.10) |
|---|---|---|
| 0 | vertex | 1174 |
| 1 | fragment | 1760 |
| 2 | kernel | 20 770 |
| 3 | no stage (every function of a dynamic library) | 199 |
| 4 | visible (`[[visible]]` and `[[stitchable]]`) | 10 598 |
| 5 | Core Image kernel | 1374 |
| 6 | intersection | 12 |
| 7 | mesh | 2 |
| 8 | object | 0 |

Tag order differs by writer: the `metallib` tool writes `NAME TYPE HASH
MDSZ OFFT VERS` (also seen in one runtime file, MTLSimDriver's); the
`metal` driver when it links directly, the run-time compiler and the other
runtime files write `NAME TYPE HASH OFFT VERS [TESS|LAYR] MDSZ [SOFF]
[RFLT]` (Core Image kernels have no `RFLT`). Readers must not depend on
order.

### 2.4 Header extension and extension sections

The header extension is a tag list. Each tag except `UUID` names a
section by `u64 offset, u64 size` from the start of the file:

| Tag | Section contents | Seen in |
|---|---|---|
| `HDYN` | a tag list with `NAME` = the library's install name (`default.metallib`, or `@executable_path/…` for a dynamic library) | 173 of 175 runtime files; files written by the `metal` driver |
| `RLST` | reflection list (§2.6) | 160 runtime files |
| `HSRD` | embedded sources: u32 string count, NUL-terminated strings (the linker command line, the working directory), then per function a record `u32 size, "SARC", u32 size, NUL-terminated id, bzip2-compressed tar archive` holding `metal-options.txt` and the source files | our files built with `-frecord-sources`; no runtime file |
| `HSRP` | a tag list with `LINK` (6 bytes; not decoded) | our run-time-compiled dynamic library |
| `ILST` | not decoded | 1 runtime file |
| `UUID` | 16 bytes inline | 174 runtime files |

Files written by the `metallib` tool alone have no extension (just
`ENDT`).

### 2.5 Public and private metadata

Each function's `OFFT` points to an entry `u32 size` (counting itself)
plus a tag list; a function without metadata has an 8-byte entry (size 8,
`ENDT`).

Public metadata:

| Tag | Payload |
|---|---|
| `VATT` | vertex attributes: u16 count, then per attribute a NUL-terminated name and a u16 whose bits 0–13 are the attribute index, bit 15 set when the attribute is used, bit 14 set for patch control-point attributes |
| `VATY` | u16 count, then one u8 `MTLDataType` per attribute (4 float2, 5 float3, 6 float4, 0x13 half4) |
| `CNST` | function constants: u16 count, then per constant a NUL-terminated name, u8 `MTLDataType` (0x35 bool), u16 index, u8 (1 in our sample) |
| `RETR`, `ARGR` | return and argument descriptions of Core Image kernels (type 5): `ARGR` is u8 count then per argument a name and a type record (not decoded further) |

Private metadata: `DEPF` (NUL-terminated path of the dependency file),
`DEBI` (u32 source line of the function, NUL-terminated source path);
present only with `-frecord-sources` or debug info.

Runtime counts: `CNST` 5253 functions, `VATT`/`VATY` 424, `RETR`/`ARGR`
1374; no private metadata in any runtime file.

### 2.6 Reflection list

`RLST` section: u32 count, then per function `u32 size`, a tag list with
`RBUF` (u32 length, then a FlatBuffers buffer whose file identifier is
`AIRR`), `ENDT`. It holds argument names and type names for API
reflection. The host does not need it: the guest computes reflection
itself (`metal-sim-protocol.md` §6), and the same facts are in the AIR
metadata (§3.5).

### 2.7 Bitcode section and modules

Two layouts occur:

- **Per-function modules** (167 runtime files, 6 of them without
  functions, and the `functionIR` form): each function has its own
  module; `OFFT` bitcode offsets differ.
- **Single module** (8 runtime files: the six multi-function Core Image
  libraries and the two dynamic libraries; also our run-time-compiled
  dynamic library): every entry points at one module at offset 0 with the
  same `HASH` and `MDSZ`.

Each module starts with the LLVM **bitcode wrapper** header (public,
LLVM `BitcodeReader`): u32 magic `0x0B17C0DE`, u32 version 0, u32 offset
(20), u32 size, u32 CPU type `0xFFFFFFFF`; the raw bitcode (`BC` `0xC0DE`)
follows (§3.1).

### 2.8 Universal containers

Two multi-slice forms exist, both with the Mach-O fat header layout (big
endian: magic, u32 slice count, then per slice u32 CPU type, u32 subtype,
u32 offset, u32 size, u32 alignment):

- magic `0xCAFEBABE` in 1 runtime file (`CoreImage.metallib`): two `MTLB`
  slices, CPU type `0x01000017`, subtypes 8 and 13 (two AIR generations);
- magic `0xCBFEBABE` from `MTLDynamicLibrary -serializeToURL:` (our run):
  an `MTLB` slice (CPU type `0x01000017`) and a GPU-binary Mach-O slice
  (CPU type `0x01000013`). A host ignores GPU-binary slices.

A reader picks the `MTLB` slice with the highest subtype.

### 2.9 Reader rules for Ycode

1. Accept `MTLB` (and the two universal forms); refuse anything else.
2. Bound every offset and size by the blob size; refuse overlaps outside
   the sections of §2.1.
3. Parse tag lists generically; skip unknown tags; stop at `ENDT` or the
   entry end.
4. For each function keep `NAME`, `TYPE`, `HASH`, `VERS`, and the module
   slice. Hand the module (wrapper included) to the bitcode reader.
5. Use `HASH` (the module's SHA-256) as the cache key of translated
   modules (§4.1); verify it when cheap.

## 3. AIR

### 3.1 Bitcode

| Property | Observed (runtime and our toolchain) |
|---|---|
| Wrapper | §2.7, CPU type `0xFFFFFFFF` |
| Identification block | present; producer string empty, epoch 0 |
| Module block version | 2 (relative value IDs) |
| Pointers | **typed** pointer records only (no opaque pointers): the producer's LLVM predates opaque pointers. Its text form also uses older attribute spellings (`argmemonly`) |
| Producer (`!llvm.ident`) | `Apple metal version 32023.921 (metalfe-32023.921.6)` in 34 325 runtime modules, `32023.823` in 1; the public toolchain 27A266a is also 32023.921 |
| Upstream LLVM 18.1.3 | `llvm-dis-18` read **all 34 326 runtime modules with no error**, and all of ours, upgrading typed pointers to opaque ones |

Our run-time-compiled dynamic library carried a newer producer
(`32023.922`) and opaque pointers; LLVM 18 read it too.

### 3.2 Target

- Triple: `air64_v29-apple-ios27.1.0-simulator` (34 310 runtime modules;
  others: `air64_v25-apple-ios16.0.0-simulator` 13,
  `air64_v28-apple-ios26.0.0-simulator` 1, `air64-apple-ios27.0.0` 1,
  `air64_v28-apple-macosx16.0.0` 1). `functionIR` carries
  `air64-apple-ios13.0.0-simulator` (R7). The translator checks only the
  `air64` prefix.
- Data layout, identical in all modules:
  `e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32`.
  Pointers are 64-bit; vectors of 3 elements are padded to 4 (`v96:128`).

### 3.3 Address spaces

| AS | Meaning (from our shaders) | In runtime entry signatures |
|---|---|---|
| 0 | private (function-local memory) | — |
| 1 | `device` buffers; also texture, acceleration-structure and function-table handles | 110 139 |
| 2 | `constant` buffers; sampler handles; constexpr sampler states | 116 381 |
| 3 | `threadgroup` memory; mesh grid properties | 9582 |
| 4 | imageblock handles | in declarations (132) of 7 files, QuartzCore among them |
| 5 | not identified | 3 (VFX only) |
| 6 | object-shader payload (`object_data`) | — |
| 7 | mesh output handle | 2 (VFX only) |
| 8 | not identified; not in the home-screen set | 6178 in 9 files (MPS, ImageIO, RawCamera, ClothPhysics, VFX, MetalTools) |

Resources are opaque struct pointers (`_texture_2d_t`, `_depth_2d_t`,
`_sampler_t`, `_imageblock_t`, …) in these address spaces, never
dereferenced; only intrinsics take them.

### 3.4 Module metadata

| Node | Contents |
|---|---|
| `!air.version` | (2, 9, 0) |
| `!air.language_version` | ("Metal", major, minor, 0): runtime modules use 1.1 to 4.1 (4.1: 12 902; 3.2: 13 373; 2.4: 4225; 3.0: 2191; 2.2: 971; 2.3: 376; 4.0: 265; 1.1: 19; 2.0: 4) |
| `!air.compile_options` | `air.compile.denorms_disable`, `air.compile.fast_math_enable` or `air.compile.fast_math_disable`, `air.compile.framebuffer_fetch_enable` |
| `!llvm.module.flags` | `air.max_device_buffers` 31, `air.max_constant_buffers` 31, `air.max_threadgroup_buffers` 31, `air.max_textures` 128, `air.max_read_write_textures` 8, `air.max_samplers` 16, plus `wchar_size`, `frame-pointer`, `SDK Version` |
| `!air.sampler_states` | constexpr samplers (§3.7) |
| `!air.function_constants` | function constants (§3.8) |
| `!air.source_file_name` | only with recorded sources |

Named entry-point lists (runtime module counts): `!air.kernel` 20 770,
`!air.visible` 10 598, `!air.fragment` 1760, `!air.vertex` 1174,
`!air.visible_function_references` 1669, `!air.global_bindings` 34,
`!air.intersection` 12, `!air.ci` 8, `!air.mesh` 2. 17 named nodes in all.

### 3.5 Entry-point metadata

An entry of `!air.vertex`, `!air.fragment` or `!air.kernel` is a node of
three operands: the function, a list of **output** nodes, and a list of
**argument** nodes. Kernels have an empty output list.

- An **argument node** starts with the argument's index (i32) and its
  **kind** string, followed by key strings, some with values:
  `air.location_index` (slot, then a count, 1), `air.buffer_size`,
  `air.address_space`, `air.arg_type_size`, `air.arg_type_align_size`,
  `air.arg_type_name` (string), `air.arg_name` (string),
  `air.struct_type_info` (a node of per-member offset, size, array count,
  type name, member name), access (`air.read`, `air.write`,
  `air.read_write`, `air.sample`), interpolation (`air.center`,
  `air.centroid`, `air.sample`, `air.perspective`, `air.no_perspective`,
  `air.flat`), `air.arg_unused`, `air.raster_order_group` (i32). Vertex
  outputs and fragment inputs carry a **match string** right after the
  kind: `generated(<length><name><type mangling>)` for unnamed members
  (e.g. `generated(2uvDv2_f)`) — Metal matches varyings by this string,
  not by position.
- An **output node** has no index: its kind (`air.position`,
  `air.vertex_output` + match string, `air.point_size`, `air.clip_distance`,
  `air.render_target` + i32 index + i32 dual-source index, `air.depth` +
  `air.depth_qualifier`, `air.sample_mask`, …) and type and name keys. The
  outputs are, in order, the members of the function's return value (a
  packed struct, or a single value).

Argument and output kinds seen (runtime files using each, of 175):

| Group | Kinds |
|---|---|
| Resources | `air.buffer` (131), `air.texture` (108), `air.sampler` (19), `air.indirect_buffer` (22, argument buffers), `air.imageblock` (11), `air.visible_function_table` (3), `air.intersection_function_table` (2), `air.instance_acceleration_structure`, `air.primitive_acceleration_structure` (3) |
| Compute built-ins | `air.thread_position_in_grid` (87), `air.thread_position_in_threadgroup` (30), `air.threadgroup_position_in_grid` (26), `air.threads_per_threadgroup` (24), `air.threads_per_grid` (23), `air.thread_index_in_threadgroup` (19), `air.thread_index_in_simdgroup` (16), `air.simdgroup_index_in_threadgroup` (16), `air.simdgroups_per_threadgroup` (11), `air.threads_per_simdgroup` (10), `air.threadgroups_per_grid` (10), `air.thread_index_in_quadgroup` (8), `air.quadgroup_index_in_threadgroup` (6), `air.dispatch_threads_per_threadgroup` (3), `air.stage_in_grid_size` (2) |
| Vertex | `air.vertex_input` (27; stage-in attributes, `air.location_index` = attribute index), `air.vertex_id` (69), `air.instance_id` (28), `air.position` (82), `air.vertex_output` (74), `air.point_size` (7), `air.clip_distance` (5), `air.invariant` (4), `air.render_target_array_index` (9), `air.viewport_array_index` (13), `air.amplification_id` (8) |
| Fragment | `air.fragment_input` (80), `air.render_target` (82; also as an *input* for programmable blending), `air.front_facing` (13), `air.primitive_id` (11), `air.point_coord` (5), `air.barycentric_coord` (10), `air.sample_mask_in` (9), `air.sample_mask` (3), `air.depth` (8), `air.stencil` (2) |
| Tessellation | `air.patch` (5), `air.patch_control_point` (5), `air.position_in_patch` (5), `air.patch_id` (3) |
| Visible and stitched functions | `air.visible_input` (40), `air.visible_output` (39), `air.stitching_info`, `air.stitching_type`, `air.stitching_argument` (36), type descriptors `air.*_type` |
| Core Image | `air.ci_builtin` (8), `air.ci_texture`, `air.ci_sampler` (5), `air.ci_pointer` (3) |

The full list (173 strings) is in our inventory output (Appendix A).

### 3.6 Argument buffers

A buffer argument that holds resources is kind `air.indirect_buffer`
(address space 2 or 1) with `air.struct_type_info` whose members carry
`air.indirect_argument` and a nested argument node (`air.texture`,
`air.sampler`, `air.buffer`, with their own `air.location_index` = the
`[[id(n)]]`). In memory every member is **8 bytes**: textures and samplers
are 64-bit handles, buffers 64-bit addresses (our shader: offsets 0, 8,
16). Shaders load the handles from the buffer and pass them to the
texture intrinsics. This is what makes the bindless design of §4.4 fit.

### 3.7 Constexpr samplers

A `constexpr sampler` becomes an internal address-space-2 global
`[2 x i64]`, listed in `!air.sampler_states` and passed (cast to a sampler
handle) to texture intrinsics. Word 0 (word 1 was 0 in all variants),
learned by changing one argument at a time in our own shaders:

| Bits | Field | Values |
|---|---|---|
| 0–2, 3–5, 6–8 | s, t, r address mode | 0 clamp to border (also clamp to zero), 1 clamp to edge (default), 2 repeat, 3 mirrored repeat |
| 9–10 | mag filter | 0 nearest, 1 linear |
| 11–12 | min filter | 0 nearest, 1 linear |
| 13–14 | mip filter | 0 none, 1 nearest, 2 linear |
| 15 | coordinates | 0 normalized, 1 pixel |
| 16–18 | compare function | 0 never/none, 1 less, 2 less-equal, 3 greater, 4 greater-equal, 5 equal, 6 not-equal, 7 always |
| 19–23 | anisotropy | 2 × max anisotropy − 1 (1 → 1, 2 → 3, 16 → 31) |
| 24–39 | LOD minimum | IEEE half (default 0.0) |
| 40–55 | LOD maximum | IEEE half (default 0x7BFF, the largest half) |
| 56–57 | border color | 0 transparent black, 1 opaque black, 2 opaque white |
| 58–59 | reduction | 0 weighted average, 1 minimum, 2 maximum |

`air.get_read_sampler()` supplies the sampler operand of texture reads.

### 3.8 Function constants

A function constant appears as an internal address-space-2 global loaded
by the function, an externally initialized constant in section
`air.fc_initializer`, a static initializer in section `air.static_init`,
and `!air.function_constants` entries (global, type name, name, index).
Intrinsics `air.is_function_constant_defined` and
`air.normalize_function_constant_predicate` test them (5254 runtime
modules have the list). Per R7 the guest resolves constants before
sending a function, so the host normally sees none; a translator still
refuses unresolved ones.

### 3.9 Intrinsics

Names are `air.<operation>[.<qualifiers>][.<overload types>]`; overload
suffixes use LLVM type mangling (`f32`, `v4f16`, `i32`, `p1i8`, …).
Conversions are `air.convert.<dk>.<dt>.<sk>.<st>`, kind `f`, `s`
(signed) or `u` (unsigned), destination first (`air.convert.f.f32.u.i32`
is unsigned int to float). Math has plain, `fast_` and `precise_`
variants. Intrinsics that may fail return `{ value, i8 }` (texture
samples and reads).

Argument meaning is learned from our own shaders, one call variant at a
time (level 3); e.g. 2D textures:

| Intrinsic | Operands (as observed) |
|---|---|
| `air.sample_texture_2d.<T>` | texture, sampler, float2 coordinate, i1 (true in all variants), int2 offset, i1 explicit LOD, float bias or LOD, float minimum-LOD clamp, i32 (0) → `{ <4 x T>, i8 }` |
| `air.sample_texture_2d_grad.<T>` | texture, sampler, coordinate, float2 dPdx, float2 dPdy, float minimum-LOD clamp, i1 (true), int2 offset, i32 (0) |
| `air.sample_texture_2d_array.<T>` | as `sample_texture_2d` with a u32 array index after the coordinate |
| `air.read_texture_2d.<T>` | texture, read sampler, uint2 coordinate, int2 offset (0), u32 LOD, i32 (1 for `access::read` textures, 0 for sampled ones) |
| `air.gather_texture_2d.<T>` | texture, sampler, coordinate, i1 (true), int2 offset, i32 component, i32 (0) |
| `air.get_width_texture_2d`, `air.get_height_texture_2d` | texture, u32 LOD |
| `air.get_num_mip_levels_texture_2d` | texture |
| `air.calculate_clamped_lod_texture_2d` | texture, sampler, float2 coordinate, i32 → float (the form visionOS RealityKit materials send to Ycode's host, visionos.md §10.11.3; the MSL member `calculate_clamped_lod(sampler, coord)`; ycode-airc: `OpImageQueryLod` component 0, fragment functions only; `calculate_unclamped_lod`: component 1) |
| `air.get_num_samples.i32` | none → i32 (the fragment function's raster sample count; translated as `air.get_num_samples`) |
| `air.atomic.global.cmpxchg.weak.i32` (also `.local.`, `.strong.`) | atomic object pointer (address space 1, or 3 for `.local.`), pointer to the expected value (address space 0), i32 desired value, i32, i32, i32, i1 → **i32** (the form visionOS RealityKit's compute functions send to Ycode's host, visionos.md §10.13; operand types reported by ycode-airc's `decls`). The MSL call is `atomic_compare_exchange_weak_explicit(object, &expected, desired, success order, failure order)`, which returns bool and writes the value found into `expected` when it fails; with `expected` passed by pointer the result can only be the success flag, so ycode-airc reads the i32 as success 1 / failure 0 (a Ycode reading, not yet confirmed by a probe of ours; the three i32 operands are taken to be the two orders and the scope, the i1 volatility). ycode-airc: load `*expected`, `OpAtomicCompareExchange` (relaxed, device or workgroup scope), store the value found back into `*expected` (unchanged on success), result = found == expected. The strong form satisfies the weak one |

Ycode's implementation keeps such a catalog (one row per intrinsic
family, from our own probe shaders) as test data; operands marked "(as
observed)" stay open until a probe varies them.

### 3.10 Inventory of the runtime's metallibs

The iOS 27.1 runtime has **177** `.metallib` files (436 MB): 165
executable, 8 Core Image, 2 dynamic libraries; 2 are empty files and 6
hold no functions. In all: **35 889 functions** in **34 326 modules**;
all modules read by LLVM 18.

Intrinsics (declarations, names only): **1992 distinct names** (1896
`air.*`, 96 `llvm.*`; 333 of them `air.convert.*`), **566 families**
after removing overload suffixes. By group (families; families used by
the home-screen set):

| Group | Families | Home-screen set |
|---|---|---|
| math (`air.[fast_|precise_]<op>`) | 145 | 55 |
| SIMD-group and quad-group | 104 | 4 (`simd_sum`, `simd_shuffle_and_fill_down`, `quad_shuffle_xor`, `get_simdgroup_size`) |
| ray tracing (`air.intersect.*`, acceleration structures) | 113 | 0 |
| texture query (size, levels, null checks) | 38 | 5 |
| `llvm.*` | 35 | 9 (`fmuladd`, `lifetime.*`, `memcpy`, `memset`, `smax`, `smin`, `umax`, `umin`) |
| atomics | 27 | 0 |
| texture read/write | 26 | 6 |
| texture sample/gather | 22 | 2 (`sample_texture_2d`, `sample_texture_3d`) |
| pack/unpack | 19 | 2 |
| other (ICB commands, coherent loads, tensors, screen mapping) | 17 | 0 |
| imageblock / tile | 8 | 3 |
| fragment control (`discard_fragment`, `dfdx`, `dfdy`, `fwidth`, `get_num_samples`) | 5 | 5 |
| function constants | 2 | 2 |
| barriers (`air.wg.barrier`, `air.simdgroup.barrier`) | 2 | 1 |
| visible-function tables | 1 | 1 |
| conversions | 1 (333 names) | 1 |
| read sampler | 1 | 1 |

Most common families by number of files: `air.dot` (116),
`air.sample_texture_2d` (103), `air.mix` (101), `air.convert.*` (99),
`air.fast_fmax` (97), `air.fast_sqrt` (96), `air.fast_fabs` (94),
`air.fast_clamp` (92), `air.fast_fmin` (76), `air.fast_pow` (73),
`air.fast_rsqrt` (68), `air.clamp` (67), `air.get_width_texture_2d` (64),
`air.write_texture_2d` (64), `air.read_texture_2d` (58).

GPU-specific `llvm.agx2.*`/`llvm.agx3.*` intrinsics occur only in MPS,
GPUToolsReplay and MetalTools files; ICB intrinsics
(`air.set_*_command`) only in MetalTools and GPUToolsReplay. Neither is
in the home-screen set.

**The home-screen set.** `backboardd` composites with QuartzCore's
library (`metal-sim-protocol.md` §10: render encoders only, 97 of 101
pipelines with vertex descriptors). Candidates and their contents:

| Library | Functions | Kinds | Families |
|---|---|---|---|
| QuartzCore `default.metallib` (2.7 MB) | 228, one module each | 145 fragment, 54 kernel, 29 vertex; 9 with function constants | 91 |
| RenderBox (SwiftUI rendering) | 109 | 58 fragment, 24 vertex, 27 visible | 69 |
| CoreMaterial3D | 191 | visible | 41 |
| MTLSimDriver (the guest driver's own kernels) | 12 | kernel: PVRTC, ETC2/EAC, ASTC and XR10 decoders | 31 |
| IconRendering | 14 | visible (stitchable icon effects) | 16 |
| CoreUI | 17 | Core Image kernels | 9 |

Their union is **97 families** (Appendix B). QuartzCore alone uses tile
features (`air.imageblock`, `air.raster_order_group`, implicit imageblock
load/store, `write_imageblock_slice_to_texture_2d`), function constants,
SIMD/quad operations, and 2D/3D sampling, reads and writes. QuartzCore's
functions fall in name groups such as glass (36), blur/downsample/upsample
(40+), tile (13), stroke, gradients, SDF and colour conversion (names
only).

## 4. Translation to SPIR-V

### 4.1 Pipeline

1. **Receive** a `functionIR` (§1). Parse the container (§2.9); key the
   result by `HASH` plus everything pipeline state adds (§4.5, §4.6).
2. **Read bitcode** with LLVM's bitcode reader (LLVM ≥ 17; 18 tested).
   Typed pointers become opaque; the translator gets pointee types from
   loads, stores and `getelementptr` source types, never from pointers.
3. **Normalize** with stock LLVM passes: lower switches, one return block,
   loop-simplify form, a dedicated back-edge block per loop; optionally
   SROA/mem2reg, instcombine and inlining of non-entry functions.
4. **Lower AIR**: read the entry metadata (§3.5) to build the interface;
   map address spaces (§4.3), resources (§4.4), stage interface (§4.5),
   and intrinsics (§4.7, the catalog of §3.9).
5. **Emit SPIR-V** with our own emitter: Shader capability,
   `PhysicalStorageBuffer64` addressing, GLSL.std.450 for math, structured
   control flow from the normalized CFG (§4.8).
6. **Validate** with SPIRV-Tools (`spirv-val` semantics, in process) and
   optionally optimize (`spirv-opt` performance passes; then validate
   again). Hand the words to `vkCreateShaderModule`.
7. **Cache** SPIR-V by key on disk; pipelines with
   `VK_EXT_graphics_pipeline_library`/`VK_KHR_pipeline_binary` (both on
   the Thor) when stable.

The PoC (§6) implements steps 1–6 for a subset.

### 4.2 Choice of translator

| Option | Verdict |
|---|---|
| **Own emitter on LLVM IR** (LLVM for reading and normalizing only) | **Recommended.** Full control of Metal's resource model (64-bit addresses and handles), varying matching, half widening, and structurization; small (the PoC is about 1000 lines for compute plus render basics) |
| Khronos SPIRV-LLVM-Translator | No. It emits OpenCL-flavored SPIR-V (`Kernel` capability, `Physical64`/generic pointers, OpenCL.std), which Vulkan cannot load, and knows neither AIR intrinsics nor AIR metadata. Useful only as a reference for LLVM-type to SPIR-V-type mapping |
| LLVM's SPIR-V back end (`spirv` target; official in LLVM 20, Vulkan shader support for HLSL in progress) | Not now. Not built in Ubuntu's `llvm-18`; its resource model is HLSL's (`target("spirv.*")` handle types); AIR would need the same lowering anyway. Re-evaluate later |
| Pure-Swift bitcode reader inside Ycode | Later option. The bitcode format is public (LLVM documentation); AIR uses a stable subset from one producer. Removes the LLVM dependency at the cost of writing the reader and the typed-pointer upgrade |

### 4.3 Memory model

- **Buffers** (address spaces 1 and 2): every pointer is a **64-bit
  integer address**. `getelementptr` becomes integer arithmetic with byte
  offsets from the data layout (§3.2); each load and store converts the
  address to a `PhysicalStorageBuffer` pointer to the accessed type and
  uses the `Aligned` operand from the IR. Casts, pointer arithmetic,
  pointers stored in memory and pointer phis all work. The address of a
  Metal buffer at an offset is the Vulkan buffer's device address plus
  the offset (`VK_KHR_buffer_device_address`).
- **Null guard** (since visionos.md §10.13). A load from a device or
  constant pointer that is not derived from a bound buffer, a table
  entry, a global or a private allocation (a pointer the function read
  from memory, made from an integer, or merged from such values) is
  guarded: if the address is below 64 KiB (a null pointer plus a field
  offset; no Vulkan allocation lies there) the load reads the argument
  table instead and yields zero. Metal functions do read through such
  pointers (visionOS RealityKit's `fsCALayer`, 22–58 guarded loads per
  variant); on the Thor a read of unmapped memory does not fault but
  stalls the GPU until the driver kills the context (stage8-contract.md
  §15.6). Cost: a compare and two selects per guarded load. The
  reflection counts them (`null_guarded_loads`); `AIRC_NULL_GUARD=0`
  turns the guard off. Stores, atomics and loads through bound buffers
  are not guarded.
- **Constant buffers** (AS 2) use the same path (read-only); small ones
  could later move to push constants or uniform buffers.
- **Threadgroup memory** (AS 3): one `Workgroup` block per kernel with
  `VK_KHR_workgroup_memory_explicit_layout` (supported, with 8- and
  16-bit access), so AS-3 pointers become byte offsets into it. Its size
  is a specialization constant: Metal sets `threadgroup(n)` lengths at
  dispatch time (`setThreadgroupMemoryLength:atIndex:`), Vulkan needs it
  at pipeline creation. Limit 48 KiB on the Thor (Metal's is 32 KiB).
- **Private memory** (AS 0, `alloca`): `Function` variables after SROA;
  address-taken arrays with casts become `u32` word arrays.
- **Imageblocks** (AS 4), payload (AS 6), mesh (AS 7): §4.10.

### 4.4 Resource binding

Metal binds by slot per stage: 31 buffers, 128 textures (8 read-write),
16 samplers (`!llvm.module.flags`, §3.4), plus argument buffers holding
64-bit addresses and 64-bit resource handles (§3.6). Recommended Vulkan
mapping, one model for both:

- **Buffers**: device addresses. A per-draw **argument table** (one
  small host-written buffer per stage, or push constants for the first
  few slots) holds the 64-bit address of each bound buffer slot; the
  shader reads slot *k*'s address from it. Vertex buffers that the
  vertex descriptor uses are also bound as Vulkan vertex buffers.
- **Textures and samplers**: a **bindless heap**: large descriptor arrays
  (`descriptorIndexing`, runtime arrays, partially bound, update after
  bind; 1 048 576 sampled images and samplers on the Thor; sampler
  objects capped at 4000 allocations) with separate array variables per
  image dimension aliased on one binding. A texture handle is an index
  into the heap. The argument table holds the handles of the bound
  texture and sampler slots.
- **Storage slots** (since visionos.md §10.18): every texture slot has an
  entry in the sampled *and* the storage array (equal sizes, 65,536 on the
  Thor); a texture without a view of one kind has the dummy image there,
  and a released texture's slots go back to the dummy image, so a kernel
  that writes a texture can never reach another texture's (possibly freed)
  image. Texture views get storage views too (their composed component
  mapping counts as identity when every component is `IDENTITY` or its
  own channel). Explicit-level storage access to level L of the texture in
  slot *h* uses slot *h* + L (ycode-airc, reflection `uses:
  storage_mip_levels`), so a texture with a storage view and n levels owns
  n consecutive slots, the later ones holding one-level storage views. On
  the Thor a write through a descriptor whose image memory was freed never
  completes (stage8-contract.md §15.9).
- **sRGB textures written through unorm views** (since visionos.md §10.20):
  Metal lets a kernel write an sRGB texture through a view in the matching
  unorm format (`pixelFormatView`), and visionOS RealityKit's ASTC decoder
  fills the room's `RGBA8Unorm_sRGB` textures that way. The sRGB Vulkan
  formats cannot be storage images on the Thor, so such an image is
  created with storage usage and `VK_IMAGE_CREATE_EXTENDED_USAGE_BIT` when
  its unorm sibling can be one (`R8G8B8A8`, `B8G8R8A8`, `A8B8G8R8`, `R8`,
  `R8G8`), and every view restricts its usage to what its own format
  supports. The unorm views get storage views and store the bytes as
  written. The sRGB texture itself gets no storage view: a kernel that
  writes it directly (Metal would encode linear to sRGB) writes the dummy
  image, logged by the back end.
- **Visibility results** (record 132, since visionos.md §10.20.8): each
  run of draws with one non-zero mode and slot offset in a render pass is a
  Vulkan occlusion query (`VK_QUERY_CONTROL_PRECISE_BIT` in counting mode
  when `occlusionQueryPrecise` is available), ended before any end of
  dynamic rendering (pass end, feedback snapshot); after the pass
  `vkCmdCopyQueryPoolResults` writes each slot as a 64-bit value. A slot
  counted by several segments of one pass gets the last count (Metal sums
  them).
- **Argument buffers**: if the host hands the guest real device addresses
  as `gpuAddress` and heap indices as `gpuResourceID` (R7 §4.2 op 39
  returns sampler resource IDs), then argument buffers written by guest
  CPU code work unchanged: shaders load the 8-byte members and use them
  as addresses or heap indices. Device addresses must stay stable
  (`bufferDeviceAddressCaptureReplay` where needed).
- Alternatives: `VK_EXT_descriptor_buffer` (supported, 64-byte offset
  alignment) to write descriptors straight into memory;
  `VK_KHR_push_descriptor` (32 descriptors, too few for 128 textures).

### 4.5 Stage interface (render pipelines)

| Metal (AIR) | Vulkan / SPIR-V |
|---|---|
| `air.vertex_input`, `air.location_index` *n* | `Input` variable `Location` *n*; the pipeline's vertex descriptor (R7 §7.2: attribute format, offset, buffer index; layout stride, step function, step rate) becomes vertex input bindings and attributes (`VK_EXT_vertex_input_dynamic_state`, `VK_KHR_vertex_attribute_divisor`, `VK_EXT_legacy_vertex_attributes` for unaligned attributes); format conversion by Vulkan format (e.g. `UChar4Normalized` → `R8G8B8A8_UNORM`) |
| `air.vertex_output` + match string | `Output` `Location` = index among the vertex function's outputs; the fragment function looks up its inputs **by match string** → so fragment SPIR-V depends on the linked vertex function (cache key includes it) |
| `air.position` (vertex output) | `BuiltIn Position`. Metal clip space has y up and z in [0, 1]: draw with a **negative viewport height** (core since Vulkan 1.1); depth range unchanged |
| `air.position` (fragment input) | `BuiltIn FragCoord` (origin upper left in both) |
| `air.render_target` *i* (output) | `Output` `Location` *i*; dual-source index → `Index` |
| `air.render_target` (input) | programmable blending: input attachment with `VK_KHR_dynamic_rendering_local_read` (supported) |
| `air.flat`, `air.no_perspective`, `air.centroid`, `air.sample` | `Flat`, `NoPerspective`, `Centroid`, `Sample` |
| `air.vertex_id`, `air.instance_id` | `VertexIndex`, `InstanceIndex` (base-vertex/base-instance semantics: §8) |
| `air.point_size`, `air.clip_distance` | `PointSize`, `ClipDistance` |
| `air.front_facing`, `air.primitive_id`, `air.sample_mask(_in)`, `air.barycentric_coord` | `FrontFacing`, `PrimitiveId`, `SampleMask`/`SampleMaskIn`, `BaryCoordKHR` (supported) |
| `air.depth` + qualifier | `FragDepth` + `DepthReplacing`/`DepthGreater`/`DepthLess` |
| `air.render_target_array_index`, `air.viewport_array_index` | `Layer`, `ViewportIndex` (`VK_EXT_shader_viewport_index_layer`). **A vertex function's `viewport_array_index` output is not written** (since visionos.md §10.13): Ycode's passes have one viewport and one scissor (the host keeps the first of a `setViewports:count:` array), so every primitive uses viewport 0; an index of 1 or more would select a Vulkan viewport and scissor that were never set (undefined). A fragment function that reads the index then reads 0. `AIRC_VIEWPORT_INDEX=1` writes it as before (experiments) |
| `air.vertex_input` the function never reads | No input variable (reflection: `"declared": false`; since visionos.md §10.13). Metal's vertex descriptor need not describe such attributes, and a Vulkan vertex shader input with no vertex attribute behind it is undefined; visionOS RealityKit's `vsUnlit` declares 15 stage-in attributes and reads 2. `AIRC_UNUSED_VERTEX_INPUTS=1` declares them as before |
| fragment input without a vertex output of the same match string | A linked fragment function's input that the function never reads and the vertex function does not write gets no interface variable (reflection: `"linked": false`); Metal accepts such pipelines (visionOS RealityKit's `fsSFBStencilBreakthrough` declares ten inputs, its `vsUnlit` writes four; uiCALayer pipelines likewise). An input that is read but not written stays an error (`bad-request`) |
| `half` at a stage boundary | **widened to 32-bit** with `OpFConvert`: the Thor has `storageInputOutput16` = false |

Front-face winding: Metal's default is clockwise; with the y flip, map
`setFrontFacingWinding:` to the opposite `VkFrontFace`.

### 4.6 Compute specifics

| Metal | Vulkan |
|---|---|
| Threadgroup size given at dispatch | `LocalSizeId` from specialization constants (maintenance4); one pipeline per size, cached |
| `dispatchThreads` (non-uniform grid) | round the dispatch up; pass the exact grid in the argument table (`air.threads_per_grid`); threads outside the grid must not run (guard; with barriers, guard side effects only) and edge threadgroups report their smaller size (§8) |
| `air.thread_position_in_grid` etc. | `GlobalInvocationId`, `LocalInvocationId`, `WorkgroupId`, `NumWorkgroups`, `LocalInvocationIndex`; `threads_per_threadgroup` = the specialization-constant composite |
| SIMD group (32 threads on Apple GPUs) | subgroup: size 32 on the Thor (min = max = 32); require full subgroups (`computeFullSubgroups`); `thread_index_in_simdgroup` → `SubgroupLocalInvocationId`, `simdgroup_index_in_threadgroup` → `SubgroupId` |
| `air.simd_*` reductions, prefix sums, shuffles, ballot, `simd_is_first`; quad operations | `GroupNonUniform` arithmetic, shuffle, shuffle-relative, ballot, vote, quad (all supported, all stages); `simd_shuffle_and_fill_*` = two shuffles and a select |
| `air.wg.barrier`, `air.simdgroup.barrier` | `OpControlBarrier` at `Workgroup` / `Subgroup` scope with acquire-release semantics for the memory classes in the flags |
| atomics (`air.atomic.global.*`, `.local.*`) | `OpAtomic*` on `PhysicalStorageBuffer` or `Workgroup` pointers; relaxed order; 64-bit and float add supported; compare-exchange as in §3.9 |
| `simdgroup_matrix` | `VK_KHR_cooperative_matrix` (supported) or emulation; not in the home-screen set |

### 4.7 Textures, samplers and math

- Texture types → `OpTypeImage` (1D, 2D, 3D, cube, arrays, MS; depth
  textures with `Depth` 1 and `OpImageSampleDref*`); sampled vs. read vs.
  read-write access → sampled image vs. storage image; formats unknown at
  translation (`shaderStorageImageReadWithoutFormat`/`WriteWithoutFormat`
  supported).
- `sample_*` → `OpImageSampleImplicitLod` (fragment) or `…ExplicitLod`
  (explicit LOD, or any sample outside fragment shaders); bias, LOD,
  gradients, minimum-LOD clamp (`MinLod` capability), constant offsets
  (`ConstOffset`; non-constant: `shaderImageGatherExtended`).
  `read_*` → `OpImageFetch` (sampled) or `OpImageRead`; `write_*` →
  `OpImageWrite`; `gather_*` → `OpImageGather`/`OpImageDrefGather`;
  `get_width/height/depth` → `OpImageQuerySizeLod`/`OpImageQuerySize`;
  `get_num_mip_levels` → `OpImageQueryLevels`. Half results: sample in
  32-bit, convert. The `i8` member of `{value, i8}` results is a
  residency status (0 until sparse textures matter).
- Constexpr samplers (§3.7) → `VkSampler` objects created at pipeline
  creation, placed in the heap. Pixel coordinates →
  `unnormalizedCoordinates` (Vulkan restricts it: no mipmaps, clamp
  modes only; otherwise scale the coordinates in the shader). Border
  colors and reduction modes map directly (`VK_EXT_custom_border_color`,
  `samplerFilterMinmax`).
- Math: `fast_`/`precise_`/plain math → GLSL.std.450 (`FMax`, `FMin`,
  `FClamp`, `Sqrt`, `InverseSqrt`, `Pow`, `Exp2`, `Log2`, `Sin`, …);
  `precise_` and `air.compile.fast_math_disable` get `NoContraction`;
  `air.dot` → `OpDot`; `air.convert.*` → `OpConvert*`/`OpFConvert`/
  `OpSConvert`/`OpUConvert` by the name's kinds. Metal's saturating
  float-to-int rule (open, §8) may need clamping.
- `half`: `Float16` arithmetic (`shaderFloat16`) and 16-bit storage in
  buffers (`storageBuffer16BitAccess`, `storagePushConstant16`) are
  supported; only stage I/O is widened (§4.5).

### 4.8 Control flow

SPIR-V for Vulkan needs structured control flow. After normalization
(§4.1 step 3): blocks in reverse post-order; each loop header gets
`OpLoopMerge` (merge = the loop's unique exit block, continue = the
dedicated back-edge block); every other conditional branch gets
`OpSelectionMerge` at its immediate post-dominator, unless one target
leaves the loop (break or continue), in which case the other target is
the merge. Irreducible control flow and multi-exit loops need LLVM's
`StructurizeCFG`-style rewriting or an exit-flag transform; `spirv-val`
rejects anything else, so failures are detected, not silently wrong.

### 4.9 Features without a direct Vulkan equivalent

| Feature | Plan |
|---|---|
| Imageblocks and tile functions (QuartzCore uses them) | Preferred: report a device family without tile shading so clients take their portable paths (depends on what the capability queries of R7 §4 steer; to test). Fallback: implicit imageblock fields backed by color attachments read with dynamic-rendering local read; explicit imageblocks as storage images; tile dispatches as compute over the render area between render-pass segments |
| Explicit imageblocks in fragment functions (visionOS RealityKit's `BreakthroughTechniques`, e.g. `fsBreakthroughMeshClearImageBlock`) | Ycode keeps no tile memory in render passes and runs no tile functions there, so nothing can read what a fragment function puts into its imageblock: a fragment result member of kind `air.imageblock_data` is **not written** (no Vulkan output; reflection `uses`: `imageblock_output_dropped`), and a fragment argument of kind `air.imageblock_data` (the pixel's imageblock, passed by value) **reads as zeros** (`imageblock_input_zero`). The function's colour, depth and other outputs are kept. Compute imageblocks are unchanged (workgroup memory). A faithful version needs per-pixel storage that lives for the pass (the fallback above) |
| Programmable blending (`[[color(n)]]` inputs) | Input attachments with `VK_KHR_dynamic_rendering_local_read` |
| Raster order groups | `SPV_EXT_fragment_shader_interlock` around the accesses (pixel and sample interlock supported) |
| Visible functions, function tables, stitching (RenderBox, IconRendering, CoreMaterial3D) | Metal requires linked functions to be declared at pipeline creation: link every candidate visible function into the pipeline's module and lower `air.get_function_pointer_visible_function_table` calls to a switch on the table index. Stitched graphs are built in the guest (open: what reaches the host) |
| Indirect command buffers | Emulate on the host (not in the home-screen set) |
| Ray tracing, mesh/object shaders | `VK_KHR_ray_query`/`VK_KHR_acceleration_structure` and `VK_EXT_mesh_shader` exist on the Thor; out of scope for 8a |
| Texture formats the host lacks | The guest driver already decodes PVRTC, ETC2/EAC, ASTC and XR10 with its own kernels (MTLSimDriver); the Thor supports ETC2, ASTC LDR and BC natively |

### 4.10 Running on Linux

- **Process model (recommended):** a separate translator process
  (`ycode-airc`), C++ against LLVM's libraries plus SPIRV-Tools, started
  by the host service and kept running; requests carry a `functionIR`
  plus pipeline facts, replies carry SPIR-V words or an error. It isolates
  LLVM's global state and crashes on hostile input from the VMM, keeps
  Swift free of C++ interop, and makes the license boundary simple. The
  translation itself takes milliseconds (§6). In-process linking stays
  possible later through a C API.
- **LLVM on the Thor:** the `llvm-18` packages (18.1.3) are installed with
  headers, static libraries and `libLLVM-18.so` (`llvm-18-dev`,
  `llvm-18-tools`; also runtime libraries of LLVM 15, 17 and 20). They
  read AIR (§3.1). Their target list has no SPIR-V back end (not needed).
  SPIRV-Tools 2025.1 (headers and static libraries), glslang 15.1 and
  Vulkan headers 1.3.275 are installed. No package was installed and no
  source build was needed; if Ycode later vendors LLVM, build only
  `Core`, `BitReader`, `Analysis`, `TransformUtils` and `Passes` into our
  directory on the data volume (`$YCODE_DATA`).
- **Licenses** (checked against the projects' license files):
  LLVM — Apache-2.0 with LLVM Exceptions; SPIRV-Tools — Apache-2.0;
  SPIRV-Cross — Apache-2.0; SPIRV-Headers — MIT-style Khronos license;
  **SPIRV-LLVM-Translator — University of Illinois/NCSA** (not
  Apache-2.0); MoltenVK — Apache-2.0. All allow use in Ycode with notices;
  the recommended design links only LLVM and SPIRV-Tools.
- **MoltenVK** implements Vulkan on top of Metal (SPIR-V → MSL through
  SPIRV-Cross): the opposite direction. It is not a source for this work.

## 5. Vulkan on the Thor

Checked read-only with `vulkaninfo` and our own `vkrun --features`
(Appendix A): NVIDIA Tegra Thor, integrated, driver 580.00
(`NVIDIA_PROPRIETARY`), Vulkan 1.4.315, conformance 1.4.1.3; instance
1.4.304.

| Need (§4) | Thor |
|---|---|
| Buffer device addresses, 64-bit integers | `bufferDeviceAddress`, `shaderInt64` yes |
| 16-bit and 8-bit types | `shaderFloat16`, `shaderInt16`, `shaderInt8`, `storageBuffer16BitAccess`, `uniformAndStorageBuffer16BitAccess`, `storagePushConstant16`, `storageBuffer8BitAccess` yes; **`storageInputOutput16` no** (widen stage I/O) |
| Bindless | `descriptorIndexing`, `runtimeDescriptorArray`, partially bound, variable count yes; 1 048 576 per-stage sampled images/samplers/storage buffers; `maxPerStageResources` 2³²−1; `maxSamplerAllocationCount` 4000; `VK_EXT_descriptor_buffer`, `VK_EXT_mutable_descriptor_type`, `VK_KHR_push_descriptor` (32) |
| Push constants | 256 bytes |
| Subgroups | size 32 (min = max = 32), all operations incl. arithmetic, shuffle, shuffle-relative, ballot, vote, clustered, quad; all 14 stages; quad in all stages; `subgroupSizeControl`, `computeFullSubgroups`; 32 subgroups per workgroup |
| Threadgroup memory | 48 KiB; 1024 invocations; `workgroupMemoryExplicitLayout` with scalar, 8- and 16-bit access |
| Memory model | `vulkanMemoryModel`, device scope; `scalarBlockLayout`; variable pointers |
| Specialization of workgroup size | `maintenance4` (`LocalSizeId`) yes |
| Render features | `dynamicRendering`, `dynamicRenderingLocalRead`, fragment shader interlock (pixel and sample), `dualSrcBlend`, `logicOp`, `independentBlend`, `depthClamp`, `fragmentShaderBarycentric`, `shaderDemoteToHelperInvocation`, 8 color attachments, 32 vertex attributes and bindings, anisotropy 16, custom border colors, min/max filtering, `VK_EXT_extended_dynamic_state3`, `VK_EXT_vertex_input_dynamic_state`, `VK_EXT_legacy_vertex_attributes`, `VK_EXT_shader_object`, `VK_EXT_graphics_pipeline_library`, `VK_KHR_pipeline_binary` |
| Atomics | 64-bit buffer and shared atomics, float32 buffer atomic add |
| Formats | ASTC LDR, ETC2, BC; image cube arrays |
| Host memory | `VK_EXT_external_memory_host`, `minImportedHostPointerAlignment` **4096**; also `VK_KHR_external_memory_fd`, `VK_EXT_external_memory_dma_buf` |
| Not present | `VK_EXT_shader_tile_image` (no tile-memory access), `textureCompressionASTC_HDR`, float32 denormal flush (`shaderDenormFlushToZeroFloat32` false) |

**Host-memory import, tested:** `vkrun` allocated every buffer in its
own process, imported it with `VkImportMemoryHostPointerInfoEXT` (handle
type host allocation, memory type from
`vkGetMemoryHostPointerPropertiesEXT`, device-address flag) and ran a
compute shader directly on it: correct for `aligned_alloc` memory and for
**`MAP_SHARED` mappings of a memfd** (the way a VMM maps guest RAM),
1 000 000 elements. Sizes and addresses must be 4096-aligned, which guest
pages (16 KiB) satisfy.

## 6. Proof of concept

`airc` (C++, LLVM 18 + SPIRV-Tools, Appendix A) translates AIR from a
metallib to SPIR-V; `vkrun` and `vkdraw` run it. Inputs are our own
shaders compiled with the public toolchain for the iOS simulator (triple
`air64_v29-apple-ios27.1.0-simulator`).

| Test | Result on the Thor |
|---|---|
| GLSL reference compute shader, same ABI (toolchain check) | `spirv-val` clean; 100 000 elements correct; also with imported host memory |
| `add_arrays` kernel (`out[i] = a[i] + b[i]` with a `constant uint &count` bound check): AIR → 322-word SPIR-V | `spirv-val` clean; **correct for 100 000 elements**; correct for 1 000 000 elements in an imported memfd mapping, threadgroup size 128 |
| `add_strided` kernel (grid-stride loop, phi, `air.fast_fmax`, `threads_per_grid`) | `spirv-val` clean, before and after `spirv-opt` performance passes; correct for 100 003 elements with a 777-thread grid |
| `draw_vs` + `draw_fs` render pipeline (stage-in float2 and half4 attributes, constant buffer by device address, `[[position]]`, two varyings matched by name, `texture2d<half>` sampling, `half4` `[[color(0)]]`) | `spirv-val` clean; **all 4096 pixels of a 64 × 64 render correct**, including orientation (Metal's y-up clip space through a negative viewport height); same as the GLSL reference |

Translation of one function takes about 18 ms wall time including process
start. The PoC refuses, with a message, what it does not handle (e.g.
threadgroup arguments, SIMD intrinsics, constexpr samplers, textures
other than sampled 2D).

## 7. What a Ycode translator must implement (derived)

1. Container reader (§2.9) and LLVM bitcode reading (§3.1).
2. Entry metadata parsing for vertex, fragment and kernel functions
   (§3.5), argument buffers (§3.6), constexpr samplers (§3.7).
3. The memory model of §4.3 and the binding model of §4.4, agreed with
   the host protocol (R7: how `gpuAddress` and `gpuResourceID` reach the
   guest).
4. Stage interface with varying matching by name and half widening
   (§4.5); compute dispatch rules (§4.6).
5. The 97 home-screen families (Appendix B) first, with a probe-shader
   catalog of their operands (§3.9); then the rest by frequency (§3.10).
6. Structurization (§4.8), SPIRV-Tools validation in debug builds.
7. A decision on tile shading (§4.9) before QuartzCore's tile functions
   are needed.

## 8. Open questions

1. Which QuartzCore functions `backboardd` actually creates pipelines
   for (R7 can log `functionIR` names); whether it uses the tile and
   imageblock functions when the device reports a non-Apple family.
2. The exact header fields of `functionIR` metallibs (platform, OS,
   extension tags) and whether their AIR differs from the runtime's
   files beyond the triple (R7 captures; §2 parsing is generic).
3. Operands marked "as observed" in §3.9 (the always-true `i1`, the
   trailing `i32`).
4. Metal's `instance_id`/`vertex_id` with base instance and base vertex
   versus Vulkan's `InstanceIndex`/`VertexIndex`.
5. Metal float-to-integer conversion rules for out-of-range values.
6. Non-uniform threadgroups at grid edges with barriers (§4.6).
7. Address spaces 5 and 8 (not in the home-screen set).
8. How stitched functions (IconRendering, RenderBox) reach the host.

## Evidence

| Claim | Level | Source |
|---|---|---|
| R7's results quoted in §1, §4.4, §4.5, §3.10 (functionIR form, home-screen processes, pipeline keys) | 3 | `metal-sim-protocol.md` (R7) |
| Header bytes 0–11 meaning | 1 + 2 | public `file(1)` magic database `/usr/share/file/magic/metallib`; confirmed on our files and the runtime's |
| Container layout, header, tag lists, function tags, extension sections, metadata tags, reflection list, embedded sources, universal forms (§2) | 2 | our `metallib_dump.py` on our own files (`metal`, `metallib`, `-frecord-sources`, `-gline-tables-only`, `MTLDynamicLibrary -serializeToURL:`) and on the runtime's 177 files (headers and tables only) |
| `HASH` = SHA-256 of the module | 2 | recomputed for 3 QuartzCore modules |
| `TYPE` values, `TESS`, `LAYR`, `VATT`/`VATY`/`CNST` payloads | 3 | our shaders of each kind (`kinds.metal`, `features.metal`, `fconst.metal`) through the public toolchain |
| FlatBuffers identifier `AIRR` | 2 + 1 | bytes of the `RBUF` payload; FlatBuffers format (public) |
| Bitcode wrapper, identification block, typed pointers, module version (§3.1) | 1 + 2 | LLVM bitcode documentation and `BitcodeReader`; `llvm-bcanalyzer-18` record counts on our modules and 4 QuartzCore modules (record kinds only) |
| LLVM 18 reads all 34 326 runtime modules | 3 | `air_inventory.py` (llvm-dis-18, no errors) |
| Triples, data layout, producers, language versions, address-space counts, named metadata, metadata keys, intrinsic names and counts (§3.2–§3.4, §3.10) | 4 | `air_inventory.py`, `addrspace_names.py`, `categorize.py`: names and counts only, text deleted after counting |
| Address-space meanings, entry metadata structure, argument buffer layout, function constants, sampler-state bits, intrinsic operands (§3.3, §3.5–§3.9) | 3 | our probe shaders (`features.metal`, `kinds.metal`, `tile.metal`, `sampler_bits.py`, the texture probe of Appendix A) compiled with `xcrun -sdk iphonesimulator metal -S -emit-llvm` |
| Names of runtime functions and bundles (§1, §3.10) | 4 | function-list `NAME` tags; file names in the runtime |
| SPIR-V, Vulkan and extension semantics (§4) | 1 | SPIR-V 1.6 specification, GLSL.std.450, Vulkan 1.4 specification and registry, Metal Shading Language specification and Metal API documentation (public) |
| Translator options and licenses (§4.2, §4.10) | 1 | project documentation and license files of LLVM, SPIRV-LLVM-Translator, SPIRV-Tools, SPIRV-Cross, SPIRV-Headers, MoltenVK |
| Thor packages, Vulkan features and limits (§4.10, §5) | 3 | `dpkg -l`, `llc-18 --version`, `vulkaninfo`, `vkrun --features` (read-only) |
| Host-memory import (§5) and the PoC results (§6) | 3 | `vkrun`, `vkdraw`, `airc` on the Thor |
| Design (§4, §7) | — | Ycode design |
| Compare-exchange operand form; fragment imageblock members and arguments; partially linked varyings; null-pointer reads in RealityKit functions (§3.9, §4.3, §4.5, §4.9) | 3 | ycode-airc `decls` (operand types only) and reflection of the functions visionOS RealityKit sent to Ycode's host (dumps kept on the Thor), visionos.md §10.13; our AIR test modules `tests/ir/interface-forms.sh`; GPU tests `CompareExchangeGPUTests`, `NullPointerGPUTests` |
| Compare-exchange semantics (§3.9) | 1 | Metal Shading Language specification (atomic functions); SPIR-V `OpAtomicCompareExchange` |
| Storage slots (§4.4): writes through a freed image's descriptor never complete on the Thor; texture views lacked storage views; explicit-level storage slots | 3 | `scripts/gpu-probes/imgoob.c` (our GLSL); Ycode boots and tests of stage8-contract.md §15.9; ycode-airc's own reflection (`storage_mip_levels`) |

No disassembly or decompilation was used (level 5 not used). No
`.claude/Xcode.app`, `research/dirty/`, or Ghidra project was opened. The
logic of the runtime's shaders was not read: bitcode was converted to text
only by scripts that kept names and counts. No runtime metallib, module
or extract left the agent's scratch directory or the Thor work directory.
The public Metal toolchain (component 27A266a) was installed with
`xcodebuild -downloadComponent MetalToolchain`.

## Appendix A. Programs and method

Sources (ours) in `research/experiments/simulator/metal-shaders/`; no
binaries. `poc.sh SCRATCH` reproduces §6 end to end.

| File | What it is |
|---|---|
| `metallib_dump.py` | container reader (§2): header, function list, extension, metadata tags, modules; universal forms; `--extract-dir` for our own files |
| `air_inventory.py` | names-only inventory of all metallibs under a root: container statistics, triples, layouts, producers, declared intrinsics, named metadata, metadata strings, attributes, address spaces; text deleted after counting |
| `categorize.py` | groups intrinsic families (§3.10) and computes the home-screen set |
| `addrspace_names.py` | counts pointee names per high address space in signatures (names only) |
| `sampler_bits.py` | constexpr sampler encoding (§3.7) from our own shader variants |
| `mtlcompile.m` | compiles MSL with the run-time compiler and serializes an `MTLDynamicLibrary` (used before the offline toolchain was installed) |
| `shaders/*.metal` | our probe and PoC shaders: `add`, `features`, `fconst`, `kinds`, `tile`, `poc`, `draw` |
| `airc/airc.cpp` | the PoC translator (§6) |
| `vk/vkrun.c`, `vk/add_ref.comp` | compute harness (ABI, features, host-memory import) and its GLSL reference |
| `vk/vkdraw.c`, `vk/draw_ref.vert`, `vk/draw_ref.frag` | render harness and its GLSL reference |
| `build-thor.sh`, `poc.sh` | build on the Thor (system packages only) and run everything |

Method notes: the inventory ran on the Thor over the runtime copy at
`$YCODE_DATA/runtimes/iOS-27.1-24A94401/RuntimeRoot`, with
outputs in `$YCODE_DATA/work/8-R8/`. The texture-intrinsic
probe of §3.9 was a scratch shader of ours with one fragment function per
`sample`/`read`/`gather`/query variant. No simulator device was created.

## Appendix B. Intrinsic families of the home-screen set

The 97 families used by QuartzCore, CoreUI, IconRendering, RenderBox,
CoreMaterial3D and MTLSimDriver (names only; `air.convert.*` counted once):

- Math (55): `air.abs`, `air.add_sat.u`, `air.all`, `air.any`, `air.ceil`,
  `air.clamp`, `air.ctz`, `air.dot`, `air.exp`, `air.fabs`,
  `air.fast_atan2`, `air.fast_ceil`, `air.fast_clamp`, `air.fast_cos`,
  `air.fast_exp`, `air.fast_exp2`, `air.fast_fabs`, `air.fast_floor`,
  `air.fast_fmax`, `air.fast_fmax3`, `air.fast_fmin`, `air.fast_fract`,
  `air.fast_log`, `air.fast_log2`, `air.fast_pow`, `air.fast_powr`,
  `air.fast_rsqrt`, `air.fast_saturate`, `air.fast_sin`,
  `air.fast_sincos`, `air.fast_sqrt`, `air.fast_trunc`, `air.floor`,
  `air.fma`, `air.fmax`, `air.fmax3`, `air.fmin`, `air.fmin3`,
  `air.fract`, `air.interpolate_center_perspective`, `air.log`,
  `air.log2`, `air.max`, `air.max.u`, `air.min`, `air.min.u`, `air.mix`,
  `air.pow`, `air.powr`, `air.reverse_bits`, `air.rsqrt`, `air.saturate`,
  `air.sign`, `air.sqrt`, `air.sub_sat.u`
- Conversions (1): `air.convert.*`
- Textures and samplers (14): `air.sample_texture_2d`,
  `air.sample_texture_3d`, `air.read_texture_2d`, `air.read_texture_2d.u`,
  `air.write_texture_2d`, `air.write_texture_2d.u`,
  `air.write_texture_2d.i16.u`, `air.get_width_texture_2d`,
  `air.get_height_texture_2d`, `air.is_null_texture_2d`,
  `air.get_null_texture_2d`, `air.get_null_texture_3d`,
  `air.get_read_sampler`, `air.write_imageblock_slice_to_texture_2d`
- Fragment (5): `air.discard_fragment`, `air.dfdx`, `air.dfdy`,
  `air.fwidth`, `air.get_num_samples`
- Imageblocks (3): `air.imageblock_data`, `air.load.implicit_imageblock`,
  `air.store.implicit_imageblock`
- SIMD, quad, barriers (5): `air.simd_sum`,
  `air.simd_shuffle_and_fill_down`, `air.quad_shuffle_xor`,
  `air.get_simdgroup_size`, `air.wg.barrier`
- Function constants and tables (3): `air.is_function_constant_defined`,
  `air.normalize_function_constant_predicate`,
  `air.get_function_pointer_visible_function_table`
- Pack (2): `air.pack.unorm.rgb565`, `air.unpack.unorm4x8`
- LLVM (9): `llvm.fmuladd`, `llvm.lifetime.start`, `llvm.lifetime.end`,
  `llvm.memcpy`, `llvm.memset`, `llvm.smax`, `llvm.smin`, `llvm.umax`,
  `llvm.umin`
